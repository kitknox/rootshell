import SwiftUI
import GhosttyKit

extension MainView {
    var effectiveDuoLayout: DuoLayoutContext {
        var context = duoLayout
        context.tabletopDisabled = duoTabletopDisabled
        return context
    }

    var showsHorizontalTabHeader: Bool {
        duoLayout.showsHorizontalTabs(globallyHidden: tabBarHidden)
    }

    /// Dynamic Island iPhones end the top safe area several points below the
    /// status bar; the tab header rises to the status bar instead. Duo keeps
    /// its own camera-aware header placement.
    var tabHeaderTopLimit: CGFloat? {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        guard showsHorizontalTabHeader, !duoLayout.hasHinge,
              UIDevice.current.userInterfaceIdiom == .phone,
              statusBarBottom > 0, statusBarBottom < windowSafeAreaInsets.top
        else { return nil }
        return statusBarBottom
        #else
        return nil
        #endif
    }

    /// Window-space top of the tab header band.
    var chromeTopInset: CGFloat { tabHeaderTopLimit ?? windowSafeAreaInsets.top }

    /// iPhone and iPad without top tabs: the terminal runs under the top safe
    /// area. Its grid stays below it while scrollback fills the band. Duo's
    /// full-width and front side-rail modes already own their top edge.
    var terminalExtendsUnderTopSafeArea: Bool {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        !showsHorizontalTabHeader && !duoLayout.usesFullWidth && !duoLayout.extendsTerminalToVerticalEdges
        #else
        false
        #endif
    }

    /// The inner display reserves the rail's column even when the rail is
    /// hidden, so only the top tab bar follows the global setting there.
    var showsDuoSideRail: Bool {
        duoLayout.usesSideRail && (!tabBarHidden || duoLayout.showsTabsBesideSideRail) && !showKeyboardChooser
    }

    @ViewBuilder
    func applyDuoChrome<Content: View>(_ content: Content) -> some View {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *) {
            content
                .toolbarVisibility(showsDuoSideRail ? .visible : .hidden, for: .navigationBar)
                .toolbar {
                    if showsDuoSideRail {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Open Connections", systemImage: "plus", action: addNewTab)
                                .labelStyle(.iconOnly)
                        }
                        .visibilityPriority(.high)
                        // Identical branches: flipping the generation replaces the item.
                        if duoTabItemGeneration.isMultiple(of: 2) {
                            duoTabToolbarItem
                        } else {
                            duoTabToolbarItem
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Settings", systemImage: "gearshape") { requestSettingsPresentation() }
                                .labelStyle(.iconOnly)
                        }
                        .visibilityPriority(.high)
                    }
                    if duoTabletopAvailable && showsDuoSideRail {
                        ToolbarOverflowMenu {
                            Toggle("Tabletop Mode", isOn: Binding(
                                get: { !duoTabletopDisabled },
                                set: { duoTabletopDisabled = !$0 }
                            ))
                        }
                    }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    @available(iOS 27.1, *)
    @ToolbarContentBuilder
    private var duoTabToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if let tab = tabsModel.selectedTab {
                DuoTabButton(
                    terminal: tab.focusedTerminal,
                    number: (tabsModel.navigationTabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1,
                    onClose: {
                        if let position = tabsModel.index(of: tab.id) { requestUserCloseTab(at: position) }
                    },
                    onManage: { showingTabSwitcher = true },
                    onMountChange: noteDuoTabButtonMounted
                )
            } else {
                Button("Tabs", systemImage: "square.on.square") {
                    showingTabSwitcher = true
                }
                .labelStyle(.iconOnly)
                .disabled(true)
            }
        }
        .axisBehavior(.verticalPreferred)
        .visibilityPriority(.high)
    }
    #endif

    /// After a display or window change UIKit can take the rail's tab button
    /// down while SwiftUI still declares it, and never remount it. Replace the
    /// item when the button stays unmounted.
    func noteDuoTabButtonMounted(_ mounted: Bool) {
        duoTabButtonMounts = max(0, duoTabButtonMounts + (mounted ? 1 : -1))
        guard !mounted else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard duoTabButtonMounts == 0 else { return }
            duoTabItemGeneration &+= 1
        }
    }
}

private struct DuoTabButton: View {
    let terminal: Ghostty.TerminalView?
    let number: Int
    let onClose: () -> Void
    let onManage: () -> Void
    let onMountChange: (Bool) -> Void

    var body: some View {
        Button(action: onManage) {
            // Never supply a tab title to the native toolbar: it can choose
            // a Label's text even when the requested style is icon-only.
            Text(number.formatted())
                .font(.system(.body, design: .monospaced, weight: .bold))
                .frame(minWidth: 28, minHeight: 28)
                .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottom) {
                    if let terminal {
                        DuoTabProgress(terminal: terminal)
                    }
                }
        }
        .onAppear { onMountChange(true) }
        .onDisappear { onMountChange(false) }
        .accessibilityLabel("Tab \(number)")
        .accessibilityHint("Show all tabs")
        .contextMenu {
            Button("Close Tab", systemImage: "xmark", action: onClose)
            Button("Manage Tabs", systemImage: "square.on.square", action: onManage)
        }
    }
}

private struct DuoTabProgress: View {
    @ObservedObject var terminal: Ghostty.TerminalView

    var body: some View {
        if let report = terminal.progressReport, report.state != .remove {
            if let progress = report.progress {
                ProgressView(value: Double(progress), total: 100)
                    .frame(width: 26)
                    .accessibilityLabel("Task progress")
            } else {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    .accessibilityLabel("Task running")
            }
        }
    }
}

/// Publishes only the requested input region into the owning window. UIKit
/// lays out this probe with the workspace, so global/screen origins never enter
/// the custom keyboard's lower-region constraints.
struct DuoInputRegionReporter: UIViewRepresentable {
    let region: CGRect?
    /// UIKit places every keyboard below the fold whether or not tabletop mode
    /// reserves a region for it.
    let fold: CGRect?

    func makeUIView(context: Context) -> RegionView { RegionView() }
    func updateUIView(_ view: RegionView, context: Context) {
        view.region = region
        view.fold = fold
        view.setNeedsLayout()
    }
    static func dismantleUIView(_ view: RegionView, coordinator: ()) { view.clear() }

    final class RegionView: UIView {
        var region: CGRect?
        var fold: CGRect?
        private weak var previousWindow: UIWindow?
        override func layoutSubviews() {
            super.layoutSubviews()
            #if !targetEnvironment(macCatalyst) && !os(visionOS)
            if previousWindow !== window { clear() }
            previousWindow = window
            if let window {
                TerminalTouchKeyboardWindowState.forWindow(window).setInputRegion(
                    region.map { convert($0, to: window) }, fold: fold.map { convert($0, to: window) })
            }
            #endif
        }
        func clear() {
            #if !targetEnvironment(macCatalyst) && !os(visionOS)
            if let previousWindow {
                TerminalTouchKeyboardWindowState.forWindow(previousWindow).setInputRegion(nil, fold: nil)
            }
            #endif
            previousWindow = nil
        }
    }
}
