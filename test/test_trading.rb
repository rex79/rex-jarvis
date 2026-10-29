require "minitest/autorun"
require "tmpdir"
require "json"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("brain")
require_relative "../lib/trading"
require_relative "../lib/telegram_bot"

class TradingTest < Minitest::Test
  NOW = Time.new(2026, 10, 29, 7, 0, 0)

  def fake_runner(results)
    calls = []
    runner = lambda do |request|
      calls << request
      result = results.fetch(request[:ticker])
      raise Trading::Error, result if result.is_a?(String)

      result
    end
    [runner, calls]
  end

  def test_tickers_are_normalized_and_capped
    assert_equal %w[NVDA ENEL.MI], Trading.tickers({ "tickers" => [" nvda", "ENEL.MI", "NVDA"] }, nil)
    assert_raises(Trading::Error) { Trading.tickers({ "tickers" => [] }, nil) }
    assert_raises(Trading::Error) { Trading.tickers({ "tickers" => %w[A B C D E F] }, nil) }
    assert_raises(Trading::Error) { Trading.tickers({ "tickers" => ["NVDA; rm -rf"] }, nil) }
  end

  def test_env_list_wins_over_config
    assert_equal %w[TSLA ENEL.MI], Trading.tickers({ "tickers" => ["NVDA"] }, "tsla, ENEL.MI")
    assert_equal %w[NVDA], Trading.tickers({ "tickers" => ["NVDA"] }, " ")
  end

  def test_decisions_become_italian_labels
    assert_equal "ACQUISTA", Trading.action("BUY")
    assert_equal "AUMENTA", Trading.action("Rating: **Overweight**")
    assert_equal "VENDI", Trading.action("sell\n")
    assert_equal "boh", Trading.action(" boh ")
  end

  def test_model_is_required
    runner, = fake_runner({})
    err = assert_raises(Trading::Error) { Trading.run(now: NOW, config: { "tickers" => ["NVDA"] }, runner: runner, model: nil) }
    assert_match(/JARVIS_TRADING_MODEL/, err.message)
  end

  def test_run_writes_note_and_latest_and_survives_a_failure
    runner, calls = fake_runner(
      "NVDA" => { "decision" => "BUY", "summary" => "Crescita forte.", "plan" => "Entrare a scaglioni." },
      "AAPL" => "analisi non conclusa entro 30 minuti"
    )
    path, reports = Trading.run(now: NOW, config: { "tickers" => %w[NVDA AAPL], "debate_rounds" => 2 },
                                runner: runner, model: "prov/veloce", deep_model: nil, override: nil)

    assert_equal "2026-10-29", calls.first[:date]
    assert_equal "prov/veloce", calls.first[:deep_model]
    assert_equal 2, calls.first[:debate_rounds]
    assert_equal 8192, calls.first[:max_tokens]
    assert_equal ["ACQUISTA", nil], reports.map(&:decision)
    note = File.read(path, encoding: "UTF-8")
    assert_includes note, "# Analisi titoli — 29 ottobre 2026"
    assert_includes note, "## NVDA: ACQUISTA"
    assert_includes note, "Entrare a scaglioni."
    assert_includes note, "## AAPL: NON DISPONIBILE"
    assert_includes note, "non un consiglio di investimento"
    latest = Trading.latest
    assert_equal({ "ticker" => "NVDA", "decision" => "ACQUISTA", "summary" => "Crescita forte." }, latest["tickers"][0])
    assert_equal "AAPL", latest["tickers"][1]["ticker"]
  end
end

class TelegramBotTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @trading = File.join(@dir, "trading.json")
    @signals = File.join(@dir, "signals.json")
    File.write(@trading, JSON.generate(date: "2026-10-29", tickers: [
      { ticker: "NVDA", decision: "ACQUISTA", summary: "Crescita forte." },
      { ticker: "AAPL", error: "timeout" }
    ]))
    File.write(@signals, JSON.generate(signals: [{ product: "BTC-EUR", label: "RESTA DENTRO" }]))
    @sent = []
    http = lambda do |method, params|
      @sent << [method, params]
      []
    end
    @bot = TelegramBot.new(token: "t", allowed: ["42"], trading_file: @trading, signals_file: @signals, http: http)
  end

  def update_for(text, from: 42, type: "private")
    { "update_id" => 1, "message" => { "text" => text, "from" => { "id" => from }, "chat" => { "id" => from, "type" => type } } }
  end

  def test_requires_token_and_allowed_users
    assert_raises(TelegramBot::Error) { TelegramBot.new(token: "", allowed: ["1"]) }
    assert_raises(TelegramBot::Error) { TelegramBot.new(token: "t", allowed: []) }
  end

  def test_ignores_strangers_and_groups
    capture_io do
      @bot.process(update_for("/trading", from: 7))
      @bot.process(update_for("/trading", type: "group"))
    end
    assert_empty @sent
  end

  def test_trading_overview_and_detail
    @bot.process(update_for("/trading"))
    method, params = @sent.last
    assert_equal "sendMessage", method
    assert_equal 42, params[:chat_id]
    assert_includes params[:text], "29 ottobre 2026"
    assert_includes params[:text], "NVDA: ACQUISTA"
    assert_includes params[:text], "AAPL: non disponibile"

    assert_includes @bot.answer("/trading nvda"), "Crescita forte."
    assert_includes @bot.answer("/trading TSLA"), "non è nell'analisi"
    assert_includes @bot.answer("/trading AAPL"), "timeout"
  end

  def test_signals_help_and_missing_reports
    assert_includes @bot.answer("/segnali"), "BTC-EUR: RESTA DENTRO"
    assert_equal TelegramBot::HELP, @bot.answer("/start")
    assert_equal TelegramBot::HELP, @bot.answer("ciao")
    assert_includes @bot.answer("/trading@JarvisBot"), "NVDA"
    File.delete(@trading)
    assert_includes @bot.answer("/trading"), "--trading"
  end

  def test_long_replies_are_split
    chunks = @bot.chunks("riga\n" * 2000)
    assert_operator chunks.size, :>, 1
    assert(chunks.all? { |c| c.size <= TelegramBot::MAX_MESSAGE })
    assert_equal "riga\n" * 2000, chunks.join
  end
end
