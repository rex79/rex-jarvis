require "minitest/autorun"
require "tmpdir"
require "json"
ENV["JARVIS_BRAIN"] ||= Dir.mktmpdir("personal")
ENV["JARVIS_SITE_DIR"] ||= Dir.mktmpdir("site")
require_relative "finanza"

class FinanzaTest < Minitest::Test
  TODAY = Date.new(2026, 11, 27)

  def settings
    YAML.safe_load(Finanza::DEFAULT_SETTINGS, permitted_classes: [Date])
  end

  def quote(ticker, closes, last_day: TODAY - 1)
    dates = closes.each_index.map { |i| last_day - (closes.size - 1 - i) }
    Finanza::Quote.new(ticker, dates, closes)
  end

  def positions(s, equity_qty: 0, cash_qty: 0, quotes: {})
    moves = []
    moves << { isin: "IE0003XJA0J9", quote: equity_qty, prezzo: 10.0 } if equity_qty.positive?
    moves << { isin: "LU1190417599", quote: cash_qty, prezzo: 100.0 } if cash_qty.positive?
    Finanza::Portfolio.positions(s, moves, quotes)
  end

  def evaluate(s, quotes, rates: nil, prev: {}, today: TODAY, **pos)
    Finanza::Rules.evaluate(s, positions(s, quotes: quotes, **pos), quotes, rates, prev, today)
  end

  def calm(eq = [10, 10, 10]) = { "WEBN.MI" => quote("WEBN.MI", eq), "SMART.MI" => quote("SMART.MI", [100, 100, 100]) }

  def test_quiet_market_gives_no_alerts
    assert_empty evaluate(settings, calm, equity_qty: 40, cash_qty: 3)
  end

  def test_strong_drop_proposes_half_of_cushion_above_minimum
    a = evaluate(settings, calm([12, 10, 10]), equity_qty: 40, cash_qty: 3).find { |x| x.key == "calo-forte" }
    assert a.action?
    assert_includes a.proposal, "75 €" # (300 - 150) / 2
  end

  def test_very_strong_drop_with_cushion_at_minimum_says_do_nothing
    a = evaluate(settings, calm([14, 10, 10]), equity_qty: 40, cash_qty: 1.5).find { |x| x.key == "calo-molto-forte" }
    assert_includes a.proposal, "non vendere"
  end

  def test_daily_move_and_watched_stock_are_info_with_impact
    q = calm([10, 10, 10.4]).merge("NVDA" => quote("NVDA", [100, 100, 88]))
    alerts = evaluate(settings, q, equity_qty: 40, cash_qty: 3)
    nvda = alerts.find { |a| a.key.start_with?("titolo-NVDA") }
    refute nvda.action?
    assert_includes nvda.why, "−0,6%".sub("−", "-") # -12% × 5%
    assert alerts.find { |a| a.key.start_with?("movimento-etf") }
  end

  def test_drift_suggests_where_to_put_new_money_never_to_sell
    a = evaluate(settings, calm, equity_qty: 90, cash_qty: 1).find { |x| x.key == "scostamento-sopra" }
    assert_includes a.proposal, "monetario"
    assert_includes a.proposal, "Non vendere"
  end

  def test_pac_reminder_two_days_before
    s = settings
    s["pac"]["attivo"] = true
    a = evaluate(s, calm, today: Date.new(2026, 12, 8)).find { |x| x.key == "pac-2026-12-10" }
    assert_includes a.proposal, "100 €"
  end

  def test_promo_expiring_only_for_used_issuers
    s = settings
    keys = evaluate(s, calm, today: Date.new(2027, 3, 20)).map(&:key)
    assert_includes keys, "promo-Amundi-2027-03-28"
    refute keys.any? { |k| k.include?("iShares") || k.include?("Xtrackers") }
  end

  def test_ecb_change_is_flagged
    rates = Finanza::Rates.new(dfr: 2.25, estr: 2.19)
    a = evaluate(settings, calm, rates: rates, prev: { "dfr" => 2.5 }).find { |x| x.key == "bce-2.25" }
    assert_includes a.why, "2.5% a 2.25%"
  end

  def test_pac_dates_clip_to_month_end_and_skip_already_recorded
    pac = { "inizio" => Date.new(2026, 12, 31), "giorno" => 31 }
    assert_equal [Date.new(2026, 12, 31), Date.new(2027, 1, 31), Date.new(2027, 2, 28)],
                 Finanza::Portfolio.pac_dates(pac, Date.new(2026, 12, 30), Date.new(2027, 3, 1))
    assert_equal [Date.new(2027, 2, 28)], Finanza::Portfolio.pac_dates(pac, Date.new(2027, 1, 31), Date.new(2027, 3, 1))
  end

  def test_news_impact_is_decided_by_code
    w = settings["osservati"]
    item = DailyDigest::Item.new(title: "Nvidia CEO returns", text: "", url: "https://x", source: "FT")
    assert_includes Finanza::News.for_you(item, w), "5%"
    fed = DailyDigest::Item.new(title: "Fed poised to raise rates", text: "", url: "https://x", source: "FT")
    assert_includes Finanza::News.for_you(fed, w), "non il rendimento"
  end

  def test_summary_falls_back_when_small_model_doubts_the_news
    llm = Object.new
    def llm.chat(*, **) = { "message" => { "content" => "La notizia è falsa e non contiene informazioni utili." } }
    item = DailyDigest::Item.new(title: "T", text: "Testo originale", url: "https://x", source: "FT")
    assert_equal "Testo originale", Finanza::News.summarize(item, llm)
  end

  def test_parse_yahoo_and_ecb
    body = { chart: { result: [{ timestamp: [1_764_115_200, 1_764_201_600, 1_764_288_000],
                                 indicators: { quote: [{ close: [10.0, nil, 11.0] }] } }] } }.to_json
    q = Finanza::Market.parse_quote("X", body)
    assert_equal [10.0, 11.0], q.closes
    assert_equal 2.445, Finanza::Market.ecb_value("KEY,TIME_PERIOD,OBS_VALUE,X\nEST,2026-11-26,2.445,\"a,b\"\n")
  end

  # Giro completo con dati finti: rata PAC registrata, pagina scritta, Telegram solo per le novità.
  def test_run_records_pac_writes_page_and_sends_only_new_alerts
    dir = Dir.mktmpdir
    store = Finanza::Store.new(dir)
    store.ensure_files!
    File.write(File.join(dir, "portafoglio.yml"), File.read(File.join(dir, "portafoglio.yml")).sub("attivo: false", "attivo: true"))
    day = Date.new(2026, 12, 14)
    stamps = (0..9).map { |i| Time.utc(2026, 12, 5 + i).to_i }
    chart = ->(c) { { chart: { result: [{ timestamp: stamps, indicators: { quote: [{ close: c }] } }] } }.to_json }
    http = lambda do |url|
      case url
      when /WEBN/ then chart.call([13.0] * 5 + [10.0] * 5) # −23% dal massimo
      when /SMART/ then chart.call([110.0] * 10)
      when /chart/ then chart.call([100.0] * 10)
      when /data-api/ then "KEY,OBS_VALUE\nX,2.5\n"
      else "<rss></rss>"
      end
    end
    sent = []
    notifier = ->(_to, text) { sent << text; true }
    Finanza.run(today: day, now: Time.utc(2026, 12, 14, 7), store: store, http: http, llm: nil, notifier: notifier, publish: false)

    rows = store.moves
    assert_equal 2, rows.size
    assert_in_delta 7.0, rows.find { |m| m[:isin] == "IE0003XJA0J9" }[:quote], 0.001 # 70 € a 10 € (chiusura del 10/12)
    assert_equal 1, sent.size
    assert_includes sent.first, "Mercato in calo"
    assert File.file?(File.join(Config::SITE_DIR, "finanza.html"))

    sent.clear
    Finanza.run(today: day + 1, now: Time.utc(2026, 12, 15, 7), store: store, http: http, llm: nil, notifier: notifier, publish: false)
    assert_equal 2, store.moves.size # la rata non viene registrata due volte
    assert_empty sent # stesso avviso: non lo ripete
  end

  def test_chat_reply_without_model
    dir = Dir.mktmpdir
    store = Finanza::Store.new(dir)
    assert_nil Finanza::Module.new(store: store).handle("che tempo fa")
    store.ensure_files!
    store.save_state({ "ultimo" => { "data" => "2026-11-27", "riepilogo" => ["Fineco: 700 €"], "avvisi" => [] } })
    assert_includes Finanza::Module.new(store: store).handle("come va il portafoglio?"), "Fineco: 700 €"
  end
end
