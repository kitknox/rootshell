# rootshell push

End-to-end encrypted push notifications from your computers to the rootshell
app. `rootshell-notify` is a small, dependency-free Go binary that AI coding
agents (Claude Code, Codex, Pi, Oh My Pi and Hermes) call from their hooks, extensions or plugins
when a turn finishes. Supported input requests also notify when the agent is
waiting on you. It works as a plain `send` command from scripts too.

The relay at `push.rootshell.com` is stateless and only ever sees
ciphertext. Titles, summaries and routing hints are sealed with a
post-quantum hybrid key (X-Wing: ML-KEM-768 + X25519) that lives on your
device. See [PROTOCOL.md](PROTOCOL.md).

## Quick start

In rootshell open Settings > Notifications > Push Notifications >
Pair a computer. The app shows a pairing bundle (`rspair1....`) and a
one-liner to paste into your terminal:

```sh
curl -fsSL https://push.rootshell.com/install.sh | sh -s -- --pair 'rspair1....'
```

This installs `rootshell-notify` into `~/.local/bin`, pairs with the device,
sends a test notification, and installs the hook for every agent it finds
(`~/.claude` for Claude Code, `~/.codex` for Codex, `~/.pi/agent` for Pi,
`~/.omp/agent` for Oh My Pi, `~/.hermes` for Hermes). If the binary is already at the current version
the download is skipped.

Installer options:

| Flag              | Effect                                                |
|-------------------|-------------------------------------------------------|
| `--pair <bundle>` | Run `rootshell-notify setup` after installing         |
| `--hooks <spec>`  | `auto` (default), a comma-separated list of `claude-code,codex,pi,omp,hermes`, or `none` |
| `--project`       | Install into `./.claude`, `./.codex`, `./.pi`, `./.omp` or `./.hermes` |
| `--system`        | Install to `/usr/local/bin` (sudo if needed)          |

The script downloads one binary, verifies its SHA-256 against a table
embedded in the script, copies it into place, and (with `--pair`) runs
`rootshell-notify setup`. Nothing else runs. Pin a version with
`ROOTSHELL_NOTIFY_VERSION=x.y.z`.

Once installed, `rootshell-notify upgrade` is the way to update (see
[Upgrading](#upgrading)); the curl one-liner is only needed to bootstrap.

If the binary is already installed, `setup` pairs and installs hooks on its
own:

```sh
rootshell-notify setup --pair 'rspair1....'                # hooks: auto
rootshell-notify setup --pair 'rspair1....' --hooks pi,omp # choose specific agents
echo "$BUNDLE" | rootshell-notify setup --hooks none       # bundle on stdin
```

Hook installs are idempotent; a failed hook install is reported but does
not undo the pairing. The sections below cover the same steps by hand.

## Install only

```sh
curl -fsSL https://push.rootshell.com/install.sh | sh
```

Without `--pair` the script only installs the binary and prints the next
steps.

## Pair a device

1. In rootshell open Settings > Notifications > Push Notifications >
   Pair a computer. The app registers with the relay and shows a pairing
   bundle (`rspair1....`) containing the relay URL, a sender credential and
   your device's public key.
2. Choose "Type into Current Terminal" to have rootshell type
   `rootshell-notify pair <bundle>` into the focused pane (review, then press
   Return), or copy the command and run it yourself:

   ```sh
   rootshell-notify pair            # paste when prompted
   echo "$BUNDLE" | rootshell-notify pair
   ```

3. A test notification arrives on the device. `rootshell-notify devices`
   lists pairings and, in a terminal, lets you toggle agent notifications by
   entering a device number. `unpair <label>` removes a pairing.

To change agent-hook recipients directly or from a script:

```sh
rootshell-notify devices off "Desk iPad"
rootshell-notify devices toggle "Test iPhone"
rootshell-notify devices on "Desk iPad"
```

Turning a device off suppresses automatic notifications from all four agents.
It stays paired, and `test`, `send`, and `send --device` can still reach it.

Pairings are stored in `~/.config/rootshell-push/config.json` (mode 0600).
Override the path with `ROOTSHELL_PUSH_CONFIG`.

Sender credentials are bound to the device's current registration with the
relay. If the device re-registers (reinstall, new push token), old
credentials stop working and the relay answers `410`; the hook logs
"device <label> is no longer registered". Run `rootshell-notify unpair
<label>` and pair again. Pairing the same label again replaces the old entry.

## Hook up an agent

```sh
rootshell-notify install claude-code     # merges into ~/.claude/settings.json
rootshell-notify install codex           # merges into ~/.codex/hooks.json
rootshell-notify install pi              # ~/.pi/agent/extensions/rootshell-push.ts
rootshell-notify install omp             # ~/.omp/agent/extensions/rootshell-push.ts
rootshell-notify install hermes          # ~/.hermes/plugins/rootshell-push/
hermes plugins enable rootshell-push     # Hermes plugins require explicit activation
```

Add `--project` for project-local installation. Claude Code and Codex use
tagged JSON entries; Pi and OMP use an embedded extension installed into
`.pi/extensions/rootshell-push.ts` or `.omp/extensions/rootshell-push.ts`.
Installs are idempotent and preserve unrelated hooks and extensions. Managed
files are backed up on their first update; an unrelated file at the extension's
destination is never overwritten. Restart the agent or reload extensions
after installation or an upgrade.

Installed commands identify their agent explicitly; hook payload fields are
never used to guess which agent produced an event.

Codex requires you to trust new hooks: run `codex` then `/hooks`, review the
rootshell entry and mark it trusted. The installer never writes
`trusted_hash` or edits `config.toml`.

Codex can cancel asynchronous hooks when a one-shot `exec` exits, so its Stop
hook is synchronous. The sender only hands the payload to a detached child
process and returns, so interactive turns do not wait for delivery.

Plugin bundles for both tools live in [plugins/](plugins/).

### What you get

| Agent       | Event                                             | Status  |
|-------------|---------------------------------------------------|---------|
| Claude Code | Stop                                              | done    |
| Claude Code | Notification: permission, elicitation, needs input| blocked |
| Claude Code | Notification: idle, agent completed               | done    |
| Claude Code | PreToolUse: AskUserQuestion (first question text)| blocked |
| Codex       | Stop (hooks) or legacy `notify` turn complete     | done    |
| Pi          | `agent_settled`, final successful assistant response | done    |
| OMP         | `agent_end`, no continuation or queued work, successful assistant response | done |
| Pi / OMP    | Final assistant response with `stopReason=error` | failed  |
| Pi          | Interactive UI prompt still pending after 2 seconds | blocked |
| OMP         | Interactive `ask` still running after 2 seconds   | blocked |
| OMP         | Tool approval request still pending after 2 seconds | blocked |
| Hermes      | `on_session_end`, completed interactive turn       | done    |
| Hermes      | Failed or incomplete interactive turn             | failed  |
| Hermes      | Human input request (questions and approval)       | blocked |

Claude Code subagent stops, re-entrant stop hooks, other PreToolUse tools and other
notification types are ignored. The hooks never answer or approve anything;
they only report.

Codex's `PermissionRequest` event occurs before automatic or user review has
resolved the request, so rootshell does not treat it as a blocker. For Codex
running in a rootshell terminal, the app's on-device screen detector sends the
blocked notification only while an approval prompt is visibly waiting.

### Pi and Oh My Pi extensions

Requires **Earendil Pi 1.2.0 or later** (`@earendil-works/pi-coding-agent`)
and **Oh My Pi 18.10.3 or later**. Pi uses its authoritative `agent_settled`
notification boundary, introduced after the older Pi lifecycle API; this
adapter is not a completion integration for legacy Pi versions.

The extensions observe lifecycle events and pipe normalized JSON to
`rootshell-notify hook --agent pi` or `--agent omp`. They produce native
`kind=agent` notifications, so device hook toggles, encryption, foreground
suppression, session grouping and terminal routing work the same way as
Claude Code and Codex. They do not register tools, answer questions or approve
commands. Delivery does not block model event handlers, uses a bounded queue
and subprocess timeout, and never fails an agent turn. Normal shutdown may
wait up to 30 seconds for an already-confirmed completion or failure, so
one-shot commands do not discard their final notification. Reloads and
session replacements do not flush old candidates. A process-wide owner per
agent/session prevents duplicate pushes when both user and project copies
are loaded.

A completion means the assistant turn ended, not that a larger task succeeded.
Aborted responses are silent. Pi waits for `agent_settled`; OMP's
`willContinue`, idle state and pending queued messages suppress intermediate
completions. OMP's boundary does not prove that unrelated background jobs or
a larger goal have finished. OMP may still be busy during `agent_end`, so the
extension retains a candidate and rechecks idle/pending state every 100 ms
(for up to a minute) or during normal shutdown. Delayed and queued input
reminders are cancelled when the request resolves, a new run starts or the
session changes; already submitted pushes cannot be recalled by the
extension. OMP ask-tool events are only an approximation of a visible
dialog: headless calls and requests resolved within two seconds are ignored.
Pi observes its real `ui_prompt_start` / `ui_prompt_end` events, not invented
ask or approval events; these do not cover arbitrary third-party permission
interfaces.

User-level directory overrides follow the agents' settings:
`PI_CODING_AGENT_DIR` for Pi, and OMP's `PI_CONFIG_DIR`, `OMP_PROFILE`
(legacy `PI_PROFILE`) and `PI_CODING_AGENT_DIR`. Project-local installation
ignores user overrides. Keep Pi and OMP in separate configuration directories.
If both would load the same `rootshell-push.ts`, `setup` and `upgrade` reject
the ambiguous destination before making changes; use separate directories or
select only the intended runtime with `--hooks pi` or `--hooks omp`.

The extensions use the running agent's session context and inherit the
sender's existing pane/tmux/herdr environment. Without a matching terminal
route the notification can still arrive, but a tap cannot recreate a session.
Pi/OMP thumbnails require a rootshell app release bundling the new logo
resources; older apps can still decrypt and display the notification text.

### Hermes plugin

The installer writes a dependency-free Python plugin and YAML manifest to
`~/.hermes/plugins/rootshell-push/`, or under `HERMES_HOME` when set. Enable it
with `hermes plugins enable rootshell-push` and restart Hermes. `status` reports
whether the managed files are current; plugin activation is shown by
`hermes plugins list`. The installer does not rewrite Hermes's YAML config.
Project installation uses `./.hermes/plugins/rootshell-push/`; Hermes also
requires `HERMES_ENABLE_PROJECT_PLUGINS=1` to discover project plugins.

The plugin caches the final `post_llm_call` response, then waits for
`on_session_end` to classify the turn as done or failed. Interrupted turns,
session cleanup and messaging/gateway platforms do not notify. Only interactive
`cli`, `tui`, `desktop` and `acp` turns are eligible. Newer Hermes versions use
`on_human_input_request` and `on_human_input_resolved`; older versions fall
back to `pre_approval_request` and `post_approval_response` (human surfaces
only). Like the Pi and OMP extensions, a waiting notification is sent only
if the request is still unanswered after 2 seconds. Clarify-question waiting notifications require the newer
human-input observer; legacy pre-tool calls cannot establish that a human
actually needs to respond. Automated smart approvals are silent. Plugins only
observe these events; they never answer or approve them.

Each turn or human request has a deduplication ID. One background thread runs
the sender off the hook callback. At most 8 deliveries wait in its queue;
waiting notifications are shed before completions. Resolving a request, a new
turn or a completion drops matching waiting notifications, whether queued or
already being sent. Normal interpreter exit drains the queue for up to 10
seconds, so one-shot completions survive shutdown without a slow relay
holding Hermes open. Each sender is bounded to 30 seconds;
missing binaries and delivery errors cannot fail the Hermes turn.
Managed Python and manifest files carry content hashes: installation and
removal refuse foreign or edited files, preserve unrelated plugin files,
and back up the first managed version before updates or removal.

## What is sent

- Title: `[<hostname>] <agent> · <project dir>`, for example
  `[build-mac] Pi · app`. The hostname comes from the existing sender route,
  with the username omitted; it is visible without opening the notification.
  Titles are limited to 120 characters. Presentation text is shortened further
  if needed to fit the encrypted header's byte budget, without trimming the route.
- Body: the first sentence or two (at most 200 characters) of the last
  assistant message with code blocks, links and URLs stripped, or the
  notification text, question, or pending command when the agent is blocked.
- Routing hints so rootshell can jump to the right place: the rootshell
  pane id, tmux pane and session, herdr terminal and server namespace,
  `user@host`, and the working directory.
- A per-session thread id and a per-event id (both hashes) for grouping and
  deduplication.

Never sent: your prompts, terminal output, transcripts, file contents, or
environment variables. Before sealing, the body is scrubbed for
credential-shaped text (`api_key=...`, `Bearer ...`, AWS/GitHub/OpenAI/
Anthropic/Slack key formats, PEM private keys, long hex or base64 runs).

Everything above is encrypted to the device before leaving your computer.

### Herdr routing

Herdr needs no additional hook installation. Inside a herdr pane,
`rootshell-notify` uses `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` to look up the
stable terminal ID. It works with the Rootshell fork and stock herdr exposing
the terminal ID API, without invoking the herdr binary.

With the updated rootshell app, regular and fallback control modes route taps
to the originating terminal, including after pane moves. Existing viewed-pane
and duplicate-agent-alert suppression apply. When running the ordinary herdr
TUI in a regular rootshell tab, taps continue returning to that exact tab using
its rootshell surface UUID. The app does not change the TUI's internal pane
selection. A failed herdr lookup never prevents sending a notification.

An unresolved control route opens rootshell and can resolve during reconnect
for up to 60 seconds; it never guesses a pane from its name or working directory.

## Custom notifications

```sh
rootshell-notify send --title "Deploy finished" --body "prod is green" --status done
rootshell-notify send --title "Build" --status failed --device "Test iPhone" --priority high
```

Notifications are text only: a title, an optional body and routing hints.

## Upgrading

```sh
rootshell-notify upgrade            # install the latest release, refresh hooks
rootshell-notify upgrade --check    # only report; exit 3 if an update is available
rootshell-notify status             # also shows whether an update is available
```

`upgrade` fetches the latest version from `push.rootshell.com` (falling back
to GitHub releases), verifies its SHA-256, replaces the running binary in
place, runs the new binary's `version` to confirm it works, and then
refreshes the agent hooks the same way `setup --no-pair` does. Pairings are
never touched. Options: `--version x.y.z` pins a release, `--hooks
auto|claude-code,codex,pi,omp,hermes|none` controls the hook refresh, `--server URL`
overrides the release server.

If the binary lives in `/usr/local/bin` (installed with `--system`), the
replace needs write access to that directory: run
`sudo rootshell-notify upgrade`.

The installer still works for upgrades and is equivalent:

```sh
curl -fsSL https://push.rootshell.com/install.sh | sh -s -- --hooks auto
```

## Uninstall

```sh
rootshell-notify uninstall claude-code
rootshell-notify uninstall codex
rootshell-notify uninstall pi
rootshell-notify uninstall omp
hermes plugins disable rootshell-push
rootshell-notify uninstall hermes
rootshell-notify uninstall claude-code --purge   # also deletes ~/.config/rootshell-push
rm ~/.local/bin/rootshell-notify
```

Uninstall removes only tagged rootshell entries or its managed extension file
and leaves other hooks and extensions untouched. Revoke the sender on the device side from the same Settings
screen; the device then ignores pushes from that sender.

## Troubleshooting

- `rootshell-notify status` shows the binary location, config, paired
  devices, each device's notification setting, and whether each agent hook is
  installed.
- The hook never writes to stdout or fails the agent; errors go to
  `~/.config/rootshell-push/hook.log` (rotated at 1 MiB).
- `ROOTSHELL_PUSH_DEBUG=1 rootshell-notify hook --agent codex < payload.json`
  also prints errors to stderr. Use `--agent claude-code` for Claude Code
  payloads.
- `rootshell-notify test` sends a test notification to every device.
- Hooks require `rootshell-notify` on the PATH seen by the agent. If you
  installed to `~/.local/bin`, make sure your login shell exports it.

## Building from source

Requires Go 1.26 or later. The sender uses the standard library only. Running
the Pi/OMP extension behavior tests also requires Node.js 22 or later; the
installed extensions run in their agent's own Node.js/Bun runtime and have no
additional package dependencies.
Hermes plugin behavior tests require Python 3.9 or later; the installed plugin
uses Hermes's existing Python runtime and standard library only.

```sh
cd push
make build                 # ./rootshell-notify for the host
make test
make release VERSION=0.1.0 # dist/0.1.0/ with all platforms, SHA256SUMS, install.sh
```

An opt-in loader smoke check uses installed official Pi/OMP runtimes with an
isolated HOME and no model request or push delivery:

```sh
ROOTSHELL_PI_PACKAGE=/path/to/@earendil-works/pi-coding-agent \
ROOTSHELL_OMP_BIN="$(command -v omp)" node installer/loader-smoke.mjs
```

This checks extension loading and event registration, not a model turn or
physical-device notification delivery.

An opt-in Hermes smoke check uses the installed Hermes loader and runs a real
agent turn against a local OpenAI-compatible fixture. It checks final response,
completion classification, plugin registration and sender subprocess delivery,
without accessing the real model or relay:

```sh
HERMES_AGENT_DIR="$HOME/.hermes/hermes-agent" \
HERMES_DISABLE_LAZY_INSTALLS=1 \
  "$HOME/.hermes/hermes-agent/venv/bin/python" \
  installer/hermes-smoke.py ./rootshell-notify
```

Build output under `dist/` is never committed. Releases are built locally
with `make release VERSION=x.y.z`, published to `push.rootshell.com/releases/`
with `deploy/publish-client.sh` from the relay repo, and optionally attached
to a GitHub Release tagged `push/vx.y.z` (the installer's fallback source).

## Layout

| Path          | Purpose                                                |
|---------------|--------------------------------------------------------|
| `envelope/`   | HPKE X-Wing sealing and pairing bundles                |
| `config/`     | Paired device store and log file                       |
| `client/`     | Relay HTTP client                                      |
| `hook/`       | Agent payload parsing, summarization, redaction        |
| `installer/`  | Hook file merging, embedded Pi / OMP extensions and Hermes plugin |
| `cmd/rootshell-notify/` | The CLI                                      |
| `plugins/`    | Plugin bundles for Claude Code and Codex               |
