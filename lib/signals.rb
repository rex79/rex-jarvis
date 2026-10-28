require "yaml"
require "json"
require "fileutils"
require_relative "config"
require_relative "signals/coinbase"
require_relative "signals/strategy"
require_relative "signals/backtest"

# Segnali di trend sulle crypto, calcolati con regole fisse sulle candele giornaliere di Coinbase.
# Jarvis non ha chiavi di Coinbase e non manda ordini: scrive il segnale nelle note
# (~/brain/signals/AAAA-MM-GG.md) e in latest.json per la dashboard. L'ordine lo inserisci tu.
module Signals
  MONTHS = %w[gennaio febbraio marzo aprile maggio giugno luglio agosto settembre ottobre novembre dicembre].freeze

  Report = Struct.new(:signal, :backtest, :error, keyword_init: true)

  def self.dir = File.join(Config::BRAIN_DIR, "signals")

  def self.run(now: Time.now, source: Coinbase.new, config: YAML.load_file(Config::SIGNALS_FILE))
    strategy = Strategy.from_config(config["strategy"])
    fee = config.fetch("fee_percent", 0.6).to_f
    days = (config.dig("backtest", "years") || 5).to_i * 365 + strategy.slow

    reports = Array(config["products"]).map do |product|
      candles = source.candles(product, days: days, now: now)
      Report.new(signal: strategy.signal(product, candles),
                 backtest: Backtest.run(candles, strategy.positions(candles), fee_percent: fee))
    rescue Error => e
      warn "⚠️  #{product}: #{e.message}"
      Report.new(signal: Signal.new(product: product), error: e.message)
    end
    raise Error, "nessuna coppia in config/signals.yml" if reports.empty?

    write(reports, strategy, fee, now)
  end

  def self.write(reports, strategy, fee, now)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{now.strftime('%Y-%m-%d')}.md")
    File.write(path, render(reports, strategy, fee, now))
    File.write(File.join(dir, "latest.json"), JSON.pretty_generate(summary(reports, now)))
    [path, reports]
  end

  def self.render(reports, strategy, fee, now)
    p = strategy.params
    lines = ["# Segnali crypto — #{long_date(now.to_date)}", ""]
    lines << "> Regola: DENTRO quando la chiusura giornaliera è sopra la media a #{p[:slow]} giorni e la media a " \
             "#{p[:fast]} è sopra quella a #{p[:slow]}; FUORI altrimenti. Dati: candele giornaliere di Coinbase " \
             "chiuse alle 00:00 UTC. È una regola meccanica, non un consiglio di investimento: " \
             "decidi tu se e quanto comprare o vendere."
    lines << ""

    reports.each do |r|
      s = r.signal
      if r.error
        lines += ["## #{s.product}: NON DISPONIBILE", "", "Dati non scaricati: #{r.error}", ""]
        next
      end

      lines << "## #{s.product}: #{Strategy::ACTIONS[s.action]}"
      lines << ""
      if s.action == :dati_insufficienti
        lines += ["Servono almeno #{p[:slow]} giorni di storico per calcolare la media lenta.", ""]
        next
      end
      lines << "- Chiusura del #{long_date(s.date)}: #{money(s.close, s.quote)}"
      lines << "- Media #{p[:fast]} g: #{money(s.fast, s.quote)} · media #{p[:slow]} g: #{money(s.slow, s.quote)} " \
               "(prezzo #{percent(s.gap_percent, sign: true)} rispetto alla media lenta)"
      lines << "- In questo stato dal #{long_date(s.since)}" if s.since
      lines << "- Stop indicativo: #{money(s.stop, s.quote)} (chiusura − #{number(p[:stop_atr], 1)} × volatilità media a #{p[:atr]} g)" if s.stop
      lines << ""
      lines << "Su Coinbase: #{advice(s)}"
      lines << ""
      lines += backtest_lines(r.backtest, fee) if r.backtest
    end

    lines << "Il backtest esegue ogni segnale all'apertura del giorno dopo e non simula lo stop. " \
             "I risultati passati non dicono nulla di certo su quelli futuri."
    lines.join("\n") + "\n"
  end

  def self.advice(s)
    case s.action
    when :entra
      "segnale di **acquisto**. Se vuoi seguirlo, compra #{s.base} con un ordine limite vicino a " \
        "#{money(s.close, s.quote)} (costa meno di un ordine a mercato) e valuta uno stop a #{money(s.stop, s.quote)}."
    when :esci
      "segnale di **vendita**. Se hai #{s.base} comprato seguendo la regola, la regola dice di venderlo."
    when :resta_dentro
      "nessuna azione. Se sei dentro resta dentro; lo stop indicativo oggi è #{money(s.stop, s.quote)}."
    when :resta_fuori
      "nessuna azione. La regola resta fuori da #{s.base}."
    end
  end

  def self.backtest_lines(bt, fee)
    win = bt.win_rate_percent
    [
      "### Backtest dal #{long_date(bt.from)} (commissione #{number(fee, 2)}% a operazione)",
      "",
      "| | Regola | Compra e tieni |",
      "|---|---|---|",
      "| Rendimento totale | #{percent(bt.total_percent, sign: true)} | #{percent(bt.hold_total_percent, sign: true)} |",
      "| Rendimento annuo | #{percent(bt.annual_percent, sign: true)} | #{percent(bt.hold_annual_percent, sign: true)} |",
      "| Ribasso massimo | #{percent(bt.max_drawdown_percent)} | #{percent(bt.hold_max_drawdown_percent)} |",
      "| Operazioni | #{bt.trades.size}#{win ? " (#{percent(win)} in guadagno)" : ''} | 1 |",
      "| Tempo investito | #{percent(bt.exposure_percent)} | 100% |",
      ""
    ]
  end

  def self.summary(reports, now)
    {
      generated_at: now.iso8601,
      signals: reports.map do |r|
        s = r.signal
        next { product: s.product, error: r.error } if r.error

        {
          product: s.product, date: s.date&.iso8601, action: s.action, label: Strategy::ACTIONS[s.action],
          close: s.close, stop: s.stop, since: s.since&.iso8601, gap_percent: s.gap_percent&.round(1),
          backtest: r.backtest && {
            total_percent: r.backtest.total_percent.round(1), hold_total_percent: r.backtest.hold_total_percent.round(1),
            max_drawdown_percent: r.backtest.max_drawdown_percent.round(1),
            hold_max_drawdown_percent: r.backtest.hold_max_drawdown_percent.round(1)
          }
        }
      end
    }
  end

  # Ultimi segnali salvati, per la dashboard.
  def self.latest(path = File.join(dir, "latest.json"))
    return nil unless File.exist?(path)

    JSON.parse(File.read(path, encoding: "UTF-8"))
  end

  def self.long_date(date) = date && "#{date.day} #{MONTHS[date.month - 1]} #{date.year}"

  # Numeri all'italiana: 72.320,45
  def self.number(value, decimals = 2)
    return "–" if value.nil?

    int, dec = format("%.#{decimals}f", value.abs).split(".")
    text = int.reverse.scan(/\d{1,3}/).join(".").reverse
    text += ",#{dec}" if dec
    value.negative? && value.round(decimals) != 0 ? "−#{text}" : text
  end

  def self.money(value, quote)
    symbol = { "EUR" => "€", "USD" => "$", "GBP" => "£" }[quote]
    digits = value && value.abs < 1 ? 4 : 2
    symbol ? "#{number(value, digits)} #{symbol}" : "#{number(value, digits)} #{quote}"
  end

  def self.percent(value, sign: false)
    return "–" if value.nil?

    prefix = sign && value.round(1).positive? ? "+" : ""
    "#{prefix}#{number(value, 1)}%"
  end
end
