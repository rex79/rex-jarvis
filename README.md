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

## Daily digest
Raccoglie Reddit, Hacker News, blog e GitHub (`config/sources.yml`), deduplica e classifica
con regole semplici, poi riassume in italiano i migliori con Ollama. Il risultato è
`~/brain/digest/AAAA-MM-GG.md` e viene indicizzato, quindi `search_notes` lo trova.

```bash
ruby jarvis.rb --digest --dry-run   # solo raccolta e classifica, senza Ollama
ruby jarvis.rb --digest             # digest completo
```
Ogni mattina alle 7 con cron (`crontab -e`):
```
0 7 * * * cd ~/jarvis && ruby jarvis.rb --digest >> ~/jarvis-digest.log 2>&1
```
Variabili: `JARVIS_DIGEST_MODEL` (default = modello principale), `JARVIS_DIGEST_ITEMS` (8),
`JARVIS_DIGEST_HOURS` (48), `GITHUB_TOKEN` (opzionale, alza i limiti dell'API).
I contenuti dei feed sono non attendibili: il modello che li riassume non ha tool
e i link nel digest li scrive il codice, non il modello.
