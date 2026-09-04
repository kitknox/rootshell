<p align="center">
  <img src="icon.png" alt="rootshell" width="160" height="160">
</p>

<h1 align="center">rootshell</h1>

<p align="center">A free, Metal-accelerated terminal emulator for iPhone, iPad, Vision Pro, and Mac.</p>

**[Website](https://www.rootshell.com)** · **[App Store](https://apps.apple.com/app/rootshell-local-terminal-ssh/id6755794662)** · **[App Store (China)](https://apps.apple.com/app/rootshell-%E6%9C%AC%E5%9C%B0%E7%BB%88%E7%AB%AF-ssh/id6763402687)** · **[Changelog](CHANGELOG.md)** · **[TestFlight Beta](https://testflight.apple.com/join/DEVnH3N2)** · **[macOS Download](https://www.rootshell.com/downloads/rootshell-macos-latest.tar.xz)**

<a href="https://apps.apple.com/app/rootshell-local-terminal-ssh/id6755794662">
  <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83" alt="Download on the App Store" height="60">
</a>

## About

rootshell is an MIT-licensed open source terminal emulator built for Apple platforms. It features GPU-accelerated rendering powered by libghostty, native SSH with post-quantum key exchange, Secure Enclave key storage, VPN tunneling, high performance HEVC screen sharing, an agent inbox that tracks coding agents and long-running commands across sessions, end-to-end encrypted push notifications and coding-agent hooks, a built-in file browser and native git client, a voice-controlled AI agent, cloud provider integration (AWS, Azure, Linode, DigitalOcean), Kubernetes node debugging, native tmux control mode, and Rootshell Roam, a mosh-compatible and tssh (QUIC+KCP) mobile terminal protocol with seamless network roaming and session persistence.

For full feature details, screenshots, and documentation, visit **[www.rootshell.com](https://www.rootshell.com)**.

## Open Source

rootshell is open source under the [MIT License](LICENSE). This repository contains the app source and is also the place to:

- Report bugs
- Request features
- Ask questions about functionality
- Contribute improvements

## Reporting Issues

Before opening an issue, please:

1. **Check existing issues** to avoid duplicates
2. **Update to the latest version** via the App Store, TestFlight, or the macOS download
3. **Include relevant details** when reporting bugs:
   - App version (Settings → About)
   - Device and OS version
   - Steps to reproduce
   - Expected vs actual behavior
   - Any error messages or screenshots

### Issue Templates

- **Bug Report** - Something isn't working correctly
- **Feature Request** - Suggest a new feature or improvement
- **Question** - General questions about usage

## Getting the App

rootshell is **completely free** with no ads, subscriptions, or in-app purchases.

| Platform | Link |
|----------|------|
| iPhone & iPad | [App Store](https://apps.apple.com/app/rootshell-local-terminal-ssh/id6755794662) |
| iPhone & iPad (China) | [App Store (China)](https://apps.apple.com/app/rootshell-%E6%9C%AC%E5%9C%B0%E7%BB%88%E7%AB%AF-ssh/id6763402687) |
| visionOS (beta) | [TestFlight](https://testflight.apple.com/join/DEVnH3N2) |
| macOS (sandboxed, beta) | [TestFlight](https://testflight.apple.com/join/DEVnH3N2) |
| macOS (standalone) | [Direct Download](https://www.rootshell.com/downloads/rootshell-macos-latest.tar.xz) |
| macOS (Homebrew) | See below |

### Install via Homebrew

```bash
brew tap kitknox/rootshell
brew install --cask rootshell
```

## Key Features

### Terminal & Rendering
- **Metal Accelerated** - GPU-accelerated rendering powered by [libghostty](https://github.com/ghostty-org/ghostty) with buttery smooth scrolling
- **450+ Themes** - Curated color themes with live preview, favorites, and per-tab overrides
- **Custom Themes** - Create your own themes with a full color picker, duplicate built-in themes, or import Ghostty theme files. Theme-aware UI tints the entire app
- **Day/Night Themes** - Automatic theme switching based on sunrise/sunset at your location
- **Tabs & Splits** - Resizable split windows within tabs with session persistence
- **Session Restoration** - Tabs, splits, themes, and connections restore automatically on launch
- **Nerd Fonts** - Multiple monospace Nerd Fonts built-in with full icon support
- **Custom Font Import** - Import TTF and OTF fonts with live preview, auto-grouped by family
- **Clickable Hyperlinks** - URLs in terminal output are interactive: Cmd+click or context menu to open
- **Cursor Blink Styles** - 7 animated cursor modes: normal, breathing, heartbeat, neon flicker, pulse, candle, and rootshell
- **Vertical Tab Sidebar** - Tab switcher as a vertical list (⌘⇧\\) with search, keyboard navigation, drag to reorder, context menus on every row, and pinning as a docked, resizable column
- **Grouped Tabs** - Automatic tab sections for local shells, remote hosts (collapsed by subnet), networks, Kubernetes and cloud sessions, and tmux gateways. Group by project or remote host with manual overrides
- **Move Tabs Between Windows** - Drag a tab or a whole group into another window without disconnecting (iPad and Mac)
- **Interactive Tab Swipe** - Swipe between tabs with a live carousel; both terminals stay live during the gesture
- **Tab Exposé** - See live previews of every tab in the current group or project, including Screen Sharing sessions. Pull down from the tab bar or press ⌘⇧A to open it; swipe sideways or use ⌘⌥[ and ⌘⌥] to page between scopes, each of which remembers its last-selected tab. On a tab attached to herdr, tmux, or zellij it opens on that session's own tabs with live, colored previews of every pane; pick one to switch the session, or page over to your app tabs
- **Tab Hover Previews** - Rest the pointer on a tab in the tab bar or the vertical tab sidebar to see a live thumbnail of it in a glass card that slides along as you move between tabs. Pinch to resize it, and click it to open Tab Exposé with that tab highlighted (iPad and Mac; off in Settings if you prefer)
- **Pixel-Smooth Scrollback** - Sub-cell scroll offsets with ProMotion 120 Hz rendering on iPhone
- **HDR Brightness Boost** - Drive the terminal brighter on HDR-capable displays via a floating HUD (⌘⌃B), clamped to display headroom
- **Visor** - Quake-style drop-down terminal summoned by a global hotkey. Slides from any screen edge, joins all Spaces, and floats above other apps (macOS Standalone)
- **Battery Controls** - Cap refresh rate at Auto, Adaptive, 60, or 30 Hz with automatic throttling under Low Power Mode or thermal pressure

### tmux Control Mode
- **Native tmux Integration** - Attach with `tmux -CC` and tmux windows become native tabs, panes become native splits, with native copy/paste, scrollback search, and per-window font size
- **Sessions Dashboard** - Every session with window counts and live tappable previews (⌘⇧S). Switch, create, rename, or kill sessions
- **Window & Pane Administration** - Create, rename, move, link/unlink, and kill windows; zoom, swap, break, and move panes from native menus
- **Seamless Resume** - Control mode sessions reattach automatically across app restarts over tssh
- **Inline Graphics in Panes** - Kitty graphics and iTerm2 inline images render inside panes, with OSC 52 clipboard, OSC 9;4 progress, and notification passthrough
- **Auto-Start Modes** - Off, tmux, or tmux control mode per connection, with configurable tab-close and new-tab actions

### Visual Effects
- **Custom Shaders** - Import shaders directly from Shadertoy with full uniform support
- **Cursor Effects** - Warp, Sweep, Tail, and Blaze cursor animations
- **Background Effects** - Solar (real-time sun tracking), Starfield, Fireflies, Aurora, Nebula, Butterflies, and Jellyfish. Butterflies flock, court, and perch with real physics; both new effects steer around active terminal text
- **Video Backgrounds** - Play looping video files as terminal backgrounds with speed control
- **Photo Backgrounds** - Terminal background from photo library with opacity presets, 9 image filters, and Ken Burns cinematic pan/zoom animation
- **Window Transparency** - Configurable transparency with blur (macOS)

### SSH & Networking
- **Native SSH Client** - Written entirely in Swift with no external dependencies
- **Jump Hosts** - Multi-hop connections through bastion servers
- **SSH Agent Forwarding** - Three approval modes: auto-approve, per-session, per-request
- **Secure Enclave Keys** - Hardware-protected P-256 keys generated in and never leaving the Secure Enclave, alongside software Ed25519, ECDSA, and RSA keys with biometric protection
- **Passkey-Backed Keys** - `sk-ecdsa-sha2-nistp256` keys created, held, and synced by your passkey provider (iCloud Keychain or a third-party manager like 1Password), confirmed per signature with Face ID or Touch ID
- **Post-Quantum SSH** - `mlkem768x25519-sha256` hybrid key exchange and ML-DSA host key signatures for end-to-end post-quantum protection, plus hybrid ML-DSA-44 + Ed25519 user keys (`ssh-mldsa44-ed25519`, interoperable with OpenSSH 10.4) and experimental pure ML-DSA-44/65/87. Also supports `sntrup761x25519-sha512` (OpenSSH 9.0+)
- **Keyboard-Interactive Auth** - RFC 4256 challenge-response (2FA, OTP, PAM) across every launch path, with password-manager AutoFill in auth prompts
- **OpenPubkey SSH (opkssh)** - Sign in with Google, Microsoft, GitLab, or a custom OIDC issuer to create an SSH identity with no key files. Ephemeral key presented as an OpenSSH certificate with silent renewal
- **SSH Certificates** - Attach OpenSSH user certificates (`-cert.pub`) to any saved key for `TrustedUserCAKeys` servers, and validate host keys against trusted certificate authorities with OpenSSH-style host patterns
- **GPG Agent Forwarding** - rootshell acts as your GPG agent over SSH and tssh: sign and decrypt remotely with keys that never leave the device. Reuse existing SSH and YubiKey keys or import GPG keys, with per-connection approval modes
- **SSH Agent Server** - Local OpenSSH-compatible agent exposes saved keys (YubiKey, FIDO2, and opkssh included) to other apps and CLI tools via `SSH_AUTH_SOCK`, with code-signature client authorization and an audit log (macOS Standalone)
- **External SSH Agents** - Use identities from a local ssh-agent, including 1Password, across profiles, jump hosts, agent forwarding, and VPN (macOS Standalone)
- **Port Forwarding** - Local (`-L`), remote (`-R`), and dynamic SOCKS5 (`-D`) forwarding
- **VPN Tunnel** - Any SSH or TSSH profile can act as a system-level VPN, routing all device traffic through the remote server. Per-profile DNS presets, route exclusions, Home Screen/Control Center widgets, Live Activity with real-time stats, Siri Shortcuts support, and an optional Block HTTP/3 (QUIC) setting. On macOS Standalone, runs as a system extension with live status and traffic stats
- **Multipath TCP** - MPTCP over Apple Network.framework maintains subflows on WiFi and cellular simultaneously for near-instant handover (requires Linux 5.6+ on server)
- **Native SCP & SFTP** - Built-in `scp` and interactive `sftp` client with tab completion, glob patterns, and real-time progress
- **Background SSH Tunnels** - Maintain port forwards without a terminal UI with auto-start on launch and byte transfer statistics
- **Auto-start Multiplexer** - Automatically attach to or create a tmux, herdr or zmx session on connect
- **Multiplexer Session Discovery** - After connecting, lists active tmux, zellij, herdr and zmx sessions with per-multiplexer detail and a live terminal preview
- **Tailscale Integration** - Device discovery and SSH to your tailnet with no-auth support
- **Host Shorthand (HSS)** - Pattern-based hostname expansion with YAML configuration
- **Connection Health** - Real-time RTT and packet loss tracking with time series chart and negotiated cryptographic algorithm details
- **Transfer to Nearby Device** - Hand off a live tssh session to another iCloud-paired device; the receiver reattaches to the same tsshd PTY with recent scrollback intact
- **Login Banners** - Server banners shown inline, sanitized against control-sequence injection
- **Scrollback Encryption** - Persisted scrollback encrypted at rest with AES-256-GCM and restored on session reconnect with full ANSI colors

### Screen Sharing
- **High Performance Mode** - Adaptive-bitrate HEVC over UDP, decoded on the GPU through Metal and tuned for Apple silicon. Up to 4K at 60 FPS and 60 Mbps, tracking the network as conditions change, with video and audio encrypted with AES-256 SRTP
- **Nothing to Install** - Connect to any Mac with Screen Sharing enabled in System Settings
- **Match Client Sizing** - The Mac creates a real virtual display sized exactly to your device: no panning, no scaling, no letterboxing, and it follows rotation
- **Remote System Audio** - The remote Mac's audio plays on your device, scheduled against the server's clock for tight A/V sync
- **Standard Mode** - RFB over TCP for constrained networks, VPNs, and non-Mac servers: headless Mac mini, Raspberry Pi, lab boxes, Linux. VNC password, Apple Diffie-Hellman, Apple Remote Desktop, and VeNCrypt authentication
- **Full Input Support** - Tap to click, pinch to zoom, trackpad and mouse with a real pointer and native scrolling, hardware keyboards with physical key identity, and two-way clipboard with optional shared-clipboard sync
- **Login Window Detection** - An on-device vision model spots the macOS login screen and offers to type your saved password. No frame or text read from one ever leaves the device
- **Curtain Mode** - Blank the remote Mac's display while you keep control, with an optional on-screen message (requires Remote Management)
- **Flexible Placement** - A tab, a split beside terminals, a separate window, or full screen, with a draggable HUD for status and controls. Standard mode tunnels over SSH or tssh jump hosts; Macs appear in Browse via Bonjour; profiles sync across devices

### YubiKey & FIDO2
- **YubiKey PIV** - SSH authentication with hardware-bound private keys via NFC or USB-C. Lightning is not enabled because Yubico has not provided MFi approval. Supports RSA, ECDSA, and Ed25519 (firmware 5.7+) with key generation directly on device
- **FIDO2 Security Keys** - Any FIDO2-compatible key (YubiKey 5, SoloKeys, etc.) for touch-to-sign SSH authentication using `webauthn-sk-ecdsa-sha2-nistp256@openssh.com`
- **Key Import** - Import existing SSH private keys to YubiKey PIV slots with optional keychain deletion
- **Smart PIN Caching** - Wired connections cache for the session; NFC connections cache across taps with session batching for multi-tab signing
- **iCloud Sync** - YubiKey references and FIDO2 credential metadata sync across devices; private keys never leave hardware

### Rootshell Roam
- **Mosh-Compatible Protocol** - Native [mosh](https://mosh.org)-compatible implementation built entirely in Swift with SSP (State Synchronization Protocol) support. Works with any standard mosh-server installation
- **tssh/trzsz Support** - [tssh](https://github.com/trzsz/trzsz-ssh) connections with UDP-based terminal transport offering full native scrollback and lower interactive latency than mosh
- **QUIC + KCP Transports** - Choose between QUIC (TLS 1.3, modern congestion control) or KCP (AES-GCM-256) for tssh transport, with rebuilt reconnection engines for fast, stable recovery after network changes. Configure in Settings → Roam → Transport Mode
- **Session Resumption** - Roam sessions survive app termination and device reboots. Credentials are stored in the Keychain and sessions resume automatically.
- **Seamless Network Roaming** - Switch between WiFi and cellular without dropping your session. Handles IP address changes, network transitions, and temporary connectivity loss with a status banner
- **STUN Firewall Traversal** - Automatic NAT hole-punching via STUN to enable connections through stateful firewalls without VPN tunnels
- **Predictive Local Echo** - Keystroke predictions displayed immediately while waiting for server confirmation, making typing responsive on high-latency connections
- **Hardware-Accelerated Crypto** - Apple hardware-accelerated AES with key state caching for OCB encryption/decryption

### Cloud & Infrastructure
- **Cloud Providers** - AWS, Azure, Linode, DigitalOcean, Tailscale, and NetBird (cloud or self-hosted) with OAuth and token authentication
- **Serial Console** - Direct access to Linode LISH and AWS EC2 serial consoles
- **Kubernetes** - Cluster browsing, node debugging via debug pods, EKS kubeconfig generation
- **Mesh Device Details** - Tailscale and NetBird peers show OS, owner, client version, mesh path, exit nodes and subnet routes, and key expiry
- **Connection Profiles** - Save connections with tags, folders, iCloud sync, and a searchable icon catalog: ~180 SF Symbols, 95 Nerd Font developer icons, and website favicons

### AI Integration
- **AI Agent** - Built-in assistant accessible via ⌘I in SSH sessions
  - Providers: Anthropic Claude, OpenAI, Google Gemini, OpenRouter, AWS Bedrock
  - Web search and page fetch tools
  - Thinking model support with extended reasoning
- **Voice Agent** - Real-time bidirectional voice conversation powered by Google Gemini Flash via WebSocket with sub-second latency. Reads terminal scrollback, types keystrokes, pastes text, and executes commands hands-free. Floating bubble overlay with live transcript, tool approval cards, three approval modes, and 30-voice selection
- **AI Commit Messages** - `git commit` auto-generates commit messages from staged diffs using your configured AI provider with preview and edit support
- **MCP Server** - Connect external AI tools to execute SSH commands and access cloud resources

### Agent Inbox
- **Coding Agent Cards** - Claude Code, Codex, Cursor, Copilot, OpenCode, Antigravity, and Pi are recognized in any tab and shown in the vertical tab bar as cards with live status: working, waiting for your input, or done
- **On-Device Detection** - Detection reads the terminal screen on device, so it works identically for local shells, SSH, tssh, and tmux control mode panes with nothing to install on the server. Split tabs are pane-aware: tapping a card focuses the exact pane
- **Smart Notifications** - One notification per event, and an agent that delegates to background agents is tracked through the wait instead of reported done early
- **Project Grouping** - Group the inbox by project to see each project's agents side by side, each card naming its git branch
- **Long-Running Commands** - Builds, test runs, deployments, file transfers, and password or confirmation prompts like sudo appear as cards too: badged while running, marked unread when they finish unseen, notifying when one blocks on input. Programs reporting OSC 9;4 progress feed the same cards. Off by default under Settings → Agents & Commands
- **Subscription Usage** - Claude, Codex, and GitHub Copilot plan usage shown per provider with reset countdowns, per-model breakdowns, and a pace mark. Sign-ins never leave memory; only usage figures and plan labels persist

### Push Notifications & Agent Hooks

- **Notifications From Any Computer** - Pair a computer under Settings → Notifications → Push Notifications, then use the dependency-free `rootshell-notify` CLI from scripts, cron jobs, CI, builds, or deployments. Set a title, body, status, priority, and optional target device; notifications arrive while rootshell is in the background
- **Claude Code and Codex Hooks** - The setup command detects installed agents and adds idempotent hooks without replacing existing configuration. Both agents report completed turns; Claude Code also reports permission prompts, questions, and other requests for input. Visible Codex approval prompts are detected on device because its pre-review hook cannot reliably say whether user action is required
- **Jump Back to Work** - Tapping an agent notification returns to its originating rootshell window, tab, and pane, including panes managed through tmux control mode
- **Post-Quantum End-to-End Encryption** - Titles, summaries, and routing hints are encrypted on the sender with X-Wing (ML-KEM-768 + X25519); the stateless relay sees only ciphertext. Hooks send a short, credential-scrubbed summary and never send prompts, terminal output, transcripts, files, or environment variables
- **Per-Device Control** - Every paired computer has its own revocable credential, and automatic agent notifications can be enabled or disabled independently for each destination without affecting manual notifications

To get started, open Settings → Notifications → Push Notifications → Pair a Computer. rootshell creates a pairing bundle for that device and displays a complete install command containing it. Copy that generated command into the computer you want notifications from. Only the command generated by the target device can pair that device.

The generated command installs `rootshell-notify` in `~/.local/bin`, pairs the device, sends a test notification, and installs hooks for the Claude Code and Codex installations it finds. Codex asks you to review and trust the new hook from `/hooks`. See the [push notification and agent hook guide](push/README.md) for manual setup, custom notifications, upgrades, per-device controls, troubleshooting, and protocol details.

### Built-in Tools
- **rf File Browser** - Yazi-inspired Swift-native TUI file browser with miller columns, vim navigation, tabs, ripgrep search, bookmarks, file operations, bat syntax-highlighted preview, kitty image preview, git status indicators, and 700+ Nerd Font icons. Includes SFTP remote browsing and cross-source yank/paste (local ↔ remote). Configurable via `~/.config/rf/rf.yaml`
- **Native Git** - Swift-native git powered by libgit2 with truecolor output and Nerd Font icons. Supports init, clone, status, add, commit, diff, log, blame, branch, reset, pull, push, fetch, rm, mv, show, revert, cherry-pick, rebase, reflog, worktree, clean, apply, switch. Commit signing with GPG and SSH keys (`-S`, `commit.gpgsign`, SSHSIG), SSH transport, [Helix](https://github.com/kitknox/helix/tree/ios) editor integration, syntax-highlighted pager via bat
- **Helix Editor** - Native [Helix](https://github.com/kitknox/helix/tree/ios) text editor (`hx`) with tree-sitter syntax highlighting, system clipboard, git diff gutter, and full CLI argument support
- **POSIX Shell** - Run shell scripts on device via `sh` with if/for/while/case, functions, pipelines, background jobs (`&`, `jobs`, `wait`, `$!`), parameter expansion, here-documents, redirections, brace expansion, `set -e`/`-u`/`-x`/`-o pipefail`, and `trap`
- **bat** - Syntax-highlighted file viewing with automatic paging
- **ripgrep** - Fast regex-based file search (`rg`) with all standard flags
- **mtr/traceroute** - Interactive TUI with per-hop loss, RTT, jitter, AS lookups, truecolor gradients, and report formats (text, CSV, JSON, XML)
- **vim 9.2** - "Huge" feature set with 24-bit color, langmap, and vartabs
- **curl** - curl 8.19.0 with HTTP/2 via nghttp2
- **croc** - Encrypted peer-to-peer file transfers with LAN peer discovery over multicast and relay fallback
- **imgcat** - Display images inline using Kitty graphics protocol (PNG, JPEG, HEIC)
- **libarchive** - bsdtar, unzip with Zip64, RAR/RAR5, 7-Zip, Zstandard, lz4 support
- **xz** - XZ/LZMA2 compression and decompression
- **WASM Runtime** - Compile your own CLI tools in any language that targets WASI Preview 1 (C/C++ via clang/wasi-sdk, Rust, Go, TinyGo, Swift, Zig, and more) and run them on device by dropping the `.wasm` into the rootshell directory. Sandboxed filesystem access plus a host-provided socket ABI for TCP, UDP, TLS, and DNS. See [`wasm/`](wasm/) for end-to-end Rust, Go, and Swift demos, the full host ABI reference, and the raw/cooked terminal mode docs

### Input & Interaction
- **Terminal Mouse Support** - Full mouse event passthrough for tmux, vim, zellij
- **Keyboard Shortcuts** - Fully customizable keybindings with menu bar integration and Ghostty keybind config compatibility
- **Customizable Toolbar** - Drag-and-drop keyboard toolbar with custom keys that send arbitrary text or key sequences, plus up to five configurable drawer rows. Sticky modifier keys with single-tap one-shot and double-tap lock
- **Clipboard Manager** - Optional device-only encrypted clipboard history (⌘⇧C) capturing copies, pastes, and OSC 52 writes, with transforms: base64, hex, URL encode/decode, JWT decode, hashes, JSON format, shell escape, ANSI strip. Off by default; turning it off wipes the store
- **Spacebar Trackpad** - Long-press the on-screen spacebar to move the cursor like a trackpad
- **Input Language Switching** - Karabiner-style input-source switch on a clean Command tap, a dedicated shortcut (default ⌘⇧Space), and reliable Korean (Hangul) composition
- **Compose Overlay** - Floating text editor (⌘⇧K) for drafting input with autocorrect, spell check, predictive text, and dictation before sending to the terminal
- **Mod-Tap Keys** - QMK-style dual-function keys: one action on tap, another on hold. 55 source keys, 14 tap actions, configurable hold threshold
- **Dictation & CJK Input** - iOS dictation and full CJK input method composition in the terminal with preedit overlay
- **Touch Selection** - Single-finger drag to select, two-finger to scroll, magnifier loupe with draggable selection handles
- **Virtual Keyboard** - Tab key toolbar with double-tap for literal tab, arrow joystick mode on iPhone

### Sync & Persistence
- **iCloud Sync** - Connection history, known hosts, and profiles sync across devices
- **Config Import** - Import connection profiles and keys from your OpenSSH config (concrete Host blocks, IdentityFile keys matched by fingerprint) and fonts, themes, keybindings, and appearance from a desktop Ghostty config
- **Backup & Restore** - Export all app data (keys, passwords, profiles, themes, fonts, shortcuts, cloud accounts, settings) into a single AES-256-GCM encrypted `.rootshellbackup` file with intelligent merging on restore
- **Shell Startup & Custom Prompt** - `~/.rootshellrc` sourced on new shell tabs. Fully customizable prompt via `.promptrc.toml` with Starship-compatible format strings, 11 modules, Powerline arrows, and transient prompt support
- **Local Shell** - Full terminal sessions on iOS and macOS

### Platform Integration
- **25 Languages** - Arabic, Brazilian Portuguese, Catalan, Czech, Danish, Dutch, Finnish, French, German, Hebrew, Hungarian, Italian, Japanese, Korean, Norwegian Bokmal, Polish, Portuguese, Romanian, Simplified Chinese, Slovenian, Spanish, Swedish, Traditional Chinese, Ukrainian, Vietnamese
- **Siri & Shortcuts** - Open any saved connection profile from Shortcuts, Siri, or automation triggers. VPN connect/disconnect intents, plus Open Local Shell, Open SSH Connection, Run Command over SSH (runs in the background with real exit codes and separate stderr), and Get Connection Profiles actions
- **Open in rootshell** - Files shared from other apps open directly in a new shell tab in your editor, honoring `EDITOR` from `~/.rootshellrc`
- **Live Activity & Widgets** - Lock Screen and Dynamic Island show active sessions with real-time stats. Home Screen widgets for VPN and WiFi info
- **Paste Image Upload** - Paste clipboard images into SSH sessions to upload files to the remote server and insert the path at cursor

## Privacy

rootshell collects no analytics or crash data unless otherwise part of the TestFlight platform itself.

## Building from Source

Building rootshell requires:

- iOS/iPadOS 18.0+, macOS 14.0+, or visionOS 26.0+
- Xcode 26.4+
- An Apple Silicon Mac for iOS Simulator builds

Clone the repository, open `rootshell.xcodeproj` in Xcode, and let Swift Package Manager resolve the project dependencies:

```bash
git clone https://github.com/kitknox/rootshell.git
cd rootshell
open rootshell.xcodeproj
```

The project builds for the Simulator as-is, signed ad-hoc under upstream's
identifiers — no signing setup needed. Building to a device, or anything that
needs real entitlements, has to be signed under your own Apple Developer team.
Run `scripts/setup-dev-signing.sh` and see
[`docs/contributor-signing.md`](docs/contributor-signing.md); do not edit
`project.pbxproj` to change the team.

Use the `rootshell-AppStore` scheme for sandboxed App Store builds or `rootshell-Standalone` for the unsandboxed Mac Catalyst build. For example, build for the iOS Simulator with:

```bash
xcodebuild -project rootshell.xcodeproj \
  -scheme rootshell-AppStore \
  -configuration DebugAppStore \
  -sdk iphonesimulator -arch arm64 build
```

### macOS Local Shells

Local shells on macOS use the `rootshell-helper` source included in this repository. The Standalone target builds the native background app and embeds it at `Contents/Helpers/rootshell-helper.app` with Code Sign on Copy; no prebuilt helper binary is stored in Git. Organizer distribution signs and notarizes the helper as nested code with the containing app. A sandboxed macOS build can connect to the same helper when it is launched separately because both products use the provisioned `group.com.kk2.ghostty` App Group container.

Build the helper alone with:

```bash
xcodebuild -project rootshell.xcodeproj \
  -scheme rootshell-helper \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

See [`rootshell-helper/README.md`](rootshell-helper/README.md) for its security model, tests, and independent release workflow.

## License

rootshell is released under the [MIT License](LICENSE). See [Third-Party Notices](THIRD_PARTY_NOTICES.md) for licenses and attribution covering bundled dependencies.

## Links

- [Website & Documentation](https://www.rootshell.com)
