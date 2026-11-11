// Modulo voce: un tasto accende la modalità vocale. Jarvis ascolta una frase (finisce da sola dopo
// una pausa), il Mac mini la trascrive, la risposta viene mostrata e letta ad alta voce, poi torna
// ad ascoltare. Si spegne con lo stesso tasto, dicendo "basta" o dopo un po' di silenzio.
// Il microfono funziona solo su pagine sicure: sul tablet la dashboard va aperta in https.
(() => {
  const { ask, log, setState, token, touch } = window.Jarvis;
  const SILENCE_MS = 1300; // pausa che chiude la frase
  const WAIT_MS = 15000; // nessuno parla: la modalità si spegne
  const MAX_MS = 30000; // durata massima di una frase
  const STOP_WORDS = /^(basta|basta così|stop|fine|chiudi|grazie|grazie jarvis|ok grazie)$/;

  const button = document.createElement('button');
  button.type = 'button';
  button.id = 'voice-toggle';
  button.className = 'voice-toggle';
  button.textContent = 'Voce';
  button.setAttribute('aria-pressed', 'false');
  document.body.append(button);

  let on = false;
  let stream = null;
  let context = null;
  let analyser = null;
  let recorder = null;
  let timer = null;

  function label(state, text) {
    button.dataset.state = state;
    button.textContent = text;
    if (state === 'listening') setState('listening', 'TI ASCOLTO');
    else if (state === 'speaking') setState('speaking', 'RISPONDO');
    else if (state === 'off') setState('idle', 'IN ASCOLTO');
  }

  function level(buffer) {
    analyser.getFloatTimeDomainData(buffer);
    let sum = 0;
    for (let i = 0; i < buffer.length; i += 1) sum += buffer[i] * buffer[i];
    return Math.sqrt(sum / buffer.length);
  }

  // Registra una frase: parte subito, finisce dopo una pausa. Restituisce l'audio, oppure null se
  // nessuno ha parlato (o la modalità è stata spenta).
  function listen() {
    return new Promise((resolve) => {
      const type = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4'].find((t) => MediaRecorder.isTypeSupported(t)) || '';
      const chunks = [];
      const buffer = new Float32Array(analyser.fftSize);
      const started = Date.now();
      let floor = 0;
      let samples = 0;
      let loud = 0;
      let spoke = false;
      let lastLoud = 0;

      const current = new MediaRecorder(stream, type ? { mimeType: type } : undefined);
      recorder = current;
      current.addEventListener('dataavailable', (event) => { if (event.data.size) chunks.push(event.data); });
      current.addEventListener('stop', () => {
        clearInterval(timer);
        resolve(spoke && on ? new Blob(chunks, { type: current.mimeType || type }) : null);
      });
      current.start();
      label('listening', 'Ti ascolto…');

      timer = setInterval(() => {
        const now = Date.now();
        const value = level(buffer);
        if (now - started < 300) { // rumore di fondo della stanza
          samples += 1;
          floor += (value - floor) / samples;
          return;
        }
        const threshold = Math.max(0.012, Math.min(floor, 0.03) * 2.5);
        if (value > threshold) {
          loud += 1;
          if (loud >= 3) { spoke = true; lastLoud = now; }
        } else {
          loud = 0;
        }
        const done = (spoke && now - lastLoud > SILENCE_MS) || (!spoke && now - started > WAIT_MS) || now - started > MAX_MS;
        if (done && current.state !== 'inactive') current.stop();
      }, 50);
    });
  }

  async function transcribe(audio) {
    const res = await fetch('/api/modules/voce/trascrivi', {
      method: 'POST',
      headers: { 'X-Jarvis-Token': token(), 'Content-Type': audio.type || 'audio/webm' },
      body: audio,
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `errore ${res.status}`);
    return (data.text || '').trim();
  }

  // Legge la risposta con la voce del tablet. Alcuni browser non avvisano quando hanno finito:
  // un tempo massimo proporzionale al testo evita di restare bloccati.
  function speak(text) {
    return new Promise((resolve) => {
      if (!('speechSynthesis' in window) || !text) { resolve(); return; }
      const clean = text.replace(/[*_#`>|]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 1500);
      const utterance = new SpeechSynthesisUtterance(clean);
      utterance.lang = 'it-IT';
      const voice = speechSynthesis.getVoices().find((v) => v.lang && v.lang.toLowerCase().startsWith('it'));
      if (voice) utterance.voice = voice;
      const finish = () => { clearTimeout(limit); resolve(); };
      const limit = setTimeout(finish, 4000 + clean.length * 90);
      utterance.addEventListener('end', finish);
      utterance.addEventListener('error', finish);
      speechSynthesis.cancel();
      speechSynthesis.speak(utterance);
    });
  }

  function release() {
    clearInterval(timer);
    if (recorder && recorder.state !== 'inactive') recorder.stop();
    if (stream) stream.getTracks().forEach((track) => track.stop());
    if (context) context.close();
    if ('speechSynthesis' in window) speechSynthesis.cancel();
    stream = null;
    context = null;
    analyser = null;
    recorder = null;
  }

  function turnOff(message) {
    on = false;
    release();
    button.setAttribute('aria-pressed', 'false');
    label('off', 'Voce');
    if (message) log('Voce', message);
  }

  async function turnOn() {
    if (!navigator.mediaDevices || !window.MediaRecorder) {
      log('Voce', 'Il microfono non è disponibile: apri la dashboard in https (JARVIS_HUD_TLS=1) e accetta il certificato del Mac mini.', 'err');
      return;
    }
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
    } catch (e) {
      log('Voce', `Microfono non concesso: ${e.message}`, 'err');
      return;
    }
    context = new (window.AudioContext || window.webkitAudioContext)();
    analyser = context.createAnalyser();
    analyser.fftSize = 2048;
    context.createMediaStreamSource(stream).connect(analyser);
    if ('speechSynthesis' in window) speechSynthesis.speak(new SpeechSynthesisUtterance('')); // sblocca la voce con questo tocco
    on = true;
    button.setAttribute('aria-pressed', 'true');

    while (on) {
      touch(); // finché si parla, niente schermata a riposo
      const audio = await listen();
      if (!on) break;
      if (!audio) { turnOff('Nessuno parla: modalità vocale spenta.'); break; }

      label('thinking', 'Un attimo…');
      setState('thinking', 'TRASCRIVO');
      let text = '';
      try {
        text = await transcribe(audio);
      } catch (e) {
        log('Voce', e.message, 'err');
        turnOff();
        break;
      }
      if (!on) break;
      if (!text) continue; // solo rumore: si torna ad ascoltare
      if (STOP_WORDS.test(text.toLowerCase().replace(/[^\p{L}\s]/gu, '').trim())) { turnOff('Modalità vocale spenta.'); break; }

      const reply = await ask(text);
      if (!on) break;
      if (reply) {
        label('speaking', 'Rispondo…');
        await speak(reply.text);
      }
    }
  }

  button.addEventListener('click', () => (on ? turnOff() : turnOn()));
})();
