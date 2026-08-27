//
//  TabComponents.swift
//  rootshell
//
//  Shared tab button and glass effect components used by MainView and AIAgentWindowView
//

import SwiftUI
import UIKit

// MARK: - Tmux Tab Badges

struct TmuxTabBadge: Equatable {
    enum Role: Equatable {
        case gateway
        case window

        var systemImage: String {
            switch self {
            case .gateway: return "star.fill"
            case .window: return "t.square.fill"
            }
        }
    }

    let role: Role
    let groupIndex: Int

    func color(in palette: TmuxTabBadgePalette) -> Color {
        palette.gatewayColor(at: groupIndex)
    }
}

struct TmuxTabBadgePalette {
    let themeColors: ThemeManager.ThemeInfo.ThemeColors?
    let baseColor: Color?
    let isLight: Bool

    static let fallback = TmuxTabBadgePalette(themeColors: nil, baseColor: nil, isLight: false)

    init(theme: ResolvedTabBarTheme) {
        self.themeColors = theme.themeColors
        self.baseColor = theme.baseColor
        self.isLight = theme.isLight
    }

    @MainActor
    static var currentTheme: TmuxTabBadgePalette {
        guard let themeInfo = ThemeManager.shared.currentThemeInfo else { return .fallback }
        let baseColor = Color(hex: themeInfo.colors.background)
        return TmuxTabBadgePalette(
            themeColors: themeInfo.colors,
            baseColor: baseColor,
            isLight: themeInfo.isLight
        )
    }

    private init(
        themeColors: ThemeManager.ThemeInfo.ThemeColors?,
        baseColor: Color?,
        isLight: Bool
    ) {
        self.themeColors = themeColors
        self.baseColor = baseColor
        self.isLight = isLight
    }

    func gatewayColor(at index: Int) -> Color {
        let background = baseColor ?? Color(uiColor: .systemBackground)
        let themeCandidates = themePaletteCandidates(on: background)

        if !themeCandidates.isEmpty {
            return cycledColor(from: themeCandidates, at: index)
        }

        return fallbackThemeDerivedColor(at: index, on: background)
    }

    private func themePaletteCandidates(on background: Color) -> [Color] {
        guard let themeColors else { return [] }
        return themeColors.palette
            .compactMap(Color.init(hex:))
            .filter { color in
                color.saturation >= 0.18 &&
                !isReservedRoamHue(color.hue)
            }
            .map { adjustedForBadgeContrast($0, on: background) }
            .filter { $0.contrastRatio(against: background) >= 2.0 }
            .deduplicatedByHue()
    }

    private func cycledColor(from colors: [Color], at index: Int) -> Color {
        let color = colors[index % colors.count]
        let cycle = index / colors.count
        guard cycle > 0 else { return color }

        let amount = min(CGFloat(cycle) * 0.10, 0.28)
        return isLight
            ? color.blendedWithBlack(amount)
            : color.blendedWithWhite(amount)
    }

    private func fallbackThemeDerivedColor(at index: Int, on background: Color) -> Color {
        let seedHue = seedHue()
        var hue = (seedHue + (Double(index + 1) * 0.618_033_988_749_895))
            .truncatingRemainder(dividingBy: 1)

        while isReservedRoamHue(CGFloat(hue)) {
            hue = (hue + 0.13).truncatingRemainder(dividingBy: 1)
        }

        let saturation = isLight ? 0.72 : 0.64
        let brightness = isLight ? 0.55 : 0.88
        let color = Color(hue: hue, saturation: saturation, brightness: brightness)
        return adjustedForBadgeContrast(color, on: background)
    }

    private func seedHue() -> Double {
        if let accent = themeColors?.vibrantAccentColor, accent.saturation >= 0.18 {
            return Double(accent.hue)
        }
        if let baseColor, baseColor.saturation >= 0.10 {
            return Double(baseColor.hue)
        }
        return 0
    }

    private func adjustedForBadgeContrast(_ color: Color, on background: Color) -> Color {
        guard color.contrastRatio(against: background) < 2.0 else { return color }
        return isLight
            ? color.blendedWithBlack(0.32)
            : color.blendedWithWhite(0.22)
    }

    private func isReservedRoamHue(_ hue: CGFloat) -> Bool {
        // Keep tmux gateway groups away from the blue/teal roam badges.
        (0.42...0.70).contains(hue)
    }
}

@MainActor
enum TmuxTabBadgeResolver {
    static func badge(for tab: TabModel, allTabs: [TabModel]) -> TmuxTabBadge? {
        badge(for: tab, gatewayOwnerIDs: activeGatewayOwnerIDs(in: allTabs))
    }

    /// Resolve the badge against a precomputed ordered gateway owner-ID list.
    /// `groupIndex` is the gateway's position in this list, so the list MUST
    /// reflect live tab order — reordering gateways recolors badges even when a
    /// tab's own index is unchanged. Compute the list ONCE per tab-bar render
    /// with `activeGatewayOwnerIDs(in:)` and reuse it for every tab (O(n), not
    /// the per-tab O(n²) of `badge(for:allTabs:)`); the top tab bar also stores
    /// the resolved badge so `TabBarItem` equality can compare it directly
    /// instead of re-deriving order from `allTabs`.
    static func badge(for tab: TabModel, gatewayOwnerIDs: [UUID]) -> TmuxTabBadge? {
        guard let role = role(for: tab),
              let ownerID = ownerID(for: tab) else { return nil }
        let groupIndex = gatewayOwnerIDs.firstIndex(of: ownerID) ?? 0
        return TmuxTabBadge(role: role, groupIndex: groupIndex)
    }

    private static func role(for tab: TabModel) -> TmuxTabBadge.Role? {
        if tab.isTmuxGateway { return .gateway }
        if tab.isTmuxWindow { return .window }
        return nil
    }

    /// The gateway terminal UUID that identifies a tab's tmux group: the
    /// owning gateway's terminal for window tabs, the live gateway view's
    /// uuid for gateway tabs. Also used by the vertical tab sidebar to
    /// bucket window tabs under their gateway.
    static func ownerID(for tab: TabModel) -> UUID? {
        if tab.isTmuxWindow {
            return tab.owningGatewayTerminalUUID
        }

        guard tab.isTmuxGateway else { return nil }
        for view in tab.splitTree.terminalLeaves {
            if view.tmuxController?.isActive == true || view.isTmuxGatewaySurfaceActive {
                return view.uuid
            }
        }
        return tab.focusedTerminal?.uuid
    }

    /// Ordered, de-duplicated gateway owner IDs in live tab order. Drives tmux
    /// badge group colors (a gateway's index here is its `groupIndex`). Compute
    /// once per tab-bar render and pass to `badge(for:gatewayOwnerIDs:)`.
    static func activeGatewayOwnerIDs(in tabs: [TabModel]) -> [UUID] {
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for tab in tabs {
            guard let id = ownerID(for: tab), seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

}

private extension Array where Element == Color {
    func deduplicatedByHue() -> [Color] {
        var result: [Color] = []
        for color in self {
            guard !result.contains(where: { $0.hueDifference(from: color.hue) < 0.025 }) else {
                continue
            }
            result.append(color)
        }
        return result
    }
}

struct RoamTabBadgeView: View {
    let roamProtocol: MainView.RoamProtocol
    var compensateVibrancy: Bool = false

    private var color: Color {
        switch roamProtocol {
        case .mosh: return .blue
        case .trzsz: return .teal
        case .none: return .clear
        }
    }

    var body: some View {
        if roamProtocol != .none {
            Text("R")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color.opacity(0.15))
                .foregroundColor(color)
                .cornerRadius(4)
                .badgeVibrancyCompensated(compensateVibrancy)
        }
    }
}

struct TmuxTabBadgeView: View {
    let badge: TmuxTabBadge
    let palette: TmuxTabBadgePalette
    var compensateVibrancy: Bool = false

    var body: some View {
        let color = badge.color(in: palette)
        switch badge.role {
        case .gateway:
            Image(systemName: badge.role.systemImage)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color.opacity(0.15))
                .foregroundColor(color)
                .cornerRadius(4)
                .badgeVibrancyCompensated(compensateVibrancy)
                .accessibilityLabel("tmux gateway")
        case .window:
            Text("T")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color.opacity(0.15))
                .foregroundColor(color)
                .cornerRadius(4)
                .badgeVibrancyCompensated(compensateVibrancy)
                .accessibilityLabel("tmux window")
        }
    }
}

// MARK: - Tab Frame Preference Key

/// Preference key for tracking tab frame positions (used for drag/drop reordering)
struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Tab Sizing Constants

/// Platform-specific tab sizing metrics
enum TabMetrics {
    #if os(visionOS)
    static let tabMaxHeight: CGFloat = 60
    static let tabBarHeight: CGFloat = 72
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 14
    static let closeButtonSize: CGFloat = 28
    static let closeIconSize: CGFloat = 14
    static let titleInnerPadding: CGFloat = 32
    static let titleFontSize: CGFloat = 17
    #else
    static let tabMaxHeight: CGFloat = 32
    static let tabBarHeight: CGFloat = 44
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 6
    static let closeButtonSize: CGFloat = 16
    static let closeIconSize: CGFloat = 10
    static let titleInnerPadding: CGFloat = 20
    static let titleFontSize: CGFloat = 14
    #endif
}

// MARK: - Tab Button

/// Reusable tab button with glass effect, hover-to-close, and optional health indicator
struct TabButton: View {
    let id: UUID
    let title: String
    let isSelected: Bool
    var selectedBackgroundColor: Color = Color(uiColor: .secondarySystemBackground)
    var unselectedBackgroundColor: Color = Color(uiColor: .tertiarySystemBackground)
    var textColor: Color = .primary
    var secondaryTextColor: Color = .secondary
    var isLightTheme: Bool = false
    let namespace: Namespace.ID?
    let onTap: () -> Void
    let onClose: () -> Void
    var isWiggling: Bool = false
    var connectionHealth: ConnectionHealth?
    var showHealthIndicator: Bool = true
    var keyboardShortcut: String? = nil  // e.g., "⌘1" - shown when tab shortcuts setting enabled
    var onHoverChange: ((Bool) -> Void)?
    var trackFrame: Bool = true  // Whether to report frame via TabFramePreferenceKey
    var hasThemeOverride: Bool = false  // Whether this tab has a theme override
    var roamProtocol: MainView.RoamProtocol = .none  // Whether this is a Mosh/Trzsz roaming connection
    var tmuxBadge: TmuxTabBadge? = nil  // tmux control-mode gateway/window badge
    var tmuxBadgePalette: TmuxTabBadgePalette = .fallback
    var attentionBadge: AgentAttentionStatus? = nil  // agent attention dot (id=agent-attention)
    var style: TopTabStyle = .pills
    var tabWidth: CGFloat = 240
    var usesTitlebarTabs: Bool = false

    @State private var isHovered: Bool = false
    @State private var isCloseHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// iOS 27 / macOS 27 desaturate saturated content drawn on Liquid Glass (the
    /// colored tab badges) ONLY when the effective appearance is Light. In Dark
    /// appearance the glass applies a vibrancy boost that we want to keep, so we
    /// must NOT touch the badge there. This is true only on a selected tab, on
    /// iOS 27+, in Light appearance (non-visionOS). When true the badge is
    /// boosted + rasterized (see `badgeVibrancyCompensated`) so it escapes the
    /// muting and roughly matches the Dark-appearance vividness.
    ///
    /// `colorScheme` reflects the effective appearance (app Appearance Mode or
    /// system), so this tracks live as the user toggles. Runtime OS check (not
    /// `#available(iOS 27, *)`): the iOS 27 SDK is not installed, so the app
    /// builds against the iOS 26 SDK and runs forward — read the OS version.
    private var badgeNeedsVibrancyEscape: Bool {
        guard isSelected, colorScheme == .light else { return false }
        #if os(visionOS)
        return false
        #else
        guard #available(iOS 26.0, *) else { return false }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        #endif
    }

    /// Close button visibility:
    /// - Mac Catalyst: hover only
    /// - iPad: hover OR selected tab (touch fallback)
    private var shouldShowCloseButton: Bool {
        if style == .integrated {
            return isSelected || isHovered || tabWidth >= integratedInactiveCloseThreshold
        }
        #if targetEnvironment(macCatalyst)
        return isHovered
        #else
        return isHovered || isSelected
        #endif
    }

    private var integratedInactiveCloseThreshold: CGFloat {
        #if os(visionOS)
        return 220
        #else
        return 160
        #endif
    }

    private var titleContent: some View {
        HStack(spacing: 6) {
            RoamTabBadgeView(
                roamProtocol: roamProtocol,
                compensateVibrancy: badgeNeedsVibrancyEscape
            )
            .fixedSize()

            if let tmuxBadge {
                TmuxTabBadgeView(
                    badge: tmuxBadge,
                    palette: tmuxBadgePalette,
                    compensateVibrancy: badgeNeedsVibrancyEscape
                )
                .fixedSize()
            }

            if let attentionBadge {
                AttentionStatusDotView(status: attentionBadge, size: 7)
                    .badgeVibrancyCompensated(badgeNeedsVibrancyEscape)
                    .fixedSize()
            }

            Text(title)
                .font(.system(size: TabMetrics.titleFontSize, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? textColor : secondaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            // Theme override indicator
            if hasThemeOverride {
                Image(systemName: "paintbrush.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
                    .fixedSize()
            }

            // Keyboard shortcut indicator
            if let shortcut = keyboardShortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(isSelected ? textColor.opacity(0.6) : secondaryTextColor.opacity(0.6))
                    .fixedSize()
            }

            // Health indicator (only show if enabled and health data available)
            if showHealthIndicator, let health = connectionHealth {
                ConnectionHealthIndicator(health: health, textColor: isSelected ? textColor : secondaryTextColor)
                    .fixedSize()
            }
        }
        .frame(minWidth: 0)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            ZStack {
                if style == .integrated {
                    Circle()
                        .fill((isSelected ? textColor : secondaryTextColor).opacity(isLightTheme ? 0.10 : 0.14))
                        .frame(width: 20, height: 20)
                        .opacity(isCloseHovered ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isCloseHovered)
                }

                Image(systemName: "xmark")
                    .font(.system(size: TabMetrics.closeIconSize, weight: .medium))
                    .foregroundColor(isSelected ? textColor : secondaryTextColor)
            }
            .frame(
                width: style == .integrated ? 44 : TabMetrics.closeButtonSize,
                height: style == .integrated ? TabMetrics.tabBarHeight : TabMetrics.closeButtonSize
            )
            .offset(y: style == .integrated ? 2 : 0)
        }
        .onHover { hovering in
            if style == .integrated {
                isCloseHovered = hovering
            }
        }
        .opacity(shouldShowCloseButton ? 1 : 0)
        .allowsHitTesting(shouldShowCloseButton)
        .accessibilityHidden(!shouldShowCloseButton)
        .animation(.easeInOut(duration: 0.15), value: shouldShowCloseButton)
        .fixedSize()
        .accessibilityLabel("Close \(title)")
    }

    var body: some View {
        Group {
            if style == .integrated {
                HStack(spacing: 4) {
                    titleContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: 2)
                    // Hidden controls must not continue consuming their 44pt
                    // target in compact tabs; that space belongs to the title
                    // until the close affordance is actually visible.
                    if shouldShowCloseButton {
                        closeButton
                    }
                }
                .transaction { $0.animation = nil }
                // The selected silhouette consumes its first 10pt with the
                // lower shoulder. Start content inside the vertical body,
                // rather than at the outer shoulder edge.
                .padding(.leading, TabMetrics.horizontalPadding + 8)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, maxHeight: TabMetrics.tabBarHeight)
                .background {
                    IntegratedTabBackground(
                        isSelected: isSelected,
                        isHovered: isHovered,
                        selectedColor: selectedBackgroundColor,
                        hoverColor: unselectedBackgroundColor,
                        namespace: namespace,
                        reduceMotion: reduceMotion
                    )
                }
                .contentShape(Rectangle())
            } else {
                pillContent
            }
        }
        .background(
            Group {
                if trackFrame {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TabFramePreferenceKey.self,
                            value: [id: geo.frame(in: .global)]
                        )
                    }
                }
            }
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            // Keep the hover state change itself immediate. The inactive-tab
            // background owns its small opacity animation so entering a tab
            // does not animate or rebuild the entire button subtree.
            isHovered = hovering
            if !hovering {
                isCloseHovered = false
            }
            onHoverChange?(hovering)
        }
        .offset(x: isWiggling ? 3 : 0)
        .animation(
            isWiggling
                ? .spring(response: 0.06, dampingFraction: 0.15).repeatCount(6, autoreverses: true)
                : .default,
            value: isWiggling
        )
    }

    private var pillContent: some View {
        Group {
            #if os(visionOS)
            // visionOS: HStack layout so close button takes explicit space and never overlaps title
            HStack(spacing: 8) {
                closeButton
                titleContent
                Spacer(minLength: 0)
            }
            #else
            ZStack {
                // Title centered in the full tab, with padding to avoid close button
                titleContent
                    .padding(.horizontal, TabMetrics.titleInnerPadding)

                // Close button at far left edge (Finder style)
                HStack {
                    closeButton
                    Spacer()
                }
            }
            #endif
        }
        // Suppress the row-level selection animation for the title + close
        // button content. The tab bar wraps selection changes in a scoped
        // `.animation(value: selectedTabID)` so the Liquid Glass / matched
        // geometry background slides smoothly; without this transaction
        // override, that same animation also drives the title text's color
        // and weight transitions, which reads as an ugly fade. The glass
        // background sits in `GlassTabBackgroundModifier` below this point
        // in the chain and still inherits the parent animation.
        .transaction { $0.animation = nil }
        .padding(.horizontal, TabMetrics.horizontalPadding)
        .padding(.vertical, TabMetrics.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: TabMetrics.tabMaxHeight)
        .modifier(GlassTabBackgroundModifier(
            isSelected: isSelected,
            selectedBackgroundColor: selectedBackgroundColor,
            unselectedBackgroundColor: unselectedBackgroundColor,
            id: id,
            namespace: namespace,
            isLightTheme: isLightTheme,
            isHovered: isHovered
        ))
        .contentShape(Capsule())
        #if os(visionOS)
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        #endif
    }
}

/// Integrated selected-tab silhouette: rounded at the top, with lower
/// shoulders that widen into the terminal edge. The bottom remains open and
/// flush, so matching the terminal background reads as one connected surface.
private struct BrowserTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Leave a narrow strip of the frame visible above the active tab, then
        // use roughly equal upper radii and lower shoulder curves.
        // Keeping the shoulders inside the tab's allocation avoids overlap
        // with neighboring close buttons while preserving the same silhouette.
        let topInset = min(5, rect.height * 0.12)
        let tabRect = CGRect(
            x: rect.minX,
            y: rect.minY + topInset,
            width: rect.width,
            height: max(0, rect.height - topInset)
        )
        // The lower shoulder is wider than it is tall. That shallow ellipse
        // makes the active surface appear to flow into the content; a 1:1
        // corner reads as a sharp hook at Retina pixel scale.
        let shoulderWidth = min(16, tabRect.width * 0.12)
        let shoulderHeight = min(10, tabRect.height * 0.28)
        let radius = min(10, tabRect.height * 0.28)
        let bezierKappa: CGFloat = 0.552_284_8
        var path = Path()
        path.move(to: CGPoint(x: tabRect.minX, y: tabRect.maxY))
        path.addCurve(
            to: CGPoint(
                x: tabRect.minX + shoulderWidth,
                y: tabRect.maxY - shoulderHeight
            ),
            control1: CGPoint(
                x: tabRect.minX + shoulderWidth * bezierKappa,
                y: tabRect.maxY
            ),
            control2: CGPoint(
                x: tabRect.minX + shoulderWidth,
                y: tabRect.maxY - shoulderHeight * (1 - bezierKappa)
            )
        )
        path.addLine(to: CGPoint(x: tabRect.minX + shoulderWidth, y: tabRect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: tabRect.minX + shoulderWidth + radius, y: tabRect.minY),
            control: CGPoint(x: tabRect.minX + shoulderWidth, y: tabRect.minY)
        )
        path.addLine(to: CGPoint(x: tabRect.maxX - shoulderWidth - radius, y: tabRect.minY))
        path.addQuadCurve(
            to: CGPoint(x: tabRect.maxX - shoulderWidth, y: tabRect.minY + radius),
            control: CGPoint(x: tabRect.maxX - shoulderWidth, y: tabRect.minY)
        )
        path.addLine(to: CGPoint(
            x: tabRect.maxX - shoulderWidth,
            y: tabRect.maxY - shoulderHeight
        ))
        path.addCurve(
            to: CGPoint(x: tabRect.maxX, y: tabRect.maxY),
            control1: CGPoint(
                x: tabRect.maxX - shoulderWidth,
                y: tabRect.maxY - shoulderHeight * (1 - bezierKappa)
            ),
            control2: CGPoint(
                x: tabRect.maxX - shoulderWidth * bezierKappa,
                y: tabRect.maxY
            )
        )
        path.closeSubpath()
        return path
    }
}

private struct IntegratedTabBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    let selectedColor: Color
    let hoverColor: Color
    let namespace: Namespace.ID?
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if isSelected {
                selectedBackground
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hoverColor.opacity(0.45))
                    .padding(.vertical, 4)
                    .opacity(isHovered ? 1 : 0)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var selectedBackground: some View {
        let background = BrowserTabShape().fill(selectedColor)

        if let namespace {
            background
                .matchedGeometryEffect(id: "integratedSelectedTab", in: namespace)
        } else {
            background
        }
    }
}

// MARK: - Glass Effect Modifiers

/// Pre-iOS 26 glassmorphism fallback for tab backgrounds
/// Creates a frosted glass appearance with blur, gradient, stroke, and shadow
struct GlassedCapsule: View {
    let tintColor: Color
    let isLightTheme: Bool

    var body: some View {
        Capsule()
            // Base blur material
            .fill(.ultraThinMaterial)
            // Tint overlay
            .overlay(
                Capsule()
                    .fill(tintColor.opacity(0.35))
            )
            // Light refraction gradient
            .overlay(
                Capsule()
                    .fill(
                        .linearGradient(
                            colors: [
                                .white.opacity(isLightTheme ? 0.3 : 0.2),
                                .white.opacity(isLightTheme ? 0.1 : 0.05),
                                .clear,
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            // Edge stroke for definition
            .overlay(
                Capsule()
                    .strokeBorder(
                        .linearGradient(
                            colors: [
                                .white.opacity(isLightTheme ? 0.5 : 0.3),
                                .white.opacity(isLightTheme ? 0.2 : 0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            // Drop shadow for depth
            .shadow(
                color: .black.opacity(isLightTheme ? 0.15 : 0.3),
                radius: 8,
                x: 0,
                y: 4
            )
    }
}

/// Applies glass effect on iOS 26+, falls back to glassmorphism on older versions
struct GlassTabBackgroundModifier: ViewModifier {
    let isSelected: Bool
    let selectedBackgroundColor: Color
    let unselectedBackgroundColor: Color
    let id: UUID
    let namespace: Namespace.ID?
    let isLightTheme: Bool
    let isHovered: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// Reduce Transparency / Increase Contrast replace Liquid Glass with a
    /// flat fill that resolves against the system appearance, ignoring the
    /// app's forced appearance mode entirely (white pill over a dark theme
    /// whenever the window is inactive — issue #250). Skip materials and
    /// draw a plain theme-colored capsule in those modes.
    private var avoidsMaterials: Bool {
        reduceTransparency || colorSchemeContrast == .increased
    }

    /// A stable, non-material hover fill for inactive tabs. Keeping this
    /// capsule in the view tree at zero opacity avoids replacing the content's
    /// Liquid Glass modifiers under the pointer, which can repeatedly
    /// invalidate the hover region and produce visible enter/exit flicker.
    private var inactiveHoverBackground: some View {
        Capsule()
            .fill(unselectedBackgroundColor)
            .opacity(isHovered ? (avoidsMaterials ? 1 : 0.5) : 0)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovered
            )
    }

    func body(content: Content) -> some View {
        #if os(visionOS)
        // glassEffect is not available on visionOS
        // Both selected and unselected tabs get a background so they look targetable for gaze
        if isSelected {
            content
                .background(
                    Capsule()
                        .fill(selectedBackgroundColor)
                )
        } else {
            content
                .background(
                    Capsule()
                        .fill(unselectedBackgroundColor.opacity(0.5))
                )
        }
        #else
        if avoidsMaterials {
            if isSelected, let ns = namespace {
                content
                    .background(
                        Capsule()
                            .fill(selectedBackgroundColor)
                            .matchedGeometryEffect(id: "selectedTab", in: ns)
                    )
            } else if isSelected {
                content
                    .background(
                        Capsule()
                            .fill(selectedBackgroundColor)
                    )
            } else {
                content
                    .background(inactiveHoverBackground)
            }
        } else if #available(iOS 26.0, macOS 26.0, *) {
            if isSelected {
                content
                    .glassEffect(
                        .regular.tint(selectedBackgroundColor),
                        in: Capsule()
                    )
                    .glassEffectTransition(.matchedGeometry)
                    .applyGlassEffectID(id: id, namespace: namespace)
                    .applyGlassEffectUnion(id: "selectedTab", namespace: namespace)
            } else {
                content
                    .background(inactiveHoverBackground)
                    .applyGlassEffectID(id: id, namespace: namespace)
            }
        } else {
            // Fallback for pre-iOS 26 - glassmorphism effect
            if isSelected, let ns = namespace {
                content
                    .background(
                        GlassedCapsule(
                            tintColor: selectedBackgroundColor,
                            isLightTheme: isLightTheme
                        )
                        .matchedGeometryEffect(id: "selectedTab", in: ns)
                    )
            } else {
                content
                    .background(inactiveHoverBackground)
            }
        }
        #endif
    }
}

/// Wraps content in GlassEffectContainer on iOS 26+, passthrough on older versions
struct GlassEffectContainerModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
        // GlassEffectContainer is not available on visionOS
        content
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
        #endif
    }
}

extension View {
    /// Compensates for the iOS 27+ Light-appearance Liquid Glass vibrancy pass,
    /// which mutes saturated content drawn on the glass. When `enabled` (selected
    /// tab, iOS 27+, Light appearance only):
    ///   1. boosts saturation/brightness to approximate the brighter result the
    ///      glass produces for free in Dark appearance, then
    ///   2. rasterizes via `.drawingGroup()` so the badge reaches the glass as an
    ///      opaque bitmap the muting pass leaves alone (the boost is baked in).
    /// When disabled (Dark appearance / iOS 26 / visionOS) the view is returned
    /// unchanged so the system's own vibrancy boost is preserved.
    /// See `TabButton.badgeNeedsVibrancyEscape`.
    @ViewBuilder
    func badgeVibrancyCompensated(_ enabled: Bool) -> some View {
        if enabled {
            self
                .saturation(1.35)
                .brightness(0.06)
                .drawingGroup()
        } else {
            self
        }
    }

    @ViewBuilder
    func applyGlassEffectID(id: UUID, namespace: Namespace.ID?) -> some View {
        #if os(visionOS)
        // glassEffectID is not available on visionOS
        self
        #else
        if #available(iOS 26.0, macOS 26.0, *), let ns = namespace {
            self.glassEffectID("tab-\(id.uuidString)", in: ns)
        } else {
            self
        }
        #endif
    }

    @ViewBuilder
    func applyGlassEffectUnion(id: some Hashable & Sendable, namespace: Namespace.ID?) -> some View {
        #if os(visionOS)
        // glassEffectUnion is not available on visionOS
        self
        #else
        if #available(iOS 26.0, macOS 26.0, *), let ns = namespace {
            self.glassEffectUnion(id: id, namespace: ns)
        } else {
            self
        }
        #endif
    }
}

// MARK: - Tab Layout Context Menu

/// Adds the lightweight Pills/Compact Pills/Integrated switcher to otherwise
/// non-tab chrome.
/// The nearest per-tab context menu still owns secondary clicks on real tabs.
struct TabStyleSwitchContextMenuModifier: ViewModifier {
    @Binding var selectedStyleRawValue: String
    @AppStorage(UserPreferences.compactPillTabSpacingKey) private var compactPillTabSpacing: Bool = false

    private var selectedStyle: TopTabStyle {
        TopTabStyle.resolve(selectedStyleRawValue)
    }

    private var selectedLayout: TopTabLayout {
        TopTabLayout.resolve(style: selectedStyle, compactPills: compactPillTabSpacing)
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .contextMenu {
                layoutButton(.pills, systemImage: "capsule")
                layoutButton(.compactPills, systemImage: "capsule.fill")
                layoutButton(.integrated, systemImage: "rectangle.topthird.inset.filled")
            }
    }

    private func layoutButton(_ layout: TopTabLayout, systemImage: String) -> some View {
        Button {
            selectedStyleRawValue = layout.style.rawValue
            if layout.style == .pills {
                compactPillTabSpacing = layout.usesCompactPillSpacing
            }
        } label: {
            Label(
                layout.displayName,
                systemImage: selectedLayout == layout ? "checkmark" : systemImage
            )
        }
    }
}

extension View {
    func tabStyleSwitchContextMenu(selection: Binding<String>) -> some View {
        modifier(TabStyleSwitchContextMenuModifier(selectedStyleRawValue: selection))
    }
}

// MARK: - Tab Animation Constants

/// Shared animation parameters for tab transitions
enum TabAnimation {
    /// Spring animation for tab selection changes
    static var selection: Animation {
        .spring(response: 0.3, dampingFraction: 0.7)
    }

    /// Animation for tab bar appearance/count changes
    static var appearance: Animation {
        .spring(response: 0.3, dampingFraction: 0.8)
    }
}
