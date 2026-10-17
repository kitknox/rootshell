import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).with_name("hermes.py")


class HermesPluginTests(unittest.TestCase):
    def run_hooks(self, script, binary=True, sender_delay=None):
        """sender_delay maps hook_event_name to seconds the fake sender sleeps before capturing."""
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            output = root / "events.jsonl"
            if binary:
                sender = root / "rootshell-notify"
                sender.write_text(
                    f"#!{sys.executable}\n"
                    "import json, os, sys, time\n"
                    "assert sys.argv[1:] == ['hook', '--agent', 'hermes']\n"
                    "event = json.load(sys.stdin)\n"
                    f"time.sleep({sender_delay or {}!r}.get(event['hook_event_name'], 0))\n"
                    "with open(os.environ['CAPTURE'], 'a') as f:\n"
                    "    f.write(json.dumps(event) + '\\n')\n"
                )
                sender.chmod(0o700)
            env = {**os.environ, "PATH": str(root), "CAPTURE": str(output)}
            code = (
                "import importlib.util\n"
                f"spec = importlib.util.spec_from_file_location('plugin', {str(SOURCE)!r})\n"
                "p = importlib.util.module_from_spec(spec)\n"
                "spec.loader.exec_module(p)\n" + script
            )
            result = subprocess.run(
                [sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=15
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            return [json.loads(line) for line in output.read_text().splitlines()] if output.exists() else []

    def test_completion_uses_final_reply_and_deduplicates_turns(self):
        events = self.run_hooks("""
p.on_pre_llm_call(session_id="s", turn_id="t", platform="cli")
p.on_post_llm_call(session_id="s", turn_id="t", assistant_response="Finished.", platform="cli")
p.on_session_end(session_id="s", turn_id="t", completed=True, platform="cli")
p.on_session_end(session_id="s", turn_id="t", completed=True, platform="cli")
p.on_post_llm_call(session_id="s", turn_id="t2", assistant_response="Next.", platform="cli")
p.on_session_end(session_id="s", turn_id="t2", completed=True, platform="cli")
""")
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]["last_assistant_message"], "Finished.")
        self.assertEqual(events[0]["stop_reason"], "stop")
        self.assertNotEqual(events[0]["event_id"], events[1]["event_id"])

    def test_interruption_and_gateway_are_silent_but_failures_notify(self):
        events = self.run_hooks("""
p.on_post_llm_call(session_id="s", turn_id="cancel", assistant_response="Partial", platform="cli")
p.on_session_end(session_id="s", turn_id="cancel", interrupted=True, completed=False, platform="cli")
p.on_session_end(session_id="s", turn_id="fail", completed=False, failed=True, platform="cli")
p.on_session_end(session_id="g", turn_id="t", completed=True, platform="telegram")
p.on_session_end(session_id="s", platform="cli", interrupted=True)
""")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["stop_reason"], "error")

    def test_latest_human_input_hook_and_legacy_fallback(self):
        events = self.run_hooks("""
import time
p._BLOCK_DELAY = 0.05
p.on_pre_llm_call(session_id="s", turn_id="t", platform="cli")
p.on_human_input_request(session_id="s", request_id="r1", kind="clarify", prompt="Which file?", platform="cli")
p.on_human_input_request(session_id="s", request_id="r1", kind="clarify", prompt="Which file?", platform="cli")
p.on_pre_approval_request(session_key="s", surface="smart", command="rm temp")
p.on_pre_approval_request(session_key="s", surface="cli", command="rm temp")
time.sleep(0.5)
""")
        self.assertEqual(len(events), 2)
        self.assertTrue(all(e["hook_event_name"] == "input_required" for e in events))
        self.assertEqual(sorted(e["message"] for e in events), ["Which file?", "rm temp"])

    def test_answered_or_superseded_requests_are_silent(self):
        self.assertEqual(self.run_hooks("""
import time
p._BLOCK_DELAY = 0.2
p.on_pre_llm_call(session_id="s", turn_id="t", platform="cli")
p.on_human_input_request(session_id="s", request_id="r1", prompt="Which file?", platform="cli")
p.on_human_input_resolved(session_id="s", request_id="r1", outcome="answered")
p.on_pre_approval_request(session_key="s", surface="cli", command="rm temp", tool_call_id="c1")
p.on_post_approval_response(session_key="s", surface="cli", command="rm temp", tool_call_id="c1", choice="once")
p.on_human_input_request(session_id="s", request_id="r2", prompt="Again?", platform="cli")
p.on_pre_llm_call(session_id="s", turn_id="t2", platform="cli")
time.sleep(0.5)
"""), [])

    def test_resolving_drops_a_reminder_queued_behind_a_slow_delivery(self):
        events = self.run_hooks("""
import time
p._BLOCK_DELAY = 0.05
p.on_session_end(session_id="other", turn_id="t", completed=True, platform="cli")
p.on_pre_llm_call(session_id="s", turn_id="t2", platform="cli")
p.on_human_input_request(session_id="s", request_id="r1", prompt="Which file?", platform="cli")
time.sleep(0.3)
assert [item[2] for item in p._queue] == [("s", "r1")], list(p._queue)
p.on_human_input_resolved(session_id="s", request_id="r1", outcome="answered")
assert not p._queue
""", sender_delay={"agent_end": 1})
        self.assertEqual([e["hook_event_name"] for e in events], ["agent_end"])

    def test_resolving_stops_a_reminder_already_being_sent(self):
        started = time.monotonic()
        events = self.run_hooks("""
import time
p._BLOCK_DELAY = 0.05
p.on_pre_llm_call(session_id="s", turn_id="t", platform="cli")
p.on_human_input_request(session_id="s", request_id="r1", prompt="Which file?", platform="cli")
time.sleep(0.3)
assert p._active and p._active["token"] == ("s", "r1"), p._active
p.on_human_input_resolved(session_id="s", request_id="r1", outcome="answered")
""", sender_delay={"input_required": 3})
        self.assertLess(time.monotonic() - started, 2.5)
        self.assertEqual(events, [])

    def test_backlog_is_bounded_and_exit_has_a_deadline(self):
        started = time.monotonic()
        events = self.run_hooks("""
p._EXIT_GRACE = 1.0
for i in range(20):
    p.on_session_end(session_id=f"s{i}", turn_id="t", completed=True, platform="cli")
assert len(p._queue) <= p._MAX_QUEUED, len(p._queue)
""", sender_delay={"agent_end": 3})
        self.assertLess(time.monotonic() - started, 6)
        self.assertEqual(events, [])

    def test_legacy_clarify_does_not_guess_that_a_human_wait_exists(self):
        self.assertEqual(self.run_hooks("""
import sys, types
sys.modules["hermes_cli"] = types.ModuleType("hermes_cli")
sys.modules["hermes_cli.plugins"] = types.SimpleNamespace(VALID_HOOKS={"pre_approval_request"})
class Context:
    def __init__(self): self.hooks = {}
    def register_hook(self, name, callback): self.hooks[name] = callback
ctx = Context()
p.register(ctx)
assert "pre_tool_call" not in ctx.hooks
assert "pre_approval_request" in ctx.hooks
ctx.hooks["pre_llm_call"](session_id="s", turn_id="t", platform="cli")
"""), [])

    def test_no_turn_id_gets_stable_fallback_without_merging_next_turn(self):
        events = self.run_hooks("""
for answer in ("First", "Second"):
    p.on_pre_llm_call(session_id="s", platform="cli")
    p.on_post_llm_call(session_id="s", assistant_response=answer, platform="cli")
    p.on_session_end(session_id="s", completed=True, platform="cli")
    p.on_session_end(session_id="s", completed=True, platform="cli")
""")
        self.assertEqual(len(events), 2)
        self.assertNotEqual(events[0]["event_id"], events[1]["event_id"])

    def test_sender_failure_does_not_break_hermes(self):
        self.assertEqual(self.run_hooks("""
p.on_session_end(session_id="s", turn_id="t", completed=True, platform="cli")
""", binary=False), [])

    def test_reused_task_id_is_not_a_turn_identity(self):
        events = self.run_hooks("""
for answer in ("First", "Second"):
    p.on_pre_llm_call(session_id="s", task_id="same-task", platform="cli")
    p.on_post_llm_call(session_id="s", task_id="same-task", assistant_response=answer, platform="cli")
    p.on_session_end(session_id="s", task_id="same-task", completed=True, platform="cli")
    p.on_session_end(session_id="s", task_id="same-task", completed=True, platform="cli")
""")
        self.assertEqual(len(events), 2)
        self.assertNotEqual(events[0]["event_id"], events[1]["event_id"])


if __name__ == "__main__":
    unittest.main()
