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
### Digest con un modello online (OpenRouter)
Solo il digest può usare un provider online; chat e note restano su Ollama locale
(i frammenti delle note non escono dalla macchina). Il digest invia a OpenRouter solo
titoli e testi di contenuti pubblici.
Metti le impostazioni in `~/.jarvis_env` (letto in automatico, ignorato da git):
```bash
OPENROUTER_API_KEY=sk-or-...
JARVIS_DIGEST_PROVIDER=openrouter
JARVIS_DIGEST_MODEL=provider/modello   # vedi openrouter.ai/models
```
```bash
chmod 600 ~/.jarvis_env   # solo tu puoi leggerlo (Jarvis avvisa se è troppo aperto)
ruby jarvis.rb --digest
```
Una variabile già presente nell'ambiente ha la precedenza sul file. Un altro percorso si
indica con `JARVIS_ENV_FILE`. Il cron funziona senza altro, perché Jarvis legge il file da solo.
Se la chiave è errata o il credito è finito il digest si ferma subito con un messaggio chiaro.

Variabili: `JARVIS_DIGEST_PROVIDER` (`ollama` o `openrouter`), `JARVIS_DIGEST_MODEL`
(con Ollama default = modello principale, con OpenRouter obbligatorio), `JARVIS_DIGEST_ITEMS` (8),
`JARVIS_DIGEST_HOURS` (48), `GITHUB_TOKEN` (opzionale, alza i limiti dell'API).
I contenuti dei feed sono non attendibili: il modello che li riassume non ha tool
e i link nel digest li scrive il codice, non il modello.

### Reddit con OAuth
Reddit limita spesso i feed RSS pubblici (errore 429). Con un'app gratuita di tipo *script*
(reddit.com/prefs/apps) Jarvis usa l'API ufficiale. Servono solo id e secret dell'app,
**non** la password dell'account: legge contenuti pubblici. In `~/.jarvis_env`:
```
REDDIT_CLIENT_ID=...
REDDIT_CLIENT_SECRET=...
REDDIT_USER_AGENT=jarvis-digest/0.1 by u/tuo_username
```
Senza credenziali, o se l'API rifiuta quelle indicate, il digest usa i feed RSS e lo segnala.
Il token resta in memoria e non viene mai scritto su disco né stampato.

### Memoria dei link già visti
Dopo ogni digest i contenuti pubblicati vengono registrati in `~/brain/digest/.visti.json`
(link e titolo normalizzati, voci più vecchie di 30 giorni eliminate). Il giorno dopo non
ricompaiono e al loro posto entrano altre voci. Rilanciare il digest nello stesso giorno
mantiene quelle già pubblicate oggi. Se un giorno non c'è nulla di nuovo, non viene creato
nessun file. Per ripartire da zero basta cancellare `~/brain/digest/.visti.json`.

### Interfaccia web
`ruby jarvis.rb --site` trasforma i digest in `~/brain/digest/*.md` in un sito statico in
`~/jarvis-site` (cambiabile con `JARVIS_SITE_DIR`): ultimo digest in home, archivio per giorno,
ricerca, voci "poco rilevanti" solo attenuate (con un interruttore per nasconderle; i contatori delle sezioni seguono le card visibili), tema chiaro/scuro, adatto al telefono.
Viene rigenerato da solo alla fine di ogni `--digest`. Nessuna risorsa esterna: HTML, CSS e JS inline.
Titoli e testi arrivano da internet, quindi sono sempre escapati e i link accettati sono solo http(s).

Per consultarlo dalla rete di casa serve solo un server di file (il sito pubblica solo quella
cartella, non `~/brain`). Sul Mac mini:
```bash
python3 -m http.server 8080 --bind 0.0.0.0 --directory ~/jarvis-site
```
poi `http://<ip-del-mac-mini>:8080` dal telefono o dal computer. Non esporlo su internet: non ha
autenticazione. Per l'accesso da fuori casa usa una VPN (per esempio Tailscale).

Per averlo sempre attivo all'avvio, crea `~/.config/systemd/user/jarvis-site.service`:
```ini
[Unit]
Description=Jarvis site

[Service]
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory %h/jarvis-site
Restart=on-failure

[Install]
WantedBy=default.target
```
```bash
systemctl --user daemon-reload && systemctl --user enable --now jarvis-site
loginctl enable-linger "$USER"   # resta attivo anche senza sessione aperta
```

### Pubblicazione su uno spazio web (FTPS/SFTP)
Se non vuoi servire il sito dal Mac mini, Jarvis può caricarlo sul tuo hosting. In `~/.jarvis_env`:
```
JARVIS_FTP_URL=ftps://ftp.tuodominio.it/public_html/jarvis/
JARVIS_FTP_USER=...
JARVIS_FTP_PASSWORD=...
```
```bash
ruby jarvis.rb --publish   # genera il sito e lo carica
```
Con `JARVIS_FTP_URL` impostata, ogni `--digest` pubblica da solo alla fine (un errore di upload
non perde il digest). Usa `curl`: schemi `ftps://` (TLS implicito), `sftp://` oppure `ftp://`, che
pretende comunque TLS esplicito; l'FTP in chiaro si consente solo con `JARVIS_FTP_ALLOW_PLAIN=1`
(sconsigliato: la password viaggia in chiaro). Le credenziali passano a `curl` da stdin, non stanno
nell'URL né nella lista dei processi e vengono oscurate negli errori. `index.html` è caricato per ultimo.

Attenzione: lo spazio web è **pubblico**. Le pagine hanno `noindex` e c'è un `robots.txt`, ma non
sono una protezione: metti una password sulla cartella dal pannello dell'hosting (es. "Directory
Privacy" in cPanel o `.htaccess` con Basic auth) e non pubblicare nulla di riservato.

### Fonti e punteggio
Le fonti sono in `config/sources.yml`; ogni feed accetta queste opzioni:
`boost` (punti extra per le fonti primarie), `max_items` (tetto di voci di quella fonte in un digest),
`hours` (finestra di freschezza: 48 di default, più lunga per blog e newsletter che pubblicano di rado —
la memoria dei link visti evita i doppioni), `title_prefix`, `exclude_url` ed `exclude_title` (regex).
Le parole chiave contano come parola intera ("rag" non scatta su "storage"; "llm" vale anche per "LLMs")
e il loro contributo ha un tetto, così una voce piena di parole chiave non schiaccia le fonti primarie.
Il digest ha 10 voci (`JARVIS_DIGEST_ITEMS`).

Fonti valutate e scartate: il feed di OpenAI (quasi solo storie di clienti), Mistral (nessun feed),
il blog di Qwen (fermo da oltre un anno), arXiv (centinaia di articoli al giorno), TechCrunch e The Verge
(troppo rumore generalista) e le fonti in italiano (richiederebbero parole chiave in italiano).
Un feed che smette di funzionare viene saltato con un avviso: non ferma il digest.

### Categorie
Ogni fonte ha una `category` (in `config/sources.yml`): Ufficiali, Analisi e newsletter, Community
(Reddit, Hacker News, Lobsters), Ricerca e stampa, Progetti GitHub. Ogni categoria ha dei posti
garantiti (`slots`): così Reddit, che ha molte voci e un bonus di posizione, non occupa tutto il digest
e le fonti primarie, che pubblicano di rado, hanno sempre il loro spazio. I posti che una categoria
non riempie passano alle migliori voci rimaste. Il totale è la somma dei posti (13 di default;
`JARVIS_DIGEST_ITEMS` lo limita). Nel digest ogni voce ha la riga `Categoria:` e nel sito le voci sono
raggruppate in sezioni, con una barra per saltare dall'una all'altra e le card su più colonne sugli
schermi larghi. I digest vecchi, senza categorie, restano una lista unica.

## Installazione su una nuova macchina
```bash
git clone git@github.com:rex79/rex-jarvis.git && cd rex-jarvis
bin/setup            # requisiti, modelli Ollama adatti alla RAM, cartelle, ~/.jarvis_env, test
```
`bin/setup --no-pull` salta il download dei modelli. Un `~/.jarvis_env` esistente non viene mai
modificato: lo script indica le righe mancanti.

## Contesti: lavoro e personale
Jarvis ha due contesti separati, ognuno con le sue note, il suo modello e i suoi strumenti.

| | Lavoro | Personale |
|---|---|---|
| Note | `JARVIS_WORK_DIR` (default `~/jarvis-work`) | `JARVIS_BRAIN` (default `~/brain`, come il digest) |
| Modello | `JARVIS_WORK_MODEL`, **solo locale** | `JARVIS_MODEL` |
| Strumenti | note | note, musica (`JARVIS_MUSIC_APP`: Music o Spotify) |

- **Privacy del contesto di lavoro:** se `OLLAMA_URL` non punta a questo computer (`localhost`,
  `127.0.0.1`, `::1`), Jarvis si rifiuta di avviare il contesto di lavoro e di indicizzarne le note.
  Ogni contesto legge e scrive solo nella sua cartella e può usare solo i suoi strumenti.
- **Smistamento:** il prefisso `lavoro:` o `personale:` sceglie il contesto; altrimenti decidono le
  parole chiave (basta un segnale di lavoro per restare nel contesto di lavoro) e, se non bastano, un
  modello locale. Nel dubbio vince il lavoro, dove nulla esce dal computer.

```bash
ruby jarvis.rb                                   # chat, ogni messaggio va al contesto giusto
ruby jarvis.rb --ask "personale: metti la playlist Focus"
ruby jarvis.rb --ask "che riunioni ho segnato?" --context work
ruby jarvis.rb --index                           # indicizza le note di entrambi i contesti
```
La prima volta che Jarvis controlla un'app musicale, macOS chiede il permesso di automazione per il
Terminale: va concesso (una volta per Musica e una per Spotify).

Comandi rapidi: pausa, riprendi/continua, avanti e indietro sulla musica ("riprendi la musica",
"Jarvis, pausa", "prossima canzone", "ferma Spotify") sono riconosciuti con regole fisse, senza
modello: istantanei e sempre uguali. Un comando con parole di lavoro non è mai un comando rapido.
Le richieste più complesse (una playlist, un brano) passano all'agente.

Musica: l'app preferita è `JARVIS_MUSIC_APP` (Music o Spotify); nominandola nel comando ("metti
Spotify", "pausa su Apple Music") si usa quella. Solo "play" avvia un'app chiusa: pausa, avanti e
indietro non aprono nulla. Con Spotify: play, pausa, avanti e indietro; cercare una playlist o un
brano per nome richiede la Web API di Spotify (OAuth), non ancora supportata.

## Dashboard (HUD)
```bash
ruby jarvis.rb --hud            # poi apri http://localhost:7777
ruby jarvis.rb --hud --port 8080
```
Interfaccia in stile Jarvis: reattore animato (accelera mentre elabora), orologio, console comandi
(stesso smistamento lavoro/personale della CLI, tasto `/` per scrivere), sistema (carico, RAM,
batteria, disco), modelli Ollama in memoria, indicatore di privacy del contesto di lavoro, Spotify o
Musica (cosa suona e comandi) e i titoli dell'ultimo digest. Si adatta al telefono e rispetta
"riduci movimento".

Sicurezza: il server ascolta solo su `127.0.0.1` (non è raggiungibile dalla rete), accetta solo
Host `localhost`/`127.0.0.1` sulla sua porta (difesa dal DNS rebinding), le API richiedono un token
casuale generato a ogni avvio e le POST con un Origin diverso vengono rifiutate; Content Security
Policy senza script inline e testo dal server inserito sempre come testo, mai come HTML.
