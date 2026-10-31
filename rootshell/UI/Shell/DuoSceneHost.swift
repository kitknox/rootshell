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

/// Keeps hinge and toolbar layout state stable for the lifetime of the scene.
/// Terminal navigation lives in MainView so sidebar stacks stay independent.
struct DuoSceneHost<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *), UIDevice.current.userInterfaceIdiom == .phone {
            DuoSceneContext(content: content)
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
    let windowSafeAreaTop: CGFloat
    var landscapeCameraOnLeft: Bool? = nil
    @ViewBuilder var content: (GeometryProxy, DuoWorkspaceLayout) -> Content
    @Environment(\.layoutDirection) private var layoutDirection

    private enum CoordinateSpace { case safeArea }

    var body: some View {
        GeometryReader { safe in
            GeometryReader { expanded in
                content(expanded, layout(safe: safe, expanded: expanded))
            }
            .ignoresSafeArea(.container, edges: ignoredEdges(in: safe))
        }
        .coordinateSpace(name: CoordinateSpace.safeArea)
    }

    private func ignoredEdges(in geometry: GeometryProxy) -> Edge.Set {
        var edges = context.workspaceIgnoredEdges(headerHeight: headerHeight)
        if headerTopLimit != nil, headerHeight > 0 { edges.insert(.top) }
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if UIDevice.current.userInterfaceIdiom == .phone,
           !context.hasHinge, geometry.size.width > geometry.size.height,
           let landscapeCameraOnLeft {
            edges.formUnion(DuoLayoutContext.unoccludedLandscapeEdge(
                cameraOnLeft: landscapeCameraOnLeft, rightToLeft: layoutDirection == .rightToLeft
            ))
        }
        #endif
        return edges
    }

    private func layout(safe: GeometryProxy, expanded: GeometryProxy) -> DuoWorkspaceLayout {
        // Window reveal effects must not feed back into workspace layout.
        let frame = expanded.frame(in: .named(CoordinateSpace.safeArea))
        let safeFrame = CGRect(origin: .zero, size: safe.size)
            .offsetBy(dx: -frame.minX, dy: -frame.minY)
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
            headerTopLimit: headerTopLimit.map { safeFrame.minY + $0 - windowSafeAreaTop }
        )
        layout.safeAreaTop = max(windowSafeAreaTop, safe.safeAreaInsets.top)
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if UIDevice.current.userInterfaceIdiom == .phone, !context.hasHinge,
           expanded.size.width > expanded.size.height {
            let reclaimed = ignoredEdges(in: safe)
            if reclaimed.contains(.leading) { layout.headerInsets.leading = 0 }
            if reclaimed.contains(.trailing) { layout.headerInsets.trailing = 0 }
        }
        #endif
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
