"""Analizza un titolo con TradingAgents (TauricResearch) e restituisce la decisione in JSON.

Lanciato da lib/trading.rb con l'interprete di .venv-trading (bin/setup-trading):
  stdin:  {"ticker": "NVDA", "date": "2026-10-29", "quick_model": "...", "deep_model": "...",
           "debate_rounds": 1, "language": "Italian", "results_dir": "..."}
  stdout: ultima riga {"ticker", "decision", "summary", "plan"} oppure {"error", "code"}

Solo analisi: nessuna chiave di broker, nessun ordine. La chiave OpenRouter arriva
dall'ambiente (OPENROUTER_API_KEY) e non viene mai stampata.
"""
import json
import sys

# Campi dello stato finale di TradingAgents che finiscono nella nota.
SUMMARY_KEY = "final_trade_decision"
PLAN_KEY = "trader_investment_plan"
MAX_TEXT = 6000


def build_config(base, request):
    """Applica la richiesta di Jarvis a una copia di DEFAULT_CONFIG."""
    config = dict(base)
    config["llm_provider"] = "openrouter"
    config["quick_think_llm"] = request["quick_model"]
    config["deep_think_llm"] = request.get("deep_model") or request["quick_model"]
    rounds = int(request.get("debate_rounds", 1))
    config["max_debate_rounds"] = rounds
    config["max_risk_discuss_rounds"] = rounds
    if request.get("results_dir"):
        config["results_dir"] = request["results_dir"]
    # Il nome della chiave della lingua è cambiato tra le versioni: si imposta quella che esiste.
    for key in [k for k in base if "language" in k]:
        config[key] = request.get("language", "Italian")
    return config


def clip(value):
    text = str(value or "").strip()
    return text if len(text) <= MAX_TEXT else text[:MAX_TEXT].rstrip() + "…"


def analyze(request):
    from tradingagents.default_config import DEFAULT_CONFIG
    from tradingagents.graph.trading_graph import TradingAgentsGraph

    graph = TradingAgentsGraph(debug=False, config=build_config(DEFAULT_CONFIG.copy(), request))
    state, decision = graph.propagate(request["ticker"], request["date"])
    if request.get("results_dir") and hasattr(graph, "save_reports"):
        try:
            graph.save_reports(state, request["ticker"])
        except Exception:  # i report completi sono un extra: la decisione vale comunque
            pass
    return {
        "ticker": request["ticker"],
        "decision": str(decision).strip(),
        "summary": clip(state.get(SUMMARY_KEY)),
        "plan": clip(state.get(PLAN_KEY)),
    }


def main():
    try:
        request = json.loads(sys.stdin.read())
        result = analyze(request)
    except ImportError:
        result = {"error": "TradingAgents non installato: esegui bin/setup-trading", "code": "CONFIG"}
    except Exception as e:  # l'errore va a Jarvis, che continua con gli altri titoli
        result = {"error": f"{type(e).__name__}: {str(e)[:300]}", "code": "ERROR"}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
