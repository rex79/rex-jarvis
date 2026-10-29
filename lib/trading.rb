require "yaml"
require "json"
require "open3"
require "fileutils"
require "time"
require "date"
require "rbconfig"
require_relative "config"

# Analisi dei titoli con TradingAgents (framework multi-agente di TauricResearch) tramite
# lib/trading/runner.py nel .venv-trading del repo. Contesto personale: al modello su
# OpenRouter arrivano solo ticker e dati di mercato pubblici, mai note o dati di lavoro.
# Jarvis non ha chiavi di broker e non manda ordini: scrive la nota (~/brain/trading/AAAA-MM-GG.md)
# e latest.json per il bot Telegram. La decisione è tua.
module Trading
  class Error < StandardError; end

  Report = Struct.new(:ticker, :decision, :summary, :plan, :error, keyword_init: true)

  ROOT = File.expand_path("..", __dir__)
  PYTHON = File.join(ROOT, ".venv-trading", "bin", "python")
  RUNNER = File.join(ROOT, "lib", "trading", "runner.py")
  MAX_TICKERS = 5 # ogni titolo costa decine di chiamate al modello
  TIMEOUT = 30 * 60 # per titolo
  TICKER = /\A[A-Z0-9][A-Z0-9.\-^=]{0,14}\z/
  MONTHS = %w[gennaio febbraio marzo aprile maggio giugno luglio agosto settembre ottobre novembre dicembre].freeze
  # Le valutazioni di TradingAgents (a 3 o 5 livelli) in italiano.
  ACTIONS = {
    "BUY" => "ACQUISTA", "OVERWEIGHT" => "AUMENTA", "HOLD" => "MANTIENI",
    "UNDERWEIGHT" => "RIDUCI", "SELL" => "VENDI"
  }.freeze

  def self.dir = File.join(Config::BRAIN_DIR, "trading")
  # Report completi degli agenti: fuori da ~/brain per non gonfiare l'indice delle note.
  def self.results_dir = File.expand_path("~/.jarvis/trading")

  # La lista di ~/.jarvis_env (JARVIS_TRADING_TICKERS) vince su quella del repo: ogni macchina
  # tiene i suoi titoli e git pull non si scontra con le modifiche locali.
  def self.tickers(config, override = Config::TRADING_TICKERS)
    source = override.to_s.strip.empty? ? Array(config["tickers"]) : override.split(/[\s,;]+/)
    list = source.map { |t| t.to_s.strip.upcase }.reject(&:empty?).uniq
    raise Error, "nessun titolo: imposta JARVIS_TRADING_TICKERS o config/trading.yml" if list.empty?
    raise Error, "troppi titoli (#{list.size}): il massimo è #{MAX_TICKERS} per contenere i costi" if list.size > MAX_TICKERS

    bad = list.grep_v(TICKER)
    raise Error, "ticker non valido: #{bad.join(', ')}" unless bad.empty?

    list
  end

  def self.run(now: Time.now, config: YAML.load_file(Config::TRADING_FILE), runner: method(:analyze),
               model: Config::TRADING_MODEL, deep_model: Config::TRADING_DEEP_MODEL, override: Config::TRADING_TICKERS)
    raise Error, "imposta JARVIS_TRADING_MODEL (es. 'provider/modello', vedi openrouter.ai/models)" if model.to_s.empty?

    reports = tickers(config, override).map do |ticker|
      data = runner.call(
        ticker: ticker, date: now.to_date.iso8601, quick_model: model, deep_model: deep_model || model,
        debate_rounds: Integer(config.fetch("debate_rounds", 1)), max_tokens: Integer(config.fetch("max_tokens", 8192)),
        language: config.fetch("language", "Italian"),
        results_dir: results_dir
      )
      Report.new(ticker: ticker, decision: action(data["decision"]), summary: data["summary"].to_s, plan: data["plan"].to_s)
    rescue Error => e
      warn "⚠️  #{ticker}: #{e.message}"
      Report.new(ticker: ticker, error: e.message)
    end

    write(reports, now)
  end

  # "BUY", "Rating: Overweight", "**SELL**" → etichetta italiana; altrimenti il testo così com'è.
  def self.action(decision)
    word = decision.to_s.upcase.scan(/[A-Z]+/).find { |w| ACTIONS.key?(w) }
    word ? ACTIONS[word] : decision.to_s.strip[0, 40]
  end

  def self.write(reports, now)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{now.strftime('%Y-%m-%d')}.md")
    File.write(path, render(reports, now))
    File.write(File.join(dir, "latest.json"), JSON.pretty_generate(summary(reports, now)))
    [path, reports]
  end

  def self.render(reports, now)
    lines = ["# Analisi titoli — #{long_date(now.to_date)}", ""]
    lines << "> Analisi di TradingAgents: più agenti AI (analisti, ricercatori toro e orso, trader, gestione " \
             "del rischio) discutono ogni titolo su dati pubblici. È ricerca automatica, non un consiglio di " \
             "investimento: i modelli possono sbagliare o inventare. Decidi tu se e quanto comprare o vendere."
    lines << ""
    reports.each do |r|
      if r.error
        lines += ["## #{r.ticker}: NON DISPONIBILE", "", "Analisi non riuscita: #{r.error}", ""]
        next
      end
      lines += ["## #{r.ticker}: #{r.decision}", ""]
      lines += ["### Decisione finale", "", r.summary, ""] unless r.summary.empty?
      lines += ["### Piano del trader", "", r.plan, ""] unless r.plan.empty?
    end
    lines.join("\n") + "\n"
  end

  def self.summary(reports, now)
    {
      generated_at: now.iso8601,
      date: now.to_date.iso8601,
      tickers: reports.map do |r|
        r.error ? { ticker: r.ticker, error: r.error } : { ticker: r.ticker, decision: r.decision, summary: r.summary }
      end
    }
  end

  # Un'analisi alla volta sulla stessa macchina (cron, terminale e dashboard possono sovrapporsi).
  def self.exclusive(lock = File.expand_path("~/.jarvis/trading.lock"))
    FileUtils.mkdir_p(File.dirname(lock))
    File.open(lock, File::RDWR | File::CREAT, 0o600) do |f|
      raise Error, "un'analisi è già in corso su questa macchina" unless f.flock(File::LOCK_EX | File::LOCK_NB)

      yield
    end
  end

  # L'indice delle note (embedding con Ollama) è lento sul Mac mini: parte dopo, in background e a
  # bassa priorità, così il risultato è subito disponibile. Log in ~/.jarvis/index.log.
  def self.index_later(log = File.expand_path("~/.jarvis/index.log"))
    FileUtils.mkdir_p(File.dirname(log))
    command = [RbConfig.ruby, File.join(ROOT, "jarvis.rb"), "--index"]
    command = ["nice", "-n", "19", *command] if system("command -v nice >/dev/null 2>&1")
    pid = Process.spawn(*command, chdir: ROOT, in: File::NULL, out: [log, "a"], err: [log, "a"], pgroup: true)
    Process.detach(pid)
    pid
  end

  # Comando eseguito sul Mac mini dalla chiave SSH dedicata della dashboard (forced command):
  # "run" lancia l'analisi, "latest" restituisce l'ultima. Ultima riga: JSON con latest e nota.
  def self.remote(command, run: -> { exclusive { Trading.run } }, index: method(:index_later))
    case command.to_s.strip
    when "run"
      run.call
      index.call
    when "latest" then nil
    else raise Error, "comando non consentito"
    end
    { latest: latest, note: latest_note }
  end

  def self.latest_note
    file = Dir.glob(File.join(dir, "*.md")).max
    file && { name: File.basename(file), text: File.read(file, encoding: "UTF-8") }
  end

  def self.latest(path = File.join(dir, "latest.json"))
    return nil unless File.exist?(path)

    JSON.parse(File.read(path, encoding: "UTF-8"))
  end

  def self.long_date(date) = "#{date.day} #{MONTHS[date.month - 1]} #{date.year}"

  def self.analyze(request)
    raise Error, "ambiente Python mancante: esegui bin/setup-trading" unless File.executable?(PYTHON)
    raise Error, "OPENROUTER_API_KEY non impostata" if ENV["OPENROUTER_API_KEY"].to_s.empty?

    out = +""
    Open3.popen3(PYTHON, "-I", RUNNER) do |stdin, stdout, stderr, thread|
      stdin.write(JSON.generate(request))
      stdin.close
      reader = Thread.new { stdout.read }
      Thread.new { stderr.read } # log delle librerie: scartati
      unless thread.join(TIMEOUT)
        Process.kill("TERM", thread.pid)
        raise Error, "analisi non conclusa entro #{TIMEOUT / 60} minuti"
      end
      out = reader.value.to_s
    end
    data = JSON.parse(out.lines.last.to_s)
    raise Error, data["error"] if data["error"]

    data
  rescue JSON::ParserError
    raise Error, "risposta non valida da TradingAgents"
  end
end
