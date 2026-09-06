# Changelog

All notable changes to the rootshell app for iPhone, iPad, Vision Pro, and Mac, newest first.
Versions are listed as `release-build`, matching the version shown in Settings, About.

## 1.0.11-142 - September 4, 2026

### Tabs

- **Live Tab Hover Previews:** Hold Shift while hovering an inactive top tab or sidebar row on iPad or Mac for a live preview. Move across tabs to slide between previews, pinch to resize, or click to open Tab Exposé on that tab. Under Settings -> Appearance -> Window -> Tab Hover Previews, change activation to Always, Command, Option or Control.
- **Resizable Tab Exposé Previews:** Pinch in Tab Exposé to resize its live thumbnails. The grid snaps to a clean column layout, remembers its size and offers a temporary Reset control.
- **Clearer Hover Targets:** Sidebar rows and multiplexer gateway headers have clearer hover highlights. Close buttons in the sidebar, Pills and Compact Pills also gain consistent hover targets and respect Reduce Motion.

### Memory

- **Lower Memory Use for Inactive Tabs and Previews:** Inactive and restored regular, tssh and tmux tabs now start with their renderers asleep, avoiding full-size Metal surfaces until first shown. Tab Exposé, multiplexer and hover previews release their mirrored surfaces when dismissed, further reducing memory use with many tabs.

### Appearance

- **Current Theme Stays Visible:** The Cmd-Shift-T theme picker pins the active theme in a Current section above Favorites, keeping it visible without searching or scrolling.

### VPN

- **Redesigned VPN Control Widget:** The VPN Control widget has a native, status-tinted design with clearer controls and wrapping profile names. It now shows user@host and SSH/tssh details; the medium widget adds a large live connection timer, while the small widget adapts its status and timer to the available space.

### Standalone macOS

- **Automatic Ghostty Shell Integration:** Local shells now receive Ghostty shell integration automatically. zsh, fish and Bash 4+ report working directories and titles without manually sourcing rootshell scripts; Elvish receives the integration search path. Integration no longer overrides rootshell's cursor style, and updated Bash handling avoids duplicated multiline prompts.
- **Reliable File and Folder Opening on macOS 15:** Opening a folder or file through Finder, a Dock drop, AppleScript or `open -a`/`open -b` now targets and surfaces the receiving window reliably on macOS 15. A new window replaces its temporary shell with the requested folder tab, while restored tabs finish loading before the request is applied.

### Multiplexers and SSH

- **Faster tmux Restore and Resume:** Returning from the background or restoring rootshell after termination now feels dramatically faster for tmux control-mode sessions. The active tab recovers first and becomes interactive quickly while background histories continue loading; selecting another tab makes it the new priority. This also applies after buffered output is discarded. Control output stays gated until tmux is ready, and fresh-shell fallbacks discard stale projections.
- **Correct Focus Reporting after tssh Resume:** Resumed tssh sessions restore focus-reporting mode instead of sending an unconditional focus event. Plain shells no longer show stray `^[[I`, tmux control channels avoid extra input, and TUIs receive their requested focus state. tmux 3.8+ panes also regain focus reporting after a cold restore.
- **Platform-Aware Multiplexer Discovery:** Session discovery and multiplexer attachment no longer probe Linux-only Homebrew and Snap paths on macOS hosts, including standalone local shells and remote connections. This avoids repeated automount and directory-service lookups while still finding tools on Linux and macOS.

### Reliability and Size

- **Correct GitHub Copilot Detection:** GitHub Copilot is no longer mistaken for OpenCode on first launch, keeping agent activity and attention indicators attached to the correct agent.
- **No CloudKit Diagnostics When Sync Is Off:** With iCloud sync disabled, rootshell no longer performs CloudKit account, zone or subscription diagnostics at startup.
- **Improved Selectable Command and Key Blocks:** Fingerprints, public keys and push install commands now use consistent selectable blocks. Long values wrap cleanly, and Copy buttons no longer resize when changing to Copied.
- **Updated curl:** The iPhone, iPad and Apple Vision Pro local shell now includes curl 8.22.0.
- **Smaller App Bundles:** The uncompressed app bundle is about 22 MiB smaller on iOS and 20 MiB smaller on Mac after removing duplicate localization catalogs from extensions, with all supported languages preserved.

## 1.0.11-141 - September 2, 2026

### Settings Sync

- **App Settings in iCloud:** App settings can now sync through iCloud alongside profiles, known hosts and history. Turn on Settings -> Privacy & Data -> iCloud Sync -> Sync Settings, then choose whether this device or iCloud wins when both have values. Changes are merged per setting rather than replacing one device's complete setup.
- **Local Exceptions and Sync Controls:** Keep exceptions local without turning sync off: touch and hold a setting (right-click on Mac) and choose Keep on This Device. New Synced Groups and Pinned Settings screens show exactly what follows iCloud, let whole groups opt in or out and make conflicts explicit before replacing either value.
- **File-Based Configuration:** A new rootshell config file uses key-value pairs to provide a text and dotfile-friendly way to manage app settings. Create or choose a file under Settings -> Privacy & Data -> Config File, use `key = value` pairs and comments, view diagnostics, reload or edit it in rootshell, or export current settings. Active pairs override the UI and stay local; optional write-back updates only the changed pair while preserving comments.

### Multiplexers

- **First-Class zmx Integration:** rootshell now discovers zmx sessions in the standalone macOS local shell and over SSH and tssh, shows running sessions in the picker, renders live history previews in Tab Exposé and switches an attached client directly from a preview. zmx can auto-start with a global or per-profile session name or custom command, matching the existing tmux and herdr workflow.

### Tabs and Appearance

- **Ledger and Trough Tab Styles:** Ledger uses a clean text row with an animated underline; Trough places tabs in a shared segmented well with the selected tab riding above it. Choose either in Settings -> Appearance -> Window or the tab bar's context menu.
- **Improved Tab Exposé:** Tab Exposé gains page indicators, improved VoiceOver labels and actions, and reliable pull and sideways gestures when a pinned sidebar is visible.
- **Background Effects and Faster Theme Loading:** Background effects can optionally extend beneath a pinned sidebar. Effects no longer cover Screen Sharing panes, including mixed terminal/VNC split layouts, and themes are parsed on demand instead of loading all 451 at launch.
- **Copy Host Addresses:** Host addresses can be copied from active tabs, the vertical sidebar, connection profiles, SSH hosts, known hosts, tunnels and VPN entries, with host-only, user@host and port-aware forms where available.

### Screen Sharing

- **Password-Only High Performance Connections:** Fixed High Performance Screen Sharing to Macs that offer password-only authentication. rootshell now supports this flow, which is less secure than user-based authentication.

### Terminal and Git

- **Paste Without Unnecessary Clipboard Prompts:** Command-V and paste buttons now use Apple's privacy-authorized paste path. Text, URLs, files, images and PDFs keep their appropriate paste or SSH upload behavior, and voice-agent insertion no longer temporarily replaces the clipboard.
- **Correct Local Git Output:** Local Git clone, fetch, pull and push now keep progress, errors and command output on the correct streams. Progress updates no longer leave stray output or make the terminal caret flicker.

### Reliability

- **Reliable macOS File and Folder Opening:** Opening folders or files with standalone rootshell on macOS through AppleScript `open`, Finder, Dock drops or `open -a` now reliably opens a window when needed and starts a shell in the folder or the file's parent directory. Duplicate Apple event and LaunchServices deliveries are ignored without losing separate requests.
- **Reliable Push-Notification Retries:** Push-notification retries no longer replace decrypted content with an encrypted placeholder, and the pairing/install command UI is clearer and easier to copy.
- **Fixed Lock-Transition Crash:** Fixed a lock-transition crash by preserving the terminal's responder state while protected drawing is suspended.

## 1.0.11-140 - August 30, 2026

### Push Notifications

- **General-Purpose Push Notifications:** Run `rootshell-notify send` from scripts, cron jobs, CI, builds, deploys or anything else that can execute a command, with a title and optional body, status, priority and target device. Messages arrive even while rootshell is in the background. Pair under Settings -> Notifications -> Push Notifications; rootshell provides the install command.
- **Claude Code and Codex Integrations:** The installer adds hooks for agents it finds. Both report completed turns, Claude Code reports when it needs input, and rootshell's on-device detector handles visible Codex approval prompts. Tapping an agent notification returns to its window, tab and pane, including tmux control mode. Agent pushes follow the existing policy, deduplicate screen detection and can be controlled per device.
- **Post-Quantum End-to-End Encryption:** Every message is encrypted on the sender with the X-Wing post-quantum hybrid (ML-KEM-768 + X25519), so the stateless relay sees only ciphertext. Agent hooks send a short, secret-scrubbed summary and routing hints, never prompts, terminal output, transcripts, files or environment variables. Each paired computer has its own revocable credential.

### macOS Automation

- **New AppleScript Commands:** AppleScript can now create a tab or window, optionally choosing a working directory, startup command and connection profile. Folders opened with rootshell now start a local shell at that path, so Finder, `open -a rootshell <folder>` and other apps can hand a directory straight to the terminal (#344).
- **Reliable Scripted Windows and Commands:** Multiple scripted new-window requests now open in order instead of being consumed by the first window. Startup commands retry partial PTY writes, and directories containing apostrophes are quoted correctly.

### Appearance and Tabs

- **Liquid Glass Window Transparency:** Transparent windows on macOS 26 gain Glass and Clear Glass blur styles alongside Standard. Liquid Glass renders the desktop through a system glass material tinted by the terminal theme; choose it under Settings -> Appearance -> Window Transparency.
- **Progress in Integrated Tabs:** Integrated tabs now carry terminal OSC progress along the continuous edge and around the active tab, including determinate, animated indeterminate, paused and error states. Their edge keeps the terminal theme's hue, inactive contrast is gentler, and the outline remains a clean physical pixel.
- **Tab-Style Fixes:** Fixed a TestFlight-reported crash when opening the tab-style context menu. Compact Pills now keep the new-tab and settings controls on-screen in narrow or resized windows, and their selection animation is no longer clipped (#351).

### Keyboard

- **Keyboard Layout Choices Persist:** Hiding the software keyboard with its chevron now remains your choice while swiping between tabs, opening and closing overlays, or switching apps. Toolbar-only and hardware-keyboard layouts also keep their size and bottom spacing stable through those transitions.

### Terminal

- **Lower CPU Use for tmux Title Updates:** Fast OSC title changes in tmux control mode no longer repeatedly invalidate every tab, split and sidebar. Title-only updates use a lower-rate refresh path, reducing stutter and CPU use without delaying real topology changes.
- **Fixed CJK tmux Notifications:** Fixed tmux control-mode notifications containing certain CJK text. A UTF-8 continuation byte could be mistaken for the end of a passthrough sequence, truncating an OSC 9 notification and printing its remaining text into the pane. Notifications now arrive complete and leave the terminal grid untouched.

### macOS Menus

- **Restored Menus and Shortcuts on macOS 15:** Restored missing Terminal and Tabs menus and View toggles on macOS 15, where duplicate system shortcuts could silently remove an entire menu. Shortcut glyphs display again, Command-1 through Command-9 select their tabs reliably, and Toggle Compose now uses its configured Command-Shift-K shortcut (#346).

## 1.0.11-139 - August 27, 2026

### Tabs

- **Three Top Tab Bar Styles:** The top tab bar now offers Pills, Compact Pills and Integrated styles. Integrated tabs use a browser-style design that visually joins the active tab to the terminal, while Compact Pills fit more of the familiar rounded tabs on screen. Choose a style in Settings -> Appearance -> Window or from the tab bar's context menu. All three retain tab groups, badges, drag-and-drop and window dragging, adapt to narrow iPhone, iPad and macOS windows, and respect Reduce Motion.
- **Clearer Inactive-Tab Hover:** Inactive top tabs now have stronger hover contrast, making the tab under the pointer easier to identify.
- **Dedicated macOS Window-Drag Area:** On macOS, enabling Tabs in Title Bar now reserves 42 points to the left of the top tabs as a dedicated window-drag area, making the window easier to move even when the tab bar is full.
- **Consistent Sidebar Alignment:** Buttons, badges and counts in the vertical tab sidebar now share a consistent trailing alignment.

### Multiplexers

- **Live Zellij Session Previews:** Zellij session discovery now shows live previews for detached sessions by capturing their focused terminal pane, and no longer offers exited sessions.
- **Reliable Escape in the Session Picker:** Pressing Escape to close the multiplexer session picker is now reliable across hardware keyboards, the software keyboard and toolbar keys, without leaking Escape into the terminal.

### Display

- **Timed Always On Display:** Always On Display is now a duration control instead of a simple switch on iPhone and iPad. Choose Off, 1-30 minutes or Always. A timed hold restarts after every touch, software or hardware key press, then returns to the normal system auto-lock behavior after you stop working. It pauses while rootshell is in the background, and the previous enabled setting migrates to Always.

### Keyboard and Layout

- **Fixed Extend Under Home Indicator Regression:** Fixed a build 138 regression in Extend Under Home Indicator. Returning from Settings, Tab Exposé, the connection sheet or another overlay could make the keyboard toolbar jump and resize the terminal twice.

### Terminal

- **Restored Cursor Effects:** Fixed cursor effects such as Neon and Cursor Blaze after upstream Ghostty changes became incompatible with rootshell's local GPU optimizations. The optimizations now work with the updated renderer: effects animate at the configured terminal refresh rate, and finite animations stop rendering when complete, continuing to use less GPU than upstream Ghostty's cursor shaders.

## 1.0.11-138 - August 25, 2026

### Memory

- **Lower Memory Use with Many Tabs:** Build 138 dramatically reduces memory use in tab-heavy sessions. Hidden tabs now release their Metal swap-chain resources and restore them when shown again, while restored tabs and tmux control-mode panes start with the correct visibility. This matters more than ever during the global RAM crunch, when every byte counts.

### Tabs

- **Multiplexer Sessions in Tab Exposé:** Tab Exposé now understands multiplexers attached through the local shell on macOS, SSH or tssh. Open it from a tmux, herdr or zellij session to see that session's own tabs, including live color previews of split-pane layouts. Swipe sideways to reach the app's regular tabs, and select a preview to switch the session. Open Tab Exposé by swiping down on the top tab bar with one finger, using a two-finger trackpad swipe down over the top tab bar, pressing Cmd-Shift-A or using its button in the vertical tab menu. Mosh is not supported because the feature uses connection channels. Enable this in Settings -> Connections -> Multiplexers -> Show Multiplexer Tabs.
- **Cleaner Transparent Tab Exposé on macOS:** Transparent windows now stay transparent throughout Tab Exposé without flashing or showing the live terminal behind the selected preview. Scaled-down multiplexer previews also render more cleanly.

### SSH

- **Fixed RSA Connections to exe.dev:** Fixed RSA connection failures with exe.dev and other SSH servers (#320). RSA key blobs and signature algorithms are now handled separately, the negotiated host-key algorithm is used when signing, and user authentication follows the server's advertised signature support. Legacy RSA/SHA-1 is attempted only when needed.
- **Authentication Banners Retire Cleanly:** Authentication banner cards now have a close button and automatically retire 15 seconds after authentication ends. A failed ssh, mosh or tssh command can no longer leave a banner stranded over the local-shell prompt.

### Terminal

- **Optional Compact Styled Prompts:** Built-in styled prompts can now omit the blank line before each prompt. Toggle Blank Line Before Prompt in prompt settings. Custom .promptrc.toml files can set add_newline; the plain "$ " prompt is unchanged.
- **New AMOLED Theme:** Added the rootshell AMOLED theme, with a true-black background for OLED displays.
- **Fixed Watchdog Crash in ping:** Fixed a system watchdog crash when ping performed a slow reverse DNS lookup. Blocking lookups now run on a dedicated utility queue, failed lookups are cached instead of repeated for every reply, and cancellation is honored once an in-flight lookup returns.

### Keyboard and Layout

- **Home-Indicator Setting Covers the Keyboard Toolbar:** Extend Under Home Indicator now also controls the keyboard toolbar on iPhone and iPad. Turn it on to run both the terminal and toolbar edge-to-edge under the indicator, or leave it off to keep a small touch-safe gap for Home gestures.
- **Keyboard Stays Open after Removing Clicks:** The software keyboard no longer closes after removing a Clicks Power Keyboard from MagSafe while its Bluetooth connection remains active.

### Standalone macOS

- **Permission Prompts for Protected Resources:** Local-shell programs can now request normal macOS permission for protected resources such as the camera, microphone, photos, contacts, calendars, location and Bluetooth.
- **Apple Events Permission Prompts:** Commands that automate another app, including tools that open files in editors such as BBEdit, can now trigger the standard Apple Events permission prompt instead of failing with an authorization error.

## 1.0.11-137 - August 23, 2026

### Mosh

- **Overwrite Prediction:** Mosh now supports overwrite prediction (#314). Local predictions can replace the cell under the cursor instead of inserting and shifting the rest of the row, which keeps tmux, zellij and other bordered interfaces aligned on high-latency links. Enable it for new sessions in Settings -> Roam -> Overwrite Predictions, or use --predict-overwrite and --no-predict-overwrite on typed mosh and roam commands.
- **More Reliable Typed Commands:** Typed mosh and roam commands preserve quoted SSH option values and the complete remote command. Flags intended for a command on the server are no longer mistaken for local Mosh options.

### SSH

- **Post-Quantum Key Exchange through ProxyJump:** ProxyJump connections now use post-quantum key exchange on the target connection when supported (#315). Previously the jump-host connection used the full algorithm policy, but the target connection used the older classically secure policy. The full policy now reaches the target across regular SSH, Mosh, tssh, AI Agent and other headless connection paths.

### Standalone macOS

- **No More Repeated Data-Access Prompt:** Fixed some Macs asking for permission to access data from other apps on every rootshell launch. rootshell-helper has moved from a command-line executable to a fully signed app companion bundle and communicates with rootshell through the shared App Group.
- **New Local SSH Agent Socket:** The local SSH agent has a new socket path. New shells launched by rootshell receive it automatically. Existing long-running shells, including tmux sessions, retain the old SSH_AUTH_SOCK; restart those shells or update SSH_AUTH_SOCK to use the agent again.
- **Safe Fallback for Invalid Local Shells:** A bad local-shell command no longer causes a new tab to close immediately. Settings now catch missing executables, relative paths, malformed quotes and control characters, explain the problem, and use a clean macOS zsh. If a valid shell disappears or fails while launching, the helper makes the same safe fallback.

## 1.0.11-136 - August 22, 2026

### Tabs

- **New Tab Exposé:** Shows live previews for every tab in the current scope, including Screen Sharing sessions. Pull down on the top tab bar with one finger, use a two-finger trackpad pull there, or press Cmd-Shift-A. In group/project mode, a sideways swipe drags the neighboring live grid alongside the current one and springs to commit or cancel. Global Cmd-Option-[ and ] shortcuts switch groups/projects anywhere; in Exposé, they use the same slide and leave it open. Each scope remembers its last tab. Configure the pull gesture in Settings -> Terminal and captions in Settings -> Appearance -> Window.

### Terminal

- **Ghostty Engine Update:** Ghostty's terminal engine received a broad upstream refresh and moved to Zig 0.16. Kitty graphics adds animated images and relative placements, plus many sizing, scrolling, clipping and transfer fixes. Wide-character reflow and grapheme output are faster, with further fixes for page growth, base64, OSC/grapheme limits, tab stops, wraps and resets.
- **Redesigned Text Selection Magnifier:** Text selection has a redesigned iPhone and iPad magnifier that tracks scrolling and layout, keeps the selected cell sharp, avoids screen edges and respects Reduce Motion. Prefer Apple's loupe? Enable it in Settings -> Appearance -> Window.
- **Cleaner Local-Shell Prompt Spacing:** The plain local-shell prompt no longer adds an unwanted blank line, and returning from a full-screen command no longer adds a row. Styled prompts keep their intentional spacing.
- **Reliable Cmd-. Cancel Shortcut:** Cmd-. now reliably acts as Cancel/Escape on iPadOS and macOS while honoring custom bindings and shortcut capture first. Overlapping UIKit deliveries are deduplicated, and special-key sentinels no longer leak into terminal text.

### Profiles

- **Per-Profile Multiplexer Session:** SSH profiles can now pin their own tmux, tmux -CC or herdr session name under Terminal Options. It wins over the last tmux session remembered for that host, syncs with the profile and yields to a custom auto-start command.

### Screen Sharing

- **Support for Delayed Desktop Sizing:** Screen Sharing now connects to servers that finish the RFB handshake before announcing a usable desktop size. KDE's KRFB is one example: its PipeWire capture backend can initially report a 0x0 framebuffer. rootshell waits for DesktopSize, Apple display-layout or media dimensions, preserves early updates in protocol order and builds the framebuffer off the main thread instead of stalling or failing the session.
- **More Reliable Apple Login Recognition:** Apple login and lock-screen recognition is more reliable. Display metadata races no longer confuse the prompt, OCR work is bounded, multi-display layouts update atomically, and password-prompt debouncing resets between explicit connections.

### Stability

- **Software Keyboard Recovery after iPhone Mirroring:** If iPhone Mirroring leaves behind a phantom hardware-keyboard claim, rootshell now trusts the visible software keyboard. Keyboard-dependent layout and toolbar behavior recover without waiting for the stale system state to clear.
- **Fixed Another Background-Termination Path:** Closed another background-termination path on iPhone and iPad: terminal and search fields, compose overlays and keyboard input views can no longer acquire focus or rebuild the keyboard while the device is locked.
- **Safer SSH Teardown:** SSH connection failure and teardown is safer after an update to the SSH engine, particularly when remote port-forward channels are active.

### AI Agents

- **Improved Codex Activity Detection:** Codex activity detection now works with custom model names, dynamic working labels, the default reasoning-effort label and elapsed timers over an hour, keeping tab status and attention indicators accurate.
- **Lower CPU Use for Active Agents:** Active coding-agent sessions use less CPU: their working indicator no longer drives SwiftUI's view graph. Rapid OSC/tmux title updates are coalesced, improving anything that rapidly changes terminal titles, a pattern common among coding agents.

### Standalone macOS

- **Configurable Local Shell:** Standalone macOS can choose its local shell in Settings -> Terminal -> Local Shell: the account login shell, a discovered installed shell or a custom command with arguments. Invalid entries warn and fall back safely; changes apply to new tabs.

## 1.0.10-135 - August 19, 2026

### SSH

- **Authentication Banners:** Servers can now tell you something during login. Authentication banners sent before you are logged in appear in a card over the pane as they arrive, with Open in Browser and Copy Link buttons for any http or https links. Tailscale SSH check mode works as a result (#290): the re-authentication URL it sends is now visible and tappable instead of being swallowed. Banners from a jump host are labeled as such so a hop's URL is never mistaken for the target's, the card also appears above the prompts in the two-factor sheet on iPhone, and the message survives a failed attempt, a password fallback, and a reconnect. Works over ssh, mosh and tssh.
- **Host Certificates on Every SSH Path:** Host certificates are now negotiated on every SSH path, not just the terminal one. With a trusted certificate authority configured for a host, mosh, tssh, Git over SSH and AI agent connections asked for a plain host key instead and could not verify the server. They now advertise certificate algorithms like a regular connection does.

### SSH Keys

- **Imported Keys Sync Across Devices:** An SSH key imported with a passphrase now works on your other devices (#285). Passphrases are device local and never sync, so a synced key would ask for one with nowhere to type it. Imported keys are decrypted once and stored under Keychain protection instead, and backups export them in the same form. Existing keys show their status in key settings, with an Unlock Legacy Key button to enter the passphrase one final time.

### macOS

- **Themes and Font Size on Intel Macs:** Fixed themes and font size not applying to the terminal on Intel Macs (#294). The terminal configuration failed to load at all on x86_64, so appearance changes only ever reached the app around it.

### Open Source

- **rootshell Is Open Source:** rootshell is now open source under the MIT license.

## 1.0.10-134 - August 13, 2026

### herdr

- **Deep herdr Integration:** herdr gets the same deep integration as tmux and zellij. It always ran fine when launched by hand or through a custom profile command; now the app understands it too. Connecting to a host running herdr lists its sessions in the session picker with running/stopped status, the agents active in each session, and a live preview of the focused pane. Attaching to a stopped session restarts it. Hosts that merely have herdr installed stay quiet; the picker only appears when there is a real session to offer.
- **Auto-Start herdr:** The per-connection "Auto-start tmux" option is now "Auto-start multiplexer" with Off, tmux, tmux -CC and herdr. herdr auto-start attaches to your session or creates it on first use, works under ssh, mosh and tssh, and syncs across devices like the tmux setting. Settings gains a herdr discovery toggle and an Auto-Start page for the session name and an optional custom command, with a preview of the exact command that will run.
- **herdr Command-Line Flag:** A --herdr flag is accepted on typed ssh command lines, alongside the existing --tmux.

### Security

- **Fixed Authentication for Synced Keys:** Fixed authentication for iCloud-synced SSH and GPG keys (#284). A key set to require Face ID or Touch ID could show the wrong prompt after syncing to another device.

### iOS and iPadOS 27 Beta 5

- **SwiftUI Beta Workarounds:** Worked around several Apple SwiftUI bugs in beta 5 of iOS and iPadOS 27: connection type tabs in the New Connection sheet ignoring taps, and a crash when the terminal's input accessory was rebuilt during a keyboard handoff between fields. The workarounds only activate on version 27.
- **More Reliable Connection Type Tabs:** If you are on beta 5 with an earlier build, including the current App Store release, the connection type tabs may need repeated taps before one activates. This build works around that, and hopefully Apple fixes the underlying bug in the next beta.

## 1.0.10-133 - August 12, 2026

### Screen Sharing

- **Faster Standard Mode on a Slow Network:** Standard Mode sessions respond faster on a slow network. Each coarse frame was held back while the sharper refinement pass finished, adding latency to every update on a busy link and, at worst, leaving the picture looking frozen. The wait is now bounded to a fraction of a second, so the picture keeps moving and sharpens as detail arrives.
- **Fixed Corruption with Adaptive Quality:** Fixed rendering corruption in Standard sessions using Adaptive quality. Tile-copy commands could copy from a stale tile left over from an earlier update, leaving misplaced 8x8 blocks on screen; copies are now validated against the update that produced their source.
- **No More Partially Drawn Desktop on Connect:** Connecting over a slow network no longer shows a partially drawn desktop. The first frame waits until the initial update covers the whole screen, and the gate is per connection, so a reconnect cannot let leftover drawing from the old connection slip into the new one.
- **Reorganized Session HUD Menu:** The session HUD menu is easier to scan: Type User Password at the top, viewport panning, zoom and curtain mode under a Display submenu, and the keyboard toolbar, quick actions and connection info under a Session submenu, with nothing hidden.

### Apple Pencil

- **Apple Pencil as a First-Class Pointer:** The terminal now treats Apple Pencil as a first-class pointer (#282). Apps that capture the mouse, like nvim and herdr, get a precise pointer: pen-down clicks exactly where the tip lands and dragging is a mouse drag. Everywhere else the pencil matches your finger: tap to click, selection gestures and scrolling. A barrel double-tap sends a right-click to the pane under the pencil, and Scribble is suppressed because it double-typed words into the terminal.
- **Pencil in Screen Sharing:** Screen Sharing gets the same treatment: the remote pointer moves to the landing spot before the first tap registers so remote UIs respond in the right place, drags and hover pan the viewport while zoomed in, and a barrel double-tap sends a remote right-click.
- **Steady Layout on the iPadOS 27 Beta:** On the iPadOS 27 beta, a pencil tap on a focused terminal made the system present a minimized keyboard pill, and the layout jumped around it. The pill is now suppressed and the layout holds still.

### Keyboard

- **Hardware Keyboard Settings on iPhone:** Hardware keyboard settings now appear on iPhone instead of being iPad-only, part of ongoing work for the Clicks Power Keyboard.
- **Steadier Key Toolbar on iPhone:** With a hardware keyboard on iPhone, the key toolbar sits at the bottom of the screen, and its height no longer jumps while swiping tabs.
- **Toolbar Keys Yield to the Home Gesture:** Toolbar keys no longer fight the Home gesture: a swipe up from the bottom edge that starts on a key now cancels cleanly instead of typing into the terminal. Keys there fire on release, and holding one still auto-repeats. With the gesture handled, the reserved gap below the toolbar is gone in more cases, on iPad too, and the terminal gets the space.

### AI

- **Fixed Anthropic-Compatible Custom Providers:** Fixed custom providers pointed at Anthropic-compatible servers (#281). The Endpoint URL field meant opposite things depending on the API format, so one format always requested a URL the server does not route. The typed URL now resolves to the correct API root for the selected format, and the editor shows the exact chat and model-list URLs it will request, live as you type.
- **Custom Providers Without an API Key:** Custom providers no longer require an API key. Local servers like Ollama, LM Studio, oMLX and llama.cpp commonly run without credentials, but a keyless provider used to vanish from the picker. With no key saved, no Authorization header is sent, which matters for servers that reject an unknown token.
- **Model Discovery for the Anthropic API Format:** Model discovery now understands the Anthropic API format; previously models could only be listed from OpenAI-format endpoints.
- **Clearer Provider Errors:** Errors from custom providers now surface the server's own message instead of a generic "Model Unavailable", and authentication and rate-limit failures are classified from the HTTP status even when the error body is unusual.
- **Editor Cleanups:** The API key field shows the saved key, clearing it deletes the key, and discovered models are only kept if you save.

## 1.0.10-132 - August 9, 2026

### Stability

- **Fixed Background Termination on iOS and iPadOS:** Fixed a background termination seen in crash reports since 1.0.9. The system kills any app that draws to the screen while the device is locked, and several paths could still trigger a frame while the app was long-backgrounded: tmux control mode traffic selecting a tab, sessions restoring in the background, and Screen Sharing panes, which never paused at all. Rendering is now latched off from the moment the app leaves the foreground until it is active again, and Screen Sharing panes suspend frame presentation alongside the terminals.
- **Fixed a Hang That Froze the Whole App:** Fixed a hang that froze the app until the system killed it, most commonly seen as herdr crashing the app on launch. The flaw has been in the terminal engine since tmux control mode arrived in build 101: output dense with title updates or terminal queries could deadlock the parser against the rest of the app. Coding Agents detection in build 128 made it much easier to hit, since herdr's dashboard produces exactly that output. The parser no longer holds the contested lock while it waits, and the agent scanner backs off instead of blocking on a busy terminal.

### macOS

- **Window Transparency Survives Reopen:** Fixed window transparency lost on reopen (#279). Closing the last terminal window and bringing the app back from the Dock or with Cmd-N returned a fully opaque window even though transparency was enabled. Background opacity and blur now survive reopen, and the window re-asserts its appearance if the system repaints it later.
- **Dock Icon Opens a Window Again:** Clicking the Dock icon with no windows open did nothing if the visor had ever been summoned and hidden. The hidden visor was silently swallowing the reopen; a new terminal window now opens as expected.
- **Hidden Visor No Longer Leaks Into Window Geometry:** Relaunching the app could size the new main window like the visor, and a reopened window could come up in the wrong position because the invisible visor counted as an existing window. Both paths now ignore it.
- **Transparent Pinned Sidebar:** A new appearance option. When the vertical tab sidebar is pinned, this applies the window's background opacity to the sidebar instead of its normal opaque fill, so the whole window reads as one translucent surface. Settings, Appearance, Transparency, off by default, and included in settings backups.

### Git

- **Updated Git Engine:** The engine behind the built-in git command (libgit2) was updated to the latest upstream. Path-filtered history commands like git log -- <path> now use commit-graph Bloom filters when the repository has them, which can make those walks dramatically faster, and repositories using Git's newer reftable reference format read more reliably.
- **Correctness and Stability Fixes:** git blame no longer crashes on hunks with a missing summary, git apply accepts patches that add or remove an empty file, merges and checkouts position directory/file conflicts correctly in the index, shallow clones are detected properly when working from a linked worktree, and HTTPS authentication prompts for the right host after a redirect. Submodule paths are now also checked so a hostile repository cannot use them to escape the working tree.

### Profiles

- **Terminal Type Picker:** The per-profile Terminal Type override moved from a cramped inline text field to its own picker screen. It shows the inherited global default, the common presets, and a Custom entry with validation warnings, and the profile form now displays a compact summary that stays readable on narrow screens.
- **Corrected VPN Wording:** The profile editor's VPN section now correctly states that VPN tunneling on macOS requires the standalone version; the App Store build previously claimed VPN was only available on iOS and iPadOS.

## 1.0.10-131 - August 5, 2026

### Terminal

- **Configurable Terminal Type:** The terminal type (TERM) is now configurable (#276). Settings, Terminal, Terminal Type sets it separately for the local shell and for remote sessions, and each connection profile can override the remote value in Terminal Options. The override syncs with your profiles and survives reconnects, session restore and ssh:// links. The macOS local shell now defaults to xterm-ghostty with the matching terminfo bundled, so full Ghostty capabilities work with nothing installed on the system. Remote sessions keep the safe xterm-256color default, since not every host knows xterm-ghostty.
- **Steadier Terminal on the iOS 27 Beta:** On the iOS 27 beta, opening the tab switcher or Settings on iPhone made the terminal wobble up and down before settling; it now holds perfectly still there too, and opening the tab sidebar can no longer occasionally drop the keyboard-preservation trick mid-swipe.

### Clipboard Manager

- **Unwrap Paragraphs and Wrap to Width:** Two new text transforms, in a Format submenu on every entry. Unwrap Paragraphs removes the hard line breaks text picks up from a PDF, an email or an 80-column terminal, and Wrap to Width re-flows paragraphs to a column budget. Bullet and numbered lists, block quotes, code blocks, headings and tables all keep their structure, and widths are measured in display cells so CJK and emoji stay inside the budget.

### Screen Sharing

- **Sessions Survive a Trip to Another App:** On iOS and iPadOS, Screen Sharing sessions no longer drop after briefly switching to another app. The system reclaims the connection seconds after backgrounding, and every return then cost a full reconnect that looked like a network fault. Screen Sharing panes now hold the same short background keepalive that terminal sessions already had. macOS was never affected.
- **Immediate Reconnect on Return:** When a session does drop while backgrounded, returning to the app now reconnects immediately instead of waiting out a retry delay meant for real network faults. High Performance sessions are still unlikely to survive backgrounding, since the system reclaims the hardware video decoder, but this makes their reconnect fast.
- **Stalled High Performance Streams Recover:** A High Performance video stream that stalls now recovers by requesting a fresh stream from the Mac, rather than tearing down the session and re-running authentication.
- **Crash Fixes:** Fixed a crash reported on build 130, where a desynchronized Screen Sharing data stream could declare a payload over a gigabyte in size and trying to honor it ran the app out of memory; absurd sizes are now refused and end the session with a clean protocol error. Also fixed a crash on iOS 26 when a full-screen Screen Sharing session tried to show its connection-failure card.

### Files

- **Non-ASCII Input in the File Browser:** On iOS, iPadOS and visionOS, the rf file browser accepts non-ASCII typed input: renaming a file to a Chinese name now works, as do accented characters and emoji everywhere rf prompts for text. Key handling got a deep cleanup along the way; Escape registers immediately instead of waiting for the next keystroke, and an unrecognized key combo no longer swallows the next characters you type.

### Settings

- **Certificate Authorities Title Fits Again:** The Certificate Authorities screen no longer truncates its title to make room for Clear All; clearing moved to a destructive row at the bottom of the list, matching how Remove Authority works.

### AI

- **Sign In to OpenAI with ChatGPT Plus or Pro:** The OpenAI provider can now sign in with a ChatGPT Plus or Pro subscription instead of a metered API key. Sign in with your ChatGPT account and the model list comes straight from your subscription. Each model gets its own reasoning-effort preset, offering the levels that model actually supports, switchable from a capsule next to the model picker on wide layouts or from the model picker itself on narrow ones.

## 1.0.10-130 - August 2, 2026

### Terminal & Keyboard

- **Faster, Smoother Overlays with the Keyboard Up:** With the on-screen keyboard up, the app feels dramatically faster and smoother, most of all on iPhone. Opening and closing the tab switcher or Settings used to dismiss the keyboard and reflow the terminal twice, sending remote sessions two resizes per round trip, so every switch had a visible hitch. The terminal now holds its exact size and position for the whole trip, so overlays glide over a perfectly still terminal, and it settles once only if something really changed while the overlay was open, like a rotation or a hardware keyboard attaching. This also fixes the Screen Sharing on-screen keyboard staying off after a visit to Settings.
- **Held Modifier Combos Repeat Again:** iOS 26 stopped auto-repeating modifier combos, so a held Shift+Return, arrow, Tab, Escape or F-key delivered a single press.
- **Docked Sidebar Clearance:** With the tab sidebar docked, the keyboard toolbar and full software keyboard no longer cover its lower rows and usage footer.
- **Crash Fixes:** Fixed crashes opening the tmux session dashboard from the floating tab sidebar, and opening settings on iPad and macOS with a cursor effect enabled.

### Privacy

- **Auto-Redact Masks Personal Strings On Screen:** Keep a list of sensitive strings, your name or email address for example, and the terminal draws them as bullets so they never appear in screenshots or screen recordings. Masking is display-only; selecting and copying still produce the real text. The list is stored encrypted in the keychain; set it up in Settings, Privacy & Data, Auto-Redact. Toggle redaction with Ctrl+Cmd+R or from the View menu.

### Shortcuts

- **New Apple Shortcuts Actions:** Open Local Shell, Open SSH Connection, Run Command over SSH, and Get Connection Profiles. Run Command executes in the background and returns output, exit code and stderr to your Shortcut; keys that need Face ID continue in the foreground. Profile properties are exposed so Shortcuts can chain on them, and a Shortcut run now survives a cold start and opens exactly one tab instead of one per window.

### Profiles

- **Searchable Icon Catalog:** The profile icon picker grows from a fixed grid of 28 icons to a searchable catalog: about 180 SF Symbols, 95 Nerd Font developer icons covering language and tool logos, and website favicons fetched from the profile's host or any hostname you enter. The editor preview now tints with the profile's color tag. A website icon whose fetch once failed, common for profiles synced from another device, retries instead of staying blank.

### SSH

- **Passkey-Backed SSH Keys on visionOS:** Passkey-backed SSH keys are now available on visionOS.
- **Clearer Passkey Provider Wording:** The passkey key screens no longer describe keys as iCloud Keychain only; they have always gone to whichever passkey provider you use, 1Password included.

### Agents & Commands

- **oh-my-pi Detection and Usage:** oh-my-pi is now detected as an agent, and the usage tracker covers it. One omp sign-in can hold logins for many providers, so instead of reading credentials the app asks omp itself for its usage report. Each provider shows its own mark in the usage footer. A freshly launched agy is also recognized right away instead of after its greeting appears.
- **Fixed Copilot Approval Dialogs:** Fixed Copilot approval dialogs showing as Working instead of Needs Input. Copilot keeps its progress indicator running while a dialog waits for you, and that report was overwriting the detected prompt in the card, tab badge and rollup. A detected prompt now always outranks a progress report.
- **Sharper Copilot Prompt Detection:** Copilot dialogs whose only hint is "esc to cancel" are now detected as needing input, and detection reads the live end of the screen, so a dialog you already answered no longer keeps the tab pinned as needing input.

### Appearance

- **Photo Background History:** Photo backgrounds keep a history: past imports appear under My Photos; tap one to switch back. Photos stay on this device.
- **Animated YubiKey Prompt:** The YubiKey insert prompt is now an animated illustration, with a haptic cue when it's time to touch.
- **Theme Fixes in Settings:** Fixed spots in Settings that ignored the selected theme.

## 1.0.10-129 - July 30, 2026

### SSH

- **Passkey-Backed SSH Keys:** sk-ecdsa keys no longer require a hardware security key: generate one backed by a passkey instead. Your passkey provider, iCloud Keychain or a third-party manager like 1Password, creates and holds the private key and syncs it, so a key generated on your iPad is ready on your iPhone and Mac. rootshell never sees key material, only signatures, and Face ID, Touch ID, or the passcode confirms each one. Servers see a standard sk-ecdsa-sha2-nistp256 key, and it works everywhere the security-key type did, agent included. External security keys remain fully supported.

### Agents & Commands

- **Subscription Usage in the Tab Bar:** The vertical tab bar shows Claude, Codex, and GitHub Copilot subscription usage, so you see how much of your plan's window is left before an agent hits the limit. A compact footer shows a row per provider; the popover has reset countdowns, per-model breakdowns, and a pace mark. The numbers come from the hosts your agents run on: the app reads the agent's stored sign-in over the session's connection and asks the provider. On a remote Mac Claude keeps its sign-in in the keychain, which a remote session cannot read; the app bridges through a tmux server started from the desktop session, so Claude usage there needs that tmux with the keychain unlocked. Sign-ins never leave memory, are never logged, and are dropped when the feature is off; only usage figures and plan labels persist. The switch is in Settings, Agents & Commands, Coding Agents.
- **Long-Running Commands in the Sidebar:** The sidebar now tracks long-running commands, not just agents: builds, test runs, deployments, file transfers, and password or confirmation prompts like sudo and SSH host keys. They appear as cards the way agents do, badged while running, marked unread when they finish unseen, and notifying when one blocks on input. Programs reporting progress with OSC 9;4 feed the same cards: a percentage on a detected run, or a plain Activity card. Detection reads the pane's screen on device; nothing is installed on the server. Off by default: Settings, Agents & Commands, Command Detection picks what to watch.
- **Updated Agent Detection:** Detection keeps up with Copilot CLI's redesigned interface and Codex fast mode.

### Locale

- **Fixed setlocale Errors on Remote Logins:** Fixed remote logins spamming setlocale errors when the device language and region pair isn't a real server locale (#272). iOS pairs your UI language with your region: English in Mexico got LANG=en_MX.UTF-8, which Linux servers have no data for. Auto mode now validates the pair against libc's locale list and substitutes a same-language locale servers actually ship. Script subtags and Latin American Spanish steer to the right locale, and Chinese devices no longer send the malformed zh_Hans-CN. Settings, Terminal, Locale explains any substitution and warns on unlisted custom locales.
- **tssh Honors the Locale Setting:** tssh sessions now honor the locale setting, omitting LANG and LANGUAGE when forwarding is off.

### Screen Sharing

- **Audio and Video in Sync:** Audio and video now play in sync in High Performance mode. Remote audio is deliberately buffered against jitter, but video displayed as soon as it decoded, so sound trailed the picture. Video is now scheduled against audio playback on the server's clock.
- **Fixed Round-Trip Estimates:** The timing feedback returned to the Mac mixed up the audio and video streams' reports, muddying the round-trip estimate that steers adaptive bitrate; it's now kept per stream.

### Tabs

- **Group Pill in the Top Tab Bar:** When tabs are grouped, the top tab bar shows a pill naming the active group or project; tap it to jump to another. Settings, Appearance, Window, Show Group Menu turns it off.
- **Stable Grouped Tab Ordering:** Each grouping keeps its own order that survives a restart, and reordering in a group no longer scrambles the flat order.
- **iPhone Sidebar Safe Area:** On iPhone the tab sidebar now uses the bottom safe area, so its last rows aren't clipped.
- **Gateway Row Highlighting:** The tmux gateway row now highlights like other group headers, and group titles dim when the active tab is elsewhere.

## 1.0.10-128 - July 29, 2026

### Coding Agents

- **Agent Inbox in the Tab Bar:** The vertical tab bar now has an agent inbox. rootshell recognizes coding agents (Claude Code, Codex, Cursor, Copilot, OpenCode, Antigravity, and Pi) running in any tab and shows each as a card with its logo and live status: working, waiting for your input, or done. Detection reads the terminal screen on device, so it works identically for local shells, SSH, tssh, and tmux control mode panes, with nothing to install on the server. A notification fires when an agent needs attention or finishes, once per event, and a Claude Code session that delegates to background agents is tracked through the wait instead of being reported done early. Split tabs are pane-aware: each pane running an agent gets its own nested row in the tab bar, and tapping it focuses that exact pane.
- **Best Setup for Detection:** The inbox works best when each agent has its own pane the app can see: a regular SSH or tssh session, or a tmux control mode pane. Agents inside a plain tmux, zellij, or herdr session are detected too, but those sessions render one shared screen, so tracking follows the window in view. For most users the optimal setup is tssh plus tmux control mode.
- **Group the Inbox by Project:** The result is one robust view of everything you have running, shown in the vertical tab bar: group the inbox by project to see each project's agents side by side, each card naming its git branch. This works in regular SSH, tssh, and mosh sessions and tmux control mode panes, not plain multiplexers. Free evidence like OSC 7 is always used; anything that runs a command on your connection sits behind a new Look Up Project Details switch.
- **Restructured Settings:** The Coding Agents and Multiplexers settings screens were restructured, moving the long-form detail to new How Detection Works and tmux Tips guide pages.

### SSH

- **Post-Quantum Keys:** Generate or import hybrid ML-DSA-44 + Ed25519 keys (the ssh-mldsa44-ed25519 type OpenSSH 10.4 ships), verified end to end against real OpenSSH 10.4, host keys included. They work through ssh-add and agent forwarding. Pure ML-DSA-44/65/87 keys are available as an experimental option for OQS-style servers; standard OpenSSH servers do not accept them, 65/87 require iOS 26, and import is seed-format only (expanded-secret keys are rejected).
- **Fixed AES-GCM Crash:** Fixed a crash that could strike mid-session when the negotiated cipher was AES-GCM: the packet writer reserved header space in a way that traps at a buffer capacity boundary. The same trap existed in the buffer writers used by jump-host connections.

### tmux Control Mode

- **Three Tab Title Fixes:** A fresh window no longer shows the tmux server's host name as its title; it now falls back to the running command. Titles no longer corrupt into replacement characters or blanks when a second client attaches to the same session. And renaming a different session on the same server no longer renames your tabs.
- **Gateway Tab Names the Session:** The gateway tab now shows the tmux session name and tracks renames.
- **Fixed Session Loss on Reconnect:** A tssh reconnection could silently discard the probe that confirms tmux is still alive, so the gateway concluded the session had exited and closed every window. The probe is now re-sent, so reconnecting no longer costs you the session.

### Screen Sharing

- **Fixed Mid-Session Drops:** Fixed mid-session "Connection interrupted" drops on a healthy local network: the dead-peer keepalive was too aggressive for an idle desktop, and an advertised encoding without a parser could desynchronize the stream. A session that loses its video now fails cleanly rather than rebuilding forever.

### Terminal

- **Fixed Crash After Moving a Pane:** Fixed a crash when switching tabs after a tmux move-pane or break-pane left one pane referenced by two tabs.
- **Fixed Crash on Theme Change:** Fixed a crash when a theme change raced a closing tab.
- **Quieter Bells:** Bells no longer pile up while the app is backgrounded and fire all at once on return, and bells the app provokes itself, like the repaint after a tssh reattach, are dropped.

### Tabs

- **Wrapping Sidebar Tab Titles:** Sidebar tab titles can wrap: Settings, Appearance, Window, Tab Bar, 1 to 3 lines.

## 1.0.10-127 - July 26, 2026

### Battery

- **Adaptive Refresh Rate:** The refresh rate can now follow the power source. A new Adaptive option in Settings under Appearance, Battery runs at full speed on wall power and applies a cap you pick, 60 or 30 Hz, only once the device is on its own battery, so there is nothing to flip by hand on every unplug. Low Power Mode and thermal throttling still bite while charging, since charging is exactly when a device runs hot. A plug or unplug that happens while the app is suspended is picked up on the way back to the foreground, so a session never comes back pinned at a stale frame rate. On a Mac the power source is read from IOKit, which reports it reliably where the iOS battery API does not.
- **Fixed Theme Overrides Reverting:** Fixed per-tab and per-window theme overrides quietly reverting to the global theme. Any reload of a cursor, selection, or palette setting pushed the global configuration over the top of every surface. It was hard to hit before; the new power-source trigger would have made it happen on every plug and unplug.

### Connections

- **Endpoint Survives a Protocol Switch:** Switching a profile between SSH and Screen Sharing keeps the endpoint you already typed. The two protocols hold entirely separate sets of fields, so flipping the picker in the profile editor, or the tab in the connect sheet, used to blank the host you had just entered, in both directions. Host, username, and a manually entered jump host now carry across. Ports stay put, because 22 and 5900 describe different things. The app only writes into a field that is still blank or still exactly what an earlier switch left there, so editing a carried field, or attaching a password to that form, hands it back to you for good and keeps a secret typed for one host from being filed under another. The editor also now says out loud what it never did: saving after a switch across the Screen Sharing boundary replaces the stored settings for the other protocol.

### tmux Control Mode

- **Fixed Zoom on the First Pane:** Zoom works on the first pane of a control mode window. The layout update from tmux used a zero pane id to mean "nothing is zoomed", but zero is a real pane, so zooming the very first pane of a window looked like a no-op while every later pane zoomed normally. The context menu title was wrong for the same reason. Fixes issue #266.
- **Control Mode for Local Shells (macOS):** A local shell on macOS can attach in control mode. The Control mode switch in the session picker never appeared for local shells, so an attach from one silently became a plain tmux attach with no split, tab, or window integration. The local shell on iOS and visionOS has no pty and still cannot run tmux.

### Terminal

- **Sessions Identify as rootshell:** LC_TERMINAL is set to rootshell and LC_TERMINAL_VERSION to the version and build, for local shells and for SSH, tssh, and jump-host sessions alike. LC_* is the one namespace that stock ssh_config and sshd forward by default, so the marker survives the connection and every further hop you make from it, which lets a prompt or a script tell a rootshell session apart from any other terminal. A server that does not accept the variables simply ignores them. TERM stays xterm-256color and TERM_PROGRAM stays ghostty, so anything sniffing those for capabilities is unaffected.
- **Real Version for Local Shells (macOS):** Local shells on macOS now report the real app version instead of a placeholder 1.0.0.

## 1.0.10-126 - July 24, 2026

### Screen Sharing

- **Curtain Mode:** When you connect to a Mac that offers it, the session menu now has a Curtain toggle that blanks the remote Mac's own display while you keep control, so anyone at that machine sees only a lock screen, with an optional message you can leave on it. The state shown is the one the server reports, so if the Mac never confirms the switch the app tells you it failed rather than claiming a privacy guarantee it does not hold. Curtaining restarts screen capture on the remote side, so expect a few seconds before the picture settles. The toggle only appears when the remote Mac has Remote Management turned on in System Settings under General, Sharing: the plain Screen Sharing checkbox is not enough, and a Mac sharing that way never offers curtain mode. Sessions using Match Client display sizing do not need any of this, since they already run on their own virtual display that the Mac's real screen never shows. Connection Info reports whether the server offers curtain mode and whether the display is currently curtained.
- **Option and Command Arrow Chords:** Option and Command arrow chords now reach the remote desktop on macOS. macOS claims those chords for its own cursor movement before any app sees them, so Option-Left, Command-Right, and friends previously did nothing in a Screen Sharing session. They are now read straight from the keyboard hardware and sent as one atomic remote chord, with key repeat while you hold them, so word and line jumps behave as they do at the remote Mac.

### Terminal

- **Option as Alt Under Remote Control (macOS):** Option key combinations now act as Alt when someone is driving your Mac remotely, over Screen Sharing or another remote-control tool. Option-Left and Option-Right moved by a single character instead of by word, and Option-Escape and Option-Tab lost their modifier entirely, because the terminal only trusted Option presses from a physical left or right key. Typing at the Mac itself is unchanged.

### Visor

- **Fixed Visor Grid Taller Than Its Window:** Fixed the visor terminal keeping a grid taller than its window, which pushed the bottom rows, usually the shell input line of a multi-line prompt, past the visible bottom edge. Manually drag-resizing the visor panel poisoned every later summon, because the snap back to your configured size was mistaken for a no-op and dropped. A surface that has already drifted now heals itself: the grid is compared against the window on each summon and re-sized only when the two disagree, so a healthy visor costs no extra resize and remote programs see no spurious redraw. A tab created or restored while the visor is animating is also sized before its first frame. Reported in issue #261.

### tmux Control Mode

- **Fixed Zoom Split in tmux Windows:** The zoom split shortcut now works in tmux windows. It zoomed the local split without telling tmux, so the next layout update from the server wiped it, and on side-by-side splits the zoom un-zoomed itself immediately. It now goes through tmux the way the context menu item does, so the zoom sticks and stays in sync with other clients. Fixes issue #260.

### SSH

- **Password Auth for Install Key on Server:** Install Key on Server can authenticate with a password again. The sheet hid the password field as soon as you typed a host, treating your app-wide default key as proof the server would already accept a key, leaving no way to bootstrap the first key on a brand-new server. There is now an explicit Password, Saved Password, or SSH Key picker, defaulting to Password unless a saved password matches that exact host, port, and user, and a saved password that stops matching the server you are editing is dropped rather than sent somewhere else.
- **Keyboard-Interactive Key Installs:** Servers that require a keyboard-interactive challenge, such as PAM prompts, two-factor codes, and one-time passwords, now complete the key install instead of failing with a correct password.

### AI

- **Claude Opus 5:** Claude Opus 5 replaces Opus 4.8 as the premium Claude tier, over both the direct Anthropic API and Bedrock. If Opus 4.8 was your selected model, it is migrated on launch.

## 1.0.10-125 - July 22, 2026

### Screen Sharing

- **Fixed Option Keys on Mac Hosts:** Fixed Option keystrokes arriving as Command when connected to a Mac. Apple's Screen Sharing server swaps the X11 modifier convention, so sending Option the standard way made the remote Mac hold Command instead: Option-Delete wiped the whole line back to its start as Command-Delete instead of deleting a word, and Option arrow word-jumps turned into line-jumps. Option is now translated correctly on Apple servers, across hardware keyboards, the on-screen modifier buttons, the keyboard toolbar's chords, and the Force Quit remote command, which was silently collapsing from Command-Option-Escape to Command-Escape. Connections to standard VNC servers are unchanged, so Alt shortcuts like Alt-Tab still work there.
- **Screen Sharing Defaults in Settings:** Settings has a new Screen Sharing page with defaults for newly opened sessions. Default Clipboard Sync can be Auto, Off, or Always On: Auto enables the shared clipboard only when the connection is protected by an SSH or tssh tunnel, VeNCrypt TLS, or Apple ComCryption, and flipping the toggle inside a session always wins over the default. Screen Panning picks whether new sessions pan when the pointer reaches the screen edge or continuously with the pointer.

### Keyboard

- **Shift Releases After Toolbar Keys:** A shifted on-screen keyboard Shift now releases after typing one toolbar key, the same way it does after typing a letter. Before, tapping Shift and then a toolbar arrow or symbol left Shift latched for the following keystrokes. Caps lock stays latched, as it should.

## 1.0.9-124 - July 20, 2026

### Keyboard

- **Toolbar Keys Follow System Shift:** On-screen toolbar keys, including Tab, the arrows, symbols, and your custom keys, now follow the system keyboard's Shift, whether you latch it, turn on caps lock, or hold Shift on a hardware keyboard. Before, only the toolbar's own Shift counted, so you can now drop the toolbar's Shift key if you prefer and reclaim that space. Shift and Control-Shift arrow keys now send the standard terminal sequences too.

### Connection Info

- **Live Performance for tssh:** tssh connections now have a live Performance section, mirroring the one Screen Sharing already had: round-trip time with variance, downlink and uplink bitrate, bytes and packets sent and received, plus KCP round-trip timeout and retransmits, or QUIC minimum RTT and packet loss, depending on which transport the connection is using. The numbers refresh once a second only while the sheet is open, and drop to placeholders after a reconnect swaps the transport out from under them. KCP byte counts are measured at the UDP wire level.
- **Connection Info on tmux Windows:** Connection Info now opens on tmux window tabs. A tmux control-mode window has no connection of its own, so the menu item was always greyed out. It now reports through the gateway session that carries the window.

### Screen Sharing

- **Fixed Trackpad Right-Click:** Fixed a trackpad secondary click not opening the context menu on the remote desktop on macOS. macOS delivers that click as a button event that never reached the tap handling, so nothing happened. It now right-clicks, without disturbing drags, which already worked.

### Tabs

- **Tab Hover Highlight:** Hovering a tab you are not currently on in the top tab bar now lights it with a soft glass capsule, instead of only revealing its close button. Reduce Transparency and Increase Contrast get a flat fill in its place.

## 1.0.9-123 - July 19, 2026

### Battery Optimizations

- **Battery Settings Page:** Added a Battery page to Settings under Appearance. Cap the refresh rate at Auto, 60, or 30, and rootshell now also throttles itself under Low Power Mode or thermal pressure, slowing background effects, simplifying the animated cursor to a classic blink, and redrawing the terminal less often, all applied live.
- **Idle Means Idle:** An idle rootshell now actually goes idle. The settings and connection panels and the animated About icon kept working even while hidden, enough to keep the CPU from ever quiescing. They now do nothing until you open them.
- **Quieter tssh Sessions:** Idle tssh sessions no longer wake the app every second to check connection health. Timeouts and recoveries are reported the moment they happen, the roaming banner only redraws when something changed, and the transport sleeps while no traffic flows. The reconnecting banner's seconds counter now ticks up too.

### Screen Sharing

- **Connection Info for Screen Sharing:** Connection Info now works for Screen Sharing sessions, from the HUD menu or a tab's context menu. It shows the negotiated authentication method, encryption status, protocol version, live resolution, and routing including any jump host, plus live performance stats: bitrate, packet loss, delay, and frame counts in High Performance mode; throughput, data received, and encodings in use in Standard.
- **Fixed iPad Trackpad Drags:** Fixed iPad trackpad drags on the remote desktop cancelling before they started, most visibly on Finder items. A secondary button still right-clicks, and the remote pointer now follows your drag instead of freezing.
- **Reliable Login Window Typing:** Typing your saved password at the Mac login window is now reliable, and sent exactly once. During High Performance setup the tap could silently vanish, half-type into a restarting display, or re-offer the prompt after you were already in. Delivery now waits for the display to hold still, survives automatic reconnects, clears the field and stuck modifiers first, and never types more than once per confirmation.
- **Hidden Shortcut Routing Control:** The keyboard shortcut routing control no longer appears when no hardware keyboard is attached.

### SSH

- **Fixed Remote Forward Crash:** Fixed the app crashing the moment a connection arrived on a remote forwarded port (`-R`), a regression dating back to when Multipath TCP support was added in February.
- **Fixed Low-Memory Output Crash:** Fixed a crash under sustained heavy terminal output when the device is low on memory. Buffered output is now queued in chunks and sheds the oldest data instead of growing one buffer until allocation fails.

### Files

- **Open Shared Files in rootshell:** Files shared from other apps can now open directly in rootshell on iPhone, iPad, and Apple Vision Pro. Choose rootshell in the share sheet and the file opens in a new local-shell tab in your editor, honoring `EDITOR` from `~/.rootshellrc`, with `hx` as the fallback. A copy lands in the incoming folder in rootshell, leaving the original untouched. On iPad it joins your frontmost window instead of spawning a new one.

### Appearance

- **Fixed Hide Title Bar Glass Strip:** Fixed Hide Title Bar on macOS 27 leaving a blurry glass strip where the tab bar normally sits; content now reaches the top edge. The tab, connection, and settings panels reach the top edge too, instead of starting below a sliver of terminal.
- **Centered Tab Indicator HUD:** The tab indicator HUD now centers over the terminal rather than the window, so it no longer looks off with the tab sidebar pinned or the AI agent sidebar open.

### Security Keys

- **Fixed YubiKey Wait CPU Spin:** Fixed cancelling the wait for a wired YubiKey pinning a CPU core until the app quit: the wait loop kept polling for devices at full speed. Cancelling now stops immediately and reads as a cancel, not a red error.
- **Fixed Long PIV PIN Crash:** Fixed a crash when a YubiKey PIV PIN longer than 8 characters was entered, a bug in Yubico's upstream SDK now patched in rootshell's copy. It was a stability issue only, never a security risk. The unlock prompt also requires a valid 6 to 8 digit PIN and re-prompts instead of crashing.

## 1.0.9-122 - July 17, 2026

### Screen Sharing

- **Fixed High Performance Black Screen:** Fixed High Performance mode showing a black screen, which hit most people connecting to a Mac found in Browse. Those Macs are identified by their `.local` name, which answers on both IPv4 and IPv6, and rootshell resolved it separately for the connection and the video, so the Mac could send video to an address rootshell was not listening on. Video now follows the address the connection reached, which also covers IPv6-only networks, mesh VPNs, and link-local addresses.
- **Log In at the Mac Login Window:** Macs at the login window or lock screen now offer to log you in, typing your saved password and pressing Return. rootshell always asks first, never shows the password, and only offers when you have saved one. A new Prompt at Mac Login toggle in the connection form's Authentication section controls this, on by default.
- **On-Device Login Detection:** macOS never tells a screen sharing client that it is sitting at a login screen, so rootshell spots it by looking. A vision model reads the first few frames and decides whether it is a password prompt, counting only text in the strip where macOS puts the password field, in every language rootshell ships in. It runs entirely on this device using Apple's Vision framework: no frame, and no text read from one, ever leaves your device or is recorded. It only looks with the toggle on and a password saved.
- **Real macOS Pointer in High Performance:** The real macOS pointer now appears in High Performance mode, not just Standard: I-beam, resize arrows, and pointing hand. It also no longer grows and shrinks as you zoom on macOS.
- **Brightness Boost on VNC Panes:** Brightness Boost now works on VNC panes, lifting highlights into HDR headroom on an EDR-capable display. Reach it with the keyboard bar's brightness button, which used to do nothing there, or Command-Control-B.
- **Right-Click and Middle-Click Fixed:** A trackpad or mouse can now right-click on the remote desktop, and right-click and middle-click are no longer swapped on Macs: Apple numbers its buttons in the opposite order from standard VNC, so a two-finger tap landed as a middle-click. Two-finger tap still right-clicks by touch.

### Screen Sharing: Panning and Scrolling

- **Screen Panning:** Added Screen Panning to the HUD menu, for moving around a remote screen zoomed in past what fits. When Pointer Reaches Edge, the default, scrolls as your pointer nears the edge, accelerating the closer you get, and works mid-drag. Continuously with Pointer maps the pointer's position onto the pannable area. Both need a trackpad or mouse; touch and pinch are unchanged.
- **Native Touch Scrolling:** Touch scrolling now behaves like a native scroll view. Line-based apps such as Terminal.app no longer race far past what your finger travelled, and fling momentum is measured the way native scroll views measure it, so a wobble as you lift no longer throws the screen backwards.
- **Tap to Stop a Fling:** Touching the screen now catches a fling in progress and stops it, without clicking or starting a drag on the remote desktop. This works for touch, trackpad taps, and Apple Pencil.

### Appearance

- **Hide Title Bar on macOS:** Added Hide Title Bar on macOS, which removes the title bar and window controls so content reaches the top edge. Drag the window by its top edge, close with Command-W, full screen from the View menu. In Settings under Appearance, off by default, also on Command-Shift-H.
- **Fixed White Tab Pill:** Fixed the selected tab rendering as a bright white pill over a dark theme on macOS, most visibly when the window was inactive (#250). It showed up with Appearance Mode forced to Dark while the system was in Light and Reduce Transparency or Increase Contrast on, which replaces Liquid Glass with a flat fill resolved against the system appearance.
- **Window-Level Appearance Mode:** Appearance Mode is now enforced at the window level, so system materials, blurs, and the macOS titlebar follow your forced Light or Dark choice, across new, restored, visor, and AI agent windows.
- **Fixed Floating Tab Sidebar Header:** Fixed the floating tab sidebar's header sitting underneath the traffic light buttons on macOS.

## 1.0.9-121 - July 15, 2026

### Screen Sharing

- **Your Mac's Screen, Not Just Its Shell:** rootshell now connects to your Mac's screen, not just its shell. Reach your Mac and other machines from every platform rootshell runs on: iPhone, iPad, Mac, and Apple Vision Pro.
- **High Performance Mode:** High Performance mode streams adaptive-bitrate HEVC over UDP, decoded on the GPU through Metal and tuned for Apple silicon. It runs up to 4K at 60 FPS and up to 60 Mbps, tracking the network as conditions change, and is at its best on a fast local network. Video and audio are encrypted with AES-256 SRTP, keyed by the authenticated handshake.
- **Nothing to Install on the Mac:** Turn on Screen Sharing in System Settings and connect.
- **Match Client Sizing:** Match Client sizing is the setting to turn on first. In High Performance mode your Mac spins up a real virtual display, named "rootshell Virtual Display", sized exactly to the iPhone or iPad you are holding. The desktop arrives fitting your screen: no panning, no scaling, no letterboxing, and it follows your rotation.
- **Remote System Audio:** Remote system audio plays on this device, on by default. It routes through the virtual display, so it needs High Performance with Match Client on.
- **Standard Mode:** Standard mode is ordinary RFB over TCP for constrained networks, VPNs, and non-Mac servers, with an Adaptive or Full Quality choice. Authentication covers VNC password, Apple Diffie-Hellman, Apple Remote Desktop, VeNCrypt, and open servers, chosen automatically unless you pin one.
- **A Screen for Headless Machines:** Put a screen on the machines that do not have one. Drive the headless Mac mini on a shelf, a Raspberry Pi with nothing plugged into it, a lab box, or a Linux server, from the same app you already use to SSH to them. Full desktop when you need it, terminal when you don't.

### Screen Sharing: Input

- **Touch:** Touch drives the remote pointer: tap to click, two-finger tap to right-click, touch and hold to drag, and pinch to zoom. Two fingers pan around the remote screen once you have zoomed in past what fits.
- **Trackpad and Mouse:** A trackpad or mouse sends real pointer and precise scroll events, using Apple's native scroll envelope when supported.
- **Hardware Keyboards:** Hardware keyboards track physical key identity rather than the produced character, so modifiers, key repeat, and arrow keys behave correctly. Keystrokes go to the focused pane, and rootshell's own shortcuts stay local.
- **On-Screen Keyboard Toolbar:** The on-screen keyboard toolbar works inside Screen Sharing sessions, and can be forced on or off per profile.
- **Two-Way Clipboard:** Clipboard works both ways, for text and URLs. Copy manually from the HUD, or turn on shared clipboard to keep both sides in sync. Transfers land in the clipboard manager's history.
- **Type User Password:** Type User Password types your saved password into the remote login window and presses Return, so a locked Mac is one tap away. It confirms first and never shows the password.

### Screen Sharing: Windows and Tunneling

- **Tabs, Splits, Windows, and Full Screen:** A session can live in a tab, in a split beside terminals, in its own window on macOS and iPad, or full screen edge to edge. Full screen is a live takeover, so the session is never torn down. Profiles can go full screen automatically on connect.
- **Draggable HUD:** A draggable HUD carries connection status, the mode switch, clipboard, and full-screen and keyboard controls.
- **Jump Hosts:** Standard and Full Quality can tunnel over an SSH or tssh jump host, so a Mac that only exposes SSH is still reachable. High Performance needs a direct path for its UDP media stream; rootshell warns before it falls back, including over mesh VPNs.
- **Bonjour Discovery:** Macs on the local network are discovered over Bonjour and appear in Browse next to SSH hosts.

### Screen Sharing: Profiles

- **Saved Profiles:** Connections save as profiles with their mode, quality, display, audio, toolbar, and jump settings, and sync across your devices.
- **Remembered Certificate Trust:** Server certificate trust decisions are remembered per host.

### Keyboard

- **Fixed Key Identity from Toolbar, Voice, and Gestures:** Fixed the key identity sent by the on-screen toolbar, voice commands, and gestures. Modified keys from those sources now encode correctly for apps reading the kitty keyboard protocol.

## 1.0.9-120 - July 12, 2026

### External SSH Agents (macOS Standalone)

- **Use Keys from ssh-agent and 1Password:** rootshell can now use keys from a local ssh-agent, including 1Password. rootshell connects to the agent over its unix socket, lists identities, and imports the ones you choose as tracked keys (public blob only, stored device-only).
- **Work Everywhere Other Keys Do:** Imported agent keys work everywhere other keys work: profiles, default keys, jump hosts, agent forwarding, the local SSH agent server, and VPN. Signing goes back to the external agent, so its own approval prompts still apply.
- **Automatic Discovery:** Agents are discovered automatically from the 1Password well-known socket, the `IdentityAgent` directive in `~/.ssh/config`, and `SSH_AUTH_SOCK`. A new SSH Agents screen under Connections manages agents and imports identities.
- **Agent Keys for VPN:** VPN can use external agent keys too. Because the VPN system extension runs as root and cannot reach your user session's agent socket, rootshell brokers each signing request back to the app while the tunnel is up, surviving app relaunch and in-tunnel reconnects.
- **Standalone Only:** This is Standalone only; the App Store sandbox cannot reach agent sockets.

### VPN HTTP/3 (QUIC)

- **Block HTTP/3 (QUIC):** Added a Block HTTP/3 (QUIC) setting to VPN profiles. When enabled, the tunnel rejects browser QUIC on UDP 443 so sites fall back to HTTP/2 instantly instead of stalling.
- **Working HTTP/3 Through the Tunnel:** Browser HTTP/3 now works correctly when it is allowed through the tunnel. The tunnel sizes its MTU to the transport's datagram budget, forwards UDP flows datagram-only so oversize packets drop like a real network, and lets QUIC's own path-MTU discovery converge below the budget. QUIC is auto-blocked when the datagram budget is too small to carry it.
- **Fixed Duplicate Profile:** Fixed Duplicate Profile dropping the advanced tssh settings.

### Local Shell (iOS)

- **Reliability and POSIX Overhaul:** Major reliability and POSIX-correctness overhaul of the on-device shell.
- **Command Substitution Fixes:** Fixed a deadlock where command substitution `$(...)` producing more than 64KB of output could hang; it now streams and is interruptible with Ctrl-C. Interactive `echo $?` now reports the real exit code.
- **More Bash Semantics:** Added `[[ ]]` conditionals with regex `=~` and the full unary operator set, correct `"$@"` expansion, parameter expansion forms (`${VAR:-x}`, `${v:off:len}`, `${v/pat/repl}`, `${v#pat}`, `${v%pat}`), and `set -e`/`-u`/`-x`/`-o pipefail` with bash-matching semantics isolated per subshell.
- **Background Jobs:** Added background jobs where the backend supports them: `cmd &`, `jobs`, `wait`, and `$!`.
- **More Builtins:** Added `printf` with flags/width/precision, `echo -e` escapes, `((expr))` arithmetic with `++`/`--`, brace expansion, `export -p`, and `trap` listing.
- **Clean Line Endings:** Line endings are now clean: the interpreter emits pure LF and converts to CRLF only at the terminal, so files, pipes, and captured output are no longer mangled. Interactive stderr is separated from stdout so top-level `2>` redirection works.
- **Better AI Command Execution:** The AI command executor now drains output concurrently, reports real exit codes, streams incrementally, and actually stops the running command on cancel or disconnect. File-browser previews (bat/rg/jq) no longer race the shell tab's output.

### AI

- **Updated OpenAI Models:** Updated the OpenAI model list to the GPT-5.6 suite.

### tmux Control Mode

- **Fixed Stuck Resync:** Closed a gateway wedge where a tmux -CC viewer could get stuck in resync forever after the remote shell was detached from another device and its exit was lost. rootshell now re-probes the connection and force-exits cleanly when it detects the shell is gone, while a slow multi-megabyte capture or a quiet-but-live session is left untouched.

### Tabs

- **Smoother Vertical Tab Drags:** Improved the vertical tab drag-and-drop: steadier drag visuals, correct preview sizing, a cleaner drag lifecycle, and a native drag preview on iPhone.

## 1.0.9-119 - July 8, 2026

### Terminal Engine

- **Lower Memory Use:** Terminal memory use is lower: standard page buffers use less space, free-listed page memory can be returned to the operating system, and PageList ownership/capacity edge cases are hardened.
- **I/O and Rendering Fixes:** Terminal I/O and rendering include upstream latency and throughput fixes for parser-idle PTY reads, scroll-region updates, render-state snapshots, and read-ahead backpressure.

### Captured Mouse Drags

- **Auto-Scroll at the Edge:** Mouse-reporting apps now auto-scroll smoothly when a captured left-button drag reaches the top or bottom edge of the terminal. This is most useful for tmux users who attach in regular mode instead of control mode, and also helps long drag operations in Vim and terminal file managers continue past the visible viewport.

### tmux Control Mode

- **Attach in Regular or Control Mode:** Session discovery can now attach discovered tmux sessions in regular mode or tmux control mode. The Control Mode toggle appears for SSH and tssh-backed terminals, remembers your choice, and is used consistently for touch, Return, and number-key attaches.
- **Fewer Blank Panes:** tmux control-mode panes that miss their first rendered frame now get another visibility kick when rootshell's first-frame watchdog reveals the tab anyway. This reduces blank panes after slow restores, delayed attaches, or occlusion recovery.
- **Fixed Blank Attach Paths:** The bundled terminal engine fixes two tmux -CC attach paths that could leave panes blank: a stuck DECSET 2026 synchronized-output flag during attach, and a history-capture retry loop that could spin forever behind a locked renderer.
- **Older tmux Compatibility:** tmux control mode now avoids pane-color-report requests on older tmux versions and ignores empty focus-event fields from older list-panes output.

### Live Activity

- **Quieter WiFi Polling:** WiFi info polling for Live Activities is quieter and lighter. Periodic refreshes now run less often, coalesce through the normal request path, and only log routine poll details when verbose lifecycle logging is enabled, values change, or a poll is unusually slow.

### macOS Standalone

- **Local SSH Agent:** Added a local OpenSSH-compatible SSH agent for Standalone local shells. When enabled, new local shells receive `SSH_AUTH_SOCK`, so command-line tools and other apps launched from that shell can use rootshell's saved SSH keys without exporting private keys to disk.
- **Full Key Stack for Local Tools:** This lets local tools use rootshell's full key stack directly, including YubiKey, FIDO2/security-key credentials, and OpenPubkey/opkssh identities, without first bouncing through an SSH connection just to get agent forwarding.
- **Per-Client Authorization:** Local agent clients are authorized by code signature and can be allowed once, for the app session, always, or denied. Rules can be limited to selected exposed keys and pinned destinations.
- **Agent Settings:** Added settings for the local SSH agent, including exposed-key selection, signature approval mode, per-client rules, `ssh-add` identities, and a capped audit log.
- **ssh-add Support:** `ssh-add` can add temporary identities to the local agent after approval, and the helper now preserves the agent socket across shell socket cleanup.

## 1.0.9-118 - July 7, 2026

### Clipboard Manager

- **Keyboard Mode for the HUD:** The clipboard manager HUD now has a keyboard mode. Press the shortcut once to open the passthrough HUD, again to focus it for keyboard navigation, and a third time to close it.
- **Full Keyboard Navigation:** In keyboard mode, Up/Down move through entries, Return pastes, Cmd+Return copies, Ctrl+1 through Ctrl+9 paste a visible entry, Ctrl+P pins or unpins, Ctrl+Delete deletes, and Escape closes the HUD.
- **Safer Large Entries:** Large clipboard entries are safer to browse: search and transforms run off the main thread, previews are bounded, and very large detail and result views show how much text is visible.

### Keyboard Toolbar

- **Up to Five Drawer Rows:** The keyboard toolbar drawer can now have up to five configurable rows.
- **Smarter More Button:** The More button can stack rows, revealing one more drawer row with each press, or cycle through one drawer row at a time. "Open Drawer by Default" opens the first row.
- **Editor Shows Every Row:** The Toolbar Keys editor now shows every drawer row and supports dragging or moving keys between Main Row and any Drawer row.
- **Automatic Migration:** Existing layouts migrate automatically, and reducing the row count keeps removed keys by moving them into the last remaining drawer row.
- **Delete Hidden Keys:** Custom keys that are no longer placed on the toolbar can now be deleted from Hidden Keys with a swipe.
- **Fixed iPad Blank Space:** Fixed extra scrollable blank space below Toolbar Keys on iPad.

### croc File Transfers (iOS Local Shell)

- **LAN Peer Discovery:** `croc` can now discover peers on the local network using Apple's multicast networking entitlement, which Apple newly approved for rootshell after a separate entitlement request. Nearby transfers can connect directly instead of always relying on the public relay when LAN discovery is available.
- **IPv4 and IPv6 Multicast:** LAN discovery supports IPv4 and IPv6 multicast and checks a discovered local peer before switching to direct transfer, falling back to the public relay when needed.

### SSH Transport

- **Keep TCP SSH Alive in Background:** On iOS and iPadOS, added a Keep TCP SSH Alive in Background setting to turn off the existing short background grace period for active TCP SSH sessions and interactive local commands. The duration and frequency of that extension is up to the operating system and is often quite small. With it off, TCP-based SSH connections may terminate after even 1 second away, but rootshell will not accumulate background runtime for them. It does not apply to `tssh` or `mosh`.

### macOS Standalone VPN

- **VPN-over-SSH on Standalone:** VPN-over-SSH is now available in the macOS Standalone build. Tunnel your traffic out the other side of any SSH connection with TCP, or `tssh` with KCP or QUIC.
- **VPN Settings on macOS:** The VPN settings page is now visible on macOS Standalone, and rootshell guides you when macOS needs the VPN system extension approved in System Settings.
- **Live Status and Traffic:** Active macOS VPN sessions report status and traffic statistics back to rootshell, and visible VPN state is restored after app relaunch.
- **Bundled VPN Host:** The VPN host runs from inside the rootshell app bundle, stays in sync with app updates, uses the rootshell icon, and authenticates control-socket peers by code signature.
- **On-Disk Size Note:** This increases rootshell's on-disk size on macOS, but the VPN system extension that carries a duplicate SSH stack only runs if you use the VPN feature.

### macOS Standalone

- **Correct Permission Attribution:** Local Network permission prompts for shell-spawned helper processes are now attributed correctly, including after the app exits and the helper continues running.
- **Titlebar Cursor Fixes:** Fixed titlebar drag-handle hit testing and cursor cleanup so the hand cursor does not stick after leaving the titlebar.

### YubiKey

- **Fixed Wired Signing Lockup:** Fixed wired YubiKey signing getting stuck with "another connection in progress" after a wrong PIN or failed operation.

## 1.0.9-117 - July 3, 2026

### Clipboard Manager

- **Encrypted Clipboard History:** An optional in-app clipboard manager keeps a device-only, encrypted history of copies, pastes, copy-on-select, and OSC 52 writes. It is off by default, and turning it off wipes the store and its key.
- **Open It Anywhere, Transform Anything:** Open the manager from Cmd+Shift+C, the keyboard toolbar, the menus, or the terminal context menu. Built-in transforms cover case changes, base64/base64url/hex, URL encode/decode, JWT decode, hashes, JSON format/minify, line operations, shell escape, ANSI strip, and counts.

### HDR Brightness Boost

- **Cleaner Boost Shader:** The HDR boost shader path is refactored so dark text keeps its contrast, saturated ANSI colors boost more evenly, and the antialiasing fringes around bright glyphs are gone.
- **Tap to Dismiss the HUD:** Tapping the terminal outside the brightness HUD pill now dismisses it.

### Stability

- **Fixed Unbounded Output Buffering:** Terminal output could buffer without bound if the read side stalled or output arrived faster than it could be parsed, eventually crashing the app. The pipe buffer is now capped, and `tmux -CC` gateways reset and recapture when loss is detected.

### tmux Control Mode (tmux -CC)

- **Atomic Large Pastes:** Large pastes into `tmux -CC` panes are now delivered atomically and in order through the control-mode gateway, SSH stdin, and tssh transports. This prevents truncated pastes, leaked paste markers, and remote apps getting stuck in bracketed paste mode.
- **Better Recovery Over tssh:** Panes running over tssh recover better from output discarded while the app or tab was backgrounded. Resync waits until the pane is foregrounded, the reset is ordered before buffered output replays, and panes that lose capture data are recaptured instead of staying blank or frozen.
- **Persistent Recovery State:** Restored tmux windows waiting for their gateway now keep their recovery state until resume succeeds or is canceled. Reconnecting placeholders include Gateway and Cancel Recovery actions.

### rootshell files (rf)

- **Live Theme Following:** `rf` now follows global, per-tab, and per-window theme changes live, keeping selections, status segments, icons, names, and preview colors readable.

### Background Effects

- **New Jellyfish Effect:** Jellyfish is a new background effect with occasional bioluminescent drifters, configurable visit frequency, color modes, a More Jellyfish control, and Visit Now.
- **Text Avoidance:** Butterflies and Jellyfish can now steer away from active terminal text and the cursor. Text Avoidance is on by default and includes tuning fixes so the effects don't spin or bounce while avoiding text.

### SSH

- **Force IPv4:** A new Force IPv4 option for SSH TCP connections routes hostnames and IPv4 addresses over IPv4 transport when enabled, while explicit IPv6 addresses still work.
- **Ordered Input Writes:** SSH input writes now use an ordered send pipeline to reduce paste and gateway-forwarding reorder risk.

### Background Tunnels

- **Smarter Retry Schedule:** Enabled background tunnels keep retrying on a longer schedule after the initial retry burst, retry immediately when connectivity or VPN/interface state returns, and show a Next Attempt In countdown.

### macOS

- **Fixed Cursor Shapes Leaking Into the UI:** Terminal cursor shapes could leak over tabs, headers, and resize dividers. The app UI now keeps the correct pointer, and terminal surfaces restore their cursor shape when you return to them.

## 1.0.9-116 - June 30, 2026

### Stability

- **Fixed Frozen, Blank Tabs When Switching:** A terminal tab could intermittently freeze and go blank. The foreground tab kept drawing, but switching to another tab showed an empty pane that only a restart could recover. This was a timing race introduced by the upstream terminal engine update in build 114, which started pausing a tab's display updates when it became visible without also holding keyboard focus. A tab switch sends those two signals separately, so usually it was fine, but if they arrived in the wrong order the tab was left paused and blank. Because it came down to timing it appeared unpredictably, and several earlier attempts didn't fully resolve it. Visible tabs now keep drawing regardless of focus, and any tab is force-repainted the moment it's shown, so a tab can no longer be stranded blank. If you still manage to reproduce the freeze, please open an issue.

### Find Bar & Theme Picker

- **Press Again to Dismiss:** The shortcut now toggles the panel, so pressing it a second time closes what it opened. Cmd+F shows and hides the find bar, and Cmd+Shift+T shows and hides the theme picker. Escape still closes either one.
- **Frosted Glass:** The scrollback find bar (Cmd+F) and the theme picker (Cmd+Shift+T) now use the app's frosted-glass look, matching the other floating panels.
- **Drag Anywhere:** Both panels can be repositioned by dragging their bar (the theme picker by its header). Movement stays on-screen, the search field and buttons still respond to taps, and the theme list still scrolls normally.

### Keyboard Shortcuts

- **Overlays Honor Your Custom Shortcuts:** Several overlays used fixed key combinations even when you had remapped them. They now follow your bindings everywhere: dismissing the find bar (default Cmd+F) and theme picker (default Cmd+Shift+T), the empty-window actions (New Local Shell, New Tab, New Window), Compose, and the AI Agent panel and its tab navigation. Default shortcuts are unchanged.

### tmux Control Mode (tmux -CC)

- **Per-Tab Theme Now Recolors the Pane:** Setting a per-tab or per-window theme override on a `tmux -CC` window recolored the tab bar but left the terminal pane on its old colors. The override now applies to the pane itself (palette, background, foreground, and cursor), scoped to the matching window tab.

### AI Agent

- **Claude Sonnet 5:** Sonnet 5 is now selectable as an Anthropic model, over both the direct API and Bedrock.

### Settings

- **Brightness Boost Hidden Where Unsupported:** The HDR brightness-boost slider only works on iOS/iPadOS 26, macOS 26, and visionOS 26. On older systems it did nothing, so the slider and its Reset button are now hidden there. The floating brightness HUD, its keyboard shortcut, menu item, and toolbar button are unchanged.
- **VPN Hidden on macOS:** The VPN row is hidden in the macOS build, where the tunnel cannot yet start. Apple's VPN API is only available to AppKit-based Mac apps, not to UIKit-based ones like rootshell, so the capability simply isn't there on macOS. Working around it would mean shipping a separate companion app, or a non-App-Store build that requires root access, neither of which we want to push on you. It's a strange gap we hope Apple closes. VPN remains available on iPhone, iPad, and Vision Pro.

## 1.0.9-115 - June 29, 2026

### Stability

- **Fixed Launch Crash on Older Systems:** The HDR Brightness Boost added in the previous build referenced display capabilities that only exist on the 2025 OS releases (iOS/iPadOS 26, macOS 26, visionOS 26). On anything older, the app could crash on launch or the moment you opened a terminal. The renderer now checks for those capabilities at runtime, so the app launches and renders normally everywhere. HDR boost is simply unavailable below the 2025 releases and is unchanged on them.

## 1.0.8-114 - June 29, 2026

### Display

- **HDR Brightness Boost:** On any HDR-capable display (iPhone, iPad, Mac, Vision Pro), the terminal can now be driven brighter than usual in bright conditions. Adjust it from a floating HUD (Cmd+Ctrl+B or a toolbar button) or in Settings -> Window -> Display. Boosted colors keep their vibrance, and the slider clamps to the display's headroom. SDR output is unchanged.

### Terminal Engine Update

- **Latest Upstream Engine:** The terminal core is updated to the latest upstream Ghostty: correct width for variation-selector emoji (e.g. the pirate flag), stable cursor and prompt placement on resize, a long-scrollback scroll fix, and crash fixes (resize, empty search, and selection).
- **Selection Auto-Scroll at the Bottom Edge:** Dragging a selection to the very bottom of the viewport now auto-scrolls again (touch and mouse/trackpad); the bottom trigger was previously unreachable.

### tmux Control Mode (tmux -CC)

- **Configurable Tab-Close Action:** New "Close Tab Action" setting (Settings -> Connections -> Multiplexers) for what Cmd-W and the close button do on a tmux window tab: Close tmux Window (default), Detach Session, Detach & Close Gateway, Hide Tab, or Ask. Tab actions were renamed to be tab-centric (Rename/Hide/Show/Close Tab).
- **Configurable New-Tab Action:** New "New Tab Action" setting for Cmd-T while attached to `tmux -CC`: Local Shell (default), New tmux Tab, or Ask. The Ask dialogs now take Return (default) and Esc (cancel).
- **Full Window Size Reclaimed on Every Tab:** When a smaller second client detaches, every tmux window tab grows back to full size automatically instead of staying shrunk until you visit it.
- **Recovered Output After a Long Background:** Over tssh, a long background could make tmux pause a pane and discard its queued output, leaving a gap even after reconnecting. rootshell now recaptures the pane on resume.
- **Stream Integrity Over tssh Reconnects:** `tmux -CC` over tssh could be corrupted or stall on a network roam. rootshell now preserves control input and, if output is dropped to avoid a stall, detects it and resyncs every pane cleanly.
- **Alt-Screen and Cursor Fixes:** Attaching to a `tmux -CC` session with btop/vim already running no longer loses scrollback or misplaces the cursor; panes also honor your cursor style and blink.

### SFTP (iOS Local Shell)

- **Spaces and Special Characters in Filenames:** The interactive `sftp>` prompt now handles filenames with spaces or glob characters (* ? [ ]). Completions are escaped and quoted, so "get my file.txt" is one filename and "rm foo\*" removes the literal file foo*.
- **CJK and Emoji Input:** The `sftp>` prompt now accepts CJK, emoji, and accented input (previously dropped), positions the cursor correctly after wide characters, and redraws wrapped lines correctly.
- **Local Commands Now Validate Paths:** lcd/lls/get/put now confine their path to the local shell sandbox (Documents plus bookmarked locations). Previously any path was accepted with no error; out-of-sandbox paths are now rejected.

### Helix Editor & Git (gix)

- **Updated gitoxide:** The gix engine behind the local-shell gix command and helix's git diff gutter is updated to 0.85, unifying the two copies that had diverged.

### Cloud & Networking

- **Tailscale & NetBird Device Details:** Device lists, QuickConnect, and a new Device section in the connection info sheet now show metadata for mesh devices (OS, owner, client, mesh path, exit-node/subnet routes, key expiry). No new permissions.

### Keyboard Shortcuts

- **Switch Keyboard Language:** A new action (default Cmd+Shift+Space, remappable) cycles the hardware keyboard through your installed input sources, wrapping around. Emoji and Dictation are excluded.

### Stability

- **Fixed Touch-Selection Handles After Swiping Tabs:** Selection drag handles no longer reappear in the wrong place after swiping to another tab and back; they are hidden during the swipe and recreated correctly when it settles.

## 1.0.8-113 - June 25, 2026

### Mosh

- **Fixed Frozen Screen After Backgrounding:** A Mosh session could come back from a quick app switch (even a one-second trip to the Home screen or another app, with or without a VPN) showing a frozen screen, a "Last contact Ns ago" banner stuck counting from the moment you left, or both, even though the connection had already recovered in the background. Switching tabs and back snapped it to life, which was the tell that live data was arriving but not being drawn. Returning to the foreground now reliably resumes drawing and updates (or clears) the contact banner. This was a regression introduced in build 109; direct SSH sessions were never affected.

### Terminal

- **Fixed Freeze Under Heavy Output (recent zellij):** If an app asked the terminal about its color scheme or size while it was also producing a burst of heavy output, the reply to that question could get stuck behind the output waiting for an internal rendering lock, freezing the interface for several seconds. On iOS the app could be killed by the system watchdog before it recovered (macOS would unfreeze once the output stopped). The common trigger was `zellij` 0.44.2 or newer (released May 2026), which added dark/light theme detection that asks the terminal for its color scheme (`zellij` commit 227142dd, "Support CSI2031 (dark/light theme switching)"); earlier `zellij` versions don't send that query. The terminal now answers those questions without waiting on that lock, so the interface stays responsive no matter how fast the output arrives.

### tmux Control Mode (tmux -CC)

- **Fixed ⌘W Leaving tmux Windows Stuck:** Closing an active tmux Control Mode gateway tab with ⌘W (or File -> Close on macOS) could remove the gateway but leave its projected tmux window tabs behind, orphaned and unusable. This was a brief regression introduced in the previous build (112) by its crash fix for gateway teardown; earlier builds weren't affected. Closing a gateway this way now tears down its window tabs cleanly, matching what already happened when you closed it from the tab bar or sidebar. Resumable sessions are unaffected: quitting, rotating, or relaunching still preserves the server-side session and re-adopts its windows.

### Cloud & Networking

- **NetBird Connects by Hostname:** SSH to a NetBird peer now targets its stable DNS name (for example, host.netbird.cloud) instead of its 100.x overlay IP. The hostname still resolves to the overlay address to connect, but using the name keeps your known-hosts entries stable and avoids breakage if the overlay IP changes. This mirrors how the app already connects to Tailscale peers by their MagicDNS name.

## 1.0.8-112 - June 24, 2026

### Tabs & Navigation

- **Interactive Swipe to Switch Tabs:** Swiping left or right between tabs is now a live, interactive carousel instead of an instant jump. As you drag, the current tab follows your finger and the neighboring tab slides in behind it, so you can see where you're going and back out mid-swipe; the switch only commits when you release past a threshold (or flick with enough velocity). The top tab bar now slides along in parallel with the terminal, and both source and target terminals stay alive during the gesture. It works with a direct touch swipe or a trackpad swipe on both iPad and macOS.

### VPN

- **Fixed Saved-Password Sign-In:** A VPN profile that uses a saved password could refuse to start, reporting that it "requires a saved password or SSH key" even though the password was right there. The app now checks whether the background VPN extension can actually read the credential rather than relying on a metadata snapshot that may not be loaded yet (for example on a locked or background launch), so password-based VPN profiles connect reliably. Biometric-protected passwords, which the background extension can't unlock on its own, now show a clear warning in the profile editor. VPN error and status messages are also now fully translated across all 25 supported languages.

### iOS Local Shell

- **Fixed CJK & Emoji Cursor Position:** In the local shell, typing wide characters (CJK text and most emoji) could push the cursor one column off for every wide character on the line. This was most visible with the multi-line starship prompt. The shell now measures input in display cells, so the cursor lands in the right place; plain ASCII input is unaffected.

### Sync & Security

- **Deleted iCloud Passwords Stay Deleted:** A saved SSH password deleted on one device could reappear on your other devices. The app no longer re-writes the synced Keychain entry on routine reconnects, so a deletion on one device now sticks everywhere. (Full convergence requires every iCloud-synced device to be on this build or newer, since an older device can still re-add the entry below the app layer.)

### Appearance

- **Darker Blue App Icons in Dark Mode:** The blue app icon and the no-border alternate icon now use a darker blue background in dark mode instead of black.

### Stability

- **Fixed an iOS 27 keyboard-toolbar crash** that could occur when the input accessory bar was rebuilt mid keyboard animation.
- **Fixed a crash on tmux Control Mode (`tmux -CC`) gateway teardown** when a session was closed or its window torn down.

## 1.0.8-111 - June 22, 2026

### Display (iPad)

- **Extend Under Home Indicator:** A new opt-in toggle in Settings -> Appearance -> Window -> Display (shown only on devices with a home indicator) runs the terminal flush to the very bottom edge of the screen. By default the home-indicator strip stays reserved so the system home-swipe gesture doesn't intercept touches meant for selecting text near the bottom; turn this on to reclaim that strip and let the grid extend edge to edge. The change applies live to open terminals and persists across launches.

### tssh

- **Faster, More Stable Reconnection Recovery:** `tssh` sessions that survive a network change or dropout now recover much faster and far more reliably. The underlying transport was rebuilt on improved KCP and QUIC engines: instead of caching and replaying packets across a reconnect, the transport now resets its own loss-detection timers on reconnect (QUIC PTO / KCP RTO) and lets the protocol recover lost traffic the way it was designed to. The result is a quicker, smoother resume after switching Wi-Fi to cellular, waking from sleep, or riding through a flaky link, and it holds up much better under heavy output. The app already ships the updated transport; the matching server-side improvements are not in any published `tsshd` release yet (the latest, v0.1.8, dates to May 10), so for now your remote host needs a `tsshd` built from the latest source to gain them. Mixing an updated app with an older `tsshd`, or vice versa, is fully supported and safe, so your existing connections keep working until you update the server.
- **No Crash When tsshd Fails to Start:** If `tsshd` couldn't start on the remote host (for example, a firewall blocking its UDP port, or a too-old server build), the connection could crash instead of failing cleanly. It now reports a clear error, including a hint about which port may be blocked, and a server too old to support session attach now falls back to a fresh session automatically rather than erroring out.

### tmux Control Mode

- **Detach Other Clients (⇧⌘X):** A new keyboard shortcut detaches every other client attached to the same tmux Control Mode session, leaving just this one connected, which is handy for kicking a stale phone or desktop off a shared session. It works from any tmux tab, the gateway or any of its window tabs, and acts immediately with no confirmation. The shortcut is rebindable in Settings, and the action is also on the menu bar and the gateway's context menu.

### iOS Local Shell (git)

- **Updated git Engine:** The engine behind the built-in `git` command (libgit2) was updated, with two fixes you may notice. History commands like `git log` and `git rev-list` now read repositories whose commit-graph was written by a recent version of Git, which previously could be silently ignored and slow the walk down. And `git fetch` and `git pull` can now request a specific commit by its hash from servers that don't advertise that capability, which most servers honor anyway, so those fetches no longer fail outright. The bundled regular-expression engine used for pattern matching was also modernized.

## 1.0.8-110 - June 20, 2026

### Cloud & Networking

- **NetBird Peer Discovery:** NetBird joins the cloud providers you can add for Quick Connect. Sign in with a Personal Access Token and your connected NetBird peers show up there for SSH, the same way Tailscale peers already do. Both NetBird Cloud and self-hosted Management URLs are supported; a self-hosted token is never sent to the public NetBird API.

### YubiKey

- **Insert and Touch Prompts During SSH Auth:** When an SSH connection needs your hardware YubiKey, a glass overlay now tells you what it's waiting for: "Insert your YubiKey" if it isn't connected, or "Touch your YubiKey now" to sign. Before, the connection would block silently and could time out with no indication of what was wrong. It now waits until you act (or tap Cancel) instead of failing on a short timeout, across every PIV path: SSH, Mosh, tssh, jump hosts, reconnect, restore, and local-shell ssh. A key that signs instantly never flashes the overlay.

### Keyboard & Input

- **Reliable Korean (Hangul) Input:** Typing Korean into the terminal with a hardware keyboard is now reliable. The app composes Hangul syllables with a local input model instead of relying on the system marked-text path, which previously dropped the in-progress syllable or swallowed special keys (Backspace, arrows, Return) while you were still composing. Editing keys now reach the active syllable, while shortcuts and non-editing keys commit what you've typed and pass straight through.

### tmux Control Mode

- **IME Composition Shows in Panes:** In-progress text from a multi-stage IME (such as the underlined Korean composition shown before you commit a character) now appears inside tmux Control Mode panes, instead of staying hidden until the character is committed.

### Sign In with OpenPubkey (opkssh)

- **Fixed Sign-In Expiring After 24 Hours:** An OpenPubkey (opkssh) identity (Sign in with Google) could stop authenticating exactly 24 hours after sign-in, even though token refresh appeared to be working. On the default server policy, the opkssh server only validates the original sign-in token, which expires after 24 hours. The app now quietly re-mints a fresh token before that limit, so connections keep working without a manual re-sign-in.

### Tabs

- **⌘N Hints Only on the Active Group:** In grouped mode, the vertical sidebar showed ⌘1-9 shortcut hints on every group, but the shortcuts only act on the active group, so the hints on inactive groups did nothing. Those non-functional hints are now hidden. Ungrouped mode keeps its global ⌘1-9 indicators.

### macOS

- **Per-Window Size and Position Restored:** Reopening the app on macOS with multiple windows could collapse every window to a single size, and secondary windows could render blank until you manually resized them. Each window now restores its own saved size and position, and the restore reliably triggers the layout pass that previously left secondary windows blank.

### Stability

- **Fixed a Crash When Locking the Device:** A foreground terminal could be killed by the system (a FrontBoard "insecure drawing in secure mode" error) while the device captured its locked-screen snapshot, crashing on the next unlock. It was most likely with a blinking cursor or live output on screen. The terminal's Metal renderer now pauses before the snapshot is taken, so it is captured cleanly.
- **Restored Keyboard Focus After Sheets:** Dismissing a modal sheet, such as the YubiKey PIN prompt, could leave the terminal without keyboard focus until you tapped it. Focus now restores automatically once the sheet finishes animating away, for every modal sheet.
- **Fixed a tmux Control Mode Freeze Under Heavy Output:** A heavy burst of output in a tmux Control Mode session could freeze the app's interface while individual panes kept updating. The renderer no longer blocks on a full internal queue, so the UI stays responsive.

## 1.0.8-109 - June 19, 2026

### tmux Control Mode

- **iTerm2 Inline Images Render in Panes:** Inline images sent with iTerm2's protocol (`OSC 1337`, as used by `imgcat`) now display in tmux Control Mode panes. Build 108 added image support for Kitty graphics (`kitten icat`), but imgcat's default auto-width sizing produced a zero-sized placement and drew nothing. Panes now carry exact cell-pixel geometry, so the image renders at the right size, and the cell-size queries that apps like `yazi` send are now answered inside a pane.
- **Multi-Line Paste Into Panes:** Pasting a multi-line block into a tmux Control Mode pane could behave as typed input, with newlines executing as the lines landed instead of arriving as a single paste. Panes now apply bracketed paste reliably, matching a regular terminal, so the whole block pastes atomically.

### Tabs

- **Move Whole Groups and tmux Gateways Between Windows:** Build 108 let you move a single tab between app windows; you can now move an entire sidebar group, or a whole tmux Control Mode gateway (its gateway tab together with all of its window tabs, including hidden and still-reconnecting ones) to another window or a new one, as one atomic unit. Available from the group and gateway headers in the vertical sidebar and from the gateway tab's menu. iPad and Mac only.
- **New Windows Keep Grouped Mode:** Moving a group or gateway into a brand-new window now opens that window in grouped mode instead of flattening the group that just arrived.
- **Tab Bar Re-Scopes After a tmux Detach:** In grouped mode with a tmux Control Mode gateway, detaching the session used to leak unrelated groups into the tab bar until you toggled grouped mode off and on. The tab bar now re-scopes automatically when the gateway's group dissolves on detach.

### Sign In with OpenPubkey (opkssh)

- **Automatic Re-Sign-In for Expired Certificates:** Connecting with an OpenPubkey (opkssh) key whose certificate has expired, and can't be renewed silently, now opens the browser sign-in inline and continues with a fresh certificate instead of failing the connection. The connection waits for sign-in the same way it already waits for a host-key prompt or a one-time password. This covers every connection that uses the key, including direct SSH, Mosh, trzsz, jump hosts, and reconnect or restore.

### Performance

- **Faster Top Tab Bar Switching:** The grouped-tabs feature added in recent builds left the top tab bar re-rendering every tab on each selection change, making switches laggy, especially quick keyboard switching with many tabs open in ungrouped mode, where all tabs are shown. The top tab bar now re-renders only the two tabs whose selection actually changed, so switching stays snappy no matter how many tabs are open. Liquid Glass, the sliding selection animation, and live title/health badges are unaffected.
- **Faster New Windows and Tabs on Mac:** Opening a new window or tab on macOS could feel sluggish, with a noticeable delay, even though the underlying work was fast. The lag came from main-thread contention during window open. Per-window startup work now runs once per launch, an already-running local shell opens without waiting on it, and the tab bar no longer re-renders dozens of times per open, so new windows and tabs appear right away.

### Background Effects

- **Glasswing Butterflies:** A new translucent "Glasswing" wing style joins the butterfly background effect, with a near-clear membrane, a glowing amber border, and visible veins. Pick it in Settings alongside the other butterfly colors. The perfect companion for your security work.

### Stability

- **Fixed a Crash Closing a tmux Pane Gateway:** Closing or detaching a tmux Control Mode gateway while a pane tab was still on screen could crash from a use-after-free, as the lingering pane's image-paste check read the freed gateway during teardown. Reported on build 107.
- **Fixed an Intermittent SSH Connection Crash:** Opening an SSH connection could occasionally crash during the key-exchange handshake, depending on the server's host key and negotiated sizes.

## 1.0.8-108 - June 17, 2026

### tmux Control Mode

- **Clipboard, Progress, and Notifications Inside Panes:** Apps running in tmux Control Mode panes can now copy to the clipboard (`OSC 52`), drive the tab progress indicator (`OSC 9;4`), report their working directory (`OSC 7`), and post notifications (`OSC 9` / `OSC 777`). These escape sequences were previously dropped by the reduced per-pane renderer in control mode; they now route through to the app exactly as they do in a regular terminal.
- **Images Render in Panes:** Inline images now display in tmux Control Mode panes. Apps that detect tmux and wrap Kitty graphics in tmux's passthrough envelope, such as `yazi`'s image previews and `kitten icat`, were previously dropped and left a blank space or stray characters. The passthrough is now unwrapped and replayed so the image draws, and the terminal probe queries those apps send (which `yazi` uses to detect graphics support) are answered, fixing "terminal response timeout" stalls.
- **No More Freezes Under Heavy Load:** A tmux Control Mode session could wedge and stop responding when the device was under heavy CPU or disk load, worst with query- or image-heavy panes like `yazi`. The control stream was being parsed while the renderer lock was held, so a starved renderer would stall the parser and silently pile up unprocessed bytes. Parsing now runs on its own lock, and a background watchdog flushes any deferred pane work, including images and clipboard copies, so the session keeps moving.

### Tabs

- **Move Tabs Between Windows:** Drag a tab from one app window into another to move its live session across, with no disconnect and no reopen. Drop it on the destination window's tab bar, its vertical sidebar, or its terminal, or use the "Move to Window" menus. Moving to a new window spins one up, and a window left empty closes itself instead of lingering blank. iPad and Mac only.
- **Toggle Grouped Mode with a Shortcut:** Grouped tab navigation now has a keyboard shortcut, Cmd+Shift+G, plus a "Toggle Group Mode" item in the View menu. Like every shortcut it's customizable in Settings -> Keyboard Shortcuts, and it's now localized in all languages.
- **Switching Grouped Mode Keeps Your Tab:** Turning grouped mode on used to jump you to the first tab of a previously-active group. It now adopts the current tab's group, so you stay on the same tab.
- **Closing a Tab Stays in Its Group:** In grouped mode, closing the active tab (including the last tab in a group, or a live tmux window tab killed on the server) could land you on an arbitrary tab in a different group. Selection now prefers a neighbor in the same group, falling back to the nearest tab in sidebar order only when the group would empty. This applies to both regular tabs and tmux windows.

### Settings

- **Reliable Cmd+comma to Open and Close Settings:** Settings now opens and closes from the same shared, deterministic side-panel overlay already used by the tab and connection sidebars. Cmd+comma is a clean open/close toggle that matches Cmd+Shift+\, rapid back-to-back presses are no longer dropped mid-animation, and the keyboard dismiss now behaves consistently with Escape and Done.

### SSH

- **No Disconnect During Keyboard-Interactive Auth on a Jump Host:** Connecting through a jump host that uses keyboard-interactive authentication, such as a one-time password prompt, could reset the connection if you took more than a few seconds to enter your response, succeeding only on the silent retry that followed. The login phase now uses the full login timeout instead of folding your typing time into the connection-progress timeout, so the first attempt waits for you.

### Background Effects

- **Butterflies Now Interact:** The butterflies background effect gained a physics layer on top of its flight paths. Butterflies now sense each other, veering to avoid collisions, occasionally pairing off into a brief courtship pinwheel, and fluttering when startled.

## 1.0.8-107 - June 15, 2026

### Tabs

- **Grouped Tab Navigation:** Open the vertical sidebar and tap the grid button next to the search field to turn on grouped mode, which sorts your tabs into automatic sections: local shells, remote hosts and domains, networks, Kubernetes and cloud sessions, and a section per tmux gateway. Remote IP hosts collapse by subnet (IPv4 /24, IPv6 /64). Navigation, shortcuts, and reordering stay scoped to the active group, and the layout is restored on relaunch.
- **Sidebar and Top Bar Together:** Grouped mode is fully navigable from the vertical sidebar alone, so the top tab bar (now labeled "Top Tab Bar" in Settings) isn't required. If you keep it enabled, it scopes to the active group, showing just that group's tabs, while the sidebar gives the full cross-group overview and switches between groups.
- **Auto-Hide Sidebar After Selection:** A new toggle (Settings -> Appearance -> Window -> Tab Bar) closes the floating sidebar once you pick a tab. Off by default; pinned/docked mode is unchanged.
- **Manual Overrides and Favicons:** Drag a tab into a different group, or use "Move to Automatic Group" (sidebar and top bar) to send it back. Domain groups show the site's favicon instead of a generic symbol.
- **Reorder Sections:** Drag a group's header in the sidebar to reorder the sections, saved per window.
- **Group by Remote Host:** An SSH, tssh, or Mosh session started from inside a local shell now groups under its remote host instead of Local Shell.

### Sign In with OpenPubkey (opkssh)

- **Ed25519 Keys:** OpenPubkey identities can now use an Ed25519 ephemeral key, the new default. A Key Type picker (Ed25519 / ECDSA P-256) appears during sign-in; existing P-256 identities are unaffected.
- **Brand Logos:** The provider picker shows real Google, Microsoft, GitLab, and Hellō logos in full color, and the key detail screen shows the provider's logo too.
- **Reuse Saved Custom Providers:** A "Saved Custom Providers" section lists the custom OIDC providers from your existing opkssh keys, so you no longer have to re-type the issuer, client ID, secret, and scopes. Tap one to load it into the form.

### tmux Control Mode

- **Detach Other Clients:** A one-tap action in the gateway tab menu and the Sessions dashboard detaches every other client while keeping your own connection. Since each attached client clamps the shared window size down, this evicts a small-screen device left attached elsewhere. Shown only when other clients are attached.
- **Auto-Hide the Gateway Tab:** A new opt-in preference (Settings -> Connections -> Multiplexers -> "tmux Control Mode", off by default) hides the control-mode gateway tab once the session's windows appear on attach. A later manual "Show Gateway Tab" sticks.
- **Smoother Reconnect:** The "Reconnecting tmux..." placeholder shown when restoring a `-CC` session is restyled as a liquid-glass pill and no longer freezes the app. Swipe-between-tabs, the left-edge drawer swipe, and tab taps all work during recovery instead of being swallowed by the overlay.

### SSH

- **Login Banners Shown Inline:** SSH servers can send a banner during authentication (legal or login notices), set with the `sshd_config` "Banner" directive. These now appear in the terminal after the connecting spinner clears, like real ssh, across regular SSH, jump-host/agent, tssh, and Mosh sessions. Banner text is sanitized so an untrusted server can't inject terminal-control sequences.

### Hardware Keyboard

- **Arrow-Key Browsing in Browse Hosts:** The Browse Hosts view now responds to hardware arrow keys. Up/Down move a highlight across the Local Network, Recent Connections, and Cloud sections (with held-key repeat), Return opens the host, and the highlight auto-scrolls into view.
- **Fixed Arrow Keys Inside Profile Folders:** Keyboard navigation in the profiles browser stopped working once you pushed into a folder. Up/Down, Return, and held-key repeat now keep working on folder screens.

## 1.0.7-106 - June 14, 2026

### Tab Sidebar

- **Swipe In From the Edge (iPad):** Pull the vertical tab sidebar in from the left screen edge like a native drawer. The floating panel tracks your finger as you drag, with the backdrop fading in proportionally; release past a third of the way (or with a flick) to open, otherwise it springs back. Drag an open panel back toward the edge to dismiss it. The gesture is finger-only, so trackpad and mouse text selection near the left edge keeps working.
- **Resize the Docked Column:** When the sidebar is pinned beside the terminal you can now drag its trailing edge to resize it, with a magnetic snap back to the default width and double-tap/double-click to reset. The width is remembered, and it never gets permanently shrunk by a narrow Split View pane. The resize floor adapts to control density so the header buttons can't clip in large mode.
- **Matches Your Theme:** The sidebar's buttons, selection dot, and highlight now pick up the active terminal theme's accent color instead of staying system blue, matching the connection and profiles sheets. The search field is now a rounded capsule consistent with the rest of the app.
- **Readability and Focus Fixes:** Docked-sidebar tab titles are no longer black-on-dark (unreadable) when a dark theme runs on a Light-mode device. The keyboard-cursor highlight now appears only when the sidebar actually holds keyboard focus, so switching tabs from the terminal beside a docked column no longer leaves a stale second highlight. The redundant "Tabs" header label was removed.

### File Browser (rf)

- **Fixed Data Loss on Yank + Paste in the Same Folder:** Yanking a file and pasting it back into its own directory could delete the file. The destination resolved to the source's own path, and confirming the "overwrite" removed the file and then failed to copy it back. Pasting onto a file's own location is now handled safely - a copy makes a Finder-style duplicate and a cut is a no-op - for both local files and SFTP, including two tabs open on the same host.
- **Fixed a Browser Crash After Filtering:** The file browser could crash (seen on build 105) when the visible list shrank from live-filter typing, the hidden-files toggle, or a reload while the scroll position was past the new end. Scroll position now stays clamped to the real list.

### Stability

- **Fixed a Crash Closing a Stale tmux Pane:** Closing a split on a tmux pane whose gateway had already gone away could crash from a use-after-free. tmux commands now require a live, active control session before touching the terminal.
- **Fixed a Crash in OAuth Sign-In:** The web authentication flow used by OpenPubkey reauth and cloud OAuth sign-in could crash if the login window failed to present. The completion now fires exactly once regardless of how the failure surfaces.

## 1.0.7-105 - June 13, 2026

### Tabs

- **New Vertical Tab Sidebar:** The tab switcher is rebuilt as a vertical list, opened with the same button or with Cmd+Shift+\. It sits on the left on iPad and Mac, and still rises from the bottom on iPhone. tmux Control Mode gateways appear as collapsible groups (with per-gateway new-window and sessions actions) and their window tabs indented beneath; regular tabs stay flat. Collapse state is remembered per gateway. It ships with a translucent liquid-glass look (on by default, toggle in Settings -> Appearance -> Window -> Tab Bar).
- **Pin It Open:** A pin button in the sidebar header docks it as a permanent left column beside the terminal instead of floating over it, and the terminal keeps keyboard focus while it's docked. Unpin to return to the floating overlay. iPad and Mac only; restored on launch.
- **Native on iPhone Too:** The iPhone panel is fully native, with a grab handle and swipe-down-to-dismiss, so the translucent mode actually blurs the terminal behind it.
- **Compact or Large Controls:** A density button in the header flips the whole panel between compact rows and larger, touch-friendly ones. It defaults to large on iPhone and compact on iPad, Mac, and Vision Pro, and is remembered.
- **Search and Keyboard Navigation:** A type-to-filter search field at the top doubles as the keyboard anchor: arrows move the highlight, Return selects, and Escape clears the filter then dismisses. Focus now stays in the panel as you move between tabs.
- **Drag to Reorder:** Drag tabs to reorder them, with list scrolling intact. Reordering a tmux window routes a single move to the server, keeping every attached client in sync, and regular tabs can now be dragged across tmux gateway groups.
- **Context Menus on Every Row:** Sidebar rows carry the same menus as the top tab bar - full actions on regular tabs, plus the tmux set on gateway headers (new window, sessions, rename, detach, hide) and on window rows (rename, move to session, hide).

### tmux Control Mode

- **Window Administration:** The sessions dashboard can create windows in any session, and each window card has a context menu to Rename, Move to Session, Link/Unlink, and Kill (with clear confirmation copy when killing the last window would close a session). Linked windows show a badge.
- **Pane Actions:** Live tmux panes gain a section in the terminal context menu: Zoom/Unzoom, Swap (directly or via a picker), Break Pane to a New Window, Move Pane to Window, Rename Pane, and Clear Pane History. Results apply on every attached client.
- **Hide Windows and the Gateway Without Killing Them:** A tmux window can be hidden instead of closed: it stays alive on the server while the tab strip, sidebar, navigation, and Cmd+N shortcuts skip it. The hidden set is stored in the session and survives reattach across clients, with a Hidden (N) disclosure per gateway group and Show/Hide controls in the dashboard. The gateway tab itself can now also be hidden once it has a visible window, clearing the control-client tab out of your strip.
- **Hardened Against Hostile Names and Topologies:** A pasted multi-line session, window, or pane name could smuggle a second control-mode command past the rename. Control characters are now stripped and such names are rejected up front. Separately, a server reporting an absurd number of windows or panes is now refused before any of them are allocated, keeping the app stable against a hostile or buggy server.

### Terminal

- **Per-Terminal Font Size Sticks:** A font-size override set on an individual terminal is now remembered for that terminal instead of resetting.

## 1.0.7-104 - June 11, 2026

### Connections

- **Sort Your Profiles:** The profiles view now has a sort menu (next to search) with Name, Recently Used, Most Used, and Date Created orders. The choice is remembered per device; the default stays alphabetical.
- **tmux Auto-Start Modes:** The "Auto-start tmux" toggle on a connection is now a three-way menu: Off, tmux, or tmux Control Mode (`-CC`). Picking control mode drops you straight into native window tabs and split panes on connect, no manual `tmux -CC` needed. Mosh connections offer Off and regular tmux only, since control mode can't run over Mosh's transport. Profiles synced to older app versions degrade gracefully to regular tmux auto-start.

### tmux Control Mode

- **Fix Blank Panes When Attaching a Large Session:** Attaching to a session with a long scrollback history, especially CJK-heavy content, could open all the window tabs but leave every pane blank forever, with no error anywhere. The control stream was being run through a 1 MiB safety cap meant for hostile escape sequences, and a single large history reply blowing past it silently swallowed everything after. The control parser now keeps its own much larger bounds, and if it ever does fail, the gateway tears down visibly instead of eating bytes.
- **Smoother Resizes While the Keyboard Animates:** Showing or hiding the on-screen keyboard sent tmux a stream of intermediate window sizes, each one storming the apps in the window with resizes mid-output and reflowing scrollback at the wrong width. Split windows now wait for the keyboard animation to settle before pushing their final size, and rapid resize bursts from any source are coalesced so the server only ever sees the freshest size instead of stepping through stale ones.
- **Fix a Frozen Shell After Detaching:** After detaching gracefully (from the sessions dashboard, or with ESC), the gateway connection's own shell could be stuck at its detach-time size forever, ignoring keyboard show/hide and looking wrong the moment the layout changed. The size flow now resyncs immediately when control mode ends.
- **Closing a Window Tab Closes the tmux Window:** The X button on a tmux window tab now asks the server to kill the window, the same way closing a split kills its pane, instead of just hiding the tab locally while the window lived on. If tabs and the server ever disagree, the layout now self-heals instead of freezing that window out.
- **Gateway Badges Follow Your Theme:** tmux gateway tab badge colors are now derived from the active theme's palette instead of the fixed green, with contrast adjustment against the tab bar. Each gateway gets a stable, distinct color, kept clear of the blue/teal range so they never read as Roam badges.
- **Badges in the Compact Tab Indicator:** If you keep the tab bar hidden, the transient tab indicator that appears when switching tabs now shows the same tmux gateway/window and Roam badges as the full tab bar.
- **Readable Session Dialogs:** Confirmation dialogs in the sessions dashboard (Switch Session, Detach Gateway, Kill Session) now use high-contrast system action colors instead of inheriting the theme accent, which was hard to read on some themes.
- **Focus Returns After the Dashboard:** Closing the sessions dashboard now reliably hands keyboard focus back to the terminal.

### Text Rendering

- **Consistent CJK Widths in the File Browser and Mosh:** The built-in file browser (`rf`) and the Mosh terminal model could disagree with the renderer about character widths in release builds, drifting columns on CJK text. Both now call Ghostty's own Unicode width table through a proper API instead of a runtime lookup that release builds could strip away, so layout decisions always match what's drawn.

### Settings

- **Stay in the Sidebar:** Importing an SSH user certificate and the OpenPubkey sign-in flow now push within the settings sidebar instead of escaping into separate sheets.

## 1.0.7-103 - June 10, 2026

### Connections

- **OpenPubkey SSH (opkssh):** Sign in with Google, Microsoft, GitLab, Hello, or a custom OIDC issuer to create an SSH identity, with no key files to generate or distribute. rootshell builds an ephemeral key bound to your sign-in via the OpenPubkey protocol and presents it as an OpenSSH certificate that servers running the opkssh verifier accept. The identity appears alongside your regular SSH keys with provider and expiry badges, renews itself silently at connection time while your sign-in is still valid, and offers Renew Now / Sign In Again when it isn't. Stored secrets follow the key's storage level: device-only identities keep tokens out of backups, while iCloud-synced identities can renew on your other devices too.
- **SSH User Certificates:** Attach an OpenSSH user certificate (`-cert.pub`, pasted or imported from a file) to any saved key and authenticate against servers configured with `TrustedUserCAKeys`. Works with software Ed25519, ECDSA, and RSA keys, Secure Enclave keys, YubiKey PIV, and FIDO2 security keys, and with agent forwarding. The certificate is offered first and the plain key on the next attempt, matching OpenSSH order; expired certificates are skipped so they never waste one of the server's auth tries. Key details show a live certificate preview (key ID, serial, principals, validity, CA fingerprint) with copy, replace, and remove actions, and key rows get a validity seal badge.

### tmux Control Mode

- **Sessions Dashboard:** Open a dashboard from a tmux tab's context menu, or with Cmd+Shift+S, listing every session on the server with window counts, attached badges, and a marker on the current one. Tap a session to switch to it in place, or create, rename, and kill sessions, including the attached one. Expand a session to see live, tappable previews of its windows; tapping one jumps straight to that window. A Gateway row shows which connection owns the control client and takes you back to its tab.
- **Hardware Keyboard in the Dashboard:** Arrow keys move the highlight, Return activates the highlighted session, Space expands its window list, and Escape closes the sheet and hands focus back to the terminal. Return also accepts tmux confirmation dialogs.

### Background Effects

- **New Effect, Butterflies:** Small groups of butterflies occasionally drift across the terminal, flapping and gliding with banking turns, sometimes perching mid-crossing before moving on. Everything is drawn procedurally, with Garden, Monarch, Morpho, and Theme Adaptive color modes. Settings cover visit frequency, group size, perching, a wing-flutter toggle, and a Visit Now button. Between visits the effect costs nothing; Reduce Motion forces gentle glides and Low Power Mode makes visits rarer.
- **Aurora, Rewritten:** The aurora is now a true procedural Metal shader: three parallax curtains with a bright folding lower edge, vertical ray shimmer sheared along the folds, and an altitude color ramp from oxygen green through teal to magenta, breathing on minutes-long cycles that never visibly repeat. New color modes (Theme, Polar Green, Mystic Purple) and a ray shimmer toggle. The lower portion of the screen is left untouched so terminal text keeps its contrast.

### Sync

- **Recover Profiles That Load Empty After an Update:** A connection-profile store that loaded empty after installing an app update could stay empty forever, because launch sync only fetches changes. rootshell now detects an enabled store that comes up empty, retries the load, and performs a full refetch from iCloud, the same recovery that cycling the sync toggle did by hand.

## 1.0.7-102 - June 9, 2026

### Connections

- **Trusted Host Certificate Authorities:** rootshell can now validate a server's host key against an OpenSSH certificate authority. Add CAs under Settings -> Connections -> Certificate Authorities (paste or import a key) and scope each one with OpenSSH-style host patterns (`*` and `?` globs, comma lists, `!` exclusions). A host certificate signed by a matching CA is verified silently, ending "host key has changed" prompts for fleets that rotate keys behind a CA. If certificate validation isn't possible, rootshell falls back to the server's base key as usual. Applies everywhere, including SFTP/SCP; supports ed25519 and ECDSA certificates with wildcard principals.

### tmux Control Mode

- **Live Theme on Open Panes:** Changing your theme now updates open control-mode panes immediately, including the full 256-color palette, instead of waiting for a detach and reattach.
- **Frosted Cover for a Shrunk Window:** When a smaller client attaches to the same tmux session, tmux shrinks the shared window, leaving a dead strip along the right and bottom. Instead of tmux's tilde fill, rootshell covers it with a native frosted-glass panel that fades away when the other client detaches.
- **Reattach Keeps Your Window Sizes:** Reattaching a tmux session no longer shrinks windows or reflows their scrollback narrow from a brief placeholder-size resize.
- **Reliable Split Focus, No Ghost Cursors:** Creating a split now reliably moves keyboard focus to the new pane, and only the pane that actually holds focus paints an active cursor, fixing duplicate cursors across splits.
- **No Clipped Bottom Row in Splits:** The bottom row of the pane above a divider could be cut off. Pane sizing now accounts for padding and the divider, so every row stays fully visible.
- **Self-Healing Layout Sync:** A layout update that only partly applied could be cached as successful, freezing a tab on a stale split arrangement. Partial failures now retry on the next update and heal.
- **ESC Returns to the Gateway Tab:** Pressing ESC to detach now always lands you back on the gateway's own shell tab with the keyboard focused, not an unrelated tab.

### Keyboard

- **Pin the Keyboard Hidden:** Long-press the dismiss chevron (0.5s) to pin the on-screen keyboard hidden: taps on the terminal no longer bring it back, and the toolbar stays visible. The chevron shows a distinct icon while pinned; tap or long-press it again to unpin. The pin survives switching away and back, and connecting a hardware keyboard drops it.

### Appearance (iPhone, iPad, macOS)

- **Brighter Tab Badges on iOS 27 and macOS 27 (Light):** The colored tab badges (the green "T" tmux badge, the blue "R" roam badge) looked muted in Light appearance because the new Liquid Glass legibility pass desaturates tinted symbols drawn on glass. rootshell now compensates in Light appearance, while Dark keeps the system's vibrancy.

### macOS

- **No Desktop Flash When Opening a Tab:** Opening a new tab could briefly flash the desktop through the translucent window before the new terminal painted its first frame. rootshell now keeps the previous tab's content on screen until the new tab can paint.
- **Fix the Return Key After Launching with the Visor:** Once the visor had been summoned, its hidden window could steal key status while macOS restored it at launch, leaving the Return key dead until you toggled the visor. Key status is now handed back to the terminal immediately.

### Stability

- **Fix a Rare Crash When Closing a Tab:** Closing a terminal at just the wrong moment could crash the app. Terminal surfaces live in the Zig terminal core and are referenced from Swift through raw C pointers, outside Swift's memory safety; a deferred screen-visibility update could fire against a surface that teardown had already freed. The update now re-reads the live surface and skips cleanly if the tab is gone.

## 1.0.7-101 - June 7, 2026

### tmux Control Mode

- **Native tmux Integration (-CC):** Attach to tmux in control mode (`tmux -CC`, locally or over SSH/tssh) and your tmux session maps directly onto rootshell's own interface. Each tmux window becomes a native tab and each tmux pane becomes a native split, so keys, splits, scrollback, and resizing are real rootshell gestures rather than raw escape sequences forwarded through the terminal. Tabs that rootshell is managing for tmux are marked with a green "T" badge. Note: Mosh connections do not support control mode, as the Mosh protocol cannot carry this traffic; use SSH or tssh instead.
- **Splits Drive tmux:** Creating, closing, and resizing a split runs the matching tmux pane operation, and dragging a divider resizes the real panes. Focus and layout stay in sync in both directions.
- **Per-Window Font Size:** Each tmux window tab keeps its own font size, so zooming one window no longer corrupts the geometry of the others. The size you pick is preserved across config reloads.
- **Native Copy and Paste:** Because each pane is a real rootshell terminal, selecting text, copying, and pasting work directly on the pane's own scrollback instead of going through tmux's copy mode. Selection and the system clipboard behave exactly as they do in a normal tab.
- **Search the Scrollback:** The find overlay searches each pane's native scrollback, so you can jump to matches and highlight text in a tmux window the same way you do anywhere else in rootshell.
- **New tmux Tab:** A "New tmux Tab" item in the window-tab context menu opens a fresh tmux window without dropping back to the command line. CMD-Shift-R now does the same on a tmux tab, opening a new tmux window on the gateway instead of falling through to the connection sidebar.
- **Seamless Resume Across Restarts:** When you attach over tssh, your tmux tabs survive an app restart. The windows you had open come back in their previous positions and rootshell re-enters control mode automatically once the session reattaches; if tmux is gone, the tab reverts cleanly to a plain shell.
- **ESC to Detach:** Pressing ESC detaches control mode and drops you back at the shell prompt, with no leftover output garbling the screen.

### SSH Keys

- **Secure Enclave (Hardware-Protected) Keys:** You can now generate a P-256 SSH key whose private key is created in, and never leaves, the Secure Enclave. No software, including rootshell itself, can read it: signing happens inside the secure coprocessor and produces a standard `ecdsa-sha2-nistp256` key your servers already understand. The key-type list is now grouped into Hardware-Protected and Software options, and storage is locked to this device.

### Keyboard

- **Drag Toolbar Keys Across Sections:** You can now drag toolbar keys directly between the Main Row and the Drawer, not just within one section. Promote a key to the always-visible row or tuck one away in the drawer with a single drag, alongside the existing edit-mode reorder grip, swipe-to-delete, and context-menu moves.

### Mouse

- **Tap to Click in Capture Scroll Mode:** A short tap now registers as a mouse click while capture scroll mode is active, so you can click in full-screen mouse-reporting apps without leaving scroll capture.

### Display (iPhone, iPad)

- **Always On Display:** A new toggle in Settings -> Appearance -> Window -> Display keeps the screen awake while you work, so it never auto-locks or dims during long-running tasks like builds, SSH sessions, `tail -f`, or monitoring. The setting applies instantly, persists across launches, and re-engages whenever you return to the app.

### Updates (macOS)

- **Fix Stale Check Interval:** In the Standalone build, the update settings "Check Interval" dropdown could keep showing an old value after you changed it. The dropdown and the automatic-update toggle now reflect the actual configured setting right away.

## 1.0.7-100 - June 4, 2026

### Connections

- **Keyboard-Interactive (2FA/OTP/PAM) SSH Auth:** rootshell now supports keyboard-interactive authentication (RFC 4256), the method servers use for 2FA, one-time passwords, and PAM challenges. It works across every launch path: direct connections, saved profiles, the local-shell ssh/mosh/tssh/sftp/scp/ssh-copy-id commands, the rf file browser, and follow-up session discovery. Prompts appear in one shared sheet rather than an inline terminal flow. A stored or typed password auto-answers a single hidden prompt for OpenSSH parity, but it is dropped on partial success so it is never reused for a later OTP factor. Turn it on with the new Keyboard-Interactive toggle under the Password method in the new-connection form and profile editor. An older copy of the app decoding a newer profile that uses this method degrades gracefully instead of dropping the profile.
- **Password Manager in Auth Prompts:** Keyboard-interactive secret prompts now surface the iOS password-manager AutoFill key, not just the one-time-code suggestion strip. Each prompt is classified by its server text: a password-style prompt offers the Passwords key (iCloud Keychain or a third-party manager), an OTP-style prompt offers the code strip. The saved SSH username is attached as an invisible AutoFill anchor so the manager can match the right credential.

### Keyboard

- **Fix iPadOS 18 Ctrl-Space Delay:** On iPadOS 18, pressing Ctrl-Space to switch input source could stall for a second or two while the system tried to disambiguate it against a cached list of legacy keyboard shortcuts. The fix restores a static shortcut strip for the older (pre-iOS 26) path while leaving the iPadOS 26 behavior untouched. Hardware Control chords like Ctrl+Return keep working as before.

## 1.0.7-99 - June 3, 2026

### Scrolling

- **1:1 Touch Scrollback on Every Display:** Dragging the local scrollback now tracks your finger exactly 1:1 on every device, not just 2x iPads. The old code leaned on a hardcoded boost that only matched a 2x display, so 3x iPhones scrolled at about two-thirds speed. The drag now uses a real model-to-physical coordinate scale, so the content stays glued to your finger whatever the screen scale, and momentum coasts at the same true 1:1 rate after you let go.
- **Snappier Flicks, Tighter Slow Releases:** The "cover more ground in fewer swipes" reach now happens only when you release a flick, never during the drag itself, and it scales with how hard you flick. A hard flick throws further while a slow, deliberate release settles tight right where you lift off. The reach applies to finger touch only: trackpad and mouse-wheel scrolling already carry the system's own acceleration, so those stay native.
- **No More Wall at the Live Bottom:** Scrolling down into the live bottom of the terminal could hit a wall and refuse to rubber-band until you lifted and re-dragged. The bottom-follow logic was yanking the view back to the edge mid-drag and cancelling the gesture. It now stays out of the way while a finger is down or a flick is coasting, so an upward flick from the bottom actually throws and overscroll engages cleanly. Streaming output still auto-follows the bottom once your finger is up and motion has settled.
- **Catch the Bottom Bounce With a Tap:** Tapping to stop the bottom rubber-band spring used to slam it shut and snap straight to the edge, while the top froze correctly. A tap that interrupts the bounce now freezes the rubber-band gap in place just like the top does, instead of collapsing it.

## 1.0.7-98 - June 1, 2026

### Scrolling

- **Optional Rubber Band Scrollback:** A new setting adds elastic rubber-band overscroll when you pull past the top or bottom of the scrollback, so the view stretches and springs back instead of stopping dead at the boundary.
- **Scrollback Into the Bottom Safe-Area Strip:** With pixel-smooth scrolling (the default), the terminal on iPhone and iPad now draws down into the home-indicator safe-area strip. The strip stays blank at rest, with the grid and prompt above it as before, but scrolling back through history flows older lines down into it for a couple of extra rows of context. It applies only in pixel-smooth mode, not with "Use Line Scrolling" on, and stays blank while the keyboard or toolbar is up or an ocean/solar bottom effect owns that area.
- **Steadier Scrollbar on Autoscroll:** The scrollbar could flicker into view when the terminal autoscrolled to follow new output. It now stays out of the way during autoscroll and only reveals when you are actually scrolling.
- **Scrollbar While Dragging a Selection:** When you drag a text selection to the top or bottom edge and the viewport auto-scrolls to extend it, the scrollbar now stays visible the whole time so you can see where you are in the scrollback, instead of flickering or disappearing.
- **Tap the Status Bar to Scroll to Top:** The system "tap the status bar to scroll to the top" gesture now works in the terminal, jumping the focused pane to the top of its scrollback.

### Keyboard

- **Show Toolbar with Hardware Keyboard:** A new "Show Toolbar with Hardware Keyboard" toggle in Settings, next to Persistent Toolbar, keeps the keyboard accessory toolbar docked at the bottom of the screen even while a hardware keyboard is connected, instead of hiding it. The change applies live to open terminals.

### Connections

- **Remote Sessions Survive a Quick Switch Away:** SSH, Kubernetes, console, and EC2 serial sessions now hold a short background task when you leave the app, giving roughly a 30-second grace window so a quick switch away and back reconnects cleanly instead of dropping. This is only a brief reprieve, not a way to keep a session alive indefinitely: for that, use a roam protocol like tssh or mosh, or enable the location diary. It defers to those stronger background modes (location, Live Activity) when they are already keeping the session alive.

### Interface

- **No More Paste Prompt on Every App Switch:** The iOS "rootshell would like to paste from..." dialog could pop on every return to the app because enabling the Paste menu item read the clipboard contents (which prompts) each time the app reactivated. Menu enablement now only detects whether the clipboard holds text or a URL, without reading it, so the actual content is read only when you tap Paste. This also fixes the compact edit menu hiding Paste when the clipboard held only a URL.
- **Consistent Trackpad Tab Swiping in Mouse-Capture Mode:** A horizontal trackpad swipe to switch tabs needed noticeably more travel while a tab had the mouse captured (tmux or vim with mouse reporting on) than in a normal tab. The capture-mode swipe now matches the regular feel, while vertical scrolling inside tmux or vim still never drifts toward an accidental tab switch.

### iOS Local Shell

- **rf File Browser Aligns Wide (CJK) Characters:** The rf file browser measured names one character per terminal column, so CJK glyphs (which render two columns wide) pushed everything after them out of alignment, skewing the size column and vertical separators. The grid is now display-width aware, so wide characters in file names, headers, and previews line up correctly.

## 1.0.7-97 - May 31, 2026

### Scrolling

- **Pixel-Smooth Scrollback:** Scrolling through the scrollback now moves the terminal pixel by pixel instead of snapping a whole row at a time, whether you drag with a finger, swipe on a trackpad, or use a mouse wheel. The view tracks the input with a sub-cell render offset, so a slow scroll glides smoothly and momentum decelerates without the old line-by-line stair-stepping. Reaching the top or bottom settles cleanly to the boundary with no leftover partial-row offset, and selection handles stay locked to the text as it moves. This applies to the local scrollback; sessions whose own scrollback is driven remotely, such as mosh, tmux, and zellij, keep snapping a row at a time.
- **ProMotion and 120 Hz on iPhone:** On ProMotion iPhones the terminal now renders at up to 120 Hz, matching the iPad and compatible Macs. Combined with pixel-smooth scrollback, fast flicks and momentum scrolls look noticeably fluid on a 120 Hz display.
- **Use Line Scrolling Setting:** A new Settings -> Terminal -> Shell toggle, "Use Line Scrolling," restores the classic snap-to-row behavior for anyone who prefers discrete whole-row jumps over the pixel-smooth glide. Smooth scrolling stays the default.
- **Selection Across the Whole Viewport:** Touch text selection has been rebuilt on the terminal's native selection engine, so the draggable handles now work anywhere on screen, including under pixel-smooth scrolling. You can adjust a selection across viewport boundaries, and dragging a handle to the top or bottom edge auto-scrolls and extends the selection into the scrollback. Only the visible endpoint shows a handle when the other end is scrolled off screen.
- **Steady Loupe in Mouse Capture Mode:** In apps that capture the mouse, such as tmux mouse mode, the magnification loupe shown during a long-press drag would flash on and immediately vanish. It now stays visible for the whole drag and disappears when you lift your finger.

### Keyboard

- **Collapse and Restore the Keyboard Toolbar:** You can now hide the keyboard accessory toolbar to reclaim screen space and bring it back with a small floating button. Both actions live on the chevron (⌄) button at the end of the toolbar: a single tap still dismisses the keyboard, while a quick double tap collapses or restores the toolbar, so neither gesture gets in the other's way.
- **CJK Candidate Bar No Longer Covers the Input:** When composing CJK with a hardware keyboard on iPad, the input-method candidate bar could overlap the line you were typing on whenever the prompt sat low on the screen. The candidate bar now draws above the input in that case and below it otherwise, and the highlighted composition text is positioned correctly.

### AI Agent

- **Claude Opus 4.8:** The AI Agent model picker now offers Claude Opus 4.8 with a 1M-token context window and adaptive thinking, on both the direct Anthropic API and AWS Bedrock. It replaces the Opus 4.6 and 4.7 entries from earlier builds.

## 1.0.6-96 - May 29, 2026

### Connections

- **SSH Launch Command Can Run as the Initial PTY Command:** A connection's launch command can now run as the session's initial command while still requesting a PTY (like `ssh -t host command`), dropping you straight into a TUI, REPL, or tmux rather than being typed at the prompt after the shell starts. The existing send-after-connect mode stays the default.
- **Roam Reconnect and Memory Reliability (Ships in This Build):** The bundled tssh client picked up the client half of a large reliability pass, with no server change needed. Stream teardown is now interruptible and asynchronous so a hung or swapped stream can't block a reconnect; blocked outbound buffers are discarded rather than held, cutting memory retained across reconnects and stalled writes; a rotating-cipher buffer-copy bug was fixed; and forwarded traffic now waits for a lost transport to recover instead of erroring mid-roam. It also exits cleanly when the remote shell ends, with tighter forwarding shutdown.
- **Matching tsshd Server Fixes (Update Your Server):** The rest of that pass is server-resident and only applies once the tsshd binary on your hosts is updated: packet-cache release on shutdown, take-and-remove stderr stream lookup, bus shutdown and channel-close race fixes, and reaping forwarding connections the client never claims instead of parking them forever. That last one matters for agent forwarding: an unclaimed connection could leave `ssh-add` or `git` commit-signing on the server hung indefinitely, which affects recent GPG agent forwarding. These are in the tsshd source but not yet in a tagged release, so self-hosters can build from current source to get them now.

### Interface

- **Faster App Switching, Steadier Keyboard:** Switching in and out of the app now feels dramatically faster, especially on iPhone, because the on-screen keyboard no longer animates out as you leave and back in as you return. The app holds off reacting to keyboard changes during the app transition and reconciles once after it settles, ignores tiny transient keyboard frames, and debounces the hide, so coming back is immediate with a single stable resize instead of a bounce.
- **Full Screen Mode Returns to iPhone:** Full Screen mode is available on iPhone again, after being limited to iPad. It auto-hides the status bar and home indicator so the terminal runs edge to edge, including into the notch or Dynamic Island if you want the extra rows. It stays opt-in, and the keyboard no longer leaves a gap above it in this mode.

### iOS Local Shell git

- **Commit Signing with GPG and SSH Keys:** The built-in `git` now signs commits using the app's existing GPG and SSH keys, with no private key on disk. `git commit -S`, `--gpg-sign[=keyid]`, `--no-gpg-sign`, and the `commit.gpgsign` / `gpg.format` / `user.signingkey` config keys are honored. GPG keys produce a detached OpenPGP signature; SSH keys an SSHSIG in the `git` namespace, with git-style key lookup, name fallback, and single-key auto-select. Signing survives the editor and AI-commit round-trip and aborts the commit on failure like stock git; `git cat-file -p` emits the `gpgsig` header so signed commits are visible.

### iOS Local Shell

- **Aliases That Expand to Native Commands:** A local-shell alias whose expansion begins with a native command (`tssh`, `mosh`, `ssh`, and the like) was expanded too late to reach the native implementation. A leading alias is now expanded before the native-command router runs, so aliasing a short name to `tssh ...` connects as expected.

### Live Activity

- **Wi-Fi Access Point on the Lock Screen:** The session Live Activity now shows the matched access point name next to the SSID, and no longer gets stuck showing only the SSID and band when access-point metadata arrives after the initial network snapshot.

## 1.0.6-95 - May 28, 2026

### Connections

- **GPG Agent:** The forwarded-agent decryption added in the previous build only spoke the newer KEM reply shape, so plain `gpg -d` and `gpg --decrypt` on the remote failed. A standard client does the final key unwrap itself and expects the agent to hand back the raw ECDH shared secret, while KEM-aware clients (`--kem=pgp`) expect the already-unwrapped session frame; the agent now detects which the client asked for and replies in the matching form. Imported legacy Curve25519 (cv25519) keys decrypt correctly too: their secret scalar is stored big-endian in OpenPGP but CryptoKit wants little-endian, so it was being fed in the wrong byte order. The agent also honors the KDF hash, cipher, and parameter fields carried in the ciphertext when the client sends them, falling back to the key's stored metadata otherwise. This covers GPG, bridged SSH, and YubiKey PIV sources.
- **GPG Key Discovery for Modern gpg:** gpg 2.4.x probes the agent with commands the previous build didn't answer, which could leave it unable to find a key before decrypting or signing. The agent now handles the `KEYINFO --data` fast path, `HAVEKEY --list` (raw keygrip enumeration), and `HAVEKEY --info` queries, and reports itself as gpg-agent 2.4.8 so clients don't fall back to older compatibility behavior. Large replies are split across multiple data lines so key listings and decrypt payloads stay within the Assuan line limit.

### Interface

- **Command-Tap Input Switching:** Tap Left or Right Command on its own to lock the hardware keyboard to a chosen input language, a stateless switch in the style of Karabiner. This is especially handy for CJK input: map one Command key to your CJK source and the other to a Latin layout, and you can flip back and forth with a single tap on a known key instead of cycling through every installed source. Holding Command together with another key still behaves as a normal modifier, so only a clean tap triggers the change. Assign the language each side maps to under Settings -> Terminal -> Mod-Tap Keys by setting a Command key's tap action to "Switch Input Source...". On iPad a brief overlay confirms the new language; on Mac the native macOS input-source HUD appears.
- **iPadOS Ctrl-Space Responsiveness:** On iPadOS, Control+Space is the system shortcut for cycling the hardware keyboard input source, but the terminal's own shortcut matching was sitting in the arbitration path and delaying it, which made the switch feel sluggish or stuck. While physical Control is held, the terminal now steps out of that path and hands Control+Space straight to the system, so the input source changes immediately. Explicit user or external key bindings for Control+Space are still honored.
- **Dragged Files and Images Use Bracketed Paste:** Dropping a file or image into the terminal now flows through the same bracketed-paste path as a clipboard paste. Programs that watch for bracketed-paste input, such as coding agents like Claude Code, now recognize a dragged file path or image instead of treating it as plain typed text. Dropped screenshots and other images on local sessions are written to a temporary file whose path is inserted, and quick successive drops use unique names so they can't overwrite one another. SSH sessions keep the existing SFTP upload sheet.

## 1.0.6-94 - May 27, 2026

### Connections

- **GPG Agent Decryption:** The forwarded GPG agent now handles PKDECRYPT in addition to signing, so `gpg -d` and `gpg --decrypt` on the remote succeed without the secret key being there. RSA, ECDH over Curve25519 and NIST P-256, and OpenPGP v6 native X25519 are supported, across imported GPG keys, bridged SSH keys, and YubiKey PIV slots. The approval sheet now distinguishes "Sign with X" from "Decrypt with X". GPG keys imported under earlier builds show a banner on their detail screen asking for a re-import, since the encryption-subkey bytes weren't being stored at the time.
- **On-Device RSA and ECDSA Key Generation:** The Generate Key sheet now offers Ed25519 (default), ECDSA P-256, P-384, P-521, and RSA 2048, 3072, 4096, instead of being Ed25519-only. Generated keys go through the same import path as pasted keys, so agent forwarding, GPG bridging, and host-key UI work with no extra setup.

### Interface

- **iPadOS 18 Hardware-Keyboard Button Hidden:** When a hardware keyboard is attached on iPadOS 18, the system floats a button over any text-input view (larger by default, shrinking to a small "A" / "中" pill once multiple input sources are installed). There's no user-facing toggle to turn it off. It's now suppressed inside the terminal view by clearing the input-assistant item without breaking CJK IME composition, scoped to iPadOS 18 specifically so later releases keep their default behaviour.
- **Terminal Padding Pinned During Resize:** The terminal was splitting any sub-cell remainder across both edges, which made text drift horizontally and vertically during live window resize (macOS, Stage Manager, Split View) until the next row or column threshold was crossed. Padding is now pinned to the explicit top-left values with any remainder kept on the trailing edges, so the grid stays put while you drag.

## 1.0.6-93 - May 26, 2026

### Connections

- **GPG Agent Forwarding:** Remote servers no longer need a copy of your GPG private key to sign things on your behalf. rootshell keeps the key securely on the device, acts as the GPG agent itself, and forwards that agent to the remote over SSH or tssh, so `gpg --sign`, signed git commits, and any other GPG signing request issued on the server are handed back to rootshell, signed locally, and returned to the server without the private key ever leaving the device. Two sources of keys are supported. Existing SSH private keys configured in Settings -> Connections -> SSH Keys can be used directly for GPG signing without any extra import, including YubiKey-backed PIV keys, so the same key that authenticated the SSH connection can also sign commits on the other side. Standalone GPG signing keys can be imported under Settings -> Connections -> GPG Keys by pasting an ASCII-armored secret block or dropping a binary `.gpg` file. Imported keys get a detail screen to rename them, copy the full fingerprint, see per-subkey details, or export an ASCII-armored public block to paste into `gpg --import` on the remote. RSA, Ed25519, and ECDSA P-256/P-384/P-521 signing keys are supported. Each connection has its own Enable toggle and an approval mode for what happens when the remote asks for a signature: auto-approve, approve once per session, or approve every signing operation. Mosh sessions hide the option, since the feature relies on a forward channel that only SSH and tssh expose.
- **SFTP Path Handling:** `cd` inside the SFTP shell now lands on the clean, real path on the server (symlinks resolved, `..` and `.` collapsed) instead of the literal text you typed, so the prompt matches where you actually are, and wildcard transfers like `get *.log` find files even when the current directory was reached through a symlink or a relative path. `~/foo` is also joined correctly on servers whose home directory is `/`, where it previously produced a doubled slash.

### Interface

- **Two-Finger Long Press Duration:** The two-finger long press that opens the new-connection sheet can fire by mistake when you're trying to pinch to change the font size, if you tend to rest two fingers on the screen for a beat before starting the pinch. The duration is now configurable under Settings -> Terminal -> Gestures, with choices of 0.5s (default), 1.0s, 2.0s, or Off, so if you're someone who lingers before pinching you can dial the threshold up to suit you or turn the gesture off entirely. Changes take effect live without reopening the terminal. Hidden on macOS, since the gesture only exists on touch devices.
- **YubiKey Wired Connect Timeout:** Tapping the USB-C transport without a key inserted used to hang the UI on "Connecting..." with no way out. Wired connects now time out after 30 seconds, and tapping again, switching transports, or dismissing the sheet cancels the attempt immediately.

## 1.0.6-92 - May 24, 2026

### Connections

- **SSH Now Uses Apple's Network Framework for Every Connect:** Every SSH connection the app makes (interactive sessions, the local-shell `ssh` and `sftp` commands, Mosh, tssh, git over SSH, MCP exec, and the AI agent runner) now opens its TCP socket through Apple's Network framework instead of the older POSIX socket path. The practical effect is that reaching a NAT'd Tailscale peer from outside the home network is reliable: Apple's path evaluator gives Tailscale a chance to set up the DERP or WireGuard route before the first packet goes out, instead of the SYN being fired blind and timing out while Tailscale is still negotiating. Reproduced locally against a NAT'd `.ts.net` target where the old path would not connect at all.
- **YubiKey Library Updated to 1.3.0:** Picked up a batch of upstream Yubico fixes that are relevant to how the app uses YubiKeys for SSH key signing. The notable ones: continuation APDUs now use the correct ISO 7816-4 Case 2 Short encoding (could affect any PIV operation that responded with more data than fit in a single APDU), HID connections now cancel pending reads when a USB-C YubiKey is unplugged mid-operation (previously could leave the app waiting on a response that would never arrive), a crash in the status-stream layer is fixed, and a CCCryptor memory leak in the crypto path is plugged.

### Interface

- **Terminal Resize Gated During Keyboard Animation:** When the on-screen keyboard slid up or down on iPad, the local terminal grid could resize to a transitional size mid-animation while the remote framebuffer was still sized for the old extent, leaving the two briefly out of agreement. Resizes now wait until the keyboard finishes animating and run once with the final bounds, removing that race so the local grid and the remote stay in sync through the transition.
- **macOS Visor First-Launch Keyboard Input:** The very first time the macOS visor was summoned, typing could beep until you clicked inside the terminal, even though the visor looked focused. After making the visor window key, the app now also primes the underlying input bridge so keystrokes reach the terminal immediately on first summon.

## 1.0.6-91 - May 22, 2026

### Connections

- **Mosh State Snapshot Copying Fixed:** Mosh keeps a local prediction snapshot so typed characters render before the server confirms them. The snapshot copy was only duplicating the framebuffer and throwing away the in-flight UTF-8 and escape-sequence parser state, so after a resync the predicted terminal could drift from the real one and show mangled characters or stale predicted text. Snapshots now copy the full parser state, so the predicted view stays in sync with what the server is rendering.
- **tssh Discard Input While Offline Toggle:** A new Settings -> Connections -> Roam -> tssh Settings -> Discard Input While Offline toggle controls what happens to keys you press while a tssh session is between networks. The default (discard on) matches upstream tsshd and avoids replaying a stale half-typed command into a prompt that has moved on by the time the link comes back. Turning it off queues your input locally and delivers it on reconnect, which is what you want if you're stepping through a confirmation prompt or a long-running interactive flow that you don't want to lose your place in.

### Interface

- **macOS Terminal Right-Click Menu:** Right-clicking inside the terminal on macOS could surface the wrong menu (the primary-click action) because the secondary-click flag wasn't being recorded on the pointer event that opened the menu. The hit test now records whether the originating event was a secondary click, so the contextual menu reflects the action you actually took.

## 1.0.6-90 - May 20, 2026

### macOS

- **Visor (Quake-Style Drop-Down Terminal):** A new global-hotkey terminal that slides down from a screen edge, joins all Spaces, and floats above other apps. Visor windows host the full main interface, so tabs, splits, profiles, and every connection type work exactly as they do in a normal window. By default the hotkey uses Carbon's RegisterEventHotKey, which works with no permission prompt; if you want a combo Carbon can't express you can opt in to a CGEventTap backend in Visor Settings and grant Accessibility access. Closing the last tab hides the visor and reopens a fresh terminal the next time you summon it. Visor is in the standalone (self-distributed) macOS build only, since the sandboxed App Store build cannot register global hotkeys.
- **Visor Settings:** Settings -> Appearance -> Visor covers the hotkey (modifiers and key), position (edge, screen, and whether the window joins all Spaces or stays on the active one), slide and cross-axis size in percent or pixels, animation duration, auto-hide on focus loss, and the Carbon vs. event-tap backend toggle.

### Connections

- **Mosh Now Renders into the Alternate Screen:** The mosh client was rendering into the primary screen, where its own framebuffer could diverge from the actual terminal grid and leave stale characters behind after a repaint (for example, restored scrollback or pre-mosh local-shell output that mosh thought was already blank). Mosh sessions now enter the alternate screen on open and restore the primary screen on close, so the mosh viewport is isolated from anything that was on screen before and everything you had is back when the session ends. The tradeoff is that native terminal scrollback is no longer available inside a mosh session (it only partially worked under the old mode, since mosh's own diff renderer never tracked rows that fell off the top); pairing mosh with tmux still gives you full scrollback through tmux's own buffer, which is the recommended setup. If you'd rather keep the previous behavior, a new toggle under Settings -> Connections -> Roam -> Mosh Settings -> Use Alternate Screen turns the alt-screen wrap back off.
- **Mosh ESC-After-Bad-UTF-8 Fix:** The mosh UTF-8 parser was discarding all but the last byte of an ill-formed sequence, so an ESC arriving immediately after a bad UTF-8 lead (a real pattern when a server emits a partial multibyte character followed by a control sequence) was being dropped and the following byte printed as plain text. Parsing now consumes only the longest well-formed UTF-8 prefix and leaves the rest, including any trailing ESC, intact for the VT parser.

### Reliability

- **Backup Restore Reports Real Outcomes:** Restoring profiles, SSH connection history, or known hosts from a backup was using `try?` around each write and counting every attempt as a success, so the restore summary could claim "N restored" even when fewer records actually made it to disk. Failures are now caught per record and surfaced in the restore summary as red rows.

## 1.0.6-89 - May 18, 2026

### Reliability

- **Use-After-Free Race in libghostty DisplayLink Fixed.**

## 1.0.6-88 - May 18, 2026

### Terminal

- **libghostty Rebased on Upstream:** The bundled libghostty was rebased onto current upstream. Pulls in roughly ten escape-sequence DoS and crash fixes uncovered by AFL fuzzing (CSI W, CSI g, CSI @, SGR underline parsing, insert-blanks and insert-lines at the right margin with wide characters and hyperlinks, zero-width graphemes arriving on a pending-wrap cell, and others), most of which were reachable by hostile shell output. Also rolls in a fix for the Korean IME crash on preedit composition, so CJK IME input is stable.
- **Renderer and Memory Fixes:** A use-after-free during mouse interaction over hyperlinked text is gone, with the renderer mutex now held for the full traversal. The C surface-text free function was silently a no-op and any caller using it was leaking; it actually frees now. The key-state overlay no longer leaks when a chord is ignored.
- **Protocol Coverage:** The Kitty keyboard protocol now reports composed and IME-produced text instead of dropping it. DECBKM (mode 67) is implemented so applications that set the backarrow-key mode get the right byte. DECSTR (soft terminal reset) handling was tightened. Link detection now respects semantic prompt boundaries, and the link regex is bounded so a pathological line can't trigger catastrophic backtracking.

### Connections

- **Ctrl-C Interrupts In-Flight ssh / sftp from the iOS Local Shell:** Pressing Ctrl-C while `ssh` or `sftp` launched from the local shell was still in the DNS, TCP-handshake, or key-exchange phase would return you to the prompt but leave the underlying connect running, which would surface later as a delayed error or stray output landing on top of your next command. Ctrl-C now tears the in-flight connect down, so the prompt you get back is real.
- **tssh Transfer Hang and Crash Fix:** Transferring a tssh session to a nearby device could hang the originating app long enough for iOS to force-quit it during the background transition. The transfer's stream reads and writes now happen off the main thread on a dedicated runloop with hard deadlines on each step, and the originator cancels cleanly if rootshell is backgrounded mid-transfer. The receiver also closes its stream in step so a close from either side can no longer race the other into a torn-down read or write.
- **tssh Transfer Cancellation:** Cancelling a Transfer to Nearby Device handoff after the offer was already in flight could leave the sending side waiting forever for an ack that the receiver had already declined. The cancel path now closes the stream and unblocks the originating tab so the session stays usable.

### Interface

- **Tab Bar Liquid Glass Transition Stabilized:** The selection animation on the Liquid Glass tab bar could pop, double-animate, or briefly show the wrong tab as selected when tabs were created, closed, or reordered during the transition. The transition now coalesces selection updates and hands off cleanly when the underlying tab set changes mid-flight.
- **Selection Magnifier Centers Above Your Finger:** The terminal selection magnifier now sits directly above your touch point instead of drifting toward the midpoint of the selection. The old midpoint-flip behaviour, which moved the loupe to the opposite end of the selection in certain drag directions, has been removed, so the magnifier stays where you'd expect for the whole drag.

### Build

- **Xcode 26.5:** rootshell now builds with Xcode 26.5.

## 1.0.6-87 - May 16, 2026

### Keyboard

- **Spacebar Trackpad for Cursor Movement:** Long-pressing the spacebar on the on-screen keyboard now drives the terminal cursor. iOS's floating-cursor drag offsets are bucketed into whole cells and emitted as arrow-key presses.

### Connections

- **Transfer to Nearby Device for tssh Sessions:** A live tssh session can now be moved between your iCloud-paired devices via Handoff. Long-press the tab title on the originating device and choose "Transfer to Nearby Device", then open the Handoff banner at the right end of the Dock on macOS (or in the App Switcher on iPadOS / visionOS) on the receiving device. The two devices exchange over secure Continuity continuation streams, the receiver reattaches to the existing tsshd PTY by session ID, and the originator only detaches once a confirmed ack lands. Recent scrollback travels with the offer so the new device picks up mid-context, and active TUIs replay through the alt-screen. Under the covers this uses tsshd's attachable mode, so make sure you're running the latest rootshell on every device involved and tsshd 0.1.8 or above on the server.

## 1.0.6-86 - May 15, 2026

### Appearance

- **Per-Theme UI Chrome Color Overrides:** Each theme can now override the algorithmically derived sheet and tab-bar chrome colors. Long-press a theme in Settings -> Appearance -> Theme and pick "Customize UI Colors..." to tweak them. Overrides persist per-theme, follow custom-theme renames and deletes, and round-trip through the backup system.
- **Disable Tab Switching Animations:** New "Disable Tab Animations" toggle under Settings -> Appearance -> Window -> Tab Bar. When enabled, tab selection skips the spring animation, so switching feels instant.

### Reliability

- **SCP Tab Completion Fixes:** Four bugs surfaced by a filename containing spaces. (1) Profile suggestions no longer surface unrelated hosts via substring matches on profile tags or notes: files come first, and profile suggestions must actually prefix-match the profile name or `user@host`. (2) File completions now backslash-escape spaces and close open quotes, matching how `cp` already behaved, instead of being inserted raw. (3) A trailing space inside an open quote or after a `\` escape no longer ends the current argument, so `scp "CODE ` and `scp My\ File\ ` complete correctly. (4) `scp My\ File.txt` no longer splits into three arguments at execution time; backslash escapes now follow shell POSIX rules.
- **Tab Close Routes to the Dying Tab:** When an SSH (or any) session ended asynchronously (e.g. `reboot`, `exit`) and you had switched tabs before the close arrived, the wrong tab would close. The close event now targets the tab that owns the dying terminal instead of whichever tab happens to be selected.

### Connections

- **SSH Compatibility:** SSH sessions now send the cooked-mode terminal modes (ECHO, ICANON, OPOST, ONLCR) that OpenSSH always populates in its pty-req. RFC 4254 §8 explicitly tells clients to populate these. Speculative fix for MikroTik / RouterOS.

## 1.0.6-85 - May 14, 2026

### Connections

- **Import from OpenSSH Config:** New Settings -> Privacy & Data -> Import from OpenSSH flow. Reads your `ssh_config`, turns each concrete Host block into a saved profile, and offers to import any IdentityFile keys not already in your keychain (matched by SHA256 fingerprint). Auto-detects `~/.ssh` on Standalone macOS and `.ssh` inside the rootshell sandbox on iOS, with a folder-picker fallback on sandboxed builds. OpenSSH semantics are honored end-to-end: wildcard Host blocks contribute defaults, negated patterns work, `IdentityFile none` and `ProxyJump none` properly clear inherited values, and ProxyJump / ProxyCommand jump hosts inherit the same identity key as their target.

### macOS

- **Custom App Icon Persists in Finder and Dock:** Standalone Mac builds now write the selected icon into the .app bundle via `NSWorkspace.setIcon(_:forFile:options:)`. The icon survives quitting and shows in Finder and the Dock even when rootshell isn't running.

### iOS Local Shell git

- **libgit2 Upgrade:** The bundled libgit2 used by our custom git CLI was rebased onto upstream. Brings in the reftable backend work, faster SHA-256 OID handling, an `oid` fix that ensures SHA-1s are zero-padded, a `revspec->from` use-after-free fix, the `load_known_hosts` HOME-tolerance change so SSH operations don't fail when the home directory is invalid, and the suppressed `FETCH_HEAD` write when fetch updates are disabled.

### iOS Local Shell WASM

- **WASI File Time and Range I/O:** Added `fd_pread`, `fd_pwrite`, `fd_sync`, `fd_filestat_set_size`, `fd_filestat_set_times`, and `path_filestat_set_times`, plus stubs for `symlink`, `link`, and the WASI `sock_*` imports the Go runtime emits. These are what Go's `wasip1` stdlib and tools rely on, so a much wider range of WASI-compiled binaries now run unmodified.
- **Cooked-Mode stdin (ICANON + ECHO + ICRNL):** The default (non-raw) terminal mode now buffers typed bytes per line, echoes them locally, and translates Enter to `LF` before delivering to the running `.wasm`. Programs that read with `bufio.ReadString('\n')` (rclone's interactive config and similar) used to hang because terminals send `\r` on Enter. Backspace now erases in-shell; Ctrl-D delivers VEOF on empty lines. Raw mode (`rootshell_terminal_set_raw(1)`) is unchanged.
- **Env libc Stubs and Auto-Stub for Missing Imports:** Added stubs for `flock`, `fcntl`, `kill`, `getpid`, `geteuid`, `umask`, and similar so neovim and other ports built against a POSIX shim link cleanly. Any other `env.*` import the runtime doesn't recognize now gets a synthesized zero-return stub that logs a stderr line on first call, so missing syscalls surface as a runtime message instead of a `LinkError` at startup.
- **DNS via `recvfrom` Returns the Real Peer Address:** UDP receive now attaches the resolved peer host and port to each reply, so apps that called `sendto_host` with a hostname get the actual post-DNS address back instead of an all-zero source-address buffer. Fixes DHCP-style, mDNS, and syslog-shaped traffic.
- **TCP `accept` No Longer Hangs Forever:** A bookkeeping bug in the listener path caused incoming connections to queue onto a stale handle while `accept` waited on a new one. Fixed.

### Reliability

- **SFTP Tab-Completion Crash Fix:** Pressing Tab in an iOS local shell SFTP session could crash rootshell if you kept typing (or deleted characters) while the directory listing was still coming back from the server. The completion result now re-checks what's on the line before applying, so a slow network reply can no longer overwrite stale text or land past the end of the line.

## 1.0.5-84 - May 12, 2026

### iOS Local Shell

- **WASM Shell Integration:** `.wasm` programs now participate in the local shell the way any other command does. You can pipe them (`wasm tool.wasm | grep foo`), redirect their output (`wasm tool.wasm > out.txt`), etc.

### Reliability

- **Scroll Mode Fix on Locked Launch:** Fixed a race condition that affected the touch handler's scroll/select gesture mode for users who had never manually toggled the Scroll Mode setting. The race condition existed in earlier builds but became worse after other recent changes.

## 1.0.5-83 - May 11, 2026

### iOS Local Shell

- **WebAssembly (WASM) Support:** The local shell can now execute `.wasm` binaries cross-compiled to WASI (`wasm32-wasip1`). This feature is provided for educational purposes, to help users learn about WebAssembly, the WASI interface, and systems programming on iOS. The execution environment is fully sandboxed within the app and is intended for code you have written yourself or audited as part of that learning; rootshell does not offer a catalog of pre-built binaries and does not function as a general-purpose package manager or app marketplace. Get a `.wasm` file onto the device (scp or sftp from another machine into the local shell is the easy path; the Files app works too), then run it like any other command, either as `wasm path/to/binary.wasm args...` or directly if the first token ends in `.wasm`. Capabilities in this first cut: sandboxed filesystem read/write (rooted at the app's Documents directory, with path-escape attempts refused), TCP client/listener and UDP sockets via `Network.framework`, DNS resolution through the system resolver (respects VPN routing and happy-eyeballs), and TLS/HTTPS through standard WASI crates. Sessions run in cooked mode by default so Ctrl-C cancels the running binary; a binary can opt into raw mode for full-screen TUIs and receive every keystroke (including `0x03`) on stdin. Each tab gets its own runtime so two `.wasm` invocations in different tabs are fully independent. Background and discussion at [issue #177](https://github.com/kitknox/rootshell/issues/177).

## 1.0.5-82 - May 10, 2026

### Connections

- **tssh Client Synced to Upstream v0.1.8:** The bundled tssh client is refreshed against upstream v0.1.8, picking up the latest reconnection, transport, and protocol fixes from the public release. For best reliability, also upgrade the tsshd binary on the servers you connect to so client and server are on matching protocol revisions; mismatched versions can leave you on older reconnection and transport behavior even though the client side is current.
- **MikroTik RouterOS Key Exchange Workaround (Awaiting Tester Confirmation):** RouterOS's SSH server (banner `SSH-2.0-ROSSSH`) can stop responding mid-handshake when the client KEXINIT offers too many key exchange algorithms. When the remote version banner identifies a RouterOS peer, rootshell now narrows its KEX proposal to just curve25519-sha256 and curve25519-sha256@libssh.org, which RouterOS is expected to handle cleanly. Other peers are unaffected. We do not have a RouterOS device in-house to verify against; if you hit RouterOS handshake hangs in prior builds, please confirm on this build at [issue #161](https://github.com/kitknox/rootshell/issues/161).

### Terminal

- **Native Scrollbar in zellij Scroll Mode:** The pipeline that drives the native scrollbar for tmux copy mode now recognizes zellij scroll mode automatically. The visible position indicator drives the scrollbar for either multiplexer, and gutter touches no longer route into the scroll view while a multiplexer owns scroll input (the handle stays visible as a position indicator but is read-only, so a drag no longer produces a glitchy local move that the next observer sample snaps back).
- **tssh Mode Restore on Resume (iOS Shell-Launched Sessions):** A previous build fixed mode restore for tssh sessions started from the Connections / profile UI, but sessions started by typing `tssh hostname` (or `ssh`, `mosh`) inside an already-open local shell tab took a different code path that cleaned up its inline spinner without injecting the mode-restore trailer. On resume those shell-launched sessions lost mouse capture, alt-screen, cursor-key mode, and bracketed paste. Trailer construction now lives in one place and runs for shell-launched sessions across all four embed contexts (local, SSH, mosh, tssh), with the mode-restore bytes written inside the same gate as the saved scrollback so the byte stream stays saved-scrollback, then trailer, then buffered server output, then live, with no trailer write racing ahead of the saved scrollback.

### iOS Local Shell

- **Shell Parser Hardening (Surfaced by a Homebrew Install Attempt):** A user tried to run the Homebrew install script in the local shell, which is not something rootshell can actually do, but the attempt walked the parser through a 1175-line stress test of bash-only constructs and surfaced several real bugs that affect ordinary scripts too. The shell used to crash outright on `bash -c "$(curl ...)"` and tripped on a number of bash extensions. Fixes: the tokenizer now handles `\` line continuation between tokens, opaque `[[ ... ]]` test expressions (so regex right-hand sides do not break the surrounding `if ... then`), process substitution `< <(cmd)` and `> >(cmd)`, bash array assignment `name=(...)` and append `name+=(...)`, brace-group function bodies after `()`, and trailing redirects on compound commands (`done < <(cmd)`, `fi > out`, `} 2>&1`).

### Reliability

- **WiFi-Poll Recursion Stack Overflow:** When the foreground activation gate cleared while rootshell's resume quiet window was still active, the deferred WiFi-info poll synchronously re-armed itself, recursing until the main-thread stack overflowed.
- **Restoration Flag Flushed Synchronously:** A force-quit very shortly after a successful state restoration could leave a stale "restoration in progress" flag on disk, which the next launch would misread as a failure.
- **Higher Quarantine Threshold for Saved State:** Five consecutive failed restorations now go straight to quarantine, collapsing the prior two-stage skip-then-quarantine policy. Less likely that one bad launch quietly disables saved-state restore.

## 1.0.5-81 - May 7, 2026

### Terminal

- **Native Scrollbar for tmux Copy Mode:** When tmux mouse capture is active rootshell now maps tmux's copy-mode position into the existing scrollbar model, and drives UIScrollView's native indicator through the standard scroll-view plumbing, making scrollback position more obvious.

### Reliability

- **Lifecycle Wedges on iOS Activation:** Subscribing complex views to SwiftUI's `@Environment(\.scenePhase)` forces the subtree to re-evaluate on every scene transition, and those re-evaluations could feed back into the lifecycle path and wedge the foreground transition outright. rootshell's lifecycle plumbing now reads UIKit notifications instead: `UIApplication.didBecomeActive` at the App level, and `willResignActive` / `didEnterBackground` / `didBecomeActive` in `MainView` feeding a locally-held phase. SwiftUI no longer re-evaluates the root scene graph on every transition.
- **Renderer Drained Before Background:** Each terminal surface now drains its renderer to idle, marks its session not-visible, and clears any cursor registration synchronously during the background transition rather than letting the renderer keep producing frames into the suspend window. Stops a class of resume issues where the GPU side and the lifecycle side disagreed about whether the surface was still active.
- **Display Links Fully Invalidated on Background:** Shader and cursor CADisplayLinks are now torn down (not just left allocated with `isPaused=true`) when a tab goes off-screen or the app backgrounds, and the same cleanup also stops the momentum-scroll animator and pointer-tracking observers. With paused-but-allocated display links left in place, iOS would occasionally try to renegotiate their preferred frame rate while the app was already backgrounded and deadlock the app on the next foreground. Suspected iOS bug; tearing the links down before background sidesteps it.
- **iOS Local Shell chdir Hangs (Rust, Vim, recursive substitution):** The local shell could land in a state where any program that called plain `chdir()` blocked forever, including Rust binaries via `std::env::set_current_dir`, Vim's `:cd`, and shell command substitution that recursed through itself. Root cause was an internal mutex being unlocked from a different thread than the one that took it, which on Darwin is undefined behavior and progressively corrupted the lock; the pseudo-fork lifecycle and the chdir override are now on separate locks with strict same-thread lock/unlock, and the pid allocator briefly takes the chdir lock around `getwd` so a concurrent chdir during pseudo-fork setup cannot cause a later cleanup to restore the wrong working directory.

### Connections

- **tssh Call Serialization:** All Swift-to-Go calls into the bundled tssh bridge now route through one gate that runs blocking gomobile calls on a `.userInteractive` concurrent worker queue, with per-transport ordering enforced inside Go. This also protects against priority inversion deadlocks where a low-priority background call could otherwise hold off a high-priority interactive call on the same transport.
- **SSH Connection Debug Logger:** A new debug-mode SSH Connection toggle that, when enabled, captures `ssh -vv` class detail (key exchange, host key fingerprints, auth method negotiation, server banners, channel state, other internals) to a log file for diagnosing connection failures. Off by default. Passwords, private keys, signatures, and shared secrets are never written.

### AI Agent

- **GPT-5.5 OpenAI Model:** OpenAI's flagship reasoning model with a 1M token context window added to the model list.

## 1.0.5-80 - May 5, 2026

### Terminal

- **iPad Scrollbar Drag Boost:** Dragging the iPadOS native scrollbar thumb or gutter applied the same 2x boost used for finger panning on the terminal body, making thumb drags feel jumpy and overshoot. Scrollbar drags are now detected via the indicator's hit frame and excluded from the boost, while finger panning still gets the 2x acceleration.
- **Output Coalescer Disable Ordering:** When the output coalescer was disabled (for example on entering passthrough or at session shutdown) the fast path was opened to direct writes immediately, while bytes still pending in the coalescer's queue had not yet flushed. In rate conditions new direct writes could land on screen ahead of the older queued bytes, producing visibly reordered output. New writes now keep going through the queue until the disable flush completes.

### Customization

- **Import from Ghostty Config:** Settings -> Privacy & Data now has an "Import from Ghostty Config" entry that reads a desktop Ghostty config file (`config` or `config.ghostty`) and applies the settings rootshell supports: fonts, theme, cursor, palette, selection, transparency, copy-on-select, and keybindings. Resolves `config-file = ...` includes up to depth 3, layers per-key color overrides on top of the named theme as a derived custom theme, and flattens keybind entries from all included files. On macOS Standalone the importer also surfaces existing configs at `~/Library/Application Support/com.mitchellh.ghostty` and `~/.config/ghostty` as one-tap rows above the file picker.
- **Window Padding Customization:** Settings -> Appearance -> Window now has a Window Padding section with steppers for horizontal and vertical inset, a current-value readout, and a Reset to Defaults button that restores the platform-tuned values (macOS 10/6, iPhone 6/3, iPad/visionOS 8/4). Overrides persist across launches and apply live through the existing config-reload path.

### Reliability

- **NetworkReachability Publish Storms Quieted:** NWPathMonitor delivers bursts of path updates during cellular/Wi-Fi handoff, VPN setup, and captive-portal probing where most metadata is unchanged. The monitor's six published values were all firing `willChange` on every path event regardless of whether anything actually changed.
- **Renderer Wedge on Resume (further fixes):** Build 79 fixed the display-link mutation race; build 80 closes the remaining edges. CADisplayLink is now invalidated synchronously before the renderer thread's mach wakeup port is destroyed (prior path could send through a recycled port and trip an EXC_GUARD).
- **tssh ClientID Race on Reattach:** Closed a race where the local ClientID could fall behind the server's view if the app was killed between the server recording an incremented ID and the client persisting it. The ID is now written to the Keychain on every change, and only sent to the server once that persist succeeds.
- **Session Recovery Loss on Quick Launch-Then-Quit:** Routine save/load/quit paths were incorrectly clearing state.
- **Network Path Monitors Paused While Backgrounded:** NWPathMonitor instances and the local network discovery monitor are now suspended on background and rearmed on foreground.

### Connections

- **SSH Bootstrap Retry With Backoff:** SSH connections (interactive sessions, tssh spawn, and the VPN bootstrap) used to attempt once and surface any transient failure to the user. They now retry connection-establishment failures with bounded backoff and a per-attempt login timeout that ramps from short to long, capped at roughly 5 minutes total. Auth failures, host-key rejections, and tsshd-not-found bail immediately. The VPN path stays cancellable mid-retry, and closing a tab during retry cancels the in-flight bootstrap so no zombie PTYs are left behind.

### macOS

- **Rapid Resize White Tearing:** During fast window resizes the IOSurfaceLayer could commit new bounds while the renderer was still producing old-size frames. The sublayer-frame update and surface size change now run inside a CATransaction with actions disabled so layer bounds and size update atomically.
- **Native Scrollbar Flicker:** The macOS scrollback view now keeps its native scrollbar visible and interactive without flickering during scroll. Scroll-wheel and trackpad events route back to UIScrollView so its native momentum is preserved, scrollbar gutter drags are detected separately from wheel scrolls, and the indicator style is observed against the active theme so contrast updates with theme changes.

### Under the Hood

- tssh synced to latest upstream.

## 1.0.4-78 - May 3, 2026

### iOS Local Shell

- **Vim Backspace in INSERT Mode:** The bundled Vim's xterm builtin termcap had no entry for the Backspace key, so on iOS where Backspace sends DEL (0x7F, the xterm convention) the byte was matched as forward-delete instead of Backspace. INSERT mode behaved like NORMAL-mode 'x' and beeped at end-of-line. Fixed at the termcap level so Backspace, forward-Delete, and the rest of the key bindings all match the keys the keyboard actually sends. Specific to the local on-device vim only.

### Connections

- **SSH Server Compatability (Settings -> SSH -> Authentication):** A new opt-in toggle switches public-key authentication from a single signed request to OpenSSH/libssh2's probe-first flow (offer the public key, wait for the server's accept, then sign). Some routers and embedded SSH servers reject pre-signed offers; with the toggle on, those servers accept the same key. Costs one extra round trip per key. Off by default, enable for maximum compatability.
- **Roam Banner Timestamp Stability:** On reconnect with a large server-side backlog, the roam banner could flicker through several different "last seen" timestamps before settling. The internal activity cache is now monotonic and only stamped on remote-confirmed events (poll completions and successful attaches), not on local-only activity like typing or resizing.
- **Connection Info Sheet on iPhone:** Opening Connection Info while the keyboard was up left the keyboard behind the sheet, covering most of it. The terminal now resigns first responder when the sheet appears, matching the other sheets, and the keyboard does not pop back when another sheet on top is dismissed.

### Reliability

- **Resume Metal Wedge Eliminated:** After backgrounding the app and bringing it back, the UI could land in a state where animations advanced one frame per touch (scrolling without inertia, sheet dismissals stepping, occasionally a scene-update watchdog kill). The display-link plumbing was being mutated from the wrong thread, leaving CADisplayLink and the run loop in disagreement. This primarily impacted iPhone users and due to different API use did not impact macOS at all.

### Live Activity

- **Info Only Filter:** A new Live Activity filter mode keeps the activity alive on WiFi or Network info alone, without requiring an open terminal or active VPN. Session and VPN content still appears when present. Eligibility requires at least one of WiFi Info or Network Info to be enabled, and Settings shows an inline hint when both are off.
- **Multi-Window Session Counts:** With the filter set to All, lock-screen totals could fail to start or show the wrong counts when only tssh sessions were active across multiple windows; closing one window also miscounted the other windows' roam and local-task content. Per-type counts now aggregate across windows so the activity reflects the full app state.

## 1.0.4-76 - April 29, 2026

### Appearance

- **Radical of the Unknown Icons Redesigned:** Every variant in the Radical collection has a new composition replacing the prior radical-plus-tilde glyph.
- **App Icon Preview Artifacts:** The icon picker tiles were rendering at default interpolation, which left visible aliasing on the previews. They now use high-quality interpolation, so the in-app previews match more closely what's actually drawn on the home screen.
- **Fireflies Color Mode Picker Label:** Changing the Fireflies effect's color mode now updates the picker row label immediately, instead of staying on the previous selection until you backed out and re-entered the settings screen.

### Connections

- **Profile Editor Validation Messages:** Save would correctly disable for an empty name, blank host, out-of-range port, or jump host without a port, but the messages explaining why never rendered. They now appear inline under the offending field.
- **SSH `-AA` for Auto-Approved Agent Forwarding:** The local-shell `ssh` command now accepts `-AA` as a shortcut for agent forwarding with auto-approval (no per-session prompt), alongside the existing `-A` which keeps the per-session approval mode.
- **Shell-Launched SSH Agent Approvals:** SSH connections opened from the local shell (e.g. `ssh -A user@host`) weren't wired up to the agent-approval prompt, so a remote command requesting an identity from the forwarded agent would silently stall. The approval handler is now installed on every terminal, including ones spawned from a shell command rather than the connection picker.
- **tssh Attach Keeps Retrying:** A tssh resume used to give up after one 30 s attempt and spawn a fresh SSH session, dropping in-flight server-side state. The client now retries with exponential backoff until you close the tab or 24 h elapses since the last confirmed connection. Particularly useful when you're temporarily on a network that can't reach the server (VPN dropped, off-network); the session is waiting when you get back inside the firewall.

### Terminal

- **Touch Selection Handle Recovery:** Backgrounding the app, or dismissing Settings or another sheet on top of a live selection, used to leave the handles invisible even though the selection was still active. They now reappear on the selection when the terminal becomes visible again.
- **Per-Font Cell Width and Height:** Font settings now exposes adjust-cell-width and adjust-cell-height sliders (±25%), scoped per font family so a tweak made for one font is remembered when you switch back to it. Useful for fonts that feel too tight or too airy at the default metrics.

### AI Agent

- **Toolbar Menu Pulsing During Streaming:** The kebab/overflow menu in the AI Agent overlay was visibly pulsing during streaming responses. The toolbar now only re-renders when something it actually displays changes.

### Live Activity

- **Recover Orphaned Activities on Launch:** Any app termination (force-quit, OS kill, crash) would leave the prior launch's Live Activity stranded on the lock screen, and relaunching couldn't replace it until the session count changed. The app now adopts the orphan in place at launch so the widget catches back up to your live sessions immediately.

## 1.0.4-75 - April 26, 2026

### Terminal

- **Bracketed Paste Hang:** Pasting a large block of text into the terminal could leave it silently buffering forever, waiting on a paste end marker that never arrived. A common giveaway was switching to another tab and back: the buffered paste would appear all at once when the tab regained focus, instead of as it arrived. This has been present since early builds of rootshell. The non-blocking response pipe could fill mid-paste and drop the closing `ESC[201~`; the writer now waits for the kernel to drain the buffer, so the full paste always reaches the app.

### Appearance

- **Radical of the Unknown App Icon Collection:** Twelve new icon variants themed after popular terminal color schemes (Solarized Dark and Light, Dracula, Nord, Gruvbox Dark, Tokyo Night, Catppuccin, Bases, Mono Light and Dark, Monokai, and Rose Pine) are now available in Settings -> Appearance -> App Icon, alongside the existing icon set. Picking a Radical of the Unknown variant updates the home-screen icon, the animated About icon, and the Live Activity widget at the same time. Thanks to @arne for designing and contributing this collection, and to @realhackcraft for the previous round of custom icons that shipped in 1.0.4-73.
- **Classic App Icon Re-mastered:** The formerly default "Classic" app icon has been re-mastered and migrated to an Icon Composer source.
- **Change App Icon From Shortcuts:** A new "Change App Icon" Shortcuts action lets you switch the rootshell icon from a shortcut, automation, or Focus mode trigger, taking any bundled variant as a parameter.

### Connections

- **Hide Long-Offline Tailscale Devices:** Tailscale's API returns every authorized device regardless of online state, so machines that had been offline for weeks were cluttering the resource list and Quick Connect suggestions. Synced devices are now filtered to those whose `lastSeen` is within the last 30 minutes.
- **Custom tsshd Binary Path:** TSSH connections can now point at a specific tsshd binary on the remote host instead of relying on `tsshd` being on the user's PATH. Set the full path under TSSH -> Advanced -> tsshd Binary in the connection editor; when populated, the path is invoked directly over both regular SSH and the VPN tunnel. Useful for testing alternate builds or for hosts where you can't drop tsshd into a system path.

### iOS Local Shell

- **Plain `$VAR` and `${VAR}` Now Expand:** The previous build only routed `$(…)`, `$((…))`, and backticks through the shell interpreter, so `setenv TIMESTAMP "$(date)"` followed by `echo "$TIMESTAMP"` at the prompt sent the literal `$TIMESTAMP` to the command runner. Plain parameter expansion (`$NAME`, `${NAME}`, `$0`-`$9`, `$@ $* $# $? $$ $! $-`) now takes the same pre-expansion path that scripts already used. Quoted forms like `'$VAR'` and `\$VAR` still pass through literal.

### macOS

- **Window Position Restored Across Launches:** macOS now persists the window's last on-screen origin alongside its size and reapplies the saved frame when the app relaunches, instead of falling back to the system default position. Additional windows still cascade as before, and the saved origin is ignored if it would land mostly off-screen (for example, after a display change).
- **Trackpad Scroll Forwarding For tmux:** Trackpad two-finger scroll inside tmux on macOS could end up stuck "off" until the next app restart, because the cached mouse-capture state was missing the moment tmux's mouse-on escape arrived. The trackpad scroll gesture now queries the live capture state on each touch and self-heals the cache when it disagrees, so wheel forwarding tracks tmux's mouse mode immediately.

## 1.0.4-74 - April 25, 2026

### Appearance

- **Refreshed App Icon Art:** The bundled app icon variants have been redrawn with cleaner layered hash artwork and more of a glass look.
- **Apple Watch Live Activity Icon:** The watchOS Smart Stack mirror of the Live Activity widget no longer shows a gray placeholder box where the app icon should be. The widget now opts into the watchOS `.small` activity family so the system renders the bundled preview imageset instead of trying (and failing) to resolve the main app's Icon Composer stack from watchOS.

### AI Agent

- **AWS Bedrock Provider:** The AI Agent can now route Claude requests through Amazon Bedrock in your own AWS account instead of going to Anthropic directly. Authentication reuses the existing Cloud account flow (Access Keys or SSO/STS, with auto-refresh per request), the same four Claude models are exposed, and the endpoint is region-scoped and SigV4-signed. This also fixed a latent double-encoding bug in the shared SigV4 signer that EC2 and EKS never tripped because their paths don't contain reserved characters; Bedrock's colon-bearing model IDs surfaced it on the first call.

### Local Shell

- **Command Substitution and Arithmetic Expansion:** Commands like `setenv TIMESTAMP "$(date)"` now expand `$(…)`, `$((…))`, and backtick command substitutions before dispatch instead of being passed through literally.

### Connections

- **SSH Transport Settings Subpage:** Connection health monitoring, the probe interval, and the post-quantum key-exchange warning toggle have moved out of the Connections list and into a dedicated SSH Transport settings page under Connections. The post-quantum warning, which previously could only be toggled via `defaults`, now has a proper UI control.
- **SSH Remote Exec PATH Prepend Is Now Opt-In:** Local-shell-launched SSH sessions (e.g. `ssh user@host some-command`) used to silently prepend a Homebrew/Linuxbrew/Go-friendly `PATH=…` to your remote command so non-interactive exec could find common tools without shell startup files. That broke commands that wanted their own environment intact. The prepend is now opt-in via a new `--path` flag on the local-shell `ssh` command; without it, your remote command goes over the wire verbatim.

### Terminal

- **Scroll Gesture Conflicts (Speculative Fix for #152):** Tightened the gesture recognizers around vertical scroll vs. the horizontal swipe that switches splits, in an attempt to address [issue #152](https://github.com/kitknox/rootshell/issues/152). This is a speculative fix; if you can still reproduce the issue, please follow up on the issue with steps.

## 1.0.4-73 - April 22, 2026

### Appearance

- **Customizable App Icon:** The app now ships with eight icons you can switch between from Settings -> Appearance -> App Icon. Picking a variant updates the home-screen icon, the animated About icon, and the Live Activity widget at the same time.

### Connections

- **OpenSSH-Style Escape Sequences (`~.` and friends):** SSH, mosh, and tssh sessions now implement OpenSSH's `~` escape state machine. At the start of a line you can press `~.` to disconnect, `~?` for the help screen, `~#` to list active forwards with live status, `~I` for connection info, and `~~` to send a literal tilde. Escape detection is suspended inside bracketed-paste markers so pasted content with a leading `~.` can't drop your session, and `~.` on a session launched from the local shell returns you to the shell prompt promptly without waiting on async PTY teardown.
- **Non-Post-Quantum Key Exchange Warning:** When an SSH connection negotiates a key exchange that isn't a post-quantum KEM, the session now prints a yellow OpenSSH 9.9-style banner after the welcome line warning that the session could be recorded today and decrypted later by an attacker who eventually acquires a sufficiently capable quantum computer. The Connection Info "Post-Quantum Secure" badge was also split into separate key-exchange and host-key signals so its readout matches the new warning.

### AI Agent

- **Agent Re-anchors When Shell Context Changes:** Opening the AI Agent on a tab where you'd SSHed from the local shell, then exited back to the shell, used to keep executing tool calls against the previous context (still over SSH on the remote host, or still on the local shell) because the per-tab session was cached for the lifetime of the tab. The session is now invalidated and re-created when the connection type underneath it changes, and is pinned to the split that spawned it so a sibling split's SSH enter/exit can't tear it down.

## 1.0.3-72 - April 20, 2026

### AI Agent

- **Claude Opus 4.7 in the Model Picker:** Anthropic's Opus 4.7 is now selectable from the AI Agent model picker.
- **Stable Toolbar Menus During Streaming:** The AI Agent model picker and overflow ("...") menu no longer flicker while a reply is streaming. The toolbar is now split into small equatable subviews that SwiftUI skips re-evaluating on every ~100 ms streaming tick, so the menus stay steady even through long responses.

### Connections

- **Active Directory Usernames (user@domain) Across the Board:** SSH usernames containing an `@`, most commonly Active-Directory-style logins like `user@domain` connecting to hosts such as `somehost.local`, now work everywhere. Previously `user@host` was being split on the first `@` instead of the last, which silently truncated the username and mangled the host. Fixed sites include ssh / mosh / tssh / scp / sftp / ssh-copy-id command parsing, SSH and Mosh URL fallbacks, HSS ProxyCommand jump hosts, the AI agent's `ssh_execute` MCP tool, SCP tab completion, Quick Connect (including its `via` jump-host syntax), and git SSH/SCP-style transport URLs. The git transport additionally isolates the authority from the path so a stray `@` inside a repo path (e.g. `/org/repo@mirror.git`) can't be mistaken for the user/host boundary.

### Keyboard

- **Cmd/Opt+Arrow Text-Editing Defaults:** On any attached hardware keyboard (iPad, macOS, or otherwise), Cmd+Left/Right now sends Ctrl-A / Ctrl-E (line start/end) and plain Opt+Left/Right sends ESC+b / ESC+f (word jump), matching the Darwin defaults in upstream Ghostty. Previously Cmd+Left/Right sent the word-jump escapes and Opt+Left/Right had no dedicated path, so muscle memory carried over from desktop Ghostty didn't translate.

### Bug Fixes

- **Background-Autosave Crash:** The periodic save of window/tab state no longer stalls or crashes when the app is sent to the background. Persistence now runs off the main thread inside a background task, so the OS can't kill the app for taking too long to suspend.
- **Quieter Ping on Flaky Networks:** Ping no longer prints a "network path changed" line every time it resets its ICMP socket in response to an `NWPathMonitor` update. iOS emits those updates frequently (DNS churn, `isExpensive` flips, probe state) even on an otherwise-stable network, so the user-visible line was firing repeatedly during long pings.

## 1.0.2-71 - April 19, 2026

### Terminal

- **iTerm2 Inline Images (imgcat):** The terminal core now implements the iTerm2 OSC 1337 File protocol, so `imgcat` actually draws images instead of printing escape-sequence noise. Both the default chunked mode and the legacy `-l` single-sequence mode are supported. PNGs pass straight through to the existing Kitty graphics decoder; JPEGs are decoded to RGBA and submitted as a raw image, so the renderer, storage, placement, and cursor-movement logic are all reused unchanged. `width` and `height` arguments in cells, pixels, or percent are translated to Kitty column/row sizes, and `preserveAspectRatio=1` picks the constraining axis from the image's real pixel dimensions. Non-image OSC 1337 sequences (Custom, SetBadgeFormat, etc.) still use the small fixed buffer, and image transfers are capped at 400 MB so a malformed stream can't run the process out of memory. `inline=0` download-mode transfers are dropped without buffering.

### Fullscreen

- **iPadOS 26 Window Control Auto-Hide in In-App Fullscreen:** When rootshell's in-app fullscreen mode is enabled and the tab bar is hidden, the iPadOS 26 traffic-light window controls now auto-hide along with the status bar, even though the underlying app window isn't in OS-level window fullscreen. Previously iPadOS 26's new persistent window controls stayed pinned on top of the terminal in this mode, leaving a visible chrome strip that the app's fullscreen toggle couldn't clear.

### AI Agent

- **Agent Availability from Shell-Launched Sessions:** Opening the AI Agent on an SSH/mosh/tssh session that was launched from the local shell (for example, via `ssh user@host` at the iOS shell prompt) showed "SSH Connection Required" and refused to attach, and the voice agent lost its SSH context in the same path. The toggles now unwrap the underlying connection so these shell-launched sessions reuse the existing SSH/mosh/tssh branches and get the full agent experience.

### Bug Fixes

- **Voice Agent Crash When Echo Cancellation Unavailable:** Starting the voice agent on an audio session or route that couldn't support echo cancellation crashed the app. The voice agent now catches that failure cleanly and shows a readable error instead of crashing.

## 1.0.2-70 - April 18, 2026

### Background Effects

- **Theme Tint for Photo and Video Backgrounds:** A new GPU-accelerated tint option recolors background media toward the active theme's palette, so photo and video backgrounds blend with whichever theme you're using instead of clashing with it. Each source color is pulled toward the nearest theme colors using a Gaussian-weighted blend across the theme's background, foreground, and 16 ANSI colors, where closer matches get more pull and distant matches fade out. The whole mapping is baked into a 32³ color lookup table once per theme and applied on the GPU in real time. An adjustable strength slider controls how far colors are pulled, so you can go from a subtle wash all the way to a fully themed reinterpretation of the image. The tint is off by default and videos only pay the extra cost when it's turned on.

### AI Agent

- **Context Window Usage Indicator:** The AI Agent input now shows how much of the active model's usable input budget the last turn consumed, so you can see when you're getting close to truncation. The reading clears when you switch models, cancel, or a turn fails, so you never see a previous model's usage attributed to the new one.
- **Live Credential Updates:** Edits to API keys or custom provider settings now apply to any AI Agent session you already have open. Previously you had to quit and relaunch the app before the new credentials or endpoint were picked up. In-flight responses keep using the credentials they started with, so an ongoing reply is never interrupted by a save.
- **Context Window for Custom Models:** You can now set a context window size on individual models added to custom providers (OpenAI Responses, OpenAI Chat Completions, and Anthropic Messages formats, including self-hosted backends like Ollama, LM Studio, and vLLM), which lights up the token usage indicator for those models. Tap a model row in the provider settings to edit it.

### Connections

- **Faster SSH Connect for Nearby Profiles:** While you browse the profiles sheet, DNS for the profile under the cursor and the ones around it is pre-resolved in the background, so when you actually pick one the connection isn't held up waiting on name resolution.
- **Snappier SSH Echo and Throughput:** Standard TCP-based SSH connections (not Mosh or tssh, which have their own transports) now stream output off the main thread, so heavy UI work (scrolling, animations, sheet dismissals) no longer briefly stalls terminal echo or delivery of output from the remote end. Those connections also use an adaptive receive buffer that grows on bursty output and shrinks when idle, so large pastes, log tails, and scrollback replays finish in fewer syscalls without adding cost to a quiet session.

### Keyboard Shortcuts

- **Multi-Key Sequence Bindings:** Two-key shortcuts recorded in the shortcut editor (for example Ctrl+A->N) now actually fire. Previously they saved but did nothing. The capture view also lays out cleanly when recording the second key, and sequence prefixes no longer get shadowed by unrelated single-key bindings.

### Bug Fixes

- **Crash When Recording Shortcuts Back-to-Back:** Recording a second shortcut immediately after dismissing the editor could crash the app. The editor now defers its changes until the sheet has fully closed, and a duplicate-press guard keeps a single keypress from being counted twice when recording a sequence.
- **Copy Pasting HTML Markup as Plain Text:** Copying certain selections (especially whitespace-only or selections that collapsed to nothing after codepoint mapping) could store HTML like `<div>…</div>` under the plain-text clipboard slot, so a later paste echoed the markup literally. Plain text and HTML are now published as separate representations on the clipboard so they can't cross-contaminate.
- **Gemini API Keys With New Prefix:** Google AI Studio recently started issuing keys with an "AQ." prefix, which the key validator rejected outright because it only recognized the old "AIza" prefix. Both known prefixes are now accepted, and any other format shows a non-blocking warning rather than blocking the save, so you can still try keys from future issuance formats.

## 1.0.2-69 - April 16, 2026

### Background Effects

- **Local Video Backgrounds:** A new "My Videos" section in Background Effect settings lets you import movies from your library and use them as terminal backgrounds. Imported files are copied into the app sandbox, probed for duration, thumbnailed, and fed into the same playback pipeline as the bundled remote catalog. Imports work from both the Files picker and the Photos library.

### iOS Local Shell

- **Cooked-Mode Stdin for Filters:** The local shell gives every command a raw pipe for stdin instead of a TTY, so running `bat` with no file argument blocked invisibly - keystrokes vanished into a silent type-ahead buffer and Ctrl-D closed the pipe before any bytes were delivered. Known stdin-consuming filters (bat, cat, grep, awk, sed, tr, sort, uniq, wc, head, tail, tee, and friends) now run through a software cooked-mode loop when invoked without a file positional or shell pipe/redirect: typed bytes are echoed locally, buffered per line, and committed on Enter; Ctrl-D flushes and closes for EOF; Backspace pops whole UTF-8 scalars so multibyte input like é or emoji can't be corrupted.

### Bug Fixes

- **Bracketed Paste Corruption on Remote Shells:** The terminal core writes a paste to the response pipe as up to three separate writes (start marker, content, end marker). When the reader drained the pipe between writes, each chunk dispatched as its own SSH packet, letting the start marker race the content and leak as literal `^[[200~` text at a bash prompt. Chunks are now coalesced so one paste maps to one send.
- **macOS Paste Losing Full Path for Finder Files:** Copying a file in Finder (Cmd+C) and pasting into the terminal inserted only the short filename instead of the full escaped path. Finder puts both a plain-text filename and a `public.file-url` on the pasteboard, and the recent HTML/RTF fix was checking plain text first so the filename always won. URL branches are now checked ahead of plain text, with the strict plain-text branch kept as the fallback.
- **macOS Paste Surfacing HTML Markup:** `UIPasteboard.general.string` bridges to NSPasteboard on macOS, which can return HTML/RTF bytes when the source app registers only rich types (Notes, Mail, some browsers), causing the terminal to faithfully type `<div>…</div>` markup into the shell. Plain text is now read by explicit UTI (utf8-plain-text, utf16 variants, public.plain-text), and the paste menu only lights up when plain text is actually available.
- **Ping UI Deadlock After Network Transition:** PingCommand ran on the main actor with a blocking ICMP socket, so a `sendto()` on a dead route after a network change parked the main thread and froze the whole app - Ctrl-C included. The socket is now non-blocking, recreated on POLLHUP/POLLERR and fatal sendto errors, and proactively reset on path-change events from NetworkReachabilityMonitor.
- **Swipe-to-Delete for Custom Provider Models:** `listRowBackground` applied before `swipeActions` was clipping the gesture, and duplicate ids from manual models that shadowed discovered ones broke ForEach row identity. Manual models now dedup over discovered entries and `swipeActions` is applied before `themedRow` so the delete gesture works again.

## 1.0.2-68 - April 13, 2026

### Security

- **Vim Modeline RCE (GHSA-2gmj-rpqf-pxvh):** Backported upstream Vim patch 9.2.0272, which fixes a two-stage exploit where a crafted modeline could escape the sandbox and execute arbitrary shell commands. The `tabpanel` option was missing the P_MLE flag, allowing modeline injection of `%{...}` expressions even with `modelineexpr` disabled; those expressions could then call `autocmd_add()` (which lacked a `check_secure()` guard) to register autocommands that fire outside the sandbox. Opening a malicious file was enough to trigger code execution. Both gaps are now closed. Impact on rootshell was muted vs other platforms as we don't fully support launching shell commands from vim but the exploit was reaching parts of the iOS local shell code path.
- **SSH Encrypted Packet Length Overflow:** Fixed an integer overflow in encrypted packet length parsing that allowed a remote peer to crash the connection before MAC verification.

### Background Execution

- **Tunnels in Location Diary:** Port forwards and SSH tunnels now participate in the Location Diary system, so auto-mode users keep tunnels alive when the app is suspended.
- **Background Awareness Prompts:** A one-time alert appears when adding a port forward on iOS, explaining app suspension behavior and offering to enable Auto Location. Contextual footer warnings appear in port forward configuration views when Location Diary is not configured.

### iOS Local Shell

- **Welcome Banner:** The plain welcome text is replaced with a width-adaptive TUI banner that picks an accent bar or stacked minimal layout based on terminal width, and uses the current prompt theme's signature color for truecolor accents.

### Bug Fixes

- **setenv/getenv Race (Crash Fix):** Fixed a crash where a background thread faulted inside getenv.
- **Pipeline Hang After Semicolons:** Commands combining semicolons with pipelines (e.g. `ls; cat file | grep foo`) could hang.

## 1.0.2-66 - April 10, 2026

### Gestures

- **Customizable Terminal Swipes:** Left/right horizontal swipes on the terminal can now be bound from Settings -> Terminal -> Gestures to presets (next/prev tab, tmux next/prev window and session, zellij next/prev tab) or to inline custom key sequences using the same SequenceStep model as the keyboard toolbar. On macOS the existing trackpad horizontal pan is routed through the same binding manager. Reminder: the keyboard toolbar already supports custom buttons that can be configured for tmux/zellij navigation if you'd rather tap than swipe.
- **Auto-Discovered Multiplexer Bindings:** For remote connections with session discovery enabled, the tmux and zellij swipe presets follow each host's actual keymap instead of assuming the built-in defaults - discovery now reads the multiplexer's bindings during the same SSH exec channel and uses them when sending the navigation keys.
- **Swipes Inside Mouse-Captured Terminals (Bug Fix):** Swipes were dead inside a mouse-captured terminal because the runtime guards and gesture-delegate filters blocked them whenever capture was active. Removed those filters so tmux/vim users in scroll mode can drive the new swipe presets even with mouse reporting on.

### Multiplexer Session Discovery

- **Local Discovery on macOS:** Tmux and zellij session discovery now runs through the standalone helper for local shells, so the session picker (and the new swipe presets) works on macOS without needing an SSH connection.

### Keybind Config Workflow

- **Editable Config:** The keybind config can now be edited and reloaded directly from Settings and the iOS local shell (via the new `reloadconfig` command). Symlink-based dotfile setups are preserved across edits, and reloads are applied safely to live terminal surfaces.

### iOS Local Shell

- **reset Command:** The terminal reset action is now available as a `reset` command in the iOS local shell, with help text and tab completion, so it can be triggered without the context menu.
- **croc Zip Filters:** `croc send` from the local shell now honors `--exclude` filters when zipping a directory, matching the behavior of non-zip sends.

### VPN

- **Control Center Start After Takeover (Bug Fix):** Starting the rootshell VPN from Control Center failed after another provider had held the system VPN slot, with the extension throwing configNotFound until the app was opened to re-bless the manager.

### Bug Fixes

- **Reconnect Sidebar Interaction Race (macOS):** When an auth failure reopened the connection sidebar before the previous dismiss animation finished, the reopened panel could appear visually but reject interaction. The dismiss completion now skips disabling interaction if the sidebar has already been re-presented.
- **Unreadable SSH Key Type Badges:** Key type badges in Known Hosts, SSH Keys, and Default Keys Order now use a tinted style (colored text on a faint same-color background) so they read cleanly in both light and dark mode instead of white-on-color. Also fixed a Known Hosts matching bug where ed25519 hosts fell through to the default badge color because keys are stored in raw OpenSSH format (`ssh-ed25519`).
- **Session Attach Shell Escaping:** Both the inner session argument and the outer `sh -c` payload used to attach to tmux and zellij sessions are now properly escaped, so crafted session names cannot trigger shell expansion or break parsing during attach.

## 1.0.2-65 - April 6, 2026

### Keyboard

- **Stuck Command Modifier (Regression Fix):** Build 64 introduced a hardware-modifier fallback to recover the Command bit on iPad system-reserved shortcuts like Cmd+. On macOS that fallback could latch after system shortcuts such as Cmd+H, causing the next keystroke to be incorrectly Cmd-modified, and the same class of issue could surface on iPad after app-switching shortcuts swallowed modifier key-up events.

## 1.0.2-64 - April 6, 2026

### Helix Editor

- **Upstream Update:** Updated to latest upstream helix. Improved syntax highlighting for Go, Rust, C/C++, Common Lisp, Erlang, Kotlin, Python, and many other languages. New language support: ebnf, embedded-perl, proverif, ptx, styx, tql. New themes: hazyland, vesper-transparent.
- **Workspace Trust:** Upstream helix added a prompt before loading workspace-specific configuration from untrusted directories. If you open a project and helix shows a trust prompt, this is new upstream behavior - approve it to allow the workspace config to take effect. Trusted workspaces are remembered.

### Keyboard

- **Persistent Toolbar:** New setting (off by default, iOS only) keeps the customizable toolbar with arrow keys and modifiers visible at the bottom of the screen after dismissing the on-screen keyboard. The dismiss button becomes a chevron-up to toggle the keyboard back, and tapping the terminal also restores it.
- **Config Import Durability:** Imported ghostty keybind configs are now copied locally to prevent iOS from revoking access to external locations (e.g., Downloads) over time. Existing imports are migrated automatically.
- **Reserved Modifier Fallback:** iOS strips the Command modifier from some keystrokes it reserves system-wide (notably Cmd+. as the iPad cancel shortcut), which caused imported `text:`/`esc:`/`csi:` keybinds like `cmd+shift+period=text:\x1B>` to silently miss.

### Multiplexer (tmux/zellij) Session Discovery

- **Sort Order:** Session list sort order is now configurable in Multiplexer preferences. Default changed from detached-first to attached-first. Sorting logic consolidated from individual tmux/zellij parsers into the shared merge step.

### tssh

- **Upstream Update:** Update from upstream with fixes for potential reconnection stalls and updated KCP library.

### croc File Transfer

- **Reliability:** Improved reliability of key exchange, encryption, file integrity checks, and path handling. Transfers are now parallelized across data ports for better throughput.
- **Relay Startup Output:** `croc relay` now prints timestamped status lines and a ready indicator on startup. Clean shutdown on Ctrl-C.
- **Exclude Option:** Fixed `--exclude` option not working for send (single files skipped pattern check, broken relative paths in directory walks, multiple flags overwriting instead of appending).
- **Local Relay Cleanup:** Fixed local relay not being cleaned up after transfer completes.
- **iOS Send Path:** Fixed send directory path resolution on iOS.

### libgit2

- **Upstream Update:** Updated to latest upstream libgit2. Includes a fix for undefined behavior in fsync and support for `@` as shorthand for `HEAD` in rev parsing.

### Bug Fixes

- **ESC Mod-Tap Overlay Dismiss:** Fixed ESC not dismissing the session discovery overlay when ESC is configured as a mod-tap key (e.g., Caps Lock -> Escape on tap, Control on hold).

## 1.0.2-63 - April 4, 2026

### croc File Transfer

- **croc:** Native Swift port of croc ([github.com/schollz/croc](https://github.com/schollz/croc)), the simple secure file transfer tool. Send and receive files between any devices on the same network or across the internet using relay servers. Interoperable with the original Go croc client - transfer files to/from your Mac, Linux box, or any other device running croc. This also makes it possible to send files between rootshell instances - for example, iPhone to iPad - even when not on the same network. Implements the complete wire protocol including PAKE (SPAKE2) key exchange, AES-256-GCM encryption, DEFLATE compression, multiplexed transfer channels, and chunk-level resume for interrupted transfers.
- **Local Relay:** Run a local relay server with `croc relay` for LAN transfers without hitting the public relay. Note: UDP multicast peer discovery is not available due to App Store restrictions, so local relay addresses must be specified explicitly. This is the main difference from croc on other platforms.
- **rf Integration:** Select files in the rf file browser and press `C` to send them via croc. Shows a confirmation prompt, runs the transfer with full progress display, and returns to rf when done.
- **Truecolor Output:** Transfer progress, code display, and status messages use truecolor terminal styling, sharing the same TerminalStyle engine as git output.

### Multiplexer Session Discovery

- **Zellij Support:** Session discovery after SSH connection now detects zellij sessions alongside tmux. Both are discovered with a single SSH exec channel. The picker overlay shows type badges and adjusts its title based on what's found - "tmux Sessions", "zellij Sessions", or "Terminal Sessions" when both are present.
- **Zellij Screen Dumps:** Session previews use the `--ansi` flag for inline capture on zellij ≥ 0.44.0. Session listing works on any zellij version.

### Keyboard

- **Keybinding Status:** External config bindings now correctly show "Config File" instead of "Custom" in the keyboard shortcuts settings.
- **Unbind Fix:** Unbinding one action no longer clobbers previous unbinds. Unbound actions show a red "Unbound" badge distinct from the gray "Displaced" badge, with "Restore Default" available in the editor.
- **Config keybind=clear:** The `keybind=clear` directive in external config files now correctly suppresses all default bindings.

### visionOS

- **Tab Close Button:** Fixed the close button overlapping the tab title on visionOS by switching from ZStack to HStack layout. Minimum tab width increased to 180pt for visionOS metrics.
- **Toolbar Joystick:** Replaced the arrow joystick button (which used raw touch handling incompatible with gaze input) with a standard tappable button on visionOS that toggles the arrow drawer via gaze+pinch.

### Bug Fixes

- **ESC Overlay Dismiss:** Fixed ESC not dismissing the session picker overlay on iPad. The ESC UIKeyCommand was intercepting the key before it reached the overlay dismiss handler.

## 1.0.2-62 - April 2, 2026

### Keyboard

- **Desktop Ghostty Config Compatibility:** Keybind configs from desktop Ghostty that use `text:`, `esc:`, and `csi:` actions now work. You can load configs that remap Cmd as Meta (e.g., `keybind = cmd+a=text:\x1Ba`). Supports `\x##` hex, `\e` ESC, and standard C escape sequences.
- **Custom Binding Priority:** Custom keybindings now take priority over the hardcoded Cmd+Arrow and Cmd+Backspace handlers, so imported desktop configs override built-in shortcuts as expected.
- **Unbind Shortcut:** Added an "Unbind Shortcut" button in the keybind editor to clear a binding without deleting it.
- **Displaced Actions Visible:** Actions whose default shortcut was taken by an external config binding (e.g., Browse Hosts when Cmd+B sends `text:\x1Bb`) now appear in Settings with "No Shortcut" instead of vanishing. You can record a new shortcut for any displaced action.
- **Config Bookmark Persistence:** External keybind config files now persist across relaunches on iOS. Previously bookmarks were only saved on macOS, so the config was lost after relaunch on iPad/iPhone.

### AI Agent

- **Custom Provider URL Fix:** Fixed custom AI provider base URLs with path components (e.g., `https://host.azure.com/openai`) having their path stripped, causing requests to go to the wrong endpoint.
- **Custom Provider Theming:** Custom provider settings sheets now follow the app theme.

### Settings

- **Acknowledgements:** Fixed the search bar chrome showing on the acknowledgements screen.

### Terminal

- **Narrow Screen Spinners:** Spinner and progress animations no longer cause scroll jitter on iPhone-width terminals. Each content line now disables auto-wrap (DECAWM) so cursor repositioning stays correct when text would exceed the screen width.

### tssh

- **Foreground Keepalive Removed:** Removed the immediate keepalive sent when the app returns to the foreground. The normal keepalive cycle handles session resumption.

### VPN Tunnel

- **Auto MTU:** The TUN device MTU is now auto-calculated from the TSSH transport's maximum datagram size instead of being hardcoded to 1500. This prevents UDP datagram fragmentation when the transport can only carry smaller payloads (e.g., KCP, QUIC). The VPN stats grid now shows both TSSH MTU and TUN MTU.

## 1.0.2-61 - March 30, 2026

### Terminal Engine

- **IPv6 Word Selection:** Double-clicking an IPv6 address now selects the entire address. Handles full, compressed (::), loopback (::1), and IPv4-mapped forms.

### iOS Local Shell

- **AI Commit Messages:** Running `git commit` can now auto-generate a commit message from the staged diff using your configured AI provider. The LLM can use read_file and list_files tools to explore the repo for context. Shows a preview with Commit/Edit/Abort prompt before finalizing. Off by default - enable in AI Agent settings under Git Integration.
- **imgtext:** New command for OCR text extraction from images using Apple Vision framework. Supports piping, redirection, multiple files, and glob expansion.
- **mtr:** Fixed a race condition where exiting mtr (q or Ctrl-C) could swallow the shell prompt.

### visionOS

- **Keyboard Toolbar:** Added the on-screen keyboard toolbar (Tab, arrows, Ctrl, Esc, modifiers, symbols) to visionOS as a native window ornament attached to the bottom of the terminal window. A floating toggle button shows/hides the toolbar. Buttons support visionOS gaze hover feedback. The toolbar is visible by default on launch.
- **Tab Bar:** Increased tab and bar height for easier eye-tracking selection. Tabs now have visible backgrounds and hover highlight effects so they can be targeted by gaze, not just the close button.
- **Clipboard:** Fixed paste from external apps and OSC 52 clipboard writes being silently ignored on visionOS.
- **Sidebar Panels:** Connection and settings sidebars now use native visionOS sheet presentation instead of custom overlays. Gray corner artifacts on rounded panels are also fixed.
- **Profiles Search:** Fixed keyboard input not reaching the profiles search box on visionOS.

### Voice AI Agent

- **Settings:** Voice agent settings are now accessible from the AI Assistant section in Settings.
- **Paste Handling:** Paste commands now route through paste action instead of writing raw text, fixing encoding and large-paste issues.
- **Tool Output Review:** Approval cards and tool results are now inspectable in full from the expanded voice view. Oversized tool output (e.g. long SSH results) spills to disk so the transcript stays reviewable without growing memory unbounded.
- **End Session Button:** Fixed the end session button appearing washed out on visionOS.
- **Voice Selection:** Expanded voice picker to the full 30-voice Gemini catalog with descriptions.
- **Alternate Screen:** The get_scrollback tool now auto-detects TUI apps (vim, htop, less) and returns the alternate screen viewport instead of stale primary screen data.
- **Scrollback Escaping:** Control characters in terminal dumps are now escaped so they don't cause the Gemini Live API to reject tool responses and reset the session.
- **TUI Interaction:** Fixed Ctrl-C, Escape, and other control characters not working when sent by the voice agent. Keystrokes now route through raw bytes matching how the real keyboard sends input. Added support for page up/down, F1-F12, Alt+letter, Shift+Tab, and Ctrl+[ keys.

### Tab Bar

- **Auto-Scroll:** Fixed the scrolling tab bar on iPhone and narrow layouts not keeping the active tab visible.

### Themes

- **Theme Picker:** The theme picker overlay now defaults to Global scope instead of Tab.

### Session Recovery

- **Window Title:** Fixed window titles not restoring in the Dock after session recovery.

### Keyboard

- **Ctrl+Backtick:** Added missing Ctrl+\` mapping, which sends NUL (0x00) matching xterm/VT tradition.

### trzsz-tssh

- **Reconnect Fix:** Pulled in upstream fix for a race condition where an async timeout flag could trigger an unnecessary reconnection loop right after a new transport path was established.

### VPN Tunnel

- **Debug Logging:** The VPN tunnel extension now captures full tssh and tsshd debug output, matching how regular SSH sessions log diagnostics.

## 1.0.2-60 - March 28, 2026

### Voice AI Agent

- **Voice Agent:** Talk to your terminal using Google's new Gemini Flash 3.1 Live model, released March 26. Bring your own Google API key - enter it in Settings > AI Agent to get started. The AI Studio free tier currently has generous limits for Flash 3.1 Live, though that may change. The agent connects to the Gemini Multimodal Live API over WebSocket for real-time bidirectional voice conversation with sub-second latency. It can read your terminal scrollback, type keystrokes, paste text, and execute commands over a background SSH connection - all hands-free. A consult_expert tool delegates complex questions to Gemini 3.1 Pro for deeper reasoning when Flash needs help. Optional web search and web fetch tools let the agent look things up on your behalf. A floating bubble overlay shows live status during the conversation - tap it to expand into a full-screen voice mode with the complete transcript and tool approval cards.
- **Tool Approval System:** Three approval modes control what the agent can do without asking - ask for all commands, auto-approve reads only, or full auto-approve. Every tool call is classified by risk level (low/medium/high/critical) with color-coded approval cards showing the command for review. Destructive operations like rm and sudo are always flagged unless you explicitly opt into auto-approve mode.
- **Menus:** Voice Agent is available from the macOS Shell menu, the right-click context menu, the iPadOS/macOS 26+ Commands menu via Cmd+Shift+V, and as a new button in the customizable on-screen keyboard toolbar.

### Helix Editor

- **Git Diff Gutter:** The iOS local shell built-in helix editor now shows added/modified/deleted line markers in the gutter when editing files inside a git repository.

### Keyboard

- **Alt/Option:** Alt+key, Alt+Shift+key, and Alt+Arrow now produce correct escape sequences. Previously Alt+Shift+letter dropped the Shift, and Alt+Arrow produced broken double-escape sequences.
- **Ctrl+Shift Encoding:** Ctrl+Shift+key now correctly encodes as a distinct modifier in CSI u mode. Previously Ctrl+A and Ctrl+Shift+A produced identical output because the Shift was ignored.
- **macOS Keyboard Layouts:** Option+key on macOS now uses UCKeyTranslate to produce layout-correct characters on non-US keyboards. Previously all Option combos assumed US layout.
- **macOS Modifier Repeat:** Fixed modifier key chords (Option-as-Alt, Ctrl+Shift) dropping held or released input on macOS.

### trzsz-tssh

- **Debug Log Labels:** Each trzsz session now includes a monotonic label (e.g. "S1 user@host") in debug logs, making it easy to distinguish interleaved output from multiple tabs or splits.

### Bug Fixes

- **Theme Hex Colors:** Fixed an off-by-one error when saving custom theme hex color values.
- **Background Opacity:** Fixed terminal theme background opacity not applying correctly on iPhone and iPad.

## 1.0.2-59 - March 27, 2026

### Terminal Engine

- **Modified Return Key Handling:** Shift+Return, Ctrl+Return, Ctrl+Shift+Return, and all other modifier+Return combinations now correctly route through the terminal engine's key encoding pipeline. Works with both hardware keyboards and the virtual keyboard toolbar modifier keys.
- **Cursor Blink Mode Fix:** Fixed animated cursor blink mode (breathing, heartbeat, etc.) persisting in the config even after disabling cursor blinking. The blink mode setting is now only written when blinking is enabled.
- **Forward Delete Key Fix:** Fixed the forward delete key on iPad hardware keyboards being misidentified as backspace. Now correctly sends the Delete escape sequence.

### iPad

- **App Switcher & Dock Titles:** Each iPad window now shows the active tab's session name (e.g. user@host) in the App Switcher and Dock, instead of a generic app name. Previously this only worked on macOS.

### iOS Local Shell

- **Ctrl-Y Yank:** The local shell line editor now supports Ctrl-Y to yank back text killed with Ctrl-K or Ctrl-U, matching standard readline/Emacs behavior.

### IP Geolocation

- **whatismyip IP Lookup:** The whatismyip, whatismyip4, and whatismyip6 commands now accept an optional IP address argument to look up ASN and geo info for any address, skipping STUN discovery. Validates the argument as IPv4 or IPv6 before lookup.

### SSH

- **sntrup761x25519-sha512 Key Exchange:** Added the sntrup761 post-quantum hybrid key exchange algorithm alongside the existing ML-KEM 768 support. sntrup761 is the algorithm OpenSSH has used by default since version 9.0, so this brings post-quantum negotiation to a much wider set of servers. Unlike ML-KEM which requires iOS/macOS 26, sntrup761 works on all supported OS versions, extending post-quantum protection to older devices.

### trzsz-tssh

- **Upstream Rebase:** Rebased against latest upstream trzsz-ssh and tsshd, picking up improved rekey crypto, better keepalive diagnostics, and per-session input discard. The upstream rekey fix eliminated the need for the SuppressRekey/ResumeRekey workaround that paused the rekey timer during iOS app backgrounding.

## 1.0.2-57 - March 25, 2026

### Terminal Engine

- **Cross-Row URL Detection:** URLs that span multiple terminal rows are now correctly detected, highlighted, and clickable even when rows are not soft-wrapped. Especially useful for long login/auth URLs such as those generated by Claude Code and Codex authentication flows. A new cross-row extension pass detects logical pane boundaries (e.g. box-drawing vertical separators in tmux split panes) and concatenates text only within the correct column range before re-running URL matching. Works both in tmux panes and the regular terminal.
- **Cursor Blink Styles:** New Blink Style picker in Settings > Cursor > Animation with 7 animated modes: normal, breathing, heartbeat, neon flicker, pulse, candle, and rootshell. Persists across sessions.
- **Harmonious Palette Generation:** New toggles in Settings > Appearance > Colors to enable palette-generate and palette-harmonious modes. Includes a live inline preview using CIELAB trilinear interpolation algorithm, showing the 216-color cube and 24-step grayscale ramp updating in real time as settings change.
- **Mouse Click Selection:** Fixed mouse/trackpad single-click incorrectly triggering word selection on iPad. Single-click now positions the cursor, double-click selects a word, and triple-click selects a line, matching macOS Ghostty click counting. Touch input is unchanged - double-tap still opens the context menu.
- **Copy on Select:** Text selections are now automatically copied to the clipboard on all platforms (iOS, iPadOS, macOS, visionOS). Configurable via a toggle in Settings > Window > Text Selection, defaults to on.
- **Window Titles:** On macOS, each window now shows its session name (e.g. user@host) in the dock menu and Mission Control instead of a generic title.

### IP Geolocation

- **Local MMDB Databases:** Import MaxMind DB files (.mmdb) for fully offline IP geolocation. A new "Local MMDB" provider option performs all lookups on-device with no network requests. Import multiple ASN and country databases and the resolver merges fields across them. Manage databases in Settings with drag-to-reorder priority, swipe-to-delete, and a file importer that validates MMDB structure on import.

### iOS Local Shell

- **Dynamic bat Syntax Theme:** bat syntax highlighting in the local shell and rf file previews now uses the terminal's actual RGB palette colors instead of generic ANSI indices. Colors are pushed at session startup and on theme change, producing truecolor output that matches any theme including custom ones.

### rf File Browser

- **SFTP Responsiveness:** Remote SFTP operations (directory listing, file preview, transfers) no longer block the rf UI. Navigation, filtering, and local tab interaction remain responsive while SFTP work runs in the background.
- **Status Bar Rendering:** Fixed status messages like "Loading directory..." and chord prompts like "copy: (c)path..." rendering with spurious trailing colons. The status bar now uses separate rendering paths for text input (with cursor), chord prompts (with block cursor), and status messages (no cursor). Waiting states (SFTP connecting, directory loading) show an animated Braille spinner.

### SSH

- **Remote Exec PATH Hardening:** SSH exec requests now prepend a comprehensive PATH covering Homebrew, Linuxbrew, Go, snap, and standard system directories. Fixes tssh, mosh, AI agent, and remote commands failing on macOS hosts with zsh configuration, where non-interactive exec channels have a minimal PATH that excludes common tool locations. Also benefits other hosts with restrictive non-interactive PATHs.

## 1.0.2-56 - March 24, 2026

### Themes

- **256-Color Extended Palette:** Importing theme files with palette entries beyond index 15 (colors 16-255) now preserves the extended colors. Previously these were silently discarded. Existing saved themes decode without issues and the new extendedPalette field defaults to empty. The theme editor shows an informational row when extended colors are present.

### rf File Browser

- **SFTP Remote Browsing:** Press 'o' in rf to open a saved SSH profile and browse the remote filesystem in a new tab. Local and SFTP tabs coexist in the same rf instance with independent connections. Navigate, preview, create, rename, and delete files over SFTP. Remote preview uses a three-phase pipeline: instant plain text, then bat syntax highlighting via temp file download (preserving the filename for language detection), then kitty image preview for images.
- **Cross-Source Yank/Paste:** Yank files locally and paste into an SFTP tab to upload, or yank remote files and paste locally to download. The shared clipboard works across all rf tabs. Recursive directory transfers with cancellation support.
- **Remote Edit:** Press 'e' or return on a remote file to download, edit locally, and auto-upload on save. Change detection skips upload if unmodified. If the upload fails, the edited file is copied to Documents/.rf-recovery/ and an interactive prompt offers retry, copy-path, and dismiss - preventing data loss from temp file cleanup on exit.
- **Profile Picker:** Scrollable list with j/k navigation, live filtering by name/host/username, and Tab completion.
- Dramatically faster bat preview for large files. Rewrote the ANSI parser, files that previously took seconds to render now preview instantly.

### Debug

- **VPN Connection Debug Logger:** New opt-in diagnostic logger that records timestamped phases (DNS, SSH, tsshd spawn, Go netstack) with millisecond durations during VPN connection setup. Off by default.

### Binary Size

- **Release Build Size Optimizations:** Enabled symbol stripping, dead code stripping, and thin LTO in the Xcode release configuration for a smaller binary.
- **Rust Dependency Size Optimizations:** bat, gitoxide, and helix builds now smaller.

## 1.0.2-55 - March 22, 2026

### iOS Local Shell

- **Transient Prompt:** After running a command, the full info bar prompt is replaced with a minimal ❯, reducing scrollback clutter. Customizable via `[transient_prompt]` in .promptrc.toml or the new Advanced section in Settings.
- **Right Prompt:** The clock segment can be moved from the left info bar to a right-aligned position, making the left prompt shorter. Uses ANSI cursor positioning and works with all 13 built-in themes. Configure via `right_format` in .promptrc.toml or the Settings toggle.
- **rf File Browser:** Navigation is now restricted to ~/Documents by default, preventing browsing above the app sandbox home. Disable with `restrict_to_home: false` in rf.yaml. Yanked-cut files now render with strikethrough and dim to distinguish from yanked-copy (yellow only). New `u` key clears the yank clipboard and selection. Yank operations immediately re-render the file list. Added config file support - `~/.config/rf/rf.yaml` persists `show_hidden`, `sort_by`, and `restrict_to_home` settings across sessions.

### Bug Fixes

- Fixed ghost image overlays in rf file browser when rapidly navigating through image files. Stale image render tasks could complete after the cursor moved on, leaving previous images stuck on screen.
- Fixed cursor effect preview row in Settings not matching the themed background color.
- Fixed a crash when viewing JavaScript, HTML, or any file containing `<script>` blocks with `bat`. The previous regex engine (fancy-regex) didn't support atomic grouping and possessive quantifiers used in JS/Babel syntax definitions. Temporarily switched to Oniguruma which supports the required regex features. Added panic isolation at the FFI boundary as defense in depth.

## 1.0.2-54 - March 22, 2026

### iOS Local Shell

- **rf File Browser:** Built-in `rf` command - a yazi-inspired Swift-native TUI file browser with miller columns. Vim navigation, tabs, filename filter, ripgrep search, bookmarks, file ops (yank/paste/delete/rename/create), visual select, bat syntax-highlighted preview, kitty image preview, git status, 700+ Nerd Font icons, powerline statusbar, copy chords, mouse-draggable columns, and editor shell-out. Optimized for iPad.
- **Shell Scripts:** Run POSIX shell scripts on device via `sh script.sh` or `./script.sh`. Supports if/for/while/until/case, functions, pipelines, variables ($?, ${VAR:-default}), quoting, here-documents, redirections, and 25 builtins (test, printf, read, sleep, trap, eval, source, etc.). The ~/.rootshellrc dotfile is now sourced through the interpreter.
- **Multi-Line Input:** Incomplete compound commands show a `> ` continuation prompt until complete. Lines ending with \, |, &&, ||, then, else, do, or { also continue. Ctrl-C cancels.
- **Brace Expansion:** {1..10}, {a..z}, {1..10..2}, {10..1}, and {a,b,c} work in for-loops and commands.
- **Builtin Tab Completion:** Shell builtins now appear in command-position tab completion.
- **Width-Aware Prompt:** Prompt adapts to terminal width - progressively truncates paths, then git branch, then hides git status as the terminal narrows.

### SSH

- **Ctrl-C to Cancel Connections:** Ctrl-C during SSH/SFTP/Mosh/Trzsz connection now cancels and returns to local shell.
- **Remote Command Execution:** `ssh host command` sends a remote exec request instead of opening an interactive shell, matching OpenSSH.

### Connections

- **Connection Sheet Redesign:** Glass-effect capsule tabs replace the previous menu, with collapsible sections for jump host, agent forwarding, port forwarding, and terminal options.
- **Profile Color Tags:** Custom color now tints the profile icon directly instead of a separate indicator.
- **Active Session Counts:** Profiles show the number of active terminal sessions.

### Terminal

- **Aurora Cursor Effect:** Theme-aware cursor shader that picks the two most vibrant colors from your palette. Adapts when you switch themes.

### Settings

- **Cursor Style Previews:** Visual terminal-cell previews for block, bar, underline, and hollow block styles.
- **Cursor Shader Effect Preview:** Live preview with an animated terminal surface showing shader trail effects in real time.

### Bug Fixes

- Fixed a crash when locking the device while the app is running.

## 1.0.2-53 - March 20, 2026

### iOS Local Shell

- **Pipe Command Latency Fix:** Piped commands (ls | grep, cat file | head, etc.) no longer have a ~1 second delay before command completion. The pipe monitoring system was rewritten from polling with Task.detached sleep loops to event-driven kqueue-backed DispatchSource read sources.
- **libarchive 3.9.0 Upgrade:** The bundled tar has been upgraded from libarchive 2.8.3 to 3.9.0 (newer than the version shipped with macOS Tahoe), and now ships four tools instead of one: bsdtar, bsdcat, cpio, and unzip. The upgrade brings Zip64, RAR/RAR5, 7-Zip, CAB, and LHA archive reading; Zstandard, lz4, lzip, and lzop compression; bsdunzip as a standalone unzip replacement; bsdcat for streaming decompression to stdout; and cpio for cpio/pax archives. Broader metadata fidelity (xattrs, NFSv4 ACLs) and years of OSS-Fuzz hardening are also included.
- **Custom Prompt Configuration:** Create a .promptrc.toml file to fully customize the shell prompt beyond the 13 built-in themes. Uses a Starship-compatible format string syntax with 11 configurable modules: username, directory, git_branch, git_status, time, battery, character, wifi, network, connection_type, and line_break. Supports true color hex, ANSI named colors, and named color palettes (13 bundled including Catppuccin, Tokyo Night, Gruvbox, Dracula, Nord, and others). Powerline arrows and rounded caps are auto-inserted between segments. Modules with unavailable data collapse automatically. Edit with the `editprompt` command, reload from Settings, or just save the file - changes are picked up on next prompt. A bundled example file documents all options.

### SSH (trzsz-ssh / tssh)

- **Session Reattach TUI Redraw:** After reattaching to a server-side session, full-screen TUI apps (Helix, Vim, etc.) now receive a forced SIGWINCH to trigger a full repaint, even when the terminal dimensions haven't changed since the previous connection.
- **Terminal Modes Persisted Across App Kill:** Mouse tracking, cursor key mode, and bracketed paste state are now saved and restored when reattaching after app termination. Previously, Helix/Vim mouse clicks, arrow keys, and paste behavior would break after reattach because the server wouldn't re-send enable sequences for modes it believed were still active.

### AI Agent

- **OpenAI GPT-5.4 Models:** Updated the OpenAI model list to GPT-5.4 Mini and GPT-5.4 Nano (released March 17, 2026), replacing the older GPT-5 Mini and GPT-5 Nano model IDs. GPT-5.4 Mini is the new recommended default.

### Bug Fixes

- Fixed SCP tab completion to suggest both local file paths and saved hostnames (previously only offered hostname suggestions), and fixed non-standard port connections inserting invalid syntax like user@host:2222: instead of the correct -P 2222 user@host: format.

## 1.0.2-52 - March 18, 2026

### SSH

- **Paste Image Upload:** Pasting non-text clipboard content (images, screenshots, etc) into an SSH session via Cmd+V or the touch paste menu uploads the file to the remote server and inserts the remote path at the cursor using bracketed paste. A confirmation sheet with thumbnail preview appears before uploading. Useful for AI CLI tools (Claude Code, Codex, Gemini CLI) that can read images from a filesystem path.

### iOS Local Shell

- **xz Compression:** The xz, unxz, and xzcat commands are now available in the local shell. Compress and decompress files using the XZ/LZMA2 format directly on device. Based on xz 5.8.2.
- **Type-Ahead Buffer:** Keystrokes typed while a non-interactive command is running (git pull, curl, ls, etc.) are now buffered and replayed through the line editor when the prompt returns, matching real terminal behavior. Full-screen programs (vim, hx) still receive input directly.
- **Shell Startup Dotfile:** A ~/.rootshellrc file is sourced when a new shell tab opens. Supports export/setenv, alias, and arbitrary commands. Edit with `editrc`, re-source with `source`. A built-in health tracker detects when the rc file causes hangs or crashes and skips it on subsequent launches until you fix it.

### Terminal

- **Trackpad Long-Press Fix:** Long-pressing (click-and-hold) on a Magic Keyboard trackpad no longer triggers the context menu. This was interfering with click-and-drag text selection. Right-click context menu still works as expected.

### Keyboard

- **Tab as Mod-Tap Source Key:** Tab can now be used as a mod-tap source key. Tap sends Tab, hold activates the assigned modifier or action. Configure in Settings > Terminal > Keyboard > Mod-Tap Keys.

### Bug Fixes

- Fixed a watchdog crash when backgrounding the app on slow or degraded networks. Heavy I/O work (state serialization, encryption, scrollback buffer dumps) is now performed off the main thread during background transitions.
- Fixed keyboard focus not returning to the terminal after dismissing host key, agent approval, or other alert dialogs.
- Fixed SCP upload overwriting the destination path instead of placing the file inside it when the destination is an existing directory (e.g., "scp foo.txt host:/tmp" now correctly uploads to /tmp/foo.txt).
- Fixed Esc key not navigating back out of Profile folders in the connection sidebar (regression in build 51). Esc now walks back through folder levels before closing the sidebar.

## 1.0.2-51 - March 16, 2026

### SSH

- **Session Resume via --attachable:** Migrated from the reconnect branch to upstream tsshd's official `--attachable` flag for session persistence. When the app terminates, the server-side session stays alive and the client reattaches with `Attach()`. Saved sessions are persisted in the Keychain so resume works across full app restarts. Users on the unofficial reconnect branch will need to migrate to the official upstream version of tsshd for sessions to survive app termination. New connections and roaming prior to app termination will continue to work prior to upgrading. See [tsshd](https://github.com/trzsz/tsshd/).
- **Agent Forwarding for tssh Sessions:** SSH agent forwarding now works through the KCP/QUIC transport layer. All approval modes (auto, per-session, per-request) and key filtering work the same as direct SSH sessions. Agent forwarding is active for both new and resumed/attached sessions.

### WiFi

- **AP Radio Scanning:** SSH into Ubiquiti access points to discover per-radio interfaces (ESSID, frequency, BSSID, band) via iwconfig. Only wireless APs are scanned - switches and gateways are filtered out using the UniFi Network API. Band badges (2.4/5/6 GHz) appear on AP rows, in the bssid shell command, and in the Live Activity lock screen widget. Configure SSH credentials per account in WiFi AP settings. This also resolves AP name matching failures where the base MAC address from the UniFi API did not match the per-radio BSSID reported by iOS.

### Connections

- **Sidebar on iPad and macOS:** The connection sheet is now a right-edge sidebar overlay that slides in, replacing the fullScreenCover presentation. iPhone still uses a standard sheet.

### iOS Local Shell

- **Seamless Session Restore:** Restored sessions no longer flash a new prompt on top of existing scrollback. If the shell was idle at a prompt when backgrounded, both the banner and prompt are suppressed for a seamless resume. If a command was running, a new prompt is shown so you can continue.

### Bug Fixes

- Fixed Helix crashing when using the bookmarked locations feature. Helix's Rust threads call `chdir()`, where the per-session pointer is NULL. The chdir/fchdir paths now guard all session dereferences with NULL checks.
- Fixed CTRL-C during iOS local shell SSH password prompt breaking all subsequent terminal input. The interrupt handler now recognizes all 9 prompt modes (password, host key, save password, etc.), clears their buffers, resets to the local shell, and redisplays the prompt.
- Fixed local shell CWD not restoring across iOS container UUID changes. Paths with /private/var vs /var prefixes are now normalized, and the working directory is kept in sync after cd commands.
- Fixed git SSH operations occasionally crashing on teardown due to a double-close race on the drain task's pipe file descriptor.
- Fixed duplicate "About" section appearing in WiFi AP provider settings.

## 1.0.2-48 - March 14, 2026

### Backup & Restore

- **Encrypted Backups:** Export all app data - SSH keys, passwords, connection profiles, known hosts, custom themes, custom fonts, keyboard shortcuts, HSS configs, cloud accounts, AI settings, and preferences - into a single password-protected .rootshellbackup file. Encryption uses AES-256-GCM with a key derived via PBKDF2-HMAC-SHA256 (600,000 iterations). Restore performs intelligent merging (deduplicates SSH keys by fingerprint, passwords by connection, etc.) rather than overwriting existing data. Found in Settings > Privacy & Data > Backup & Restore.

### AI

- **Local Shell Agent:** The AI agent can now run commands in the iOS local shell. It has access to file tools (read_file, write_file, edit_file) that are sandboxed to the app's Documents directory and respect the approval flow. The agent receives an iOS-specific system prompt documenting available and unavailable commands, and uses the terminal's current working directory as context.

### WiFi

- **Manual AP Names:** Associate BSSIDs with vendor names, domains (for favicon), and friendly AP names without needing a Ubiquiti or other provider integration. Entering a BSSID auto-detects the vendor from the OUI database (~20K vendors, prefix-ranked search). A "Use Current BSSID" button grabs the connected AP. Manual entries appear in the bssid command, Live Activity, and WiFi info displays. Included in backup/restore.

### iOS Local Shell Prompt

- **Git Branch Segment:** Starship-style prompts now show the current git branch name (or short hash on detached HEAD) and staged file count between the directory and time segments. Each of the 13 prompt themes has a matching green-toned color for the segment. Toggle in Settings > Terminal > Prompt & Username > Show Git Status.

### Git

- **Pipe and Redirect Support:** Git commands now run through the full pipeline, enabling piping (`git log | grep foo`) and redirection (`git status > file.txt`). Auth flags and editor commits still use the interactive path.
- **Color Output:** New --color=auto|always|never flag. Auto-injects --color=always when output goes to the terminal and strips ANSI codes when piped or redirected.
- **Auto-Pager:** Paged subcommands (diff, log, blame, reflog) pipe through bat via real pipelines instead of a temp file.

### Helix

- **Directory Argument:** Running `hx .` or `hx ~/project` now opens the file picker for that directory instead of silently opening an empty buffer.

### Settings

- **Double-Space for Period:** Optional shortcut that converts two rapid space taps on the on-screen keyboard into ". " (period + space), matching iOS system behavior. Off by default. Found in Settings > Terminal > Keyboard.

### Bug Fixes

- Fixed local shell losing its working directory after app relaunch when iOS assigns a new container UUID. Saved paths are now rewritten relative to the current container.
- Fixed git fetch progress bar getting stuck at ~99% and never reaching 100%. Each phase (receiving, resolving deltas, indexing) now properly completes.
- Fixed tab morph animation regression in last build.
- Fixed duplicate section titles appearing in Settings.
- Fixed missing vertical padding in the Settings sidebar on iPad and Mac.
- Fixed piped commands losing session context (tty, window size), which broke keyboard input for pagers in pipelines.
- Fixed "/" search in the bat pager not accepting keyboard input.
- Fixed day/night theme not applying the correct theme on cold launch.

## 1.0.2-47 - March 12, 2026

### tmux

- **Session Discovery:** After connecting via SSH, Mosh, or tssh, the app checks for active tmux sessions on the remote host. A floating overlay lists them with window count and last-activity timestamp. The selected session shows a live terminal preview of the active pane with ANSI colors. Tap or press a digit key to attach, arrow keys to navigate, Escape to dismiss. Skipped when tmux auto-connect is enabled. Toggle in Settings > Connections > tmux.

### Settings

- **Redesigned Navigation:** iPhone settings changed from a single long flat list to a two-level category layout. iPad and macOS settings changed from a centered modal card with a two-column split view to a narrow sidebar.
- **Search:** A floating search bar at the bottom of settings lets you find any setting by name or keyword. Tap the pill or start typing to expand it into a filtered results panel that navigates directly to the matching setting.
- **Toggle with Cmd-Comma:** Pressing Cmd+comma while settings is already open now closes it instead of doing nothing.

### Themes

- **Chromatic Background Support:** Themes with colorful dark backgrounds (dark teal, dark purple, etc.) now get tab backgrounds that retain their color character instead of looking washed out, and accent colors that harmonize with the background instead of clashing.
- **Adaptive Tab Contrast:** Medium-dark themed backgrounds now have stronger tab differentiation so selected and unselected tabs are easier to distinguish.
- Sheet and row backgrounds in dark themes preserve the theme's color character instead of shifting toward neutral gray.

### AI

- **Toolbar Button:** Sparkles icon in the virtual keyboard toolbar toggles the AI agent panel.
- Added Gemini 3.1 Flash Lite preview model.

### Git

- **7 New Commands:** cherry-pick, rebase, reflog, worktree, clean, apply, and switch are now available natively. Cherry-pick and rebase support --continue, --abort, and --skip for conflict resolution. Worktree supports list, add, remove, lock, and unlock. Clean requires -f or --force (with -n for dry run).
- **Enhanced Existing Commands:** log gained --all, --graph, --grep, --since, --stat, -p, and path filtering. diff gained commit ranges, --name-only, --name-status, and --diff-filter. merge gained --no-ff, --ff-only, --squash, and -X ours/theirs. stash gained show, -u, -k, and branch. branch gained --show-current, --set-upstream-to, and --merged. blame gained -L line range, -w, and --date format. checkout gained -B, --track, --ours, and --theirs. revert gained --continue, --abort, and -m mainline.
- **Auth Override Flags:** New --ssh-key, --password, and --profile global flags let you override automatic SSH credential resolution for remote operations. --ssh-key forces a specific saved key by name, --password prompts interactively, and --profile uses a saved connection profile's auth method and optional jump host.

### Bug Fixes

- Fixed Helix file picker (Space+f) showing files from the initial working directory instead of the current directory after using cd.
- Fixed git checkout -b and switch -c corrupting the working tree if branch creation fails. Operations now pre-validate and rollback safely.
- Fixed git rebase --skip silently continuing with a stale index. The index is now properly reset to HEAD before updating the working tree.
- Fixed SSH key iCloud sync failing with Keychain error -50 when biometric auth was set. The Keychain API does not support combining iCloud sync with per-operation access control.
- Fixed renaming a custom theme losing the active theme selection, favorites, day/night assignments, and per-tab/window overrides. All name-based references now track the new name.

## 1.0.2-46 - March 11, 2026

### Git

- **Pull Fast-Forward:** Fixed git pull fast-forward leaving the working tree dirty after a successful pull. Also added rollback recovery so the working tree is restored if the ref update fails after checkout.
- **Help & Tab Completion:** The git command is now listed in the local shell help output and available in tab completion.
- **Progress Bars:** Git clone, fetch, and push progress bars now size dynamically to fit the terminal width, preventing line wrapping on iPhone screens.
- **SSH Auth Resolution:** Git SSH transport now supports auth-none and saved-password connections in addition to key-based auth. The credential resolver checks saved connection profiles, then SSH history for matching hosts, before falling back to default keys.
- **Known Hosts Validation:** Git SSH connections now validate host keys against your known hosts store instead of blindly accepting all keys. Unknown or changed keys are rejected.
- **Repo-Optional Commands:** git general and git config now work outside a git repository, showing global config and system info instead of erroring. Real errors (corrupt .git, permission denied) are still surfaced.

### Live Activity

- **WiFi Info:** The lock screen Live Activity can now display your current WiFi SSID and access point name (if a WiFi AP provider is configured). Enable in Settings > Live Activity > WiFi Info.
- **Network / ISP Info:** Public IP address, ISP name, and country are shown on the lock screen via STUN + geo lookup. Enable in Settings > Live Activity > Network Info.
- **Favicons:** WiFi vendor and ISP favicons are displayed inline on the lock screen widget next to their respective rows.
- WiFi and network data update in the background when iOS grants execution time, but the app is not always running - information may be stale until you return to the app.

### iOS Local Shell

- **ripgrep (rg):** Fast regex-based file search is now available as a local shell command. Pairs naturally with the new git support - clone a repo and immediately search it with rg. Supports all standard rg flags including file type filters, context lines, and glob patterns.

### Bug Fixes

- Fixed third-party keyboard input (notably WeChat keyboard in English mode) producing garbled or missing terminal output. These keyboards send autocompleted words as multi-character replacements rather than individual keystrokes; the terminal now diffs the incoming text against the document buffer and emits the correct backspace + insert sequence.
- Fixed the I-beam cursor leaking into the Settings view on iPad when presented as a modal over the terminal.
- Fixed toolbar key presses (virtual keyboard) always going to the terminal even when the Compose overlay was open. Plain character keys and tab now route to the compose text view while modified keys (Ctrl/Alt/Cmd) and escape still reach the terminal.

## 1.0.2-45 - March 10, 2026

### iOS Local Shell Git

- **Native Git CLI:** A Swift-native git implementation powered by libgit2, with truecolor output styling and Nerd Font icons. Supported subcommands: init, clone, status, add, commit, diff, log, blame, branch, reset, pull, push, fetch, rm, mv, show, and revert.
- **SSH Transport:** Clone, push, and pull over SSH using the built-in SSH client. SCP-style URLs (git@host:path) are supported.
- **Helix Editor Integration:** Running git commit without -m opens the Helix editor for composing commit messages interactively.
- **Syntax-Highlighted Pager:** git diff, log, and blame output is piped through bat for syntax highlighting and paged scrolling.
- Note: Git support is new and has not yet been thoroughly tested. Take caution when using it with production data.

### UI

- **Double-Tap to Paste:** The double-tap gesture on a terminal tab has been replaced with a context menu that includes Paste, making it easier for touch users to paste without a hardware keyboard.
- **Settings Navigation:** Reworked the settings split view navigation for smoother transitions and more reliable detail-column push behavior.
- **Theme Tinting:** Improved contrast tuning for themed sheet tints so text and controls remain legible across light and dark themes.
- Adapted Live Activity colors for tinted Liquid Glass mode.
- Increased terminal dimming behind sheets.
- Selection handles now only appear for touch-initiated selections.

### Bug Fixes

- Fixed pbcopy and other commands crashing when interrupted. The shell engine now uses cooperative cancellation instead of pthread_cancel, which could corrupt internal state mid-operation.
- Fixed theme search results appearing empty until scroll or jiggle.
- Fixed virtual keyboard toolbar Ctrl-C not interrupting local shell.
- Fixed iOS text selection handle alignment.
- Fixed selection handles not restoring after returning from background.
- Fixed intermittent SSH password auth failures caused by 10-second login timeout.
- Fixed traceroute failing with dlsym symbol not found error.
- Fixed enterprise AP vendor lookup with improved BSSID handling.
- Fixed OpenAI stream errors with optional error messages.
- Suppressed duplicate welcome banner on local shell session restore.

### Reliability

- **Protected Data Guard:** Background launches (VPN reconnect, Live Activities, CloudKit push) can start the app before the device is unlocked, causing UserDefaults to return empty values. All UserDefaults-dependent initialization is now deferred until protected data is available, and didSet observers that write back to UserDefaults are guarded against running while the device is locked.

### AI

- Updated OpenAI model to GPT-5.4.

## 1.0.2-44 - March 8, 2026

### Terminal

- **Magnifier Loupe:** A magnifier loupe now appears when dragging selection handles, panning a text selection, or dragging in capture mode. The loupe tracks your finger or cursor for precise positioning. Works inside tmux panes and split views.
- **Selection Handles:** Touch-based text selection now shows draggable handles at the start and end of the selection. Drag either handle to adjust the selection range. The edit menu appears automatically when you finish dragging. Handles stay in sync with the active surface and hide when overlays or other views appear on top.
- **Mouse Capture Toggle:** Press Cmd+Shift+M or tap the mouse button in the keyboard toolbar to force-disable mouse reporting. When active, native text selection and scrolling work even inside programs that capture the mouse like tmux, vim, or htop. Toggle again to restore mouse reporting.

### WiFi & Networking

- **WiFi AP Providers:** New provider system for identifying the access point you're connected to. The first integration is Ubiquiti UniFi - add your API key in Settings > WiFi AP Providers to see the AP name, model, and location for your current BSSID. macOS is fully supported.
- **OUI Vendor Lookup:** The bssid command now performs IEEE OUI lookups, showing the hardware vendor for any BSSID. Randomized MACs are detected and labeled.
- **Favicons:** The bssid and whatismyip commands render favicons inline next to domain names for ISPs and vendors using the Kitty image protocol. Icons are fetched and cached automatically.

### iOS Local Shell

- **Help Command:** Expanded to include all available commands with localized descriptions.
- **Localization:** Added missing translation keys across all 25 supported languages.

### Bug Fixes

- Fixed bssid showing the wrong error message on the first run when location permission has not yet been granted.
- Fixed whatismyip and the Geo Provider settings view hanging on IPv4-only networks while waiting for IPv6 STUN queries that could never succeed.

## 1.0.2-43 - March 7, 2026

### Themes

- **Theme-Aware UI:** Your terminal theme's colors now extend beyond the terminal. Settings views, connection sheets, toolbars, toggles, and sub-sheets are all tinted with your theme's accent and background colors. This is on by default; turn it off in Settings > Appearance Mode to fall back to standard Light/Dark mode styling.
- **Custom Themes:** Create your own themes with a full color picker GUI, duplicate any built-in theme as a starting point, or import Ghostty theme files. Custom themes can be exported and shared, and work everywhere built-in themes do - favorites, day/night switching, and per-tab overrides.

### IP Geolocation

- **Geo Provider:** IP geolocation lookups now support multiple providers. Choose between IPInfo Lite (new default), Team Cymru DNS, or disabled. Results are cached locally (500 entries, 7-day TTL). Configure in Settings > IP Geolocation.
- **Network Info in Settings:** The IP Geolocation settings view now shows your live public IPv4/IPv6 addresses with per-IP network info (ASN, org, country). Automatically refreshes on network changes and provider switching.
- **Richer Geo Data:** Connection Info, whatismyip, and mtr now show AS name, domain, and continent when available (via IPInfo). mtr adds two new display modes for AS name and continent.

### Settings

- **Sidebar Layout:** Settings now uses a two-column sidebar layout on iPad, macOS, and visionOS. Sections are listed in a persistent sidebar with the detail view alongside. Sub-navigation (e.g. SSH Keys > Key Detail) pushes within the detail column.
- **SF Symbol Icons:** All Settings rows now display icons for easier scanning.
- **Font Size:** Lowered the minimum font size from 8 to 4.

### Terminal

- **Scroll Keybinds:** Terminal scrolling moved from Page Up/Down to Cmd+Up/Down, matching standard macOS conventions.

### Bug Fixes

- Fixed CapsLock-as-Shift (mod-tap hold) being ignored by the case fixup logic, and fixed Shift capitalization breaking when CapsLock mod-tap compensation was active.
- Fixed function keys (F1-F12) sending wrong keycodes on macOS.
- Fixed mtr column misalignment on unknown hops when country flags are displayed.
- Fixed bssid command failing on devices without a VPN configured. Note: Apple requires Precise Location permission to access BSSID unless rootshell is your active VPN provider.

## 1.0.2-42 - March 6, 2026

### SSH and Networking

- **Connection Info:** Right-click or long-press a terminal tab and choose "Connection Info" to see a live sheet with connection duration, negotiated SSH cryptographic algorithms (key exchange, host key, cipher, MAC), post-quantum security status, ASN, country, and CIDR. Mosh and tssh sessions show the crypto negotiated during the bootstrap SSH handshake plus the transport mode (QUIC vs KCP for tssh).

### iOS Local Shell

- **whatismyip:** Discover your public IPv4 and IPv6 addresses via STUN. Shows ASN, CIDR, and country for each address and copies bare IPs to the clipboard. Use `whatismyip4` or `whatismyip6` for a single address family, or `-g` to skip the ASN/geo lookup.
- **bssid:** New command to display the SSID and BSSID of the connected WiFi network.

### VPN

- **Control Center Widget:** New VPN toggle for Control Center, the Lock Screen, and the Action Button. Supports profile selection.
- **Background Connect/Disconnect:** The VPN widget and Shortcuts intent no longer need to launch the main app to start or stop a connection.
- Note: A device reboot may be required after this update for widgets to appear and function correctly.

### Terminal

- **Function Keys:** F1-F19, Insert, PrintScreen, ScrollLock, and Pause are now routed through Ghostty's key encoding pipeline instead of being silently dropped. All encoding modes (legacy VT220, CSI u, kitty protocol) are handled correctly.
- **Cursor Settings:** New options for cursor color, cursor text color, opacity, thickness, and height.
- Fixed lock screen live activity title centering.

## 1.0.2-41 - March 4, 2026

### iOS Local Shell

- **mtr / traceroute:** Custom Swift implementation built for rootshell. mtr shows an interactive TUI with per-hop loss, RTT statistics, jitter, and AS number lookups. Three display modes (statistics, stripchart, strip+numbers) and report formats (text, CSV, JSON, XML). traceroute/traceroute6 are aliased to one-shot mtr reports. The interactive display uses truecolor gradients derived from your terminal theme. Loss and latency values smoothly interpolate between green, yellow, and red using your theme's palette colors. Press 't' to toggle between truecolor and classic 16-color mode. Works on IPv6-only carrier networks with NAT64 translation.
- **imgcat Wildcards:** The imgcat command now accepts glob patterns (e.g. `imgcat *.png`) to display multiple images at once.
- Fixed imgcat hanging on large images.
- Fixed imgcat blocking the UI while encoding large images.
- **SFTP Wildcards:** Interactive SFTP commands (ls, get, put, rm) now accept glob patterns for batch operations on multiple files.
- Fixed SFTP glob matching for mid-path wildcards, rm on directories, and destination path validation.

### SSH and Networking

- **Pipelined SFTP/SCP:** File transfers over high-latency links are up to ~15x faster. Multiple SFTP requests are now sent in a pipeline without waiting for each individual acknowledgment, dramatically reducing round-trip overhead.
- **Tmux Settings:** New options to customize the tmux session name and specify a custom tmux command. The settings view now shows the resolved command for easy copying and includes a clear button to reset to defaults.

### CJK Input

- **IME Preedit Display:** Composing CJK characters now shows a live preedit overlay near the cursor, so you can see what you're typing before committing. Input is NFC-normalized for correct rendering of precomposed Hangul and other Unicode sequences.

### Bug Fixes

- Fixed the "Change Title..." dialog pre-filling with "ghostty" instead of the tab's current title.
- Rewrote session save/restore. Scrollback and the active viewport are now captured in two separate phases, fixing blank line injection from soft-wrap boundary splits and ensuring the active area replays correctly regardless of terminal size on restore. Also fixed CTRL-L (clear screen) not triggering a save. Detection now uses a content hash instead of row count so any layout change is captured.
- Minor Live Activity polish: fixed timer overlap on Always-On Display, adjusted background tint and opacity to blend with the lock screen while keeping a slight visual differentiation from system notifications.

## 1.0.2-40 - March 3, 2026

### Terminal

- **Photo Background:** New terminal background effect that displays a photo from your library behind the terminal. Choose from named opacity presets (Subtle through Vivid), apply one of 9 image filters (Noir, Chrome, Sepia, and more), and optionally enable a Ken Burns cinematic pan/zoom animation with adjustable speed. Photos persist across launches. Configure in Settings > Background Effect.
- **Sound Presets:** Configurable sounds for the terminal bell and notifications. Bell sounds include 6 presets (Classic Bell, Soft Chime, Glass Tap, Typewriter Ding, Digital Beep, Muted Thud) plus haptic-only and silent options, with a volume slider and live preview. Notification sounds offer 5 presets plus the system default. Configure in Settings.

### iOS Local Shell

- **imgcat Command:** New command to display images inline in the terminal using the Kitty graphics protocol. Supports PNG, JPEG, HEIC, and other image formats. Use -w and -r flags to control display sizing.
- **Ping Accuracy:** The ping command now uses kernel-level receive timestamps (SO_TIMESTAMP) instead of userspace timing, and batch-drains queued ICMP replies to prevent one-cycle RTT inflation. Round-trip times are more accurate, especially under load.

### SSH and Networking

- tssh connection failures now show the actual server error (exec format error, Go panics, version mismatches) instead of the opaque "No valid JSON found in tsshd output" message.

### VPN

- Fixed the VPN widget connect button sometimes failing to actually connect or failing to reflect the current VPN state after a cold launch.

### Visual Polish

- Added effects across the app for smoother state transitions: bounce and replace animations on copy buttons, breathing and pulsing on reconnection overlays, rotation on VPN connecting indicators, and wiggle effects on key availability badges.

## 1.0.2-39 - March 2, 2026

### Keyboard and Input

- **Option Key Fix:** Fixed the Option key tap triggering a word-delete in the terminal, a regression in build 38. Pressing and releasing Option alone no longer emits any character. Standalone modifier key events (Alt, Shift, Control) are no longer forwarded to the terminal engine; only Command is forwarded for Cmd+hover link detection.
- **Force ASCII Keyboard:** New toggle in Settings > Locale switches the software keyboard to ASCII-only mode, preventing CJK input methods from substituting pipe | and others with IME characters. Default is off.

### Context Menus

- **Copy Link:** Right-click and edit menu context menus now include a "Copy Link" action alongside "Open Link" when the cursor is over a URL.
- Fixed right-click on a URL not showing the "Open Link" action. Link detection was being silently deduplicated when the cursor was already over the URL from normal hover tracking.

### Terminal

- Fixed the shell prompt appearing glued to the previous command after restoring a tssh session that was backgrounded while a TUI app was on the alternate screen. The primary screen dump now includes the cursor position so the trailing blank line is preserved on restore.

### Localization

- **Norwegian Bokmål:** Added Norwegian Bokmål (nb) as the 25th supported language.

### VPN

- Fixed VPN disconnect not sending the exit signal to the server. The tsshd client is now closed before the network stack tears down, ensuring the server receives clean shutdown notification instead of holding stale sessions until timeout.
- Moved the "Disconnect VPN" button to immediately below the status section in VPN settings for easier access.
- VPN event history now shows most recent events first.

## 1.0.2-38 - March 1, 2026

### Terminal

- **Cursor Effect:** New "Neon" cursor effect shader adds a glowing outline around the cursor. Enable it in Settings > Cursor.
- **Scrollback Preservation:** Scrollback history is now preserved when a TUI app (vim, helix, tmux) is running on the alternate screen and iOS evicts the app in the background. Previously reconnecting would corrupt the primary scrollback because TUI output arrived before the alternate screen switch.
- **Upstream Rebase:** Merged upstream Ghostty commits. Includes the new URL regex rewrite, unsafe byte stripping in paste, new shader uniforms, and key tables restructuring.

### SSH and Networking

- **tmux via Exec Request:** tmux auto-start on tssh sessions now uses a proper SSH exec request instead of typing the command into the login shell. This eliminates the brief login shell flash.

### Keyboard and Input

- **Action Buttons:** The keyboard toolbar drawer now includes four action buttons: Full Screen, Tab Bar Toggle, New Connection, and App Settings. Existing users get the buttons automatically via layout migration.

### Live Activity

- Polished the Live Activity lock screen layout: centered title, improved timer alignment, and fixed the activity reposting when the user dismisses it.
- Fixed duplicate Live Activities appearing on the lock screen after an app relaunch. Orphaned activities from previous launches (app kill, crash, system eviction) are now cleaned up on startup.

### iOS Local Shell

- Fixed Ctrl-C not interrupting non-interactive iOS shell commands (tail -f).
- Fixed SSH password prompts appearing on the same line as the previous command output instead of on a new line.

### Bug Fixes

- Fixed URL detection regex greedily swallowing URLs that follow file paths. For example, "root/shell https://rootshell.com" previously treated the entire string as a single file path instead of detecting the URL separately.
- Fixed Cmd+hover link highlighting requiring mouse movement on iPad and macOS. Links now highlight immediately when Cmd is pressed while the pointer is already over a URL.
- Fixed Cmd+hover link detection not working inside mouse-tracking apps like tmux. Since the xterm mouse protocol doesn't encode Cmd, link detection now bypasses the mouse-capture gate when Cmd is held.
- Fixed kitty icat pixel size detection on macOS local shell. The terminal window size ioctl now preserves pixel dimensions so kitty graphics protocol images render at the correct size.
- Fixed orphan scrollback history files never being cleaned up when their associated terminal session was deleted.

## 1.0.2-37 - February 27, 2026

### Terminal

- **Clickable Hyperlinks:** URLs in terminal output are now interactive. Cmd+click opens links in Safari (iPad with trackpad / macOS), right-click or two-finger tap shows "Open Link" in the context menu, and the iOS edit menu adds an "Open Link" option when over a link.
- **Text Selection Appearance:** New setting in Settings > Window to choose how selected text looks: the default rootshell style, your theme's native selection colors, inverted colors, or fully custom foreground/background colors.

### Security

- **Scrollback Encryption:** Persisted scrollback history is now encrypted at rest with AES-256-GCM using a device-only Keychain key. Existing plaintext scrollback files are migrated transparently on restore.

### SSH and Networking

- **Locale Override:** New setting in Settings > Terminal to control the locale sent to remote servers. Choose Automatic (system locale), Don't Send (suppress locale entirely), or Custom. Fixes repeated setlocale warnings for users whose OS region produces unavailable locale combinations like en_IL.UTF-8.
- Fixed a crash in local SSH port forwards when many connections arrive simultaneously (e.g. a browser opening multiple sockets).
- Fixed KCP rekey failures after backgrounding the app by suppressing the rekey timer during iOS process suspension.
- Fixed the cursor permanently flipping to underline after resuming a tssh session running Helix, or other focus-reporting apps.

### VPN

- **Home Screen Widget:** New small and medium Home Screen widgets to connect and disconnect your VPN without opening the app. Long-press to choose a VPN profile. Shows profile name, host, status with gradient background and status orb, and a connect/disconnect button.
- **Live Activity:** Lock Screen and Dynamic Island now show active sessions and real-time VPN stats (bytes in/out, uptime, connection count). A session filter in Settings lets you choose All Sessions, Diary Sessions, or VPN Only.

### Keyboard and Input

- **Restore Custom Keys:** Custom keys removed from the toolbar layout now appear in a "Hidden Keys" section in toolbar settings with a restore button, instead of being permanently deleted.

### Bug Fixes

- Fixed blank screen when the last session exits on iOS. The connection sheet is now shown instead of destroying the only window.

## 1.0.2-36 - February 24, 2026

### SSH

- **Post-Quantum Host Keys:** Added ML-DSA-65 and ML-DSA-87 post-quantum host key signature algorithms built on Apple CryptoKit (macOS 26+, iPadOS 26+, visionOS 26+). Combined with the ML-KEM hybrid key exchange added in build 34, Rootshell now has end-to-end post-quantum protection: ML-KEM secures the key exchange against harvest-now-decrypt-later attacks, while ML-DSA authenticates the server's identity against forgery by a future quantum computer. Currently works with servers running OQS OpenSSH; Rootshell will be ready out of the box when upstream OpenSSH adds ML-DSA support.

### Keyboard and Input

- **Paste Button:** The toolbar's extra keys drawer now includes a clipboard paste button, so you can paste without a keyboard shortcut or gesture based context menu. Existing users get the button automatically via layout migration.
- **Toolbar Shift Modifier:** When Shift is active on the virtual keyboard toolbar, characters typed on the regular iOS keyboard are now shifted (a->A, 1->!, ;->:, etc.). Previously only the toolbar's own keys respected the Shift state.

### iOS Local Shell

- **Windows ping Hint:** Typing "ping -n \<count>" (Windows syntax) now suggests the correct flag "-c" instead of "too many arguments" error.

### Themes

- **System Appearance Tracking:** Day/night automatic theme switching now follows the system light/dark mode instead of using sunrise/sunset calculations and device location. This is more reliable and lets you control the switch from Control Center, Settings, or Shortcuts automations.

### Fonts

- **Smaller App Size:** Replaced Nerd Font Mono patched fonts with unpatched originals, reducing bundled font size from 41 MB to 1.6 MB. Nerd Font symbols are already provided automatically by Ghostty's built-in fallback font. Unused weight variants were also removed. Existing users are automatically migrated to the new font family names.
- **Configurable Font Features:** Font features (stylistic sets, slashed zero, etc.) are now user-configurable in Settings > Font Features, replacing the previously hardcoded ss01-ss08 and zero features. Enable or disable individual OpenType features per font.
- **Font Preview:** The font list preview text now reflects your enabled font features so you can see the effect.

### Localization

- **Hungarian:** Added Hungarian (hu) as the 24th supported language.
- Extended translation coverage across all 24 languages with newly localized strings for font features, toolbar key names, iCloud sync status, and other UI elements.

### Bug Fixes

- Fixed scrollback restore showing corrupted colors by resolving palette-indexed colors to RGB in the scrollback dump.
- Fixed toolbar modifier keys (Ctrl, Alt, etc.) not applying to custom drawer keys.
- Fixed cursor joystick icon in the toolbar keys editor not matching the actual toolbar button icon.

## 1.0.2-35 - February 23, 2026

### Localization

- **23 Languages:** The app is now localized into Arabic, Brazilian Portuguese, Catalan, Czech, Danish, Dutch, Portuguese, Finnish, French, German, Hebrew, Italian, Japanese, Korean, Polish, Romanian, Simplified Chinese, Slovenian, Spanish, Swedish, Traditional Chinese, Ukrainian, and Vietnamese.

### Keyboard and Input

- **Drawer Toggle Hiding:** The drawer toggle button in the keyboard toolbar can now actually be hidden via Settings > Toolbar Keys.

### macOS/iPad Menu

- **Menu Reorganization:** View-related items (font size, tab bar, background effect, theme picker, transparency) moved from the Terminal menu to the View menu per macOS Human Interface Guidelines. The Terminal menu now contains splits, Focus Split, scroll, and compose actions.

### Bug Fixes

- **Local Shell CWD Persistence (iOS):** The local shell now restores your working directory when a session reconnects or the app relaunches instead of always resetting to the Documents folder.
- **Background Notifications:** Terminal notifications (OSC 9/777) now fire when the app is in the background. Previously they were suppressed whenever the terminal was focused, even if you had switched to another app, so long-running commands could not alert you. When the app is in the foreground, notifications only appear for non-focused tabs. On iPhone/iPad, Location Diary must be active for background notifications to fire.

## 1.0.2-34 - February 22, 2026

### SSH

- **Post-Quantum Key Exchange:** SSH connections now negotiate mlkem768x25519-sha256 (ML-KEM + Curve25519 hybrid) as the highest-priority key exchange algorithm. This protects session traffic against future quantum attacks while maintaining classical security. Requires iOS/iPadOS 26+, macOS 26+, or visionOS 26+ because Apple CryptoKit only exposes ML-KEM on those versions; older OS versions fall back to curve25519-sha256 and diffie-hellman-group14. Requires OpenSSH 9.9+ or equivalent on the server.

### Keyboard and Input

- **Ctrl+Key via Toolbar Now (Hopefully) Uses Proper Key Encoding:** The virtual keyboard toolbar's Ctrl+key combinations now route through Ghostty's full key encoding pipeline instead of manually encoding legacy control characters. This fixes keys like Ctrl+; and Ctrl+Shift+- that have no legacy mapping, and enables proper CSI u / kitty protocol encoding for all modified keys.
- **Custom Key Editor UX:** Sequence mode steps are now tappable to edit in-place instead of requiring delete-and-recreate. Quick-add buttons for Return, Tab, Escape, and Space let you build sequences without opening the full Key Combo picker.
- **Custom Toolbar Key ESC Fix:** Fixed custom toolbar keys whose sequences end with ESC (0x1B) being misinterpreted as Alt+key combinations in editors like Helix. Steps are now sent individually with a short delay after any ESC byte.
- **Keyboard Dismiss in Settings:** Scrolling now interactively dismisses the keyboard in all settings views with text fields. Number pad fields in Roam settings also gain a Done button.

### Terminal

- **Bundled Commands - bat and gix:** Two new iOS local shell command-line tools are bundled with the app. [bat](https://github.com/sharkdp/bat) provides syntax-highlighted file viewing with automatic paging (try `bat foo.swift`). [gix](https://github.com/GitoxideLabs/gitoxide) is a fast Git implementation written in Rust for repository operations.
- **Vim 9.2 Upgrade:** Upgraded the bundled Vim from 9.1 to 9.2.0038 (471 upstream patches). Now built with the "huge" feature set, enabling termguicolors (24-bit color in themes like catppuccin), langmap, vartabs, and profiling. Includes updated syntax highlighting, indent rules, filetype detection, netrw/matchit plugins, and new documentation.
- **curl Upgrade with HTTP/2:** Upgraded bundled curl to 8.19.0 with HTTP/2 support via nghttp2 and OpenSSL. HTTP/2 enables multiplexed transfers and header compression for faster downloads.
- **Scrollback Restore Timing:** Fixed scrollback restore on remote sessions (SSH, Kubernetes, Console, Mosh, TSSH) sometimes capturing connection spinner animation artifacts. The restore now waits until the session reaches the running state.

### Split Panes

- **Split Focus Border Customization:** New settings under Window > Split Panes to choose the focus border style (none/subtle/standard/bold) and color (accent/gray/custom).

### macOS

- **Split Pane Focus Border:** Maybe fixed the blue pane-focus border incorrectly appearing on single-pane layouts due to a race condition between window key status changes and layout computation. Also suppresses the system UITextInput focus ring on macOS. Could never reproduce this myself, so fingers crossed.

### Bug Fixes

- **Roam Port Range Defaults:** Clearing the port range fields in Settings > Roam now correctly restores the defaults (61000-61999) instead of silently retaining the last entered value.
