// Dashboard di Jarvis. Tutto il testo che arriva dal server (titoli del digest, risposte)
// viene inserito come testo, mai come HTML. Ogni chiamata alle API porta il token della pagina.
// Sulla rete di casa la pagina non contiene il token: il dispositivo lo ottiene abbinandosi e lo tiene qui.
const pageToken = document.querySelector('meta[name="jarvis-token"]').content;
const paired = !pageToken;
const STORE = 'jarvis-device-token';
const stored = {
  get() { try { return localStorage.getItem(STORE) || ''; } catch { return ''; } },
  set(value) { try { value ? localStorage.setItem(STORE, value) : localStorage.removeItem(STORE); } catch { /* resta in memoria */ } },
};
let token = pageToken || stored.get();
const $ = (id) => document.getElementById(id);

async function api(path, body) {
  const options = { headers: { 'X-Jarvis-Token': token } };
  if (body) {
    options.method = 'POST';
    options.headers['Content-Type'] = 'application/json';
    options.body = JSON.stringify(body);
  }
  const res = await fetch(path, options);
  const data = await res.json().catch(() => ({}));
  if (res.status === 403 && paired) showPairing(); // abbinamento revocato
  if (!res.ok) throw new Error(data.error || `errore ${res.status}`);
  return data;
}

function showPairing() {
  token = '';
  stored.set('');
  if (!$('pair-dialog').open) $('pair-dialog').showModal();
}

function setCopilot(active) { $('copilot-badge').hidden = !active; }

function setText(id, value) { $(id).textContent = value ?? '–'; }

function setState(state, label) {
  document.body.dataset.state = state;
  $('state-label').textContent = label;
}

function tick() {
  const now = new Date();
  setText('time', now.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', second: '2-digit' }));
  setText('date', now.toLocaleDateString('it-IT', { weekday: 'long', day: 'numeric', month: 'long' }));
  if (paired) {
    setText('rest-time', now.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' }));
    setText('rest-date', $('date').textContent);
    if (now.getSeconds() === 0) shiftRest(); // lo schermo resta acceso: niente immagini sempre ferme
    if (Date.now() - lastTouch > IDLE_MS && canRest()) rest();
  }
}

function render(s) {
  setText('host', s.host ? `· ${s.host}` : '');

  const badge = $('privacy-badge');
  badge.className = 'badge ' + (s.privacy.local ? 'ok' : 'ko');
  const personal = s.mode === 'personal';
  badge.textContent = personal ? 'PERSONALE' : (s.privacy.local ? 'LAVORO · SOLO LOCALE' : 'ATTENZIONE · OLLAMA NON LOCALE');
  if (personal) badge.className = 'badge ok';
  $('audio-panel').hidden = personal;
  $('work-model').parentElement.hidden = personal;

  setCopilot(s.copilot_active);

  const sys = s.system || {};
  if (sys.error) {
    setText('load', 'n/d');
  } else {
    setText('load', sys.load_percent != null ? `${sys.load_percent}%` : sys.load);
    $('load-bar').style.width = `${sys.load_percent || 0}%`;
    setText('ram', sys.ram_gb ? `${sys.ram_gb} GB` : null);
    setText('battery', sys.battery != null ? `${sys.battery}%` : 'rete');
    setText('disk', sys.disk_free_gb != null ? `${sys.disk_free_gb} GB` : null);
  }

  const ol = s.ollama || {};
  setText('ollama', ol.online ? 'ONLINE' : 'NON RAGGIUNGIBILE');
  setText('work-model', s.privacy.work_model);
  setText('personal-model', s.privacy.personal_model);
  const loaded = $('loaded');
  loaded.replaceChildren(...(ol.models || []).map((m) => {
    const li = document.createElement('li');
    li.textContent = `◉ in memoria: ${m.name} · ${m.gb} GB`;
    return li;
  }));

  const mu = s.music || {};
  setText('track', mu.error ? 'Audio non disponibile' : (mu.track || 'Nessun brano'));
  setText('artist', mu.artist || '');
  setText('music-state', mu.error ? mu.error : `${mu.app || ''} · ${mu.state || ''}`);

  renderDigest(s.digest || {});
  renderSignals(s.signals);
  renderTrading(s.trading, s.trading_job || {});
  if (paired) renderHome(s);
}

const dayLabel = (iso) => new Date(iso).toLocaleDateString('it-IT', { day: 'numeric', month: 'short' });
const clock = (seconds) => `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
const DECISION_CLASS = { ACQUISTA: 'up', AUMENTA: 'up', MANTIENI: 'hold', RIDUCI: 'down', VENDI: 'down' };
let tradingTimer = null;

function renderTrading(tr, job) {
  setText('trading-date', tr && tr.date ? `· ${dayLabel(tr.date)}` : '');
  const button = $('trading-run');
  button.disabled = !!job.running || !job.configured;
  button.title = job.configured ? 'Lancia TradingAgents sul Mac mini' : 'Imposta JARVIS_TRADING_SSH e la chiave SSH';

  clearInterval(tradingTimer);
  const state = $('trading-state');
  state.className = 'small' + (job.error ? ' err' : '');
  if (job.running) {
    const started = new Date(job.started_at);
    const update = () => { state.textContent = `In corso sul Mac mini · ${clock(Math.max(0, Math.round((Date.now() - started) / 1000)))}`; };
    update();
    tradingTimer = setInterval(update, 1000);
  } else if (job.error) {
    state.textContent = `Errore: ${job.error}`;
  } else if (job.finished_at) {
    state.textContent = `Aggiornata alle ${new Date(job.finished_at).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })}`;
  } else {
    state.textContent = job.configured ? 'Pronta' : 'Mac mini non configurato';
  }

  const list = $('trading');
  const items = (tr && tr.tickers) || [];
  if (!items.length) {
    const li = document.createElement('li');
    li.className = 'dim';
    li.textContent = tr && tr.error ? 'Analisi non disponibile.' : 'Nessuna analisi: premi Aggiorna.';
    list.replaceChildren(li);
    return;
  }
  list.replaceChildren(...items.map((it) => {
    const li = document.createElement('li');
    const head = document.createElement('div');
    head.className = 'metric';
    const name = document.createElement('span');
    name.textContent = it.ticker;
    const action = document.createElement('b');
    action.className = `action ${it.error ? 'down' : (DECISION_CLASS[it.decision] || 'hold')}`;
    action.textContent = it.error ? 'N/D' : it.decision;
    head.append(name, action);
    li.append(head);
    const text = it.error || (it.summary || '').replace(/\*\*/g, ''); // grassetti Markdown come testo semplice
    if (text) {
      const p = document.createElement('p');
      p.className = 'summary';
      p.textContent = text;
      p.title = 'Clic per espandere';
      p.addEventListener('click', () => p.classList.toggle('open'));
      li.append(p);
    }
    return li;
  }));
}

const euro = (v) => (v == null ? '–' : v.toLocaleString('it-IT', { maximumFractionDigits: 2 }));

function renderSignals(sg) {
  const list = $('signals');
  const items = (sg && sg.signals) || [];
  const first = items.find((it) => it.date);
  setText('signals-date', first ? `· ${new Date(first.date).toLocaleDateString('it-IT', { day: 'numeric', month: 'short' })}` : '');
  if (!items.length) {
    const li = document.createElement('li');
    li.className = 'dim';
    li.textContent = sg && sg.error ? 'Segnali non disponibili.' : 'Nessun segnale: ruby jarvis.rb --signals';
    list.replaceChildren(li);
    return;
  }
  list.replaceChildren(...items.map((it) => {
    const li = document.createElement('li');
    const head = document.createElement('div');
    head.className = 'metric';
    const name = document.createElement('span');
    name.textContent = it.product;
    const action = document.createElement('b');
    action.className = `action ${it.action || 'error'}`;
    action.textContent = it.error ? 'N/D' : it.label;
    head.append(name, action);
    const detail = document.createElement('div');
    detail.className = 'dim small';
    detail.textContent = it.error
      ? it.error
      : [`chiusura ${euro(it.close)}`, it.stop != null ? `stop ${euro(it.stop)}` : null,
         it.since ? `dal ${new Date(it.since).toLocaleDateString('it-IT', { day: 'numeric', month: 'short', year: 'numeric' })}` : null]
          .filter(Boolean).join(' · ');
    li.append(head, detail);
    return li;
  }));
}

function renderDigest(dg) {
  const origin = dg.origin === 'remoto' ? ' · dal Mac mini' : '';
  setText('digest-date', dg.date ? `· ${dg.date}${origin}` : '');
  const note = $('digest-note');
  note.hidden = !(dg.stale || (dg.error && !(dg.items || []).length));
  note.textContent = dg.stale ? `Sito non raggiungibile, mostro l'ultima copia (${dg.error || ''})` : (dg.error || '');

  const list = $('digest');
  const items = dg.items || [];
  if (!items.length) {
    const li = document.createElement('li');
    li.className = 'dim';
    li.textContent = dg.error ? 'Digest non disponibile.' : 'Nessun digest: imposta JARVIS_DIGEST_URL.';
    list.replaceChildren(li);
    return;
  }
  list.replaceChildren(...items.map((it) => {
    const li = document.createElement('li');
    if (it.low) li.className = 'low';
    const meta = document.createElement('span');
    meta.className = 'meta';
    meta.textContent = [it.category, it.source].filter(Boolean).join(' · ');
    const a = document.createElement(it.url ? 'a' : 'span');
    a.className = 'title';
    if (it.url && /^https?:\/\//.test(it.url)) {
      a.href = it.url;
      a.target = '_blank';
      a.rel = 'noopener noreferrer';
    }
    a.textContent = it.title;
    li.append(meta, a);
    if (it.summary) {
      const p = document.createElement('p');
      p.className = 'summary';
      p.textContent = it.summary;
      p.title = 'Clic per espandere';
      p.addEventListener('click', () => p.classList.toggle('open'));
      li.append(p);
    }
    return li;
  }));
}

async function refresh() {
  if (!token) return;
  try {
    render(await api('/api/status'));
    if (paired) { $('rest-status').hidden = true; $('home-system').classList.remove('err'); }
  } catch (e) {
    setState('error', 'OFFLINE');
    if (paired && token) {
      setText('rest-status', 'Mac mini non raggiungibile');
      $('rest-status').hidden = false;
      setText('home-system', 'Mac mini non raggiungibile');
      $('home-system').classList.add('err');
    }
  }
}

function log(label, text, kind) {
  const li = document.createElement('li');
  if (kind) li.className = kind;
  const who = document.createElement('span');
  who.className = 'who';
  const tag = document.createElement('span');
  tag.className = 'tag';
  tag.textContent = label;
  who.append(tag);
  const body = document.createElement('div');
  body.className = 'text';
  body.textContent = text;
  li.append(who, body);
  $('log').prepend(li);
  while ($('log').children.length > 12) $('log').lastChild.remove();
}

$('console').addEventListener('submit', async (event) => {
  event.preventDefault();
  const input = $('command');
  const text = input.value.trim();
  if (!text) return;
  input.value = '';
  log('Tu', text);
  setState('thinking', 'ELABORAZIONE');
  input.disabled = true;
  try {
    const reply = await api('/api/ask', { text });
    log(`Jarvis · ${reply.label}`, reply.text, reply.label.startsWith('lavoro') ? 'work' : '');
    setCopilot(reply.copilot_active);
    setState('idle', 'IN ASCOLTO');
  } catch (e) {
    log('Errore', e.message, 'err');
    setState('error', 'ERRORE');
    setTimeout(() => setState('idle', 'IN ASCOLTO'), 2500);
  } finally {
    input.disabled = false;
    input.focus();
    refresh();
  }
});

document.querySelectorAll('[data-music]').forEach((button) => {
  button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      await api('/api/music', { action: button.dataset.music });
    } catch (e) {
      log('Audio', e.message, 'err');
    } finally {
      button.disabled = false;
      refresh();
    }
  });
});

// Sul tablet il pulsante è a portata di tutti e ogni analisi costa credito: serve un secondo tocco.
let tradingArmed = null;

$('trading-run').addEventListener('click', async () => {
  const button = $('trading-run');
  if (paired && !tradingArmed) {
    button.textContent = 'Conferma?';
    tradingArmed = setTimeout(() => { tradingArmed = null; button.textContent = 'Aggiorna'; }, 4000);
    return;
  }
  clearTimeout(tradingArmed);
  tradingArmed = null;
  button.textContent = 'Aggiorna';
  $('trading-run').disabled = true;
  try {
    await api('/api/trading', {});
    log('Analisi titoli', 'Avviata sul Mac mini: il riquadro si aggiorna quando ha finito.');
  } catch (e) {
    log('Analisi titoli', e.message, 'err');
  } finally {
    refresh();
  }
});

// Nota completa dell'ultima analisi: Markdown minimo reso con elementi e textContent, mai come HTML.
function renderNote(text) {
  const blocks = [];
  let list = null;
  text.split('\n').forEach((raw) => {
    const line = raw.replace(/\*\*/g, '').trimEnd();
    const heading = line.match(/^(#{1,3})\s+(.*)$/);
    if (!line.trim()) { list = null; return; }
    let el;
    if (heading) {
      el = document.createElement(`h${heading[1].length + 2}`);
      el.textContent = heading[2];
      list = null;
    } else if (/^\s*[-*]\s+/.test(line)) {
      if (!list) { list = document.createElement('ul'); blocks.push(list); }
      const li = document.createElement('li');
      li.textContent = line.replace(/^\s*[-*]\s+/, '');
      list.append(li);
      return;
    } else {
      el = document.createElement(line.startsWith('>') ? 'blockquote' : 'p');
      el.textContent = line.replace(/^>\s?/, '');
      list = null;
    }
    blocks.push(el);
  });
  return blocks;
}

$('trading-read').addEventListener('click', async () => {
  try {
    const note = await api('/api/trading/note');
    const body = $('trading-note');
    if (note.text) {
      body.replaceChildren(...renderNote(note.text));
    } else {
      const p = document.createElement('p');
      p.textContent = 'Nessuna analisi ancora: premi Aggiorna.';
      body.replaceChildren(p);
    }
    $('trading-dialog').showModal();
    body.scrollTop = 0;
  } catch (e) {
    log('Analisi titoli', e.message, 'err');
  }
});
$('trading-close').addEventListener('click', () => $('trading-dialog').close());
$('trading-dialog').addEventListener('click', (event) => {
  if (event.target === $('trading-dialog')) $('trading-dialog').close(); // clic fuori dal riquadro
});

document.addEventListener('keydown', (event) => {
  if (event.key === '/' && document.activeElement !== $('command') && !$('trading-dialog').open) {
    event.preventDefault();
    $('command').focus();
  }
});

// Tablet: una sezione alla volta, e schermata a riposo se nessuno lo tocca.
const IDLE_MS = 3 * 60 * 1000;
let lastTouch = Date.now();

function setView(view) {
  document.querySelectorAll('[data-view]').forEach((el) => el.classList.toggle('active', el.dataset.view === view));
  document.querySelectorAll('#tabs [data-go]').forEach((el) => {
    if (el.dataset.go === view) el.setAttribute('aria-current', 'page'); else el.removeAttribute('aria-current');
  });
  document.querySelector('.layout').scrollTop = 0;
}

function canRest() {
  return $('rest').hidden && !document.querySelector('dialog[open]') && !$('command').value
    && document.body.dataset.state !== 'thinking';
}

function rest() {
  setView('casa');
  shiftRest();
  $('rest').hidden = false;
  document.body.classList.add('resting');
  if (document.activeElement) document.activeElement.blur();
}

function shiftRest() {
  const offset = () => Math.round(Math.random() * 60 - 30);
  $('rest-body').style.transform = `translate(${offset()}px, ${offset()}px)`;
}

function tileList(id, rows, empty) {
  const items = rows.slice(0, 5).map(([name, value, kind]) => {
    const li = document.createElement('li');
    const label = document.createElement('span');
    label.textContent = name;
    const b = document.createElement('b');
    b.className = `action ${kind || ''}`;
    b.textContent = value;
    li.append(label, b);
    return li;
  });
  if (!items.length) {
    const li = document.createElement('li');
    li.className = 'dim';
    li.textContent = empty;
    items.push(li);
  }
  $(id).replaceChildren(...items);
}

function renderHome(s) {
  const rows = ((s.trading && s.trading.tickers) || []).map((it) => (it.error
    ? [it.ticker, 'N/D', 'down'] : [it.ticker, it.decision, DECISION_CLASS[it.decision] || 'hold']));
  const job = s.trading_job || {};
  const empty = job.running ? 'Analisi in corso…' : 'Nessuna analisi';
  tileList('home-trading', rows, empty);
  tileList('rest-trading', rows, empty);
  tileList('home-signals', ((s.signals && s.signals.signals) || []).map((it) => (it.error
    ? [it.product, 'N/D', 'error'] : [it.product, it.label, it.action])), 'Nessun segnale');
  const items = (s.digest && s.digest.items) || [];
  setText('home-digest', items.length ? `${s.digest.date || ''} · ${items.length === 1 ? '1 notizia' : `${items.length} notizie`}\n${items[0].title}` : 'Nessun digest');
  const sys = s.system || {};
  setText('home-system', [`Carico ${sys.load_percent ?? '–'}%`, `Disco ${sys.disk_free_gb ?? '–'} GB`,
    `Ollama ${(s.ollama || {}).online ? 'online' : 'non raggiungibile'}`].join(' · '));
}

if (paired) {
  document.body.dataset.mode = 'personal';
  $('home').hidden = false;
  $('tabs').hidden = false;
  setView('casa');
  document.querySelectorAll('[data-go]').forEach((el) => el.addEventListener('click', () => setView(el.dataset.go)));
  ['pointerdown', 'keydown'].forEach((type) => document.addEventListener(type, () => { lastTouch = Date.now(); }));
  $('rest').addEventListener('click', () => {
    $('rest').hidden = true;
    document.body.classList.remove('resting');
  });
}

$('pair-dialog').addEventListener('cancel', (event) => event.preventDefault()); // senza abbinamento non c'è altro da fare
$('pair-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const error = $('pair-error');
  error.hidden = true;
  try {
    const res = await fetch('/api/pair', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: $('pair-code').value }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `errore ${res.status}`);
    token = data.token;
    stored.set(token);
    $('pair-code').value = '';
    $('pair-dialog').close();
    refresh();
  } catch (e) {
    error.textContent = e.message;
    error.hidden = false;
  }
});

tick();
setInterval(tick, 1000);
refresh();
setInterval(refresh, 5000);
if (paired) {
  if (!token) showPairing();
  $('command').placeholder = 'Dimmi cosa fare…';
} else {
  $('command').focus(); // non sul tablet: aprirebbe la tastiera a ogni caricamento
}
