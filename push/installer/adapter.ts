// Uses only JavaScript syntax and Node built-ins; no agent SDK imports.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

const AGENT = "__ROOTSHELL_AGENT__";

export default function rootshellPush(api) {
  // Pi can load both project and personal copies of this extension.
  const registryKey = Symbol.for("rootshell-notify.push.owners.v1");
  const owners = globalThis[registryKey] ??= new Map();
  const owner = {};
  let ownerKey;
  let settleTimer;
  let session;
  let generation = 0;
  let settled = false;
  let pendingEnd;
  let confirmedEnd;
  let finalSend;
  const blocks = new Map();
  let queue = [];
  let active;

  function releaseOwner() {
    if (owners.get(ownerKey) === owner) owners.delete(ownerKey);
    ownerKey = undefined;
  }

  function clearBlocks() {
    for (const block of blocks.values()) clearTimeout(block.timer);
    blocks.clear();
  }

  function stopActive() {
    const current = active;
    if (!current) return;
    try { current.child?.kill("SIGKILL"); } catch {}
    current.done();
  }

  function cancelInvalidActive() {
    if (active && !valid(active.item)) stopActive();
  }

  function reset(ctx) {
    clearTimeout(settleTimer);
    generation++;
    settled = false;
    pendingEnd = undefined;
    confirmedEnd = undefined;
    finalSend = undefined;
    clearBlocks();
    for (const item of queue) item.finish();
    queue = [];
    const id = ctx.sessionManager.getSessionId();
    if (id !== session) releaseOwner();
    session = id;
    cancelInvalidActive();
  }

  function valid(item) {
    try { return item.valid(); } catch { return false; }
  }

  function drain() {
    if (active) return;
    while (queue.length) {
      const item = queue.shift();
      if (!valid(item)) {
        item.finish();
        continue;
      }
      const current = { item };
      active = current;
      const done = () => {
        if (active !== current) return;
        clearTimeout(current.timeout);
        active = undefined;
        item.finish();
        drain();
      };
      current.done = done;
      try {
        current.child = spawn("rootshell-notify", ["hook", "--agent", AGENT], {
          shell: false, stdio: ["pipe", "ignore", "ignore"], windowsHide: true,
        });
        current.child.on("error", done);
        current.child.once("close", done);
        // A failed pipe must not crash the host; the process deadline remains.
        current.child.stdin.on("error", () => {});
        // Allow the hook's 25-second deadline plus process startup overhead.
        current.timeout = setTimeout(() => {
          try { current.child.kill("SIGKILL"); } catch {}
          done();
        }, 30_000);
        current.timeout.unref?.();
        current.child.stdin.end(JSON.stringify(item.payload));
        current.child.unref();
        current.child.stdin.unref?.();
        return;
      } catch {
        // Missing binaries, spawn errors and broken pipes are fail-open.
        try { current.child?.kill("SIGKILL"); } catch {}
        clearTimeout(current.timeout);
        if (active === current) active = undefined;
        item.finish();
      }
    }
  }

  function send(payload, check) {
    queue = queue.filter((item) => {
      if (valid(item)) return true;
      item.finish();
      return false;
    });
    if (queue.length >= 8) return Promise.resolve();
    let finish;
    const promise = new Promise((resolve) => { finish = resolve; });
    queue.push({ payload, valid: check, finish });
    drain();
    return promise;
  }

  function cancelBlock(key) {
    clearTimeout(blocks.get(key)?.timer);
    blocks.delete(key);
    cancelInvalidActive();
  }

  function block(key, message, ctx) {
    if (!ctx.hasUI || blocks.has(key) || blocks.size >= 8) return;
    const id = session;
    const currentGeneration = generation;
    const entry = {};
    blocks.set(key, entry);
    const check = () => blocks.get(key) === entry && generation === currentGeneration &&
      ctx.sessionManager.getSessionId() === id && ctx.hasUI;
    entry.timer = setTimeout(() => {
      try {
        if (!check()) return;
        send({ hook_event_name: "input_required", session_id: id, cwd: ctx.cwd,
          event_id: randomUUID(), message }, check);
      } catch {
        // UI may have been disposed along with its session.
      }
    }, 2000);
    entry.timer.unref?.();
  }

  function on(name, handler) {
    return api.on(name, (event, ctx) => {
      try {
        if (ctx.agent?.kind === "sub") return;
        const id = ctx.sessionManager.getSessionId();
        if (typeof id !== "string" || !id || typeof ctx.cwd !== "string") return;
        if (id !== session) reset(ctx);
        const key = `${AGENT}\0${id}`;
        if (owners.has(key) && owners.get(key) !== owner) return;
        if (name === "session_shutdown" && owners.get(key) !== owner) return;
        owners.set(key, owner);
        ownerKey = key;
        return handler(event, ctx);
      } catch {
        // Notifications must never interrupt the agent.
      }
    });
  }

  function currentEnd(end) {
    return end && generation === end.currentGeneration &&
      end.ctx.sessionManager.getSessionId() === end.id &&
      end.ctx.isIdle() && !end.ctx.hasPendingMessages();
  }

  function commitEnd(end) {
    if (settled || !currentEnd(end)) return;
    clearTimeout(settleTimer);
    clearBlocks();
    cancelInvalidActive();
    settled = true;
    finalSend = send(end.payload, () => currentEnd(end));
  }

  // OMP can stay busy after agent_end (e.g. revoking computer control), so
  // recheck until idle; a new run, session change or reset clears the timer.
  function scheduleEnd(end, attempt = 0) {
    if (!end || settled || attempt >= 600) return;
    clearTimeout(settleTimer);
    settleTimer = setTimeout(() => {
      try {
        if (generation !== end.currentGeneration ||
          end.ctx.sessionManager.getSessionId() !== end.id) return;
        if (currentEnd(end)) commitEnd(end);
        else scheduleEnd(end, attempt + 1);
      } catch {
        // Missing notifier binaries and I/O errors are fail-open.
      }
    }, 100);
    settleTimer.unref?.();
  }

  // Requires Earendil Pi >= 1.2.0. agent_end is only a candidate; the
  // authoritative agent_settled event follows all automatic continuations.
  if (AGENT === "pi") {
    on("agent_settled", (event, ctx) => {
      if (event.aborted) {
        reset(ctx);
        return;
      }
      confirmedEnd = pendingEnd;
      // print-mode disposes immediately after this authoritative event.
      if (!ctx.hasUI) commitEnd(confirmedEnd);
      else scheduleEnd(confirmedEnd);
    });
  }

  for (const name of ["session_start", "session_tree", "before_agent_start", "agent_start"]) {
    on(name, (_event, ctx) => reset(ctx));
  }
  if (AGENT === "omp") {
    for (const name of ["session_switch", "auto_retry_start"]) {
      on(name, (_event, ctx) => reset(ctx));
    }
  }
  on("session_shutdown", (event, ctx) => {
    // Pi 1.2 emits quit/reload/new/resume/fork; OMP 18.10.3 has no reason.
    const closing = AGENT === "pi" ? event.reason === "quit" : event.reason === undefined;
    if (!closing) {
      reset(ctx);
      stopActive();
      releaseOwner();
      return;
    }
    clearTimeout(settleTimer);
    clearBlocks();
    cancelInvalidActive();
    if (!finalSend) commitEnd(AGENT === "pi" ? confirmedEnd : pendingEnd);
    if (!finalSend) {
      reset(ctx);
      stopActive();
      releaseOwner();
      return;
    }
    // Only shutdown may await I/O. A referenced deadline keeps one-shot hosts
    // alive while the final hook runs; no blocked reminder is flushed.
    const pending = finalSend;
    const shutdownGeneration = generation;
    const shutdownOwnerKey = ownerKey;
    const stillClosing = () => generation === shutdownGeneration && ownerKey === shutdownOwnerKey;
    return new Promise((resolve) => {
      let finished = false;
      const finish = () => {
        if (finished) return;
        finished = true;
        clearTimeout(deadline);
        if (stillClosing()) {
          try { reset(ctx); stopActive(); } catch {}
          releaseOwner();
        }
        resolve();
      };
      const deadline = setTimeout(() => {
        if (stillClosing()) stopActive();
        finish();
      }, 30_000);
      pending.then(finish, finish);
    });
  });

  on("agent_end", (event, ctx) => {
    clearTimeout(settleTimer);
    pendingEnd = undefined;
    clearBlocks();
    cancelInvalidActive();
    if (settled || event.willContinue || ctx.hasPendingMessages()) return;
    // OMP can still be busy while notifying agent_end handlers. Retain the
    // candidate; commitEnd checks idle/pending state after dispatch or at quit.
    const message = event.messages?.findLast((item) => item.role === "assistant");
    if (!message || !["stop", "length", "error"].includes(message.stopReason)) return;
    const id = session;
    const currentGeneration = generation;
    // Only text goes to Go's common redactor, never thinking, tool arguments,
    // tool results, provider errors or a serialized conversation.
    let text = "";
    for (const part of Array.isArray(message.content) ? message.content : []) {
      if (part.type === "text" && typeof part.text === "string") {
        text += (text ? "\n" : "") + part.text.slice(0, 4096 - text.length);
        if (text.length >= 4096) break;
      }
    }
    const payload = {
      hook_event_name: "agent_end",
      session_id: id,
      cwd: ctx.cwd,
      event_id: randomUUID(),
      last_assistant_message: text.slice(0, 4096),
      stop_reason: message.stopReason,
    };
    pendingEnd = { payload, ctx, id, currentGeneration };
    if (AGENT === "omp") scheduleEnd(pendingEnd);
  });

  if (AGENT === "omp") {
    const approvalSession = (event) => event.sessionId === session;
    const toolID = (event) => typeof event.toolCallId === "string" &&
      event.toolCallId.length > 0 && event.toolCallId.length <= 256;
    on("tool_approval_requested", (event, ctx) => {
      if (approvalSession(event) && toolID(event)) {
        block(`approval:${event.toolCallId}`, "Tool approval required.", ctx);
      }
    });
    on("tool_approval_resolved", (event) => {
      if (approvalSession(event) && toolID(event)) cancelBlock(`approval:${event.toolCallId}`);
    });
    on("tool_execution_start", (event, ctx) => {
      if (event.toolName === "ask" && toolID(event)) {
        block(`ask:${event.toolCallId}`, "User input required.", ctx);
      }
    });
    on("tool_execution_end", (event) => {
      if (!toolID(event)) return;
      cancelBlock(`ask:${event.toolCallId}`);
      cancelBlock(`approval:${event.toolCallId}`);
    });
  } else {
    // Earendil Pi's UI wrapper emits these real events for extension dialogs;
    // they do not cover all possible tools or constitute a generic approval API.
    on("ui_prompt_start", (_event, ctx) => block("ui", "User input required.", ctx));
    on("ui_prompt_end", () => cancelBlock("ui"));
  }
}
