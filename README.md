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

## Segnali crypto (Coinbase)
Jarvis calcola ogni giorno un segnale di trend sulle coppie di `config/signals.yml` (BTC-EUR ed ETH-EUR
di default) e ti dice se la regola è dentro o fuori. **Non manda ordini e non ha chiavi di Coinbase**:
l'ordine, se vuoi seguirlo, lo inserisci tu su Coinbase.

```bash
ruby jarvis.rb --signals    # scarica le candele, calcola segnale e backtest, scrive la nota
```
- **Dati:** candele giornaliere dall'API pubblica di Coinbase (nessuna chiave, nessun account, solo prezzi).
  La candela del giorno in corso non è chiusa e non viene usata.
- **Regola:** DENTRO quando la chiusura è sopra la media a 200 giorni e la media a 50 è sopra quella a 200,
  FUORI altrimenti. Niente modelli: lo stesso storico dà sempre lo stesso segnale. Periodi, ATR e
  commissione si cambiano in `config/signals.yml`.
- **Segnale:** ENTRA o ESCI il giorno in cui la regola cambia stato, altrimenti RESTA DENTRO o RESTA FUORI,
  con la data dell'ultimo cambio e uno stop indicativo (chiusura − 3 × ATR a 14 giorni).
- **Backtest:** negli ultimi 5 anni, confrontato con "compra e tieni", con rendimento, ribasso massimo,
  operazioni e tempo investito. Ogni segnale si esegue all'apertura del giorno dopo pagando la commissione
  a ogni acquisto e vendita; lo stop non è simulato.
- **Dove lo trovi:** `~/brain/signals/AAAA-MM-GG.md` (indicizzata, quindi `search_notes` la trova), un
  riquadro nella dashboard (da `~/brain/signals/latest.json`) e l'output del comando.

La candela giornaliera di Coinbase chiude alle 00:00 UTC; lancialo ogni mattina prima del digest con cron:
```
50 6 * * * cd ~/jarvis && ruby jarvis.rb --signals >> ~/jarvis-signals.log 2>&1
```
La dashboard legge i segnali della macchina su cui gira: sul Mac di lavoro basta lanciare lì lo stesso
comando (sono solo prezzi pubblici).

## Analisi titoli (TradingAgents)
Ogni mattina Jarvis fa analizzare i titoli di `config/trading.yml` da
[TradingAgents](https://github.com/TauricResearch/TradingAgents): più agenti AI (analisti di fondamentali,
notizie, sentiment e tecnica, ricercatori toro e orso, trader, gestione del rischio) discutono ogni titolo
e arrivano a una valutazione (ACQUISTA, AUMENTA, MANTIENI, RIDUCI, VENDI). **Non manda ordini e non ha
chiavi di broker**: è ricerca automatica, non un consiglio di investimento, e i modelli possono sbagliare.

Va sul Mac mini, nel contesto personale: al modello su OpenRouter arrivano solo ticker e dati di mercato
pubblici (Yahoo Finance, SEC EDGAR, FRED), mai note o dati di lavoro.

```bash
bin/setup-trading            # scarica TradingAgents in ~/.jarvis/TradingAgents e lo installa in .venv-trading
ruby jarvis.rb --trading     # analizza i titoli e scrive la nota
```
In `~/.jarvis_env` (la chiave `OPENROUTER_API_KEY` è quella del digest):
```
JARVIS_TRADING_MODEL=provider/modello        # economico e bravo con gli strumenti (tool calling)
JARVIS_TRADING_DEEP_MODEL=provider/modello   # opzionale: per i ruoli che decidono, default il precedente
JARVIS_TRADING_TICKERS=NVDA,ENEL.MI           # i tuoi titoli (ticker Yahoo Finance), vince su config/trading.yml
SEC_EDGAR_USER_AGENT="Nome Cognome email"   # opzionale, consigliato da TradingAgents per i dati SEC
```
- **Costi:** ogni titolo richiede decine di chiamate al modello; Jarvis accetta al massimo 5 titoli e un
  giro di discussione di default (`debate_rounds`). Controlla la spesa su openrouter.ai dopo i primi giorni.
- **Versione:** `JARVIS_TRADING_REF=v0.x.y bin/setup-trading` installa un tag preciso; lo script stampa il
  commit installato. Rilancialo per aggiornare.
- **Dove lo trovi:** `~/brain/trading/AAAA-MM-GG.md` (indicizzata), `~/brain/trading/latest.json` per il
  bot, e i report completi degli agenti in `~/.jarvis/trading`.

Dopo aver scritto la nota, `--trading` avvia l'indicizzazione delle note in background a bassa
priorità (`nice`, log in `~/.jarvis/index.log`): il risultato è subito disponibile anche se Ollama è lento.

### Lanciarla dalla dashboard
Nella dashboard del Mac di lavoro il riquadro **Analisi titoli** ha il pulsante **Aggiorna**: la
dashboard chiede al Mac mini di lanciare l'analisi via SSH e mostra il risultato appena la nota è scritta
(il Mac mini indicizza dopo, con calma). Usa una chiave SSH dedicata che sul Mac mini può eseguire **solo**
`jarvis.rb --trading-remote` (accetta i soli comandi `run` e `latest`): nessuna porta nuova, nessuna shell.

1. Sul Mac di lavoro crea la chiave (senza passphrase: la dashboard gira in background); `cat` ne mostra la parte pubblica:
   ```bash
   ssh-keygen -t ed25519 -N "" -C jarvis-trading -f ~/.ssh/jarvis_trading && cat ~/.ssh/jarvis_trading.pub
   ```
2. Sempre dal Mac di lavoro, aggiungi la chiave pubblica agli `authorized_keys` del Mac mini con il
   comando forzato (la riga la compone il Mac mini, con il suo percorso di Ruby):
   ```bash
   ssh rex@192.168.2.26 'read -r key; echo "command=\"cd $HOME/jarvis && $(command -v ruby) jarvis.rb --trading-remote\",from=\"192.168.2.0/24\",restrict $key" >> ~/.ssh/authorized_keys' < ~/.ssh/jarvis_trading.pub
   ssh rex@192.168.2.26 tail -1 ~/.ssh/authorized_keys   # command="cd /home/rex/jarvis && … --trading-remote",… ssh-ed25519 …
   ```
   La chiave privata (`~/.ssh/jarvis_trading`, senza `.pub`) non lascia mai il Mac di lavoro.
3. Sul Mac di lavoro, in `~/.jarvis_env`: `JARVIS_TRADING_SSH=rex@192.168.2.26`
   (`JARVIS_TRADING_SSH_KEY` se la chiave non è in `~/.ssh/jarvis_trading`), poi `bin/hud-service install`.
4. Prova: `ssh -i ~/.ssh/jarvis_trading rex@192.168.2.26 latest` risponde con l'ultima analisi in JSON;
   qualsiasi altro comando viene rifiutato. La prima volta conferma l'impronta del Mac mini con `yes`:
   la dashboard usa SSH in modalità non interattiva e senza questo passaggio non si collega.

All'avvio la dashboard copia l'ultima analisi del Mac mini (anche quella del cron) in `~/brain/trading`.

La borsa americana chiude alle 22 italiane; lancialo ogni mattina con cron:
```
30 6 * * 1-5 cd ~/jarvis && ruby jarvis.rb --trading >> ~/jarvis-trading.log 2>&1
```

### Bot Telegram di Jarvis
Un bot dedicato, separato da Hermes, che **legge soltanto** i report già pronti: non lancia analisi,
non chiama modelli e non esegue comandi. Risponde solo agli ID ammessi e solo in chat privata.

| Comando | Risposta |
|---|---|
| `/trading` | le valutazioni dell'ultima analisi |
| `/trading NVDA` | la decisione finale motivata per un titolo |
| `/segnali` | gli ultimi segnali crypto |

1. Su Telegram, con @BotFather: `/newbot`, poi `/setjoingroups` → Disable.
2. In `~/.jarvis_env`:
   ```
   JARVIS_TELEGRAM_TOKEN=...            # il token di @BotFather, mai in chat o nel repo
   JARVIS_TELEGRAM_ALLOWED_USERS=123456 # il tuo ID numerico (lo stesso dato a Hermes)
   ```
3. Prova con `ruby jarvis.rb --telegram`, poi rendilo un servizio in
   `~/.config/systemd/user/jarvis-telegram.service`:
   ```ini
   [Unit]
   Description=Jarvis Telegram bot
   After=network-online.target

   [Service]
   WorkingDirectory=%h/jarvis
   ExecStart=/usr/bin/env ruby jarvis.rb --telegram
   Restart=on-failure
   RestartSec=30

   [Install]
   WantedBy=default.target
   ```
   ```bash
   systemctl --user daemon-reload && systemctl --user enable --now jarvis-telegram
   journalctl --user -u jarvis-telegram -f   # log: un ID non ammesso compare qui
   ```
Il bot usa il long polling verso Telegram: nessuna porta da aprire sul Mac mini.

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

Digest nella dashboard: il sito pubblicato dal Mac mini contiene anche `digest.json` (ultimo digest
con titoli, fonti, categorie, link e riassunti). Sul Mac di lavoro, in `~/.jarvis_env`:
```
JARVIS_DIGEST_URL=https://tuodominio.it/jarvis/
# solo se la cartella è protetta da password (Basic auth, accettata solo su https):
JARVIS_DIGEST_USER=...
JARVIS_DIGEST_PASSWORD=...
```
La dashboard lo scarica al massimo ogni 15 minuti e, se il sito non risponde, mostra l'ultima copia con
un avviso. Senza `JARVIS_DIGEST_URL` usa i digest locali in `~/brain/digest`. Il contenuto arriva da
internet: viene validato (solo link http(s), lunghezze limitate) e inserito solo come testo.

Sicurezza: il server ascolta solo su `127.0.0.1` (non è raggiungibile dalla rete), accetta solo
Host `localhost`/`127.0.0.1` sulla sua porta (difesa dal DNS rebinding), le API richiedono un token
casuale generato a ogni avvio e le POST con un Origin diverso vengono rifiutate; Content Security
Policy senza script inline e testo dal server inserito sempre come testo, mai come HTML.

### Dashboard sempre attiva (macOS)
```bash
bin/hud-service install     # parte al login e si riavvia se si ferma (porta: JARVIS_HUD_PORT, default 7777)
bin/hud-service status      # stato del servizio e della dashboard
bin/hud-service logs        # ultime righe di ~/Library/Logs/jarvis-hud.log
bin/hud-service open        # apre la dashboard
bin/hud-service uninstall   # ferma e rimuove
```
Usa un LaunchAgent (`~/Library/LaunchAgents/com.jarvis.hud.plist`). Dopo un `git pull` che cambia il
codice Ruby, rilancia `bin/hud-service install` per riavviarlo con la versione nuova (HTML, CSS e JS
della dashboard invece si aggiornano subito). Ollama deve essere attivo: l'app di Ollama parte al login.

## Agente Copilot Studio (contesto di lavoro)
Jarvis inoltra le richieste di lavoro all'agente aziendale Copilot Studio con il client ufficiale
Microsoft (`microsoft-agents-copilotstudio-client`), in un ambiente Python isolato in `.venv`.

```bash
bin/setup-copilot                 # installa il client in .venv (escluso da git)
ruby jarvis.rb --copilot-login    # accesso Microsoft nel browser (una volta; MFA compresa)
ruby jarvis.rb --copilot-status
ruby jarvis.rb --ask "Jarvis, dammi il daily briefing"
```
In `~/.jarvis_env`: `JARVIS_COPILOT_TENANT_ID`, `JARVIS_COPILOT_CLIENT_ID` (registrazione app Entra ID,
client pubblico, permesso delegato Power Platform `CopilotStudio.Copilots.Invoke`),
`JARVIS_COPILOT_ENVIRONMENT_ID` e `JARVIS_COPILOT_AGENT` (schema name dell'agente).

- Le frasi con "copilot", "briefing" o "agente" nel contesto di lavoro vanno **direttamente** all'agente,
  senza passare dal modello locale; le parole rivolte a Jarvis ("Jarvis, chiedi a Copilot…") vengono
  tolte. Nella stessa sessione la conversazione con l'agente prosegue.
- Conversazione agganciata: dopo una risposta dell'agente, i messaggi di lavoro successivi ("inseriscile
  nei to-do") vanno a lui nella stessa conversazione per 15 minuti dall'ultimo scambio, anche senza
  la parola "copilot". La chiudono "Jarvis, nuova conversazione", 15 minuti di silenzio, un messaggio
  personale o un comando musicale. La dashboard mostra "Copilot · conversazione aperta". Anche lo
  strumento `ask_copilot` dell'agente locale continua la stessa conversazione.
- Ogni risposta viene salvata anche in `JARVIS_WORK_DIR/copilot/` (ricercabile con `search_notes`).
- L'agente è anche lo strumento `ask_copilot`, disponibile **solo** nel contesto di lavoro.
- Privacy: è l'unica eccezione al "solo locale" del contesto di lavoro, e porta i dati solo al tenant
  Microsoft dell'azienda: il ponte rifiuta endpoint che non siano `*.api.powerplatform.com`. Il token
  resta nel Portachiavi di macOS (`msal-extensions`), mai in chiaro su disco.
- L'agente usa i suoi strumenti (salvataggi, Jira, posta…) come quando lo usi da Teams: una richiesta
  come "salvamelo" fa davvero salvare.
