require "json"
require "open3"
require "fileutils"
require_relative "config"
require_relative "trading"

# La dashboard (Mac di lavoro) chiede al Mac mini di lanciare TradingAgents via SSH, con una chiave
# dedicata che sul Mac mini può eseguire solo `jarvis.rb --trading-remote` (command= in
# authorized_keys). Nessuna porta nuova: passa dall'SSH già aperto in LAN. Il risultato (ricerca su
# dati pubblici) viene copiato in ~/brain/trading anche qui, così dashboard e note lo vedono.
module TradingRemote
  class Error < StandardError; end

  HOST = /\A[A-Za-z0-9_][\w.-]*@[A-Za-z0-9][\w.:-]*\z/ # utente@host: niente opzioni travestite
  TIMEOUT = Trading::MAX_TICKERS * Trading::TIMEOUT + 300

  def self.host = ENV["JARVIS_TRADING_SSH"].to_s.strip
  def self.key = File.expand_path(ENV.fetch("JARVIS_TRADING_SSH_KEY", "~/.ssh/jarvis_trading"))
  def self.configured? = host.match?(HOST) && File.file?(key)

  def self.run(runner: method(:ssh)) = save(call("run", runner))
  def self.latest(runner: method(:ssh)) = save(call("latest", runner))

  def self.call(command, runner)
    raise Error, "imposta JARVIS_TRADING_SSH (es. rex@192.168.2.26) e la chiave #{key}" unless configured?

    data = JSON.parse(runner.call(command).to_s.lines.last.to_s)
    raise Error, data["error"] if data["error"]

    data
  rescue JSON::ParserError
    raise Error, "risposta non valida dal Mac mini"
  end

  def self.save(data, dir: Trading.dir)
    latest = data["latest"] or return nil
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "latest.json"), JSON.pretty_generate(latest))
    note = data["note"]
    if note && note["name"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\.md\z/)
      File.write(File.join(dir, note["name"]), note["text"].to_s)
    end
    latest
  end

  def self.ssh(command)
    args = ["ssh", "-T", "-i", key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=60", host, command]
    out = +""
    Open3.popen3(*args) do |stdin, stdout, stderr, thread|
      stdin.close
      reader = Thread.new { stdout.read }
      errors = Thread.new { stderr.read }
      unless thread.join(TIMEOUT)
        Process.kill("TERM", thread.pid)
        raise Error, "il Mac mini non ha finito entro #{TIMEOUT / 60} minuti"
      end
      out = reader.value.to_s
      if out.strip.empty?
        message = errors.value.to_s.lines.grep_v(/^\s*$/).last.to_s.strip
        raise Error, "Mac mini non raggiungibile: #{message.empty? ? 'nessuna risposta' : message[0, 200]}"
      end
    end
    out
  end
end
