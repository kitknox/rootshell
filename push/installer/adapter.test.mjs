import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { test } from "node:test";

const template = await readFile(new URL("./adapter.ts", import.meta.url), "utf8");
let moduleID = 0;

async function harness(t, agent = "omp", modernPi = false) {
  const calls = [];
  const children = [];
  t.mock.timers.enable({ apis: ["setTimeout"] });
  t.mock.method(childProcess, "spawn", (...args) => {
    const child = new EventEmitter();
    child.stdin = new EventEmitter();
    child.stdin.end = (data) => calls.push({ args, payload: JSON.parse(data) });
    child.stdin.destroy = () => {};
    child.kill = () => { child.killed = true; };
    child.unref = () => {};
    children.push(child);
    return child;
  });
  syncBuiltinESMExports();
  t.after(() => {
    t.mock.restoreAll();
    syncBuiltinESMExports();
  });
  const handlers = new Map();
  const source = template.replaceAll("__ROOTSHELL_AGENT__", agent);
  const { default: adapter } = await import(
    `data:text/javascript;base64,${Buffer.from(source).toString("base64")}#${moduleID++}`
  );
  adapter({ on: (event, handler) => {
    assert.equal(handlers.has(event), false, `duplicate handler: ${event}`);
    handlers.set(event, handler);
    if (modernPi) return () => handlers.delete(event);
  } });
  let session = "session-a";
  let idle = true;
  let pending = false;
  const ctx = {
    cwd: "/work/project with spaces; $(secret)",
    hasUI: true,
    agent: { kind: "main", depth: 0 },
    sessionManager: { getSessionId: () => session },
    isIdle: () => idle,
    hasPendingMessages: () => pending,
  };
  const runtimes = [handlers];
  t.after(() => {
    for (const runtime of runtimes) {
      runtime.get("before_agent_start")?.({ type: "before_agent_start" }, ctx);
      runtime.get("session_shutdown")?.({ type: "session_shutdown", reason: "reload" }, ctx);
    }
  });
  return {
    ctx, calls, children, handlers,
    emit(event, data = {}, context = ctx) {
      assert.ok(handlers.has(event), `${agent} must handle ${event}`);
      // An extension event must not wait for a notifier process.
      assert.equal(handlers.get(event)({ type: event, ...data }, context), undefined);
    },
    shutdown(data = {}) {
      return handlers.get("session_shutdown")({ type: "session_shutdown", ...data }, ctx);
    },
    clone() {
      const other = new Map();
      adapter({ on(name, handler) { other.set(name, handler); } });
      runtimes.push(other);
      return {
        emit(event, data = {}, context = ctx) {
          return other.get(event)({ type: event, ...data }, context);
        },
      };
    },
    tick(ms = 100) { t.mock.timers.tick(ms); },
    session(value) { session = value; },
    idle(value) { idle = value; },
    pending(value) { pending = value; },
    close(index = children.length - 1, code = 0) { children[index].emit("close", code); },
  };
}

function assistant(text = "Round finished.", stopReason = "stop") {
  return {
    role: "assistant", stopReason,
    content: [{ type: "thinking", thinking: "private chain" }, { type: "text", text }],
    errorMessage: "private provider error",
  };
}

test("settled completion sends only last assistant text over argv and JSON stdin", async (t) => {
  for (const agent of ["pi", "omp"]) {
    await t.test(agent, async (t) => {
      const h = await harness(t, agent);
      h.emit("agent_start");
      h.emit("agent_end", { messages: [
        { role: "user", content: "private prompt" },
        assistant("Earlier reply."),
        { role: "toolResult", content: "secret file" },
        assistant("Final reply."),
      ] });
      if (agent === "pi") h.emit("agent_settled", { aborted: false });
      assert.equal(h.calls.length, 0);
      h.tick();
      assert.equal(h.calls.length, 1);
      const { args, payload } = h.calls[0];
      assert.equal(args[0], "rootshell-notify");
      assert.deepEqual(args[1], ["hook", "--agent", agent]);
      assert.equal(args[2].shell, false);
      assert.deepEqual(args[2].stdio, ["pipe", "ignore", "ignore"]);
      assert.deepEqual(payload, {
        hook_event_name: "agent_end", session_id: "session-a", cwd: h.ctx.cwd,
        event_id: payload.event_id, last_assistant_message: "Final reply.", stop_reason: "stop",
      });
      assert.match(payload.event_id, /^[a-f0-9-]{36}$/);
      h.close();
    });
  }
});

test("only terminal rounds notify; continuations, aborts, tool calls and subagents stay silent", async (t) => {
  for (const agent of ["pi", "omp"]) {
    await t.test(agent, async (t) => {
      const h = await harness(t, agent);
      const end = (data = {}) => {
        h.emit("agent_end", { messages: [assistant()], ...data });
        if (agent === "pi") h.emit("agent_settled", { aborted: false });
      };
      for (const reason of ["aborted", "toolUse"]) {
        h.emit("agent_start");
        end({ messages: [assistant("", reason)] });
        h.tick();
      }
      h.emit("agent_start");
      end({ willContinue: true });
      h.tick();
      h.emit("agent_start");
      h.pending(true);
      end();
      h.tick();
      h.pending(false);
      h.emit("agent_start");
      end();
      h.pending(true); // A different extension queues a follow-up after our handler.
      h.tick();
      h.pending(false);
      h.emit("agent_start");
      end({ messages: [{ role: "user", content: "no assistant" }] });
      h.tick();
      h.emit("agent_start");
      end({ messages: [assistant("Success."), assistant("", "aborted")] });
      h.tick();
      assert.equal(h.calls.length, 0);

      if (agent === "omp") {
        h.emit("agent_start");
        h.idle(false);
        end();
        h.tick(1000);
        assert.equal(h.calls.length, 0);
        // Settlement can outlast many rechecks without losing the completion.
        h.idle(true);
        h.tick();
        assert.equal(h.calls.length, 1);
        h.close();
        const subCtx = { ...h.ctx, agent: { kind: "sub", depth: 0 } };
        h.emit("agent_start", {}, subCtx);
        h.emit("agent_end", { messages: [assistant()] }, subCtx);
        h.tick();
        assert.equal(h.calls.length, 1);
      } else {
        // Pi 1.2.0's agent_end context is still busy until handlers return.
        h.emit("agent_start");
        h.idle(false);
        end();
        h.idle(true);
        h.tick();
        assert.equal(h.calls.length, 1);
        h.close();
      }
      h.emit("agent_start");
      end({ messages: [assistant("Earlier success."), assistant("", "error")] });
      h.tick();
      const failure = h.calls.at(-1).payload;
      assert.equal(failure.stop_reason, "error");
      assert.equal(failure.last_assistant_message, "");
      assert.equal(JSON.stringify(failure).includes("private provider error"), false);
    });
  }
});

test("OMP agent_end may be busy until the final idle or shutdown boundary", async (t) => {
  for (const boundary of ["timer", "shutdown"]) {
    await t.test(boundary, async (t) => {
      const h = await harness(t, "omp");
      h.ctx.hasUI = false;
      h.emit("agent_start");
      h.idle(false);
      h.emit("agent_end", { messages: [assistant()], willContinue: false });
      assert.equal(h.calls.length, 0);
      h.idle(true);
      if (boundary === "timer") {
        h.tick();
        assert.equal(h.calls.length, 1);
        h.close();
      } else {
        const flushing = h.shutdown();
        assert.equal(h.calls.length, 1);
        h.close();
        await flushing;
      }
      assert.equal(h.calls[0].payload.stop_reason, "stop");
    });
  }
});

test("new runs, retries and session switches cancel stale completions; each round has its own ID", async (t) => {
  const h = await harness(t);
  const end = () => h.emit("agent_end", { messages: [assistant()] });
  h.emit("agent_start");
  end();
  h.emit("agent_start");
  h.tick();
  assert.equal(h.calls.length, 0);
  end();
  h.session("session-b"); // Also revalidate the session without a switch callback.
  h.tick();
  assert.equal(h.calls.length, 0);
  h.emit("session_switch");
  h.emit("agent_start");
  end();
  h.emit("auto_retry_start");
  h.tick();
  assert.equal(h.calls.length, 0);
  h.emit("agent_start");
  end();
  h.tick();
  assert.equal(h.calls.length, 1);
  const first = h.calls[0].payload.event_id;
  assert.equal(h.calls[0].payload.session_id, "session-b");
  end(); // A duplicate terminal event in the same run is not a new round.
  h.tick();
  assert.equal(h.calls.length, 1);
  h.close();
  h.emit("agent_start");
  end();
  h.tick();
  assert.equal(h.calls.length, 2);
  assert.notEqual(h.calls[1].payload.event_id, first);
  h.close();
  h.emit("agent_start");
  h.emit("agent_end", { messages: [assistant()], willContinue: true });
  h.emit("session_shutdown");
  h.tick();
  assert.equal(h.calls.length, 2);
});

test("Pi 1.2 waits for authoritative agent_settled, never for an intermediate agent_end", async (t) => {
  const h = await harness(t, "pi", true);
  h.emit("agent_start");
  h.idle(false);
  h.emit("agent_end", { messages: [assistant("Intermediate reply.")] });
  h.idle(true);
  h.tick(30_000); // Retrying/compacting can outlast any fixed debounce.
  assert.equal(h.calls.length, 0);
  h.emit("agent_start");
  h.emit("agent_end", { messages: [assistant("Final reply.")] });
  h.emit("agent_settled", { aborted: false });
  h.tick();
  assert.equal(h.calls.length, 1);
  assert.equal(h.calls[0].payload.last_assistant_message, "Final reply.");
  h.close();
  h.emit("agent_settled", { aborted: false });
  h.tick();
  assert.equal(h.calls.length, 1);
  h.emit("agent_start");
  h.emit("agent_end", { messages: [assistant()] });
  h.emit("agent_settled", { aborted: true });
  h.tick();
  assert.equal(h.calls.length, 1);
});

test("OMP approvals and ask notify after two seconds using only safe metadata", async (t) => {
  const h = await harness(t);
  h.emit("agent_start");
  h.idle(false);
  h.emit("tool_approval_requested", {
    sessionId: "session-a", toolCallId: "approval-1", toolName: "bash secret",
    reason: "private command", args: { secret: "private args" },
  });
  h.tick(1999);
  assert.equal(h.calls.length, 0);
  h.tick(1);
  assert.equal(h.calls.length, 1);
  const payload = h.calls[0].payload;
  assert.deepEqual(payload, {
    hook_event_name: "input_required", session_id: "session-a", cwd: h.ctx.cwd,
    event_id: payload.event_id, message: "Tool approval required.",
  });
  h.close();
  h.emit("tool_approval_resolved", { sessionId: "session-a", toolCallId: "approval-1" });
  h.emit("tool_execution_start", {
    toolName: "ask", toolCallId: "ask-1", args: { question: "private question" },
  });
  h.tick(2000);
  assert.equal(h.calls.length, 2);
  assert.equal(h.calls[1].payload.message, "User input required.");
  assert.notEqual(h.calls[1].payload.event_id, payload.event_id);
  h.emit("tool_execution_end", { toolName: "ask", toolCallId: "ask-1" });
});

test("fast tools, resolved approvals, non-UI sessions and session/run changes cancel blockers", async (t) => {
  const h = await harness(t);
  const approval = (id = "approval") => h.emit("tool_approval_requested", {
    sessionId: "session-a", toolCallId: id, toolName: "bash",
  });
  const ask = (id = "ask") => h.emit("tool_execution_start", { toolName: "ask", toolCallId: id });
  h.emit("agent_start");
  approval();
  h.tick(1000);
  h.emit("tool_approval_resolved", { sessionId: "session-a", toolCallId: "approval" });
  ask();
  h.emit("tool_execution_end", { toolName: "ask", toolCallId: "ask" });
  h.tick(3000);
  h.ctx.hasUI = false;
  approval("no-ui");
  ask("no-ui");
  h.tick(3000);
  h.ctx.hasUI = true;
  approval("new-run");
  h.emit("agent_start");
  h.tick(3000);
  ask("switched");
  h.session("session-b");
  h.tick(3000);
  h.emit("session_switch");
  h.emit("tool_approval_requested", { sessionId: "session-a", toolCallId: "foreign-session" });
  const subCtx = { ...h.ctx, agent: { kind: "sub", depth: 0 } };
  h.emit("tool_execution_start", { toolName: "ask", toolCallId: "sub" }, subCtx);
  h.tick(3000);
  assert.equal(h.calls.length, 0);
  ask("shutdown");
  h.emit("session_shutdown");
  h.tick(3000);
  assert.equal(h.calls.length, 0);
});

test("Pi uses real UI-prompt events, never invented approval or ask-tool events", async (t) => {
  const h = await harness(t, "pi", true);
  assert.equal(h.handlers.has("tool_approval_requested"), false);
  assert.equal(h.handlers.has("tool_execution_start"), false);
  h.emit("agent_start");
  h.emit("ui_prompt_start", { kind: "confirm", title: "secret command", reason: "ui_prompt" });
  h.tick(1999);
  h.emit("ui_prompt_end", { kind: "confirm" });
  h.tick(10);
  assert.equal(h.calls.length, 0);
  h.emit("ui_prompt_start", { kind: "input", title: "private question" });
  h.tick(2000);
  assert.equal(h.calls.length, 1);
  assert.equal(h.calls[0].payload.message, "User input required.");
  assert.equal(JSON.stringify(h.calls[0].payload).includes("private"), false);
});

test("notifier processes are serialized, time-bounded and stale queued requests are dropped", async (t) => {
  const h = await harness(t);
  h.emit("agent_start");
  for (const toolCallId of ["one", "two", "three"]) {
    h.emit("tool_approval_requested", { sessionId: "session-a", toolCallId });
  }
  h.tick(2000);
  assert.equal(h.children.length, 1);
  h.emit("tool_approval_resolved", { sessionId: "session-a", toolCallId: "two" });
  h.close(0);
  assert.equal(h.children.length, 2); // "two" is skipped; only "three" spawns.
  h.tick(29_999);
  assert.notEqual(h.children[1].killed, true);
  h.tick(1);
  assert.equal(h.children[1].killed, true);
  h.emit("agent_start");
  h.emit("agent_end", { messages: [assistant()] });
  h.tick();
  assert.equal(h.children.length, 3);
  h.close(2);
});

test("bounded blockers cannot create unlimited subprocesses or delayed timers", async (t) => {
  const h = await harness(t);
  h.emit("agent_start");
  for (let i = 0; i < 1000; i++) {
    h.emit("tool_execution_start", { toolName: "ask", toolCallId: `ask-${i}` });
  }
  h.tick(2000);
  assert.equal(h.children.length, 1);
  // 8 outstanding blockers maximum; drain through the public process boundary.
  for (let i = 0; i < 8; i++) h.close(i);
  assert.equal(h.children.length, 8);
  assert.equal(new Set(h.calls.map((call) => call.payload.event_id)).size, 8);
});

test("spawn failures, EPIPE and broken contexts never reject an extension handler", async (t) => {
  const h = await harness(t);
  h.emit("agent_start");
  h.emit("agent_end", { messages: [assistant()] });
  h.tick();
  h.children[0].stdin.emit("error", new Error("EPIPE"));
  h.children[0].emit("error", new Error("ENOENT"));
  h.emit("agent_start");
  h.emit("agent_end", { messages: [assistant("x".repeat(100_000))] });
  h.tick();
  assert.ok(h.calls.at(-1).payload.last_assistant_message.length <= 4096);
  h.close();
  t.mock.method(childProcess, "spawn", () => { throw new Error("spawn unavailable"); });
  syncBuiltinESMExports();
  h.emit("agent_start");
  h.emit("agent_end", { messages: [assistant()] });
  assert.doesNotThrow(() => h.tick());
  h.emit("agent_end", { messages: [assistant()] }, {
    ...h.ctx, sessionManager: { getSessionId() { throw new Error("disposed"); } },
  });
});

test("headless terminal completion survives immediate shutdown with a bounded flush", async (t) => {
  for (const agent of ["pi", "omp"]) {
    for (const stopReason of ["stop", "error"]) {
      await t.test(`${agent}/${stopReason}`, async (t) => {
        const h = await harness(t, agent);
        h.ctx.hasUI = false;
        h.emit("agent_start");
        h.emit("agent_end", { messages: [assistant("Final reply.", stopReason)] });
        if (agent === "pi") {
          h.emit("agent_settled", { aborted: false });
          assert.equal(h.calls.length, 1, "Pi's authoritative settle starts sender immediately");
        }
        const flushing = h.shutdown(agent === "pi" ? { reason: "quit" } : {});
        assert.ok(flushing instanceof Promise);
        assert.equal(h.calls.length, 1);
        assert.equal(h.calls[0].payload.stop_reason, stopReason);
        assert.notEqual(h.children[0].killed, true);
        let finished = false;
        flushing.then(() => { finished = true; });
        await Promise.resolve();
        assert.equal(finished, false);
        h.close();
        await flushing;
        assert.equal(finished, true);
      });
    }
  }
});

test("shutdown flush deadline kills a hung final sender at 30 seconds, not earlier", async (t) => {
  const h = await harness(t, "pi");
  h.ctx.hasUI = false;
  h.emit("agent_start");
  h.emit("agent_end", { messages: [assistant()] });
  h.emit("agent_settled", { aborted: false });
  const flushing = h.shutdown({ reason: "quit" });
  assert.ok(flushing instanceof Promise);
  h.tick(29_999);
  assert.notEqual(h.children[0].killed, true);
  h.tick(1);
  await flushing;
  assert.equal(h.children[0].killed, true);
});

test("reload, replacement, aborted and unsettled Pi shutdown never flush old candidates", async (t) => {
  for (const reason of ["quit", "reload", "new", "resume", "fork"]) {
    await t.test(reason, async (t) => {
      const h = await harness(t, "pi");
      h.ctx.hasUI = false;
      h.emit("agent_start");
      h.emit("agent_end", { messages: [assistant()] });
      await h.shutdown({ reason });
      h.tick(30_000);
      assert.equal(h.calls.length, 0, "agent_end alone is never a final Pi settle");
    });
  }
  const h = await harness(t, "omp");
  h.ctx.hasUI = false;
  h.emit("agent_start");
  h.emit("agent_end", { messages: [assistant()], willContinue: true });
  await h.shutdown();
  h.tick(30_000);
  assert.equal(h.calls.length, 0);
});

test("reload cancels queued final completion and shutdown drops blocked senders", async (t) => {
  const h = await harness(t, "pi");
  h.emit("agent_start");
  h.emit("ui_prompt_start", { kind: "input" });
  h.tick(2000);
  assert.equal(h.calls[0].payload.hook_event_name, "input_required");
  h.emit("agent_end", { messages: [assistant()] });
  h.emit("agent_settled", { aborted: false });
  await h.shutdown({ reason: "reload" });
  assert.equal(h.children[0].killed, true);
  h.tick(30_000);
  assert.equal(h.calls.length, 1, "reload never starts the queued old completion");
});

test("global and project factories share one notifier owner per agent/session", async (t) => {
  const h = await harness(t, "pi");
  const project = h.clone();
  for (const runtime of [h, project]) {
    runtime.emit("agent_start");
    runtime.emit("agent_end", { messages: [assistant()] });
    runtime.emit("agent_settled", { aborted: false });
  }
  h.tick();
  assert.equal(h.calls.length, 1);
  const otherCtx = { ...h.ctx, sessionManager: { getSessionId: () => "session-other" } };
  project.emit("agent_start", {}, otherCtx);
  project.emit("agent_end", { messages: [assistant()] }, otherCtx);
  project.emit("agent_settled", { aborted: false }, otherCtx);
  h.tick();
  assert.equal(h.calls.length, 2);
  assert.equal(h.calls[1].payload.session_id, "session-other");
  project.emit("session_shutdown", { reason: "reload" }, otherCtx);
  h.shutdown({ reason: "reload" });
  const reloaded = h.clone();
  reloaded.emit("agent_start");
  reloaded.emit("agent_end", { messages: [assistant()] });
  reloaded.emit("agent_settled", { aborted: false });
  h.tick();
  assert.equal(h.calls.length, 3, "reload releases notifier ownership");
});

test("invalid in-flight blocked senders are killed on resolve, new run and session change", async (t) => {
  for (const cancel of ["resolve", "run", "session"]) {
    await t.test(cancel, async (t) => {
      const h = await harness(t, "omp");
      h.emit("agent_start");
      h.emit("tool_approval_requested", { sessionId: "session-a", toolCallId: "old" });
      h.tick(2000);
      assert.equal(h.children.length, 1);
      if (cancel === "resolve") {
        h.emit("tool_approval_resolved", { sessionId: "session-a", toolCallId: "old" });
      } else if (cancel === "run") {
        h.emit("agent_start");
      } else {
        h.session("session-new");
        h.emit("session_switch");
      }
      assert.equal(h.children[0].killed, true);
      h.emit("tool_execution_start", { toolName: "ask", toolCallId: "new" });
      h.tick(2000);
      assert.equal(h.children.length, 2);
      assert.notEqual(h.children[1].killed, true);
      h.close(0); // Late close of the cancelled process cannot finish the new sender.
      assert.notEqual(h.children[1].killed, true);
      h.close(1);
    });
  }
});

test("an obsolete shutdown flush cannot cancel a newer valid run", async (t) => {
  const h = await harness(t, "omp");
  h.emit("agent_start");
  h.emit("agent_end", { messages: [assistant()] });
  h.tick();
  const oldFlush = h.shutdown();
  h.emit("agent_start");
  h.emit("tool_execution_start", { toolName: "ask", toolCallId: "new-run" });
  h.tick(2000);
  assert.equal(h.children.length, 2);
  await oldFlush;
  assert.notEqual(h.children[1].killed, true);
  h.close(1);
});
