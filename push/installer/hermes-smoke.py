"""Opt-in smoke: real Hermes loader and agent turn, with local fake model/sender.

Run with Hermes's Python: python installer/hermes-smoke.py /path/to/rootshell-notify
HERMES_AGENT_DIR selects the installed Hermes source. No real model or push calls.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class ModelHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if "model" not in request:
            body = json.dumps({"tokens": [1], "count": 1}).encode()
            content_type = "application/json"
        elif request.get("stream"):
            assert request["model"] == "rootshell-smoke", request["model"]
            chunks = [
                {"id": "chatcmpl-smoke", "object": "chat.completion.chunk", "created": 1,
                 "model": "rootshell-smoke", "choices": [{"index": 0, "delta": {
                     "role": "assistant", "content": "Hermes rootshell smoke completed.",
                 }, "finish_reason": None}]},
                {"id": "chatcmpl-smoke", "object": "chat.completion.chunk", "created": 1,
                 "model": "rootshell-smoke", "choices": [
                     {"index": 0, "delta": {}, "finish_reason": "stop"}],
                 "usage": {"prompt_tokens": 10, "completion_tokens": 8, "total_tokens": 18}},
            ]
            body = ("".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks)
                    + "data: [DONE]\n\n").encode()
            content_type = "text/event-stream"
        else:
            assert request["model"] == "rootshell-smoke", request["model"]
            body = json.dumps({
                "id": "chatcmpl-smoke", "object": "chat.completion", "created": 1,
                "model": "rootshell-smoke",
                "choices": [{"index": 0, "message": {
                    "role": "assistant", "content": "Hermes rootshell smoke completed.",
                }, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 8, "total_tokens": 18},
            }).encode()
            content_type = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    hermes_source = Path(os.getenv("HERMES_AGENT_DIR", Path.home() / ".hermes/hermes-agent"))
    sys.path.insert(0, str(hermes_source))
    with tempfile.TemporaryDirectory(prefix="rootshell-hermes-smoke-") as root:
        root = Path(root)
        home = root / "hermes"
        home.mkdir()
        os.environ["HERMES_HOME"] = str(home)
        os.environ["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
        os.environ.pop("HERMES_SAFE_MODE", None)
        os.environ.pop("HERMES_ENABLE_PROJECT_PLUGINS", None)
        (home / "config.yaml").write_text(
            "plugins:\n  enabled: [rootshell-push]\n"
            "memory:\n  provider: none\n"
        )
        subprocess.run([binary, "install", "hermes"], check=True, capture_output=True)
        capture = root / "events.jsonl"
        sender = root / "rootshell-notify"
        sender.write_text(
            f"#!{sys.executable}\n"
            "import json, sys\n"
            "assert sys.argv[1:] == ['hook', '--agent', 'hermes']\n"
            f"with open({str(capture)!r}, 'a') as f:\n"
            "    f.write(json.dumps(json.load(sys.stdin)) + '\\n')\n"
        )
        sender.chmod(0o700)
        os.environ["PATH"] = str(root) + os.pathsep + os.environ["PATH"]
        from hermes_cli.plugins import discover_plugins, get_plugin_manager
        discover_plugins()
        manager = get_plugin_manager()
        loaded = manager._plugins["rootshell-push"]
        assert loaded.enabled and not loaded.error, loaded
        assert loaded.module is not None, loaded
        assert {"pre_llm_call", "post_llm_call", "on_session_end"}.issubset(loaded.hooks_registered), loaded
        server = ThreadingHTTPServer(("127.0.0.1", 0), ModelHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            from run_agent import AIAgent
            agent = AIAgent(
                base_url=f"http://127.0.0.1:{server.server_port}/v1",
                api_key="smoke-key", provider="custom", api_mode="chat_completions",
                model="rootshell-smoke", platform="cli", enabled_toolsets=[],
                max_iterations=2, quiet_mode=True, skip_memory=True,
                skip_context_files=True, skip_background_review=True,
                save_trajectories=False, session_id="rootshell-smoke-session",
            )
            result = agent.run_conversation("Reply with the completion message.")
            assert result["completed"], result
            assert result["final_response"] == "Hermes rootshell smoke completed.", result
            second = agent.run_conversation("Reply with the completion message again.")
            assert second["completed"], second
            # A real one-shot process drains at exit. Drain explicitly here so
            # the smoke can inspect the subprocess output.
            loaded.module._drain()
            events = [json.loads(line) for line in capture.read_text().splitlines()]
            assert len(events) == 2, events
            assert events[0]["event_id"] != events[1]["event_id"], events
            for event in events:
                assert event["hook_event_name"] == "agent_end", event
                assert event["stop_reason"] == "stop", event
                assert event["session_id"] == agent.session_id, event
                assert event["event_id"], event
                assert event["last_assistant_message"] == result["final_response"], event
            print("Hermes real loader + two agent turns + sender subprocesses: PASS")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
