// Modulo dispensa: cosa c'è in congelatore, frigo e dispensa. I nomi arrivano dalla voce o dalla
// tastiera: sempre inseriti come testo. Un tocco su un alimento chiede conferma, il secondo lo toglie.
(() => {
  const { api, log, addView, onStatus } = window.Jarvis;
  const view = addView({ id: 'dispensa', title: 'Dispensa' });
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
