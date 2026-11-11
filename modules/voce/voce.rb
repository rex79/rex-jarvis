require "json"
require "open3"
require "tempfile"
require "fileutils"
require "etc"
require_relative "../../lib/modules"

# Modalità vocale della dashboard: il tablet registra una frase, il Mac mini la trascrive con Whisper
# in locale (modules/voce/transcribe.py in .venv-voce, vedi bin/setup-voce) e restituisce il testo.
# Il testo poi segue la strada di ogni altro comando (/api/ask); la risposta la legge il tablet con la
# sua sintesi vocale. L'audio non esce da casa e non viene conservato.
module Voce
  class Error < StandardError; end

  ROOT = File.expand_path("../..", __dir__)
  PYTHON = File.join(ROOT, ".venv-voce", "bin", "python")
  SCRIPT = File.join(__dir__, "transcribe.py")
  MAX_AUDIO = 2 * 1024 * 1024 # una frase in Opus pesa poche decine di kB
  # Frasi che Whisper "sente" nel silenzio o nel rumore: non sono comandi.
  NOISE = /sottotitoli|amara\.org|grazie per (?:la visione|l'attenzione|aver guardato)|iscrivetevi|al prossimo (?:episodio|video)/i

  def self.model = ENV.fetch("JARVIS_VOCE_MODEL", "base")

  # Tiene acceso il processo Python e gli passa un file alla volta.
  class Transcriber
    START_TIMEOUT = 180 # caricare il modello sul Mac mini richiede tempo
    TIMEOUT = 90

    def initialize(command: nil, log: File.expand_path("~/.jarvis/voce.log"))
      @command = command || [PYTHON, "-I", SCRIPT, Voce.model, [Etc.nprocessors / 2, 1].max.to_s]
      @log = log
      @lock = Mutex.new
    end

    def ready? = File.executable?(@command.first)

    def transcribe(path)
      @lock.synchronize do
        start unless alive?
        @stdin.puts(JSON.generate(path: path))
        @stdin.flush
        answer(TIMEOUT).fetch("text").to_s
      end
    rescue Errno::EPIPE, IOError
      stop
      raise Error, "il servizio di trascrizione si è fermato: riprova (log in #{@log})"
    end

    # Carica il modello in anticipo, così la prima frase non aspetta.
    def warm_up
      Thread.new do
        @lock.synchronize { start unless alive? }
      rescue StandardError => e
        warn "⚠️  voce: #{e.message}"
      end
    end

    def stop
      Process.kill("TERM", @wait.pid) if alive?
    rescue Errno::ESRCH
      nil
    ensure
      @wait = nil
    end

    private

    def alive? = @wait&.alive?

    def start
      raise Error, "ambiente Python mancante: esegui bin/setup-voce" unless ready?

      FileUtils.mkdir_p(File.dirname(@log))
      @stdin, @stdout, @wait = Open3.popen2(*@command, err: [@log, "a"])
      answer(START_TIMEOUT)
    rescue Error
      stop # avvio fallito: il prossimo tentativo riparte da capo
      raise
    end

    def answer(timeout)
      unless @stdout.wait_readable(timeout)
        stop
        raise Error, "trascrizione non conclusa entro #{timeout} secondi"
      end
      line = @stdout.gets
      if line.nil?
        stop
        raise Error, "il servizio di trascrizione si è fermato (log in #{@log})"
      end
      data = JSON.parse(line)
      raise Error, data["error"] if data["error"] # se è un errore di avvio il processo è già uscito

      data
    rescue JSON::ParserError
      stop
      raise Error, "risposta non valida dal servizio di trascrizione (log in #{@log})"
    end
  end

  class Module < Modules::Base
    def initialize(transcriber: Transcriber.new)
      @transcriber = transcriber
    end

    # Alla partenza della dashboard il modello viene caricato in anticipo: la prima frase non aspetta.
    def start
      @transcriber.warm_up if @transcriber.ready?
    end

    def max_body = MAX_AUDIO

    # POST /api/modules/voce/trascrivi con l'audio come corpo → { text }
    def api(method, path, body, headers)
      raise ArgumentError, "richiesta non prevista" unless method == "POST" && path == "trascrivi"
      raise ArgumentError, "serve un file audio" unless headers["content-type"].to_s.match?(%r{\Aaudio/[\w.+-]+}i)
      raise ArgumentError, "audio vuoto" if body.to_s.empty?

      { text: Voce.clean(transcribe(body)) }
    rescue Error => e
      # L'errore di un file che non è audio contiene il percorso temporaneo: al tablet basta il senso.
      raise ArgumentError, e.message.match?(/Invalid ?data/i) ? "audio non leggibile" : e.message
    end

    def status = { ready: @transcriber.ready?, model: Voce.model }

    private

    # L'audio passa da un file temporaneo privato, cancellato subito dopo la trascrizione.
    def transcribe(audio)
      Tempfile.create(["jarvis-voce", ".audio"], binmode: true) do |file|
        file.write(audio)
        file.flush
        @transcriber.transcribe(file.path)
      end
    end
  end

  def self.clean(text)
    text = text.to_s.gsub(/\s+/, " ").strip
    text.match?(NOISE) ? "" : text[0, 500]
  end
end

Modules.register("voce") { Voce::Module.new }
