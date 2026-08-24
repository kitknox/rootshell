//
//  TerminalView.swift
//  rootshell
//
//  Metal-based terminal view for iOS with Swift-managed PTY
//

import UIKit
import SwiftUI
import Combine
import os
import GhosttyKit
import UserNotifications
#if targetEnvironment(macCatalyst)
import AppKit
#endif

extension Ghostty {

    /// Controls whether the physical Option key acts as terminal Alt/Meta (sends ESC prefix)
    /// or as a character-producing modifier (sends OS-translated character, e.g., @ for ⌥L on German).
    /// Matches Ghostty's `macos-option-as-alt` setting.
    enum OptionKeyAsAlt: String, CaseIterable, Sendable {
        case off = "off"        // Option produces OS characters (default, correct for international layouts)
        case on = "on"          // Both Option keys act as terminal Alt (ESC prefix)
        case left = "left"      // Only left Option acts as Alt
        case right = "right"    // Only right Option acts as Alt

        var displayName: String {
            switch self {
            case .off: return "Off"
            case .on: return "Both"
            case .left: return "Left Only"
            case .right: return "Right Only"
            }
        }

        var description: String {
            switch self {
            case .off: return "Option key produces characters (e.g., @ { } on international layouts)"
            case .on: return "Both Option keys send ESC prefix (terminal Alt/Meta)"
            case .left: return "Left Option sends ESC prefix, Right Option produces characters"
            case .right: return "Right Option sends ESC prefix, Left Option produces characters"
            }
        }
    }

    /// Tracks which physical Option key is currently held down.
    enum HeldOptionSide {
        case none, left, right, both
    }

    /// Tracks which physical Control key is currently held down.
    enum HeldControlSide {
        case none, left, right, both
    }

    /// The UIView implementation for a terminal surface on iOS
    class TerminalView: SplitPaneView, ObservableObject, UITextInput {

        struct SelectionCell: Equatable {
            let col: Int
            let row: Int

            var tuple: (col: Int, row: Int) {
                (col: col, row: row)
            }
        }


        // MARK: - Properties

        /// Standard terminal control character mappings for Ctrl+key.
        /// Based on xterm/VT tradition: Ctrl sends char & 0x1F for @-_ range,
        /// digits map via their shifted equivalents on US keyboard layout.
        static let controlCharacterMap: [Character: UInt8] = [
            " ": 0,    // NUL
            "@": 0,    // NUL
            "2": 0,    // NUL (Shift+2 = @)
            "[": 27,   // ESC
            "\\": 28,  // FS
            "]": 29,   // GS
            "^": 30,   // RS
            "6": 30,   // RS  (Shift+6 = ^)
            "_": 31,   // US
            "-": 31,   // US  (Shift+- = _)
            "/": 31,   // US
            "?": 127,  // DEL
            "8": 127,  // DEL
            "`": 0,    // NUL
        ]

        /// US keyboard layout shift mappings for digits and symbols.
        /// Letters are handled separately via `.uppercased()`.
        static let usShiftMap: [Character: Character] = [
            "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
            "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
            "-": "_", "=": "+",
            "[": "{", "]": "}",
            "\\": "|",
            ";": ":", "'": "\"",
            ",": "<", ".": ">", "/": "?",
            "`": "~",
        ]

        /// Returns the shifted version of a character using US keyboard layout.
        static func shiftedCharacter(_ char: Character) -> Character {
            if char.isLetter { return char.uppercased().first ?? char }
            if let shifted = usShiftMap[char] { return shifted }
            return char
        }

        /// Maps characters to HID usages for routing virtual keyboard
        /// key presses through Ghostty's key encoding pipeline.
        /// This enables proper CSI u / kitty protocol encoding for modified keys.
        static let characterHIDUsageMap: [Character: UIKeyboardHIDUsage] = {
            var map: [Character: UIKeyboardHIDUsage] = [
                "-": .keyboardHyphen,
                ";": .keyboardSemicolon,
                "/": .keyboardSlash,
                "`": .keyboardGraveAccentAndTilde,
                "[": .keyboardOpenBracket,
                "]": .keyboardCloseBracket,
                "\\": .keyboardBackslash,
                "=": .keyboardEqualSign,
                "'": .keyboardQuote,
                ",": .keyboardComma,
                ".": .keyboardPeriod,
                " ": .keyboardSpacebar,
            ]
            // a-z
            let letters: [(Character, UIKeyboardHIDUsage)] = [
                ("a", .keyboardA), ("b", .keyboardB), ("c", .keyboardC),
                ("d", .keyboardD), ("e", .keyboardE), ("f", .keyboardF),
                ("g", .keyboardG), ("h", .keyboardH), ("i", .keyboardI),
                ("j", .keyboardJ), ("k", .keyboardK), ("l", .keyboardL),
                ("m", .keyboardM), ("n", .keyboardN), ("o", .keyboardO),
                ("p", .keyboardP), ("q", .keyboardQ), ("r", .keyboardR),
                ("s", .keyboardS), ("t", .keyboardT), ("u", .keyboardU),
                ("v", .keyboardV), ("w", .keyboardW), ("x", .keyboardX),
                ("y", .keyboardY), ("z", .keyboardZ),
            ]
            for (ch, key) in letters { map[ch] = key }
            // 0-9
            let digits: [UIKeyboardHIDUsage] = [
                .keyboard0, .keyboard1, .keyboard2, .keyboard3, .keyboard4,
                .keyboard5, .keyboard6, .keyboard7, .keyboard8, .keyboard9,
            ]
            for (i, key) in digits.enumerated() {
                map[Character("\(i)")] = key
            }
            return map
        }()

        // MARK: Identity

        // `uuid` and `containingTabID` are inherited from SplitPaneView.

        /// Window ID this terminal belongs to
        var windowId: String

        /// Whether the containing tab is currently visible (selected).
        /// Used to set initial occlusion state when surface is created.
        var isTabVisible: Bool = true

        /// App-level presentations, such as settings and sheets, occlude
        /// selection handle overlays before UIKit has attached a modal VC.
        var selectionUIExternallyOccluded: Bool = false

        /// Set while this tab is sliding during an app-tab swipe. The selection
        /// handles are window-anchored and can't follow the SwiftUI `.offset(x:)`
        /// slide, so they're suppressed for the duration and recreated at the
        /// settled position when the slide lands (avoids a wrong-place flash).
        var selectionUISwipeSuppressed: Bool = false

        /// Notification identifiers for desktop notifications (for cleanup on focus)
        private var notificationIdentifiers: Set<String> = []

        /// Cancellables for Combine subscriptions
        private var cancellables = Set<AnyCancellable>()
        
        // Window focus observers (multi-window cursor syncing)
        private weak var observedWindow: UIWindow?
        private weak var observedScene: UIScene?
        private var windowFocusObservers: [NSObjectProtocol] = []
        private var windowActiveOverride: Bool?

        /// True while a keyboard-owning overlay (the vertical tab sidebar, the
        /// connection sidebar, any sheet — see `MainView.isAnySheetPresented`)
        /// is up in this window. A single per-window gate, set synchronously by
        /// MainView through `setOverlayOwnsKeyboard`, that makes this terminal
        /// physically refuse first responder so the overlay's own field owns
        /// the keyboard without contention. This is what makes focus
        /// deterministic across rapid sidebar toggles: every async first-
        /// responder claimer funnels through `becomeFirstResponder()`, which
        /// honors this flag at fire time, so stale retries from a prior toggle
        /// cycle can never land first responder in the wrong place.
        private var overlayOwnsKeyboard: Bool = false

        /// Pre-resign snapshot of `reservedKeyboardToolbarHeightAtBottom`,
        /// held while an overlay owns the keyboard. The live computation
        /// requires first responder, so the overlay-driven resign alone would
        /// zero the toolbar reserve and bounce the terminal's bottom padding
        /// even when no software keyboard is involved (hardware keyboard /
        /// toolbar-only mode). Cleared when first responder returns or the
        /// post-overlay reconcile resolves without us.
        private var overlayLatchedToolbarReserve: CGFloat = 0

        // MARK: Published State

        /// The current title of the surface
        @Published var title: String = "ghostty" {
            didSet { refreshPanePresentationTitle() }
        }

        /// Title set by the user via the context menu (overrides session-provided title)
        var userOverrideTitle: String? {
            didSet { refreshPanePresentationTitle() }
        }

        /// Title provided by the terminal session (from escape sequences)
        var sessionProvidedTitle: String?

        /// Most recent working directory the terminal has reported. Cached in a
        /// non-observed property so we can keep it up to date while the resume
        /// gate is up without triggering SwiftUI scene updates (see
        /// `Ghostty.isAppBackgroundedAtomic`). On foreground return,
        /// `replayCachedSessionStateOnForeground()` pushes this into the
        /// `@Published pwd` so the UI catches up.
        var sessionProvidedPwd: String?

        /// The current working directory
        @Published var pwd: String? = nil

        /// The cell size of this surface
        @Published var cellSize: CGSize = .zero

        /// Health state of the surface
        @Published var healthy: Bool = true

        /// Any error while initializing the surface
        @Published var error: Error? = nil

        /// Search state for scrollback search
        @Published var searchState: Ghostty.SearchState? = nil {
            didSet {
                #if !targetEnvironment(macCatalyst)
                syncSelectionHandlesForSurfaceActivity()
                #endif
            }
        }

        /// Whether mouse capture mode is currently active (tmux, vim mouse mode)
        /// Used to hide scroll bars since they cannot be rendered correctly in capture mode
        @Published var isMouseCaptured: Bool = false {
            didSet {
                updateOutputCoalescingState()
                // When capture ends, force-reset the tmux scroll observer so
                // it doesn't keep `isTracking == true` (and thus block
                // Ghostty's native handleScrollbar values from updating the
                // indicator) while it sits in `.fading`.
                if oldValue && !isMouseCaptured {
                    multiplexerScrollObserver?.reset()
                }
            }
        }

        /// User-toggled override that force-disables mouse reporting for this terminal.
        /// When active, native text selection and scrolling work even when the
        /// terminal program has mouse reporting enabled (tmux, vim, etc.).
        /// This uses ghostty's built-in `toggle_mouse_reporting` action which sets
        /// `config.mouse_reporting = false`, making `ghostty_surface_mouse_captured()`
        /// return false and suppressing mouse protocol reports at the ghostty level.
        var mouseCaptureOverrideActive: Bool = false

        /// Progress report state (for OSC 9;4 progress indicators)
        @Published var progressReport: Ghostty.Action.ProgressReport? = nil {
            didSet {
                // Cancel any existing timer
                progressReportTimer?.invalidate()
                progressReportTimer = nil

                // If we have a new progress report, start a timer to remove it after 15 seconds
                if progressReport != nil {
                    progressReportTimer = Timer.scheduledTimer(
                        withTimeInterval: 15.0,
                        repeats: false
                    ) { [weak self] _ in
                        // Timer fires on the run loop that scheduled it (main).
                        MainActor.assumeIsolated {
                            self?.progressReport = nil
                            self?.progressReportTimer = nil
                        }
                    }
                }

                // Keep sidebar activity in lockstep for every transition,
                // including explicit remove and the stale timer's nil.
                AgentAttentionCenter.shared.noteProgressChanged(terminal: self)
            }
        }

        /// Surface size information
        var surfaceSize: ghostty_surface_size_s? {
            guard let surface = self.surface else { return nil }
            return ghostty_surface_size(surface)
        }
        
        // MARK: Session State

        var surface: ghostty_surface_t?
        var ghosttyApp: Ghostty.App?

        /// When set, this view renders a tmux control mode PANE rather than
        /// running its own session. Its surface is created via
        /// `ghostty_surface_new_tmux_pane` bound to the viewer-owner's pane
        /// terminal (single-terminal model): it has no PTY/pipe and no
        /// `TerminalSession`. Keyboard/text input flows to the tmux backend,
        /// which relays it to the parent as `send-keys`. Must be assigned
        /// before the view is added to a window (before `createSurface`).
        struct TmuxPaneBinding {
            let parentSurface: ghostty_surface_t
            /// Stable identity of the gateway terminal that owns `parentSurface`
            /// (the gateway view's `uuid`, == its `TmuxController.ownerTerminalUUID`),
            /// captured at bind time. `parentSurface` is a raw pointer whose ADDRESS
            /// can be reused by an unrelated surface after the gateway is freed, so a
            /// pointer-value lookup alone can resolve the wrong terminal (ABA). Code
            /// that resolves the gateway from `parentSurface` must confirm the
            /// resolved view's `uuid` equals this before trusting it.
            /// (id=tmux-stale-parent-surface)
            let parentUUID: UUID
            let windowId: Int
            let paneId: Int
            let viewerTerminal: UnsafeMutableRawPointer?
            let viewerPane: UnsafeMutableRawPointer?
        }
        var tmuxPaneBinding: TmuxPaneBinding? {
            didSet {
                if tmuxPaneBinding == nil {
                    tmuxReportedPaneTitle = nil
                    tmuxReportedCurrentCommand = nil
                }
                refreshPanePresentationTitle()
            }
        }
        var isTmuxPane: Bool { tmuxPaneBinding != nil }

        /// Per-pane identity queried from tmux. A projected tmux surface has a
        /// synthetic Ghostty title such as "Pane%196", so its ordinary OSC
        /// title publisher cannot be used as the pane label.
        var tmuxReportedPaneTitle: String? {
            didSet { refreshPanePresentationTitle() }
        }
        var tmuxReportedCurrentCommand: String? {
            didSet { refreshPanePresentationTitle() }
        }

        /// A multiplexer the app does NOT drive (raw `tmux`, `zellij`) is
        /// rendering into this surface, so one surface holds many logical
        /// windows. Agent detection reads a pane's screen assuming it is a
        /// single agent context; that assumption is false here, and every
        /// protection built on it inverts (the multiplexer owns the alternate
        /// screen for its whole attach, so presence never lapses; its status
        /// bar keeps activity permanently fresh, so completions never settle).
        /// Set by construction wherever the app knows it started or attached
        /// one, so nothing has to be inferred from the screen.
        /// (id=agent-attention-raw-mux)
        struct RawMultiplexerBinding: Equatable {
            let type: MultiplexerType
            /// Known when the app issued the attach; nil when the binding came
            /// from a corroborating screen signal.
            let sessionName: String?
            /// True once the multiplexer has actually taken the alternate
            /// screen. The binding is recorded at session-ready, before the
            /// remote command has run, so the surface is legitimately on the
            /// primary screen for a moment — releasing on that would undo the
            /// binding instantly. Only a primary frame AFTER ownership means
            /// the multiplexer detached or exited.
            var hasOwnedAltScreen: Bool = false
        }
        var rawMultiplexer: RawMultiplexerBinding?
        nonisolated(unsafe) var tmuxDetachInProgressAtomic: Bool = false

        var isTmuxDetachInProgress: Bool {
            if tmuxDetachInProgressAtomic { return true }
            if tmuxController?.isDetaching == true { return true }
            guard let binding = tmuxPaneBinding,
                  let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface)
            else { return false }
            return controller.isDetaching
        }

        /// Set by the split-tree container (`SplitTreeHostingView.attach`) once it
        /// has positioned this pane at its real frame. Until then, `sizeDidChange`
        /// ignores size changes for a tmux pane: the view is born at an 800x600
        /// placeholder frame and `didMoveToWindow` fires `sizeDidChange` at that
        /// placeholder BEFORE the container assigns the real frame, which would
        /// send a tiny (~72x26) `resize-pane` to the tmux server and reflow the
        /// pane's scrollback narrow (a lossy wrap that survives the snap-back to
        /// full size). ROOTSHELL-TMUX (id=tmux-pane-defer-size-until-laid-out)
        var tmuxPaneContainerLaidOut: Bool = false

        /// Set by `TmuxController.prune` just before this pane view is torn
        /// down (its tmux pane no longer exists). A dying pane must never drive
        /// the server's window size again: an in-flight async `set_size` /
        /// `updatePTYSize` from teardown would otherwise push its transient
        /// (tiny) grid as the WINDOW size via `pushWindowSize` or the core's
        /// sole-pane `resize-pane` -> `refresh-client -C` rewrite, shrinking
        /// the tmux window for every attached client.
        /// ROOTSHELL-TMUX (id=tmux-pane-retired-no-size)
        var tmuxPaneRetired: Bool = false

        /// When this view's surface enters tmux control mode (it becomes the
        /// viewer-owner), this holds the controller that maps the tmux
        /// topology onto native tabs/splits. Created lazily on the first
        /// reconcile. nil for pane views and non-tmux sessions.
        var tmuxController: TmuxController?

        /// Attached-session identity (GHOSTTY_ACTION_TMUX_SESSION_CHANGED)
        /// that arrived BEFORE the first reconcile created `tmuxController`
        /// (startup emits it alongside the first command, well before the
        /// topology). Flushed into the controller at creation
        /// (applyTmuxReconcile). ROOTSHELL-TMUX (id=tmux-session-info-stash)
        var pendingTmuxSessionInfo: (id: Int, name: String)?

        /// Pipe-writer overflow bytes reported while this surface shows
        /// gateway evidence (core control channel hooked, or a gateway
        /// restore/resume pending) but `tmuxController` is still nil — the
        /// drain-to-empty report can beat the first reconcile on a large -CC
        /// attach. Flushed into `resetForDiscard` at controller creation so
        /// the gapped control stream still heals; cleared on surface
        /// teardown. Never stashed for non-tmux surfaces.
        /// ROOTSHELL-TMUX (id=tmux-overflow-stash)
        var pendingTmuxOverflowBytes: Int = 0

        // PTY and session (SSH, Kubernetes, Console, EC2, or local shell).
        // Owned by `sessionController`; these are thin forwarders so the many
        // existing `self.session` / `self.pty` references across the view's
        // extensions keep compiling unchanged while the session domain is
        // peeled out incrementally. See `TerminalSessionController`.
        // Assigned in `init` (needs `self` as host), so implicitly unwrapped.
        private(set) var sessionController: TerminalSessionController!
        private(set) var surfaceController: TerminalSurfaceController!
        private(set) var inputController: TerminalInputController!
        private(set) var shaderAnimationController: TerminalShaderAnimationController!
        private(set) var keyboardAccessoryController: TerminalKeyboardAccessoryController!
        var pty: TerminalPTY? {
            get { sessionController.pty }
            set { sessionController.pty = newValue }
        }
        var session: TerminalSession? {
            get { sessionController.session }
            set { sessionController.session = newValue }
        }
        var outputMonitorTask: Task<Void, Never>?
        var activeTransferTicketID: UUID?
        var transferAttachTask: Task<Void, Never>?

        /// One-shot: a shared file this tab should open in the editor once
        /// its local shell starts (see FileOpenCoordinator). Consumed (nilled)
        /// by TerminalSessionController when the session is built, so session
        /// restores/reconnects never re-launch the editor.
        var pendingFileToOpen: String?

        // MARK: UI State

        // Keyboard toolbar
        var keyboardAccessory: KeyboardAccessoryView? {
            get { keyboardAccessoryController?.keyboardAccessory }
            set { keyboardAccessoryController?.keyboardAccessory = newValue }
        }
        #if os(visionOS)
        weak var externalToolbar: KeyboardToolbarView? {
            get { keyboardAccessoryController?.externalToolbar }
            set { keyboardAccessoryController?.externalToolbar = newValue }
        }
        #endif
        var shouldShowKeyboardToolbar: Bool {
            get { keyboardAccessoryController?.shouldShowKeyboardToolbar ?? false }
            set { keyboardAccessoryController?.shouldShowKeyboardToolbar = newValue }
        }
        var activeKeyboardModifiers: KeyModifiers {
            get { keyboardAccessoryController?.activeKeyboardModifiers ?? [] }
            set { keyboardAccessoryController?.activeKeyboardModifiers = newValue }
        }

        var activeToolbarView: KeyboardToolbarView? {
            keyboardAccessoryController?.activeToolbarView
        }
        var reservesKeyboardToolbarAtBottom: Bool {
            keyboardAccessoryController?.reservesKeyboardToolbarAtBottom ?? false
        }
        override var reservedKeyboardToolbarHeightAtBottom: CGFloat {
            // Hold the pre-resign reserve while an overlay owns the keyboard so
            // bottom padding doesn't collapse and re-grow across the round trip.
            if !isFirstResponder, overlayLatchedToolbarReserve > 0 {
                return overlayLatchedToolbarReserve
            }
            return keyboardAccessoryController?.reservedKeyboardToolbarHeightAtBottom ?? 0
        }
        override var defersBottomSystemGestureForKeyboardToolbar: Bool {
            keyboardAccessoryController?.defersBottomSystemGesture ?? false
        }
        var showComposeOverlay: Bool = false {
            didSet {
                #if !targetEnvironment(macCatalyst)
                syncSelectionHandlesForSurfaceActivity()
                #endif
            }
        }
        var composeText: String = ""
        weak var activeComposeTextView: UITextView?
        var keyboardManuallyDismissed: Bool {
            get { keyboardAccessoryController?.keyboardManuallyDismissed ?? false }
            set { keyboardAccessoryController?.keyboardManuallyDismissed = newValue }
        }
        var toolbarOnlyMode: Bool {
            get { keyboardAccessoryController?.toolbarOnlyMode ?? false }
            set { keyboardAccessoryController?.toolbarOnlyMode = newValue }
        }
        // Set by long-pressing the dismiss chevron: keyboard stays hidden across
        // terminal taps and focus changes until the chevron is tapped again.
        var keyboardPinnedHidden: Bool {
            get { keyboardAccessoryController?.keyboardPinnedHidden ?? false }
            set { keyboardAccessoryController?.keyboardPinnedHidden = newValue }
        }
        var keyboardToolbarCollapsed: Bool {
            get { keyboardAccessoryController?.keyboardToolbarCollapsed ?? false }
            set { keyboardAccessoryController?.keyboardToolbarCollapsed = newValue }
        }
        var dismissTapStartPoint: CGPoint? {
            get { keyboardAccessoryController?.dismissTapStartPoint }
            set { keyboardAccessoryController?.dismissTapStartPoint = newValue }
        }
        /// Whether AI Agent overlay is visible for this terminal's tab (suppresses keyboard toolbar)
        var aiAgentOverlayActive: Bool = false {
            didSet {
                keyboardAccessoryController?.setAIAgentOverlayActive(aiAgentOverlayActive)
            }
        }
        /// Whether the theme picker overlay is visible over this terminal's tab.
        var themePickerOverlayActive: Bool = false

        // MARK: Input Mode Indicator
        #if !targetEnvironment(macCatalyst)
        private var inputModeOverlayHost: UIHostingController<InputModeOverlayView>?
        private var inputModeDismissTask: Task<Void, Never>?
        private var inputModeObserver: NSObjectProtocol?
        private var lastInputModePrimaryLanguage: String?
        var hasHardwareInputSourceSwitchAvailable = false
        /// Suppress the indicator until the user actively switches input methods.
        /// Prevents showing on first responder gain, tab creation, or app launch.
        private var inputModeChangeCount: Int = 0

        // MARK: Mouse Capture Override Overlay
        private var mouseCaptureOverlayHost: UIHostingController<InputModeOverlayView>?
        private var mouseCaptureOverlayDismissTask: Task<Void, Never>?
        #endif

        /// Whether shader animation is suppressed because the keyboard was manually dismissed.
        /// Prevents cursor shader artifacts during keyboard transitions and while keyboard is hidden.
        var keyboardDismissedShadersSuppressed: Bool = false

        /// Timestamp of last space insertion for double-space-for-period detection
        private var lastSpaceInsertTime: Date?

        /// Last URL detected by Ghostty's mouse-over-link action (set synchronously by probe)
        var lastProbedLinkURL: String?

        /// Connection configuration for this terminal session
        var connectionConfig: ConnectionConfig {
            didSet { refreshPanePresentationTitle() }
        }

        /// The profile ID that created this terminal (nil for non-profile connections)
        var sourceProfileID: UUID?

        /// Absolute per-surface font size override set by keyboard shortcuts or
        /// pinch zoom. Nil means this terminal follows `FontManager`'s global
        /// font size and should adopt future global changes.
        var fontSizeOverride: Double?

        /// For trzsz terminals being restored from saved window state: the
        /// `lastConnectedAt` heartbeat captured by the previous run. Read
        /// once by `TrzszSession.attemptResume` to drive the "still within
        /// the server's 24h AliveTimeout" deadline; remains available so a
        /// re-serialization before the resume completes can re-emit it.
        var restoredTrzszLastConnectedAt: Date?

        /// Set on a restored gateway terminal whose saved leaf had
        /// `wasTmuxGateway == true`. When this terminal's tssh session resumes
        /// the live pty (`.running` + `wasResumed`), the app calls
        /// `ghostty_surface_tmux_resume` to re-enter tmux control mode. Kept true
        /// while resume is pending so autosave can still identify the gateway;
        /// cleared on successful reconcile or resume abort. See
        /// `maybeResumeTmuxControlMode`.
        var restoredWasTmuxGateway: Bool = false

        /// True once `ghostty_surface_tmux_resume` has been fired for this
        /// restored gateway, so the resume + watchdog are armed at most once.
        var tmuxResumeRequested: Bool = false

        /// User asked to cancel tmux restore before the resumed pty was ready.
        /// Kept separate from `restoredWasTmuxGateway`: the gateway must still
        /// enter tmux-resume handling once the surface is ready so the core can
        /// abort control mode cleanly instead of dumping raw control bytes.
        var tmuxResumeCancelRequested: Bool = false

        /// Watchdog armed when a restored gateway requests a tmux resume. If no
        /// reconcile arrives before it fires (tmux died / session expired / the
        /// reattached pty is at a bare shell), it aborts the resume and removes
        /// the still-awaiting placeholder tabs. Cancelled by the first reconcile
        /// in `applyTmuxReconcile`.
        var tmuxResumeWatchdog: Task<Void, Never>?

        /// Whether the local shell has an active long-running task (helix, vim, sftp, scp, ping)
        var hasActiveLocalTask: Bool = false

        // Callback for when SSH authentication is required (auth failure)
        var onAuthenticationRequired: (@MainActor @Sendable (SSHConfig) -> Void)?
        
        // Callback for SSH host key validation
        var onHostKeyValidationRequired: (@MainActor @Sendable (HostKeyValidationRequest, Ghostty.TerminalView) async -> HostKeyValidationResult)?

        // Callback for keyboard-interactive (RFC 4256) SSH challenges. Returns one
        // response per prompt, or nil if the user cancelled.
        var onKeyboardInteractiveChallengeRequired: (@MainActor @Sendable (KeyboardInteractiveChallenge, Ghostty.TerminalView) async -> [String]?)?

        // Callback for SSH agent approval requests
        var onAgentApprovalRequired: (@MainActor @Sendable (SSHAgentApprovalRequest) -> Void)?

        // Callback for forwarded GPG-agent PKSIGN approval requests.
        // Parallel to onAgentApprovalRequired; the GPG path doesn't
        // share its queue with the SSH path because the request
        // shapes (one carries a hash + algo + keygrip preview) and the
        // dismiss messages differ.
        var onGPGAgentApprovalRequired: (@MainActor @Sendable (GPGAgentApprovalRequest) -> Void)?

        /// Companion withdraw callback fired when the session decides
        /// a previously-surfaced GPG approval is no longer wanted
        /// (e.g. the underlying connection tore down). MainView
        /// removes the matching queued entry by id.
        var onGPGAgentApprovalWithdrawn: (@MainActor @Sendable (UUID) -> Void)?

        // Connection health for SSH sessions.
        // Mutate via `applyConnectionHealth(_:)` so writes are equality-guarded
        // and suppressed while the app is backgrounded; the cached value is
        // released to the @Published property by `replayCachedSessionStateOnForeground()`.
        @Published var connectionHealth: ConnectionHealth?

        /// Most recent connection-health value observed from the SSH session.
        /// Cached in a non-observed property so we can keep it up to date while
        /// backgrounded without firing SwiftUI invalidations (mirrors the
        /// pattern used for `sessionProvidedPwd` / `sessionProvidedTitle`).
        var sessionProvidedConnectionHealth: ConnectionHealth?

        // Attachment upload state
        var activeUploader: AttachmentUploader?

        // Multiplexer session discovery state (tmux + zellij)
        var discoveredSessions: [MultiplexerSession]?

        /// While an in-window overlay (tab exposé) is presented it takes keys
        /// here instead of stealing first responder, so the software keyboard
        /// and grid stay put. Fed from both `processKeyPress` and the dedicated
        /// UIKeyCommand handlers (arrows/Return/Tab/Escape). Return true to consume.
        var presentedOverlayKeyHandler: ((OverlayKeyEvent) -> Bool)?
        var discoveredSessionTypes: Set<MultiplexerType> = []
        var discoveredMultiplexerSwipeBindings = MultiplexerSwipeBindings()
        var hasUserTyped: Bool = false
        var sessionSelectionIndex: Int = 0
        var tmuxDiscoveryAttachMode: TmuxAutoMode = TmuxAutoMode.persistedDiscoveryAttachMode
        var sessionDiscoveryTask: Task<Void, Never>?

        // MARK: Restoration State

        /// State for session restoration after app relaunch
        enum RestorationState: Equatable {
            case none                           // Normal terminal
            case pendingReconnection            // Waiting to reconnect
            case connectingFromRestore          // Actively reconnecting
            case needsPassword(SSHConfig)       // Needs password entry before connect
            case failed(String)                 // Reconnection failed

            static func == (lhs: RestorationState, rhs: RestorationState) -> Bool {
                switch (lhs, rhs) {
                case (.none, .none):
                    return true
                case (.pendingReconnection, .pendingReconnection):
                    return true
                case (.connectingFromRestore, .connectingFromRestore):
                    return true
                case (.needsPassword(let lhsConfig), .needsPassword(let rhsConfig)):
                    return lhsConfig.host == rhsConfig.host && lhsConfig.username == rhsConfig.username
                case (.failed(let lhsMsg), .failed(let rhsMsg)):
                    return lhsMsg == rhsMsg
                default:
                    return false
                }
            }
        }

        /// Current restoration state (for restored sessions)
        @Published var restorationState: RestorationState = .none {
            didSet {
                #if !targetEnvironment(macCatalyst)
                syncSelectionHandlesForSurfaceActivity()
                #endif
            }
        }

        /// Whether the current overlay is from a live disconnection (vs state restoration)
        var isLiveDisconnectionOverlay: Bool = false

        /// Whether this terminal shows a reconnection overlay
        var showsReconnectionOverlay: Bool {
            switch restorationState {
            case .pendingReconnection, .needsPassword, .failed:
                return true
            case .none, .connectingFromRestore:
                return false
            }
        }

        var reconnectionManager: ReconnectionManager? {
            sessionController?.reconnectionManager
        }

        // Flag to gate launch command / tmux auto-connect per connection (reset on reconnect)
        var hasSentLaunchCommand: Bool = false

        // Flag to indicate this terminal should become first responder when ready
        var shouldBecomeFirstResponderWhenReady: Bool = false

        // `isLogicallyFocused` (logically focused in the split tree) is
        // inherited from SplitPaneView.

        // Slave FD for writing session output to Ghostty
        var slaveFd: Int32 {
            get { surfaceController.slaveFd }
            set { surfaceController.slaveFd = newValue }
        }

        // Response pipe read FD for reading terminal responses from Ghostty (e.g., cursor position queries)
        var responseFd: Int32 {
            get { surfaceController.responseFd }
            set { surfaceController.responseFd = newValue }
        }

        /// This gateway's owner-surface key (`Int(bitPattern:)`), used to key the
        /// tmux debug byte counters so simultaneous gateways don't share counts.
        /// 0 = none.
        nonisolated(unsafe) var tmuxGatewayOwnerKey: Int = 0

        // Serial queue for PTY master reads
        let readQueue = DispatchQueue(label: "com.rootshell.pty.read", qos: .userInitiated)

        /// Owns the terminal output byte path: buffered writes, scrollback
        /// restore gating, and mouse-capture coalescing.
        let outputPipeline = TerminalOutputPipeline()

        /// Compatibility accessors for existing persistence/tmux call sites.
        var bufferedWriter: TerminalBufferedPipeWriter { outputPipeline.bufferedWriter }
        var scrollbackRestoreOutputGate: TerminalScrollbackRestoreOutputGate { outputPipeline.scrollbackRestoreOutputGate }

        // MARK: Size Change Tracking

        static let logFrequentLayout = ProcessInfo.processInfo.environment["GHOSTTY_LOG_FREQUENT_LAYOUT"] == "1"

        /// Suppresses PTY size updates during background transitions to prevent spurious
        /// SIGWINCH signals that corrupt cursor position. Set to true when entering background,
        /// cleared when returning to foreground.
        var suppressPTYSizeUpdates: Bool {
            get { surfaceController.sizeUpdatesSuppressed }
            set { surfaceController.setSizeUpdatesSuppressed(newValue) }
        }

        /// Force next sizeDidChange to process even if dimensions appear unchanged.
        /// Used when UI layout changes (tab bar toggle, titlebar tabs, AI sidebar) may not
        /// trigger normal UIKit layout invalidation.
        func invalidateCachedSize() {
            surfaceController.invalidateCachedSize()
        }

        // MARK: Constants

        /// Common terminal escape sequences used for progress indicators and cursor control
        nonisolated enum TerminalSequence {
            // OSC 9;4 Progress Indicator States
            static let progressPulsing = "\u{1B}]9;4;3\u{07}"   // Indeterminate/pulsing
            static let progressError = "\u{1B}]9;4;2\u{07}"     // Error state (red)
            static let progressClear = "\u{1B}]9;4;0\u{07}"     // Clear progress

            // Synchronized Output (DECSYNC)
            static let syncOutputStart = "\u{1B}[?2026h"
            static let syncOutputEnd = "\u{1B}[?2026l"

            // Cursor and Line Control
            static let clearLine = "\r\u{1B}[K"                  // CR + clear to EOL

            // Arrow Key Sequences
            static let arrowUp = "\u{1B}[A"
            static let arrowDown = "\u{1B}[B"
            static let arrowRight = "\u{1B}[C"
            static let arrowLeft = "\u{1B}[D"

            // Navigation Keys
            static let home = "\u{1B}[H"
            static let end = "\u{1B}[F"
            static let pageUp = "\u{1B}[5~"
            static let pageDown = "\u{1B}[6~"
            static let deleteForward = "\u{1B}[3~"
            static let backTab = "\u{1B}[Z"

            // Control Characters
            static let escape = "\u{1B}"
            static let tab = "\t"
            static let backspace = "\u{7F}"
            static let carriageReturn = "\r"
        }

        #if targetEnvironment(macCatalyst)
        // MARK: Cursor Management (Mac Catalyst)

        /// Current cursor to display when mouse is over this view
        var currentCursor: NSCursor = .iBeam

        /// Whether the mouse is currently inside this view's bounds
        var isMouseInsideView: Bool = false

        /// Cursor registration token while hovered (Mac Catalyst only)
        var cursorToken: UUID?

        private func clearCursorRegistration() {
            if let cursorToken {
                CatalystCursorCoordinator.shared.unregister(cursorToken)
                self.cursorToken = nil
            }
            isMouseInsideView = false
        }
        #else
        /// Pointer interaction used for iPad mouse/trackpad cursor shape.
        private var pointerInteraction: UIPointerInteraction?
        #endif

        /// Dictation auto-corrections: spoken phrases → terminal characters
        private static let dictationReplacements: [(phrase: String, replacement: String)] = [
            ("shell pipe", "|"),
            ("shell tick", "`"),
            ("shell greater", ">"),
            ("shell less", "<"),
        ]

        /// Replace dictation phrases like "shell pipe" with their terminal characters.
        func applyDictationReplacements(_ text: String) -> String {
            var result = text
            for (phrase, replacement) in Self.dictationReplacements {
                while let range = result.range(of: phrase, options: .caseInsensitive) {
                    result.replaceSubrange(range, with: replacement)
                }
            }
            return result
        }

        // MARK: Input State

        // Selection state
        var isSelecting = false
        var selectionStartPoint: CGPoint?

        /// The wrapper currently hosting this terminal. `SplitTreeHostingView.attach`
        /// reuses it instead of building a second wrapper around the same terminal:
        /// each wrapper reparents the terminal and activates Auto Layout constraints
        /// against its own documentView, so two of them leave cross-hierarchy
        /// constraints behind and fight over the view on every layout pass. Declared
        /// outside the Catalyst gate below — the wrapper exists on every platform.
        weak var enclosingTerminalScrollView: Ghostty.TerminalScrollView?

        #if !targetEnvironment(macCatalyst)
        /// Pan gesture for text selection on iOS/iPadOS (movement-based, not long press)
        var selectionPanGesture: UIPanGestureRecognizer?
        /// Delayed double-tap action so a third tap can cancel it.
        var pendingDoubleTapActionTask: Task<Void, Never>?
        /// Timer for 0.15s delay to distinguish tap from selection drag
        var selectionDelayTimer: Timer?
        /// Whether we're waiting for the delay to start selection
        var isSelectionDelayPending = false
        /// Suppress single-finger selection while multi-touch is active.
        var suppressSelectionUntilTouchEnd = false
        /// Tracks whether the current selection started from a pan gesture.
        var selectionStartedFromPan = false
        /// Edit menu for programmatic presentation after text selection (transient — created on demand)
        var editMenuInteraction: UIEditMenuInteraction?
        /// Whether the current edit menu presentation should show the full context menu
        var isFullContextMenuPresentation: Bool = false
        /// Long-press gesture for text selection in scroll mode
        var selectionLongPressGesture: UILongPressGestureRecognizer?
        /// Two-finger tap gesture for context menu in scroll mode
        var twoFingerTapGesture: UITapGestureRecognizer?
        /// Swipe left gesture for next tab in scroll mode
        var tabSwipeLeftGesture: UISwipeGestureRecognizer?
        /// Swipe right gesture for previous tab in scroll mode
        var tabSwipeRightGesture: UISwipeGestureRecognizer?
        /// Direct-finger pan gesture for interactive app-tab switching.
        var appTabSwipePanGesture: UIPanGestureRecognizer?
        /// Physical direction chosen when the current app-tab pan began.
        var activeAppTabSwipeDirection: SwipeDirection?
        /// True when MainView accepted the current direct-finger app-tab pan.
        var activeAppTabSwipeAccepted: Bool = false
        /// Single-finger pan gesture for scrolling during mouse capture + scroll mode
        var captureScrollPanGesture: UIPanGestureRecognizer?
        /// Long press gesture for mouse click during mouse capture + scroll mode
        var captureLongPressGesture: UILongPressGestureRecognizer?
        /// Start point for a direct-finger short tap in mouse capture + scroll mode.
        var captureTapStartPoint: CGPoint?
        /// Touch timestamp for the capture-mode tap candidate.
        var captureTapStartTimestamp: TimeInterval = 0
        /// Whether the current capture-mode tap candidate has moved too far to be a tap.
        var captureTapInvalidated = false
        /// Whether this tap candidate only exists to stop capture-mode momentum.
        var captureTapSuppressedForMomentum = false
        /// Pinch gesture for font size adjustment in scroll mode
        var pinchZoomGesture: UIPinchGestureRecognizer?
        /// Two-finger long press to open new connection sheet
        var twoFingerLongPressGesture: UILongPressGestureRecognizer?
        /// Tracks accumulated scale for discrete font size stepping
        var pinchScaleAnchor: CGFloat = 1.0
        /// Hosting controller for the dimension overlay SwiftUI view
        var dimensionOverlayHost: UIHostingController<DimensionOverlayView>?
        /// Auto-hide timer for the dimension overlay
        var dimensionOverlayHideTask: Task<Void, Never>?
        /// Weak reference to enclosing scroll view that owns native scrollback/scrollbar state.
        weak var enclosingScrollView: UIScrollView?

        // Selection handle state
        var selectionStartHandle: SelectionHandleView?
        var selectionEndHandle: SelectionHandleView?
        var selectionHandlesVisible: Bool = false
        /// Whether the current selection was initiated via touch gesture (pan or long-press).
        /// Prevents handles from appearing for keyboard/programmatic selections on tab switch.
        var selectionWasTouchInitiated: Bool = false
        /// Coalesces deferred selection-handle visibility refreshes.
        var selectionHandleSyncPending: Bool = false
        /// Pan gesture for dragging selection handles
        var handleDragPanGesture: UIPanGestureRecognizer?
        /// Which handle is currently being dragged
        var activeHandleDrag: Ghostty.SelectionHandlePosition?
        /// Magnifier shown during touch selection and selection-handle drags.
        var selectionMagnifierView: SelectionMagnifierView?
        /// System loupe used when the iOS/iPadOS native-loupe preference is enabled.
        var selectionLoupe: SelectionLoupe?
        /// Last touch point used to position and refresh the magnifier.
        var selectionMagnifierPoint: CGPoint?
        /// Last cell position during drag (for haptic on cell boundary crossing)
        var lastDragCell: (col: Int, row: Int)?
        #if !os(visionOS)
        /// Haptic generator for cell boundary crossings during handle drag
        lazy var selectionFeedbackGenerator = UISelectionFeedbackGenerator()
        #endif
        #endif

        #if !targetEnvironment(macCatalyst)
        /// Whether touch scroll mode is enabled (single finger scrolls, long press selects)
        var isTouchScrollMode: Bool {
            UserDefaults.standard.bool(forKey: "scrollModeEnabled")
        }
        #endif

        /// Tracks whether the last context menu trigger was from a finger (vs mouse/trackpad)
        var lastContextMenuTriggerWasFinger: Bool = false
        /// Tracks whether the last context menu trigger was the Apple Pencil.
        /// A captured pencil hold is a left-drag, so the context-menu right-press
        /// branch must not fire for it.
        var lastContextMenuTriggerWasPencil: Bool = false
        /// Whether a captured Apple Pencil contact currently owns a mouse drag.
        /// Mirrors fingerDragActive so Moved/Ended/Cancelled route consistently
        /// even if the capture state flips mid-touch.
        var pencilPointerDragActive = false
        /// Last pencil contact location, for barrel-tap right-clicks on
        /// non-hover-capable hardware.
        var lastPencilLocation: CGPoint?
        var lastPencilLocationTimestamp: TimeInterval = 0
        /// The view that saw the most recent pencil contact, process-wide.
        /// UIKit delivers a barrel tap to every visible UIPencilInteraction,
        /// so without hover data only the last-touched pane may respond.
        static weak var lastPencilContactView: TerminalView?
        /// Tracks whether the last pointer event was a secondary (right) click.
        /// Set in hitTest (before gesture recognizers) so context menu delegate can distinguish.
        var lastPointerEventWasSecondaryClick: Bool = false

        // Context menu for copy/paste/split/etc
        var contextMenuInteraction: UIContextMenuInteraction?

        /// Hosting controller for the HDR brightness-boost HUD. Cross-platform
        /// (iOS/iPadOS/Catalyst/visionOS) — unlike the dimension overlay, the
        /// brightness HUD is reachable on Catalyst via the hardware keybind.
        var brightnessHUDHost: UIHostingController<BrightnessBoostHUDView>?
        /// Auto-hide timer for the brightness HUD.
        var brightnessHUDHideTask: Task<Void, Never>?

        #if !targetEnvironment(macCatalyst)
        /// Pan gesture for right-click drag on iPad (bypasses UIContextMenuInteraction touch issues)
        var rightClickPanGesture: UIPanGestureRecognizer?
        /// Delegate that excludes mouse/trackpad touches from the double-tap gesture
        var doubleTapDelegate: TouchOnlyGestureDelegate?
        #endif

        // Mouse/trackpad state
        var mousePressed = false
        var selectionMouseDragActive = false

        /// Last known mouse position for discrete scroll wheel events (Mac Catalyst)
        var lastMousePosition: CGPoint = .zero

        // Keyboard/input state is owned by TerminalInputController. These
        // accessors keep the existing input and gesture code compiling while
        // input behavior is separated from the UIView identity.
        var keyRepeatManager: KeyRepeatManager { inputController.keyRepeatManager }
        var modTapInterceptor: Ghostty.ModTapInterceptor { inputController.modTapInterceptor }
        var virtualModTapModifier: ModTapModifier? {
            get { inputController.virtualModTapModifier }
            set { inputController.virtualModTapModifier = newValue }
        }
        var userWantsCapsLock: Bool {
            get { inputController.userWantsCapsLock }
            set { inputController.userWantsCapsLock = newValue }
        }

        // Preferred hardware-keyboard input source (e.g. "zh-Hans-pinyin").
        // When non-nil, textInputMode resolves to the matching UITextInputMode so the
        // system nudges the hardware input source. Set via Command-tap mod-tap rules.
        var preferredInputLanguage: String?
        // 1pt hidden text field that absorbs first-responder during the resign/become
        // swap so the keyboard window and candidate strip stay alive.
        var inputLanguageSwapParkingField: UITextField?
        #if !targetEnvironment(macCatalyst)
        var isPreservingResponderAcrossSceneDeactivation = false
        #endif

        // Flag to prevent double-processing of OPTION+key on Catalyst
        // When pressesBegan handles OPTION+key, insertText may also be called with composed char
        var didHandleOptionKey: Bool {
            get { inputController.didHandleOptionKey }
            set { inputController.didHandleOptionKey = newValue }
        }

        // Flag to prevent double-processing of digit keys when session picker overlay is visible.
        // processKeyPress handles the digit, but insertText may also fire with the same char.
        var didHandleSessionPickerKey: Bool {
            get { inputController.didHandleSessionPickerKey }
            set { inputController.didHandleSessionPickerKey = newValue }
        }

        // Track which physical Option key is currently held (for insertText on Catalyst
        // and for left/right Option-as-Alt resolution)
        var heldOptionSide: HeldOptionSide {
            get { inputController.heldOptionSide }
            set { inputController.heldOptionSide = newValue }
        }

        // Track which physical Control key is currently held so iPad right-Option
        // AltGr reporting can be normalized without breaking real Ctrl+Option chords.
        var heldControlSide: HeldControlSide {
            get { inputController.heldControlSide }
            set { inputController.heldControlSide = newValue }
        }

        // Track modifiers used at press time for special keys routed through Ghostty,
        // so release events use the same modifiers (avoids mismatched key event pairs).
        var specialKeyPressModifiers: [UIKeyboardHIDUsage: UIKeyModifierFlags] {
            get { inputController.specialKeyPressModifiers }
            set { inputController.specialKeyPressModifiers = newValue }
        }

        // Keys whose UIKeyCommand press triggered a one-shot overlay action.
        // Repeat invocations are swallowed until the key is released.
        var keysConsumedByOverlayAction: Set<UIKeyboardHIDUsage> {
            get { inputController.keysConsumedByOverlayAction }
            set { inputController.keysConsumedByOverlayAction = newValue }
        }

        /// Currently held hardware keyboard modifiers (tracked for mouse event modifier state).
        var heldHardwareModifiers: Ghostty.Input.Mods {
            get { inputController.heldHardwareModifiers }
            set { inputController.heldHardwareModifiers = newValue }
        }

        // GCKeyboard modifier state can remain stale across app/window deactivation
        // when the system swallows modifier key-up events (for example Cmd+H on Catalyst
        // or app-switching shortcuts on iPad). After focus loss we distrust GCKeyboard-
        // only modifier recovery until we observe fresh corroborating input again.
        var isGCKeyboardModifierStateTrusted: Bool {
            get { inputController.isGCKeyboardModifierStateTrusted }
            set { inputController.isGCKeyboardModifierStateTrusted = newValue }
        }

        // UITextInput state (dictation / IME composition)
        var markedTextString: String?
        var markedTextSelectedRange: NSRange = NSRange(location: NSNotFound, length: 0)
        var markedTextStyle: [NSAttributedString.Key: Any]?
        var koreanCompositionModel = TerminalKoreanCompositionModel()
        var inputDelegate: (any UITextInputDelegate)?
        lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

        /// Tracks what iOS thinks the editable text contains, so UITextInput
        /// position/range queries return correct values during dictation.
        var documentBuffer = ""

        /// Active placeholder tokens for UIKit dictation sessions.
        /// Generic keyboard autocorrection must not rewrite previously sent
        /// terminal bytes; committed text replacement is only trusted while
        /// UIKit is actively delivering dictation results for this responder.
        var pendingDictationPlaceholderTokens = Set<String>()
        var isHandlingDictationResult = false
        var lastDictationActivityAt: Date?
        var lastBulkTextInputAt: Date?

        /// Long-press spacebar trackpad state. iOS reports drag offsets via
        /// `updateFloatingCursor(at:)`; we bucket them into whole-cell steps and
        /// emit arrow keys for each cell crossed.
        var floatingCursorStartPoint: CGPoint?
        var floatingCursorCumulativeCol: Int = 0
        var floatingCursorCumulativeRow: Int = 0

        /// Notifies iOS's text input system that our document changed externally.
        /// Must wrap every mutation of documentBuffer that happens OUTSIDE of
        /// insertText/deleteBackward/replace (iOS already brackets those).
        func notifyInputDelegateOfExternalChange(_ mutation: () -> Void) {
            inputDelegate?.textWillChange(self)
            inputDelegate?.selectionWillChange(self)
            mutation()
            inputDelegate?.selectionDidChange(self)
            inputDelegate?.textDidChange(self)
        }

        // Title change debouncing (like macOS implementation)
        var titleChangeTimer: Timer?

        // Progress report auto-removal timer
        var progressReportTimer: Timer?

        // Renders the connect-time spinner / OSC 9;4 progress indicator. Owns
        // the SpinnerAnimator; the per-session-type onStateChange blocks drive
        // it. Assigned in `init` (needs `self` as host), so implicitly unwrapped.
        // See ConnectionProgressPresenter.
        private(set) var connectionProgress: ConnectionProgressPresenter!

        // Failure animator for connection errors
        var failureAnimator: FailureAnimator?

        /// Whether scrollback restore is deferred until after connection animation completes
        var pendingScrollbackRestore: Bool = false

        /// Whether scrollback restore is deferred until layoutSubviews provides correct dimensions
        var pendingScrollbackRestoreForLayout: Bool = false

        /// Mode-restoration trailer captured when an embedded trzsz session reaches
        /// `.running` *before* the layout-deferred scrollback restore has run. The
        /// pending layout-deferred restore consumes this on its way through so the
        /// trailer is appended atomically to the saved scrollback (inside the
        /// gate, before buffered live output is released). Avoids the race where
        /// the trailer would otherwise be written direct to the buffered writer
        /// ahead of the saved scrollback while the gate is still buffering inline
        /// spinner frames + ESC[J cleanup.
        var pendingResumeTrailer: Data?

        /// Set true by the layout-deferred restore path for shellLaunchedTrzsz
        /// restorations where the embedded trzsz session has not yet reached
        /// `.running`. The restore writes saved scrollback to bufferedWriter but
        /// keeps the gate open so subsequent server output (attach response,
        /// resize-jiggle redraw, spinner frames) is buffered. Cleared by
        /// `applyResumeTrailer` once it writes the trailer and finishes the gate
        /// — together making the byte stream
        ///     saved-scrollback → trailer → buffered-server-output → live
        /// even when layout fires before `.running`.
        var scrollbackWrittenAwaitingTrailer: Bool = false

        /// Set true when the embedded trzsz session reaches `.running` and
        /// `applyResumeTrailer` has fired. The layout-deferred restore path
        /// uses this to decide whether to keep the gate open: if `.running` has
        /// already happened (and either deposited the trailer in
        /// `pendingResumeTrailer` or finished without one for fresh sessions),
        /// the layout restore can flush the gate atomically — no need to wait.
        var embeddedTrzszReachedRunning: Bool = false

        // Scrollbar state
        var scrollIndicator: UIView?
        var scrollbarTotal: UInt64 = 0
        var scrollbarOffset: UInt64 = 0
        var scrollbarLen: UInt64 = 0
        private var scrollIndicatorHideWorkItem: DispatchWorkItem?
        private var scrollIndicatorRevealDeadline: TimeInterval = 0
        var smoothScrollOffset: CGFloat = 0
        var smoothScrollActive: Bool = false
        var suppressBottomInsetUpdatesForScrollRubberBand: Bool = false

        /// Observer that scrapes terminal-multiplexer scroll-mode position
        /// indicators (tmux `[N/M]`, zellij ` SCROLL: N/M `) while the user
        /// is scrolling under mouse capture. Updates scrollbarTotal/Offset/Len
        /// with multiplexer-derived values so the existing scrollbar plumbing
        /// (handleScrollbarUpdate in TerminalScrollView) drives UIScrollView's
        /// native indicator.
        var multiplexerScrollObserver: Ghostty.MultiplexerScrollIndicatorObserver?

        /// True while `multiplexerScrollObserver` is feeding multiplexer-
        /// derived values into scrollbarTotal/Offset/Len. Used by
        /// handleScrollbar to drop native (alt-screen) callbacks that would
        /// otherwise clobber the multiplexer values, and by TerminalScrollView
        /// to keep the native scroll indicator visible despite mouse capture
        /// being active.
        @Published var multiplexerScrollActive: Bool = false

        /// Pre-tracking snapshot of native scrollbar state, captured on
        /// the first apply(sample) of a tracking session and restored on
        /// apply(nil). Without this, the post-tracking nil notification
        /// would hit `terminalView.scrollbar == nil` and TerminalScrollView's
        /// handleScrollbarUpdate would early-return, leaving the document
        /// view sized for tmux's history until the next native
        /// handleScrollbar callback (which may not arrive immediately).
        private var nativeScrollbarSnapshotTotal: UInt64?
        private var nativeScrollbarSnapshotOffset: UInt64?
        private var nativeScrollbarSnapshotLen: UInt64?
        
        /// Current scrollbar state (exposed for TerminalScrollView)
        var scrollbar: Ghostty.Action.Scrollbar? {
            // tmux control-mode panes render a viewer-owned terminal while the
            // surface's io.terminal is only a relay placeholder. Query the full
            // displayed-terminal scrollbar so total and offset come from the
            // same pane state.
            if tmuxPaneBinding != nil, let surface = surface {
                var scrollbar = ghostty_action_scrollbar_s()
                guard ghostty_surface_display_scrollbar(surface, &scrollbar) else { return nil }
                return Ghostty.Action.Scrollbar(
                    total: scrollbar.total,
                    offset: scrollbar.offset,
                    len: scrollbar.len
                )
            }
            guard scrollbarTotal > 0 else { return nil }
            return Ghostty.Action.Scrollbar(
                total: scrollbarTotal,
                offset: scrollbarOffset,
                len: scrollbarLen
            )
        }
        
        /// Whether user is actively selecting text (exposed for TerminalScrollView)
        var isActivelySelecting: Bool {
            #if targetEnvironment(macCatalyst)
            return isSelecting || selectionMouseDragActive
            #else
            return isSelecting || activeHandleDrag != nil || selectionMouseDragActive
            #endif
        }
        
        // MARK: - Hit Testing

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Track secondary click state during hit-testing, before gesture recognizers fire.
            // UIContextMenuInteraction's gesture recognizer recognizes instantly on secondary click
            // and calls its delegate before the view's touchesBegan, so this is the only reliable
            // place to distinguish right-click from left-click+hold.
            if let event = event {
                lastPointerEventWasSecondaryClick = event.buttonMask.contains(.secondary)
            }
            return super.hitTest(point, with: event)
        }

        // MARK: - Initialization

        var ghosttyAppRef: Ghostty.App?
        var appPtr: ghostty_app_t?
        
        init(_ app: ghostty_app_t, ghosttyApp: Ghostty.App, uuid: UUID? = nil, connectionConfig: ConnectionConfig = .local(), windowId: String) {
            self.windowId = windowId
            self.ghosttyApp = ghosttyApp
            self.ghosttyAppRef = ghosttyApp
            self.appPtr = app
            self.connectionConfig = connectionConfig

            // Initialize with default frame (will be resized)
            super.init(uuid: uuid ?? .init(), frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            refreshPanePresentationTitle()

            // The session controller owns this terminal's TerminalSession/PTY
            // and relays session events back through the TerminalSessionHost
            // protocol (which this view conforms to). Constructed after
            // super.init because it captures `self` as its host.
            self.surfaceController = TerminalSurfaceController(host: self)
            self.sessionController = TerminalSessionController(host: self)
            self.inputController = TerminalInputController()
            self.shaderAnimationController = TerminalShaderAnimationController(host: self)
            self.keyboardAccessoryController = TerminalKeyboardAccessoryController(host: self)
            self.connectionProgress = ConnectionProgressPresenter(host: self)

            // A pipe-writer overflow dropped oldest output (reader stalled or
            // firehose). Non-tmux surfaces self-correct on the next repaint,
            // but a -CC gateway's control stream is now gapped: drive the same
            // full reset + recapture as a tssh output discard.
            outputPipeline.setWriterOverflowHandler { [weak self] droppedBytes in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let controller = self.tmuxController {
                        controller.resetForDiscard(outputLines: 0, outputBytes: droppedBytes)
                    } else if self.isTmuxGatewaySurfaceActive
                                || self.restoredWasTmuxGateway
                                || self.tmuxResumeRequested {
                        // Live or resuming -CC gateway whose first reconcile
                        // hasn't created the controller yet; stash so the
                        // reset isn't lost. Non-tmux surfaces fall through:
                        // the writer already logged the loss and the display
                        // self-corrects on the next repaint — stashing for
                        // them would fire a bogus reset if this tab later
                        // starts tmux -CC.
                        // ROOTSHELL-TMUX (id=tmux-overflow-stash)
                        self.pendingTmuxOverflowBytes &+= droppedBytes
                    }
                }
            }

            Ghostty.logger.info("TerminalView initialized for window \(windowId), deferring surface creation until view is in window")
            
            // Setup view properties
            setupView()
            
            // Setup keyboard
            setupKeyboard()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }
        
        nonisolated deinit {
            // Safety net - surface should already be freed by cleanup()
            // This handles edge cases where cleanup() wasn't called
            if let surface = self.surface {
                // Capture as Int to satisfy Sendable requirement (raw pointers aren't Sendable)
                let surfaceAddress = Int(bitPattern: surface)
                Task { @MainActor in
                    guard let ptr = UnsafeMutableRawPointer(bitPattern: surfaceAddress) else { return }

                    // Drop the surface from the registry before freeing it.
                    // teardownSurface() normally does this; if it didn't run, a
                    // stale entry would keep taking config pushes after the free
                    // and double-free the surface's link regexes.
                    if let app = Ghostty.App.shared {
                        app.unregisterSurfaceTab(ptr)
                        app.unregisterSurfaceWindow(ptr)
                        app.unregisterSurfaceDelegate(ptr)
                        app.unregisterSurface(ptr)
                    }

                    // Free on background queue - may block on IO thread join
                    nonisolated(unsafe) let surfacePtr = ptr
                    Self.ghosttyAPIQueue.async {
                        // Wait (bounded) for any in-flight background save before
                        // freeing. If the save doesn't finish within 500 ms, leak
                        // the surface rather than risk a use-after-free — the
                        // save dumps `ghostty_surface_dump_primary_screen` and
                        // freeing under it crashes. A wedged save would also
                        // saturate this serial queue and stall every queued
                        // occlusion/render call behind it.
                        let saveCompleted = ScrollbackPersistenceManager.waitForSurfaceSave(surfacePtr)
                        if saveCompleted {
                            ghostty_surface_free(surfacePtr)
                        }
                    }
                }
            }
            // Note: windowFocusObservers cleanup is handled by cleanup() which should be called
            // before deallocation. We don't call unregisterWindowFocusObservers() here because:
            // 1. It's a MainActor-isolated method that can't be called from nonisolated deinit
            // 2. NotificationCenter observer tokens are automatically invalidated when deallocated
        }

        // MARK: - Cleanup

        /// Why the terminal is being torn down. Drives the resumable-session
        /// branch in `cleanup` — the wrong choice here either kills a server
        /// session the user wants preserved (.userClose during a scene
        /// teardown) or strands a server session the user wanted closed
        /// (.sceneTeardown for an explicit tab close).
        enum CleanupReason {
            /// User tapped Close Tab / closed the split. Send "close" to
            /// tsshd/mosh-server and delete local credentials.
            case userClose
            /// Scene/window is being torn down (rotation, app exit). Keep
            /// server-side session alive so resume can pick it back up.
            case sceneTeardown
            /// Continuity transfer: a peer device has already attached to
            /// the same server-side session and ack'd. Abandon transport
            /// silently AND delete local creds (peer owns the session now).
            case transferOut
        }

        /// Generic pane close funnel: a user-initiated close of this pane.
        /// Close paths that know they have a terminal call `cleanup(reason:)`
        /// directly with the appropriate reason.
        override func prepareForClose() {
            cleanup(reason: .userClose)
        }

        /// Re-home overlay child view controllers (the SSH auth-banner card)
        /// under the destination window's controller before the split tree
        /// inserts this pane — a live card mid-auth must not keep a child-VC
        /// relationship with the old window after a tab transfer.
        override func prepareForAttachment(to parentViewController: UIViewController?) -> Bool {
            enclosingTerminalScrollView?.refreshAuthBannerParentViewController(parentViewController)
            return true
        }

        /// Explicitly cleanup resources before deallocation.
        /// Call this from MainView when closing a tab/split.
        func cleanup(reason: CleanupReason = .sceneTeardown) {
            ScrollbackPersistenceManager.shared.unregisterTerminal(uuid: self.uuid)

            #if targetEnvironment(macCatalyst)
            clearCursorRegistration()
            #endif

            unregisterWindowFocusObservers()

            // 0. Remove any pending desktop notifications
            if !notificationIdentifiers.isEmpty {
                NotificationManager.shared.removeNotifications(identifiers: Array(notificationIdentifiers))
                notificationIdentifiers.removeAll()
            }

            // 0.5. Stop spinner animation
            connectionProgress.reset()

            if let ticketID = activeTransferTicketID {
                activeTransferTicketID = nil
                TrzszTransferInbox.shared.cancel(ticketID)
            }

            // 1-2. Stop the session and close the PTY. The per-session-type
            // teardown semantics (resumable Trzsz/Mosh keep the server session
            // alive for .sceneTeardown; .userClose terminates) live on the
            // owning controller now. See TerminalSessionController.teardown.
            sessionController.teardown(reason: reason)

            // 3. Cancel async tasks and timers
            activeUploader?.cancel()
            activeUploader = nil
            outputMonitorTask?.cancel()
            outputMonitorTask = nil
            transferAttachTask?.cancel()
            transferAttachTask = nil
            outputPipeline.cancel()
            scrollIndicatorHideWorkItem?.cancel()
            scrollIndicatorHideWorkItem = nil
            keyboardAccessoryController.tearDown()
            #if !targetEnvironment(macCatalyst)
            pendingDoubleTapActionTask?.cancel()
            pendingDoubleTapActionTask = nil
            selectionStartHandle?.removeFromSuperview()
            selectionStartHandle = nil
            selectionEndHandle?.removeFromSuperview()
            selectionEndHandle = nil
            selectionHandlesVisible = false
            selectionMagnifierView?.dismiss(animated: false) {}
            selectionMagnifierView?.removeFromSuperview()
            selectionMagnifierView = nil
            selectionLoupe?.invalidate()
            selectionLoupe = nil
            selectionMagnifierPoint = nil

            inputModeDismissTask?.cancel()
            inputModeDismissTask = nil
            if let obs = inputModeObserver {
                NotificationCenter.default.removeObserver(obs)
                inputModeObserver = nil
            }
            tearDownIOSScrollHandling()
            #else
            // Tear down Catalyst-specific NotificationCenter observers and timers.
            // NotificationCenter strongly retains block-based observers, so without
            // this each closed tab leaks one.
            tearDownCatalystScrollHandling()
            #endif

            multiplexerScrollObserver?.tearDown()
            multiplexerScrollObserver = nil
            titleChangeTimer?.invalidate()
            titleChangeTimer = nil
            progressReportTimer?.invalidate()
            progressReportTimer = nil
            progressReport = nil

            // 3.25. Stop any scroll or pointer display links
            cancelMomentumScrolling()
            stopRightClickMonitoring()

            // 3.5. Stop shader animation
            shaderAnimationController.tearDown()

            // 4. Unregister/free surface and re-arm first-frame tracking for a
            // possible surface recreation.
            //
            // Tear down tmux gateway state bound to this surface BEFORE it is
            // freed. teardownSurface nils the view's surface now, then frees the
            // real surface async on ghosttyAPIQueue. The TmuxController captured
            // that surface as a raw pointer (always-on recovery watchdog, command
            // sends, and queued reconciles all deref it), and the response
            // pipeline reports this view as a gateway while tmuxController /
            // tmuxGatewayOwnerKey are set. Mirror the %exit teardown in
            // applyTmuxReconcile (minus the size-resync — the surface is going
            // away, not reverting to a shell): stop the controller's
            // surface-touching tasks, then clear the view-side gateway tracking so
            // a queued reconcile can't reuse the dead controller (it falls through
            // to applyTmuxReconcile's nil-surface guard) and a recreated surface
            // starts clean. No-op for non-gateway views (tmuxController == nil).
            // ROOTSHELL-TMUX (id=tmux-gateway-surface-freed)
            if let controller = tmuxController {
                controller.gatewaySurfaceWillBeFreed()
                sessionController.clearGatewayFastPath()
                tmuxGatewayOwnerKey = 0
                sessionController.resetGatewayReportFilter()
                tmuxController = nil
            }
            // Loss stashed for a controller that never got created belongs to
            // the surface generation being torn down; don't let it fire a
            // reset on the next one. ROOTSHELL-TMUX (id=tmux-overflow-stash)
            pendingTmuxOverflowBytes = 0
            surfaceController.teardownSurface()

            // 5. Clear callbacks to break any retain cycles
            onAuthenticationRequired = nil
            onHostKeyValidationRequired = nil
            onKeyboardInteractiveChallengeRequired = nil
        }

        // MARK: - View Setup

        private func setupView() {
            // Configure view for transparency
            // Use clear background to allow window-level transparency to show through
            backgroundColor = .clear
            isOpaque = false
            
            // Enable user interaction
            isUserInteractionEnabled = true
            
            // FIX: Set content scale to match screen for Retina rendering
            // By default UIView has contentScaleFactor = 1.0, but we need 2.0+ for Retina
#if os(visionOS)
            // visionOS doesn't have UIScreen.main, use display scale from trait collection
            self.contentScaleFactor = traitCollection.displayScale
#else
            self.contentScaleFactor = UIScreen.main.scale
#endif

#if !targetEnvironment(macCatalyst)
            // UIKit re-derives contentScaleFactor from traits on its own schedule;
            // turn a silent revert of the external scale into a re-assert + re-push.
            registerForTraitChanges([UITraitDisplayScale.self]) { (view: TerminalView, _) in
                view.noteEffectiveScaleChanged()
            }
#endif

            // Log display properties
            Ghostty.logger.info("Display properties:")
            Ghostty.logger.info("   contentScaleFactor: \(self.contentScaleFactor) (set to match screen)")
#if !os(visionOS)
            Ghostty.logger.info("   Screen scale: \(UIScreen.main.scale)")
            Ghostty.logger.info("   Screen nativeScale: \(UIScreen.main.nativeScale)")
#endif
            
            // Add tap gesture to show keyboard
            // Configure to not interfere with touch delivery for mouse capture mode
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tapGesture.cancelsTouchesInView = false
            tapGesture.delaysTouchesBegan = false
            addGestureRecognizer(tapGesture)

            #if !targetEnvironment(macCatalyst)
            let dblTapDelegate = TouchOnlyGestureDelegate()
            doubleTapDelegate = dblTapDelegate

            let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTapGesture.numberOfTapsRequired = 2
            doubleTapGesture.cancelsTouchesInView = false
            doubleTapGesture.delaysTouchesBegan = false
            doubleTapGesture.delegate = dblTapDelegate
            addGestureRecognizer(doubleTapGesture)

            tapGesture.require(toFail: doubleTapGesture)
            #endif

            #if targetEnvironment(macCatalyst)
            // Mac Catalyst: Keep long press for trackpad click-and-drag selection
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
            longPress.minimumPressDuration = 0.5
            longPress.cancelsTouchesInView = false
            longPress.delaysTouchesBegan = false
            addGestureRecognizer(longPress)
            #else
            // iOS/iPadOS: Use pan gesture for touch-based selection
            // Pan recognizes movement, context menu recognizes stillness - no conflict
            let selectionPan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionPan))
            selectionPan.minimumNumberOfTouches = 1
            selectionPan.maximumNumberOfTouches = 1
            selectionPan.cancelsTouchesInView = false
            selectionPan.delegate = self
            // Finger or pencil contacts, not mouse/trackpad
            selectionPan.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.pencil.rawValue),
            ]
            addGestureRecognizer(selectionPan)
            self.selectionPanGesture = selectionPan

            // Long-press gesture for text selection in scroll mode (initially disabled)
            let selectionLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleSelectionLongPress))
            selectionLongPress.minimumPressDuration = 0.5
            selectionLongPress.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.pencil.rawValue),
            ]
            selectionLongPress.isEnabled = false
            selectionLongPress.delegate = self
            addGestureRecognizer(selectionLongPress)
            self.selectionLongPressGesture = selectionLongPress

            // Two-finger tap for context menu in scroll mode (initially disabled)
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.isEnabled = false
            addGestureRecognizer(twoFingerTap)
            self.twoFingerTapGesture = twoFingerTap

            // Horizontal swipe gestures for user-configurable bindings (SwipeGestureManager).
            // Only enabled in Scroll Mode — outside scroll mode, single-finger pan is
            // owned by selectionPanGesture (text selection) and immediate mouse forwarding
            // in touchesBegan (capture-mode finger drags), and we keep the original mutual
            // exclusion. gestureRecognizerShouldBegin gates the capture scroll pan by
            // direction so vertical scroll starts immediately while horizontal swipes
            // still route through the user's binding.
            let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleTabSwipeLeft))
            swipeLeft.direction = .left
            swipeLeft.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            swipeLeft.isEnabled = false  // applyTouchMode() will gate on scrollMode
            // Delegate so `shouldReceive` excludes touches inside the brightness
            // HUD — otherwise a fast horizontal flick on the slider fires this
            // discrete swipe → app-tab swipe → occlusion thrash → render freeze.
            swipeLeft.delegate = self
            addGestureRecognizer(swipeLeft)
            self.tabSwipeLeftGesture = swipeLeft

            let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleTabSwipeRight))
            swipeRight.direction = .right
            swipeRight.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            swipeRight.isEnabled = false  // applyTouchMode() will gate on scrollMode
            swipeRight.delegate = self
            addGestureRecognizer(swipeRight)
            self.tabSwipeRightGesture = swipeRight

            let appTabSwipePan = UIPanGestureRecognizer(target: self, action: #selector(handleAppTabSwipePan))
            appTabSwipePan.minimumNumberOfTouches = 1
            appTabSwipePan.maximumNumberOfTouches = 1
            appTabSwipePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            appTabSwipePan.isEnabled = false
            appTabSwipePan.delegate = self
            addGestureRecognizer(appTabSwipePan)
            self.appTabSwipePanGesture = appTabSwipePan

            // Single-finger pan for scrolling during mouse capture + scroll mode (initially disabled)
            let captureScrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleCaptureScrollPan))
            captureScrollPan.minimumNumberOfTouches = 1
            captureScrollPan.maximumNumberOfTouches = 1
            captureScrollPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            captureScrollPan.isEnabled = false
            captureScrollPan.delegate = self
            addGestureRecognizer(captureScrollPan)
            self.captureScrollPanGesture = captureScrollPan

            // Long press for mouse click during mouse capture + scroll mode (initially disabled)
            let captureLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCaptureLongPress))
            captureLongPress.minimumPressDuration = 0.3
            captureLongPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            captureLongPress.cancelsTouchesInView = true
            captureLongPress.isEnabled = false
            captureLongPress.delegate = self
            addGestureRecognizer(captureLongPress)
            self.captureLongPressGesture = captureLongPress

            // Pinch gesture for font size adjustment in scroll mode
            let pinchZoom = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchZoom))
            pinchZoom.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pinchZoom.isEnabled = false
            pinchZoom.delegate = self
            addGestureRecognizer(pinchZoom)
            self.pinchZoomGesture = pinchZoom

            // Two-finger long press to open new connection sheet.
            // Duration and enablement are reconciled in applyTouchMode() based on
            // TwoFingerLongPressSetting (user-configurable, defaults to 0.5s).
            let twoFingerLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleTwoFingerLongPress))
            twoFingerLongPress.numberOfTouchesRequired = 2
            twoFingerLongPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            twoFingerLongPress.isEnabled = false
            addGestureRecognizer(twoFingerLongPress)
            self.twoFingerLongPressGesture = twoFingerLongPress

            // Apply initial touch mode and observe changes
            applyTouchMode()
            setupTouchModeObserver()
            #endif

            // Apply initial ASCII keyboard setting and observe changes
            applyASCIIKeyboardSetting()
            setupASCIIKeyboardObserver()

            #if !targetEnvironment(macCatalyst) && !os(visionOS)
            // Re-evaluate the home-indicator bottom inset live when the
            // "Extend Under Home Indicator" setting changes.
            setupBottomInsetObserver()
            #endif

            #if STANDALONE && targetEnvironment(macCatalyst)
            setupVisorResizeFlushObserver()
            #endif

            // Flush the size a dropped layout left behind when the overlay
            // keyboard-preservation latch releases.
            setupOverlayPreservationFlushObserver()

            // Add pointer interaction for mouse/trackpad support
            let pointerInteraction = UIPointerInteraction(delegate: self)
            addInteraction(pointerInteraction)
            #if !targetEnvironment(macCatalyst)
            self.pointerInteraction = pointerInteraction
            #endif

            // Add context menu interaction for copy/paste/split/etc
            // Note: Right-click in mouse capture mode (tmux, vim) is handled in the
            // contextMenuInteraction delegate by sending events to Ghostty and polling for release
            let contextInteraction = UIContextMenuInteraction(delegate: self)
            addInteraction(contextInteraction)
            self.contextMenuInteraction = contextInteraction

            // Add drop interaction for file/URL drag-and-drop
            let dropInteraction = UIDropInteraction(delegate: self)
            addInteraction(dropInteraction)

            // Enable user interaction for mouse events
            isUserInteractionEnabled = true

            // Add hover gesture for cursor management and right-click tracking
            // Works on Mac Catalyst and iPad with trackpad (iPadOS 13.4+)
            let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHoverGesture(_:)))
            addGestureRecognizer(hoverGesture)

            #if !targetEnvironment(macCatalyst) && !os(visionOS)
            // Barrel double-tap (Pencil 2/Pro) = right-click at the pencil's
            // position (tap.hoverPose on hover-capable hardware, last contact
            // otherwise)
            let pencilInteraction = UIPencilInteraction(delegate: self)
            addInteraction(pencilInteraction)

            // Scribble assumes it can read back and edit the text it inserted,
            // which double-emits words into a write-only terminal (same failure
            // class as dictation). Suppress handwriting entirely; the pencil is
            // pointer/selection input here.
            let scribbleInteraction = UIScribbleInteraction(delegate: self)
            addInteraction(scribbleInteraction)
            #endif

            #if !targetEnvironment(macCatalyst)
            // Add pan gesture for right-click drag on iPad
            // UIContextMenuInteraction consumes touches on fresh tabs, so we use a gesture instead
            let rightClickPan = UIPanGestureRecognizer(target: self, action: #selector(handleRightClickPan(_:)))
            rightClickPan.allowedScrollTypesMask = [.continuous, .discrete]
            rightClickPan.minimumNumberOfTouches = 0  // Allow mouse/trackpad (no finger touches required)
            rightClickPan.maximumNumberOfTouches = 1
            rightClickPan.delegate = self
            addGestureRecognizer(rightClickPan)
            self.rightClickPanGesture = rightClickPan
            #endif

            // Setup platform-specific scroll handling
            // Mac Catalyst: scroll wheel via UIPanGestureRecognizer with scroll type mask
            // iOS/visionOS: finger pan gesture with UIDynamicAnimator for momentum
            setupScrollHandling()

            // Create scroll indicator
            setupScrollIndicator()
            setupCollapsedKeyboardToolbarButton()

            // Setup shader animation observer (for CADisplayLink vsync on iOS)
            setupShaderAnimationObserver()
        }
        
        #if !targetEnvironment(macCatalyst)
        /// Apply current touch mode settings to gesture recognizers
        func applyTouchMode() {
            let scrollMode = isTouchScrollMode
            let captured = isMouseCaptured
            selectionPanGesture?.isEnabled = !scrollMode
            selectionLongPressGesture?.isEnabled = scrollMode && !captured
            twoFingerTapGesture?.isEnabled = scrollMode
            // Swipe gestures are gated on Scroll Mode (matching the original mutual
            // exclusion with selectionPanGesture and immediate-mouse-forward in
            // touchesBegan) AND on whether the user has bound a non-disabled action
            // to that direction. Within scroll mode, swipes work even in capture mode
            // — the runtime guards and gesture-delegate filters that previously blocked
            // them have been removed, and the capture scroll pan's direction gate
            // keeps horizontal swipes from leaking as mouse-forward pans.
            let leftBinding = SwipeGestureManager.shared.binding(for: .left)
            let rightBinding = SwipeGestureManager.shared.binding(for: .right)
            tabSwipeLeftGesture?.isEnabled = scrollMode
                && !leftBinding.isDisabled
                && !leftBinding.isAppTabNavigation
            tabSwipeRightGesture?.isEnabled = scrollMode
                && !rightBinding.isDisabled
                && !rightBinding.isAppTabNavigation
            appTabSwipePanGesture?.isEnabled = scrollMode
                && (leftBinding.isAppTabNavigation || rightBinding.isAppTabNavigation)
            captureScrollPanGesture?.isEnabled = scrollMode && captured
            captureLongPressGesture?.isEnabled = scrollMode && captured
            pinchZoomGesture?.isEnabled = scrollMode
            let twoFingerLongPressDuration = TwoFingerLongPressSetting.storedDuration()
            twoFingerLongPressGesture?.minimumPressDuration = max(twoFingerLongPressDuration, 0.1)
            twoFingerLongPressGesture?.isEnabled = scrollMode && twoFingerLongPressDuration > 0
            applyTrackpadTabSwipeMode()
        }

        private func setupTouchModeObserver() {
            let observer = NotificationCenter.default.addObserver(
                forName: .touchModeChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTouchMode() }
            }
            cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(observer) })

            // Re-apply when the user changes a swipe binding so that .preset(.none)
            // disables the recognizer (and any non-disabled binding re-enables it).
            let swipeObserver = NotificationCenter.default.addObserver(
                forName: SwipeGestureManager.bindingsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTouchMode() }
            }
            cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(swipeObserver) })
        }
        #endif

        private func applyASCIIKeyboardSetting() {
            let forceASCII = UserDefaults.standard.bool(forKey: "forceASCIIKeyboard")
            keyboardType = forceASCII ? .asciiCapable : .default
            if isFirstResponder {
                reloadInputViews()
            }
        }

        private func setupASCIIKeyboardObserver() {
            let observer = NotificationCenter.default.addObserver(
                forName: .forceASCIIKeyboardChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyASCIIKeyboardSetting() }
            }
            cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(observer) })
        }

        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        private func setupBottomInsetObserver() {
            let observer = NotificationCenter.default.addObserver(
                forName: .terminalBottomInsetInvalidated,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshBottomInset() }
            }
            cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(observer) })
        }

        /// The reserved home-indicator bottom inset changed ("Extend Under Home
        /// Indicator" toggled). Clear the size dedupe so the grid recomputes against
        /// the new inset even when the view bounds are unchanged.
        private func refreshBottomInset() {
            surfaceController.invalidateCachedSize()
            updateBottomInset()
            sizeDidChange(bounds.size)
        }
        #endif

        private func setupOverlayPreservationFlushObserver() {
            let observer = NotificationCenter.default.addObserver(
                forName: .overlayKeyboardPreservationEnded,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Hop one turn so any SwiftUI update the release triggered
                // (padding recompute when a pending hide was committed) lands
                // first and the flush pushes the final bounds exactly once.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.flushOverlayPreservationSuppressedResize()
                    }
                }
            }
            cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(observer) })
        }

        /// Overlay keyboard preservation ended. Layouts that landed while it
        /// was armed were dropped and UIKit will not re-fire them, so push the
        /// current bounds through. Deliberately NO invalidateCachedSize():
        /// the cache reflects what was actually sent, so a clean round trip
        /// (bounds back where they started) dedupes away with zero pushes and
        /// zero SIGWINCH, while a genuine change (rotation while open) flows.
        private func flushOverlayPreservationSuppressedResize() {
            guard window != nil else { return }
            // Keep inset + size atomic: while background suppression is up,
            // sizeDidChange would bail after the inset applied, reflowing the
            // grid against the stale framebuffer. Skip both; foreground
            // recovery (clearSizeSuppression + relayout) re-applies them
            // together.
            guard !surfaceController.sizeUpdatesSuppressed else { return }
            updateBottomInset()
            sizeDidChange(bounds.size)
        }

        #if STANDALONE && targetEnvironment(macCatalyst)
        private func setupVisorResizeFlushObserver() {
            let observer = NotificationCenter.default.addObserver(
                forName: .visorResizeSuppressionEnded,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.windowId == "visor" else { return }
                    self.flushVisorSuppressedResize()
                }
            }
            cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(observer) })
        }

        /// Visor resize suppression ended. Any layout that landed while it was
        /// active was dropped and UIKit will not re-fire it, so push the
        /// current bounds through. Deliberately NO invalidateCachedSize():
        /// the cached sizes reflect what was actually sent (written after all
        /// suppression gates), so a dropped resize mismatches the cache and
        /// flows, while an unchanged size dedupes away without touching
        /// Ghostty or the PTY (no spurious SIGWINCH/TUI redraw per toggle).
        private func flushVisorSuppressedResize() {
            // The cache records what was last SENT, which catches a resize the
            // suppression gate dropped but NOT a surface that is stale despite
            // a matching cache. That case leaves the grid taller than the view,
            // with its bottom rows (the shell input line on a multi-line
            // prompt) rendering past the visible bottom edge. Ask the surface
            // what size it believes it has and only overrule the cache when it
            // disagrees, so a healthy toggle still dedupes to nothing.
            let scale = contentScaleFactor
            if scale > 0, bounds.width > 0, bounds.height > 0,
               let grid = surfaceController.surfaceSize {
                let expectedWidth = UInt32(bounds.width * scale)
                let expectedHeight = UInt32(bounds.height * scale)
                let actualWidth = grid.width_px
                let actualHeight = grid.height_px
                if actualWidth != expectedWidth || actualHeight != expectedHeight {
                    Ghostty.logger.warning(
                        "visor surface drifted from view: surface=\(actualWidth)x\(actualHeight) expected=\(expectedWidth)x\(expectedHeight)")
                    surfaceController.invalidateCachedSize()
                }
            }

            sizeDidChange(bounds.size)
            let boundsSize = bounds.size
            let windowHeight = window?.bounds.height ?? -1
            let grid = surfaceController.surfaceSize
            let columns = grid?.columns ?? 0
            let rows = grid?.rows ?? 0
            Ghostty.logger.info("visor resize flush: bounds=\(boundsSize.width)x\(boundsSize.height) windowHeight=\(windowHeight) grid=\(columns)x\(rows)")
        }
        #endif

        private func setupScrollIndicator() {
            let indicator = UIView()
            indicator.backgroundColor = UIColor.white.withAlphaComponent(0.5)
            indicator.layer.cornerRadius = 2
            indicator.alpha = 0 // Hidden by default
            indicator.isUserInteractionEnabled = false
            addSubview(indicator)

            self.scrollIndicator = indicator

            // Observer that drives this same indicator with multiplexer-
            // derived values during mouse-captured scrolling. Hooked to the
            // surface and grid via closures so the observer stays decoupled
            // from the view's lifecycle.
            multiplexerScrollObserver = Ghostty.MultiplexerScrollIndicatorObserver(
                surfaceProvider: { [weak self] in self?.surface },
                gridSizeProvider: { [weak self] in
                    guard let size = self?.surfaceSize else { return nil }
                    return (rows: size.rows, cols: size.columns)
                },
                altScreenActive: { [weak self] in
                    // Direct mosh renders a reconstructed framebuffer into
                    // Ghostty instead of forwarding the remote PTY byte stream.
                    // Its renderer restores mouse modes, but it does not emit
                    // smcup/1049, so Ghostty's alternate-screen flag remains
                    // false even while tmux is rendering copy mode.
                    if self?.connectionConfig.isMosh == true {
                        return true
                    }
                    guard let surface = self?.surface else { return false }
                    return ghostty_surface_is_alternate_active(surface)
                },
                // Query the C side directly. The cached @Published
                // `isMouseCaptured` can lag tmux's mouse-on sequence (same
                // reason the scroll handlers query C directly — see comment
                // at TerminalViewScroll.swift:425).
                mouseCaptured: { [weak self] in
                    guard let surface = self?.surface else { return false }
                    return ghostty_surface_mouse_captured(surface)
                },
                onSample: { [weak self] sample in
                    self?.applyMultiplexerScrollSample(sample)
                }
            )
        }

        private func setupCollapsedKeyboardToolbarButton() {
            keyboardAccessoryController.setupCollapsedKeyboardToolbarButton()
        }

        private func collapseKeyboardToolbar() {
            keyboardToolbarCollapsed = true
            reloadInputViews()
        }

        @objc private func restoreCollapsedKeyboardToolbar() {
            keyboardToolbarCollapsed = false
            if !isFirstResponder {
                _ = becomeFirstResponder()
            }
            reloadInputViews()
        }

        private func updateCollapsedKeyboardToolbarButtonVisibility() {
            keyboardAccessoryController.setAIAgentOverlayActive(aiAgentOverlayActive)
        }

        private func updateCollapsedKeyboardToolbarButtonLayout() {
            keyboardAccessoryController.updateCollapsedKeyboardToolbarButtonLayout()
        }

        func hitTestCollapsedKeyboardToolbarButton(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            keyboardAccessoryController.hitTestCollapsedKeyboardToolbarButton(point, with: event)
        }

        /// Suppress the keyboard while keeping the toolbar visible above the
        /// home indicator. Used by the persistent-toolbar dismiss, the
        /// pinned-hidden long-press, and re-arming the pin on focus regain.
        func enterToolbarOnlyMode() {
            keyboardAccessoryController.enterToolbarOnlyMode()
        }

        /// Restore the full keyboard from toolbar-only mode, clearing the
        /// pinned-hidden state if set.
        func exitToolbarOnlyMode() {
            keyboardAccessoryController.exitToolbarOnlyMode()
        }

        private func setupKeyboard() {
            keyboardAccessoryController.setupKeyboard(delegate: self)
            setupInputModeObserver()
            setupModTapInterceptorCallbacks()
        }

        private func setupInputModeObserver() {
            #if !targetEnvironment(macCatalyst)
            refreshHardwareInputSourceSwitchAvailability()
            lastInputModePrimaryLanguage = textInputMode?.primaryLanguage
            inputModeObserver = NotificationCenter.default.addObserver(
                forName: UITextInputMode.currentInputModeDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleInputModeChange() }
            }
            #endif
        }

        private func setupModTapInterceptorCallbacks() {
            modTapInterceptor.onTapAction = { [weak self] action in
                guard let self else { return }

                if case .switchInputSource(let lang) = action {
                    self.applyInputLanguageSwitch(toPrimaryLanguage: lang)
                    return
                }

                guard let data = action.data else { return }

                if data == Data([0x1B]) {
                    if self.discoveredSessions != nil {
                        self.dismissSessionDiscovery()
                        return
                    }
                    if self.aiAgentOverlayActive {
                        NotificationCenter.default.post(name: .toggleAIAgent, object: self)
                        return
                    }
                }

                NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
                self.sendUserInput(data)
            }
            modTapInterceptor.onModifierChanged = { [weak self] modifier in
                self?.virtualModTapModifier = modifier
            }
            modTapInterceptor.onReplayKeyWithModifier = { [weak self] press, modifier in
                guard let self else { return }
                self.virtualModTapModifier = modifier
                self.processKeyPress(press, virtualModifier: modifier)
            }
            modTapInterceptor.onSourceKeyResolved = { [weak self] rule, isHold in
                if rule.sourceKey == .capsLock && !isHold && rule.tapAction == .none {
                    self?.userWantsCapsLock.toggle()
                }
            }
        }
        
        // MARK: - Window Focus Management

        #if !targetEnvironment(macCatalyst)
        /// External content is genuinely focusable only in control mode, where
        /// it lives in the key ControlSurfaceWindow.
        private func externalContentWindowIsActive() -> Bool {
            guard let window, window is ControlSurfaceWindow else { return false }
            return window.isKeyWindow && ExternalDisplayManager.shared.isControlSurfaceActive
        }

        /// Called by ExternalDisplayManager when typing focus returns to the
        /// device: heal a windowActiveOverride stuck false, then run the normal
        /// focus path so first responder and the software keyboard come back.
        func restoreDeviceFocusAfterExternalForwarding() {
            guard !isExternalDisplayTerminal, window != nil else { return }
            if !windowIsActiveForFocus(), windowGenuineFocusSignal() {
                setWindowActive(true)
            }
            if !isLogicallyFocused { isLogicallyFocused = true }
            _ = focusDidChange(true)
        }
        #endif

        private func windowIsActiveForFocus() -> Bool {
            #if !targetEnvironment(macCatalyst)
            if isExternalDisplayTerminal { return externalContentWindowIsActive() }
            #endif
            // The override may only NARROW focus, never claim it while the scene
            // is not foreground-active. `updateWindowFocusState` leaves it armed
            // across an app transition to preserve the software keyboard, and a
            // stale `true` let becomeFirstResponder() present the keyboard under
            // lock (FrontBoard 0x2BAD45EC).
            #if !targetEnvironment(macCatalyst)
            if let scene = window?.windowScene, scene.activationState != .foregroundActive {
                return false
            }
            #endif
            if let windowActiveOverride {
                return windowActiveOverride
            }
            return windowGenuineFocusSignal()
        }

        /// Ground-truth "this window is the active/usable one" from live UIKit
        /// state, bypassing the `windowActiveOverride`. Used both as the override-nil
        /// fallback above and by `reassertVisibleIfNeeded` to detect (and heal) a
        /// `windowActiveOverride` stuck `false` after a missed `setWindowActive`.
        ///
        /// Mirrors `MainView.currentWindowIsKey`: on iPadOS/visionOS multi-window
        /// `isKeyWindow` is UNRELIABLE — multiple scenes can be `.foregroundActive`
        /// at once and it can false-positive on an inactive window. Since this signal
        /// can heal a (correctly) `false` override and then drive
        /// `focusDidChange(true)` from the delayed tab-switch backstop, trusting
        /// `isKeyWindow` here would let an inactive window steal first responder. So
        /// non-Catalyst requires the authoritative `activeAppearance` trait only;
        /// Catalyst keeps `isKeyWindow` (reliable there, matching MainView).
        private func windowGenuineFocusSignal() -> Bool {
            guard let window = window else { return false }
            #if !targetEnvironment(macCatalyst)
            if isExternalDisplayTerminal { return externalContentWindowIsActive() }
            #endif
            if let scene = window.windowScene, scene.activationState != .foregroundActive {
                return false
            }
            #if targetEnvironment(macCatalyst)
            return window.isKeyWindow
            #else
            return traitCollection.activeAppearance == .active
            #endif
        }

        override func setWindowActive(_ active: Bool) {
            // Don't let false poison the override before it has ever been true.
            // During cold start, isWindowFocused starts as false and every terminal
            // creation site calls setWindowActive(false) — sometimes even after the
            // view is in a window (e.g. TerminalContainer.updateUIView). Setting the
            // override to false blocks ALL focus recovery paths (didMoveToWindow,
            // window/scene notifications) because windowIsActiveForFocus() returns
            // the override value instead of checking real UIKit state.
            //
            // By only allowing false after the override has been set to true at least
            // once, we ensure: (1) cold start can't be poisoned regardless of timing,
            // (2) once the window has been active, defocusing works correctly.
            if !active && windowActiveOverride == nil {
                return
            }
            windowActiveOverride = active
            syncFocusForWindowStateChange()
        }

        /// Per-window keyboard-ownership gate, driven synchronously by MainView
        /// from `isAnySheetPresented`. Mirrors `setWindowActive` but with no
        /// "has-been-true-once" latch: the flag is fed by a well-defined
        /// MainView edge, so a default `false` can never poison cold start.
        ///
        /// Raising it resigns first responder immediately (the overlay's field
        /// takes over); dropping it reconciles first responder back to this
        /// terminal when it is the logically focused one.
        override func setOverlayOwnsKeyboard(_ owns: Bool) {
            guard overlayOwnsKeyboard != owns else { return }
            overlayOwnsKeyboard = owns
            Ghostty.logger.info("setOverlayOwnsKeyboard(\(owns)) terminal=\(self.uuid.uuidString.prefix(8)) isFR=\(self.isFirstResponder) logical=\(self.isLogicallyFocused)")
            if owns {
                if isFirstResponder {
                    // Snapshot the live toolbar reserve while it is still valid
                    // (it requires first responder). When we aren't focused —
                    // e.g. a rapid reopen before the reconcile restored us —
                    // keep the existing latch instead of clobbering it with 0.
                    overlayLatchedToolbarReserve =
                        keyboardAccessoryController?.reservedKeyboardToolbarHeightAtBottom ?? 0
                    _ = resignFirstResponder()
                }
            } else {
                // Defer one runloop so the overlay's dismiss update fully
                // settles first: the search field resigns (endEditing) and its
                // @FocusState binding goes false. Claiming synchronously here
                // races that — the terminal would take first responder, then
                // SwiftUI re-asserts the still-true @FocusState on the
                // off-screen field and steals it back, then the field resigns,
                // leaving NOTHING focused. Letting the dismiss settle first
                // means the terminal claims into a quiet state nothing contests.
                DispatchQueue.main.async { [weak self] in
                    self?.reconcileFirstResponderAfterOverlayRelease(attempt: 0)
                }
            }
        }

        /// Drive first responder back onto this terminal after a keyboard-owning
        /// overlay (the tab sidebar) is dismissed. The single synchronous
        /// becomeFirstResponder can fail TRANSIENTLY: the gate drops the instant
        /// the dismiss binding flips, while the overlay's hosting view is still
        /// on-screen mid-animation and the search field is still mid-resign, so
        /// UIKit can refuse the hand-off for a runloop or two. Unlike the old
        /// design this is a SINGLE owner that re-checks the gate every attempt
        /// and stops the moment the overlay returns — it converges without ever
        /// fighting the search field (which cannot be first responder once the
        /// gate is down anyway).
        private func reconcileFirstResponderAfterOverlayRelease(attempt: Int) {
            // Hard bails: the overlay came back (rapid reopen), we are no longer
            // the logically focused pane, or the window went inactive. Each is a
            // legitimate reason NOT to take the keyboard.
            guard !overlayOwnsKeyboard,
                  isLogicallyFocused,
                  windowIsActiveForFocus() else {
                // Overlay came back: keep the toolbar-reserve latch armed for
                // the reopened round trip. Any other bail means first responder
                // is never returning here — release the latch so padding
                // reflects reality.
                if !overlayOwnsKeyboard {
                    clearOverlayLatchedToolbarReserve()
                }
                Ghostty.logger.info("reconcile bail attempt=\(attempt) terminal=\(self.uuid.uuidString.prefix(8)) gate=\(self.overlayOwnsKeyboard) logical=\(self.isLogicallyFocused) winActive=\(self.windowIsActiveForFocus())")
                return
            }
            // A modal still presented at gate-down time is necessarily ANIMATING
            // AWAY: every tracked sheet/overlay is already dismissed (that's what
            // dropped the gate). A real `.sheet` — the YubiKey PIN prompt, the
            // settings sheet — keeps `presentedViewController` non-nil through its
            // ~300ms dismiss, far longer than the immediate yield-retries below can
            // outlast, which is why a modal sheet (unlike the non-modal sidebar)
            // used to lose the keyboard back to the terminal. So wait it out with a
            // short delay rather than bailing. Bounded, and harmless if some
            // untracked modal genuinely stays up — we never reach
            // becomeFirstResponder() while one is presented, so we can't steal it.
            if isModalPresented() {
                guard attempt < 24 else {
                    clearOverlayLatchedToolbarReserve()
                    Ghostty.logger.warning("reconcile GAVE UP (modal still presented) after \(attempt) attempts terminal=\(self.uuid.uuidString.prefix(8))")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.reconcileFirstResponderAfterOverlayRelease(attempt: attempt + 1)
                }
                return
            }
            if isFirstResponder {
                clearOverlayLatchedToolbarReserve()
                return
            }
            if becomeFirstResponder() {
                // First responder is back, so the live reserve computation is
                // valid again and the latch can drop without a layout jump.
                clearOverlayLatchedToolbarReserve()
                reloadInputViews()
                Ghostty.logger.info("reconcile SUCCESS attempt=\(attempt) terminal=\(self.uuid.uuidString.prefix(8))")
                return
            }
            guard attempt < 24 else {
                clearOverlayLatchedToolbarReserve()
                Ghostty.logger.warning("reconcile GAVE UP after \(attempt) attempts terminal=\(self.uuid.uuidString.prefix(8))")
                return
            }
            // Transient failure: re-attempt on the next runloop turn. No fixed
            // delay — just yield so the dismiss transition advances — and the
            // gate guard above invalidates this if the overlay reopens.
            DispatchQueue.main.async { [weak self] in
                self?.reconcileFirstResponderAfterOverlayRelease(attempt: attempt + 1)
            }
        }

        /// Drop the overlay toolbar-reserve latch and let SwiftUI recompute the
        /// bottom padding from live state. The version bump is a no-op layout
        /// when the live reserve matches the latched value.
        private func clearOverlayLatchedToolbarReserve() {
            guard overlayLatchedToolbarReserve > 0 else { return }
            overlayLatchedToolbarReserve = 0
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }

        private func registerWindowFocusObservers() {
            guard let window = window else { return }
            if observedWindow === window { return }
            
            unregisterWindowFocusObservers()
            observedWindow = window
            observedScene = window.windowScene
            
            let center = NotificationCenter.default
            let didBecomeKey = center.addObserver(
                forName: UIWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFocusForWindowStateChange() }
            }
            let didResignKey = center.addObserver(
                forName: UIWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFocusForWindowStateChange() }
            }
            
            windowFocusObservers = [didBecomeKey, didResignKey]
            
            if let scene = observedScene {
                let didActivate = center.addObserver(
                    forName: UIScene.didActivateNotification,
                    object: scene,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        #if !targetEnvironment(macCatalyst)
                        self?.isPreservingResponderAcrossSceneDeactivation = false
                        #endif
                        self?.syncFocusForWindowStateChange()
                    }
                }
                let willDeactivate = center.addObserver(
                    forName: UIScene.willDeactivateNotification,
                    object: scene,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        #if !targetEnvironment(macCatalyst)
                        self?.isPreservingResponderAcrossSceneDeactivation = true
                        #endif
                        self?.syncFocusForWindowStateChange(sceneIsDeactivating: true)
                    }
                }
                windowFocusObservers.append(contentsOf: [didActivate, willDeactivate])
            }
        }
        
        private func unregisterWindowFocusObservers() {
            guard !windowFocusObservers.isEmpty else { return }
            let center = NotificationCenter.default
            for token in windowFocusObservers {
                center.removeObserver(token)
            }
            windowFocusObservers.removeAll()
            observedWindow = nil
            observedScene = nil
        }
        
        /// Background queue for Ghostty surface API calls that may block on the termio mailbox.
        /// When the mailbox is full (e.g., during heavy zellij output), calls like `ghostty_surface_set_focus`,
        /// `ghostty_surface_mouse_button`, and `ghostty_surface_key` can block indefinitely.
        /// By dispatching to this background queue, we keep the main thread free to run `appTick()`,
        /// which drains the mailbox and prevents deadlocks.
        nonisolated static let ghosttyAPIQueue = DispatchQueue(label: "com.rootshell.surface.api", qos: .userInitiated)

        /// Send mouse button event to Ghostty on background queue to avoid blocking main thread.
        func sendMouseButton(
            _ action: ghostty_input_mouse_state_e,
            button: ghostty_input_mouse_button_e,
            mods: ghostty_input_mods_e = Ghostty.Input.Mods.none.cMods
        ) {
            guard let surface = surface else { return }
            Self.ghosttyAPIQueue.async {
                ghostty_surface_mouse_button(surface, action, button, mods)
            }
        }

        /// Send mouse scroll event to Ghostty on background queue to avoid blocking main thread.
        func sendMouseScroll(deltaX: Double, deltaY: Double, mods: ghostty_input_scroll_mods_t = Ghostty.Input.ScrollMods.none.cMods) {
            guard let surface = surface else { return }
            Self.ghosttyAPIQueue.async {
                ghostty_surface_mouse_scroll(surface, deltaX, deltaY, mods)
            }
        }

        /// Set Ghostty's visual vertical scroll offset for smooth primary
        /// scrollback.
        func setSmoothScrollOffset(_ offset: CGFloat) {
            let normalizedOffset = max(0, offset)
            smoothScrollOffset = normalizedOffset
            smoothScrollActive = normalizedOffset > 0
            guard let surface = surface else { return }
            ghostty_surface_set_smooth_scroll_offset(surface, Double(normalizedOffset))
        }

        /// Set Ghostty's render-only signed rubber-band offset.
        func setRubberBandOffset(_ offset: CGFloat) {
            guard let surface = surface else { return }
            ghostty_surface_set_rubber_band_offset(surface, Double(offset))
        }

        /// Atomically scroll Ghostty to an absolute row and apply a render-only
        /// vertical offset for smooth primary scrollback.
        func scrollToRowSmooth(row: Int, offset: CGFloat) {
            let normalizedOffset = max(0, offset)
            smoothScrollOffset = normalizedOffset
            let bottomRow = scrollbarTotal > scrollbarLen ? Int(scrollbarTotal - scrollbarLen) : 0
            smoothScrollActive = normalizedOffset > 0 || row < bottomRow
            guard let surface = surface else { return }
            ghostty_surface_scroll_to_row_smooth(surface, UInt(row), Double(normalizedOffset))
        }

        /// The portion of this surface's drawable that overlaps the window's
        /// bottom safe-area strip (the home-indicator region), in framebuffer
        /// pixels. We reserve this as a bottom inset so the grid stays above the
        /// strip while the drawable covers it, letting smooth-scroll overscan
        /// rows fill it on scrollback. Returns 0 when the terminal ends above the
        /// strip (keyboard/toolbar up pushes it up), when a bottom-rendering
        /// effect owns the strip (ocean/solar waves), or on platforms without a
        /// strip (macOS, home-button devices).
        func currentBottomInsetPixels() -> Double {
            if EffectManager.shared.terminalBottomInsetFraction > 0 { return 0 }
            #if !targetEnvironment(macCatalyst) && !os(visionOS)
            // Reserve the home-indicator strip by default: it keeps a touch-safe
            // gap so the system home-swipe gesture doesn't intercept touches meant
            // for text selection near the bottom edge. This is intentionally
            // independent of Full Screen mode — the gesture is live even when the
            // indicator is dimmed/hidden, so the gap is still needed there. The
            // "Extend Under Home Indicator" setting lets the user drop the
            // reservation and run edge-to-edge.
            if PaddingManager.shared.extendUnderHomeIndicator { return 0 }
            #endif
            guard let window = self.window else { return 0 }
            #if !targetEnvironment(macCatalyst)
            // External content renders on a screen with no home indicator; in
            // control mode the zoom container already keeps it clear.
            if isExternalDisplayTerminal { return 0 }
            #endif
            let safeBottom = window.safeAreaInsets.bottom
            guard safeBottom > 0 else { return 0 }
            let frameInWindow = self.convert(self.bounds, to: window)
            let stripTop = window.bounds.maxY - safeBottom
            let overlap = min(max(0, frameInWindow.maxY - stripTop), safeBottom)
            let scale = contentScaleFactor
            guard scale > 0 else { return 0 }
            return Double(overlap * scale)
        }

        /// Push the current bottom inset to the core so the grid reserves the
        /// home-indicator strip (the drawable covers it; smooth-scroll overscan
        /// fills it on scrollback). Deduped, so it is safe to call on every
        /// layout pass.
        func updateBottomInset() {
            surfaceController.updateBottomInset()
        }

        /// Toggle mouse reporting via ghostty's built-in action.
        /// This flips `config.mouse_reporting` inside ghostty so that
        /// `ghostty_surface_mouse_captured()` returns false and mouse events
        /// are treated as selection instead of being reported to the program.
        func toggleMouseReporting() {
            guard let surface = surface else { return }
            mouseCaptureOverrideActive.toggle()
            activeToolbarView?.setMouseCaptureOverrideActive(mouseCaptureOverrideActive)

            // Call toggle_mouse_reporting synchronously so ghostty's internal
            // config.mouse_reporting flips immediately. This makes
            // ghostty_surface_mouse_captured() return the correct value
            // before any subsequent touch/hitTest queries.
            let action = "toggle_mouse_reporting"
            action.withCString { cString in
                _ = ghostty_surface_binding_action(surface, cString, UInt(action.utf8.count))
            }

            // Sync cached isMouseCaptured from ghostty's now-updated state
            updateMouseCaptureState()

            #if !targetEnvironment(macCatalyst)
            showMouseCaptureOverlay()
            #endif
        }

        /// Dispatch a terminal binding action off the main thread so heavy
        /// mailbox contention doesn't block UI responsiveness.
        func performActionAsync(_ action: String) {
            guard let surface = surface else { return }
            let len = action.utf8CString.count
            if len == 0 { return }

            if Self.actionRevealsScrollIndicator(action) {
                noteUserScrollForScrollIndicator()
            }

            Self.ghosttyAPIQueue.async { [weak self] in
                let performed = action.withCString { cString in
                    ghostty_surface_binding_action(surface, cString, UInt(len - 1))
                }

                #if !targetEnvironment(macCatalyst)
                guard performed else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleSelectionHandleSync(afterGhosttyAppTick: true)
                }
                #endif
            }
        }

        #if !targetEnvironment(macCatalyst)
        /// The external terminal this view's input is forwarded to while the
        /// external display owns typing focus. Nil for external terminals
        /// themselves (they are the target).
        var externalInputRedirectTarget: Ghostty.TerminalView? {
            guard !isExternalDisplayTerminal else { return nil }
            let target = ExternalDisplayManager.shared.redirectTarget()
            guard target !== self else { return nil }
            return target
        }

        /// Cursor-focus visuals for a parked external terminal receiving
        /// forwarded input; never touches first responder.
        func setRemoteInputFocus(_ focused: Bool) {
            applyGhosttyFocus(focused)
        }
        #endif

        private func applyGhosttyFocus(_ focused: Bool) {
            guard let surface = surface else { return }

            // Dispatch focus change to background queue to prevent main thread deadlock.
            // The termio mailbox can become full during heavy I/O (e.g., zellij startup),
            // causing ghostty_surface_set_focus to block indefinitely. By running on a
            // background queue, the main thread stays responsive for appTick().
            Self.ghosttyAPIQueue.async {
                ghostty_surface_set_focus(surface, focused)
            }

            // Refresh can stay on main thread - it just schedules a redraw
            ghostty_surface_refresh(surface)

            // Update shader animation based on focus state
            updateShaderAnimation(focused: focused)
        }

        #if !targetEnvironment(macCatalyst)
        private func selectionUIIsOccluded() -> Bool {
            selectionUIExternallyOccluded
                || selectionUISwipeSuppressed
                || isModalPresented()
                || aiAgentOverlayActive
                || themePickerOverlayActive
                || showsReconnectionOverlay
                || showComposeOverlay
                || searchState != nil
        }

        func selectionHandlesCanBePresented() -> Bool {
            // Parked external terminals never hold UIKit focus; follow the
            // manager's remote-focus oracle instead.
            if isExternalDisplayTerminal,
               !ExternalDisplayManager.shared.isControlSurfaceActive {
                return isTabVisible
                    && isLogicallyFocused
                    && ExternalDisplayManager.shared.remoteFocusApplies(to: self)
                    && window != nil
                    && !selectionUIIsOccluded()
            }
            return isTabVisible
                && isLogicallyFocused
                && windowIsActiveForFocus()
                && window != nil
                && !selectionUIIsOccluded()
        }

        func setSelectionUIExternallyOccluded(_ occluded: Bool) {
            guard selectionUIExternallyOccluded != occluded else { return }
            selectionUIExternallyOccluded = occluded
            pointerInteraction?.invalidate()
            if occluded {
                removeSelectionHandleViewsFromWindow()
                hideSelectionHandles(animated: false)
                hideSelectionMagnifier(animated: false)
            } else {
                scheduleSelectionHandleSync(afterGhosttyAppTick: true)
            }
        }

        /// Suppress selection-handle presentation while this tab slides during
        /// an app-tab swipe, then restore it once the slide settles. On suppress
        /// the existing window-anchored handles are torn down (they can't follow
        /// the `.offset(x:)` slide); on release they're recreated at the final,
        /// settled geometry — so they appear once, in the right place, instead of
        /// flashing at the mid-slide position and then jumping.
        func setSelectionUISwipeSuppressed(_ suppressed: Bool) {
            guard selectionUISwipeSuppressed != suppressed else { return }
            selectionUISwipeSuppressed = suppressed
            if suppressed {
                removeSelectionHandleViewsFromWindow()
                hideSelectionHandles(animated: false)
                hideSelectionMagnifier(animated: false)
            } else {
                resyncSelectionHandlesAfterGeometryChange()
            }
        }

        func syncSelectionHandlesForSurfaceActivity() {
            let activeSurface = selectionHandlesCanBePresented()
            if !activeSurface {
                hideSelectionMagnifier(animated: false)
            }
            syncSelectionHandleVisibility(forActiveSurface: activeSurface)
        }

        func scheduleSelectionHandleSync(afterGhosttyAppTick: Bool = false) {
            guard !selectionHandleSyncPending else { return }
            selectionHandleSyncPending = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selectionHandleSyncPending = false
                if afterGhosttyAppTick {
                    self.ghosttyApp?.appTick()
                }
                self.syncSelectionHandlesForSurfaceActivity()
            }
        }

        /// Re-evaluate selection-handle visibility AND reposition the handles
        /// after a deferred geometry change that doesn't trigger layoutSubviews —
        /// e.g. an app-tab swipe settling its `.offset(x:)` slide back to 0.
        ///
        /// The handles are window-anchored and positioned via `convert(_:to:
        /// window)`, so they were placed against the terminal's mid-slide
        /// (translated) frame and stay there once the slide ends: visible but in
        /// the wrong place until a drag forces `updateSelectionHandlePositions`.
        /// Running both passes here snaps them to their final position. Dispatched
        /// async so it runs after the offset has settled to 0.
        func resyncSelectionHandlesAfterGeometryChange() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.syncSelectionHandlesForSurfaceActivity()
                if self.selectionHandlesVisible {
                    self.updateSelectionHandlePositions()
                }
            }
        }
        #endif

        /// Notify Ghostty of surface visibility (occlusion) state.
        /// When occluded (visible=false), the internal IOSDisplayLink stops
        /// and the renderer thread drops to low priority, saving GPU resources.
        /// Also notifies the session for CPU throttling (e.g., Mosh sessions).
        override func setOcclusion(_ visible: Bool) {
            Ghostty.logger.info("setOcclusion(\(visible)): terminal=\(self.uuid.uuidString.prefix(8))")
            isTabVisible = visible
            if visible {
                updateShaderAnimation(focused: isLogicallyFocused)
            } else {
                stopShaderAnimation()
                cancelMomentumScrolling()
                stopRightClickMonitoring()
            }
            #if targetEnvironment(macCatalyst)
            if !visible {
                clearCursorRegistration()
            }
            #else
            syncSelectionHandlesForSurfaceActivity()
            #endif

            // Notify session of visibility change for CPU throttling
            session?.setTabVisible(visible)

            surfaceController.setOcclusion(visible)
        }

        /// Backstop re-assert used by the tab-switch + foreground reconcile paths
        /// to guarantee a surface that should be on-screen is actually un-occluded
        /// and (when it should be focused) holds first responder.
        ///
        /// Post the GhosttyKit merge a surface stranded at `flags.visible == false`
        /// hard-stops its render thread (a permanent freeze, not a soft pause).
        /// `setOcclusion(true)` silently no-ops when the surface was briefly nil at
        /// the original switch and never retries; `becomeFirstResponder()` can be
        /// refused mid scene/keyboard event. This recovers both: re-asserting
        /// occlusion is a cheap core no-op when already visible (the renderer drops
        /// same-value `.visible` messages), and the focus retry funnels through the
        /// same gates (`overlayOwnsKeyboard`, modal, `windowIsActiveForFocus`) as
        /// every other claimer, so it is a correct no-op when focus must not move.
        ///
        /// Returns `true` when a first-responder retry was actually attempted.
        @discardableResult
        func reassertVisibleIfNeeded(shouldFocus: Bool, reason: String) -> Bool {
            // Always re-push occlusion=true; only does real work in the freeze case.
            setOcclusion(true)

            let surfaceAlive = surface != nil
            // Real render-thread liveness (not the Swift-side `isTabVisible`
            // belief): a frozen tab that logs vsyncRunning=true with a large
            // vsyncTickAgeMs is the CADisplayLink wedge captured directly.
            var vsyncRunning = false
            var vsyncTickAgeMs: Int64 = -1
            if let s = surface {
                vsyncRunning = ghostty_surface_vsync_running(s)
                vsyncTickAgeMs = ghostty_surface_vsync_last_tick_age_ms(s)
            }
            var winActive = windowIsActiveForFocus()
            var healedOverride = false
            var focusRetried = false
            if shouldFocus,
               isLogicallyFocused,
               !isFirstResponder,
               !overlayOwnsKeyboard,
               !isModalPresented() {
                // A `windowActiveOverride` stuck `false` (a terminal that missed a
                // `setWindowActive(true)` propagation) blocks first responder even
                // though the window is genuinely active. Heal it from ground truth
                // so focus can land — the focus-half of the freeze on non-active
                // tabs. `setWindowActive` itself reconciles first responder, and the
                // explicit retry below is belt-and-suspenders.
                if !winActive, windowGenuineFocusSignal() {
                    healedOverride = true
                    setWindowActive(true)
                    winActive = windowIsActiveForFocus()
                }
                if winActive {
                    focusRetried = true
                    _ = focusDidChange(true)
                }
            }

            LifecycleDebugLogger.shared.checkpoint("FG.tabSwitch.reassert.surface", ms: nil, [
                ("reason", reason),
                ("terminal", String(self.uuid.uuidString.prefix(8))),
                ("shouldFocus", shouldFocus),
                ("surface", surfaceAlive),
                ("isTabVisible", isTabVisible),
                ("isFR", isFirstResponder),
                ("logical", isLogicallyFocused),
                ("overlayKbd", overlayOwnsKeyboard),
                ("winActive", winActive),
                ("healedOverride", healedOverride),
                ("focusRetried", focusRetried),
                ("vsyncRunning", vsyncRunning),
                ("vsyncTickAgeMs", vsyncTickAgeMs),
            ])
            return focusRetried
        }

        /// Deterministically pauses renderer-owned work from the deferred
        /// background transition before persistence and suspend-oriented
        /// cleanup continue.
        @discardableResult
        override func pauseRendererForBackground(timeoutNanoseconds: UInt64 = 200_000_000) -> Bool {
            isTabVisible = false
            stopShaderAnimation()
            cancelMomentumScrolling()
            stopRightClickMonitoring()

            #if targetEnvironment(macCatalyst)
            clearCursorRegistration()
            #endif

            // Notify session of visibility change for CPU throttling.
            session?.setTabVisible(false)

            return surfaceController.pauseRendererForBackground(timeoutNanoseconds: timeoutNanoseconds)
        }

        /// Synchronously pause this surface's renderer before iOS suspends
        /// the app. Called from the main thread at the very top of the
        /// background scene-transition path. Returns true if the renderer
        /// was confirmed paused within the timeout.
        ///
        /// On the C side this:
        ///   1. Stops the per-surface CADisplayLink on the main thread
        ///      (ghostty_surface_set_occlusion → renderer.setVisible →
        ///      IOSDisplayLink.stop, which now hops to main if not already
        ///      there).
        ///   2. Pushes a `drain_to_idle` ack the renderer thread signals
        ///      after processing the pause, confirming no further drawFrame
        ///      will run.
        ///
        /// This closes the race where iOS could suspend us with a Metal
        /// commit still in flight or a CADisplayLink still attached to the
        /// main run loop in an inconsistent state — the documented cause
        /// of the "one frame per touch" wedge users hit on scene resume.
        @discardableResult
        func drainRendererToIdleSync(timeoutNanoseconds: UInt64 = 200_000_000) -> Bool {
            isTabVisible = false
            return surfaceController.drainRendererToIdleSync(timeoutNanoseconds: timeoutNanoseconds)
        }

        func requestRendererDrainToIdleAsync(timeoutNanoseconds: UInt64 = 200_000_000) {
            isTabVisible = false
            let terminalID = uuid.uuidString
            let connection = connectionConfig.lifecycleDebugKind
            surfaceController.requestRendererDrainToIdleAsync(
                terminalID: terminalID,
                connection: connection,
                timeoutNanoseconds: timeoutNanoseconds
            )
        }

        // MARK: - Background Lifecycle

        /// Pauses reconnection UI (timers and spinners) when entering background.
        /// Prevents cursor corruption from escape sequences written while backgrounded.
        func pauseReconnectionUI() {
            // Suppress PTY size updates during background to prevent SIGWINCH cursor corruption
            suppressPTYSizeUpdates = true
            Ghostty.logger.info("pauseReconnectionUI: PTY size updates suppressed")

            sessionController.pauseReconnectionUI()

            // Tell the session itself to pause periodic work (Trzsz health
            // monitor, Citadel heartbeat probes) and to abort any in-flight
            // cleanup that's parked on a dead FD. This is the watchdog-kill
            // mitigation — a wedged session keeps work queued for the main
            // actor, and that's what trips the scene-update watchdog on
            // foreground return.
            session?.pauseForBackground()
        }

        /// Resumes reconnection UI after returning from background.
        func resumeReconnectionUI() {
            // Re-enable PTY size updates now that we're back in foreground
            clearSizeSuppression()

            sessionController.resumeReconnectionUI()

            // Re-arm session-level periodic work paused in pauseReconnectionUI.
            session?.resumeForForeground()

            updateShaderAnimation(focused: isLogicallyFocused)
        }

        /// Clears the size suppression flag. Called immediately when scene becomes active
        /// to ensure layout passes don't get incorrectly suppressed.
        func clearSizeSuppression() {
            if surfaceController.clearSizeSuppression() {
                Ghostty.logger.info("clearSizeSuppression: PTY size updates re-enabled")
            }

            // Force a fresh size sync. UIKit may have laid out views during
            // the foreground scene-update transaction (rotation, multitasking,
            // keyboard show/hide while we were backgrounded), but those
            // sizeDidChange calls were suppressed by the atomic / suppress
            // gates above. Now that suppression is cleared, UIKit will not
            // re-fire layout on its own — push current dims through
            // ghostty_surface_set_size + updatePTYSize so both ghostty's grid
            // and the shell's tty know the correct size. Without this the
            // shell wedges at whatever dim was last seen pre-background and
            // helix / cursor render is corrupt until the user manually
            // triggers a real resize.
            surfaceController.invalidateCachedSize()
            sizeDidChange(bounds.size)
        }

        /// Clears stale touch/selection state when entering background.
        /// Prevents ghost selections from touches that were interrupted by app switch.
        func clearTouchState() {
            let preserveTouchSelection: Bool
            if let surface {
                preserveTouchSelection = ghostty_surface_has_selection(surface)
            } else {
                preserveTouchSelection = false
            }

            isSelecting = false
            selectionStartPoint = nil
            mousePressed = false
            #if !targetEnvironment(macCatalyst)
            selectionStartedFromPan = false
            suppressSelectionUntilTouchEnd = false
            isSelectionDelayPending = false
            selectionDelayTimer?.invalidate()
            selectionDelayTimer = nil
            fingerDragActive = false
            if !preserveTouchSelection {
                selectionWasTouchInitiated = false
            }
            #endif
        }

        // MARK: - Shader Animation (CADisplayLink)

        private func setupShaderAnimationObserver() {
            shaderAnimationController.setupActivationObserver()
        }

        private func updateShaderAnimation(focused: Bool) {
            shaderAnimationController.update(focused: focused)
        }

        private func stopShaderAnimation(graceful: Bool = false) {
            shaderAnimationController.stop(graceful: graceful)
        }

        func notifyTerminalActivity() {
            shaderAnimationController.notifyTerminalActivity()
        }

        /// Check if a modal/sheet is presented over the root view controller
        private func isModalPresented() -> Bool {
            guard let rootVC = window?.rootViewController else { return false }
            return rootVC.presentedViewController != nil
        }

        private func syncFocusForWindowStateChange(sceneIsDeactivating: Bool = false) {
            #if !targetEnvironment(macCatalyst)
            // Parked external: cursor follows the remote-focus oracle; no first
            // responder or KeyboardTracker interaction. Control mode falls through.
            if isExternalDisplayTerminal,
               !ExternalDisplayManager.shared.isControlSurfaceActive {
                applyGhosttyFocus(ExternalDisplayManager.shared.remoteFocusApplies(to: self))
                syncSelectionHandlesForSurfaceActivity()
                return
            }
            #endif
            let windowActive = windowIsActiveForFocus()
            #if !targetEnvironment(macCatalyst)
            if (!windowActive || sceneIsDeactivating),
               shouldPreserveFirstResponderForSoftwareKeyboardAppTransition(sceneIsDeactivating: sceneIsDeactivating) {
                applyGhosttyFocus(true)
                return
            }
            #endif

            let shouldFocus = windowActive && (isLogicallyFocused || shouldBecomeFirstResponderWhenReady)
            // The rendered cursor (surface focus) follows LOGICAL focus only.
            // `shouldBecomeFirstResponderWhenReady` stays part of shouldFocus
            // so it can still drive the become-attempt below, but it must not
            // paint an active cursor: an armed-but-unconsumed flag on a
            // non-focused pane (armed by a bare becomeFirstResponder caller
            // that then failed, or pending a window event) would otherwise
            // light up a second active cursor on every window event / view
            // reparent — visible as two focused cursors across tmux splits in
            // one tab. Every legitimate focus path sets isLogicallyFocused
            // alongside the flag, so real focus is unaffected.
            // ROOTSHELL-TMUX (id=tmux-focus-cursor-logical-only)
            applyGhosttyFocus(windowActive && isLogicallyFocused)
            #if !targetEnvironment(macCatalyst)
            if windowActive {
                scheduleSelectionHandleSync(afterGhosttyAppTick: true)
            } else {
                syncSelectionHandlesForSurfaceActivity()
            }
            #endif

            if shouldFocus {
                shouldBecomeFirstResponderWhenReady = false
                // Don't steal focus if a sheet/modal is presented - this prevents
                // keyboard from appearing over Settings, PIN dialogs, etc.
                if isModalPresented() {
                    Ghostty.logger.info("syncFocusForWindowStateChange: skipping focus - modal presented")
                    return
                }
                // Same for an in-hierarchy keyboard-owning overlay (the tab
                // sidebar isn't a presented VC, so isModalPresented() misses
                // it). becomeFirstResponder() would refuse anyway; bail early
                // to skip the +0.05s retry churn while the overlay is up.
                if overlayOwnsKeyboard {
                    return
                }
                if window != nil && !isFirstResponder {
                    let result = becomeFirstResponder()
                    if result {
                        reloadInputViews()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                            guard let self = self else { return }
                            guard self.windowIsActiveForFocus(),
                                  self.isLogicallyFocused,
                                  !self.isFirstResponder else { return }
                            // Also check for modal in retry path
                            if self.isModalPresented() {
                                Ghostty.logger.info("syncFocusForWindowStateChange retry: skipping focus - modal presented")
                                return
                            }
                            let retryResult = self.becomeFirstResponder()
                            if retryResult {
                                self.reloadInputViews()
                            }
                        }
                    }
                }
            } else {
                #if targetEnvironment(macCatalyst)
                clearCursorRegistration()
                #endif
                resetKeyboardInteractionState(sendSyntheticKeyReleases: true)
                if isFirstResponder {
                    _ = resignFirstResponder()
                }
            }
        }

        /// Clear a stale "focused" cursor on a pane that is not actually
        /// focused. A pane can be left with surface focus = true but no
        /// first-responder status when a focus attempt half-completed (the
        /// immediate cursor-true in focusDidChange(true) with a failed
        /// becomeFirstResponder, or a window event on a flag-armed pane).
        /// Only the focused-pane bookkeeping (`tab.focusedTerminal`) gets a
        /// paired unfocus, so any other pane's stray cursor persists —
        /// rendered as multiple active cursors across tmux splits. Safe to
        /// call broadly: no-op for the real focused pane.
        /// ROOTSHELL-TMUX (id=tmux-focus-cursor-sweep)
        func clearStaleGhosttyFocus() {
            guard !isLogicallyFocused, !isFirstResponder else { return }
            applyGhosttyFocus(false)
        }

        /// Re-assert UIKit first responder for the pane that is logically
        /// focused. Idempotent and safe to call repeatedly: every precondition
        /// is re-checked, so it cannot steal focus from a pane the user has
        /// since selected (`isLogicallyFocused` goes false via
        /// `setFocusedTerminal` / `focusPane`). Driven by TmuxController's
        /// focus watchdog after a tmux reconcile, whose split-tree rebuild can
        /// transiently defeat the one-shot retries in
        /// `syncFocusForWindowStateChange` / `didMoveToWindow`.
        /// ROOTSHELL-TMUX (id=tmux-focus-reassert)
        @discardableResult
        func reassertFirstResponderIfFocused() -> Bool {
            if isFirstResponder { return true }
            guard isLogicallyFocused,
                  window != nil,
                  windowIsActiveForFocus(),
                  !overlayOwnsKeyboard,
                  !isModalPresented() else { return false }
            if becomeFirstResponder() {
                // Consume the one-shot hint here too: every other successful
                // acquisition path consumes it, and a stale true would let a
                // later window-key event re-focus this pane after the user
                // moved on.
                shouldBecomeFirstResponderWhenReady = false
                reloadInputViews()
            }
            return isFirstResponder
        }

        #if !targetEnvironment(macCatalyst)
        private func shouldPreserveFirstResponderForSoftwareKeyboardAppTransition(
            sceneIsDeactivating: Bool = false
        ) -> Bool {
            let tracker = KeyboardTracker.shared
            guard isLogicallyFocused,
                  !tracker.isHardwareKeyboard else {
                return false
            }

            let keyboardWasVisibleOrPreserving =
                tracker.isSoftwareKeyboardVisible ||
                tracker.isPreservingSoftwareKeyboardForAppTransition
            guard keyboardWasVisibleOrPreserving else { return false }

            let appOrSceneIsLeaving =
                sceneIsDeactivating ||
                isPreservingResponderAcrossSceneDeactivation ||
                UIApplication.shared.applicationState != .active ||
                window?.windowScene?.activationState != .foregroundActive

            return appOrSceneIsLeaving
        }
        #endif

        /// Set up subscription to theme override changes
        func setupThemeOverrideSubscription() {
            ThemeOverrideManager.shared.overridesDidChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] change in
                    self?.handleThemeOverrideChange(change)
                }
                .store(in: &cancellables)
        }

        /// Handle theme override changes - refresh surface theme if this surface is affected
        private func handleThemeOverrideChange(_ change: ThemeOverrideManager.ThemeOverrideChange) {
            guard let surface = self.surface else { return }

            // Check if this change affects us
            let isAffected: Bool
            switch change.scope {
            case .tab:
                // Tab change affects us if our tab ID matches
                isAffected = containingTabID?.uuidString == change.id
            case .window:
                // Window change affects us if our window ID matches
                isAffected = windowId == change.id
            }

            if isAffected {
                Ghostty.logger.info("Theme override changed for this surface, refreshing theme")
                ghosttyAppRef?.refreshSurfaceTheme(surface, tabId: containingTabID, windowId: windowId)
            }
        }

        override func retargetWindow(to newWindowId: String) {
            guard windowId != newWindowId else { return }
            windowId = newWindowId
            guard let surface else { return }
            ghosttyAppRef?.registerSurfaceWindow(surface, windowId: newWindowId)
            ghosttyAppRef?.refreshSurfaceTheme(surface, tabId: containingTabID, windowId: newWindowId)
        }

        // MARK: - Input Mode Indicator

        #if !targetEnvironment(macCatalyst)
        private func handleInputModeChange() {
            guard isFirstResponder else { return }

            refreshHardwareInputSourceSwitchAvailability()

            // Switching input source can re-populate the system Shortcuts bar;
            // re-clear so the language pill stays hidden across Globe presses.
            clearInputAssistantsRecursively()

            let newLang = textInputMode?.primaryLanguage
            guard newLang != lastInputModePrimaryLanguage else { return }
            lastInputModePrimaryLanguage = newLang

            // Skip the first change — it fires when the view becomes first responder
            // or on app launch, not from a user-initiated Globe key press.
            inputModeChangeCount += 1
            guard inputModeChangeCount > 1 else { return }

            guard let lang = newLang else { return }
            let displayName = Locale.current.localizedString(forIdentifier: lang) ?? lang
            showInputModeOverlay(displayName)
        }

        private func refreshHardwareInputSourceSwitchAvailability() {
            #if os(visionOS)
            hasHardwareInputSourceSwitchAvailable = false
            #else
            let inputModeCount = UITextInputMode.activeInputModes
                .compactMap(\.primaryLanguage)
                .count
            hasHardwareInputSourceSwitchAvailable = inputModeCount > 1
            #endif
        }

        func showInputModeOverlay(_ text: String) {
            inputModeDismissTask?.cancel()

            if let host = inputModeOverlayHost {
                // Update existing overlay
                host.rootView = InputModeOverlayView(text: text)
                host.view.layer.removeAllAnimations()
                host.view.alpha = 1.0
            } else {
                // Create overlay using same hosting pattern as DimensionOverlayView
                let host = UIHostingController(rootView: InputModeOverlayView(text: text))
                host.sizingOptions = [.intrinsicContentSize]
                host.view.backgroundColor = .clear
                host.view.translatesAutoresizingMaskIntoConstraints = false

                addSubview(host.view)
                NSLayoutConstraint.activate([
                    host.view.centerXAnchor.constraint(equalTo: centerXAnchor),
                    host.view.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
                inputModeOverlayHost = host

                host.view.alpha = 0
                UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
                    host.view.alpha = 1.0
                }
            }

            // Auto-dismiss after 0.5s
            inputModeDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.hideInputModeOverlay()
            }
        }

        private func hideInputModeOverlay() {
            guard let host = inputModeOverlayHost else { return }
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn, animations: {
                host.view.alpha = 0
            }, completion: { [weak self] _ in
                host.view.removeFromSuperview()
                self?.inputModeOverlayHost = nil
            })
        }

        // MARK: - Mouse Capture Override Overlay

        private func showMouseCaptureOverlay() {
            let text = mouseCaptureOverrideActive
                ? String(localized: "Mouse Capture Off")
                : String(localized: "Mouse Capture On")

            mouseCaptureOverlayDismissTask?.cancel()

            if let host = mouseCaptureOverlayHost {
                host.rootView = InputModeOverlayView(text: text)
                host.view.layer.removeAllAnimations()
                host.view.alpha = 1.0
            } else {
                let host = UIHostingController(rootView: InputModeOverlayView(text: text))
                host.sizingOptions = [.intrinsicContentSize]
                host.view.backgroundColor = .clear
                host.view.translatesAutoresizingMaskIntoConstraints = false

                addSubview(host.view)
                NSLayoutConstraint.activate([
                    host.view.centerXAnchor.constraint(equalTo: centerXAnchor),
                    host.view.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
                mouseCaptureOverlayHost = host

                host.view.alpha = 0
                UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
                    host.view.alpha = 1.0
                }
            }

            mouseCaptureOverlayDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.hideMouseCaptureOverlay()
            }
        }

        private func hideMouseCaptureOverlay() {
            guard let host = mouseCaptureOverlayHost else { return }
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn, animations: {
                host.view.alpha = 0
            }, completion: { [weak self] _ in
                host.view.removeFromSuperview()
                self?.mouseCaptureOverlayHost = nil
            })
        }
        #endif

        /// Sets whether the AI Agent overlay is active for this terminal's tab.
        /// When active, the keyboard toolbar is suppressed.
        func setAIAgentOverlayActive(_ active: Bool) {
            guard aiAgentOverlayActive != active else { return }
            aiAgentOverlayActive = active
            reloadInputViews()
            #if !targetEnvironment(macCatalyst)
            syncSelectionHandlesForSurfaceActivity()
            #endif
        }

        func setThemePickerOverlayActive(_ active: Bool) {
            guard themePickerOverlayActive != active else { return }
            themePickerOverlayActive = active
            #if !targetEnvironment(macCatalyst)
            syncSelectionHandlesForSurfaceActivity()
            #endif
        }

        // MARK: - UIView Overrides

        // NOTE: We do NOT override layerClass to CAMetalLayer.
        // Ghostty's Metal renderer creates and manages its own CAMetalLayer,
        // which it adds as a sublayer to our view's default layer (per Metal.zig iOS path)
        
        override func didMoveToWindow() {
            super.didMoveToWindow()

            if window == nil {
                Ghostty.logger.warning("didMoveToWindow called but window is nil!")
                unregisterWindowFocusObservers()
                applyGhosttyFocus(false)
                resetKeyboardInteractionState(sendSyntheticKeyReleases: true)
                #if !targetEnvironment(macCatalyst)
                syncSelectionHandlesForSurfaceActivity()
                #endif
                #if targetEnvironment(macCatalyst)
                clearCursorRegistration()
                #endif
                return
            }
            
            registerWindowFocusObservers()

            clearInputAssistantsRecursively()

            Ghostty.logger.info("didMoveToWindow: surface=\(self.surface != nil), isLogicallyFocused=\(self.isLogicallyFocused), shouldBecomeFirstResponderWhenReady=\(self.shouldBecomeFirstResponderWhenReady)")

            #if !targetEnvironment(macCatalyst)
            // Align scale BEFORE surface creation: the renderer freezes its layer
            // contentsScale from the scale_factor passed to ghostty_surface_new.
            let scaleChangedOnWindowMove = applyEffectiveContentScale()
            #endif

            // If we have a surface but it's not created yet (deferred), create it now
            if surface == nil {
                Ghostty.logger.info("View added to window, creating Ghostty surface now...")
                createSurface()
            }

            syncFocusForWindowStateChange()

            // Defense-in-depth for cold start: if this terminal should be focused
            // but syncFocusForWindowStateChange() didn't succeed (window not key yet),
            // schedule a backup retry.
            if isLogicallyFocused && !isFirstResponder {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self,
                          self.isLogicallyFocused,
                          !self.isFirstResponder,
                          self.window != nil else { return }
                    guard self.windowIsActiveForFocus() else { return }
                    if self.isModalPresented() { return }
                    let result = self.becomeFirstResponder()
                    if result {
                        self.reloadInputViews()
                        Ghostty.logger.info("didMoveToWindow backup retry succeeded")
                    }
                }
            }

            #if !targetEnvironment(macCatalyst)
            syncSelectionHandlesForSurfaceActivity()
            #endif

            #if !targetEnvironment(macCatalyst)
            // Boundary = content moving between device and external presentation.
            // ExternalWindow <-> ControlSurfaceWindow shares size and scale: not a
            // boundary. SplitTreeHostingView inserts before assigning the final
            // frame, so never push `frame.size` here; defer to layoutSubviews.
            let crossed = isExternalDisplayTerminal != lastWasExternalPresentation
            lastWasExternalPresentation = isExternalDisplayTerminal
            if crossed || scaleChangedOnWindowMove {
                surfaceController.invalidateCachedSize()
                pendingWindowTransitionSync = true
                setNeedsLayout()
            } else {
                sizeDidChange(frame.size)
            }
            #else
            sizeDidChange(frame.size)
            #endif
        }

        // MARK: - First Frame Readiness

        /// True once the renderer has presented at least one frame for the
        /// current surface. The core attaches an empty "IOSurfaceLayer"
        /// sublayer at surface creation; its `contents` stays nil until the
        /// renderer thread presents. Until then a freshly opened tab is fully
        /// transparent, so the tab-swap gating in TabsModel keeps the previous
        /// tab visible via `notifyOnFirstFrame`.
        var hasRenderedFirstFrame: Bool {
            surfaceController.hasRenderedFirstFrame
        }

        /// The core's renderer layer; its `contents` is the live frame's
        /// IOSurface, which a mirror layer can share (tab exposé previews).
        var rendererLayer: CALayer? {
            surfaceController.rendererLayer()
        }

        /// Invoke `callback` on the main actor once the first frame has been
        /// presented. Fires immediately if it already has.
        func notifyOnFirstFrame(_ callback: @escaping @MainActor () -> Void) {
            surfaceController.notifyOnFirstFrame(callback)
        }

        /// Re-arm tracking so a recreated surface waits for its own first
        /// frame again. Pending callbacks are dropped (the tab-swap state
        /// machine re-registers per selection change).
        func resetFirstFrameTracking() {
            surfaceController.resetFirstFrameTracking()
        }

        // MARK: - Surface Creation

        private func createSurface() {
            surfaceController.createSurfaceIfNeeded()
        }

        #if !targetEnvironment(macCatalyst)
        // MARK: - Effective Content Scale (external display)

        /// Content-based presentation of the previous didMoveToWindow.
        private var lastWasExternalPresentation = false
        /// Where the IME preedit last rendered while forwarding (nil = locally).
        weak var lastExternalPreeditTarget: Ghostty.TerminalView?
        /// Armed on a presentation boundary or scale change; consumed by the
        /// first layout pass whose sizeDidChange actually reached the surface.
        private var pendingWindowTransitionSync = false

        /// Aligns contentScaleFactor and the renderer layer's contentsScale.
        /// Returns true when the view scale changed.
        @discardableResult
        private func applyEffectiveContentScale() -> Bool {
            let target = ExternalDisplayManager.shared.effectiveScale(
                isExternalContent: isExternalDisplayTerminal, window: window)
            var changed = false
            if contentScaleFactor != target {
                contentScaleFactor = target
                changed = true
            }
            surfaceController.updateRendererLayerContentsScale(target)
            return changed
        }

        /// Live scale change in the same window (zoom preference, trait revert).
        func noteEffectiveScaleChanged() {
            guard window != nil else { return }
            if applyEffectiveContentScale() {
                surfaceController.invalidateCachedSize()
                pendingWindowTransitionSync = true
                setNeedsLayout()
            }
        }
        #endif

        override func layoutSubviews() {
            super.layoutSubviews()

            // On Mac Catalyst, batch the sublayer-frame change with the
            // surface-size update inside one CATransaction so Core Animation
            // commits the new bounds together with the synchronous draw the
            // IOSurfaceLayer triggers via needsDisplayOnBoundsChange. Without
            // this, rapid window resize can commit new layer bounds while
            // the renderer is still producing old-size frames, which then
            // get discarded by IOSurfaceLayer's size check — leaving the
            // layer with stale (smaller) contents pinned top-left.
            #if targetEnvironment(macCatalyst)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            #endif

            // FIX: Ghostty's iOS Metal renderer creates IOSurfaceLayer that doesn't auto-resize
            // Always update the sublayer frame to match view bounds
            if let sublayers = self.layer.sublayers {
                for sublayer in sublayers {
                    if sublayer.frame != self.bounds {
                        sublayer.frame = self.bounds
                    }
                }
            }

            // Update scroll indicator position when layout changes
            updateScrollIndicatorLayout()
            updateCollapsedKeyboardToolbarButtonLayout()

            // Reserve the bottom safe-area strip as a per-surface inset BEFORE
            // reporting the (now taller, safe-area-ignoring) size, so the grid is
            // computed at its final row count in one step instead of briefly
            // growing into the strip and snapping back. Deduped internally.
            updateBottomInset()

            #if !targetEnvironment(macCatalyst)
            if pendingWindowTransitionSync {
                // Re-assert scale (UIKit may have trait-reverted it), push the
                // paired scale+size against the FINAL bounds, then apply the
                // external font preference after that push. If a gate dropped
                // the push the cache stays nil and the flag stays armed.
                applyEffectiveContentScale()
                let isExternal = isExternalDisplayTerminal
                if bounds.width > 1 { sizeDidChange(bounds.size) }
                if bounds.width > 1, !surfaceController.hasPendingScaleSync {
                    pendingWindowTransitionSync = false
                    notifyOnFirstFrame { [weak self] in
                        guard let self, self.window != nil,
                              self.isExternalDisplayTerminal == isExternal else { return }
                        if isExternal {
                            ExternalDisplayManager.shared.applyExternalFontSizeIfNeeded(to: self)
                        } else {
                            ExternalDisplayManager.shared.clearExternalFontSizeIfNeeded(from: self)
                        }
                    }
                }
            } else {
                // sizeDidChange itself gates on KeyboardTracker.isKeyboardAnimating
                // so interpolated bounds during keyboard show/hide are skipped here
                // and re-applied once the animation settles.
                sizeDidChange(bounds.size)
            }
            #else
            // sizeDidChange itself gates on KeyboardTracker.isKeyboardAnimating
            // so interpolated bounds during keyboard show/hide are skipped here
            // and re-applied once the animation settles.
            sizeDidChange(bounds.size)
            #endif

            #if targetEnvironment(macCatalyst)
            CATransaction.commit()
            #endif

            #if !targetEnvironment(macCatalyst)
            if selectionHandlesVisible || selectionWasTouchInitiated || selectionMagnifierPoint != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.selectionHandlesVisible || self.selectionWasTouchInitiated {
                        self.syncSelectionHandleVisibility()
                        if self.selectionHandlesVisible {
                            self.updateSelectionHandlePositions()
                        }
                    }
                    if let point = self.selectionMagnifierPoint {
                        if let handle = self.activeHandleDrag {
                            self.updateSelectionMagnifier(at: point, for: handle)
                        } else {
                            self.updateCaptureMagnifier(at: point)
                        }
                    }
                }
            }
            #endif
        }
        
        override var canBecomeFirstResponder: Bool {
            #if !targetEnvironment(macCatalyst)
            // Parked external terminals never take first responder: the keyboard
            // would attach to the non-interactive external window.
            if isExternalDisplayTerminal,
               !ExternalDisplayManager.shared.isControlSurfaceActive {
                return false
            }
            #endif
            return true
        }

        #if targetEnvironment(macCatalyst)
        // Suppress the system focus ring on Mac Catalyst.
        // Without this, AppKit draws a blue outline around the first-responder
        // UITextInput view, which conflicts with our custom split focus border.
        override var focusEffect: UIFocusEffect? {
            get { nil }
            set { }
        }
        #endif

        @discardableResult
        override func becomeFirstResponder() -> Bool {
            #if !targetEnvironment(macCatalyst)
            // See canBecomeFirstResponder: refuse while parked on the external
            // display; legitimate in control mode (key ControlSurfaceWindow).
            if isExternalDisplayTerminal,
               !ExternalDisplayManager.shared.isControlSurfaceActive {
                return false
            }
            #endif

            // Gate: while a keyboard-owning overlay (tab sidebar, connection
            // sidebar, any sheet) is up in this window, the terminal must not
            // hold first responder — the overlay's own field owns the keyboard.
            // This single check neutralizes every async first-responder claimer
            // (focusDidChange's deferred retry, syncFocusForWindowStateChange,
            // didMoveToWindow, the tmux focus watchdog, setFocusedTerminal's
            // retry) deterministically: they all funnel here and read the live
            // flag, so a stale retry from a prior sidebar-toggle cycle is a
            // correct no-op instead of a focus thief.
            guard !overlayOwnsKeyboard else {
                Ghostty.logger.info("becomeFirstResponder() BLOCKED on terminal \(self.uuid.uuidString.prefix(8)) - overlay owns keyboard")
                return false
            }

            // Guard: Only allow becoming first responder if logically focused or pending initial focus
            // This prevents old terminals from stealing focus during view hierarchy updates
            guard isLogicallyFocused || shouldBecomeFirstResponderWhenReady else {
                Ghostty.logger.info("becomeFirstResponder() BLOCKED on terminal \(self.uuid.uuidString.prefix(8)) - not logically focused")
                return false
            }
            
            guard windowIsActiveForFocus() else {
                Ghostty.logger.info("becomeFirstResponder() BLOCKED on terminal \(self.uuid.uuidString.prefix(8)) - window inactive")
                return false
            }

            // Acquiring first responder installs our custom inputView and runs a
            // UIInputWindowController placement animation, which draws into the
            // lock snapshot while the latch is armed (FrontBoard 0x2BAD45EC).
            // Left to the foreground resume, which re-focuses from
            // `isLogicallyFocused` (preserved here) rather than a re-armed hint —
            // a stale hint on a pane that later loses focus is a focus thief.
            guard !Ghostty.isSecureDrawProhibitedAtomic else {
                Ghostty.logger.info("becomeFirstResponder() BLOCKED on terminal \(self.uuid.uuidString.prefix(8)) - secure draw prohibited")
                return false
            }

            // Re-arm pinned-hidden mode before acquiring first responder so
            // inputView already returns emptyInputView and the keyboard
            // never flashes on focus regain.
            if keyboardPinnedHidden && !toolbarOnlyMode {
                enterToolbarOnlyMode()
                keyboardAccessory?.setDismissButtonPinned(true)
            }

            let result = super.becomeFirstResponder()

            if result {
                // Consume the one-shot focus hint on EVERY successful
                // acquisition, not just the syncFocusForWindowStateChange
                // path. Bare becomeFirstResponder() callers (tab-close
                // auto-move, TmuxController.selectTab) otherwise leave it
                // armed forever, and a later view reparent (tmux split tree
                // rebuild) re-runs syncFocus where the stale flag steals
                // first responder back to an unfocused pane.
                // ROOTSHELL-TMUX (id=tmux-focus-stale-flag)
                shouldBecomeFirstResponderWhenReady = false
                clearInputAssistantsRecursively()
                EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
            }

            // Sync Ghostty surface focus when UIKit grants us focus
            // This ensures Ghostty cursor state matches UIKit even when
            // becomeFirstResponder() is called directly (e.g., from session ready callbacks)
            if result, self.surface != nil {
                Ghostty.logger.info("becomeFirstResponder() SUCCESS on terminal \(self.uuid.uuidString.prefix(8)) - setting Ghostty focus")
                applyGhosttyFocus(true)
                // Point the sequence tracker's deferred-action callback at the
                // currently focused view. didMoveToWindow fires on window entry
                // regardless of focus, so installing there would leave the
                // callback aimed at whichever view most recently entered a
                // window rather than the one actually receiving keystrokes.
                installSequenceTrackerTimeoutHandler()
            } else if !result {
                Ghostty.logger.info("becomeFirstResponder() FAILED on terminal \(self.uuid.uuidString.prefix(8)) - not setting Ghostty focus")
            }

            return result
        }

        @discardableResult
        override func resignFirstResponder() -> Bool {
            #if !targetEnvironment(macCatalyst)
            if shouldPreserveFirstResponderForSoftwareKeyboardAppTransition() {
                Ghostty.logger.info("resignFirstResponder() blocked to preserve software keyboard during app transition")
                applyGhosttyFocus(true)
                return false
            }
            #endif

            if toolbarOnlyMode {
                toolbarOnlyMode = false
                keyboardAccessory?.setDismissButtonShowsRestore(false)
            }
            if keyboardToolbarCollapsed {
                keyboardToolbarCollapsed = false
            }
            Ghostty.logger.info("resignFirstResponder() called on terminal \(self.uuid.uuidString.prefix(8))")
            let result = super.resignFirstResponder()
            if result {
                EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
            }

            // Sync Ghostty surface focus when UIKit resigns us
            // This handles auto-resign when another view becomes first responder
            if result, self.surface != nil {
                Ghostty.logger.info("resignFirstResponder() SUCCESS - clearing Ghostty focus")
                applyGhosttyFocus(false)
            }

            // Focus loss can swallow key-up events for modifiers and special keys.
            // Reset all tracked keyboard state so we don't synthesize stale modifiers
            // after the view becomes active again.
            resetKeyboardInteractionState(sendSyntheticKeyReleases: true)

            // Drop any sequence prefix we armed. Without this, a pending Ctrl+A
            // on this terminal would persist in the shared tracker and arm the
            // next-focused terminal's first keystroke.
            KeySequenceTracker.shared.resetIfOwnedBy(self)

            return result
        }

#if !os(visionOS)
        override var inputAccessoryView: UIView? {
            return keyboardAccessoryController.inputAccessoryView
        }

        override var inputView: UIView? {
            return keyboardAccessoryController.inputView
        }

        /// Set when a `reloadInputViews()` was deferred because the keyboard was
        /// mid-animation; flushed once in `keyboardDidFinishAnimationLayout()`.
        private var pendingInputViewReload = false

        override func reloadInputViews() {
            // UIKit has nothing to reload for an inactive or detached
            // responder. More importantly, iPadOS 27 may still have another
            // field's remote-keyboard placeholder installed during a responder
            // handoff; rebuilding this terminal's input set then can cross the
            // two view hierarchies and raise an uncaught Auto Layout exception.
            guard isFirstResponder, window != nil else {
                pendingInputViewReload = false
                return
            }

            // Rebuilding the input view set moves the input window placement,
            // which animates and draws. That lands in the lock snapshot while
            // the secure-draw latch is armed — FrontBoard 0x2BAD45EC.
            guard !Ghostty.isSecureDrawProhibitedAtomic else {
                pendingInputViewReload = false
                return
            }

            // iOS 27 nil-anchors the input-accessory host
            // (-[NSLayoutAnchor initWithItem:attribute:] asserts item != nil) if we
            // rebuild the input view set while a keyboard placement animation is in
            // flight. Defer and coalesce one reload to the animation-end hook.
            // (crash VA6agg6U2YLDoCuhST_j2)
            if KeyboardTracker.shared.isKeyboardAnimating {
                pendingInputViewReload = true
                return
            }
            pendingInputViewReload = false
            super.reloadInputViews()
        }

        /// Flush a reload deferred by `reloadInputViews()` while the keyboard
        /// animated. Lives in the class body (not an extension) so it can call
        /// `super`; invoked from `keyboardDidFinishAnimationLayout()`.
        fileprivate func flushPendingInputViewReloadIfNeeded() {
            guard pendingInputViewReload else { return }
            guard isFirstResponder, window != nil else {
                pendingInputViewReload = false
                return
            }
            // Same secure-mode rule as `reloadInputViews()`: never rebuild the
            // input set while the lock snapshot could capture it.
            guard !Ghostty.isSecureDrawProhibitedAtomic else {
                pendingInputViewReload = false
                return
            }
            pendingInputViewReload = false
            super.reloadInputViews()
        }
#endif

        // MARK: - Hardware Keyboard Language Pill Suppression
        //
        // iPadOS 18 draws a floating "input source" pill (the minimised
        // Shortcuts bar — Apple calls it the "language button" in user docs)
        // in a corner of the screen whenever a UITextInput-conforming view is
        // first responder, a hardware keyboard is attached, and more than one
        // input source is installed. There is no public API to hide it.
        //
        // Clearing inputAssistantItem on the view AND recursively on every
        // subview, then reapplying on the lifecycle hooks that can re-populate
        // the bar, suppresses it without breaking CJK IME composition.
        //
        // iPadOS 18's always-on pill vanished in later majors, but iPadOS 27
        // shows a sibling (globe/language + mic + return cluster) whenever an
        // Apple Pencil interacts with a focused text input and a hardware
        // keyboard is attached. Clearing the assistant groups suppresses that
        // one too; the terminal ships no shortcut-bar buttons, so there is
        // nothing to lose on any version.
        private static let suppressLanguagePill: Bool = {
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 18
        }()

        override var inputAssistantItem: UITextInputAssistantItem {
            let item = super.inputAssistantItem
            #if !os(visionOS)
            if Self.suppressLanguagePill {
                item.leadingBarButtonGroups = []
                item.trailingBarButtonGroups = []
            }
            #endif
            return item
        }

        private func clearInputAssistantsRecursively(_ view: UIView? = nil) {
            #if !os(visionOS)
            guard Self.suppressLanguagePill else { return }
            let root = view ?? self
            root.inputAssistantItem.leadingBarButtonGroups = []
            root.inputAssistantItem.trailingBarButtonGroups = []
            for subview in root.subviews {
                clearInputAssistantsRecursively(subview)
            }
            #endif
        }

        // MARK: - Text Input

        var hasText: Bool {
            return true // Terminal can always accept input
        }

        // MARK: UITextInputTraits
        // These must be stored properties (not computed) so iOS can read them
        // correctly during keyboard configuration with UITextInput.
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        var inlinePredictionType: UITextInlinePredictionType = .no
        var mathExpressionCompletionType: UITextMathExpressionCompletionType = .no
        var writingToolsBehavior: UIWritingToolsBehavior = .none
        var keyboardType: UIKeyboardType = .default

        #if targetEnvironment(macCatalyst)
        private enum CatalystNonTextInsert {
            case deleteBackward
            case arrow(String)
            case other(UInt8)
        }

        private func catalystNonTextInsert(_ text: String) -> CatalystNonTextInsert? {
            guard text.unicodeScalars.count == 1,
                  let scalar = text.unicodeScalars.first else {
                return nil
            }

            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                return nil
            case 0x08, 0x7F:
                return .deleteBackward
            case 0x1C:
                return .arrow(catalystArrowSequence(.keyboardLeftArrow))
            case 0x1D:
                return .arrow(catalystArrowSequence(.keyboardRightArrow))
            case 0x1E:
                return .arrow(catalystArrowSequence(.keyboardUpArrow))
            case 0x1F:
                return .arrow(catalystArrowSequence(.keyboardDownArrow))
            case 0x00..<0x20, 0x80...0x9F:
                return .other(UInt8(scalar.value))
            default:
                return nil
            }
        }

        private func catalystArrowSequence(_ keyCode: UIKeyboardHIDUsage) -> String {
            let appMode = surface.map { ghostty_surface_cursor_key_mode($0) } ?? false
            switch keyCode {
            case .keyboardUpArrow:
                return appMode ? "\u{1B}OA" : "\u{1B}[A"
            case .keyboardDownArrow:
                return appMode ? "\u{1B}OB" : "\u{1B}[B"
            case .keyboardRightArrow:
                return appMode ? "\u{1B}OC" : "\u{1B}[C"
            case .keyboardLeftArrow:
                return appMode ? "\u{1B}OD" : "\u{1B}[D"
            default:
                return ""
            }
        }
        #endif
        
        func insertText(_ text: String) {
            // Sentinel key names are not text. Drop before any flag is consumed.
            if KeyCode.isUIKeyInputSentinel(text) { return }

            #if !targetEnvironment(macCatalyst)
            // External display forwarding: the device terminal keeps the
            // keyboard; keystrokes act on the external terminal (or VNC pane).
            if let redirect = externalInputRedirectTarget {
                redirect.insertText(text)
                return
            }
            if !isExternalDisplayTerminal,
               ExternalDisplayManager.shared.inputProxy.forwardInsertTextToVNC(text) {
                return
            }
            #endif

            // Skip if we already handled this key in pressesBegan (OPTION+key on Catalyst)
            // The text input system sends composed characters (e.g., 'å' for Option+a) separately
            if didHandleOptionKey {
                didHandleOptionKey = false
                return
            }

            // If processKeyPress already handled a session picker digit key, skip insertText.
            if didHandleSessionPickerKey {
                didHandleSessionPickerKey = false
                return
            }

            // Intercept text input when session discovery overlay is visible.
            // Digit keys select a session by matching the session name; other text dismisses.
            if discoveredSessions != nil {
                if text.count == 1,
                   let digit = text.first?.wholeNumberValue,
                   selectSessionByDigit(digit) {
                    return
                }
                // Non-matching text: dismiss overlay, fall through to send to terminal
                dismissSessionDiscovery()
            }

            var finalText = text.precomposedStringWithCanonicalMapping
            #if targetEnvironment(macCatalyst)
            if let nonTextInsert = catalystNonTextInsert(finalText),
               koreanCompositionModel.hasActiveComposition || markedTextString != nil || InputSourceCatalog.catalystCurrentInputSourceHasLanguagePrefix(["ko"]) {
                switch nonTextInsert {
                case .deleteBackward:
                    if !handleKoreanCompositionDeleteIfNeeded() {
                        deleteBackward()
                    }
                case .arrow(let sequence):
                    commitKoreanCompositionIfNeeded(external: false)
                    if let data = sequence.data(using: .utf8) {
                        NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
                        sendUserInput(data)
                    }
                case .other(let byte):
                    commitKoreanCompositionIfNeeded(external: false)
                    NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
                    sendUserInput(Data([byte]))
                }
                return
            }
            #endif

            if handleKoreanCompositionInsertIfNeeded(finalText) {
                return
            }
            commitKoreanCompositionIfNeeded(external: false)

            // Apply dictation auto-corrections (e.g., "shell pipe" → "|")
            finalText = applyDictationReplacements(finalText)

            // Dictation often arrives as one multi-character insert and then
            // follows with committed-text replacement. Track that pattern so
            // replace(_:withText:) can allow the immediate follow-up without
            // reopening per-keystroke keyboard autocorrection.
            if text.count > 1 {
                lastBulkTextInputAt = Date()
            }

            if activeKeyboardModifiers.isEmpty,
               virtualModTapModifier == nil,
               handleThirdPartyKeyboardInsert(finalText) {
                return
            }

            // Notify that input was received (for scroll-to-bottom behavior)
            NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)

            // Handle OPTION+key on Catalyst
            // Behavior depends on optionKeyAsAlt setting:
            // - Alt mode: convert composed character to ESC + base character
            // - Character mode: send OS-translated character as-is (correct for international layouts)
            #if targetEnvironment(macCatalyst)
            if heldOptionSide != .none && text.count == 1 {
                if shouldOptionActAsAlt(),
                   let hidUsage = currentCatalystPressedPrintableHIDUsage(),
                   canEncodeCatalystPrintableKey(hidUsage) {
                    // Alt mode: suppress insertText only when the GCKeyboard path
                    // can encode the physical key. Otherwise fall through so we
                    // don't drop unsupported layout-specific characters.
                    return
                }
                // Character mode: fall through and send OS-translated character as-is
            }
            #endif

            // Double-space-for-period: when enabled, two rapid spaces become ". "
            #if !targetEnvironment(macCatalyst)
            if finalText == " ",
               UserDefaults.standard.bool(forKey: "doubleSpaceForPeriod"),
               let lastSpace = lastSpaceInsertTime,
               Date().timeIntervalSince(lastSpace) < 0.3 {
                lastSpaceInsertTime = nil
                // Delete the previous space from the terminal
                if let del = "\u{7F}".data(using: .utf8) {
                    sendUserInput(del)
                }
                // Update document buffer: remove trailing space, add ". "
                if !documentBuffer.isEmpty { documentBuffer.removeLast() }
                documentBuffer.append(". ")
                // Send ". " to the terminal
                if let data = ". ".data(using: .utf8) {
                    sendUserInput(data)
                }
                return
            }
            lastSpaceInsertTime = (finalText == " ") ? Date() : nil
            #endif

            // Track what iOS sent us for UITextInput position tracking.
            // Clear any active marked text since we're committing.
            if markedTextString != nil {
                markedTextString = nil
                markedTextSelectedRange = NSRange(location: NSNotFound, length: 0)
                syncIMEPreedit(nil)
            }

            if (finalText == "\n" || finalText == "\r"),
               (!activeKeyboardModifiers.isEmpty || virtualModTapModifier != nil),
               sendEnterKeyViaGhostty(toolbarModifiers: activeKeyboardModifiers, virtualModifier: virtualModTapModifier) {
                documentBuffer = ""
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.notifyInputDelegateOfExternalChange { /* buffer already reset */ }
                }
                activeToolbarView?.clearOneShotModifiers()
                return
            }

            documentBuffer.append(finalText)
            if documentBuffer.count > 4096 {
                documentBuffer = String(documentBuffer.suffix(2048))
            }

            // Convert newline (\n) to carriage return (\r) for terminal compatibility
            // Virtual keyboard sends \n but terminals expect \r for Enter key
            if finalText == "\n" {
                finalText = "\r"
                documentBuffer = ""  // TUI clears input on submission; keep in sync
                // iOS thinks we appended "\n" — defer notification so it re-queries
                // and sees the actual empty state after its own notification cycle completes
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.notifyInputDelegateOfExternalChange { /* buffer already reset */ }
                }
            }
            
            // Apply active toolbar modifiers to the typed character.
            // Route through Ghostty's key encoding pipeline when possible for
            // correct CSI u / kitty protocol support.
            if !activeKeyboardModifiers.isEmpty {
                Ghostty.logger.debug("TerminalView.insertText: Applying modifiers rawValue=\(self.activeKeyboardModifiers.rawValue) to '\(text)'")

                // Ctrl-C: interrupt local shell (matches hardware keyboard behavior in TerminalViewKeyboard.swift)
                #if !targetEnvironment(macCatalyst)
                if activeKeyboardModifiers.contains(.control), text.lowercased() == "c",
                   let localSession = session as? LocalShellSession,
                   !localSession.hasActiveEmbeddedSession {
                    localSession.interrupt()
                    activeToolbarView?.clearOneShotModifiers()
                    return
                }
                #endif

                // Try routing through Ghostty's key encoder first
                if text.count == 1, let char = text.first,
                   sendViaGhosttyKeyEvent(char, modifiers: activeKeyboardModifiers) {
                    activeToolbarView?.clearOneShotModifiers()
                    return
                }

                // Fallback: manually encode for keys without Ghostty mapping
                // Handle Control modifier
                if activeKeyboardModifiers.contains(.control) {
                    if text.count == 1, let char = text.first {
                        if let asciiValue = char.lowercased().first?.asciiValue,
                           asciiValue >= 97, asciiValue <= 122 {
                            // Ctrl+A through Ctrl+Z map to ASCII 1-26
                            let controlChar = asciiValue - 96
                            finalText = String(UnicodeScalar(controlChar))
                            let upper = char.uppercased()
                            Ghostty.logger.debug("TerminalView.insertText: Converted to Ctrl-\(upper) (ASCII \(controlChar))")
                        } else if let ctrlCode = Self.controlCharacterMap[char] {
                            finalText = String(UnicodeScalar(ctrlCode))
                        }
                    }
                }

                // Handle Shift+Tab → backtab escape sequence
                if activeKeyboardModifiers.contains(.shift) && finalText == "\t" {
                    finalText = "\u{1B}[Z"
                }

                // Handle Shift modifier for regular characters
                if activeKeyboardModifiers.contains(.shift) && finalText != "\t" {
                    finalText = String(finalText.map { Self.shiftedCharacter($0) })
                }

                // Handle Alt modifier (Meta key - prefix with ESC)
                if activeKeyboardModifiers.contains(.alt) {
                    if !finalText.hasPrefix("\u{1B}") {
                        finalText = "\u{1B}" + finalText
                    }
                }

                // Clear one-shot modifiers after applying (locked modifiers persist)
                activeToolbarView?.clearOneShotModifiers()
            }

            // Apply active mod-tap virtual modifier when input is routed through UITextInput.
            // This is primarily a Catalyst fallback for keys that bypass pressesBegan.
            if let virtualModifier = virtualModTapModifier {
                // Try Ghostty key encoding first for proper protocol support
                if finalText.count == 1, let char = finalText.first {
                    var modTapMods = KeyModifiers()
                    switch virtualModifier {
                    case .control: modTapMods.insert(.control)
                    case .alt: modTapMods.insert(.alt)
                    case .shift: modTapMods.insert(.shift)
                    case .command: modTapMods.insert(.command)
                    }
                    if sendViaGhosttyKeyEvent(char, modifiers: modTapMods) {
                        return
                    }
                }
                // Fallback: manual encoding
                switch virtualModifier {
                case .control:
                    if finalText.count == 1, let char = finalText.first {
                        if let asciiValue = char.lowercased().first?.asciiValue,
                           asciiValue >= 97, asciiValue <= 122 {
                            let controlChar = asciiValue - 96
                            finalText = String(UnicodeScalar(controlChar))
                        } else if let ctrlCode = Self.controlCharacterMap[char] {
                            finalText = String(UnicodeScalar(ctrlCode))
                        }
                    }
                case .alt:
                    if !finalText.hasPrefix("\u{1B}") {
                        finalText = "\u{1B}" + finalText
                    }
                case .shift:
                    finalText = String(finalText.map { Self.shiftedCharacter($0) })
                case .command:
                    break
                }
            }
            
            // Check for Ctrl-C (ASCII 3) and interrupt local shell if applicable
            #if !targetEnvironment(macCatalyst)
            if finalText == "\u{03}", let localSession = session as? LocalShellSession,
               !localSession.hasActiveEmbeddedSession {
                localSession.interrupt()
                return
            }
            #endif
            
            // Send input to Ghostty which will route it appropriately
            guard let data = finalText.data(using: .utf8) else { return }
            //Ghostty.logger.debug("TerminalView.insertText: Sending bytes: \(data.hexDescription)")
            sendUserInput(data)
        }
        
        func deleteBackward() {
            #if !targetEnvironment(macCatalyst)
            if let redirect = externalInputRedirectTarget {
                redirect.deleteBackward()
                return
            }
            if !isExternalDisplayTerminal,
               ExternalDisplayManager.shared.inputProxy.forwardDeleteBackwardToVNC() {
                return
            }
            #endif

            if handleKoreanCompositionDeleteIfNeeded() {
                return
            }

            if handleThirdPartyKeyboardDelete() {
                return
            }

            // Reset double-space tracking to avoid false triggers after backspace
            lastSpaceInsertTime = nil

            // Notify that input was received (for scroll-to-bottom behavior)
            NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)

            // Track deletion in document buffer
            if !documentBuffer.isEmpty {
                documentBuffer.removeLast()
            }

            // Send backspace/delete character (DEL = 0x7F)
            guard let data = "\u{7F}".data(using: .utf8) else { return }
            sendUserInput(data)

            // Clear one-shot modifiers (backspace consumes them too)
            activeToolbarView?.clearOneShotModifiers()
        }
        
        func handleSpecialKey(_ key: UIKey) -> String? {
            let modifiers = key.modifierFlags
            // Sentinel characters are a key name; the keyCode branches below
            // still resolve the real key.
            let characters = KeyCode.isUIKeyInputSentinel(key.characters) ? "" : key.characters

            // Check for Tab with Shift modifier FIRST (before control character check)
            // iOS converts Shift+Tab to control character 0x19, but we need to catch it as Tab
            if key.keyCode == .keyboardTab && modifiers.contains(.shift) {
                return "\u{1B}[Z" // Shift-Tab (backtab escape sequence)
            }
            
            // Check for forward delete before character fallback. Some iPadOS
            // hardware keyboards expose Forward Delete with a DEL character,
            // so checking `characters` first collapses it into backspace.
            if key.keyCode == .keyboardDeleteForward {
                return "\u{1B}[3~"
            }

            // Check for backspace/delete (DEL = 0x7F)
            if key.keyCode == .keyboardDeleteOrBackspace {
                return "\u{7F}"
            }
            if let char = characters.first, char.unicodeScalars.count == 1 {
                let scalar = char.unicodeScalars.first!
                if scalar.value == 8 {
                    return "\u{7F}"
                }
                if scalar.value == 127 {
                    // Backspace/Delete key
                    return "\u{7F}"
                }
                // Check if the character is already a control character (0x01-0x1F)
                if scalar.value >= 1 && scalar.value <= 31 {
                    // Already a control character, pass it through
                    return String(char)
                }
            }
            
            // Handle Ctrl combinations explicitly
            if modifiers.contains(.control) {
                if let char = characters.lowercased().first {
                    // Ctrl+A through Ctrl+Z map to ASCII 1-26
                    if let asciiValue = char.asciiValue, asciiValue >= 97, asciiValue <= 122 {
                        let controlChar = asciiValue - 96
                        return String(UnicodeScalar(controlChar))
                    }
                }
            }
            
            // Handle arrow keys and navigation keys
            // IMPORTANT: Don't handle keys with Command modifier - return nil to let UIKeyCommand handle them
            // This allows CMD+arrow for split navigation to work properly
            let hasCommand = modifiers.contains(.command)

            // Check cursor key application mode (DECCKM) for arrow key sequences
            // Application mode (smkx set): SS3 format \x1bOX
            // Normal mode (rmkx set): CSI format \x1b[X
            let appMode = surface.map { ghostty_surface_cursor_key_mode($0) } ?? false

            switch key.keyCode {
            // Arrow keys - use SS3 in application mode, CSI in normal mode
            // Option prefix is applied by caller
            // CTRL+arrow is handled by GCKeyboard in KeyboardTracker
            // Shift+arrow goes through UIKeyCommand -> handleArrowKey
            case .keyboardUpArrow:
                if hasCommand { return nil }
                return appMode ? "\u{1B}OA" : "\u{1B}[A"
            case .keyboardDownArrow:
                if hasCommand { return nil }
                return appMode ? "\u{1B}OB" : "\u{1B}[B"
            case .keyboardRightArrow:
                if hasCommand { return nil }
                return appMode ? "\u{1B}OC" : "\u{1B}[C"
            case .keyboardLeftArrow:
                if hasCommand { return nil }
                return appMode ? "\u{1B}OD" : "\u{1B}[D"
            case .keyboardHome:
                return hasCommand ? nil : "\u{1B}[H" // Home
            case .keyboardEnd:
                return hasCommand ? nil : "\u{1B}[F" // End
            case .keyboardPageUp:
                return hasCommand ? nil : "\u{1B}[5~" // Page Up
            case .keyboardPageDown:
                return hasCommand ? nil : "\u{1B}[6~" // Page Down
            case .keyboardDeleteForward:
                return hasCommand ? nil : "\u{1B}[3~" // Delete (forward delete)
            case .keyboardEscape:
                if aiAgentOverlayActive {
                    // If AI Agent is active, Escape should close it
                    NotificationCenter.default.post(name: .toggleAIAgent, object: self)
                    return nil
                }
                return hasCommand ? nil : "\u{1B}" // Escape
            case .keyboardTab:
                return hasCommand ? nil : "\t" // Tab
            default:
                break
            }
            
            return nil
        }
        
        // MARK: - Size Management
        
        /// Updates the PTY/SSH session with the current terminal grid size
        /// Note: Only needed for external I/O mode (SSH, iOS local shell)
        /// In Catalyst PTY mode, Ghostty manages window size internally
        func updatePTYSize() {
            guard let surfaceSize = surfaceSize else {
                if Self.logFrequentLayout {
                    Ghostty.logger.debug("   surfaceSize is nil, cannot update PTY size")
                }
                return
            }

            // Update spinner width if animating (for responsive joke truncation)
            connectionProgress.updateTerminalWidth(Int(surfaceSize.columns))

            // tmux single-pane window: the pane IS the window, so push this
            // window's per-window tmux size from the pane's OWN grid. This runs
            // after ghostty_surface_set_size, so surfaceSize is fresh — unlike
            // the split container, which would read it before the child re-laid
            // out on a bounds-only change (rotation, sidebar/tab-bar). Multi-pane
            // windows are driven by the container instead. Respect the
            // background-suppression gates (as the PTY path below does) so a
            // transient size during a scene transition isn't sent; the
            // controller dedups so repeated calls don't storm the command channel.
            if let binding = tmuxPaneBinding {
                if !surfaceController.sizeUpdatesSuppressed,
                   !tmuxPaneRetired,  // a dying pane must not size the window
                   let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
                   controller.isActive,
                   controller.isSolePane(windowId: binding.windowId) {
                    // Pin THIS window's size with its own per-window entry (base
                    // AND font-overridden windows), so it stays independent of
                    // every other window.
                    controller.pushWindowSize(
                        windowId: binding.windowId,
                        cols: surfaceSize.columns,
                        rows: surfaceSize.rows)
                    // A BASE-font, ACTIVE sole pane also refreshes the global client
                    // size (its grid IS the base viewport) — the fallback for
                    // windows with no per-window entry yet, so a just-reattached /
                    // never-visited window doesn't revert to a stale (narrow) size.
                    if controller.isActiveWindow(windowId: binding.windowId),
                       controller.overrideFontSize(forWindowId: binding.windowId) == nil {
                        controller.pushGlobalClientSize(
                            cols: surfaceSize.columns,
                            rows: surfaceSize.rows)
                    }
                }
                return
            }

            // In PTY mode (Catalyst local shell), session is nil and Ghostty handles sizing internally
            guard let session = session else {
                // Expected for Catalyst PTY mode - no action needed
                return
            }

            // If the session instance changed (e.g., reconnect), resend size even if unchanged.
            let sessionID = ObjectIdentifier(session as AnyObject)
            let gridSize = (rows: surfaceSize.rows, cols: surfaceSize.columns)
            if !surfaceController.shouldSendPTYSize(for: sessionID, gridSize: gridSize) {
                // Debug log for cursor position bug investigation
                Ghostty.logger.debug("updatePTYSize: skipped (cache hit) \(gridSize.rows)x\(gridSize.cols)")
                return
            }

            // Suppress PTY size updates during background transitions to prevent
            // cursor corruption. Two gates:
            //   - `suppressPTYSizeUpdates` is the per-terminal flag set by
            //     pauseReconnectionUI / cleared by clearSizeSuppression.
            //   - `Ghostty.isAppBackgroundedAtomic` is the synchronous global
            //     gate flipped at the entry of handleAppBackgrounded — closes
            //     the window between scenePhase=.background and the deferred
            //     performBackgroundTransition where iOS's scene-update may
            //     relayout views (App Switcher snapshot / Stage Manager /
            //     rotation) and produce intermediate-dim SIGWINCH that wedges
            //     the shell at the wrong size until a manual resize.
            if surfaceController.sizeUpdatesSuppressed {
                Ghostty.logger.info("updatePTYSize: SUPPRESSED during background transition \(gridSize.rows)x\(gridSize.cols)")
                return
            }

            // Debug log for cursor position bug investigation
            let lastSizeStr = surfaceController.lastSentPTYGridDescription
            Ghostty.logger.info("updatePTYSize: SENDING resize \(lastSizeStr) -> \(gridSize.rows)x\(gridSize.cols)")

            let scale = contentScaleFactor
            let size = bounds.size

            let ptySize = TerminalPTY.TerminalSize(
                rows: surfaceSize.rows,
                cols: surfaceSize.columns,
                pixelWidth: UInt16(size.width * scale),
                pixelHeight: UInt16(size.height * scale)
            )

            do {
                try session.setSize(ptySize)
                surfaceController.markPTYSizeSent(gridSize)
                if Self.logFrequentLayout {
                    Ghostty.logger.debug("   Sent size update to session: \(ptySize.rows)x\(ptySize.cols)")
                }
            } catch {
                Ghostty.logger.error("   Failed to set session size: \(error)")
            }
        }

        var shouldUseOutputCoalescer: Bool {
            // tmux control mode gateway: the session output IS the control
            // stream that drives every pane's reconcile + rendering, so it is
            // latency-sensitive and must not be batched. Pane surfaces render
            // from the viewer terminal and have no session at all.
            if tmuxController != nil || isTmuxPane { return false }
            switch connectionConfig {
            case .ssh, .local:
                return true
            default:
                return false
            }
        }

        private func updateOutputCoalescingState() {
            outputPipeline.updateOutputCoalescingState(
                shouldUseOutputCoalescer: shouldUseOutputCoalescer,
                isMouseCaptured: isMouseCaptured,
                fdConfigured: slaveFd >= 0
            )
        }

        func noteUserInputForOutputCoalescing() {
            outputPipeline.noteUserInputForOutputCoalescing(
                shouldUseOutputCoalescer: shouldUseOutputCoalescer,
                fdConfigured: slaveFd >= 0
            ) { [weak self] in
                guard let self else { return }
                self.updateOutputCoalescingState()
            }
        }

        /// Updates the mouse capture state and publishes changes.
        /// Called from handleScrollbar() and scroll events to detect mode changes.
        func updateMouseCaptureState() {
            guard let surface = surface else {
                if isMouseCaptured {
                    isMouseCaptured = false
                }
                return
            }
            let captured = ghostty_surface_mouse_captured(surface)
            if isMouseCaptured != captured {
                isMouseCaptured = captured
            }
        }

        func sizeDidChange(_ size: CGSize) {
            surfaceController.sizeDidChange(size)
        }
        
        /// Returns `true` when `focused == true` and `becomeFirstResponder()`
        /// succeeded synchronously (meaning UIKit already auto-resigned the
        /// previous first responder). Callers use this to decide whether
        /// `skipResign` is safe when unfocusing the old terminal.
        @discardableResult
        override func focusDidChange(_ focused: Bool, skipResign: Bool = false) -> Bool {
            // Update mouse capture state when focus changes to ensure scroll handling
            // has accurate state for this terminal (fixes split view mouse capture scrolling)
            updateMouseCaptureState()

            #if !targetEnvironment(macCatalyst)
            // Parked external: never bump MainView.focusGeneration (process-global;
            // a bump cancels the device terminal's pending first-responder retry).
            if isExternalDisplayTerminal,
               !ExternalDisplayManager.shared.isControlSurfaceActive {
                applyGhosttyFocus(focused && ExternalDisplayManager.shared.remoteFocusApplies(to: self))
                syncSelectionHandlesForSurfaceActivity()
                return true
            }
            #endif

            // Drive the iOS status-bar "scroll to top" gesture: only the single
            // globally-focused pane should opt in, otherwise the system finds
            // multiple eligible scroll views and does nothing. Setting it here
            // (for both focus and unfocus) keeps exactly one enabled across
            // splits and tab switches, since both transitions route through here.
            #if !targetEnvironment(macCatalyst)
            enclosingScrollView?.scrollsToTop = focused
            #endif

            if focused {
                // Increment GLOBAL version to invalidate any pending async focus operations
                // across ALL terminals (not just this one). Only increment when focusing so
                // that unfocusing the old terminal doesn't invalidate the new terminal's
                // async fallback.
                let capturedVersion = MainView.incrementFocusGeneration()
                guard windowIsActiveForFocus() else {
                    Ghostty.logger.info("focusDidChange(true): Window inactive, deferring focus")
                    applyGhosttyFocus(false)
                    #if !targetEnvironment(macCatalyst)
                    syncSelectionHandlesForSurfaceActivity()
                    #endif
                    return false
                }

                // Clear any desktop notifications for this terminal when it gains focus
                if !notificationIdentifiers.isEmpty {
                    NotificationManager.shared.removeNotifications(identifiers: Array(notificationIdentifiers))
                    notificationIdentifiers.removeAll()
                }

                // Set Ghostty focus immediately if surface exists
                // This is independent of UIKit first responder - we want the cursor
                // to appear focused even before becomeFirstResponder() succeeds
                if surface != nil {
                    Ghostty.logger.info("focusDidChange(true): Setting Ghostty focus immediately")
                    applyGhosttyFocus(true)
                } else {
                    Ghostty.logger.info("focusDidChange(true): No surface yet, will set focus in didMoveToWindow")
                }

                // Attempt UIKit focus - defer only if necessary
                if window != nil {
                    // View is in window, try synchronous focus
                    let result = becomeFirstResponder()
                    Ghostty.logger.info("focusDidChange(true): becomeFirstResponder() = \(result)")
                    if result {
                        #if !targetEnvironment(macCatalyst)
                        syncSelectionHandlesForSurfaceActivity()
                        #endif
                        reloadInputViews()
                        return true
                    }
                }

                // Fallback: defer to next run loop with global version check.
                // Return false because becomeFirstResponder() hasn't happened yet —
                // the old terminal must still explicitly resign.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Check GLOBAL version - any focus change anywhere will invalidate this
                    guard MainView.focusGeneration == capturedVersion else {
                        Ghostty.logger.debug("Skipping stale becomeFirstResponder (version \(capturedVersion) != \(MainView.focusGeneration))")
                        return
                    }
                    guard self.isLogicallyFocused else {
                        Ghostty.logger.debug("Skipping async becomeFirstResponder - not logically focused")
                        return
                    }
                    if self.window != nil && !self.isFirstResponder {
                        let result = self.becomeFirstResponder()
                        Ghostty.logger.info("focusDidChange async: becomeFirstResponder() = \(result)")
                        #if !targetEnvironment(macCatalyst)
                        self.syncSelectionHandlesForSurfaceActivity()
                        #endif
                        self.reloadInputViews()
                    }
                }
                return false
            } else {
                Ghostty.logger.info("focusDidChange(false): Unfocusing terminal")
                if toolbarOnlyMode {
                    toolbarOnlyMode = false
                    keyboardAccessory?.setDismissButtonShowsRestore(false)
                }
                if keyboardToolbarCollapsed {
                    keyboardToolbarCollapsed = false
                }
                applyGhosttyFocus(false)
                #if !targetEnvironment(macCatalyst)
                syncSelectionHandlesForSurfaceActivity()
                #endif
                #if targetEnvironment(macCatalyst)
                clearCursorRegistration()
                #endif
                if !skipResign {
                    // Ghostty focus is synced via resignFirstResponder() override
                    resignFirstResponder()
                }
                return true
            }
        }
    }
}

// MARK: - TerminalShaderAnimationHost

extension Ghostty.TerminalView: TerminalShaderAnimationHost {
    var shaderSurface: ghostty_surface_t? { surface }
    var shaderGhosttyApp: Ghostty.App? { ghosttyApp }
    var shaderIsLogicallyFocused: Bool { isLogicallyFocused }
    var shaderKeyboardDismissedSuppressed: Bool { keyboardDismissedShadersSuppressed }

    func shaderSyncSelectionAfterAppTick() {
        #if !targetEnvironment(macCatalyst)
        scheduleSelectionHandleSync(afterGhosttyAppTick: true)
        #endif
    }
}

// MARK: - TerminalKeyboardAccessoryHost

extension Ghostty.TerminalView: TerminalKeyboardAccessoryHost {
    var keyboardHostView: UIView { self }
    var keyboardIsFirstResponder: Bool { isFirstResponder }
    var keyboardAIAgentOverlayActive: Bool { aiAgentOverlayActive }
    var keyboardToolbarOnlyMode: Bool { toolbarOnlyMode }

    @discardableResult
    func keyboardBecomeFirstResponder() -> Bool {
        becomeFirstResponder()
    }

    @discardableResult
    func keyboardResignFirstResponder() -> Bool {
        resignFirstResponder()
    }

    func keyboardSetSoftwareKeyboardRequested(_ requested: Bool) {
        // TerminalView switches between the system keyboard and its empty
        // toolbar-only input view through `inputView` + `reloadInputViews()`.
        // The shared controller performs that reload after updating its mode.
    }

    func keyboardReloadInputViews() {
        reloadInputViews()
    }

    func keyboardStopShaderAnimationForDismiss() {
        stopShaderAnimation(graceful: false)
    }

    func keyboardSetShaderDismissSuppressed(_ suppressed: Bool) {
        keyboardDismissedShadersSuppressed = suppressed
    }

    func keyboardInvalidateKeyCommands() {
        invalidateKeyCommands()
    }

    func keyboardDidFinishAnimationLayout() {
        sizeDidChange(bounds.size)
        #if !os(visionOS)
        // Flush any input-view reload we deferred while the keyboard animated.
        flushPendingInputViewReloadIfNeeded()
        #endif
    }

    func keyboardUpdateAccessoryForTraitCollection() {
        keyboardAccessory?.updateForTraitCollection(traitCollection)
    }

    func keyboardPaste() {
        paste(nil)
    }

    func keyboardToggleCompose() {
        if showComposeOverlay {
            becomeFirstResponder()
        }
        showComposeOverlay.toggle()
        NotificationCenter.default.post(name: .ghosttyComposeStateChanged, object: self)
    }

    func keyboardToggleMouseCapture() {
        toggleMouseReporting()
    }

    func keyboardToggleBrightnessHUD() {
        toggleBrightnessHUD()
    }
}

// MARK: - GhosttyActionDelegate

extension Ghostty.TerminalView: GhosttyActionDelegate {
    func handleTitleChange(_ title: String) {
        // Coalesce rapid title changes with a timer (0.075s, like macOS)
        // This prevents flickering and excessive updates
        titleChangeTimer?.invalidate()
        titleChangeTimer = Timer.scheduledTimer(
            withTimeInterval: 0.075,
            repeats: false
        ) { [weak self] _ in
            // Timer fires on the run loop that scheduled it (main).
            MainActor.assumeIsolated {
                guard let self = self else { return }
                // Always cache the session-provided title so foreground replay has it.
                self.sessionProvidedTitle = title
                // Agent identity/state from title rules (cheap, no screen
                // read); works while backgrounded so codex's "Action
                // Required" title can notify.
                AgentAttentionCenter.shared.noteTitleChanged(terminal: self, title: title)
                // Skip the @Published write while the resume gate is up. The atomic
                // (not UIApplication state) is canonical because the gate stays
                // true through the deferred-resume window, after applicationState
                // has already flipped to .active. replayCachedSessionStateOnForeground()
                // pushes the cached value into `self.title` on resume.
                guard !Ghostty.isAppBackgroundedAtomic else { return }
                if self.userOverrideTitle == nil {
                    self.title = title
                }
                Ghostty.logger.debug("Title changed: \(title)")
            }
        }
    }

    func handleCommandFinished(exitCode: Int?, duration: TimeInterval) {
        // OSC 133 shell integration: exit code + wall time for the agent
        // inbox (failed/done rows, agent-exit identity clearing).
        AgentAttentionCenter.shared.commandFinished(
            paneUUID: uuid, exitCode: exitCode, duration: duration)
    }

    func handlePwdChange(_ pwd: String) {
        // Always cache so we don't lose the latest value while backgrounded.
        self.sessionProvidedPwd = pwd
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        self.pwd = pwd
        // Keep connectionConfig in sync (mirrors onWorkingDirectoryChange callback)
        if case .local = connectionConfig {
            connectionConfig = .local(workingDirectory: pwd)
        }
        AgentAttentionCenter.shared.notePwdChanged(terminal: self)
        Ghostty.logger.info("PWD changed: \(pwd)")
    }

    /// Pushes cached title/pwd/health into the `@Published` properties that were
    /// suppressed while the app was backgrounded. Call from the scene-phase
    /// transition back to `.active` (see `MainViewLifecycle.handleAppForegrounded`).
    /// Runs before SwiftUI's first post-resume render so stale values never
    /// reach the UI.
    func replayCachedSessionStateOnForeground() {
        if userOverrideTitle == nil,
           let cached = sessionProvidedTitle,
           cached != title {
            title = cached
        }
        if let cached = sessionProvidedPwd, cached != pwd {
            pwd = cached
            if case .local = connectionConfig {
                connectionConfig = .local(workingDirectory: cached)
            }
        }
        if sessionProvidedConnectionHealth != connectionHealth {
            connectionHealth = sessionProvidedConnectionHealth
        }
    }

    /// Applies a new connection-health value with the cache + skip-while-backgrounded
    /// + replay pattern used by `title` and `pwd`. Equality-guarded to avoid
    /// redundant @Published fires when the SSH health monitor reports the same
    /// state on consecutive ticks.
    @MainActor
    func applyConnectionHealth(_ health: ConnectionHealth?) {
        sessionProvidedConnectionHealth = health
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        // BISECT GATE 2: also gate during the post-foreground health quiet
        // window — a longer-than-general window scoped specifically to
        // health publishes. Toggle via BisectFlags.gate2_connectionHealth.
        // The cached value in sessionProvidedConnectionHealth is replayed
        // by the per-terminal foreground replay
        // (replayCachedSessionStateOnForeground), so suppressing the live
        // publish here doesn't lose data — it only prevents the @Published
        // storm across N sessions from landing inside the SwiftUI
        // scene-update settling window. The health-change fan-out
        // (Combine sink in TabsModel.startObserving mirroring into
        // TabsModel.connectionHealth) is one of the noisiest sources
        // post-resume.
        if BisectFlags.gate2_connectionHealth && Ghostty.isInResumeHealthQuietWindowAtomic {
            LifecycleDebugLogger.shared.bumpSuppression("gate2_connectionHealth")
            return
        }
        if connectionHealth != health {
            connectionHealth = health
        }
    }
    
    func handleBell() {
        ringBell()
    }

    /// The one bell sink: sound, haptic, and the `.bellTriggered` post that
    /// drives the tab wiggle. A suppressed bell does none of the three —
    /// see `TerminalBellSuppressor` for why a reattach's bells are noise.
    ///
    /// A tmux -CC pane also honors its gateway's suppression: the gateway's
    /// reattach replays into pane surfaces, which the session driving that
    /// reattach has no reference to. `parentUUID` is the gateway's stable
    /// identity, so this is safe against the `parentSurface` ABA problem.
    func ringBell() {
        guard !TerminalBellSuppressor.isSuppressed(uuid) else { return }
        if let parentUUID = tmuxPaneBinding?.parentUUID,
           TerminalBellSuppressor.isSuppressed(parentUUID) {
            return
        }
        let preset = SoundManager.shared.bellPreset
        if preset.includesHaptic {
            triggerHapticFeedback()
        }
        SoundManager.shared.playBellSound()
        NotificationCenter.default.post(name: .bellTriggered, object: self)
    }

    func handleSurfaceContentChanged() {
        AgentAttentionCenter.shared.noteContentChanged(terminal: self)
        if let binding = tmuxPaneBinding,
           let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface) {
            controller.notePaneContentChanged()
        }
    }
    
    func handleCellSizeChange(width: CGFloat, height: CGFloat) {
        self.cellSize = CGSize(width: width, height: height)
        Ghostty.logger.info("Cell size changed: \(width)x\(height)")
        guard !isTmuxDetachInProgress else { return }

        // Cell size change means the grid dimensions (rows/cols) have changed
        // even though the framebuffer pixel dimensions are the same.
        // Clear the framebuffer cache to force a full resize, which will:
        // 1. Call ghostty_surface_set_size() to recalculate the grid
        // 2. Call updatePTYSize() to notify the PTY/shell of new dimensions
        surfaceController.invalidateCachedSize()
        sizeDidChange(bounds.size)

        // A tmux pane has no PTY, so updatePTYSize is a no-op; instead the
        // window's per-window tmux size must be re-pushed now that its grid
        // changed. Drive the active window's container layout, which recomputes
        // and sends `refresh-client -C @win:WxH`. Only the active tab pushes, so
        // other windows are untouched. This is the single chokepoint for every
        // cell-size change (keyboard, pinch, and the Settings font path).
        if isTmuxPane {
            NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
        }
    }
    
    func handleRendererHealth(healthy: Bool) {
        self.healthy = healthy
        Ghostty.logger.info("Renderer health: \(healthy)")
    }
    
    func handleMouseShape(shape: Int) {
        #if targetEnvironment(macCatalyst)
        let newCursor = nsCursorForShape(shape)
        currentCursor = newCursor

        // If mouse is currently inside the view, update the displayed cursor
        if isMouseInsideView, let cursorToken {
            CatalystCursorCoordinator.shared.ensure(
                cursorToken,
                cursor: newCursor,
                priority: .terminal
            )
        }
        #endif

        Ghostty.logger.debug("Mouse shape changed: \(shape)")
    }

    #if targetEnvironment(macCatalyst)
    /// Maps Ghostty mouse shape values to NSCursor instances
    private func nsCursorForShape(_ shape: Int) -> NSCursor {
        let ghosttyShape = ghostty_action_mouse_shape_e(rawValue: UInt32(shape))

        switch ghosttyShape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            return .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            return .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            return .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
            return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            return .resizeRight
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            return .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
            return .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            return .resizeDown
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            return .resizeUpDown
        default:
            // For any unhandled shapes, default to I-beam (text cursor)
            return .iBeam
        }
    }
    #endif

    func handleMouseVisibility(visible: Bool) {
        #if targetEnvironment(macCatalyst)
        guard isLogicallyFocused, windowIsActiveForFocus(), isMouseInsideView else { return }
        // Implement hide-while-typing: hide cursor when typing, reveal on mouse move
        if visible {
            NSCursor.unhide()
        } else {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        #endif

        Ghostty.logger.debug("Mouse visibility changed: \(visible)")
    }

    func handleDesktopNotification(title: String?, body: String?) {
        Ghostty.logger.info("handleDesktopNotification called: title=\(title ?? "nil"), body=\(body ?? "nil")")

        // Skip if terminal notifications are disabled
        guard NotificationManager.shared.terminalNotificationsEnabled else {
            Ghostty.logger.debug("Skipping desktop notification - notifications disabled")
            return
        }

        // Need tab ID to schedule notification for navigation on click
        guard let tabID = containingTabID else {
            Ghostty.logger.warning("Cannot schedule desktop notification - no containing tab ID")
            return
        }

        // Skip if terminal is focused - no need to notify about something user is already looking at
        // (check after other guards so we can see in logs if this is the issue)
        guard !isLogicallyFocused || !windowIsActiveForFocus() else {
            Ghostty.logger.debug("Skipping desktop notification - terminal is focused and window is active")
            return
        }

        Task { @MainActor in
            // Request permission lazily if not yet determined
            var settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                let granted = await NotificationManager.shared.requestPermissions()
                if !granted {
                    Ghostty.logger.info("Desktop notification permission denied")
                    return
                }
                // Re-fetch settings after permission request
                settings = await UNUserNotificationCenter.current().notificationSettings()
            }

            // Check authorization after potential permission request
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else {
                Ghostty.logger.debug("Desktop notification skipped - not authorized (status=\(settings.authorizationStatus.rawValue))")
                return
            }

            // Schedule the notification
            // Use connection display name as subtitle, or terminal title if customized via OSC
            let subtitle = (self.title != "ghostty") ? self.title : self.connectionConfig.displayName

            if let identifier = NotificationManager.shared.scheduleTerminalNotification(
                title: title ?? "Terminal",
                body: body ?? "",
                subtitle: subtitle,
                tabID: tabID,
                surfaceID: self.uuid
            ) {
                self.notificationIdentifiers.insert(identifier)
                Ghostty.logger.info("Scheduled desktop notification: \(identifier)")
            }
        }
    }
    
    func handleScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        // While multiplexer tracking owns the scrollbar values, drop
        // native callbacks (which fire for the alt screen the multiplexer
        // is on, with useless at-bottom values that would clobber the
        // multiplexer state). Still sync mouse-capture state so a
        // multiplexer exit reaching here gets observed — that didSet path
        // can flip multiplexerScrollActive off (via the observer's
        // reset → apply(nil) chain), in which case we want to fall
        // through and apply THIS callback's native values rather than
        // dropping them.
        if multiplexerScrollActive {
            updateMouseCaptureState()
            if multiplexerScrollActive {
                return
            }
        }

        let viewportChanged = scrollbarOffset != offset || scrollbarLen != len

        scrollbarTotal = total
        scrollbarOffset = offset
        scrollbarLen = len

        // Check mouse capture state when scrollback changes
        // This catches mode changes during terminal output (e.g., vim startup)
        updateMouseCaptureState()

        #if !targetEnvironment(macCatalyst)
        if viewportChanged {
            // Keep the selection handles pinned to the (now-moved) selection
            // instead of tearing them down. This covers auto-scroll during a
            // handle drag, the snap-to-bottom when exiting scroll mode, and live
            // output. updateSelectionHandlePositions hides the handles only when
            // the selection has scrolled entirely off-screen, and no-ops while
            // they're already hidden during an active scroll gesture (so the
            // post-scroll sync still re-shows them). Blindly hiding here used to
            // race the post-scroll re-show: the snap-to-bottom viewport change
            // could arrive after the handles were restored and hide them again.
            updateSelectionHandlePositions()
        }
        #endif

        updateScrollIndicatorLayout()
        let revealScrollIndicator = Date().timeIntervalSinceReferenceDate <= scrollIndicatorRevealDeadline
        scrollIndicatorRevealDeadline = 0
        updateScrollIndicatorVisibility(animated: true, reveal: revealScrollIndicator)

        // Notify TerminalScrollView of scrollbar updates
        NotificationCenter.default.post(name: .ghosttyDidUpdateScrollbar, object: self)
    }

    /// Apply a multiplexer-derived scrollbar sample (or clear it). Maps the
    /// multiplexer's `(oy, history)` semantics into Ghostty's `(total,
    /// offset_from_top, len)` model and writes them into
    /// scrollbarTotal/Offset/Len so TerminalScrollView's existing
    /// handleScrollbarUpdate path sizes the document and flashes
    /// UIScrollView's native scroll indicator.
    func applyMultiplexerScrollSample(_ sample: Ghostty.MultiplexerScrollIndicatorObserver.Sample?) {
        guard let sample = sample else {
            // Tracking ended. Restore the pre-tracking native scrollbar
            // state so TerminalScrollView resizes its document view back
            // to the correct primary-screen geometry. If no snapshot
            // exists (first run, or the snapshot was already consumed),
            // clear to 0 — the next native handleScrollbar callback will
            // repopulate.
            if let snapshotTotal = nativeScrollbarSnapshotTotal {
                scrollbarTotal = snapshotTotal
                scrollbarOffset = nativeScrollbarSnapshotOffset ?? 0
                scrollbarLen = nativeScrollbarSnapshotLen ?? 0
            } else {
                scrollbarTotal = 0
                scrollbarOffset = 0
                scrollbarLen = 0
            }
            nativeScrollbarSnapshotTotal = nil
            nativeScrollbarSnapshotOffset = nil
            nativeScrollbarSnapshotLen = nil
            multiplexerScrollActive = false
            NotificationCenter.default.post(name: .ghosttyDidUpdateScrollbar, object: self)
            return
        }

        // A copy-mode position indicator rendered into OUR surface is evidence
        // this pane is a multiplexer the app does not drive: control mode
        // projects panes onto their own surfaces and never paints this chrome
        // here. This is the late fallback for a multiplexer the user started
        // by hand, which no by-construction site can know about.
        //
        // Deliberately NOT conditioned on the pane having no agent yet: by the
        // time anyone scrolls, the agent is usually already identified, and
        // that is precisely the pane whose completion inferences need
        // correcting. Refused only for surfaces the app already drives as
        // tmux -CC. (id=agent-attention-raw-mux)
        if tmuxPaneBinding == nil, tmuxController == nil {
            bindRawMultiplexer(sample.source.multiplexerType, sessionName: nil)
        }

        let viewportRows = sample.viewportRows
        guard viewportRows > 0, sample.history > 0 else { return }

        // Checked addition. The observer already caps `history` to a sane
        // value, so this is belt-and-braces — but UInt64.max + viewportRows
        // would otherwise trap.
        let (total, overflow) = sample.history.addingReportingOverflow(viewportRows)
        guard !overflow else { return }

        // First sample of this tracking session: snapshot native scrollbar
        // values so apply(nil) can restore them when tracking ends. Native
        // handleScrollbar callbacks during tracking are dropped (they fire
        // for the alt screen and are useless), so snapshotting at first
        // sample is the only chance we get.
        if nativeScrollbarSnapshotTotal == nil {
            nativeScrollbarSnapshotTotal = scrollbarTotal
            nativeScrollbarSnapshotOffset = scrollbarOffset
            nativeScrollbarSnapshotLen = scrollbarLen
        }

        let len = viewportRows
        let maxOffset = total > len ? total - len : 0
        let offset = min(sample.history > sample.oy ? sample.history - sample.oy : 0, maxOffset)

        scrollbarTotal = total
        scrollbarOffset = offset
        scrollbarLen = len
        // Only flip on transitions. @Published emits per-assignment even
        // when the value is unchanged, and downstream sinks (e.g. the
        // indicator pulse timer) would churn at sample rate (~30 Hz).
        if !multiplexerScrollActive {
            multiplexerScrollActive = true
        }
        NotificationCenter.default.post(name: .ghosttyDidUpdateScrollbar, object: self)
    }

    func handleProgressReport(_ report: Ghostty.Action.ProgressReport) {
        // Update the progress report state
        // The TerminalScrollView observer will automatically update the UI
        self.progressReport = report
        Ghostty.logger.debug("Progress report updated: state=\(report.state), progress=\(report.progress?.description ?? "nil")")
    }

    // MARK: - Search Delegate

    func handleStartSearch(_ startSearch: Ghostty.Action.StartSearch) {
        if searchState != nil {
            // Same shortcut that opened search now dismisses it.
            closeSearch()
        } else {
            searchState = Ghostty.SearchState(from: startSearch)
            // Notify MainView to re-render with search overlay
            NotificationCenter.default.post(name: .ghosttySearchStateChanged, object: self)
        }
        Ghostty.logger.info("Search started with needle: \(startSearch.needle ?? "(empty)")")
    }

    func handleEndSearch() {
        searchState = nil
        // Notify MainView to re-render without search overlay
        NotificationCenter.default.post(name: .ghosttySearchStateChanged, object: self)
        Ghostty.logger.info("Search ended")
        
        // Restore focus to terminal
        self.becomeFirstResponder()
    }

    func handleSearchTotal(_ total: UInt?) {
        searchState?.total = total
        Ghostty.logger.debug("Search total: \(total?.description ?? "nil")")
    }

    func handleSearchSelected(_ selected: UInt?) {
        searchState?.selected = selected
        Ghostty.logger.debug("Search selected: \(selected?.description ?? "nil")")
    }

    func handleMouseOverLink(url: String?) {
        lastProbedLinkURL = url
    }

    // MARK: - Search Helpers

    /// Perform a search with the given needle
    func performSearch(_ needle: String) {
        performActionAsync("search:\(needle)")
    }

    /// Navigate to the next or previous search match
    func navigateSearch(direction: String) {
        performActionAsync("navigate_search:\(direction)")
    }

    /// Close the search and clear highlights
    func closeSearch() {
        performActionAsync("end_search")
    }

    /// Perform a binding action on this surface
    /// - Parameter action: The action string (e.g., "scroll_to_row:100", "select_all")
    /// - Returns: True if the action was performed successfully
    func performAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        let len = action.utf8CString.count
        if len == 0 { return false }
        let performed = action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(len - 1))
        }

        #if !targetEnvironment(macCatalyst)
        if performed {
            scheduleSelectionHandleSync(afterGhosttyAppTick: true)
        }
        #endif

        return performed
    }

    func noteUserScrollForScrollIndicator() {
        scrollIndicatorRevealDeadline = Date().timeIntervalSinceReferenceDate + 1.0
    }

    private static func actionRevealsScrollIndicator(_ action: String) -> Bool {
        switch action {
        case "scroll_page_up", "scroll_page_down", "scroll_to_top", "scroll_to_bottom":
            return true
        default:
            return action.hasPrefix("scroll_to_row:")
        }
    }
    
    private func updateScrollIndicatorLayout() {
        guard let indicator = scrollIndicator else { return }

        // Only update layout when the indicator should be visible.
        let isAtBottom = scrollbarOffset + scrollbarLen >= scrollbarTotal
        guard scrollbarTotal != 0, !isAtBottom else { return }

        // Calculate scroll indicator position and size
        let viewHeight = bounds.height
        let indicatorWidth: CGFloat = 4
        let inset: CGFloat = 2

        // Calculate proportional position and size
        let proportion = Float(scrollbarLen) / Float(scrollbarTotal)
        let indicatorHeight = max(CGFloat(proportion) * viewHeight, 30) // Minimum 30pt height

        let scrollPosition = Float(scrollbarOffset) / Float(scrollbarTotal)
        let indicatorY = CGFloat(scrollPosition) * (viewHeight - indicatorHeight)

        let newFrame = CGRect(
            x: bounds.width - indicatorWidth - inset,
            y: indicatorY,
            width: indicatorWidth,
            height: indicatorHeight
        )

        if indicator.frame != newFrame {
            UIView.performWithoutAnimation {
                indicator.frame = newFrame
            }
        }
    }

    private func updateScrollIndicatorVisibility(animated: Bool, reveal: Bool) {
        guard let indicator = scrollIndicator else { return }

        let isAtBottom = scrollbarOffset + scrollbarLen >= scrollbarTotal
        // Hide scroll indicator when mouse is captured (tmux, vim mouse mode).
        // In multiplexer scroll mode the native UIScrollView indicator
        // (driven by TerminalScrollView via multiplexerScrollActive) is
        // what shows instead.
        let shouldBeVisible = scrollbarTotal != 0 && !isAtBottom && !isMouseCaptured
        let targetAlpha: CGFloat = shouldBeVisible ? 1 : 0

        if !shouldBeVisible {
            scrollIndicatorHideWorkItem?.cancel()
            scrollIndicatorHideWorkItem = nil
        }

        guard reveal || !shouldBeVisible else { return }

        if indicator.alpha != targetAlpha {
            let changeAlpha = { indicator.alpha = targetAlpha }
            if animated {
                UIView.animate(withDuration: 0.2, animations: changeAlpha)
            } else {
                UIView.performWithoutAnimation(changeAlpha)
            }
        }

        if shouldBeVisible {
            scheduleScrollIndicatorAutoHide()
        }
    }

    private func scheduleScrollIndicatorAutoHide() {
        scrollIndicatorHideWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, let indicator = self.scrollIndicator else { return }
            UIView.animate(withDuration: 0.5) {
                indicator.alpha = 0
            }
        }

        scrollIndicatorHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }
}

// MARK: - Pane Presentation

extension Ghostty.TerminalView {
    /// Keep split chrome and pane-level agent cards on a stable, non-empty
    /// title without changing the existing tab-title rules.
    func refreshPanePresentationTitle() {
        let resolved: String
        if let override = userOverrideTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            resolved = override
        } else {
            let live = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !TabModel.shouldUseFallbackTitle(live),
               !Self.isInternalTmuxPaneTitle(live) {
                resolved = live
            } else if tmuxPaneBinding != nil {
                let reportedTitle = tmuxReportedPaneTitle?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let currentCommand = tmuxReportedCurrentCommand?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !reportedTitle.isEmpty,
                   !TabModel.shouldUseFallbackTitle(reportedTitle),
                   !Self.isInternalTmuxPaneTitle(reportedTitle) {
                    resolved = reportedTitle
                } else if !currentCommand.isEmpty {
                    resolved = currentCommand
                } else {
                    // Never expose tmux's internal `%123` pane identifier.
                    // Split consumers add a stable visual ordinal
                    // ("Terminal 1") until tmux metadata arrives.
                    resolved = "Terminal"
                }
            } else {
                switch connectionConfig {
                case .local:
                    resolved = "Terminal"
                default:
                    let displayName = connectionConfig.displayName
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    resolved = displayName.isEmpty ? "Terminal" : displayName
                }
            }
        }

        if presentation.title != resolved {
            presentation.title = resolved
        }
    }

    private static func isInternalTmuxPaneTitle(_ title: String) -> Bool {
        let compact = title
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        guard compact.hasPrefix("pane%") else { return false }
        return Int(compact.dropFirst("pane%".count)) != nil
    }
}

// MARK: - Ghostty Key Event Routing

extension Ghostty.TerminalView {
    func sendEnterKeyViaGhostty(modifiers: UIKeyModifierFlags) -> Bool {
        sendKeyViaGhostty(
            keyCode: .keyboardReturnOrEnter,
            action: .press,
            modifiers: modifiers
        )
    }

    func sendEnterKeyViaGhostty(
        toolbarModifiers: KeyModifiers = [],
        virtualModifier: ModTapModifier? = nil
    ) -> Bool {
        var modifiers = UIKeyModifierFlags()
        if toolbarModifiers.contains(.control) { modifiers.insert(.control) }
        if toolbarModifiers.contains(.shift) { modifiers.insert(.shift) }
        if toolbarModifiers.contains(.alt) { modifiers.insert(.alternate) }
        if toolbarModifiers.contains(.command) { modifiers.insert(.command) }

        if let virtualModifier {
            modifiers.insert(virtualModifier.uiKeyModifierFlag)
        }

        return sendEnterKeyViaGhostty(modifiers: modifiers)
    }

    /// Routes a modified key press through Ghostty's key encoding pipeline
    /// (`ghostty_surface_key`) instead of manually building escape sequences.
    /// This enables proper CSI u / kitty protocol encoding for keys like
    /// Ctrl+;, Ctrl+-, Ctrl+Shift+- that have no legacy control character.
    ///
    /// - Parameters:
    ///   - char: The character being pressed (lowercase for letters)
    ///   - modifiers: Active keyboard modifiers from toolbar
    /// - Returns: `true` if the key was handled via Ghostty, `false` if no mapping exists
    private func sendViaGhosttyKeyEvent(_ char: Character, modifiers: KeyModifiers) -> Bool {
        let lookupChar = char.lowercased().first ?? char
        guard let hidUsage = Self.characterHIDUsageMap[lookupChar] else { return false }

        // Convert KeyModifiers to Ghostty mods
        var mods = Ghostty.Input.Mods.none
        if modifiers.contains(.control) { mods.insert(.ctrl) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.alt) { mods.insert(.alt) }
        if modifiers.contains(.command) { mods.insert(.cmd) }

        // Build the text payload: apply shift transformation so legacy mode
        // sends the correct character (e.g., 'A' instead of 'a').
        let shiftActive = modifiers.contains(.shift)
        let effectiveChar = shiftActive ? Self.shiftedCharacter(char) : char
        let text = String(effectiveChar)

        // Determine the unshifted codepoint (what the key produces without Shift)
        let unshiftedCodepoint = UInt32(lookupChar.asciiValue ?? 0)

        guard sendKeyViaGhostty(
            keyCode: hidUsage,
            action: .press,
            mods: mods,
            consumedMods: shiftActive ? .shift : [],
            text: text,
            unshiftedCodepoint: unshiftedCodepoint
        ) else { return false }

        // Also send a release event so Ghostty doesn't think the key is held.
        _ = sendKeyViaGhostty(keyCode: hidUsage, action: .release, mods: mods)

        return true
    }

    /// Route a key through Ghostty's encoder via `ghostty_surface_key()`.
    /// For modifier shortcuts (Ctrl/Alt/Cmd), text=nil lets Ghostty encode from keycode.
    /// Maps UIKeyboardHIDUsage → native macOS CGKeyCode (what Ghostty core expects).
    @discardableResult
    func sendKeyViaGhostty(
        keyCode: UIKeyboardHIDUsage,
        action: Ghostty.Input.Action,
        mods: Ghostty.Input.Mods,
        consumedMods: Ghostty.Input.Mods = .none,
        text: String? = nil,
        unshiftedCodepoint: UInt32 = 0
    ) -> Bool {
        guard let surface = surface else { return false }
        guard let nativeKeycode = Ghostty.Input.nativeKeyCode(for: keyCode) else { return false }

        // A UIKit sentinel is a key name, not text.
        let text = text.flatMap { KeyCode.isUIKeyInputSentinel($0) ? nil : $0 }

        let event = Ghostty.Input.KeyEvent(
            nativeKeyCode: nativeKeycode,
            action: action,
            text: text,
            mods: mods,
            consumedMods: consumedMods,
            unshiftedCodepoint: unshiftedCodepoint
        )
        event.withCValue { ghostty_surface_key(surface, $0) }
        return true
    }

    /// Convenience: build Ghostty mods from UIKeyModifierFlags.
    @discardableResult
    func sendKeyViaGhostty(
        keyCode: UIKeyboardHIDUsage,
        action: Ghostty.Input.Action,
        modifiers: UIKeyModifierFlags
    ) -> Bool {
        let mods = ghosttyInputMods(from: modifiers)
        return sendKeyViaGhostty(keyCode: keyCode, action: action, mods: mods)
    }

    /// Look up the native macOS CGKeyCode for a HID usage code.
    func cgKeyCode(for hidUsage: UIKeyboardHIDUsage) -> UInt32? {
        Ghostty.Input.nativeKeyCode(for: hidUsage)
    }
}

// MARK: - KeyboardButtonDelegate

extension Ghostty.TerminalView: KeyboardButtonDelegate {
    func keyPressed(_ key: String, modifiers: KeyModifiers) {
        // Debug logging
        Ghostty.logger.debug("TerminalView.keyPressed: key=\(key), modifiers rawValue=\(modifiers.rawValue)")

        // A UIKit sentinel is a key name, not text.
        guard !KeyCode.isUIKeyInputSentinel(key) else { return }

        // Accessory keys bypass UIKit's normal keyboard insertion path. Notify
        // the text system after shifted input so one-shot software Shift is
        // consumed while Caps Lock remains latched.
        if modifiers.contains(.shift), KeyboardTracker.shared.isSoftwareKeyboardVisible {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.notifyInputDelegateOfExternalChange { }
            }
        }

        // When Compose overlay is active, route printable keys to the compose text view.
        // Modified keys (Ctrl/Alt/Cmd) and escape sequences still go to the terminal.
        if showComposeOverlay, let composeTV = activeComposeTextView {
            let hasModifier = modifiers.contains(.control) || modifiers.contains(.alt) || modifiers.contains(.command)
            if !hasModifier && key.count == 1 && !key.hasPrefix("\u{1B}") {
                let effectiveKey = modifiers.contains(.shift)
                    ? String(Self.shiftedCharacter(key.first!))
                    : key
                composeTV.insertText(effectiveKey)
                return
            }
            if !hasModifier && key == "\t" {
                composeTV.insertText("\t")
                return
            }
        }

        commitKoreanCompositionIfNeeded(external: true)

        // Notify that input was received (for scroll-to-bottom behavior)
        NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)

        if (key == "\r" || key == "\n"),
           !modifiers.isEmpty,
           sendEnterKeyViaGhostty(toolbarModifiers: modifiers) {
            notifyInputDelegateOfExternalChange {
                documentBuffer = ""
            }
            return
        }

        // For single-character keys with modifiers, route through Ghostty's key
        // encoding pipeline. This produces correct output for all keyboard protocol
        // modes (legacy, fixterms/CSI u, kitty) and handles keys like Ctrl+;,
        // Ctrl+-, Ctrl+Shift+- that have no legacy control character mapping.
        // Ctrl-C: interrupt local shell (matches hardware keyboard behavior in TerminalViewKeyboard.swift)
        #if !targetEnvironment(macCatalyst)
        if modifiers.contains(.control), key.count == 1, key.lowercased() == "c",
           let localSession = session as? LocalShellSession,
           !localSession.hasActiveEmbeddedSession {
            localSession.interrupt()
            return
        }
        #endif

        if !modifiers.isEmpty, key.count == 1, let char = key.first {
            if sendViaGhosttyKeyEvent(char, modifiers: modifiers) {
                return
            }
        }

        // Fallback: manually build escape sequences for keys that don't have
        // a Ghostty key mapping (e.g., multi-byte escape sequences for arrows)
        // or when the surface is unavailable.
        var keySequence = key

        // Handle DECCKM mode for arrow keys (before modifier processing)
        // Only convert plain arrows - modified arrows keep CSI format
        let applicationMode = surface.map { ghostty_surface_cursor_key_mode($0) } ?? false
        if modifiers.isEmpty,
           key.count == 3,
           key.hasPrefix("\u{1B}["),
           let direction = key.last,
           "ABCD".contains(direction),
           applicationMode {
            // Convert CSI to SS3: \e[A -> \eOA
            keySequence = "\u{1B}O\(direction)"
        }

        // Modified arrow keys: xterm CSI `1;{param}` encoding where
        // param = 1 + Shift(1) + Alt(2) + Ctrl(4). Cmd maps to the Alt bit,
        // matching the previous Cmd+arrow behavior.
        if !modifiers.isEmpty,
           key.count == 3,
           key.hasPrefix("\u{1B}["),
           let direction = key.last,
           "ABCD".contains(direction) {
            var param = 1
            if modifiers.contains(.shift) { param += 1 }
            if modifiers.contains(.alt) || modifiers.contains(.command) { param += 2 }
            if modifiers.contains(.control) { param += 4 }
            keySequence = "\u{1B}[1;\(param)\(direction)"
        }

        // Handle modifiers for special keys
        // Shift+Tab → backtab escape sequence
        if modifiers.contains(.shift) && key == "\t" {
            keySequence = "\u{1B}[Z"
        }

        // Shift modifier for regular single characters
        if modifiers.contains(.shift) && key.count == 1 && key != "\t" {
            keySequence = String(key.map { Self.shiftedCharacter($0) })
        }

        // Control modifier
        if modifiers.contains(.control) {
            if key.count == 1, let char = key.first {
                if let asciiValue = char.lowercased().first?.asciiValue,
                   asciiValue >= 97, asciiValue <= 122 {
                    // Ctrl+A through Ctrl+Z map to ASCII 1-26
                    let controlChar = asciiValue - 96
                    keySequence = String(UnicodeScalar(controlChar))
                } else if let ctrlCode = Self.controlCharacterMap[char] {
                    keySequence = String(UnicodeScalar(ctrlCode))
                }
            }
        }

        // Alt modifier (Meta key)
        if modifiers.contains(.alt) {
            // Alt sends ESC prefix for most keys
            if !key.hasPrefix("\u{1B}") {
                keySequence = "\u{1B}" + keySequence
            }
        }

        // Send to session
        guard let data = keySequence.data(using: .utf8) else {
            Ghostty.logger.error("TerminalView: Failed to encode keySequence to UTF-8")
            return
        }
        Ghostty.logger.debug("TerminalView: Sending sequence bytes: \(data.hexDescription)")
        sendUserInput(data)
    }

    func sendRawData(_ data: Data) {
        commitKoreanCompositionIfNeeded(external: true)
        NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
        Ghostty.logger.debug("TerminalView: Sending raw data (\(data.count) bytes)")
        sendUserInput(data)
    }
}
