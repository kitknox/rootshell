import SwiftUI

extension Notification.Name {
    /// Posted when the app moves between Duo's inner and front displays.
    static let duoDisplayDidChange = Notification.Name("duoDisplayDidChange")
}

/// Counts hinge updates; a terminal may reclaim focus the system took once per fold.
@MainActor
enum DuoHingeEvents {
    private(set) static var generation = 0
    /// Lets UIKit views without the `duoLayout` environment pick per-display settings.
    private(set) static var isFrontDisplay = false

    static func noteChange(isFrontDisplay: Bool) {
        generation &+= 1
        setFrontDisplay(isFrontDisplay)
    }

    static func setFrontDisplay(_ value: Bool) {
        guard value != isFrontDisplay else { return }
        isFrontDisplay = value
        NotificationCenter.default.post(name: .duoDisplayDidChange, object: nil)
    }
}

/// The navigation container is installed once for the lifetime of the scene;
/// folding only changes its chrome, never the identity of MainView.
/// iPhone only: on iPad this stack captures pushes from side-panel NavigationStacks.
struct DuoSceneHost<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *), UIDevice.current.userInterfaceIdiom == .phone {
            NavigationStack {
                DuoSceneContext(content: content)
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

#if !targetEnvironment(macCatalyst) && !os(visionOS)
@available(iOS 27.1, *)
private struct DuoSceneContext<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @Setting(Settings.Tabs.duoFrontDisplayMode) private var mode
    @Setting(Settings.Tabs.duoBehindCameraShowsTabs) private var showsTabs
    @State private var hasHinge = false
    @State private var isClosed = false
    @State private var holdsImmersiveChrome = false
    @ViewBuilder var content: () -> Content

    private var layoutContext: DuoLayoutContext {
        DuoLayoutContext(
            hasHinge: hasHinge, isFrontDisplay: isClosed,
            verticalEdge: verticalEdge, frontMode: mode,
            behindCameraShowsTabs: showsTabs
        )
    }

    var body: some View {
        content()
            .environment(\.duoLayout, layoutContext)
            .toolbarVerticalBehavior(isClosed && mode != .sideRail ? .disabled : .automatic)
            .onChange(of: layoutContext.requiresImmersiveChrome, initial: true) { _, required in
                setImmersiveChrome(required)
            }
            .onAppear {
                setImmersiveChrome(layoutContext.requiresImmersiveChrome)
                // Pushes disappear this root too; the fold state outlives them.
                DuoHingeEvents.setFrontDisplay(isClosed)
            }
            .onDisappear { setImmersiveChrome(false) }
            .onHingeChange { _, update in
                // Status selects a user preference; layout still comes from
                // reserved regions, never from the continuous hinge angle.
                hasHinge = update.hinge != nil
                isClosed = update.hinge?.status == .closed
                DuoHingeEvents.noteChange(isFrontDisplay: isClosed)
            }
    }

    private func setImmersiveChrome(_ required: Bool) {
        guard required != holdsImmersiveChrome else { return }
        holdsImmersiveChrome = required
        // Use the existing counted fullscreen hold so this composes with VNC
        // takeovers and never overwrites the user's persistent preference.
        if required {
            ImmersiveChromeManager.shared.beginTransientImmersion()
        } else {
            ImmersiveChromeManager.shared.endTransientImmersion()
        }
    }
}
#endif

struct DuoWorkspaceGeometry<Content: View>: View {
    let context: DuoLayoutContext
    let headerHeight: CGFloat
    /// Window-space y the header may rise to above the safe area, if any.
    var headerTopLimit: CGFloat? = nil
    @ViewBuilder var content: (GeometryProxy, DuoWorkspaceLayout) -> Content
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        GeometryReader { safe in
            GeometryReader { expanded in
                content(expanded, layout(safe: safe, expanded: expanded))
            }
            .ignoresSafeArea(.container, edges: ignoredEdges)
        }
    }

    private var ignoredEdges: Edge.Set {
        var edges = context.workspaceIgnoredEdges(headerHeight: headerHeight)
        if headerTopLimit != nil, headerHeight > 0 { edges.insert(.top) }
        return edges
    }

    private func layout(safe: GeometryProxy, expanded: GeometryProxy) -> DuoWorkspaceLayout {
        let frame = expanded.frame(in: .global)
        let safeFrame = safe.frame(in: .global).offsetBy(dx: -frame.minX, dy: -frame.minY)
        var occlusions: [CGRect] = []
        var occlusionContentFrames: [CGRect] = []
        var divisions: [CGRect] = []
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *) {
            let regions = expanded.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed)
            occlusions = regions.map(\.frame)
            occlusionContentFrames = regions.map { region in
                // The reported frame includes interaction margins. Keep that
                // frame for buttons, but align the terminal with visible UI.
                let frame = region.frame
                let margins = region.margins
                return CGRect(x: frame.minX + margins.leading, y: frame.minY + margins.top,
                              width: max(0, frame.width - margins.leading - margins.trailing),
                              height: max(0, frame.height - margins.top - margins.bottom))
            }
            divisions = expanded.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed).map(\.frame)
        }
        #endif
        var layout = DuoWorkspaceLayout.resolve(
            bounds: CGRect(origin: .zero, size: expanded.size), safeFrame: safeFrame,
            occlusions: occlusions, divisions: divisions, context: context,
            headerHeight: headerHeight, rightToLeft: layoutDirection == .rightToLeft,
            occlusionContentFrames: occlusionContentFrames,
            headerTopLimit: headerTopLimit.map { $0 - frame.minY }
        )
        layout.safeAreaTop = safe.frame(in: .global).minY
        return layout
    }
}

/// Camera underlap belongs only to the terminal canvas. Floating controls use
/// a separate region-aware container even when their terminal is full bleed.
struct DuoControlClearance: ViewModifier {
    @Environment(\.duoLayout) private var layout

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            ZStack { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, clearance(in: proxy))
        }
    }

    private func clearance(in proxy: GeometryProxy) -> CGFloat {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *), layout.usesFullWidth {
            return max(0, proxy.reservedRegions(kind: .occlusion).filter {
                $0.frame.intersects(CGRect(origin: .zero, size: proxy.size))
            }.map(\.frame.maxY).max() ?? 0)
        }
        #endif
        return 0
    }
}
