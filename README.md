# Jarvis

Assistente locale in Ruby (solo libreria standard) basato su Ollama, con un "second brain" di note Markdown.

## Requisiti
- Ruby 3.x, Ollama in esecuzione
- `ollama pull qwen3.5:4b` e `ollama pull nomic-embed-text`

## Uso
```bash
mkdir -p ~/brain          # metti qui le tue note .md
ruby jarvis.rb --index    # indicizza (solo i file cambiati)
ruby jarvis.rb            # chat
ruby test/test_tools.rb   # test
```

## Configurazione (variabili d'ambiente)
`JARVIS_MODEL`, `JARVIS_EMBED_MODEL`, `JARVIS_BRAIN` (default `~/brain`), `OLLAMA_URL`.

## Tool dell'agente
`search_notes`, `list_files`, `read_file`, `save_note`, `current_time`.
L'accesso ai file è limitato alla cartella note.
