//
//  SidebarAgentUsageFooter.swift
//  rootshell
//
//  Subtle subscription-usage footer at the bottom of the vertical tab
//  sidebar: one compact row per provider with a live agent, tap for the
//  detail popover, plus a Live Weather row while that background is live.
//  Renders nothing when there is nothing to show — no
//  spinner, no placeholder.
//
//  A separate view so the `AgentUsageCenter.revision` read is scoped here
//  instead of to `VerticalTabSidebar.body`, mirroring SidebarAgentSummaryBar.
//

import SwiftUI
import UIKit

extension AgentUsageProvider: Identifiable {
    nonisolated var id: String { rawValue }
}

struct SidebarAgentUsageFooter: View {
    let metrics: SidebarMetrics
    let accentTint: Color
    let isDocked: Bool

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    /// The row whose popover is open, by `Row.id`. Keyed on the row and
    /// not the provider because the oh-my-pi lane yields one row per
    /// brand, and a provider-keyed binding opened all of them at once.
    @State private var popoverRowID: String?

    var body: some View {
        // Registers the Observation dependency; the value itself is meaningless.
        let _ = AgentUsageCenter.shared.revision
        let rows = AgentUsageCenter.shared.rows()
        if !rows.isEmpty || hasWeather {
            VStack(spacing: 2) {
                Divider()
                    .padding(.bottom, 3)
                ForEach(rows, id: \.id) { row in
                    Button {
                        popoverRowID = row.id
                    } label: {
                        UsageCompactRow(row: row, metrics: metrics, accentTint: accentTint)
                    }
                    .buttonStyle(.plain)
                    // Presented through UIKit, not SwiftUI's `.popover`: the
                    // SwiftUI popover measures its content through a hosting
                    // root whose keyboard avoidance can't be disabled from
                    // inside, so with the keyboard toolbar (or a floating
                    // keyboard) visible the reported height gained the whole
                    // keyboard safe-area inset and the popover stretched
                    // toward fullscreen. Owning the UIHostingController lets
                    // us drop `.keyboard` from its safe-area regions.
                    .background(AnchoredUsagePopover(
                        isPresented: Binding(
                            get: { popoverRowID == row.id },
                            set: { if !$0 { popoverRowID = nil } }
                        )
                    ) {
                        AgentUsageDetailPopover(row: row, accentTint: accentTint)
                            .themedSubSheet(sheetThemeColors)
                    })
                }
                #if !CHINA_BUILD
                SidebarWeatherRow(metrics: metrics)
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.bottom, bottomPadding)
        }
    }

    /// Live Weather's row, shown while a live weather background is on screen.
    private var hasWeather: Bool {
        #if CHINA_BUILD
        return false
        #else
        return WeatherStore.shared.sidebarSnapshot != nil
        #endif
    }

    private var bottomPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        // Keep pinned controls above macOS's bottom window-resize hit region.
        // iPad's safe area supplies this clearance automatically.
        return isDocked ? 14 : 6
        #else
        return 6
        #endif
    }
}

// MARK: - Compact row

private struct UsageCompactRow: View {
    let row: AgentUsageCenter.Row
    let metrics: SidebarMetrics
    let accentTint: Color

    var body: some View {
        HStack(spacing: 8) {
            // The brand's OWN mark, never oh-my-pi's: a usage row carries no
            // name text, so the mark is the only thing telling an xAI row
            // apart from a Z.AI one.
            AgentBrandMark(
                assetName: row.brand.assetName ?? "OhMyPiLogo",
                size: metrics.subtitleSize + 1
            )
                .frame(width: 20, alignment: .leading)

            // Only for a provider we have no mark for, so the row is still
            // identifiable instead of showing a second generic oh-my-pi
            // glyph. Lowest layout priority: the numbers win the space.
            if row.brand.assetName == nil {
                Text(verbatim: row.displayName)
                    .font(.system(size: metrics.subtitleSize))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }

            switch row.content {
            case .usage(let snapshot):
                HStack(spacing: 4) {
                    if let session = snapshot.session {
                        UsageMiniBar(window: session, accentTint: accentTint)
                    }
                    if let weekly = snapshot.weekly {
                        UsageMiniBar(window: weekly, accentTint: accentTint)
                    }
                    if let monthly = snapshot.monthly {
                        UsageMiniBar(window: monthly, accentTint: accentTint)
                    }
                }

                Spacer(minLength: 6)

                // An account whose lanes are all unlimited parses to zero
                // windows on purpose; say so rather than render an empty
                // row that reads as broken.
                Text(verbatim: snapshot.windows.isEmpty
                    ? String(
                        localized: "Unlimited",
                        comment: "Agent usage plan has no metered quotas")
                    : AgentUsageFormat.compactLine(windows: snapshot.windows))
                    .font(.system(size: metrics.subtitleSize, weight: .regular).monospacedDigit())
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText())
                    .lineLimit(1)

            case .unavailable(let reason):
                // Explaining the silence beats an empty footer: the remedy
                // for a remote Mac's locked keychain is not guessable.
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: metrics.subtitleSize - 2))
                    Text(verbatim: reason.shortLabel)
                        .font(.system(size: metrics.subtitleSize))
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(row.isStale ? 0.55 : 1.0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private var accessibilityLabel: String {
        switch row.content {
        case .usage(let snapshot):
            let usage = snapshot.windows.isEmpty
                ? String(
                    localized: "unlimited",
                    comment: "Accessibility: an agent usage plan has no metered quotas")
                : AgentUsageFormat.compactLine(windows: snapshot.windows)
            return String(
                localized: "\(row.displayName) usage, \(usage)",
                comment: "Accessibility: coding agent provider and current usage")
        case .unavailable(let reason):
            return String(
                localized: "\(row.displayName) usage unavailable, \(reason.shortLabel)",
                comment: "Accessibility: coding agent usage is unavailable")
        }
    }
}

/// 4pt capsule, band-colored fill. Small enough that the pace tick lives in
/// the popover instead.
private struct UsageMiniBar: View {
    let window: AgentUsageWindow
    let accentTint: Color

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.09))
            .frame(width: 36, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(AgentUsageBarStyle.color(for: window.usedPercent, accentTint: accentTint))
                    .frame(width: 36 * window.barFraction, height: 4)
            }
    }
}

enum AgentUsageBarStyle {
    static func color(for usedPercent: Double, accentTint: Color) -> Color {
        switch AgentUsageBand.band(usedPercent: usedPercent) {
        case .healthy: return accentTint.opacity(0.55)
        case .warning: return .orange.opacity(0.8)
        case .critical: return .red.opacity(0.85)
        case .depleted: return .red
        }
    }
}

// MARK: - Detail popover

private struct AgentUsageDetailPopover: View {
    /// The footer row this popover was opened from. Carries the brand as
    /// well as the provider, since one oh-my-pi lane covers several brands
    /// and the detail must show only the one that was tapped.
    let row: AgentUsageCenter.Row
    let accentTint: Color

    private var provider: AgentUsageProvider { row.provider }

    var body: some View {
        // REQUIRED, not hygiene: every field these rows come from is
        // @ObservationIgnored, so `revision` is the only thing that can
        // register a dependency. Without this read the popover never
        // re-rendered while open — a manual refresh landed, and the numbers
        // and "Updated ..." line only changed once it was reopened.
        let _ = AgentUsageCenter.shared.revision
        let accounts = AgentUsageCenter.shared
            .accountRows(provider: provider, brand: row.brand)
            .filter { $0.snapshot != nil }
        let lockedHosts = AgentUsageCenter.shared.keychainLockedHosts(provider: provider)

        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                if index > 0 { Divider() }
                AccountUsageSection(account: account, accentTint: accentTint)
            }

            if let reason {
                if !accounts.isEmpty { Divider() }
                VStack(alignment: .leading, spacing: 5) {
                    if accounts.isEmpty {
                        HStack(spacing: 6) {
                            AgentBrandMark(agentID: provider.rawValue, size: 14)
                            Text(verbatim: provider.displayName)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.bottom, 5)
                    }
                    Label {
                        Text(verbatim: reason.shortLabel)
                            .font(.system(size: 12, weight: .semibold))
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    if !lockedHosts.isEmpty {
                        Text(verbatim: lockedHosts.joined(separator: ", "))
                            .font(.system(size: 11).monospaced())
                            .foregroundColor(.secondary)
                    }
                    Text(verbatim: reason.detail(for: provider))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            RefreshControl(provider: provider)
        }
        .padding(14)
        .frame(width: 300)
    }

    /// The unavailable reason from the footer row, when that is what the
    /// user tapped.
    private var reason: AgentUsageUnavailableReason? {
        for row in AgentUsageCenter.shared.rows() where row.provider == provider {
            if case .unavailable(let reason) = row.content { return reason }
        }
        return nil
    }
}

/// UIKit-owned popover presentation for the usage detail. Exists because
/// SwiftUI's `.popover` sizes its chrome from a hosting root that always
/// keyboard-avoids: the measured ideal height gains the keyboard's full
/// safe-area inset, so with the keyboard toolbar or a floating keyboard
/// visible the popover stretched toward fullscreen, and no modifier inside
/// the content can reach that root. Here we own the UIHostingController,
/// remove `.keyboard` from its safe-area regions, and let
/// `preferredContentSize` track the content's real ideal size.
/// Also hosts the Live Weather detail, so both footer popovers match.
struct AnchoredUsagePopover<Content: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> AnchoredUsagePopoverCoordinator {
        AnchoredUsagePopoverCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        let content = self.content
        coordinator.makeContent = { AnyView(content()) }
        coordinator.isPresented = $isPresented
        if isPresented {
            if let presented = coordinator.presented {
                presented.rootView = coordinator.makeContent()
            } else {
                // Presenting during a SwiftUI update is unsafe; defer a turn.
                Task { @MainActor in coordinator.presentIfNeeded(from: view) }
            }
        } else if let presented = coordinator.presented {
            coordinator.presented = nil
            presented.dismiss(animated: true)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: AnchoredUsagePopoverCoordinator) {
        coordinator.presented?.dismiss(animated: false)
        coordinator.presented = nil
    }
}

/// Kept non-generic and outside `AnchoredUsagePopover` on purpose. As a
/// generic class nested in a generic struct, its implicit `deinit` segfaulted
/// the SIL performance inliner in Swift 6.3.2 (`EarlyPerfInliner` ->
/// `isCallerAndCalleeLayoutConstraintsCompatible`) while optimizing the
/// x86_64 Catalyst slice, so release archives failed even though every debug
/// build (arm64, -Onone) compiled. Erasing the content type keeps the
/// optimizer on ground it can handle.
@MainActor
final class AnchoredUsagePopoverCoordinator: NSObject, UIPopoverPresentationControllerDelegate {
    var isPresented: Binding<Bool> = .constant(false)
    var makeContent: () -> AnyView = { AnyView(EmptyView()) }
    var presented: UIHostingController<AnyView>?

    func presentIfNeeded(from anchor: UIView, attempt: Int = 0) {
        guard isPresented.wrappedValue,
              presented == nil,
              anchor.window != nil,
              let presenter = nearestViewController(from: anchor) else { return }

        // A sibling popover may still be animating its dismissal (rapid
        // taps between rows); presenting now would be silently dropped by
        // UIKit. Retry a few turns, then give up cleanly.
        if presenter.presentedViewController != nil {
            guard attempt < 10 else {
                isPresented.wrappedValue = false
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                self.presentIfNeeded(from: anchor, attempt: attempt + 1)
            }
            return
        }

        let host = UIHostingController(rootView: makeContent())
        host.modalPresentationStyle = .popover
        host.view.backgroundColor = .clear
        // The whole point of this type: content sized without keyboard
        // avoidance, and kept in sync with the content's ideal size.
        host.safeAreaRegions = .container
        host.sizingOptions = .preferredContentSize
        // Seed the size before presentation; sizingOptions only keeps it
        // updated after the first layout pass.
        host.preferredContentSize = host.sizeThatFits(
            in: CGSize(width: UIView.layoutFittingCompressedSize.width,
                       height: UIView.layoutFittingCompressedSize.height))

        if let popover = host.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
            popover.delegate = self
        }
        presented = host
        presenter.present(host, animated: true)
    }

    private func nearestViewController(from view: UIView) -> UIViewController? {
        var responder: UIResponder? = view.next
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    // Stay a popover in compact contexts too (matches the previous
    // `.presentationCompactAdaptation(.popover)`).
    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        presented = nil
        isPresented.wrappedValue = false
    }
}

/// Manual refresh. Usage is polled on a deliberately slow cadence (the
/// Claude endpoint punishes chatty clients), so the moments a person most
/// wants fresh numbers — just signed in, just unlocked a keychain, just
/// resumed an agent — are exactly the ones our own timer is worst at.
private struct RefreshControl: View {
    let provider: AgentUsageProvider

    var body: some View {
        let _ = AgentUsageCenter.shared.revision
        let isRefreshing = AgentUsageCenter.shared.refreshingProviders.contains(provider)
        // A 429 is the one case where refusing is the helpful answer:
        // retrying into an active window is how an hour-long lockout is won.
        let blockedUntil = AgentUsageCenter.shared.rateLimitedUntil(provider: provider)

        HStack(spacing: 6) {
            if let blockedUntil {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 11))
                Text("Rate limited, \(AgentUsageFormat.retryCountdown(until: blockedUntil, now: Date()))")
                    .font(.system(size: 11))
            } else {
                let refreshLabel = isRefreshing
                    ? String(localized: "Checking", comment: "Agent usage refresh in progress")
                    : String(localized: "Refresh", comment: "Refresh coding agent usage")
                Button {
                    AgentUsageCenter.shared.refreshNow(provider: provider)
                } label: {
                    HStack(spacing: 5) {
                        if isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(verbatim: refreshLabel)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            }
            Spacer()
        }
        .foregroundColor(.secondary)
    }
}

private struct AccountUsageSection: View {
    let account: AgentUsageCenter.Row
    let accentTint: Color

    private var now: Date { Date() }

    var body: some View {
        // Callers filter to rows that carry a snapshot.
        if let snapshot = account.snapshot {
            content(snapshot)
        }
    }

    private func content(_ snapshot: AgentUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                AgentBrandMark(
                    assetName: account.brand.assetName ?? "OhMyPiLogo",
                    size: 14)
                Text(verbatim: account.displayName)
                    .font(.system(size: 13, weight: .semibold))
                // Which account, when the source knows. oh-my-pi can hold
                // several logins for one brand and the sections were
                // otherwise identical down to the plan name.
                if let label = snapshot.accountLabel {
                    Text(verbatim: label)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let plan = snapshot.planLabel {
                    Text(verbatim: plan)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(verbatim: AgentUsageFormat.updatedAgo(
                    fetchedAt: snapshot.fetchedAt,
                    now: now))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                UsageWindowDetail(
                    window: window,
                    provider: account.provider,
                    accentTint: accentTint,
                    now: now)
            }

            if snapshot.windows.isEmpty {
                Text("No metered quotas on this plan.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if let credits = snapshot.creditsBalance {
                Text("Credits: \(Int(credits.rounded()))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// One window: label + used percent, a full-width bar, the pace tick under
/// it (where usage would sit at perfectly even burn), and the reset line.
private struct UsageWindowDetail: View {
    let window: AgentUsageWindow
    let provider: AgentUsageProvider
    let accentTint: Color
    let now: Date

    private var title: String {
        // Antigravity's session and weekly windows are its Gemini pool, shown
        // beside its Claude pool, so they say which pool they are.
        if provider == .antigravity {
            switch window.kind {
            case .session:
                return String(
                    localized: "Session (Gemini)",
                    comment: "Antigravity usage window title: Gemini five-hour pool")
            case .weekly:
                return String(
                    localized: "Week (Gemini)",
                    comment: "Antigravity usage window title: Gemini weekly pool")
            default:
                break
            }
        }
        switch window.kind {
        case .session:
            return String(
                localized: "Session (5h)",
                comment: "Agent usage window title: five-hour session")
        case .sessionModel(let model):
            return String(
                localized: "Session (\(model))",
                comment: "Agent usage window title for a specific model's five-hour window")
        case .weekly:
            return provider == .claude
                ? String(
                    localized: "Week (all models)",
                    comment: "Claude usage window title: all models")
                : String(
                    localized: "Weekly",
                    comment: "Agent usage window title: weekly quota")
        case .weeklyModel(let model):
            return String(
                localized: "Week (\(model))",
                comment: "Agent usage window title for a specific model")
        // The lane names its own unit ("Credits", "Premium requests",
        // "Chat") — GitHub re-denominated once already.
        case .monthly(let label), .monthlyScoped(let label):
            return String(
                localized: "\(label) (month)",
                comment: "Agent usage window title: provider quota label measured monthly")
        // No period suffix on purpose: the provider did not state one.
        case .labelled(let label):
            return label
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(window.displayPercent, format: .percent)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                let fraction = window.barFraction
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                        .frame(height: 5)
                    Capsule()
                        .fill(AgentUsageBarStyle.color(
                            for: window.usedPercent, accentTint: accentTint))
                        .frame(width: geo.size.width * fraction, height: 5)
                    if let expected = AgentUsagePace.expectedUsedFraction(
                        window: window, now: now) {
                        PaceTick()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 4)
                            .offset(x: geo.size.width * expected - 3, y: 6)
                    }
                }
            }
            .frame(height: 11)

            HStack {
                if let resetsAt = window.resetsAt {
                    Text(verbatim: AgentUsageFormat.resetCountdown(
                        until: resetsAt,
                        now: now))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                // Where the provider meters in units rather than percent
                // (Copilot), the magnitude is the number users think in —
                // "3% used" of 50 Free-plan chats reads healthier than it is.
                if let remaining = window.remainingCount,
                   let entitlement = window.entitlement, entitlement > 0 {
                    Text("\(Int(remaining.rounded())) of \(Int(entitlement.rounded())) left")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// Small upward triangle marking even-burn position under a bar.
private struct PaceTick: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
