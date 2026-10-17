// Opt-in smoke test against installed official loaders; never prompts a model.
// ROOTSHELL_PI_PACKAGE=/path/to/@earendil-works/pi-coding-agent
// ROOTSHELL_OMP_BIN=/path/to/omp node installer/loader-smoke.mjs
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

if (process.argv[2] === "--pi-child") {
  const [packageDir, extension, cwd] = process.argv.slice(3);
  const pkg = JSON.parse(await readFile(join(packageDir, "package.json"), "utf8"));
  const { loadExtensions } = await import(pathToFileURL(join(packageDir, "dist/core/extensions/loader.js")));
  const result = await loadExtensions([extension], cwd);
  assert.deepEqual(result.errors, []);
  assert.equal(result.extensions.length, 1);
  const events = [...result.extensions[0].handlers.keys()];
  const types = await readFile(join(packageDir, "dist/core/extensions/types.d.ts"), "utf8");
  for (const event of events) {
    assert.ok(types.includes(`on(event: "${event}"`), `Pi does not declare ${event}`);
  }
  for (const event of ["agent_end", "agent_settled", "ui_prompt_start", "ui_prompt_end"]) {
    assert.ok(events.includes(event), `Pi did not register ${event}`);
  }
  assert.equal(events.includes("tool_approval_requested"), false);
  console.log(JSON.stringify({ agent: pkg.name, version: pkg.version, events }));
} else {
  const piPackage = process.env.ROOTSHELL_PI_PACKAGE;
  const ompBinary = process.env.ROOTSHELL_OMP_BIN;
  assert.ok(piPackage && ompBinary, "Set ROOTSHELL_PI_PACKAGE and ROOTSHELL_OMP_BIN");
  const root = await mkdtemp(join(tmpdir(), "rootshell-loader-smoke-"));
  let child;
  try {
    const source = await readFile(new URL("./adapter.ts", import.meta.url), "utf8");
    const cwd = join(root, "project");
    const home = join(root, "home");
    await mkdir(cwd);
    await mkdir(home);
    const piExtension = join(root, "pi-push.ts");
    const ompExtension = join(root, "omp-push.ts");
    await writeFile(piExtension, source.replaceAll("__ROOTSHELL_AGENT__", "pi"));
    await writeFile(ompExtension, source.replaceAll("__ROOTSHELL_AGENT__", "omp"));
    // No credentials, original HOME/settings, or rootshell-notify on PATH.
    const env = {
      PATH: "/usr/bin:/bin", HOME: home, LANG: "en_US.UTF-8",
      TMPDIR: tmpdir(), PI_CODING_AGENT_DIR: join(home, ".pi/agent"), OMP_PROFILE: "",
    };
    const piOutput = execFileSync(process.execPath, [fileURLToPath(import.meta.url),
      "--pi-child", resolve(piPackage), piExtension, cwd], { cwd, env, encoding: "utf8", timeout: 30_000 });
    console.log(piOutput.trim());

    const marker = join(root, "omp-loaded.json");
    const wrapper = join(root, "omp-loader-probe.ts");
    await writeFile(wrapper, `import adapter from ${JSON.stringify(ompExtension)};
import { writeFileSync } from "node:fs";
export default function(api) {
  const events = [];
  adapter({on(name, handler) { events.push(name); return api.on(name, handler); }});
  writeFileSync(${JSON.stringify(marker)}, JSON.stringify({agent: "omp", events}));
}
`);
    const version = execFileSync(resolve(ompBinary), ["--version"], {
      cwd, env, encoding: "utf8", timeout: 15_000,
    }).trim();
    child = spawn(resolve(ompBinary), ["--mode", "rpc", "--no-session", "--no-extensions",
      "--no-skills", "--no-rules", "--no-lsp", "--no-tools", "--no-prewalk", "--extension", wrapper], {
      cwd, env: { ...env, PI_CODING_AGENT_DIR: join(home, ".omp/agent") },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let output = "";
    let spawnError;
    child.on("error", (error) => { spawnError = error; });
    child.stdout.on("data", (chunk) => { output = (output + chunk).slice(-16_384); });
    child.stderr.on("data", (chunk) => { output = (output + chunk).slice(-16_384); });
    let loaded;
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      try { loaded = JSON.parse(await readFile(marker, "utf8")); break; } catch {}
      if (spawnError || child.exitCode !== null) break;
      await new Promise((done) => setTimeout(done, 50));
    }
    assert.ok(loaded, `OMP factory did not load: ${spawnError ?? output}`);
    for (const event of ["agent_end", "tool_approval_requested", "tool_approval_resolved",
      "tool_execution_start", "tool_execution_end"]) {
      assert.ok(loaded.events.includes(event), `OMP did not register ${event}`);
    }
    assert.equal(loaded.events.includes("agent_settled"), false);
    console.log(JSON.stringify({ ...loaded, version }));
  } finally {
    if (child && child.exitCode === null) {
      child.kill("SIGKILL");
      await new Promise((done) => child.once("close", done));
    }
    await rm(root, { recursive: true, force: true });
  }
}
