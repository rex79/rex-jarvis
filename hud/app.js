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
  if (paired) renderHome(s);
  statusListeners.forEach((listener) => listener(s));
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

// Manda un comando a Jarvis e mostra la risposta nel registro. Restituisce la risposta, o null se fallisce.
async function ask(text) {
  log('Tu', text);
  setState('thinking', 'ELABORAZIONE');
  try {
    const reply = await api('/api/ask', { text });
    log(`Jarvis · ${reply.label}`, reply.text, reply.label.startsWith('lavoro') ? 'work' : '');
    setCopilot(reply.copilot_active);
    setState('idle', 'IN ASCOLTO');
    return reply;
  } catch (e) {
    log('Errore', e.message, 'err');
    setState('error', 'ERRORE');
    setTimeout(() => { if (document.body.dataset.state === 'error') setState('idle', 'IN ASCOLTO'); }, 2500);
    return null;
  } finally {
    refresh();
  }
}

$('console').addEventListener('submit', async (event) => {
  event.preventDefault();
  const input = $('command');
  const text = input.value.trim();
  if (!text) return;
  input.value = '';
  input.disabled = true;
  await ask(text);
  input.disabled = false;
  if (!paired) input.focus(); // sul tablet riaprirebbe la tastiera
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

document.addEventListener('keydown', (event) => {
  if (event.key === '/' && document.activeElement !== $('command') && !document.querySelector('dialog[open]')) {
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
    && !['thinking', 'listening', 'speaking'].includes(document.body.dataset.state);
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

function renderHome(s) {
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

// Quello che un modulo (modules/<nome>/hud/hud.js) può usare della dashboard, senza toccare questo file.
const statusListeners = [];
window.Jarvis = {
  $, api, ask, log, setState, refresh, paired,
  token: () => token,
  touch() { lastTouch = Date.now(); },
  onStatus(listener) { statusListeners.push(listener); },
  // Aggiunge una sezione: riquadro, scheda del tablet e riquadro nella schermata Casa.
  // Restituisce { panel, tile } dove tile è il paragrafo di riepilogo nella Casa.
  addView({ id, title, tab }) {
    const panel = document.createElement('section');
    panel.className = 'panel';
    panel.dataset.view = id;
    const heading = document.createElement('h2');
    heading.textContent = title;
    panel.append(heading);
    document.querySelector('.layout > aside.col:last-of-type').prepend(panel);

    const tabButton = document.createElement('button');
    tabButton.type = 'button';
    tabButton.dataset.go = id;
    tabButton.textContent = tab || title;
    $('tabs').append(tabButton);

    const tileButton = document.createElement('button');
    tileButton.type = 'button';
    tileButton.className = 'tile';
    tileButton.dataset.go = id;
    const tileTitle = document.createElement('h2');
    tileTitle.textContent = title;
    const tile = document.createElement('p');
    tileButton.append(tileTitle, tile);
    $('home').insertBefore(tileButton, $('home').querySelector('.tile.wide'));

    if (paired) [tabButton, tileButton].forEach((el) => el.addEventListener('click', () => setView(id)));
    return { panel, tile };
  },
};

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
