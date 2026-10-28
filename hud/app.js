// Dashboard di Jarvis. Tutto il testo che arriva dal server (titoli del digest, risposte)
// viene inserito come testo, mai come HTML. Ogni chiamata alle API porta il token della pagina.
const token = document.querySelector('meta[name="jarvis-token"]').content;
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
  if (!res.ok) throw new Error(data.error || `errore ${res.status}`);
  return data;
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
}

function render(s) {
  setText('host', s.host ? `· ${s.host}` : '');

  const badge = $('privacy-badge');
  badge.className = 'badge ' + (s.privacy.local ? 'ok' : 'ko');
  badge.textContent = s.privacy.local ? 'LAVORO · SOLO LOCALE' : 'ATTENZIONE · OLLAMA NON LOCALE';

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
  try {
    render(await api('/api/status'));
  } catch (e) {
    setState('error', 'OFFLINE');
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

document.addEventListener('keydown', (event) => {
  if (event.key === '/' && document.activeElement !== $('command')) {
    event.preventDefault();
    $('command').focus();
  }
});

tick();
setInterval(tick, 1000);
refresh();
setInterval(refresh, 5000);
$('command').focus();
