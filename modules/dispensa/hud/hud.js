// Modulo dispensa: cosa c'è in congelatore, frigo e dispensa. I nomi arrivano dalla voce o dalla
// tastiera: sempre inseriti come testo. Un tocco su un alimento chiede conferma, il secondo lo toglie.
(() => {
  const { api, log, addView, onStatus, onLink, openLink, busy } = window.Jarvis;
  const view = addView({ id: 'dispensa', title: 'Dispensa' });

  // Riquadro interno per Cookidoo: il sito si apre sopra la dashboard, senza uscire dallo schermo
  // intero, e "Torna a Jarvis" lo chiude. Se dentro il riquadro il sito non riconosce l'accesso
  // (i browser limitano i cookie dei siti incorporati), "Apri in una scheda" lo apre normalmente.
  const viewer = document.createElement('div');
  viewer.className = 'webview';
  viewer.hidden = true;
  const bar = document.createElement('div');
  bar.className = 'webview-bar';
  const back = document.createElement('button');
  back.type = 'button';
  back.textContent = '← Torna a Jarvis';
  const viewerTitle = document.createElement('span');
  const outside = document.createElement('a');
  outside.target = '_blank';
  outside.rel = 'noopener';
  outside.textContent = 'Apri in una scheda';
  bar.append(back, viewerTitle, outside);
  viewer.append(bar);
  document.body.append(viewer);
  let frame = null;

  function closeViewer() {
    if (frame) frame.remove(); // il sito viene scaricato del tutto, non resta in sottofondo
    frame = null;
    viewer.hidden = true;
    busy(false);
  }

  function openViewer(link) {
    closeViewer();
    frame = document.createElement('iframe');
    frame.title = link.title || 'Cookidoo';
    frame.referrerPolicy = 'no-referrer';
    // Senza allow-top-navigation il sito non può sostituirsi alla dashboard.
    frame.setAttribute('sandbox', 'allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox');
    frame.src = link.url;
    viewerTitle.textContent = link.title || '';
    outside.href = link.url;
    viewer.append(frame);
    viewer.hidden = false;
    busy(true);
  }

  back.addEventListener('click', closeViewer);
  outside.addEventListener('click', closeViewer);
  onLink((link) => {
    if (!link.frame) return false;
    openViewer(link);
    return true;
  });

  // Ricerca a mano su Cookidoo, dallo stesso riquadro.
  let cookidoo = '';
  const search = document.createElement('form');
  search.className = 'cookidoo-search';
  search.autocomplete = 'off';
  search.hidden = true;
  const searchInput = document.createElement('input');
  searchInput.maxLength = 80;
  searchInput.placeholder = 'Cerca una ricetta su Cookidoo…';
  searchInput.setAttribute('aria-label', 'Cerca una ricetta su Cookidoo');
  const searchButton = document.createElement('button');
  searchButton.type = 'submit';
  searchButton.textContent = 'Cerca';
  search.append(searchInput, searchButton);
  search.addEventListener('submit', (event) => {
    event.preventDefault();
    const query = searchInput.value.trim();
    if (query && cookidoo) openLink({ title: `Cookidoo: ${query}`, url: `${cookidoo}?query=${encodeURIComponent(query)}`, frame: true });
  });
  view.panel.append(search);
  const lists = document.createElement('div');
  lists.className = 'dispensa';
  view.panel.append(lists);
  let armed = null;

  const days = (since) => {
    if (!since) return '';
    const n = Math.floor((Date.now() - new Date(since)) / 86400000);
    return n <= 0 ? 'oggi' : (n === 1 ? 'da ieri' : `da ${n} giorni`);
  };

  async function send(action, body) {
    try {
      render(await api(`/api/modules/dispensa/${action}`, body));
    } catch (e) {
      log('Dispensa', e.message, 'err');
    }
  }

  function render(data) {
    if (!data || data.error) {
      view.tile.textContent = 'Non disponibile';
      return;
    }
    cookidoo = /^https:\/\//.test(data.cookidoo || '') ? data.cookidoo : '';
    search.hidden = !cookidoo;
    view.tile.textContent = data.places.map((p) => `${p.label} ${p.items.length}`).join(' · ');
    lists.replaceChildren(...data.places.map((place) => {
      const box = document.createElement('div');
      const title = document.createElement('h3');
      title.textContent = `${place.label} · ${place.items.length}`;
      const ul = document.createElement('ul');
      ul.className = 'list';
      place.items.forEach((item) => {
        const li = document.createElement('li');
        const button = document.createElement('button');
        button.type = 'button';
        const name = document.createElement('span');
        name.textContent = item.name;
        const since = document.createElement('span');
        since.className = 'dim small';
        since.textContent = days(item.since);
        button.append(name, since);
        button.addEventListener('click', () => {
          if (armed !== button) {
            if (armed) armed.classList.remove('armed');
            armed = button;
            button.classList.add('armed');
            since.textContent = 'tocca ancora per togliere';
            setTimeout(() => { if (armed === button) { armed = null; button.classList.remove('armed'); since.textContent = days(item.since); } }, 4000);
            return;
          }
          armed = null;
          send('togli', { posto: place.id, nome: item.name });
        });
        li.append(button);
        ul.append(li);
      });
      if (!place.items.length) {
        const li = document.createElement('li');
        li.className = 'dim';
        li.textContent = 'Vuoto';
        ul.append(li);
      }
      const form = document.createElement('form');
      form.autocomplete = 'off';
      const input = document.createElement('input');
      input.maxLength = 200;
      input.placeholder = 'Aggiungi…';
      input.setAttribute('aria-label', `Aggiungi a ${place.label}`);
      const add = document.createElement('button');
      add.type = 'submit';
      add.textContent = '+';
      form.append(input, add);
      form.addEventListener('submit', (event) => {
        event.preventDefault();
        if (input.value.trim()) send('aggiungi', { posto: place.id, testo: input.value });
      });
      box.append(title, ul, form);
      return box;
    }));
  }

  let last = '';
  onStatus((s) => {
    const data = s.modules && s.modules.dispensa;
    const now = JSON.stringify(data);
    // Non ridisegnare se non è cambiato nulla: si perderebbe ciò che si sta scrivendo o la conferma in corso.
    if (now !== last && !lists.contains(document.activeElement) && !armed) {
      last = now;
      render(data);
    }
  });
})();
