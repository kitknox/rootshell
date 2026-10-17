"""Hermes lifecycle adapter; the sender owns encryption, redaction and routing."""

import atexit
from collections import OrderedDict, deque
import json
import os
import subprocess
import threading
import time
import uuid

_INTERACTIVE = {"cli", "tui", "desktop", "acp"}
_LIMIT = 256
_MAX_QUEUED = 8
# Answered prompts stay silent; matches the Pi/OMP extension.
_BLOCK_DELAY = 2.0
_SEND_TIMEOUT = 30
_EXIT_GRACE = 10.0
_turns = OrderedDict()
_seen = OrderedDict()
_blocks = {}
_lock = threading.RLock()
_ready = threading.Condition(_lock)
_queue = deque()
_worker = None
_busy = False
_active = None
_closed = False


def _bounded_put(table, key, value):
    table[key] = value
    table.move_to_end(key)
    while len(table) > _LIMIT:
        table.popitem(last=False)


def _session(kwargs):
    return str(kwargs.get("session_id") or kwargs.get("session_key") or "")


def _turn(kwargs, new=False):
    session = _session(kwargs)
    if not session:
        return None
    # Hermes can reuse task_id across many turns (CLI uses the session ID).
    # Without a real turn_id, pre_llm_call supplies a fresh local occurrence.
    turn_id = str(kwargs.get("turn_id") or "")
    with _lock:
        state = _turns.get(session)
        if new or state is None or (turn_id and turn_id != state["event_id"]):
            state = {
                "event_id": turn_id or uuid.uuid4().hex,
                "platform": kwargs.get("platform") or "",
                "cwd": os.getcwd(),
                "text": "",
            }
            _bounded_put(_turns, session, state)
        elif kwargs.get("platform"):
            state["platform"] = kwargs["platform"]
        return dict(state)


def _kill(proc):
    try:
        proc.kill()
    except OSError:
        pass


def _deliver(payload, env, timeout=_SEND_TIMEOUT, job=None):
    try:
        proc = subprocess.Popen(
            ["rootshell-notify", "hook", "--agent", "hermes"], stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, env=env,
        )
    except OSError:
        return
    with _lock:
        if job is not None:
            job["proc"] = proc
            if job["cancelled"]:
                _kill(proc)
    try:
        proc.communicate(json.dumps(payload), timeout=timeout)
    except (OSError, ValueError, subprocess.SubprocessError):
        _kill(proc)
        proc.wait()


def _work():
    global _busy, _active
    while True:
        with _ready:
            while not _queue:
                _ready.wait()
            payload, env, token = _queue.popleft()
            _busy = True
            # A reminder stays cancellable while its sender runs.
            job = _active = {"token": token, "proc": None, "cancelled": False}
        try:
            _deliver(payload, env, job=job)
        finally:
            with _ready:
                _busy = False
                _active = None
                _ready.notify_all()


def _drop_reminders(match):
    """Drops queued and in-flight reminders whose (session, request) token matches."""
    for item in [item for item in _queue if item[2] is not None and match(item[2])]:
        _queue.remove(item)
    job = _active
    if job is not None and job["token"] is not None and match(job["token"]):
        job["cancelled"] = True
        if job["proc"] is not None:
            _kill(job["proc"])


def _enqueue(payload, env, token=None):
    global _worker
    with _ready:
        if not _closed:
            if payload["hook_event_name"] == "agent_end":
                session = payload["session_id"]
                _drop_reminders(lambda t: t[0] == session)
            if len(_queue) >= _MAX_QUEUED:
                # Shed a reminder before any completion.
                reminders = [item for item in _queue if item[2] is not None]
                _queue.remove(reminders[0] if reminders else _queue[0])
            _queue.append((payload, env, token))
            try:
                if _worker is None:
                    _worker = threading.Thread(target=_work, name="rootshell-push", daemon=True)
                    _worker.start()
                _ready.notify_all()
                return
            except RuntimeError:
                _worker = None
                _queue.pop()
    # Interpreter shutdown: the exit drain already ran, so send inline.
    _deliver(payload, env, timeout=_EXIT_GRACE)


def _drain():
    """Waits for queued deliveries, bounded so a slow relay cannot hold exit."""
    global _closed
    deadline = time.monotonic() + _EXIT_GRACE
    with _ready:
        _closed = True
        for timer in _blocks.values():
            timer.cancel()
        _blocks.clear()
        while _queue or _busy:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _queue.clear()
                break
            _ready.wait(remaining)


# Normal one-shot exit must still deliver its final notification.
atexit.register(_drain)


def _send(event, session, event_id, cwd, token=None, **extra):
    if not session or not event_id:
        return
    key = (event, session, event_id)
    with _lock:
        if key in _seen:
            return
        _bounded_put(_seen, key, True)
    payload = {
        "hook_event_name": event, "session_id": session,
        "event_id": event_id, "cwd": cwd, **extra,
    }
    _enqueue(payload, dict(os.environ), token)


def _cancel_blocks(session):
    with _lock:
        for token in [token for token in _blocks if token[0] == session]:
            _blocks.pop(token).cancel()
        _drop_reminders(lambda t: t[0] == session)


def _block(token, kwargs, prompt, event_id=None):
    state = _turn(kwargs)
    if state is None or state["platform"] not in _INTERACTIVE:
        return
    session = _session(kwargs)
    token = (session, token)
    event_id = event_id or uuid.uuid4().hex

    def fire():
        # Queue under the lock so a concurrent resolve finds the reminder.
        with _lock:
            if _blocks.get(token) is not timer:
                return
            del _blocks[token]
            _send("input_required", session, event_id, state["cwd"], token, message=prompt[:4096])

    timer = threading.Timer(_BLOCK_DELAY, fire)
    timer.daemon = True
    with _lock:
        if _closed or token in _blocks or len(_blocks) >= _MAX_QUEUED:
            return
        _blocks[token] = timer
    timer.start()


def _unblock(token, kwargs):
    token = (_session(kwargs), token)
    with _lock:
        timer = _blocks.pop(token, None)
        _drop_reminders(lambda t: t == token)
    if timer is not None:
        timer.cancel()


def on_pre_llm_call(**kwargs):
    _cancel_blocks(_session(kwargs))
    _turn(kwargs, new=True)


def on_post_llm_call(assistant_response="", **kwargs):
    state = _turn(kwargs)
    if state is not None:
        with _lock:
            current = _turns.get(_session(kwargs))
            if current and current["event_id"] == state["event_id"]:
                current["text"] = str(assistant_response or "")[:4096]


def on_session_end(completed=None, failed=False, interrupted=False, **kwargs):
    state = _turn(kwargs)
    if state is None:
        return
    _cancel_blocks(_session(kwargs))
    if interrupted or (completed is None and not failed):
        with _lock:
            _turns.pop(_session(kwargs), None)
        return
    if state["platform"] not in _INTERACTIVE:
        return
    _send(
        "agent_end", _session(kwargs), state["event_id"], state["cwd"],
        stop_reason="error" if failed or not completed else "stop",
        last_assistant_message=state["text"] or (
            "Hermes task failed." if failed or not completed else "Hermes task completed."
        ),
    )


def on_human_input_request(request_id="", prompt="", **kwargs):
    if request_id:
        _block(str(request_id), kwargs, str(prompt or "Hermes is waiting for your input."), str(request_id))


def on_human_input_resolved(request_id="", **kwargs):
    _unblock(str(request_id), kwargs)


def _approval_token(kwargs):
    return "approval:" + str(kwargs.get("tool_call_id") or kwargs.get("command") or "")


def on_pre_approval_request(surface="", command="", description="", **kwargs):
    # Smart approval is an automated decision, not a human blocker.
    if surface not in _INTERACTIVE:
        return
    kwargs = {**kwargs, "command": command, "platform": surface}
    _block(_approval_token(kwargs), kwargs, description or command or "Hermes needs permission.")


def on_post_approval_response(surface="", command="", **kwargs):
    _unblock(_approval_token({**kwargs, "command": command}), kwargs)


def register(ctx):
    ctx.register_hook("pre_llm_call", on_pre_llm_call)
    ctx.register_hook("post_llm_call", on_post_llm_call)
    ctx.register_hook("on_session_end", on_session_end)
    # Newer Hermes versions provide a single observer for actual human waits.
    # Older versions expose a human approval observer but no authoritative
    # observer for clarify questions; guessing from pre-tool calls is unsafe.
    from hermes_cli.plugins import VALID_HOOKS
    if "on_human_input_request" in VALID_HOOKS:
        ctx.register_hook("on_human_input_request", on_human_input_request)
        ctx.register_hook("on_human_input_resolved", on_human_input_resolved)
    else:
        ctx.register_hook("pre_approval_request", on_pre_approval_request)
        ctx.register_hook("post_approval_response", on_post_approval_response)
