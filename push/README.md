# rootshell push

End-to-end encrypted push notifications from your computers to the rootshell
app. `rootshell-notify` is a small, dependency-free Go binary that AI coding
agents (Claude Code, Codex) call from their hooks when a turn finishes, and
Claude Code also calls when it is waiting on you. It works as a plain `send`
command from scripts too.

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
(`~/.claude` for Claude Code, `~/.codex` for Codex). If the binary is already
at the current version the download is skipped.

Installer options:

| Flag              | Effect                                                |
|-------------------|-------------------------------------------------------|
| `--pair <bundle>` | Run `rootshell-notify setup` after installing         |
| `--hooks <spec>`  | `auto` (default), `claude-code,codex`, or `none`      |
| `--project`       | Install hooks into `./.claude` / `./.codex`           |
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
rootshell-notify setup --pair 'rspair1....' --hooks codex  # or claude-code,codex | none
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

Turning a device off only suppresses automatic notifications from Claude Code
and Codex hooks. It stays paired, and `test`, `send`, and `send --device` can
still reach it.

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
```

Add `--project` to install into `./.claude` or `./.codex` instead. The
installer only appends its own tagged entries, keeps everything else in the
file intact, writes a `.bak` of the original the first time it changes a
file, and is idempotent. Installed commands identify their agent explicitly;
hook payload fields are never used to guess whether an event came from Claude
Code or Codex.

Codex requires you to trust new hooks: run `codex` then `/hooks`, review the
rootshell entry and mark it trusted. The installer never writes
`trusted_hash` or edits `config.toml`.

Plugin bundles for both tools live in [plugins/](plugins/).

### What you get

| Agent       | Event                                             | Status  |
|-------------|---------------------------------------------------|---------|
| Claude Code | Stop                                              | done    |
| Claude Code | Notification: permission, elicitation, needs input| blocked |
| Claude Code | Notification: idle, agent completed               | done    |
| Claude Code | PreToolUse: AskUserQuestion (first question text)| blocked |
| Codex       | Stop (hooks) or legacy `notify` turn complete     | done    |

Subagent stops, re-entrant stop hooks, other PreToolUse tools and other
notification types are ignored. The hooks never answer or approve anything;
they only report.

Codex's `PermissionRequest` event occurs before automatic or user review has
resolved the request, so rootshell does not treat it as a blocker. For Codex
running in a rootshell terminal, the app's on-device screen detector sends the
blocked notification only while an approval prompt is visibly waiting.

## What is sent

- Title: `Claude Code · <project dir>` or `Codex · <project dir>`.
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
auto|claude-code,codex|none` controls the hook refresh, `--server URL`
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
rootshell-notify uninstall claude-code --purge   # also deletes ~/.config/rootshell-push
rm ~/.local/bin/rootshell-notify
```

Uninstall removes only the tagged rootshell entries and leaves other hooks
untouched. Revoke the sender on the device side from the same Settings
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

Requires Go 1.26 or later. Standard library only.

```sh
cd push
make build                 # ./rootshell-notify for the host
make test
make release VERSION=0.1.0 # dist/0.1.0/ with all platforms, SHA256SUMS, install.sh
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
| `installer/`  | Claude Code / Codex hook file merging                  |
| `cmd/rootshell-notify/` | The CLI                                      |
| `plugins/`    | Plugin bundles for Claude Code and Codex               |
