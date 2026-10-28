require "minitest/autorun"
require "tmpdir"
require "json"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("brain")
require_relative "../lib/signals"

class SignalsTest < Minitest::Test
  include Signals

  DAY = 86_400
  START = Time.utc(2026, 1, 1)

  # Candele con chiusure date; apertura = chiusura del giorno prima (come sulle crypto 24/7).
  def candles(closes, start: START)
    closes.each_with_index.map do |c, i|
      open = i.zero? ? c : closes[i - 1]
      Candle.new(time: start + i * DAY, open: open.to_f, high: [open, c].max + 1.0, low: [open, c].min - 1.0, close: c.to_f, volume: 1.0)
    end
  end

  def strategy = Strategy.new(fast: 2, slow: 4, atr: 2, stop_atr: 2)

  def test_sma_waits_for_enough_days
    assert_equal [nil, nil, 2.0, 3.0], Indicators.sma([1, 2, 3, 4], 3)
  end

  def test_atr_uses_previous_close_for_gaps
    c = candles([10, 20]) # gap da 10 a 20: high 21, low 9 → il true range include il salto
    assert_equal 12.0, Indicators.atr(c, 1)[1]
  end

  def test_fast_must_be_shorter_than_slow
    assert_raises(ArgumentError) { Strategy.new(fast: 200, slow: 50) }
  end

  def test_rising_market_is_in_and_falling_market_is_out
    up = strategy.positions(candles([10, 11, 12, 13, 14, 15]))
    assert_equal [nil, nil, nil, true, true, true], up
    down = strategy.positions(candles([15, 14, 13, 12, 11, 10]))
    assert_equal [nil, nil, nil, false, false, false], down
  end

  def test_signal_reports_entry_on_the_day_the_rule_turns_on
    s = strategy.signal("BTC-EUR", candles([20, 19, 18, 17, 16, 30]))
    assert_equal :entra, s.action
    assert_equal Date.new(2026, 1, 6), s.since
    assert s.stop < s.close
    assert_equal "BTC", s.base
  end

  def test_signal_reports_exit_and_no_stop_when_out
    s = strategy.signal("ETH-EUR", candles([10, 11, 12, 13, 14, 5]))
    assert_equal :esci, s.action
    assert_nil s.stop
  end

  def test_signal_with_too_little_history
    assert_equal :dati_insufficienti, strategy.signal("BTC-EUR", candles([1, 2])).action
  end

  def test_backtest_executes_next_open_and_charges_fees_both_ways
    c = candles([10, 10, 10, 10, 20, 40, 40, 5, 5])
    pos = [nil, nil, nil, false, true, true, false, false, false]
    bt = Backtest.run(c, pos, fee_percent: 1)
    trade = bt.trades.first
    assert_equal 1, bt.trades.size
    assert_equal 20.0, trade.entry # deciso alla chiusura del giorno 5, eseguito all'apertura del 6
    assert_equal 40.0, trade.exit  # deciso alla chiusura del giorno 7, eseguito all'apertura dell'8, prima del crollo
    assert_in_delta (40 * 0.99**2 / 20 - 1) * 100, trade.return_percent, 1e-9
    assert_in_delta trade.return_percent, bt.total_percent, 1e-9
    assert bt.max_drawdown_percent <= 0
  end

  def test_backtest_marks_open_position_at_last_close
    bt = Backtest.run(candles([10, 10, 10, 10, 20, 30]), [nil, nil, nil, true, true, true], fee_percent: 0)
    assert bt.trades.last.open
    assert_in_delta 200.0, bt.trades.last.return_percent, 1e-9 # entrata a 10, ultima chiusura 30
  end

  def test_italian_number_format
    assert_equal "72.320,45", Signals.number(72_320.454)
    assert_equal "−1.000,0", Signals.number(-1000, 1)
    assert_equal "0,1234 €", Signals.money(0.12341, "EUR")
    assert_equal "+12,3%", Signals.percent(12.34, sign: true)
  end

  class FakeSource
    def initialize(data) = @data = data

    def candles(product, **)
      raise Signals::Error, "coppia sconosciuta" unless @data.key?(product)

      @data[product]
    end
  end

  def test_run_writes_note_and_json_and_survives_a_failing_product
    config = { "products" => %w[BTC-EUR XYZ-EUR], "strategy" => { "fast" => 2, "slow" => 4, "atr" => 2 }, "fee_percent" => 0.5,
               "backtest" => { "years" => 1 } }
    source = FakeSource.new("BTC-EUR" => candles([10, 11, 12, 13, 14, 15, 16]))
    path, reports = Signals.run(now: Time.utc(2026, 1, 8, 7), source: source, config: config)

    note = File.read(path)
    assert_includes note, "## BTC-EUR: RESTA DENTRO"
    assert_includes note, "## XYZ-EUR: NON DISPONIBILE"
    assert_includes note, "| Rendimento totale |"
    assert_includes note, "non un consiglio di investimento"
    assert_equal 2, reports.size

    latest = Signals.latest
    assert_equal "resta_dentro", latest["signals"][0]["action"]
    assert_equal "coppia sconosciuta", latest["signals"][1]["error"]
  end
end

class CoinbaseTest < Minitest::Test
  DAY = 86_400

  def row(t, close) = [t, close - 1, close + 1, close, close, 1.0]

  def test_paginates_sorts_and_drops_the_unclosed_candle
    now = Time.utc(2026, 10, 28, 7)
    today = Time.utc(2026, 10, 28).to_i
    requests = []
    http = lambda do |uri|
      requests << uri
      params = URI.decode_www_form(uri.query).to_h
      finish = Time.iso8601(params["end"]).to_i
      # risponde dal più recente al più vecchio, includendo la candela di oggi non chiusa
      JSON.generate((0..299).map { |k| row(finish - k * DAY, 100.0 + k) } + (finish == today ? [row(today, 1.0)] : []))
    end
    candles = Signals::Coinbase.new(http: http, pause: 0).candles("BTC-EUR", days: 400, now: now)

    assert_equal 400, candles.size
    assert_equal 2, requests.size
    assert_equal "/products/BTC-EUR/candles", requests.first.path
    assert candles.each_cons(2).all? { |a, b| a.time < b.time }
    assert_equal Time.utc(2026, 10, 27), candles.last.time
  end

  def test_rejects_strange_product_names
    http = ->(_) { flunk "nessuna richiesta attesa" }
    assert_raises(Signals::Error) { Signals::Coinbase.new(http: http).candles("../../x", days: 10) }
  end

  def test_api_error_message_is_reported
    http = ->(_) { '{"message":"NotFound"}' }
    error = assert_raises(Signals::Error) { Signals::Coinbase.new(http: http, pause: 0).candles("FOO-EUR", days: 10) }
    assert_includes error.message, "NotFound"
  end
end
