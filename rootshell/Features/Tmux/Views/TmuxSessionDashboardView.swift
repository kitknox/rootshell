//
//  TmuxSessionDashboardView.swift
//  rootshell
//
//  Session dashboard for a tmux -CC gateway: lists every session on the
//  server (name, window count, attached marker), switches the gateway's
//  attached session, and creates / renames / kills sessions. One control
//  client displays one session at a time (tmux gates %output on the attached
//  session), so switching re-attaches this gateway; to SHOW two sessions at
//  once, open a second gateway tab to the same host.
//

import SwiftUI
import UIKit

/// Sheet payload: which gateway's controller the dashboard drives.
struct TmuxDashboardRequest: Identifiable {
    let id = UUID()
    let controller: TmuxController
}

struct TmuxSessionDashboardView: View {
    let controller: TmuxController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    private static let maxRenderedWindowPreviewsPerSession = 8

    @State private var sessions: [TmuxControlSession] = []
    @State private var windowsBySession: [Int: [TmuxControlWindow]] = [:]
    @State private var expandedSessionIds: Set<Int> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var highlightedSessionId: Int?
    @State private var scrollTargetID: Int?
    @State private var isKeyboardNavigationActive = false
    @State private var arrowKeyRepeatManager = ArrowKeyRepeatManager()
    @State private var windowPreviewStates: [Int: WindowPreviewState] = [:]
    @State private var previewLoaderTasks: [Int: Task<Void, Never>] = [:]
    @State private var previewLoaderTokens: [Int: UUID] = [:]
    @State private var pendingWindowSelectionId: Int?

    // Create / rename alert state
    @State private var showingCreateAlert = false
    @State private var newSessionName = ""
    @State private var renameTarget: TmuxControlSession?
    @State private var renameText = ""
    // Confirmations
    @State private var killTarget: TmuxControlSession?
    @State private var switchTarget: TmuxControlSession?
    @State private var switchTargetWindow: TmuxControlWindow?
    @State private var showingDetachConfirmation = false

    // Window administration state
    private struct WindowActionTarget {
        let session: TmuxControlSession
        let window: TmuxControlWindow
    }
    private struct WindowMoveRequest {
        let session: TmuxControlSession
        let window: TmuxControlWindow
        let destination: TmuxControlSession
    }
    @State private var renameWindowTarget: WindowActionTarget?
    @State private var renameWindowText = ""
    @State private var killWindowTarget: WindowActionTarget?
    /// Moving the attached session's LAST window ends the session; that move
    /// is parked here pending an explicit confirmation.
    @State private var pendingLastWindowMove: WindowMoveRequest?
    /// Hidden window ids per session, for dimming + Show/Hide affordances.
    /// The current session mirrors `controller.hiddenWindowIds`; others are
    /// fetched alongside their window lists. (id=tmux-hidden-windows)
    @State private var hiddenBySession: [Int: Set<Int>] = [:]

    private enum WindowPreviewState: Equatable {
        case loading
        case loaded(String)
        case empty
        case failed
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                List {
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .themedRow()
                        }
                    }
                    Section("Gateway") {
                        gatewayRow
                            .themedRow()
                    }
                    Section {
                        ForEach(sessions) { session in
                            sessionRow(session)
                                .id(session.id)
                        }
                    } footer: {
                        Text("Switching re-attaches this tmux tab's client. To view two sessions at once, open a second connection to this host.")
                    }
                }
                .themedList()
                .onChange(of: scrollTargetID) { _, target in
                    guard let target else { return }
                    scrollProxy.scrollTo(target, anchor: .center)
                }
            }
            .navigationTitle("tmux Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newSessionName = ""
                        showingCreateAlert = true
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .disabled(controller.didEnd)
                }
            }
            .overlay {
                if isLoading && sessions.isEmpty {
                    ProgressView()
                }
            }
        }
        .overlay {
            ZStack {
                Button("") { handleEscapeKey() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .accessibilityHidden(true)

                TmuxDashboardKeyCommandHost(
                    isActive: isKeyboardInputActive,
                    onEscape: { handleEscapeKey() },
                    onMoveUp: { beginKeyboardMove(.up) },
                    onMoveDown: { beginKeyboardMove(.down) },
                    onStopUp: { arrowKeyRepeatManager.stop(direction: .up) },
                    onStopDown: { arrowKeyRepeatManager.stop(direction: .down) },
                    onReturn: { _ = activateHighlightedSession() },
                    onSpace: { _ = toggleHighlightedSessionExpansion() }
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
        .background {
            dialogPresenter
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .presentationDetents([.medium, .large], selection: .constant(.large))
        .task { await refresh() }
        .onDisappear {
            arrowKeyRepeatManager.stop()
            cancelAllPreviewLoaders()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tmuxSessionsDidChange)) { note in
            guard isOurGateway(note) else { return }
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tmuxAttachedSessionDidChange)) { note in
            guard isOurGateway(note) else { return }
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tmuxControlModeDidEnd)) { note in
            guard isOurGateway(note) else { return }
            dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tmuxHiddenWindowsDidChange)) { note in
            guard isOurGateway(note), let sessionId = controller.currentSessionId else { return }
            hiddenBySession[sessionId] = controller.hiddenWindowIds
        }
    }

    private var dialogPresenter: some View {
        ZStack {
            createSessionDialog
            renameSessionDialog
            killSessionDialog
            switchSessionDialog
            detachGatewayDialog
            renameWindowDialog
            killWindowDialog
            moveLastWindowDialog
        }
    }

    private var createSessionDialog: some View {
        Color.clear.alert("New Session", isPresented: $showingCreateAlert) {
            TextField("Session name", text: $newSessionName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Create & Switch") {
                let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await run { try await controller.createSession(named: name, andSwitch: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a new tmux session on this server and switches this tab's client to it.")
        }
    }

    private var renameSessionDialog: some View {
        Color.clear.alert("Rename Session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Session name", text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Rename") {
                guard let target = renameTarget else { return }
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await run { try await controller.renameSession(id: target.id, to: name) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var killSessionDialog: some View {
        Color.clear.confirmationDialog(
            killConfirmationTitle,
            isPresented: Binding(
                get: { killTarget != nil },
                set: { if !$0 { killTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Kill Session", role: .destructive) {
                guard let target = killTarget else { return }
                let fallback = sessions.first(where: { $0.id != target.id })?.id
                Task { await run { try await controller.killSession(id: target.id, fallback: fallback) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(killConfirmationMessage)
        }
    }

    private var switchSessionDialog: some View {
        Color.clear.confirmationDialog(
            "Switch Session",
            isPresented: Binding(
                get: { switchTarget != nil },
                set: {
                    if !$0 {
                        switchTarget = nil
                        switchTargetWindow = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Switch", role: .destructive) {
                guard let target = switchTarget else { return }
                if let window = switchTargetWindow {
                    pendingWindowSelectionId = window.id
                    Task { await selectWindowAndDismiss(window, in: target) }
                } else {
                    Task { await switchAndDismiss(to: target.id) }
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This session is attached elsewhere. All attached clients mirror the same windows.")
        }
    }

    private var detachGatewayDialog: some View {
        Color.clear.confirmationDialog(
            "Detach Session?",
            isPresented: $showingDetachConfirmation,
            titleVisibility: .visible
        ) {
            Button("Detach Session", role: .destructive) {
                detachGateway()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leaves tmux control mode for this connection. Window tabs close; sessions keep running on the server.")
        }
    }

    private var renameWindowDialog: some View {
        Color.clear.alert("Rename Tab", isPresented: Binding(
            get: { renameWindowTarget != nil },
            set: { if !$0 { renameWindowTarget = nil } }
        )) {
            TextField("Tab name", text: $renameWindowText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Rename") {
                guard let target = renameWindowTarget else { return }
                let name = renameWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await run { try await controller.renameWindow(id: target.window.id, to: name) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var killWindowDialog: some View {
        Color.clear.confirmationDialog(
            killWindowConfirmationTitle,
            isPresented: Binding(
                get: { killWindowTarget != nil },
                set: { if !$0 { killWindowTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Kill Window", role: .destructive) {
                guard let target = killWindowTarget else { return }
                Task { await run { try await controller.killWindow(id: target.window.id) } }
            }
            if killWindowTarget?.window.isLinked == true {
                // Killing destroys the window in EVERY session it's linked
                // into; unlinking removes it from just this one.
                Button("Unlink from This Session") {
                    guard let target = killWindowTarget else { return }
                    Task { await run { try await controller.unlinkWindow(id: target.window.id) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(killWindowConfirmationMessage)
        }
    }

    private var moveLastWindowDialog: some View {
        Color.clear.confirmationDialog(
            "Move Last Window?",
            isPresented: Binding(
                get: { pendingLastWindowMove != nil },
                set: { if !$0 { pendingLastWindowMove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move Window", role: .destructive) {
                guard let request = pendingLastWindowMove else { return }
                Task { await run { try await controller.moveWindow(id: request.window.id, toSession: request.destination.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is the session's only window: moving it ends the session and this tab's client detaches.")
        }
    }

    private var killWindowConfirmationTitle: String {
        guard let killWindowTarget else { return "Kill Window" }
        let name = killWindowTarget.window.name
        return "Kill \u{201C}\(name.isEmpty ? "Untitled" : name)\u{201D}?"
    }

    private var killWindowConfirmationMessage: String {
        guard let target = killWindowTarget else {
            return "Ends every pane in this window."
        }
        let isAttachedSession = target.session.id == controller.currentSessionId
        if isAttachedSession, target.session.windowCount <= 1 {
            if sessions.count <= 1 {
                return "This is the only window of the only session: tmux will exit and this tab returns to a shell."
            }
            return "This is the session's only window: the session will end and this tab's client detaches."
        }
        if target.window.isLinked {
            return "This window is linked into more than one session; killing it removes it everywhere."
        }
        return "Ends every pane in this window."
    }

    private var killConfirmationTitle: String {
        guard let killTarget else { return "Kill Session" }
        return "Kill \u{201C}\(killTarget.name)\u{201D}?"
    }

    private var killConfirmationMessage: String {
        guard let killTarget else {
            return "Ends every window and pane in this session."
        }
        if killTarget.id == controller.currentSessionId, sessions.count <= 1 {
            return "This is the only session: tmux will exit and this tab returns to a shell."
        }
        if killTarget.id == controller.currentSessionId {
            return "You are attached to this session; this tab will switch to another session first."
        }
        return "Ends every window and pane in this session."
    }

    private var gatewayRow: some View {
        HStack(spacing: 10) {
            Button {
                if controller.selectGatewayTab() {
                    dismiss()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: controller.gatewaySourceSystemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)

                    Text(controller.gatewaySourceDisplayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.didEnd)
            .accessibilityLabel("Gateway \(controller.gatewaySourceDisplayName)")

            Button {
                showingDetachConfirmation = true
            } label: {
                Image(systemName: "eject")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(controller.didEnd)
            .accessibilityLabel("Detach Session")

            // Evict every OTHER client (e.g. a small-screen device left
            // attached, clamping the shared window). Shown only while other
            // clients are attached, using the freshly-refreshed session list.
            // (id=tmux-detach-other-clients)
            if otherAttachedClientCount > 0 {
                Button {
                    Task { await detachOthers() }
                } label: {
                    Image(systemName: "person.2.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(controller.didEnd)
                .accessibilityLabel("Detach ^[\(otherAttachedClientCount) other client](inflect: true)")
            }
        }
    }

    /// Clients other than us attached anywhere on the server, from the
    /// freshly-loaded `sessions` list (one attached client is always us).
    private var otherAttachedClientCount: Int {
        max(0, sessions.reduce(0) { $0 + $1.attachedClients } - 1)
    }

    @ViewBuilder
    private func sessionRow(_ session: TmuxControlSession) -> some View {
        let isCurrent = session.id == controller.currentSessionId
        let isHighlighted = isSessionHighlighted(session)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Tapping a session SWITCHES to it (the dashboard's primary
                // action). The current session's row expands its window list
                // instead. Both buttons need an explicit non-default style:
                // with a single default Button, List makes the WHOLE row one
                // tap target and the second button never fires.
                Button {
                    if isCurrent {
                        toggleExpanded(session)
                    } else {
                        requestSwitch(to: session)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.name)
                                .fontWeight(isCurrent ? .semibold : .regular)
                            if isCurrent {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .imageScale(.small)
                            }
                        }
                        HStack(spacing: 8) {
                            Text("\(session.windowCount) window\(session.windowCount == 1 ? "" : "s")")
                            if isCurrent {
                                Text("current")
                            } else if session.isAttachedSomewhere {
                                Text("attached")
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    toggleExpanded(session)
                } label: {
                    Image(systemName: expandedSessionIds.contains(session.id) ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }

            if expandedSessionIds.contains(session.id) {
                windowList(for: session)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                killTarget = session
            } label: {
                Label("Kill", systemImage: "trash")
            }
        }
        .contextMenu {
            if !isCurrent {
                Button {
                    requestSwitch(to: session)
                } label: {
                    Label("Switch to Session", systemImage: "arrow.right.circle")
                }
            }
            Button {
                beginRename(session)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                killTarget = session
            } label: {
                Label("Kill Session", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                beginRename(session)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)

            if !isCurrent {
                Button {
                    requestSwitch(to: session)
                } label: {
                    Label("Switch", systemImage: "arrow.right.circle")
                }
                .tint(.accentColor)
            }
        }
        .listRowBackground(rowBackground(isCurrent: isCurrent, isHighlighted: isHighlighted))
    }

    @ViewBuilder
    private func windowList(for session: TmuxControlSession) -> some View {
        if let windows = windowsBySession[session.id] {
            if windows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.tertiary)
                        Text("No windows")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    newWindowRow(for: session)
                }
                .padding(.leading, 12)
                .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(windows) { window in
                        windowCard(window, in: session)
                    }
                    newWindowRow(for: session)
                }
                .padding(.leading, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading windows")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.vertical, 6)
            .padding(.leading, 12)
        }
    }

    private func windowCard(_ window: TmuxControlWindow, in session: TmuxControlSession) -> some View {
        let isSelecting = pendingWindowSelectionId == window.id
        let isHidden = isWindowHidden(window, in: session)
        let isAttachedSession = session.id == controller.currentSessionId

        // NOT a Button: the Show/Hide control inside the card is a real
        // Button, and nesting it in an outer Button makes a single eye tap
        // fire BOTH actions — the select would instantly re-show a window
        // just hidden (and dismiss the sheet). A tap gesture on the card +
        // sibling buttons inside is the reliable arrangement.
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text("\(window.index)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: Capsule())

                Text(window.name.isEmpty ? "Untitled" : window.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if window.isActive {
                    Text("active")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.14), in: Capsule())
                }

                if window.isLinked {
                    Text("linked")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }

                if isHidden {
                    Text("hidden")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }

                Spacer(minLength: 8)

                Label(
                    "\(window.paneCount)",
                    systemImage: window.paneCount == 1 ? "rectangle" : "rectangle.split.2x1"
                )
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .accessibilityLabel("\(window.paneCount) pane\(window.paneCount == 1 ? "" : "s")")

                // Show/Hide toggle: only the attached session's windows
                // can be hidden from this gateway (the controller only
                // projects that session). (id=tmux-hidden-windows)
                if isAttachedSession {
                    Button {
                        if isHidden {
                            controller.showWindow(windowId: window.id, andSelect: false)
                        } else {
                            controller.hideWindow(windowId: window.id)
                        }
                        hiddenBySession[session.id] = controller.hiddenWindowIds
                    } label: {
                        Image(systemName: isHidden ? "eye" : "eye.slash")
                            .imageScale(.medium)
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isHidden ? "Show tab" : "Hide tab")
                }

                if isSelecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.forward.circle.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.tertiary)
                }
            }

            windowPreview(for: window, in: session)
        }
        .disabled(controller.didEnd || (pendingWindowSelectionId != nil && !isSelecting))
        .padding(10)
        .background(windowCardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelecting ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.07))
        }
        .opacity(cardOpacity(isSelecting: isSelecting, isHidden: isHidden))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            guard !controller.didEnd, pendingWindowSelectionId == nil else { return }
            selectWindow(window, in: session)
        }
        .contextMenu {
            windowContextMenu(window, in: session)
        }
        .accessibilityLabel("Open tmux window \(window.index), \(window.name.isEmpty ? "Untitled" : window.name)")
        .accessibilityAddTraits(.isButton)
    }

    private func cardOpacity(isSelecting: Bool, isHidden: Bool) -> Double {
        if pendingWindowSelectionId != nil && !isSelecting { return 0.62 }
        if isHidden { return 0.55 }
        return 1
    }

    private func isWindowHidden(_ window: TmuxControlWindow, in session: TmuxControlSession) -> Bool {
        if session.id == controller.currentSessionId {
            return controller.isWindowHidden(window.id)
        }
        return hiddenBySession[session.id]?.contains(window.id) ?? false
    }

    @ViewBuilder
    private func windowContextMenu(_ window: TmuxControlWindow, in session: TmuxControlSession) -> some View {
        Button {
            renameWindowTarget = WindowActionTarget(session: session, window: window)
            renameWindowText = window.name
        } label: {
            Label("Rename Tab", systemImage: "pencil")
        }

        let otherSessions = sessions.filter { $0.id != session.id }
        if !otherSessions.isEmpty {
            Menu {
                ForEach(otherSessions) { destination in
                    Button(destination.name) {
                        requestMoveWindow(window, from: session, to: destination)
                    }
                }
            } label: {
                Label("Move to Session", systemImage: "arrow.turn.up.right")
            }
            Menu {
                ForEach(otherSessions) { destination in
                    Button(destination.name) {
                        Task { await run { try await controller.linkWindow(id: window.id, toSession: destination.id) } }
                    }
                }
            } label: {
                Label("Link to Session", systemImage: "link")
            }
        }
        if window.isLinked {
            Button {
                Task { await run { try await controller.unlinkWindow(id: window.id) } }
            } label: {
                Label("Unlink from Session", systemImage: "link.badge.minus")
            }
        }

        if session.id == controller.currentSessionId {
            let isHidden = isWindowHidden(window, in: session)
            Button {
                if isHidden {
                    controller.showWindow(windowId: window.id, andSelect: false)
                } else {
                    controller.hideWindow(windowId: window.id)
                }
                hiddenBySession[session.id] = controller.hiddenWindowIds
            } label: {
                Label(isHidden ? "Show Tab" : "Hide Tab",
                      systemImage: isHidden ? "eye" : "eye.slash")
            }
        }

        Divider()
        Button(role: .destructive) {
            killWindowTarget = WindowActionTarget(session: session, window: window)
        } label: {
            Label("Kill Window", systemImage: "trash")
        }
    }

    private func requestMoveWindow(
        _ window: TmuxControlWindow,
        from session: TmuxControlSession,
        to destination: TmuxControlSession
    ) {
        if session.id == controller.currentSessionId, session.windowCount <= 1 {
            pendingLastWindowMove = WindowMoveRequest(
                session: session, window: window, destination: destination)
            return
        }
        Task { await run { try await controller.moveWindow(id: window.id, toSession: destination.id) } }
    }

    private func newWindowRow(for session: TmuxControlSession) -> some View {
        Button {
            Task { await run { try await controller.createWindow(inSession: session.id) } }
        } label: {
            Label("New Window", systemImage: "plus")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.didEnd)
        .accessibilityLabel("New window in \(session.name)")
    }

    @ViewBuilder
    private func windowPreview(for window: TmuxControlWindow, in session: TmuxControlSession) -> some View {
        if !shouldRenderPreview(for: window, in: session) {
            previewPlaceholder(
                systemImage: "rectangle.stack",
                title: "Preview deferred",
                showsProgress: false
            )
        } else {
            switch windowPreviewStates[window.id] ?? .loading {
            case .loading:
                previewPlaceholder(
                    systemImage: "hourglass",
                    title: "Loading preview",
                    showsProgress: true
                )
            case .loaded(let content):
                capturedPreview(content)
            case .empty:
                previewPlaceholder(
                    systemImage: "rectangle.dashed",
                    title: "No visible output",
                    showsProgress: false
                )
            case .failed:
                previewPlaceholder(
                    systemImage: "exclamationmark.triangle",
                    title: "Preview unavailable",
                    showsProgress: false
                )
            }
        }
    }

    private func capturedPreview(_ content: String) -> some View {
        let previewScale: CGFloat = 0.44
        let displayHeight: CGFloat = 136
        let virtualHeight = displayHeight / previewScale

        return GeometryReader { geo in
            let virtualWidth = max(1, geo.size.width / previewScale)

            TmuxPreviewContainer(
                content: content,
                previewSize: CGSize(width: virtualWidth, height: virtualHeight)
            )
            .frame(width: virtualWidth, height: virtualHeight)
            .scaleEffect(previewScale, anchor: .topLeading)
        }
        .frame(height: displayHeight)
        .background(previewBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        }
        .accessibilityLabel("Window preview")
    }

    private func previewPlaceholder(
        systemImage: String,
        title: String,
        showsProgress: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(previewBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private var windowCardBackground: Color {
        if let sheetThemeColors {
            return sheetThemeColors.background.opacity(0.42)
        }
        return Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var previewBackground: Color {
        Color.black.opacity(sheetThemeColors == nil ? 0.88 : 0.74)
    }

    // MARK: - Actions

    private func isOurGateway(_ note: Notification) -> Bool {
        (note.object as? UUID) == controller.ownerTerminalUUIDForNotifications
    }

    private func toggleExpanded(_ session: TmuxControlSession) {
        if expandedSessionIds.contains(session.id) {
            expandedSessionIds.remove(session.id)
            cancelPreviewLoader(for: session.id)
            return
        }
        expandedSessionIds.insert(session.id)
        if let windows = windowsBySession[session.id] {
            if !windows.isEmpty {
                startWindowPreviewLoader(for: session.id)
            }
        } else {
            Task { @MainActor in
                do {
                    let windows = try await controller.listWindows(sessionId: session.id)
                    windowsBySession[session.id] = windows
                    startWindowPreviewLoader(for: session.id)
                } catch {
                    windowsBySession[session.id] = []
                }
            }
        }
        refreshHiddenSet(for: session.id)
    }

    /// Refresh one session's hidden-window set for dimming/Show affordances.
    /// The current session reads the controller's live set; others round-trip
    /// `show @hidden`. (id=tmux-hidden-windows)
    private func refreshHiddenSet(for sessionId: Int) {
        if sessionId == controller.currentSessionId {
            hiddenBySession[sessionId] = controller.hiddenWindowIds
            return
        }
        Task { @MainActor in
            if let hidden = try? await controller.fetchHiddenWindows(sessionId: sessionId) {
                hiddenBySession[sessionId] = hidden
            }
        }
    }

    private func requestSwitch(to session: TmuxControlSession) {
        // A session that's already attached (another device, or another
        // gateway tab of ours) mirrors its windows to every client. Warn,
        // don't block — that's normal tmux multi-client behavior.
        if session.isAttachedSomewhere {
            switchTarget = session
            switchTargetWindow = nil
        } else {
            Task { await switchAndDismiss(to: session.id) }
        }
    }

    private func selectWindow(_ window: TmuxControlWindow, in session: TmuxControlSession) {
        guard pendingWindowSelectionId == nil, !controller.didEnd else { return }
        if session.id != controller.currentSessionId, session.isAttachedSomewhere {
            switchTarget = session
            switchTargetWindow = window
            return
        }
        pendingWindowSelectionId = window.id
        Task { @MainActor in
            await selectWindowAndDismiss(window, in: session)
        }
    }

    private func selectWindowAndDismiss(_ window: TmuxControlWindow, in session: TmuxControlSession) async {
        defer {
            if pendingWindowSelectionId == window.id {
                pendingWindowSelectionId = nil
            }
        }

        do {
            errorMessage = nil
            if session.id == controller.currentSessionId {
                if controller.selectWindowTab(windowId: window.id) {
                    dismiss()
                } else {
                    errorMessage = "That tmux window is not available yet."
                    await refresh()
                }
            } else {
                try await controller.switchToSession(id: session.id, selectingWindowId: window.id)
                dismiss()
            }
        } catch TmuxCommandError.gatewayEnded {
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginRename(_ session: TmuxControlSession) {
        renameTarget = session
        renameText = session.name
    }

    private var isKeyboardInputActive: Bool {
        !controller.didEnd
            && !showingCreateAlert
            && renameTarget == nil
            && killTarget == nil
            && switchTarget == nil
            && !showingDetachConfirmation
            && renameWindowTarget == nil
            && killWindowTarget == nil
            && pendingLastWindowMove == nil
    }

    private func handleEscapeKey() {
        dismiss()
    }

    private func beginKeyboardMove(_ direction: ArrowKeyRepeatManager.Direction) {
        guard isKeyboardInputActive else { return }
        switch (arrowKeyRepeatManager.activeDirection, direction) {
        case (.some(.up), .up), (.some(.down), .down):
            return
        default:
            break
        }
        let delta: Int
        switch direction {
        case .down:
            delta = 1
        case .up:
            delta = -1
        }
        moveHighlight(by: delta)
        arrowKeyRepeatManager.start(direction: direction) { [self] in
            moveHighlight(by: delta)
        }
    }

    private func isSessionHighlighted(_ session: TmuxControlSession) -> Bool {
        guard isKeyboardNavigationActive || KeyboardTracker.shared.isHardwareKeyboard else { return false }
        return highlightedSessionId == session.id
    }

    @discardableResult
    private func activateHighlightedSession() -> Bool {
        guard let session = highlightedSession() else { return false }
        isKeyboardNavigationActive = true
        if session.id == controller.currentSessionId {
            toggleExpanded(session)
        } else {
            requestSwitch(to: session)
        }
        return true
    }

    @discardableResult
    private func toggleHighlightedSessionExpansion() -> Bool {
        guard let session = highlightedSession() else { return false }
        isKeyboardNavigationActive = true
        toggleExpanded(session)
        return true
    }

    private func highlightedSession() -> TmuxControlSession? {
        if let highlightedSessionId,
           let session = sessions.first(where: { $0.id == highlightedSessionId }) {
            return session
        }
        return sessions.first(where: { $0.id == controller.currentSessionId }) ?? sessions.first
    }

    private func moveHighlight(by delta: Int) {
        guard !sessions.isEmpty else { return }
        isKeyboardNavigationActive = true
        let currentIndex = highlightedSession()
            .flatMap { highlighted in sessions.firstIndex(where: { $0.id == highlighted.id }) }
            ?? (delta > 0 ? -1 : sessions.count)
        let nextIndex = min(max(currentIndex + delta, 0), sessions.count - 1)
        let nextId = sessions[nextIndex].id
        highlightedSessionId = nextId
        scrollTargetID = nextId
    }

    private func reconcileHighlightedSession(previousHighlightedId: Int?) {
        if let previousHighlightedId,
           sessions.contains(where: { $0.id == previousHighlightedId }) {
            highlightedSessionId = previousHighlightedId
            return
        }

        highlightedSessionId = sessions.first(where: { $0.id == controller.currentSessionId })?.id
            ?? sessions.first?.id
        scrollTargetID = highlightedSessionId
    }

    private func rowBackground(isCurrent: Bool, isHighlighted: Bool) -> Color? {
        if isHighlighted {
            return Color.accentColor.opacity(0.24)
        }
        if isKeyboardNavigationActive || KeyboardTracker.shared.isHardwareKeyboard {
            return sheetThemeColors?.rowBackground
        }
        if isCurrent {
            return Color.accentColor.opacity(sheetThemeColors == nil ? 0.12 : 0.18)
        }
        return sheetThemeColors?.rowBackground
    }

    private func switchAndDismiss(to sessionId: Int) async {
        await run { try await controller.switchToSession(id: sessionId) }
        if errorMessage == nil { dismiss() }
    }

    private func detachGateway() {
        controller.detachGatewayClient()
    }

    /// Evict all other clients, then refresh so the count/button updates.
    /// `run(_:)` surfaces failures inline and re-lists sessions afterward.
    private func detachOthers() async {
        await run { try await controller.detachOtherClients() }
    }

    private func shouldRenderPreview(for window: TmuxControlWindow, in session: TmuxControlSession) -> Bool {
        previewWindowIds(for: session.id).contains(window.id)
    }

    private func previewWindowIds(
        for sessionId: Int,
        windows providedWindows: [TmuxControlWindow]? = nil
    ) -> Set<Int> {
        guard let windows = providedWindows ?? windowsBySession[sessionId],
              !windows.isEmpty else {
            return []
        }

        var ids: [Int] = []
        if let activeWindow = windows.first(where: \.isActive) {
            ids.append(activeWindow.id)
        }

        for window in windows where ids.count < Self.maxRenderedWindowPreviewsPerSession {
            guard !ids.contains(window.id) else { continue }
            ids.append(window.id)
        }

        return Set(ids)
    }

    private func hasMissingWindowPreview(for sessionId: Int) -> Bool {
        guard let windows = windowsBySession[sessionId], !windows.isEmpty else {
            return false
        }

        let previewIds = previewWindowIds(for: sessionId, windows: windows)
        return windows.contains { window in
            previewIds.contains(window.id) && windowPreviewStates[window.id] == nil
        }
    }

    private func startWindowPreviewLoader(for sessionId: Int) {
        guard previewLoaderTasks[sessionId] == nil,
              expandedSessionIds.contains(sessionId),
              hasMissingWindowPreview(for: sessionId) else {
            return
        }

        let token = UUID()
        previewLoaderTokens[sessionId] = token
        previewLoaderTasks[sessionId] = Task { @MainActor in
            defer {
                if previewLoaderTokens[sessionId] == token {
                    let shouldRestart = Task.isCancelled
                        && expandedSessionIds.contains(sessionId)
                        && hasMissingWindowPreview(for: sessionId)
                    previewLoaderTasks[sessionId] = nil
                    previewLoaderTokens[sessionId] = nil
                    if shouldRestart {
                        startWindowPreviewLoader(for: sessionId)
                    }
                }
            }

            while !Task.isCancelled,
                  expandedSessionIds.contains(sessionId),
                  let windows = windowsBySession[sessionId] {
                let previewIds = previewWindowIds(for: sessionId, windows: windows)
                guard let window = windows.first(where: {
                    previewIds.contains($0.id) && windowPreviewStates[$0.id] == nil
                }) else {
                    return
                }

                windowPreviewStates[window.id] = .loading
                do {
                    let content = try await controller.captureWindowPreview(windowId: window.id)
                    guard !Task.isCancelled else { return }
                    if let content {
                        windowPreviewStates[window.id] = .loaded(content)
                    } else {
                        windowPreviewStates[window.id] = .empty
                    }
                } catch TmuxCommandError.gatewayEnded {
                    guard !Task.isCancelled else { return }
                    dismiss()
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    windowPreviewStates[window.id] = .failed
                }
            }
        }
    }

    private func cancelPreviewLoader(for sessionId: Int) {
        previewLoaderTasks[sessionId]?.cancel()
        guard let windows = windowsBySession[sessionId] else { return }
        for window in windows where windowPreviewStates[window.id] == .loading {
            windowPreviewStates[window.id] = nil
        }
    }

    private func cancelAllPreviewLoaders() {
        for task in previewLoaderTasks.values {
            task.cancel()
        }
        previewLoaderTasks.removeAll()
        previewLoaderTokens.removeAll()
    }

    private func pruneWindowPreviewCache() {
        let knownWindowIds = Set(windowsBySession.values.flatMap { $0.map(\.id) })
        windowPreviewStates = windowPreviewStates.filter { knownWindowIds.contains($0.key) }

        for sessionId in Array(previewLoaderTasks.keys) where !expandedSessionIds.contains(sessionId) {
            cancelPreviewLoader(for: sessionId)
        }
    }

    private func refresh() async {
        // ownerSurfaceFreed: the gateway view freed its surface out from under a
        // dashboard that outlived a tab/scene teardown; dismiss instead of
        // querying through the dangling surface. ROOTSHELL-TMUX
        // (id=tmux-gateway-surface-freed)
        guard !controller.didEnd, !controller.ownerSurfaceFreed else {
            dismiss()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let previousHighlightedId = highlightedSessionId
            sessions = try await controller.listSessions()
            reconcileHighlightedSession(previousHighlightedId: previousHighlightedId)
            errorMessage = nil
            // Refresh any expanded sessions' window lists too (cheap, and the
            // refresh was likely triggered by topology churn).
            for id in expandedSessionIds {
                guard sessions.contains(where: { $0.id == id }) else {
                    expandedSessionIds.remove(id)
                    windowsBySession.removeValue(forKey: id)
                    cancelPreviewLoader(for: id)
                    continue
                }
                if let windows = try? await controller.listWindows(sessionId: id) {
                    windowsBySession[id] = windows
                    startWindowPreviewLoader(for: id)
                } else {
                    windowsBySession[id] = []
                }
                refreshHiddenSet(for: id)
            }
            pruneWindowPreviewCache()
        } catch TmuxCommandError.gatewayEnded {
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Run a session operation, surfacing failures inline and refreshing after.
    private func run(_ operation: () async throws -> Void) async {
        do {
            errorMessage = nil
            try await operation()
            await refresh()
        } catch TmuxCommandError.gatewayEnded {
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TmuxDashboardKeyCommandHost: UIViewControllerRepresentable {
    var isActive: Bool
    var onEscape: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onStopUp: () -> Void
    var onStopDown: () -> Void
    var onReturn: () -> Void
    var onSpace: () -> Void

    func makeUIViewController(context: Context) -> TmuxDashboardKeyCommandViewController {
        let viewController = TmuxDashboardKeyCommandViewController()
        updateUIViewController(viewController, context: context)
        return viewController
    }

    func updateUIViewController(_ uiViewController: TmuxDashboardKeyCommandViewController, context: Context) {
        uiViewController.configure(
            isActive: isActive,
            onEscape: onEscape,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onStopUp: onStopUp,
            onStopDown: onStopDown,
            onReturn: onReturn,
            onSpace: onSpace
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: TmuxDashboardKeyCommandViewController,
        coordinator: ()
    ) {
        uiViewController.resignKeyboardFocus()
    }
}

private final class TmuxDashboardKeyCommandViewController: UIViewController {
    private var isActive = true
    private var onEscape: (() -> Void)?
    private var onMoveUp: (() -> Void)?
    private var onMoveDown: (() -> Void)?
    private var onStopUp: (() -> Void)?
    private var onStopDown: (() -> Void)?
    private var onReturn: (() -> Void)?
    private var onSpace: (() -> Void)?

    override var canBecomeFirstResponder: Bool {
        isActive
    }

    override var keyCommands: [UIKeyCommand]? {
        guard isActive else { return nil }
        return [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleReturn)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleSpace))
        ]
    }

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateKeyboardFocus()
    }

    func configure(
        isActive: Bool,
        onEscape: @escaping () -> Void,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void,
        onStopUp: @escaping () -> Void,
        onStopDown: @escaping () -> Void,
        onReturn: @escaping () -> Void,
        onSpace: @escaping () -> Void
    ) {
        self.isActive = isActive
        self.onEscape = onEscape
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onStopUp = onStopUp
        self.onStopDown = onStopDown
        self.onReturn = onReturn
        self.onSpace = onSpace
        updateKeyboardFocus()
    }

    func resignKeyboardFocus() {
        if isFirstResponder {
            resignFirstResponder()
        }
    }

    private func updateKeyboardFocus() {
        if isActive {
            requestKeyboardFocus()
        } else {
            resignKeyboardFocus()
        }
    }

    private func requestKeyboardFocus() {
        guard isActive, isViewLoaded, view.window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.isViewLoaded, self.view.window != nil, !self.isFirstResponder else {
                return
            }
            self.becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isActive else {
            super.pressesBegan(presses, with: event)
            return
        }

        var remainingPresses = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                remainingPresses.insert(press)
                continue
            }

            switch key.keyCode {
            case .keyboardEscape:
                handleEscape()
            case .keyboardUpArrow:
                onMoveUp?()
            case .keyboardDownArrow:
                onMoveDown?()
            case .keyboardReturnOrEnter:
                onReturn?()
            case .keyboardSpacebar:
                onSpace?()
            default:
                remainingPresses.insert(press)
            }
        }

        if !remainingPresses.isEmpty {
            super.pressesBegan(remainingPresses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeatingArrows(for: presses, event: event, cancelled: false)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeatingArrows(for: presses, event: event, cancelled: true)
    }

    private func stopRepeatingArrows(
        for presses: Set<UIPress>,
        event: UIPressesEvent?,
        cancelled: Bool
    ) {
        var remainingPresses = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                remainingPresses.insert(press)
                continue
            }

            switch key.keyCode {
            case .keyboardUpArrow:
                onStopUp?()
            case .keyboardDownArrow:
                onStopDown?()
            default:
                remainingPresses.insert(press)
            }
        }

        guard !remainingPresses.isEmpty else { return }
        if cancelled {
            super.pressesCancelled(remainingPresses, with: event)
        } else {
            super.pressesEnded(remainingPresses, with: event)
        }
    }

    @objc private func handleEscape() {
        resignKeyboardFocus()
        onEscape?()
    }

    @objc private func handleReturn() {
        onReturn?()
    }

    @objc private func handleSpace() {
        onSpace?()
    }
}
