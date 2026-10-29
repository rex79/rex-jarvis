require_relative "env_file"
EnvFile.load # prima delle costanti: JARVIS_* e OPENROUTER_API_KEY possono venire da ~/.jarvis_env

module Config
  MAIN_MODEL = ENV.fetch("JARVIS_MODEL", "qwen3.5:4b")
  EMBED_MODEL = ENV.fetch("JARVIS_EMBED_MODEL", "nomic-embed-text")
  OLLAMA_URL  = ENV.fetch("OLLAMA_URL", "http://localhost:11434")
  BRAIN_DIR   = File.expand_path(ENV.fetch("JARVIS_BRAIN", "~/brain"))

  # Contesto di lavoro: note separate e SOLO modelli locali (vedi lib/privacy.rb).
  WORK_DIR    = File.expand_path(ENV.fetch("JARVIS_WORK_DIR", "~/jarvis-work"))
  WORK_MODEL  = ENV.fetch("JARVIS_WORK_MODEL", MAIN_MODEL)
  # Il router vede il testo dei comandi (anche di lavoro): usa sempre un modello locale.
  ROUTER_MODEL = ENV.fetch("JARVIS_ROUTER_MODEL", WORK_MODEL)
  MUSIC_APP   = ENV.fetch("JARVIS_MUSIC_APP", "Music") # Music | Spotify (solo macOS)
  MAX_TURNS   = 8
  MAX_TOOL_OUTPUT = 4000
  KEEP_ALIVE  = "30m"

  # Solo il digest può usare un provider online (contenuti pubblici); chat e note restano su Ollama locale.
  DIGEST_PROVIDER = ENV.fetch("JARVIS_DIGEST_PROVIDER", "ollama") # ollama | openrouter
  DIGEST_MODEL  = ENV["JARVIS_DIGEST_MODEL"] || (DIGEST_PROVIDER == "ollama" ? MAIN_MODEL : nil)
  OPENROUTER_URL = ENV.fetch("OPENROUTER_URL", "https://openrouter.ai/api/v1/chat/completions")
  DIGEST_ITEMS  = ENV["JARVIS_DIGEST_ITEMS"] && Integer(ENV["JARVIS_DIGEST_ITEMS"]) # default: somma dei posti delle categorie
  DIGEST_HOURS  = Integer(ENV.fetch("JARVIS_DIGEST_HOURS", "48"))
  SITE_DIR      = File.expand_path(ENV.fetch("JARVIS_SITE_DIR", "~/jarvis-site"))
  SOURCES_FILE  = File.expand_path("../config/sources.yml", __dir__)
  SIGNALS_FILE  = File.expand_path("../config/signals.yml", __dir__)

  # TradingAgents (contesto personale, Mac mini) via OpenRouter: solo dati di mercato pubblici.
  TRADING_FILE  = File.expand_path("../config/trading.yml", __dir__)
  TRADING_MODEL = ENV["JARVIS_TRADING_MODEL"]                       # obbligatorio, es. provider/modello
  TRADING_DEEP_MODEL = ENV["JARVIS_TRADING_DEEP_MODEL"] || TRADING_MODEL # per i ruoli che decidono
  TRADING_TICKERS = ENV["JARVIS_TRADING_TICKERS"] # es. "NVDA,ENEL.MI": se c'è, vince su config/trading.yml

  # Bot Telegram di Jarvis: risponde solo agli ID ammessi, in chat privata.
  TELEGRAM_TOKEN = ENV["JARVIS_TELEGRAM_TOKEN"]
  TELEGRAM_ALLOWED = ENV.fetch("JARVIS_TELEGRAM_ALLOWED_USERS", "").split(/[\s,]+/).reject(&:empty?)
end
