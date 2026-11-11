"""Trascrive l'audio della modalità vocale con Whisper (faster-whisper), tutto su questa macchina.

Lanciato da modules/voce/voce.rb con l'interprete di .venv-voce (bin/setup-voce) e tenuto acceso,
così il modello si carica una volta sola:
  argv:   nome del modello (es. "small"), numero di thread
  stdout: {"ready": true}, poi per ogni riga di stdin {"path": "/file/audio"} una riga
          {"text": "..."} oppure {"error": "..."}
Nessun dato lascia il Mac mini: il modello è in locale e l'audio viene letto dal file indicato.
"""
import json
import sys

# Aiuta Whisper con le parole di casa; non è un comando, solo un contesto per il riconoscimento.
HINT = "Jarvis, aggiungi al congelatore i piselli. Cosa ho in frigo? Cosa posso cucinare a cena?"


def transcribe(model, path):
    segments, _ = model.transcribe(
        path, language="it", beam_size=1, vad_filter=True, condition_on_previous_text=False,
        initial_prompt=HINT, no_speech_threshold=0.6,
    )
    return " ".join(segment.text.strip() for segment in segments).strip()


def main():
    try:
        from faster_whisper import WhisperModel
        model = WhisperModel(sys.argv[1], device="cpu", compute_type="int8", cpu_threads=int(sys.argv[2]))
    except ImportError:
        print(json.dumps({"error": "faster-whisper non installato: esegui bin/setup-voce"}), flush=True)
        return
    except Exception as e:  # modello mancante, memoria insufficiente…
        print(json.dumps({"error": f"{type(e).__name__}: {str(e)[:300]}"}), flush=True)
        return
    print(json.dumps({"ready": True}), flush=True)
    for line in sys.stdin:
        try:
            result = {"text": transcribe(model, json.loads(line)["path"])}
        except Exception as e:  # un audio illeggibile non deve fermare il servizio
            result = {"error": f"{type(e).__name__}: {str(e)[:300]}"}
        print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
