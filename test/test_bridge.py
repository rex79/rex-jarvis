"""Test del ponte Copilot senza rete: timeout per inattività e log senza contenuti."""
import asyncio
import os
import sys
import tempfile
import unittest
from pathlib import Path

os.environ["JARVIS_COPILOT_INACTIVITY"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib" / "copilot"))
import bridge  # noqa: E402


class Activity:
    def __init__(self, type_, text=None, name=None):
        self.type, self.text, self.name = type_, text, name


async def stream(items, stall_after=None):
    for i, item in enumerate(items):
        if stall_after is not None and i == stall_after:
            await asyncio.sleep(5)
        await asyncio.sleep(0.01)
        yield item


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        bridge.LOG_PATH = Path(self.tmp.name) / "copilot.log"

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_long_but_active_stream_is_fully_collected(self):
        items = [Activity("typing")] * 3 + [Activity("message", "Briefing segreto del cliente X")]
        got = asyncio.run(bridge.collect(stream(items), bridge.Trace("test")))
        self.assertEqual(4, len(got))

    def test_silence_beyond_inactivity_raises_timeout(self):
        items = [Activity("typing"), Activity("message", "mai arrivato")]
        with self.assertRaises(bridge.BridgeError) as ctx:
            asyncio.run(bridge.collect(stream(items, stall_after=1), bridge.Trace("test")))
        self.assertEqual("TIMEOUT", ctx.exception.code)

    def test_log_contains_types_and_lengths_never_text(self):
        asyncio.run(bridge.collect(stream([Activity("message", "Briefing segreto del cliente X")]), bridge.Trace("test")))
        log = bridge.LOG_PATH.read_text(encoding="utf-8")
        self.assertIn("message (30 caratteri)", log)
        self.assertNotIn("segreto", log)

    def test_texts_keeps_only_message_text(self):
        acts = [Activity("typing"), Activity("message", " Uno "), Activity("event", name="x"), Activity("message", "Due")]
        self.assertEqual(["Uno", "Due"], bridge.texts(acts))


if __name__ == "__main__":
    unittest.main()
