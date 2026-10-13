module Config
  MAIN_MODEL  = ENV.fetch("JARVIS_MODEL", "qwen3.5:4b")
  EMBED_MODEL = ENV.fetch("JARVIS_EMBED_MODEL", "nomic-embed-text")
  OLLAMA_URL  = ENV.fetch("OLLAMA_URL", "http://localhost:11434")
  BRAIN_DIR   = File.expand_path(ENV.fetch("JARVIS_BRAIN", "~/brain"))
  INDEX_FILE  = File.join(BRAIN_DIR, ".jarvis_index.json")
  MAX_TURNS   = 8
  MAX_TOOL_OUTPUT = 4000
  KEEP_ALIVE  = "30m"

  DIGEST_MODEL  = ENV.fetch("JARVIS_DIGEST_MODEL", MAIN_MODEL)
  DIGEST_ITEMS  = Integer(ENV.fetch("JARVIS_DIGEST_ITEMS", "8"))
  DIGEST_HOURS  = Integer(ENV.fetch("JARVIS_DIGEST_HOURS", "48"))
  SOURCES_FILE  = File.expand_path("../config/sources.yml", __dir__)
end
