# rootshell

A free, Metal-accelerated terminal emulator for iPhone, iPad, Vision Pro, and Mac.

<p>
  <img alt="Apple Platforms" src="https://img.shields.io/badge/Apple%20Platforms-iPhone%20%7C%20iPad%20%7C%20Vision%20Pro%20%7C%20Mac-111111?style=flat-square">
  <img alt="Rendering" src="https://img.shields.io/badge/Rendering-Metal%20Accelerated-5b2eff?style=flat-square">
  <img alt="SSH" src="https://img.shields.io/badge/SSH-Native-1f6feb?style=flat-square">
  <img alt="Roam" src="https://img.shields.io/badge/Roam-Seamless%20Network%20Handover-0a7f5a?style=flat-square">
  <img alt="Pricing" src="https://img.shields.io/badge/Pricing-Free-2ea44f?style=flat-square">
</p>

**[Website](https://beta.rootshell.com)** · **[App Store](https://apps.apple.com/app/rootshell-local-terminal-ssh/id6755794662)** · **[TestFlight Beta](https://testflight.apple.com/join/DEVnH3N2)** · **[macOS Download](https://beta.rootshell.com/downloads/rootshell-macos-latest.tar.xz)**

<a href="https://apps.apple.com/app/rootshell-local-terminal-ssh/id6755794662">
  <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83" alt="Download on the App Store" height="60">
</a>

## Why rootshell?

rootshell is built for developers who need a terminal that actually works on mobile — not a stripped-down compromise.

It combines GPU-accelerated rendering, native SSH, resilient roaming sessions, deep cloud and Kubernetes integration, and AI-assisted workflows in a single Apple-native app.

## Highlights

- Metal-accelerated terminal rendering powered by libghostty
- Native SSH with post-quantum key exchange and Secure Enclave key storage
- Rootshell Roam for seamless WiFi/cellular handoff and persistent mobile sessions
- Built-in file browser, native git client, and local shell
- Cloud provider integration for AWS, Azure, Linode, DigitalOcean, and Tailscale
- Voice-controlled AI agent and built-in assistant inside terminal sessions

## About

rootshell is a terminal emulator built for Apple platforms. It features GPU-accelerated rendering powered by libghostty, native SSH with post-quantum key exchange, Secure Enclave key storage, VPN tunneling, a built-in file browser and native git client, a voice-controlled AI agent, cloud provider integration (AWS, Azure, Linode, DigitalOcean), Kubernetes node debugging, and Rootshell Roam — a mosh-compatible and tssh (QUIC+KCP) mobile terminal protocol with seamless network roaming and session persistence.

For full feature details, screenshots, and documentation, visit **[beta.rootshell.com](https://beta.rootshell.com)**.

## Getting the App

rootshell is **completely free** with no ads, subscriptions, or in-app purchases.

| Platform | Link |
|----------|------|
| iPhone & iPad | [App Store](https://apps.apple.com/app/rootshell-local-terminal-ssh/id6755794662) |
| visionOS (beta) | [TestFlight](https://testflight.apple.com/join/DEVnH3N2) |
| macOS (sandboxed, beta) | [TestFlight](https://testflight.apple.com/join/DEVnH3N2) |
| macOS (standalone) | [Direct Download](https://beta.rootshell.com/downloads/rootshell-macos-latest.tar.xz) |
| macOS (Homebrew) | See below |

### Install via Homebrew

```bash
brew tap kitknox/rootshell
brew install --cask rootshell
```

## Feature Areas

- [Terminal & Rendering](#terminal--rendering)
- [Visual Effects](#visual-effects)
- [SSH & Networking](#ssh--networking)
- [YubiKey & FIDO2](#yubikey--fido2)
- [Rootshell Roam](#rootshell-roam)
- [Cloud & Infrastructure](#cloud--infrastructure)
- [AI Integration](#ai-integration)
- [Built-in Tools](#built-in-tools)
- [Input & Interaction](#input--interaction)
- [Sync & Persistence](#sync--persistence)
- [Platform Integration](#platform-integration)

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
- **Clickable Hyperlinks** - URLs in terminal output are interactive — Cmd+click or context menu to open
- **Cursor Blink Styles** - 7 animated cursor modes: normal, breathing, heartbeat, neon flicker, pulse, candle, and rootshell

### Visual Effects
- **Custom Shaders** - Import shaders directly from Shadertoy with full uniform support
- **Cursor Effects** - Warp, Sweep, Tail, and Blaze cursor animations
- **Background Effects** - Solar (real-time sun tracking), Starfield, Fireflies, Aurora, Nebula
- **Video Backgrounds** - Play looping video files as terminal backgrounds with speed control
- **Photo Backgrounds** - Terminal background from photo library with opacity presets, 9 image filters, and Ken Burns cinematic pan/zoom animation
- **Window Transparency** - Configurable transparency with blur (macOS)

### SSH & Networking
- **Native SSH Client** - Written entirely in Swift with no external dependencies
- **Jump Hosts** - Multi-hop connections through bastion servers
- **SSH Agent Forwarding** - Three approval modes: auto-approve, per-session, per-request
- **Secure Enclave Keys** - Ed25519, ECDSA, and RSA keys with biometric protection
- **Post-Quantum SSH** - `mlkem768x25519-sha256` hybrid key exchange and ML-DSA host key signatures for end-to-end post-quantum protection. Also supports `sntrup761x25519-sha512` (OpenSSH 9.0+)
- **Port Forwarding** - Local (`-L`), remote (`-R`), and dynamic SOCKS5 (`-D`) forwarding
- **VPN Tunnel** - Any SSH or TSSH profile can act as a system-level VPN, routing all device traffic through the remote server. Per-profile DNS presets, route exclusions, Home Screen/Control Center widgets, Live Activity with real-time stats, and Siri Shortcuts support
- **Multipath TCP** - MPTCP over Apple Network.framework maintains subflows on WiFi and cellular simultaneously for near-instant handover (requires Linux 5.6+ on server)
- **Native SCP & SFTP** - Built-in `scp` and interactive `sftp` client with tab completion, glob patterns, and real-time progress
- **Background SSH Tunnels** - Maintain port forwards without a terminal UI with auto-start on launch and byte transfer statistics
- **Auto-start tmux** - Automatically attach to or create tmux sessions on connect
- **tmux Session Discovery** - After connecting, lists active tmux sessions with window count and live terminal preview
- **Tailscale Integration** - Device discovery and SSH to your tailnet with no-auth support
- **Host Shorthand (HSS)** - Pattern-based hostname expansion with YAML configuration
- **Connection Health** - Real-time RTT and packet loss tracking with time series chart and negotiated cryptographic algorithm details
- **Scrollback Encryption** - Persisted scrollback encrypted at rest with AES-256-GCM and restored on session reconnect with full ANSI colors

### YubiKey & FIDO2
- **YubiKey PIV** - SSH authentication with hardware-bound private keys via Lightning, NFC, or USB-C. Supports RSA, ECDSA, and Ed25519 (firmware 5.7+) with key generation directly on device
- **FIDO2 Security Keys** - Any FIDO2-compatible key (YubiKey 5, SoloKeys, etc.) for touch-to-sign SSH authentication using `webauthn-sk-ecdsa-sha2-nistp256@openssh.com`
- **Key Import** - Import existing SSH private keys to YubiKey PIV slots with optional keychain deletion
- **Smart PIN Caching** - Wired connections cache for the session; NFC connections cache across taps with session batching for multi-tab signing
- **iCloud Sync** - YubiKey references and FIDO2 credential metadata sync across devices; private keys never leave hardware

### Rootshell Roam
- **Mosh-Compatible Protocol** - Native [mosh](https://mosh.org)-compatible implementation built entirely in Swift with SSP (State Synchronization Protocol) support. Works with any standard mosh-server installation
- **tssh/trzsz Support** - [tssh](https://github.com/trzsz/trzsz-ssh) connections with UDP-based terminal transport offering full native scrollback and lower interactive latency than mosh
- **QUIC + KCP Transports** - Choose between QUIC (TLS 1.3, modern congestion control) or KCP (AES-GCM-256) for tssh transport. Configure in Settings → Roam → Transport Mode
- **Session Resumption** - Roam sessions survive app termination and device reboots. Credentials are stored in the Keychain and sessions resume automatically. tsshd reconnect support requires our [upstream PR](https://github.com/trzsz/tsshd/pull/16) ([fork](https://github.com/kitknox/tsshd))
- **Seamless Network Roaming** - Switch between WiFi and cellular without dropping your session. Handles IP address changes, network transitions, and temporary connectivity loss with a status banner
- **STUN Firewall Traversal** - Automatic NAT hole-punching via STUN to enable connections through stateful firewalls without VPN tunnels
- **Predictive Local Echo** - Keystroke predictions displayed immediately while waiting for server confirmation, making typing responsive on high-latency connections
- **Hardware-Accelerated Crypto** - Apple hardware-accelerated AES with key state caching for OCB encryption/decryption

### Cloud & Infrastructure
- **Cloud Providers** - AWS, Azure, Linode, DigitalOcean, Tailscale with OAuth authentication
- **Serial Console** - Direct access to Linode LISH and AWS EC2 serial consoles
- **Kubernetes** - Cluster browsing, node debugging via debug pods, EKS kubeconfig generation
- **Connection Profiles** - Save connections with tags, folders, and iCloud sync

### AI Integration
- **AI Agent** - Built-in assistant accessible via ⌘I in SSH sessions
  - Providers: Anthropic Claude, OpenAI, Google Gemini, OpenRouter
  - Web search and page fetch tools
  - Thinking model support with extended reasoning
- **Voice Agent** - Real-time bidirectional voice conversation powered by Google Gemini Flash via WebSocket with sub-second latency. Reads terminal scrollback, types keystrokes, pastes text, and executes commands hands-free. Floating bubble overlay with live transcript, tool approval cards, three approval modes, and 30-voice selection
- **AI Commit Messages** - `git commit` auto-generates commit messages from staged diffs using your configured AI provider with preview and edit support
- **MCP Server** - Connect external AI tools to execute SSH commands and access cloud resources

### Built-in Tools
- **rf File Browser** - Yazi-inspired Swift-native TUI file browser with miller columns, vim navigation, tabs, ripgrep search, bookmarks, file operations, bat syntax-highlighted preview, kitty image preview, git status indicators, and 700+ Nerd Font icons. Includes SFTP remote browsing and cross-source yank/paste (local ↔ remote). Configurable via `~/.config/rf/rf.yaml`
- **Native Git** - Swift-native git powered by libgit2 with truecolor output and Nerd Font icons. Supports init, clone, status, add, commit, diff, log, blame, branch, reset, pull, push, fetch, rm, mv, show, revert, cherry-pick, rebase, reflog, worktree, clean, apply, switch. SSH transport, [Helix](https://github.com/kitknox/helix/tree/ios) editor integration, syntax-highlighted pager via bat
- **Helix Editor** - Native [Helix](https://github.com/kitknox/helix/tree/ios) text editor (`hx`) with tree-sitter syntax highlighting, system clipboard, git diff gutter, and full CLI argument support
- **POSIX Shell** - Run shell scripts on device via `sh` with if/for/while/case, functions, pipelines, variables, here-documents, redirections, brace expansion, and 25 builtins
- **bat** - Syntax-highlighted file viewing with automatic paging
- **ripgrep** - Fast regex-based file search (`rg`) with all standard flags
- **mtr/traceroute** - Interactive TUI with per-hop loss, RTT, jitter, AS lookups, truecolor gradients, and report formats (text, CSV, JSON, XML)
- **vim 9.2** - "Huge" feature set with 24-bit color, langmap, and vartabs
- **curl** - curl 8.19.0 with HTTP/2 via nghttp2
- **imgcat** - Display images inline using Kitty graphics protocol (PNG, JPEG, HEIC)
- **libarchive** - bsdtar, unzip with Zip64, RAR/RAR5, 7-Zip, Zstandard, lz4 support
- **xz** - XZ/LZMA2 compression and decompression

### Input & Interaction
- **Terminal Mouse Support** - Full mouse event passthrough for tmux, vim, zellij
- **Keyboard Shortcuts** - Fully customizable keybindings with menu bar integration and Ghostty keybind config compatibility
- **Customizable Toolbar** - Drag-and-drop keyboard toolbar with custom keys that send arbitrary text or key sequences. Sticky modifier keys with single-tap one-shot and double-tap lock
- **Compose Overlay** - Floating text editor (⌘⇧K) for drafting input with autocorrect, spell check, predictive text, and dictation before sending to the terminal
- **Mod-Tap Keys** - QMK-style dual-function keys: one action on tap, another on hold. 55 source keys, 14 tap actions, configurable hold threshold
- **Dictation & CJK Input** - iOS dictation and full CJK input method composition in the terminal with preedit overlay
- **Touch Selection** - Single-finger drag to select, two-finger to scroll, magnifier loupe with draggable selection handles
- **Virtual Keyboard** - Tab key toolbar with double-tap for literal tab, arrow joystick mode on iPhone

### Sync & Persistence
- **iCloud Sync** - Connection history, known hosts, and profiles sync across devices
- **Backup & Restore** - Export all app data (keys, passwords, profiles, themes, fonts, shortcuts, cloud accounts, settings) into a single AES-256-GCM encrypted `.rootshellbackup` file with intelligent merging on restore
- **Shell Startup & Custom Prompt** - `~/.rootshellrc` sourced on new shell tabs. Fully customizable prompt via `.promptrc.toml` with Starship-compatible format strings, 11 modules, Powerline arrows, and transient prompt support
- **Local Shell** - Full terminal sessions on iOS and macOS

### Platform Integration
- **25 Languages** - Arabic, Brazilian Portuguese, Catalan, Czech, Danish, Dutch, Finnish, French, German, Hebrew, Hungarian, Italian, Japanese, Korean, Norwegian Bokmal, Polish, Portuguese, Romanian, Simplified Chinese, Slovenian, Spanish, Swedish, Traditional Chinese, Ukrainian, Vietnamese
- **Siri & Shortcuts** - Open any saved connection profile from Shortcuts, Siri, or automation triggers. VPN connect/disconnect intents
- **Live Activity & Widgets** - Lock Screen and Dynamic Island show active sessions with real-time stats. Home Screen widgets for VPN and WiFi info
- **Paste Image Upload** - Paste clipboard images into SSH sessions to upload files to the remote server and insert the path at cursor

## This Repository

This repository serves as the **public issue tracker** for rootshell. Use it to:

- Report bugs
- Request features
- Ask questions about functionality

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

## Privacy

rootshell collects no analytics or crash data unless otherwise part of the TestFlight platform itself.

## Links

- [Website & Documentation](https://beta.rootshell.com)
