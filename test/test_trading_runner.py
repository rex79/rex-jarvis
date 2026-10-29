"""Test del ponte TradingAgents senza rete né libreria installata: solo la configurazione."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib" / "trading"))
import runner  # noqa: E402


class RunnerTest(unittest.TestCase):
    BASE = {"llm_provider": "openai", "deep_think_llm": "x", "quick_think_llm": "y", "output_language": "English"}

    def test_config_uses_openrouter_models_and_language(self):
        config = runner.build_config(self.BASE, {"quick_model": "p/fast", "debate_rounds": 2, "language": "Italian"})
        self.assertEqual("openrouter", config["llm_provider"])
        self.assertEqual("p/fast", config["quick_think_llm"])
        self.assertEqual("p/fast", config["deep_think_llm"])
        self.assertEqual(2, config["max_debate_rounds"])
        self.assertEqual("Italian", config["output_language"])
        self.assertEqual(runner.DEFAULT_MAX_TOKENS, config["max_tokens"])
        self.assertEqual(2048, runner.build_config(self.BASE, {"quick_model": "p", "max_tokens": 2048})["max_tokens"])
        self.assertEqual("English", self.BASE["output_language"])  # l'originale non cambia

    def test_long_texts_are_clipped(self):
        self.assertTrue(len(runner.clip("a" * 10000)) <= runner.MAX_TEXT + 1)
        self.assertEqual("", runner.clip(None))


if __name__ == "__main__":
    unittest.main()
