module Config
  MAIN_MODEL  = ENV.fetch("JARVIS_MODEL", "qwen3.5:4b")
  EMBED_MODEL = ENV.fetch("JARVIS_EMBED_MODEL", "nomic-embed-text")
  OLLAMA_URL  = ENV.fetch("OLLAMA_URL", "http://localhost:11434")
  BRAIN_DIR   = File.expand_path(ENV.fetch("JARVIS_BRAIN", "~/brain"))
  INDEX_FILE  = File.join(BRAIN_DIR, ".jarvis_index.json")
  MAX_TURNS   = 8
  MAX_TOOL_OUTPUT = 4000
  KEEP_ALIVE  = "30m"
end
