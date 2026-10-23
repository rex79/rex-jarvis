require "json"
require "open3"
require "fileutils"
require "time"
require_relative "../config"

# Inoltra richieste all'agente aziendale Copilot Studio tramite lib/copilot/bridge.py
# (client ufficiale Microsoft nel .venv del repo). Solo contesto di lavoro: i dati vanno
# esclusivamente al tenant Microsoft dell'azienda; il ponte rifiuta altri endpoint.
module Copilot
  class Error < StandardError
    attr_reader :code

    def initialize(message, code = "ERROR")
      super(message)
      @code = code
    end
  end

  ROOT = File.expand_path("../..", __dir__)
  PYTHON = File.join(ROOT, ".venv", "bin", "python")
  BRIDGE = File.join(ROOT, "lib", "copilot", "bridge.py")
  TIMEOUT = 240
  VARS = %w[JARVIS_COPILOT_TENANT_ID JARVIS_COPILOT_CLIENT_ID JARVIS_COPILOT_ENVIRONMENT_ID JARVIS_COPILOT_AGENT].freeze

  def self.configured?
    VARS.all? { |v| !ENV[v].to_s.strip.empty? } && File.executable?(PYTHON)
  end

  def self.ask(text, conversation_id: nil, runner: method(:run))
    raise Error.new("Copilot non configurato: servono #{VARS.join(', ')} e bin/setup-copilot", "CONFIG") unless configured?

    data = runner.call("ask", JSON.generate(text: text, conversation_id: conversation_id))
    { text: data.fetch("text"), conversation_id: data["conversation_id"] }
  end

  def self.status(runner: method(:run)) = runner.call("status", "")
  def self.login(runner: method(:run)) = runner.call("login", "")

  # Copia locale della risposta nelle note di lavoro (Markdown, ricercabile con search_notes).
  def self.save_copy(question, answer, dir: File.join(Config::WORK_DIR, "copilot"), now: Time.now)
    FileUtils.mkdir_p(dir)
    slug = question.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 50]
    path = File.join(dir, "#{now.strftime('%Y-%m-%d-%H%M')}-#{slug.empty? ? 'risposta' : slug}.md")
    File.write(path, "# #{question}\n\n_Copilot · #{now.strftime('%d/%m/%Y %H:%M')}_\n\n#{answer}\n")
    path
  end

  def self.run(command, input)
    out = +""
    Open3.popen3(PYTHON, "-I", BRIDGE, command) do |stdin, stdout, stderr, thread|
      stdin.write(input)
      stdin.close
      reader = Thread.new { stdout.read }
      Thread.new { stderr.read } # svuota stderr (log del client) senza mostrarlo
      unless thread.join(command == "login" ? 600 : TIMEOUT)
        Process.kill("TERM", thread.pid)
        raise Error.new("l'agente Copilot non ha risposto entro #{TIMEOUT} secondi", "TIMEOUT")
      end
      out = reader.value.to_s
    end
    data = JSON.parse(out.lines.last.to_s)
    raise Error.new(data["error"], data["code"]) if data["error"]

    data
  rescue JSON::ParserError
    raise Error.new("risposta non valida dal ponte Copilot", "BRIDGE")
  rescue Errno::ENOENT
    raise Error.new("ambiente Python mancante: esegui bin/setup-copilot", "CONFIG")
  end
end
