//
//  SessionPickerOverlay.swift
//  rootshell
//
//  Overlay for selecting an active multiplexer session (tmux/zellij/herdr/zmx) after SSH connection.
//

import SwiftUI

/// Why the picker is showing no rows. Only a user-invoked run presents a card
/// without results, so each case names something the user can act on.
enum SessionDiscoveryPlaceholder: Equatable {
    /// Scan in flight.
    case searching
    /// Scan finished and the host reported no sessions.
    case empty
    /// Scan could not complete: timeout, auth failure, helper unavailable.
    case failed
    /// Every multiplexer's discovery setting is off, so nothing was scanned.
    case disabled
    /// The local shell is scannable but "Discover Local Sessions" is off. Distinct
    /// from `disabled`: the per-multiplexer toggles may all be on.
    case localDisabled
    /// This surface cannot be scanned at all (not SSH-backed, no local shell).
    case unsupported
}

struct SessionPickerOverlay: View {
    let sessions: [MultiplexerSession]
    let sessionTypes: Set<MultiplexerType>
    let selectedIndex: Int
    let hasUserTyped: Bool
    /// Set when the card is up with no rows, saying why. Nil once rows exist.
    let placeholder: SessionDiscoveryPlaceholder?
    @Binding var tmuxAttachMode: TmuxAutoMode
    let allowsTmuxControlAttach: Bool
    @Binding var herdrAttachMode: HerdrAutoMode
    let allowsHerdrControlAttach: Bool
    let onSelect: (MultiplexerSession) -> Void
    let onChangeSelection: (Int) -> Void
    let onDismiss: () -> Void

    @State private var showAttachConfirmation = false
    @State private var pendingSession: MultiplexerSession?

    private var title: String {
        if sessionTypes.count == 1, let type = sessionTypes.first {
            return "\(type.rawValue) Sessions"
        }
        return "Terminal Sessions"
    }

    /// No rows to show.
    private var isPlaceholder: Bool { sessions.isEmpty }

    private var isSearching: Bool { placeholder == .searching }

    private var headerIcon: String {
        // Single-type pickers show that multiplexer's own icon; mixed pickers
        // fall back to tmux's, which reads as a generic "panes" glyph.
        if sessionTypes.count == 1, let type = sessionTypes.first {
            return type.iconName
        }
        return MultiplexerType.tmux.iconName
    }

    private var isMixed: Bool { sessionTypes.count > 1 }

    private var showsTmuxAttachModeToggle: Bool {
        allowsTmuxControlAttach && sessionTypes.contains(.tmux)
    }

    private var tmuxControlModeBinding: Binding<Bool> {
        Binding(
            get: { tmuxAttachMode == .control },
            set: { tmuxAttachMode = $0 ? .control : .regular }
        )
    }

    private var showsHerdrAttachModeToggle: Bool {
        allowsHerdrControlAttach && sessionTypes.contains(.herdr)
    }

    private var herdrControlModeBinding: Binding<Bool> {
        Binding(
            get: { herdrAttachMode == .control },
            set: { herdrAttachMode = $0 ? .control : .regular }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 500
            let horizontalPadding: CGFloat = isCompact ? 12 : 32
            let maxCardWidth: CGFloat = isCompact ? .infinity : 540

            ZStack(alignment: isCompact ? .top : .center) {
                // Tap-to-dismiss background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(spacing: 10) {
                        Image(systemName: headerIcon)
                            .font(.system(size: isCompact ? 14 : 20, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(title)
                            .font(.system(size: isCompact ? 14 : 18, weight: .semibold))

                        Spacer()

                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("\(sessions.count)")
                                .font(.system(size: isCompact ? 12 : 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.fill.tertiary, in: Capsule())
                        }
                    }
                    .padding(.horizontal, isCompact ? 16 : 20)
                    .padding(.top, isCompact ? 14 : 18)
                    .padding(.bottom, isCompact ? 10 : 14)

                    Divider()
                        .padding(.horizontal, 12)

                    // Session list
                    if isPlaceholder {
                        placeholderBody(compact: isCompact)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 2) {
                                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                        sessionRow(session: session, index: index, isSelected: index == selectedIndex, compact: isCompact)
                                            .id(index)
                                            .onTapGesture { handleRowTap(session: session, index: index) }
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                            }
                            .frame(maxHeight: isCompact ? 300 : 500)
                            .onChange(of: selectedIndex) { _, newIndex in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo(newIndex, anchor: .center)
                                }
                            }
                        }
                    }

                    Divider()
                        .padding(.horizontal, 12)

                    if showsTmuxAttachModeToggle, !isPlaceholder {
                        tmuxAttachModeToggle(compact: isCompact)

                        Divider()
                            .padding(.horizontal, 12)
                    }

                    if showsHerdrAttachModeToggle, !isPlaceholder {
                        herdrAttachModeToggle(compact: isCompact)

                        Divider()
                            .padding(.horizontal, 12)
                    }

                    // Footer
                    if KeyboardTracker.shared.isHardwareKeyboard {
                        // Hardware keyboard hints. With no rows there is nothing
                        // to navigate or attach to, so only dismiss applies.
                        HStack(spacing: isCompact ? 8 : 16) {
                            hintBadge("Esc", label: "dismiss", compact: isCompact)
                            if !isPlaceholder {
                                hintBadge("\u{2191}\u{2193}", label: "navigate", compact: isCompact)
                                hintBadge("\u{21A9}", label: "attach", compact: isCompact)
                                if let jumpKeys = digitJumpKeys {
                                    hintBadge(jumpKeys, label: "jump", compact: isCompact)
                                }
                            }
                        }
                        .padding(.horizontal, isCompact ? 16 : 20)
                        .padding(.vertical, isCompact ? 10 : 14)
                    } else {
                        // Touch-only hint
                        HStack {
                            Text(isPlaceholder
                                 ? "Tap outside to dismiss"
                                 : "Tap a session to select, tap Attach to connect")
                                .font(.system(size: isCompact ? 10 : 12))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, isCompact ? 16 : 20)
                        .padding(.vertical, isCompact ? 8 : 10)
                    }
                }
                .overlayCardBackground()
                .frame(maxWidth: maxCardWidth)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, isCompact ? 8 : 0)
            }
        }
        .alert("Attach to Session?", isPresented: $showAttachConfirmation) {
            Button("Attach") {
                if let session = pendingSession {
                    onSelect(session)
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingSession = nil
            }
        } message: {
            if let session = pendingSession {
                Text("You've already started typing. Attach to \"\(session.name)\" anyway? This will send a \(attachDescription(for: session)) command to the terminal.")
            }
        }
    }

    /// Stands in for the session list on a user-invoked run with no rows.
    @ViewBuilder
    private func placeholderBody(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 8) {
            if isSearching {
                ProgressView()
                    .controlSize(.regular)
                Text("Searching for sessions…")
                    .font(.system(size: compact ? 12 : 14, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: placeholderIcon)
                    .font(.system(size: compact ? 18 : 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(placeholderTitle)
                    .font(.system(size: compact ? 12 : 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(placeholderDetail)
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.vertical, compact ? 24 : 32)
    }

    private var placeholderIcon: String {
        switch placeholder {
        case .failed: return "exclamationmark.triangle"
        case .disabled, .localDisabled: return "slider.horizontal.3"
        case .unsupported: return "minus.circle"
        default: return "magnifyingglass"
        }
    }

    private var placeholderTitle: String {
        switch placeholder {
        case .failed: return String(localized: "Could not check for sessions")
        case .disabled, .localDisabled: return String(localized: "Session discovery is off")
        case .unsupported: return String(localized: "This tab cannot be checked")
        default: return String(localized: "No sessions found")
        }
    }

    private var placeholderDetail: String {
        switch placeholder {
        case .failed:
            return String(localized: "The host did not answer in time, or the connection could not be reused.")
        case .disabled:
            return String(localized: "Turn on discovery for tmux, zellij, herdr or zmx in Settings.")
        case .localDisabled:
            // Names the setting that actually gates this, which is not one of the
            // per-multiplexer toggles. Interpolated so it tracks the Settings row.
            return String(localized: "Turn on \(Settings.Multiplexer.localSessionDiscovery.title) in Settings.")
        case .unsupported:
            // The local shell is only a discovery surface on unsandboxed Catalyst,
            // where the helper can run the scan.
            #if STANDALONE && targetEnvironment(macCatalyst)
            return String(localized: "Discovery needs an SSH connection or the local shell.")
            #else
            return String(localized: "Discovery needs an SSH connection.")
            #endif
        default:
            // Deliberately names no multiplexer: only the types still enabled in
            // Settings were scanned, so a fixed list would over-claim.
            return String(localized: "This host has no multiplexer sessions to attach to.")
        }
    }

    @ViewBuilder
    private func tmuxAttachModeToggle(compact: Bool) -> some View {
        Toggle(isOn: tmuxControlModeBinding) {
            Label {
                Text(isMixed ? "tmux control mode" : "Control mode")
                    .font(.system(size: compact ? 12 : 14, weight: .medium))
            } icon: {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: compact ? 11 : 13, weight: .medium))
            }
        }
        .toggleStyle(.switch)
        .controlSize(compact ? .small : .regular)
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.vertical, compact ? 8 : 10)
    }

    /// The host's herdr lacks control streams: control mode still works,
    /// but with server-rendered panes and polled topology.
    private var herdrControlIsDegraded: Bool {
        sessions.contains { $0.type == .herdr && $0.supportsControlStream == false }
    }

    @ViewBuilder
    private func herdrAttachModeToggle(compact: Bool) -> some View {
        Toggle(isOn: herdrControlModeBinding) {
            Label {
                let base = isMixed ? "herdr control mode" : "Control mode"
                Text(herdrControlIsDegraded ? "\(base) (degraded, upgrade herdr)" : base)
                    .font(.system(size: compact ? 12 : 14, weight: .medium))
            } icon: {
                Image(systemName: MultiplexerType.herdr.iconName)
                    .font(.system(size: compact ? 11 : 13, weight: .medium))
            }
        }
        .toggleStyle(.switch)
        .controlSize(compact ? .small : .regular)
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.vertical, compact ? 8 : 10)
    }

    @ViewBuilder
    private func sessionRow(session: MultiplexerSession, index: Int, isSelected: Bool, compact: Bool) -> some View {
        VStack(spacing: 0) {
            // Metadata row
            sessionRowMetadata(session: session, isSelected: isSelected, compact: compact)

            // Preview (only for selected row with captured content)
            if isSelected, let content = session.capturedContent, !content.isEmpty {
                let previewScale: CGFloat = 0.45
                let isSingle = sessions.count == 1
                let displayHeight: CGFloat = isSingle
                    ? (compact ? 140 : 280)
                    : (compact ? 100 : 150)
                let virtualHeight = displayHeight / previewScale

                GeometryReader { geo in
                    let virtualWidth = geo.size.width / previewScale

                    TmuxPreviewContainer(
                        content: content,
                        previewSize: CGSize(width: virtualWidth, height: virtualHeight)
                    )
                    .id(session.id)
                    .frame(width: virtualWidth, height: virtualHeight)
                    .scaleEffect(previewScale, anchor: .topLeading)
                }
                .frame(height: displayHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, compact ? 8 : 14)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }

            // Touch-only attach button for selected row
            if isSelected && !KeyboardTracker.shared.isHardwareKeyboard {
                Button("Attach") { handleAttach(session) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.vertical, compact ? 6 : 10)
        .background(
            isSelected
                ? AnyShapeStyle(.tint.opacity(0.12))
                : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func sessionRowMetadata(session: MultiplexerSession, isSelected: Bool, compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            // Selection indicator
            Image(systemName: isSelected ? "chevron.right" : "")
                .font(.system(size: compact ? 10 : 13, weight: .bold))
                .foregroundStyle(.tint)
                .frame(width: compact ? 12 : 16)

            // Session info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name)
                        .font(.system(size: compact ? 13 : 16, weight: .semibold, design: .monospaced))
                        .lineLimit(1)

                    // Type badge (only in mixed-type lists)
                    if isMixed {
                        Text(session.type.rawValue)
                            .font(.system(size: compact ? 9 : 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: Capsule())
                    }

                    // Status pill
                    Text(statusText(for: session))
                        .font(.system(size: compact ? 10 : 12, weight: .medium))
                        .foregroundStyle(statusColor(for: session))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            statusColor(for: session).opacity(0.15),
                            in: Capsule()
                        )

                    Text(session.detail)
                        .font(.system(size: compact ? 11 : 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                // Subtitle: active command + path (tmux) or empty (zellij)
                if let subtitle = session.subtitle {
                    Text(subtitle)
                        .font(.system(size: compact ? 11 : 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func statusText(for session: MultiplexerSession) -> String {
        // herdr sessions have no attached-client notion; stopped ones are
        // resurrected by attach, so "exited"/"detached" would mislead.
        if session.type == .herdr { return session.isExited ? "stopped" : "running" }
        if session.isExited { return "exited" }
        return session.isAttached ? "attached" : "detached"
    }

    private func statusColor(for session: MultiplexerSession) -> Color {
        if session.type == .herdr { return session.isExited ? .secondary : .green }
        if session.isExited { return .red }
        return session.isAttached ? .orange : .green
    }

    @ViewBuilder
    private func hintBadge(_ key: String, label: String, compact: Bool = false) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            Text(key)
                .font(.system(size: compact ? 10 : 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, compact ? 4 : 6)
                .padding(.vertical, compact ? 2 : 3)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: compact ? 10 : 12))
                .foregroundStyle(.tertiary)
        }
    }

    /// Returns the digit key hint string if all session names are single digits (e.g. "0,2,5"),
    /// or nil if any session has a non-numeric name or there are too many to display.
    private var digitJumpKeys: String? {
        guard sessions.count <= 6 else { return nil }
        let digitNames = sessions.compactMap { s -> String? in
            let n = s.name
            guard n.count == 1, n.first?.isWholeNumber == true else { return nil }
            return n
        }
        guard digitNames.count == sessions.count else { return nil }
        return digitNames.joined(separator: ",")
    }

    private func handleRowTap(session: MultiplexerSession, index: Int) {
        if KeyboardTracker.shared.isHardwareKeyboard {
            // Hardware keyboard: tap attaches directly (same as Enter)
            handleAttach(session)
        } else {
            // Touch: tap selects the row; use Attach button to connect
            onChangeSelection(index)
        }
    }

    private func handleAttach(_ session: MultiplexerSession) {
        if hasUserTyped {
            pendingSession = session
            showAttachConfirmation = true
        } else {
            onSelect(session)
        }
    }

    private func attachDescription(for session: MultiplexerSession) -> String {
        if session.type == .tmux, tmuxAttachMode == .control, allowsTmuxControlAttach {
            return "tmux -CC attach"
        }
        if session.type == .herdr, herdrAttachMode == .control, allowsHerdrControlAttach {
            return "herdr control"
        }
        return "\(session.type.rawValue) attach"
    }
}
