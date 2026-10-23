"""Ponte tra Jarvis e l'agente Copilot Studio, con il client ufficiale Microsoft.

Uso (lo chiama lib/tools/copilot.rb con il Python di .venv):
  bridge.py login    login interattivo nel browser (account aziendale, MFA)
  bridge.py status   {"logged_in": bool, "account": "..."}
  bridge.py ask      legge {"text": "...", "conversation_id": "..."?} da stdin,
                     scrive {"text": "...", "conversation_id": "..."} su stdout

Configurazione da variabili d'ambiente (le carica Jarvis da ~/.jarvis_env):
  JARVIS_COPILOT_TENANT_ID, JARVIS_COPILOT_CLIENT_ID,
  JARVIS_COPILOT_ENVIRONMENT_ID, JARVIS_COPILOT_AGENT

Il token resta nel Portachiavi di macOS (msal-extensions), mai in chiaro su disco.
Gli errori escono come {"error": "...", "code": "..."} con codice di uscita 1.
"""

import asyncio
import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import msal
from msal_extensions import PersistedTokenCache, build_encrypted_persistence
from microsoft_agents.copilotstudio.client import (
    ConnectionSettings,
    CopilotClient,
    PowerPlatformEnvironment,
)

CACHE_PATH = Path.home() / ".jarvis" / "copilot_token_cache.bin"
# Il contesto di lavoro può uscire dal Mac solo verso Microsoft (login e Power Platform).
ALLOWED_SUFFIX = ".api.powerplatform.com"
# Un briefing completo consulta posta, calendario, Jira e documenti: può richiedere minuti.
# L'attesa si interrompe dopo INACTIVITY secondi senza alcun evento dall'agente, o dopo TOTAL.
INACTIVITY = int(os.environ.get("JARVIS_COPILOT_INACTIVITY", "300"))
TOTAL = int(os.environ.get("JARVIS_COPILOT_TIMEOUT", "900"))
LOG_PATH = Path.home() / ".jarvis" / "copilot.log"


class BridgeError(Exception):
    def __init__(self, message, code="ERROR"):
        super().__init__(message)
        self.code = code


def config():
    names = ["JARVIS_COPILOT_TENANT_ID", "JARVIS_COPILOT_CLIENT_ID",
             "JARVIS_COPILOT_ENVIRONMENT_ID", "JARVIS_COPILOT_AGENT"]
    values = {n: os.environ.get(n, "").strip() for n in names}
    missing = [n for n, v in values.items() if not v]
    if missing:
        raise BridgeError("mancano in ~/.jarvis_env: " + ", ".join(missing), "CONFIG")
    return values


def settings(cfg):
    s = ConnectionSettings(environment_id=cfg["JARVIS_COPILOT_ENVIRONMENT_ID"],
                           agent_identifier=cfg["JARVIS_COPILOT_AGENT"])
    host = urlparse(PowerPlatformEnvironment.get_copilot_studio_connection_url(settings=s)).hostname or ""
    if not host.endswith(ALLOWED_SUFFIX):
        raise BridgeError(f"endpoint inatteso {host}: rifiuto di inviare dati", "PRIVACY")
    return s


def msal_app(cfg):
    CACHE_PATH.parent.mkdir(mode=0o700, exist_ok=True)
    cache = PersistedTokenCache(build_encrypted_persistence(str(CACHE_PATH)))
    return msal.PublicClientApplication(
        cfg["JARVIS_COPILOT_CLIENT_ID"],
        authority=f"https://login.microsoftonline.com/{cfg['JARVIS_COPILOT_TENANT_ID']}",
        token_cache=cache,
    )


def token(cfg, scope, interactive=False):
    app = msal_app(cfg)
    accounts = app.get_accounts()
    result = app.acquire_token_silent([scope], account=accounts[0]) if accounts else None
    if not result and interactive:
        result = app.acquire_token_interactive([scope], prompt="select_account")
    if not result:
        raise BridgeError("accesso Microsoft necessario: esegui ruby jarvis.rb --copilot-login", "LOGIN_REQUIRED")
    if "access_token" not in result:
        raise BridgeError(result.get("error_description") or result.get("error") or "login non riuscito", "AUTH")
    return result["access_token"], (result.get("id_token_claims") or {}).get("preferred_username")


class Trace:
    """Progressi su stderr (per Jarvis) e log diagnostico con SOLO tipi di evento e tempi:
    mai il contenuto, che è un dato di lavoro."""

    def __init__(self, label):
        self.start = time.monotonic()
        LOG_PATH.parent.mkdir(mode=0o700, exist_ok=True)
        self.log = open(LOG_PATH, "a", encoding="utf-8")
        self.event(f"--- {label}")

    def event(self, what):
        elapsed = time.monotonic() - self.start
        self.log.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} +{elapsed:6.1f}s {what}\n")
        self.log.flush()
        print(f"PROGRESS {elapsed:.0f}", file=sys.stderr, flush=True)

    def activity(self, a):
        kind = getattr(a, "type", "?")
        name = getattr(a, "name", None)
        text = getattr(a, "text", None)
        self.event(f"{kind}{'/' + name if name else ''}{f' ({len(text)} caratteri)' if text else ''}")


async def collect(iterator, trace):
    """Legge gli eventi finché il flusso finisce; errore solo dopo INACTIVITY secondi di silenzio."""
    items = []
    it = iterator.__aiter__()
    while True:
        try:
            item = await asyncio.wait_for(it.__anext__(), INACTIVITY)
        except StopAsyncIteration:
            return items
        except asyncio.TimeoutError:
            trace.event(f"nessun evento per {INACTIVITY}s: interrompo l'attesa")
            raise BridgeError(f"l'agente non ha dato segni di vita per {INACTIVITY // 60} minuti; "
                              "potrebbe aver completato comunque il lavoro sul suo lato", "TIMEOUT")
        trace.activity(item)
        items.append(item)


def texts(activities):
    return [a.text.strip() for a in activities if getattr(a, "type", None) == "message" and getattr(a, "text", None)]


async def ask(cfg, text, conversation_id=None):
    trace = Trace(f"richiesta ({len(text)} caratteri)")
    s = settings(cfg)
    access_token, _ = token(cfg, CopilotClient.scope_from_settings(s))
    client = CopilotClient(s, access_token)
    if not conversation_id:
        for activity in await collect(client.start_conversation(True), trace):
            if getattr(activity, "conversation", None) and activity.conversation.id:
                conversation_id = activity.conversation.id
    replies = await collect(client.ask_question(text, conversation_id), trace)
    answer = "\n\n".join(texts(replies))
    trace.event(f"fine: {len(replies)} eventi, risposta di {len(answer)} caratteri")
    if not answer:
        raise BridgeError("l'agente non ha risposto con un testo", "EMPTY")
    return {"text": answer, "conversation_id": conversation_id}


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    cfg = config()
    if command == "login":
        _, account = token(cfg, CopilotClient.scope_from_settings(settings(cfg)), interactive=True)
        return {"logged_in": True, "account": account}
    if command == "status":
        accounts = msal_app(cfg).get_accounts()
        return {"logged_in": bool(accounts), "account": accounts[0].get("username") if accounts else None}
    if command == "ask":
        request = json.loads(sys.stdin.read() or "{}")
        text = str(request.get("text", "")).strip()
        if not text:
            raise BridgeError("richiesta vuota", "INPUT")
        return asyncio.run(asyncio.wait_for(ask(cfg, text, request.get("conversation_id")), TOTAL))
    raise BridgeError("comando sconosciuto (login, status, ask)", "USAGE")


if __name__ == "__main__":
    try:
        print(json.dumps(main(sys.argv), ensure_ascii=False))
    except BridgeError as e:
        print(json.dumps({"error": str(e), "code": e.code}, ensure_ascii=False))
        sys.exit(1)
    except asyncio.TimeoutError:
        print(json.dumps({"error": f"l'agente non ha finito entro {TOTAL // 60} minuti; potrebbe aver completato "
                                   "comunque il lavoro sul suo lato", "code": "TIMEOUT"}, ensure_ascii=False))
        sys.exit(1)
    except Exception as e:  # errori di rete o del servizio: messaggio breve, senza token
        print(json.dumps({"error": f"{type(e).__name__}: {str(e)[:300]}", "code": "ERROR"}, ensure_ascii=False))
        sys.exit(1)
