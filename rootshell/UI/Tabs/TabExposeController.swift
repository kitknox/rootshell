//
//  TabExposeController.swift
//  rootshell
//
//  State machine for the tab exposé: which tabs are in scope, where the
//  reveal is (0 hidden … 1 presented), what the hero tab is, and the
//  progress spring that settles commit/cancel/select. Per window, owned by
//  MainView. `TabExposeView` renders it and drives `tick(now:)` from its
//  display link; MainView supplies the occlusion / tab-switch hooks.
//

import UIKit
import Observation

@MainActor
protocol TabExposeControllerObserver: AnyObject {
    /// `isActive` flipped: start/stop rendering.
    func tabExposeDidChangeActivity(_ controller: TabExposeController)
    /// Scope, hero, or highlight changed: rebuild/refresh cells.
    func tabExposeDidChangeCells(_ controller: TabExposeController)
}

@MainActor
@Observable
final class TabExposeController {
    enum Phase: Equatable {
        case hidden
        /// Finger/trackpad is driving `progress`.
        case interactive
        /// Spring is driving `progress` toward `target` (0 or 1).
        case settling(target: CGFloat)
        case presented
    }

    private enum InteractiveMode {
        case reveal
        case dismiss
    }

    /// One page of the exposé: the attached multiplexer session's tabs, or
    /// an app-tab scope (a group / project, or every tab in flat mode).
    struct Scope: Equatable {
        enum Kind: Equatable {
            case multiplexer
            case app(TabsModel.ScopeKey?)
        }
        let kind: Kind
        let title: String?
        let tabIDs: [UUID]
        /// Cell marked current and landed on when entering the page.
        let currentID: UUID?
        var isMultiplexer: Bool { kind == .multiplexer }
    }

    // MARK: - State

    private(set) var phase: Phase = .hidden
    /// Tabs in the current scope, in navigation order.
    private(set) var tabIDs: [UUID] = []
    private(set) var scopeTitle: String?
    /// Shown in the scope header; nil in flat mode.
    private(set) var isScoped = false
    /// The current page is the multiplexer session's tabs.
    private(set) var showsMultiplexer = false
    /// The multiplexer page exists for this presentation (the hero tab is
    /// attached to herdr / tmux / zellij and the feed could start).
    @ObservationIgnored private(set) var multiplexerAttached = false
    /// The app tab whose terminal feeds the multiplexer page.
    @ObservationIgnored private var multiplexerHostTabID: UUID?
    /// Opened on the app page on purpose (hover-preview hand-off): a
    /// multiplexer page detected late is attached but not switched to.
    @ObservationIgnored private var prefersAppPage = false
    /// The tab whose full-size live picture slides in/out with the tray.
    private(set) var heroTabID: UUID?
    var highlightedTabID: UUID? {
        didSet {
            guard highlightedTabID != oldValue else { return }
            // Inside refreshScope the single announce at its end delivers this.
            if isRefreshingScope { highlightChangedDuringRefresh = true } else { observer?.tabExposeDidChangeCells(self) }
        }
    }
    /// Tabs of the neighbor scope being previewed by an in-flight group swipe
    /// (the host keeps their renderers live; empty when no preview). Observed
    /// because MainView's window-wide terminal-effect layer must also account
    /// for panes entering through the neighboring preview.
    private(set) var previewTabIDs: [UUID] = []
    var isActive: Bool { phase != .hidden }
    /// More than one page to move between (groups / projects, or the
    /// multiplexer page next to the app tabs).
    var canNavigateScope: Bool {
        scopeList().scopes.count > 1
    }
    /// Page-control metadata for the currently presented scope list.
    var scopePageCount: Int {
        scopeList().scopes.count
    }
    var currentScopePageIndex: Int {
        let list = scopeList()
        return list.scopes.indices.contains(list.activeIndex) ? list.activeIndex : 0
    }
    /// Cell marked as current on the active page.
    var currentCellID: UUID? {
        showsMultiplexer ? muxFeed?.activeTabUUID : tabsModel?.selectedTabID
    }

    /// 0 hidden … 1 presented (may overshoot slightly). Read per frame by the
    /// view; deliberately not observed so scrubbing never invalidates SwiftUI.
    @ObservationIgnored private(set) var progress: CGFloat = 0
    /// Set by the view after layout so ↑/↓ move by a row.
    @ObservationIgnored var columns: Int = 1

    // MARK: - Wiring

    @ObservationIgnored weak var tabsModel: TabsModel?
    @ObservationIgnored weak var observer: TabExposeControllerObserver?
    /// Serves the multiplexer page; started on activation when the hero
    /// tab's terminal is bound to a raw multiplexer.
    @ObservationIgnored weak var muxFeed: MultiplexerExposeFeed?
    /// The terminal holding the selected tab's connection (focused pane,
    /// else any terminal in the tab).
    @ObservationIgnored var multiplexerTerminal: (() -> Ghostty.TerminalView?)?
    /// Un-occlude scope tabs (and anything else the host needs before showing).
    @ObservationIgnored var onWillPresent: (([UUID]) -> Void)?
    /// Restore occlusion after the overlay is gone.
    @ObservationIgnored var onDidDismiss: (() -> Void)?
    /// Switch the real selection; the overlay stays until the tab is displayed.
    @ObservationIgnored var onSelect: ((UUID) -> Void)?
    @ObservationIgnored var onCommitHaptic: (() -> Void)?
    @ObservationIgnored var reduceMotion: () -> Bool = { false }
    /// Scope membership changed while presented (new ids). Host wakes the
    /// newcomers and reconciles occlusion for the rest.
    @ObservationIgnored var onScopeDidChange: (([UUID]) -> Void)?
    /// Move to the previous (-1) / next (+1) group or project. The host
    /// switches the selection; the exposé stays up and re-scopes.
    @ObservationIgnored var onNavigateScope: ((Int) -> Void)?
    /// `previewTabIDs` changed: wake the newcomers, re-occlude the leavers.
    @ObservationIgnored var onScopePreviewChanged: (([UUID]) -> Void)?
    /// Direction of a scope switch in flight; published as `scopeTransition`
    /// with the scope-changed announce so the view pages in that direction.
    @ObservationIgnored var pendingScopeTransition: Int?
    @ObservationIgnored private var scopeTransition: Int?
    /// The terminal carrying `presentedOverlayKeyHandler` while presented.
    @ObservationIgnored weak var keyHandlerTerminal: Ghostty.TerminalView?
    /// No terminal to hook keys on (VNC pane focused): the view takes first
    /// responder itself while presented.
    @ObservationIgnored var wantsFirstResponderFallback = false
    /// Resting preview frame (window coordinates) and corner radius of a
    /// tab's cell, supplied by the view; the hover preview card flies into it.
    @ObservationIgnored var previewFrameProvider: ((UUID) -> (frame: CGRect, cornerRadius: CGFloat)?)?

    // MARK: - Private

    @ObservationIgnored private var interactiveMode: InteractiveMode = .reveal
    @ObservationIgnored private var velocity: CGFloat = 0
    @ObservationIgnored private var springResponse: CGFloat = 0.32
    @ObservationIgnored private var springDamping: CGFloat = 0.86
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    /// After a select settles to 0, wait for the real tab to be displayed before hiding.
    @ObservationIgnored private var hideDeadline: CFTimeInterval = 0
    @ObservationIgnored private var pendingSelectedTabID: UUID?
    @ObservationIgnored private var scopeObservationArmed = false
    @ObservationIgnored private var isRefreshingScope = false
    @ObservationIgnored private var highlightChangedDuringRefresh = false
    /// Inside `attachMultiplexer`: the feed's synchronous start notification
    /// must not re-enter `refreshScope` from underneath one.
    @ObservationIgnored private var isAttachingMultiplexer = false
    @ObservationIgnored private var dismissalCallbackPending = false

    // MARK: - Interactive reveal / dismiss

    /// A pull started. From hidden this is a reveal; from presented (or a
    /// settle) the finger takes over wherever the tray currently is.
    func beginInteractive() {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        switch phase {
        case .hidden:
            guard activate() else { return }
            interactiveMode = .reveal
            progress = 0
        case .presented:
            interactiveMode = .dismiss
        case .settling(let target):
            interactiveMode = target >= 1 ? .reveal : .dismiss
        case .interactive:
            break
        }
        velocity = 0
        phase = .interactive
    }

    /// `signed` is the gesture's distance/length, down-positive: a reveal
    /// pulls down from 0, a dismiss pushes up from 1.
    func updateInteractive(signed: CGFloat) {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        guard phase == .interactive else { return }
        let p: CGFloat
        switch interactiveMode {
        case .reveal: p = signed
        case .dismiss: p = 1 + signed
        }
        progress = rubberBanded(p)
    }

    /// Release. `velocity` is along the gesture axis, down-positive, pt/s.
    func endInteractive(velocity v: CGFloat) {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        guard phase == .interactive else { return }
        let commit: Bool
        switch interactiveMode {
        case .reveal:
            commit = progress >= 0.25 || v > 600
            if commit { onCommitHaptic?() }
            settle(to: commit ? 1 : 0, fast: !commit)
        case .dismiss:
            commit = progress <= 0.75 || v < -600
            settle(to: commit ? 0 : 1, fast: commit)
        }
    }

    func cancelInteractive() {
        guard phase == .interactive else { return }
        switch interactiveMode {
        case .reveal: settle(to: 0, fast: true)
        case .dismiss: settle(to: 1, fast: false)
        }
    }

    // MARK: - Programmatic

    func toggle() {
        if isActive {
            cancel()
        } else {
            present()
        }
    }

    func present() {
        guard !isActive, activate() else { return }
        progress = 0
        settle(to: 1, fast: false)
    }

    /// Present with `id` highlighted, landing on the app page even when the
    /// selected tab has a multiplexer page (the hover preview hands off an
    /// app tab, and that tab's cell is where the card flies).
    func present(highlighting id: UUID) {
        // A hidden tmux window is not in any scope and a plain select would
        // not unhide it; the sidebar's own unhide path owns that.
        guard let tabsModel, let tab = tabsModel.tab(withID: id), !tab.isHiddenTmuxWindow else { return }
        if isActive {
            if tabIDs.contains(id) { highlightedTabID = id }
            return
        }
        // A tab from another group / project (the sidebar lists them all):
        // select it first so the scope is built around it, the way scope
        // paging selects into the neighbor scope.
        if tabsModel.selectedTabID != id, let list = tabsModel.scopeList(),
           list.scopes.indices.contains(list.activeIndex),
           !list.scopes[list.activeIndex].tabIDs.contains(id) {
            onSelect?(id)
        }
        guard activate(preferAppPage: true) else { return }
        if tabIDs.contains(id) { highlightedTabID = id }
        progress = 0
        settle(to: 1, fast: false)
    }

    /// Dismiss without changing the selection.
    func cancel() {
        guard isActive else { return }
        pendingSelectedTabID = nil
        heroTabID = tabsModel?.selectedTabID ?? heroTabID
        observer?.tabExposeDidChangeCells(self)
        settle(to: 0, fast: true)
    }

    /// Switch to `id`: it becomes the hero that slides back in while the
    /// tray leaves; the real selection changes immediately. On the
    /// multiplexer page the hero is unchanged: the session switches tabs
    /// underneath it and its own PTY repaints.
    func select(_ id: UUID) {
        guard isActive, tabIDs.contains(id) else { return }
        if showsMultiplexer {
            highlightedTabID = id
            pendingSelectedTabID = nil
            observer?.tabExposeDidChangeCells(self)
            if let tab = muxFeed?.tab(uuid: id) {
                onCommitHaptic?()
                muxFeed?.focus(tabID: tab.id)
            }
            settle(to: 0, fast: false)
            return
        }
        heroTabID = id
        highlightedTabID = id
        pendingSelectedTabID = id
        observer?.tabExposeDidChangeCells(self)
        if tabsModel?.selectedTabID != id {
            onSelect?(id)
        }
        settle(to: 0, fast: false)
    }

    /// Previous / next page while presented (swipe, ⌘⌥[ ]): the multiplexer
    /// page re-scopes in place; an app scope selects a tab in it and the
    /// observation re-scopes.
    func navigateScope(by delta: Int) {
        guard isActive, delta != 0 else { return }
        let list = scopeList()
        guard list.scopes.count > 1 else { return }
        let count = list.scopes.count
        let targetIndex = ((list.activeIndex + delta) % count + count) % count
        let target = list.scopes[targetIndex]
        pendingScopeTransition = delta
        // Re-scope on the next turn, like the observation-driven app-scope
        // switch: the view's swipe commit must finish arming its settle
        // before the pages swap roles.
        let deferredRefresh = { [weak self] in
            _ = Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.refreshScope()
            }
        }
        switch target.kind {
        case .multiplexer:
            showsMultiplexer = true
            deferredRefresh()
        case .app:
            showsMultiplexer = false
            let appOffset = targetIndex - list.appActiveIndex
            if appOffset == 0 {
                deferredRefresh()
            } else {
                onNavigateScope?(appOffset)
                // The host's selection re-scopes asynchronously; keep the
                // page direction the user asked for, not the app-scope offset.
                pendingScopeTransition = delta
            }
        }
    }

    /// The view consumes the page direction of the scope switch this
    /// `tabExposeDidChangeCells` announces, if it is one.
    func takeScopeTransition() -> Int? {
        defer { scopeTransition = nil }
        return scopeTransition
    }

    /// The page a swipe would land on (nil: a single page).
    func neighborScope(offset: Int) -> Scope? {
        let list = scopeList()
        guard list.scopes.count > 1 else { return nil }
        let count = list.scopes.count
        return list.scopes[((list.activeIndex + offset) % count + count) % count]
    }

    /// Every page in order: the multiplexer session first when attached,
    /// then the app scopes (a single "Tabs" page in flat mode).
    private func scopeList() -> (scopes: [Scope], activeIndex: Int, appActiveIndex: Int) {
        guard let tabsModel else { return ([], 0, 0) }
        var scopes: [Scope] = []
        if multiplexerAttached, let feed = muxFeed {
            scopes.append(Scope(kind: .multiplexer, title: feed.title, tabIDs: feed.tabUUIDs, currentID: feed.activeTabUUID))
        }
        let appActive: Int
        if let list = tabsModel.scopeList() {
            appActive = scopes.count + list.activeIndex
            scopes += list.scopes.map { info in
                Scope(kind: .app(info.key), title: info.title, tabIDs: info.tabIDs,
                      currentID: tabsModel.preferredTabID(in: info.tabIDs, scope: info.key))
            }
        } else {
            appActive = scopes.count
            scopes.append(Scope(
                kind: .app(nil),
                title: String(localized: "Tabs", comment: "Exposé page title for all app tabs next to a multiplexer page"),
                tabIDs: tabsModel.orderProjection.navigationTabIDs,
                currentID: tabsModel.selectedTabID
            ))
        }
        let active = (showsMultiplexer && multiplexerAttached) ? 0 : appActive
        return (scopes, active, appActive)
    }

    /// The feed's state or topology changed.
    func muxFeedDidChange() {
        // Starting the feed notifies synchronously; the attach path is
        // already inside a refresh that will pick the new state up.
        guard !isAttachingMultiplexer else { return }
        guard let muxFeed, let host = multiplexerHostTabID else { return }
        if !multiplexerAttached {
            // Detection finished: adopt the page if we're still on the host tab.
            guard isActive, muxFeed.isServing, tabsModel?.selectedTabID == host else { return }
            multiplexerAttached = true
            showsMultiplexer = !prefersAppPage
            refreshScope(force: true)
            return
        }
        if muxFeed.state == .unsupported {
            multiplexerAttached = false
            showsMultiplexer = false
        }
        // Tab ids survive a topology change: force the rebuild that carries
        // the new layouts, titles, current tab, and header state.
        refreshScope(force: true)
    }

    /// The view is previewing `ids` (a neighbor scope dragged in); empty ends it.
    func setScopePreview(_ ids: [UUID]) {
        guard ids != previewTabIDs else { return }
        previewTabIDs = ids
        onScopePreviewChanged?(ids)
    }

    /// Immediate teardown (scene background, scope emptied).
    func forceHide(reason: String) {
        guard isActive else { return }
        progress = 0
        velocity = 0
        // Detach first so the feed's stop notification doesn't re-scope.
        multiplexerAttached = false
        showsMultiplexer = false
        multiplexerHostTabID = nil
        muxFeed?.stopNow()
        finishHide()
    }

    // MARK: - Highlight / keyboard

    func moveHighlight(by delta: Int, wrap: Bool) {
        guard !tabIDs.isEmpty else { return }
        let current = highlightedTabID.flatMap { tabIDs.firstIndex(of: $0) } ?? 0
        var next = current + delta
        if wrap {
            next = ((next % tabIDs.count) + tabIDs.count) % tabIDs.count
        } else {
            next = min(max(next, 0), tabIDs.count - 1)
        }
        highlightedTabID = tabIDs[next]
    }

    /// Keys routed from the focused terminal while presented. Returns false
    /// for anything the exposé doesn't own (the host dismisses and lets it through).
    func handleKey(_ key: OverlayKeyEvent) -> Bool {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return false }
        guard isActive else { return false }
        switch key.keyCode {
        case .keyboardEscape:
            cancel()
            return true
        case .keyboardReturnOrEnter, .keyboardSpacebar:
            if let id = highlightedTabID { select(id) } else { cancel() }
            return true
        case .keyboardLeftArrow:
            moveHighlight(by: -1, wrap: true)
            return true
        case .keyboardRightArrow:
            moveHighlight(by: 1, wrap: true)
            return true
        case .keyboardUpArrow:
            moveHighlight(by: -max(columns, 1), wrap: false)
            return true
        case .keyboardDownArrow:
            moveHighlight(by: max(columns, 1), wrap: false)
            return true
        case .keyboardTab:
            moveHighlight(by: key.modifiers.contains(.shift) ? -1 : 1, wrap: true)
            return true
        case .keyboardHome:
            highlightedTabID = tabIDs.first
            return true
        case .keyboardEnd:
            highlightedTabID = tabIDs.last
            return true
        default:
            break
        }
        if key.modifiers.isDisjoint(with: [.control, .alternate]),
           key.characters.count == 1,
           let digit = key.characters.first?.wholeNumberValue,
           (1...9).contains(digit),
           digit <= tabIDs.count {
            select(tabIDs[digit - 1])
            return true
        }
        return false
    }

    // MARK: - Ticking (driven by the view's display link)

    /// Advance the settle spring. Returns true while the overlay needs frames.
    @discardableResult
    func tick(now: CFTimeInterval) -> Bool {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return false }
        defer { lastTick = now }
        guard isActive else { return false }

        if case .settling(let target) = phase {
            let dt = lastTick == 0 ? 1.0 / 60.0 : min(max(now - lastTick, 0), 1.0 / 20.0)
            stepSpring(toward: target, dt: CGFloat(dt))
            if abs(progress - target) < 0.002, abs(velocity) < 0.01 {
                progress = target
                velocity = 0
                if target >= 1 {
                    phase = .presented
                } else {
                    settledAtZero(now: now)
                }
            }
        } else if phase == .hidden {
            return false
        }
        return isActive
    }

    private func settledAtZero(now: CFTimeInterval) {
        // A select waits (briefly) for the real tab to be displayed so the
        // swap under the overlay is invisible.
        if let pending = pendingSelectedTabID {
            if hideDeadline == 0 { hideDeadline = now + 0.6 }
            let displayed = tabsModel?.displayedTabID
            guard displayed == pending || now >= hideDeadline else { return }
        }
        finishHide()
    }

    private func stepSpring(toward target: CGFloat, dt: CGFloat) {
        ExposeSpring.step(value: &progress, velocity: &velocity, target: target,
                          response: springResponse, damping: springDamping, dt: dt)
    }

    // MARK: - Internals

    func resumeAfterInactivity() {
        lastTick = 0
        // UIKit may cancel a gesture during lock without delivering an end
        // while drawing is allowed. Settle it instead of leaving it stranded.
        if phase == .interactive { endInteractive(velocity: 0) }
    }

    func finishDeferredDismissal() {
        guard dismissalCallbackPending, !Ghostty.isSecureDrawProhibitedAtomic else { return }
        dismissalCallbackPending = false
        onDidDismiss?()
    }

    /// Snapshot the scope and tell the host we're about to show. False if there is nothing to show.
    /// `preferAppPage` keeps an attached multiplexer page reachable by paging
    /// but opens on the app tabs.
    private func activate(preferAppPage: Bool = false) -> Bool {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return false }
        guard let tabsModel else { return false }
        attachMultiplexer()
        prefersAppPage = preferAppPage
        if preferAppPage { showsMultiplexer = false }
        refreshScope(announce: false)
        guard !tabIDs.isEmpty || showsMultiplexer else {
            muxFeed?.stop(grace: 0)
            multiplexerAttached = false
            multiplexerHostTabID = nil
            return false
        }
        heroTabID = tabsModel.selectedTabID
        let landing = showsMultiplexer ? muxFeed?.activeTabUUID : tabsModel.selectedTabID
        highlightedTabID = landing.flatMap { tabIDs.contains($0) ? $0 : nil } ?? tabIDs.first
        pendingSelectedTabID = nil
        hideDeadline = 0
        lastTick = 0
        onWillPresent?(tabIDs)
        phase = .interactive
        observer?.tabExposeDidChangeActivity(self)
        observer?.tabExposeDidChangeCells(self)
        armScopeObservation()
        return true
    }

    private func settle(to target: CGFloat, fast: Bool) {
        if reduceMotion() {
            progress = target
            velocity = 0
            if target >= 1 {
                phase = .presented
                observer?.tabExposeDidChangeCells(self)
            } else {
                phase = .settling(target: 0)
                settledAtZero(now: CACurrentMediaTime())
            }
            return
        }
        springResponse = fast ? 0.26 : 0.32
        springDamping = fast ? 0.9 : 0.86
        hideDeadline = 0
        phase = .settling(target: target)
    }

    private func finishHide() {
        phase = .hidden
        progress = 0
        velocity = 0
        pendingSelectedTabID = nil
        hideDeadline = 0
        scopeObservationArmed = false
        pendingScopeTransition = nil
        scopeTransition = nil
        previewTabIDs = []
        if multiplexerHostTabID != nil {
            // Keep the session's picture warm briefly for a quick re-entry.
            muxFeed?.stop(grace: 3)
        }
        multiplexerAttached = false
        showsMultiplexer = false
        multiplexerHostTabID = nil
        prefersAppPage = false
        observer?.tabExposeDidChangeActivity(self)
        // The host callback can hand keyboard focus back to a VNC pane.
        // Defer that along with the view's responder/hierarchy teardown.
        dismissalCallbackPending = true
        finishDeferredDismissal()
    }

    /// The multiplexer page always belongs to the SELECTED tab: after any
    /// selection change (scope paging, ⌘N, the sidebar) the feed re-binds to
    /// that tab's terminal, and the page disappears if it has no multiplexer.
    /// Which page is showing is the user's choice and is preserved.
    private func rebindMultiplexerIfNeeded() {
        guard isActive, tabsModel?.selectedTabID != multiplexerHostTabID else { return }
        let wasShowing = showsMultiplexer
        attachMultiplexer()
        showsMultiplexer = wasShowing && multiplexerAttached
    }

    /// Open on the multiplexer page when the selected tab's terminal is
    /// attached to one and the feed can serve it.
    private func attachMultiplexer() {
        multiplexerAttached = false
        showsMultiplexer = false
        // Remember the tab that was evaluated even when it has no
        // multiplexer, so the rebind check does not re-probe every refresh.
        multiplexerHostTabID = tabsModel?.selectedTabID
        isAttachingMultiplexer = true
        defer { isAttachingMultiplexer = false }
        guard TabExposeSettings.multiplexerEnabled() else { return }
        guard let feed = muxFeed, let terminal = multiplexerTerminal?() else { return }
        guard feed.start(terminal: terminal) else {
            // Whatever the feed was serving belongs to another tab now.
            feed.stop(grace: 1)
            return
        }
        // Still detecting: the page is adopted when the feed reports in.
        guard feed.isServing else { return }
        multiplexerAttached = true
        showsMultiplexer = true
    }

    private func rubberBanded(_ p: CGFloat) -> CGFloat {
        if p <= 0 { return 0 }
        if p <= 1 { return p }
        return 1 + 0.08 * tanh((p - 1) * 4)
    }

    /// Re-read the scope from the model. Tabs that left are dropped (their
    /// cells vanish); a new selection made elsewhere becomes a select.
    /// `force` rebuilds the cells even when the scope's membership is
    /// unchanged: the multiplexer feed revises pane layouts, titles, badges,
    /// the session's own current tab, and its header state under stable tab
    /// ids, and cells hold those values until they are rebuilt.
    func refreshScope(announce: Bool = true, force: Bool = false) {
        guard let tabsModel else { return }
        rebindMultiplexerIfNeeded()
        let list = scopeList()
        let scope = list.scopes.indices.contains(list.activeIndex) ? list.scopes[list.activeIndex] : nil
        let ids = scope?.tabIDs ?? []
        let title = scope?.title
        let scoped: Bool = {
            if list.scopes.count > 1 { return true }
            if case .flat = tabsModel.orderProjection.mode { return false }
            return true
        }()
        let multiplexerPage = scope?.isMultiplexer ?? false
        let scopeChanged = ids != tabIDs || multiplexerPage != showsMultiplexer
        let changed = scopeChanged || title != scopeTitle || scoped != isScoped
        // Only a real scope change pages; a stale direction must not leak
        // into a later announce.
        let transition = pendingScopeTransition
        pendingScopeTransition = nil
        let previousIDs = tabIDs
        tabIDs = ids
        scopeTitle = title
        isScoped = scoped
        showsMultiplexer = multiplexerPage
        guard isActive else { return }

        if ids.isEmpty, !multiplexerPage {
            forceHide(reason: "scopeEmpty")
            return
        }
        isRefreshingScope = true
        highlightChangedDuringRefresh = false
        defer { isRefreshingScope = false }
        if multiplexerPage {
            // The hero is the attached app tab; the highlight follows the
            // session's own current tab until the user moves it.
            heroTabID = tabsModel.selectedTabID
            if let h = highlightedTabID, !ids.contains(h) {
                highlightedTabID = scope?.currentID ?? ids.first
            } else if highlightedTabID == nil {
                highlightedTabID = scope?.currentID ?? ids.first
            }
            scopeTransition = scopeChanged ? transition : nil
            if scopeTransition != nil { previewTabIDs = previousIDs }
            if announce, changed || highlightChangedDuringRefresh || force {
                if changed { onScopeDidChange?(ids) }
                observer?.tabExposeDidChangeCells(self)
            } else {
                scopeTransition = nil
            }
            return
        }
        if let selected = tabsModel.selectedTabID, selected != heroTabID, ids.contains(selected) {
            if scopeChanged || phase == .settling(target: 0) {
                // The selection moved to another scope (group swipe, ⌘⌥[ ],
                // scope menu): stay up and re-scope around the new selection.
                heroTabID = selected
                highlightedTabID = selected
            } else if phase == .presented || phase == .interactive {
                // Selection changed within the scope (⌘N, sidebar): ride it out as a select.
                isRefreshingScope = false
                select(selected)
                return
            } else {
                heroTabID = selected
            }
        } else if let hero = heroTabID, !ids.contains(hero) {
            heroTabID = tabsModel.selectedTabID
        }
        if let h = highlightedTabID, !ids.contains(h) {
            highlightedTabID = scope?.currentID ?? ids.first
        }
        scopeTransition = scopeChanged ? transition : nil
        if scopeTransition != nil {
            // The old scope's page slides out: its renderers stay live through
            // the host's reconcile until the view drops it (`setScopePreview([])`).
            previewTabIDs = previousIDs
        }
        if announce, changed || highlightChangedDuringRefresh || force {
            if changed { onScopeDidChange?(ids) }
            observer?.tabExposeDidChangeCells(self)
        } else {
            scopeTransition = nil
        }
    }

    private func armScopeObservation() {
        guard isActive, let tabsModel else { return }
        scopeObservationArmed = true
        withObservationTracking {
            _ = tabsModel.orderProjection
            _ = tabsModel.selectedTabID
            _ = tabsModel.displayedTabID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.scopeObservationArmed else { return }
                self.refreshScope()
                self.armScopeObservation()
            }
        }
    }
}
