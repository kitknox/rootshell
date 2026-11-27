//
//  WindowSettingsView.swift
//  rootshell
//
//  Settings → Window: a live preview of the window over links to focused
//  pages for the tab bar, tab switcher, panes, display, and text selection.
//

import SwiftUI

// MARK: - Hub

struct WindowSettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Setting(Settings.Tabs.barHidden) private var tabBarHidden
    @Setting(Settings.Tabs.barPosition) private var tabBarPosition
    @Setting(Settings.Tabs.topTabStyle) private var topTabStyle
    @Setting(Settings.Tabs.compactPillSpacing) private var compactPillTabSpacing
    @Setting(Settings.Sidebar.translucent) private var tabSidebarTranslucent
    @Setting(Settings.Window.roundedPanes) private var roundedPanes
    @Bindable private var selectionManager = SelectionManager.shared

    private var layout: TopTabLayout {
        TopTabLayout.resolve(style: topTabStyle, compactPills: compactPillTabSpacing)
    }

    private var tabBarSummary: String {
        if tabBarHidden { return String(localized: "Hidden", comment: "Window settings: tab bar is hidden") }
        return String(localized: "\(layout.displayName) · \(tabBarPosition.displayName)",
                      comment: "Window settings: tab style and tab bar position, e.g. Pills · Top")
    }

    var body: some View {
        List {
            Section {
                TabBarScenePreview(height: 150)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink(value: SettingsSearchDestination.windowTabBar) {
                    hubRow("menubar.rectangle", String(localized: "Tab Bar"), value: tabBarSummary)
                }
                .themedRow()
                .settingGroupContextMenu(.tabs)

                NavigationLink(value: SettingsSearchDestination.windowTabSwitcher) {
                    #if os(visionOS)
                    hubRow("sidebar.left", WindowTabSwitcherSettingsView.title(horizontalSizeClass), value: nil)
                    #else
                    hubRow("sidebar.left", WindowTabSwitcherSettingsView.title(horizontalSizeClass),
                           value: tabSidebarTranslucent
                            ? String(localized: "Translucent", comment: "Window settings: tab switcher is translucent")
                            : String(localized: "Opaque", comment: "Window settings: tab switcher is opaque"))
                    #endif
                }
                .themedRow()
                .settingGroupContextMenu(.sidebar)

                NavigationLink(value: SettingsSearchDestination.windowPanes) {
                    hubRow("rectangle.split.2x1", String(localized: "Panes & Padding"),
                           value: roundedPanes
                            ? String(localized: "Rounded", comment: "Window settings: panes are drawn as rounded cards")
                            : String(localized: "Square", comment: "Window settings: panes are drawn edge to edge"))
                }
                .themedRow()
                .settingGroupContextMenu(.window)

                if WindowDisplaySettingsView.isAvailable {
                    NavigationLink(value: SettingsSearchDestination.windowDisplay) {
                        hubRow("sun.max", String(localized: "Display"), value: nil)
                    }
                    .themedRow()
                    .settingGroupContextMenu(.power)
                }

                NavigationLink(value: SettingsSearchDestination.windowSelection) {
                    hubRow("character.cursor.ibeam", String(localized: "Text Selection"),
                           value: selectionManager.selectionMode.displayName)
                }
                .themedRow()
                .settingGroupContextMenu(.selection)
            }
        }
        .themedList()
        .navigationTitle("Window")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hubRow(_ icon: String, _ title: String, value: String?) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: icon)
            Text(title)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Tab Bar

struct WindowTabBarSettingsView: View {
    @Environment(\.duoLayout) private var duoLayout
    @Setting(Settings.Tabs.duoFrontDisplayMode) private var duoFrontDisplayMode
    @Setting(Settings.Tabs.duoBehindCameraShowsTabs) private var duoBehindCameraShowsTabs
    @Setting(Settings.Tabs.hoverPreviews) private var tabHoverPreviewsEnabled
    @Setting(Settings.Tabs.hoverPreviewActivation) private var tabHoverPreviewActivation
    @Setting(Settings.Tabs.showScopeMenu) private var showTabScopeMenu
    @Setting(Settings.Tabs.scopeMenuSize) private var tabScopeMenuSize
    @Setting(Settings.Tabs.hoverPreviewZoom) private var tabHoverPreviewZoom

    var body: some View {
        List {
            Section {
                TabBarPreviewCard()
                    .themedRow()
            }

            Section {
                SettingDescribedToggle(
                    Settings.Tabs.showShortcutIndicators,
                    title: "Show Tab Shortcuts",
                    description: "Display ⌘1–9 indicators on tabs for quick keyboard navigation."
                )
                .themedRow()

                SettingDescribedToggle(
                    Settings.Tabs.showScopeMenu,
                    title: "Show Group Menu",
                    description: "Show the active group or project switcher in the top tab bar while tabs are grouped."
                )
                .themedRow()

                if showTabScopeMenu {
                    Picker(selection: $tabScopeMenuSize) {
                        ForEach(TabScopeMenuSize.allCases, id: \.rawValue) { size in
                            Text(size.choiceName).tag(size)
                        }
                    } label: {
                        Text("Group Menu Size")
                            .settingRow(Settings.Tabs.scopeMenuSize)
                    }
                    .pickerStyle(.menu)
                    .disabled(SettingFileLock.isReadOnly(Settings.Tabs.scopeMenuSize.name))
                    .themedRow()
                }

                SettingDescribedToggle(
                    Settings.Tabs.programIcons,
                    title: "Show Program Icons",
                    description: "Show the shell or running program's logo on tabs and sidebar rows, and a Running card for long-running programs."
                )
                .themedRow()

                SettingDescribedToggle(
                    Settings.Tabs.exposeShowsCaptions,
                    title: "Tab Exposé Captions",
                    description: "Show tab titles and badges under each live preview in Tab Exposé."
                )
                .themedRow()

                SettingToggle(Settings.Tabs.barAnimationsDisabled, title: "Disable Tab Animations")
                    .themedRow()

                // Pointer-only: phones have no hover, visionOS gaze never reports one.
                #if !os(visionOS)
                if UIDevice.current.userInterfaceIdiom != .phone {
                    SettingDescribedToggle(
                        Settings.Tabs.hoverPreviews,
                        isOn: $tabHoverPreviewsEnabled,
                        title: "Tab Hover Previews",
                        description: "Rest the pointer on a tab to see a live preview. Optionally require a hardware modifier; pinch to resize or click to open Tab Exposé."
                    )
                    .themedRow()

                    if tabHoverPreviewsEnabled {
                        Picker(selection: $tabHoverPreviewActivation) {
                            ForEach(TabHoverPreviewActivation.allCases, id: \.rawValue) { activation in
                                Text(activation.displayName).tag(activation)
                            }
                        } label: {
                            Text("Tab Hover Activation")
                                .settingRow(Settings.Tabs.hoverPreviewActivation)
                        }
                        .pickerStyle(.menu)
                        .disabled(SettingFileLock.isReadOnly(Settings.Tabs.hoverPreviewActivation.name))
                        .themedRow()
                    }

                    if tabHoverPreviewZoom != 1 {
                        Button {
                            tabHoverPreviewZoom = 1
                        } label: {
                            Text("Reset Tab Preview Size")
                        }
                        .themedRow()
                    }
                }
                #endif
            } header: {
                Text("Tabs")
            }

            #if os(iOS) && !targetEnvironment(macCatalyst)
            if #available(iOS 27.1, *), duoLayout.hasHinge {
                Section {
                    PreviewSceneCard(
                        values: DuoFrontSceneValues(
                            mode: DuoFrontDisplayMode.allCases.firstIndex(of: duoFrontDisplayMode) ?? 0,
                            showsTabs: duoBehindCameraShowsTabs
                        ).vector,
                        draw: DuoFrontScene.draw
                    )
                    .themedRow()

                    Picker(selection: $duoFrontDisplayMode) {
                        ForEach(DuoFrontDisplayMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    } label: {
                        Text("Layout")
                            .settingRow(Settings.Tabs.duoFrontDisplayMode)
                    }
                    .pickerStyle(.menu)
                    .disabled(SettingFileLock.isReadOnly(Settings.Tabs.duoFrontDisplayMode.name))
                    .themedRow()

                    if duoFrontDisplayMode == .behindCamera {
                        SettingDescribedToggle(
                            Settings.Tabs.duoBehindCameraShowsTabs,
                            title: "Show Top Tabs",
                            description: "Text behind the camera will be hidden."
                        )
                        .themedRow()
                    }
                } header: {
                    Text("Duo Front Display")
                } footer: {
                    Text("Choose the terminal layout when Duo is closed. Side Rail moves tabs beside the terminal. Below Camera keeps top tabs and uses the full width beneath the camera. Behind Camera lets the terminal extend beneath the camera.")
                        .font(.caption)
                }
            }
            #endif

            #if targetEnvironment(macCatalyst)
            Section {
                SettingToggle(Settings.Window.tabsInTitlebar, title: "Tabs in Title Bar")
                    .themedRow()

                SettingDescribedToggle(
                    Settings.Window.hideTitleBar,
                    title: "Hide Title Bar",
                    description: "Removes the macOS title bar and window controls so content reaches the top edge. Close the window with ⌘W and enter full screen with the View menu."
                )
                .themedRow()
            } header: {
                SettingGroupHeader("Title Bar", group: .window)
            } footer: {
                Text("Moves the tab bar into the macOS title bar area to remove the extra top row.")
                    .font(.caption)
            }
            #endif
        }
        .themedList()
        .navigationTitle("Tab Bar")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The tab bar scene, reading every setting it draws.
struct TabBarScenePreview: View {
    var height: CGFloat = 176
    var hoverMoment = false
    var exposeMoment = false

    @Setting(Settings.Tabs.barHidden) private var tabBarHidden
    @Setting(Settings.Tabs.barPosition) private var tabBarPosition
    @Setting(Settings.Tabs.topTabStyle) private var topTabStyle
    @Setting(Settings.Tabs.compactPillSpacing) private var compactPillTabSpacing
    @Setting(Settings.Tabs.showShortcutIndicators) private var showShortcuts
    @Setting(Settings.Tabs.showScopeMenu) private var showGroupMenu
    @Setting(Settings.Tabs.scopeMenuSize) private var groupMenuSize
    @Setting(Settings.Tabs.programIcons) private var programIcons
    @Setting(Settings.Tabs.barAnimationsDisabled) private var animationsDisabled
    @Setting(Settings.Tabs.hoverPreviews) private var hoverPreviews
    @Setting(Settings.Window.tabsInTitlebar) private var tabsInTitlebar
    @Setting(Settings.Window.hideTitleBar) private var hideTitleBar
    @Setting(Settings.Tabs.exposeShowsCaptions) private var exposeShowsCaptions

    var body: some View {
        var values = TabBarSceneValues()
        values.tabsInTitleBar = tabsInTitlebar ? 1 : 0
        values.hideTitleBar = hideTitleBar ? 1 : 0
        values.shown = tabBarHidden ? 0 : 1
        values.bottom = tabBarPosition == .bottom ? 1 : 0
        let layout = TopTabLayout.resolve(style: topTabStyle, compactPills: compactPillTabSpacing)
        values.layout = Double(PreviewTabStyle(layout).rawValue)
        values.shortcuts = showShortcuts ? 1 : 0
        values.groupMenu = showGroupMenu ? 1 : 0
        values.groupMenuSize = Double(TabScopeMenuSize.allCases.firstIndex(of: groupMenuSize) ?? 0)
        values.programIcons = programIcons ? 1 : 0
        values.animationsOff = animationsDisabled ? 1 : 0
        values.hoverPreviews = hoverPreviews ? 1 : 0
        values.hoverMoment = hoverMoment ? 1 : 0
        values.exposeCaptions = exposeShowsCaptions ? 1 : 0
        values.exposeMoment = exposeMoment ? 1 : 0
        return PreviewSceneCard(values: values.vector, height: height, draw: TabBarScene.draw)
    }
}

/// The window preview above the three tab bar choices that change it.
struct TabBarPreviewCard: View {
    @Setting(Settings.Tabs.barHidden) private var tabBarHidden
    @Setting(Settings.Tabs.barPosition) private var tabBarPosition
    @Setting(Settings.Tabs.topTabStyle) private var topTabStyle
    @Setting(Settings.Tabs.compactPillSpacing) private var compactPillTabSpacing
    @Setting(Settings.Tabs.hoverPreviews) private var hoverPreviews
    @Setting(Settings.Tabs.hoverPreviewActivation) private var hoverPreviewActivation
    @Setting(Settings.Tabs.exposeShowsCaptions) private var exposeShowsCaptions
    // Brief scenes for settings the tab strip alone can't show.
    @State private var hoverMoment = false
    @State private var exposeMoment = false
    @State private var momentToken = 0

    private var layout: TopTabLayout {
        TopTabLayout.resolve(style: topTabStyle, compactPills: compactPillTabSpacing)
    }

    private func select(_ layout: TopTabLayout) {
        topTabStyle = layout.style
        if layout.style == .pills {
            compactPillTabSpacing = layout.usesCompactPillSpacing
        }
    }

    private func showMoment(hover: Bool) {
        hoverMoment = hover
        exposeMoment = !hover
        momentToken += 1
    }

    var body: some View {
        VStack(spacing: 12) {
            TabBarScenePreview(hoverMoment: hoverMoment, exposeMoment: exposeMoment)
                .onChange(of: hoverPreviews) { _, _ in showMoment(hover: true) }
                .onChange(of: hoverPreviewActivation) { _, _ in showMoment(hover: true) }
                .onChange(of: exposeShowsCaptions) { _, _ in showMoment(hover: false) }
                .task(id: momentToken) {
                    guard momentToken > 0 else { return }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    hoverMoment = false
                    exposeMoment = false
                }

            let visibility = PreviewSegmentedControl<Bool>(
                title: "Tab Bar",
                options: [
                    .init(value: false, symbol: "eye", title: String(localized: "Shown", comment: "Tab bar visibility")),
                    .init(value: true, symbol: "eye.slash", title: String(localized: "Hidden", comment: "Tab bar visibility")),
                ],
                selection: tabBarHidden,
                onSelect: { tabBarHidden = $0 }
            )
            .disabled(SettingFileLock.isReadOnly(Settings.Tabs.barHidden.name))
            .settingContextMenu(Settings.Tabs.barHidden)

            let position = PreviewSegmentedControl<TabBarPosition>(
                title: "Tab Bar Position",
                options: TabBarPosition.allCases.map {
                    .init(value: $0, symbol: $0 == .top ? "arrow.up.to.line" : "arrow.down.to.line", title: $0.displayName)
                },
                selection: tabBarPosition,
                onSelect: { tabBarPosition = $0 }
            )
            .disabled(SettingFileLock.isReadOnly(Settings.Tabs.barPosition.name))
            // Still choosable while hidden; it applies once the bar is back.
            .opacity(tabBarHidden ? 0.5 : 1)
            .settingContextMenu(Settings.Tabs.barPosition)

            // Side by side when both fit untruncated (wide rows), stacked otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    visibility.fixedSize(horizontal: true, vertical: false)
                    position.fixedSize(horizontal: true, vertical: false)
                }
                VStack(spacing: 8) {
                    visibility
                    position
                }
            }

            TabStyleTilePicker(selection: layout, onSelect: select)
                .disabled(SettingFileLock.isReadOnly(Settings.Tabs.topTabStyle.name))
                .opacity(tabBarHidden ? 0.5 : 1)
                .settingContextMenu(Settings.Tabs.topTabStyle)

            // Every caption laid out at once so the row keeps its height.
            ZStack {
                ForEach(Self.captionKeys, id: \.self) { key in
                    Text(caption(for: key))
                        .opacity(key == currentCaptionKey ? 1 : 0)
                        .accessibilityHidden(key != currentCaptionKey)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: currentCaptionKey)
        }
        .padding(.vertical, 6)
    }

    private static let captionKeys = ["hidden"] + TopTabLayout.allCases.map(\.rawValue)

    private var currentCaptionKey: String { tabBarHidden ? "hidden" : layout.rawValue }

    private func caption(for key: String) -> String {
        switch key {
        case "hidden":
            String(localized: "The tab bar is hidden, so the terminal fills the window.", comment: "Tab bar preview caption")
        case TopTabLayout.compactPills.rawValue:
            String(localized: "Pills that sit edge to edge, so more tabs fit.", comment: "Tab bar preview caption: Compact Pills")
        case TopTabLayout.integrated.rawValue:
            String(localized: "The selected tab joins the terminal, like a browser tab.", comment: "Tab bar preview caption: Integrated")
        case TopTabLayout.ledger.rawValue:
            String(localized: "Plain titles, with an accent line under the selected tab.", comment: "Tab bar preview caption: Ledger")
        case TopTabLayout.trough.rawValue:
            String(localized: "Tabs share one track, and the selected tab slides along it.", comment: "Tab bar preview caption: Trough")
        default:
            String(localized: "Each tab is a rounded pill, with a little space between them.", comment: "Tab bar preview caption: Pills")
        }
    }
}

// MARK: - Controls

/// Icon segmented control in the style of the Appearance Mode picker.
struct PreviewSegmentedControl<Value: Hashable>: View {
    struct Option {
        let value: Value
        let symbol: String
        let title: String
    }

    let title: LocalizedStringKey
    let options: [Option]
    let selection: Value
    let onSelect: (Value) -> Void
    /// Vertical stacks each icon over its title, for many options in a narrow row.
    var labelAxis: Axis = .horizontal

    @Namespace private var pillNamespace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var bounceCounts: [Value: Int] = [:]

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(options, id: \.value) { option in
                segment(option)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityRepresentation {
            Picker(title, selection: Binding(get: { selection }, set: onSelect)) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            guard !isSelected else { return }
            bounceCounts[option.value, default: 0] += 1
            withAnimation(.smooth(duration: 0.35)) { onSelect(option.value) }
        } label: {
            let label = labelAxis == .vertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 6))
            label {
                Image(systemName: option.symbol)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .symbolEffect(.bounce, value: bounceCounts[option.value, default: 0])
                Text(option.title)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, labelAxis == .vertical ? 7 : 9)
            .padding(.horizontal, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.tint.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(.tint.opacity(0.85), lineWidth: 1.5)
                        }
                        .matchedGeometryEffect(id: "pill", in: pillNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Each tab style as a miniature of the real strip, drawn by the scene's painter.
private struct TabStyleTilePicker: View {
    let selection: TopTabLayout
    let onSelect: (TopTabLayout) -> Void

    @Namespace private var pillNamespace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.self) private var environment

    var body: some View {
        let palette = WindowPreviewPalette.current(sheetThemeColors: sheetThemeColors, environment: environment)
        let minWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 130 : 58
        TileRowLayout(minWidth: minWidth, maxWidth: max(minWidth, 96), spacing: 2) {
            ForEach(TopTabLayout.allCases) { layout in
                tile(layout, palette: palette)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityRepresentation {
            Picker("Tab Style", selection: Binding(get: { selection }, set: onSelect)) {
                ForEach(TopTabLayout.allCases) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
        }
    }

    /// Tiles are narrow; the shortest name that still tells the styles apart.
    private func tileName(_ layout: TopTabLayout) -> String {
        layout == .compactPills ? String(localized: "Compact", comment: "Tab style tile for Compact Pills") : layout.displayName
    }

    private func tile(_ layout: TopTabLayout, palette: WindowPreviewPalette) -> some View {
        let isSelected = layout == selection
        let style = PreviewTabStyle(layout)
        return Button {
            guard !isSelected else { return }
            withAnimation(.smooth(duration: 0.35)) { onSelect(layout) }
        } label: {
            VStack(spacing: 6) {
                Canvas { context, size in
                    let bounds = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7)
                    context.fill(bounds, with: .color(palette.background.color()))
                    context.clip(to: bounds)
                    let strip = CGRect(x: -size.width * 0.04, y: 0, width: size.width * 1.08, height: size.height * 0.7)
                    context.fill(Path(strip), with: .color(palette.chrome.color()))
                    TabStripPainter(palette: palette, k: size.width / 118, selection: 1, time: 0)
                        .paint(&context, layout: style, strip: strip, terminalBelow: true)
                }
                .frame(height: 34)
                Text(tileName(layout))
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.tint.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(.tint.opacity(0.85), lineWidth: 1.5)
                        }
                        .matchedGeometryEffect(id: "pill", in: pillNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Equal-width tiles that wrap like an adaptive grid when narrow, but never make
/// more columns than tiles and stop growing at `maxWidth`, so wide rows hug and center.
private struct TileRowLayout: Layout {
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let spacing: CGFloat

    private struct Metrics {
        let columns: Int
        let tileWidth: CGFloat
        let rowHeights: [CGFloat]
        var width: CGFloat { CGFloat(columns) * tileWidth + CGFloat(columns - 1) * spacing }
        var height: CGFloat { rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * spacing }
        let spacing: CGFloat
    }

    private func metrics(width proposed: CGFloat?, subviews: Subviews) -> Metrics {
        let count = max(1, subviews.count)
        let available = proposed ?? CGFloat(count) * maxWidth + CGFloat(count - 1) * spacing
        let fit = Int((available + spacing) / (minWidth + spacing))
        let columns = min(count, max(1, fit))
        let tileWidth = min(maxWidth, (available - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let proposal = ProposedViewSize(width: tileWidth, height: nil)
        let rowHeights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)].map { $0.sizeThatFits(proposal).height }.max() ?? 0
        }
        return Metrics(columns: columns, tileWidth: tileWidth, rowHeights: rowHeights, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = metrics(width: proposal.width, subviews: subviews)
        return CGSize(width: m.width, height: m.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(width: bounds.width, subviews: subviews)
        let originX = bounds.minX + (bounds.width - m.width) / 2
        var y = bounds.minY
        for (row, height) in m.rowHeights.enumerated() {
            for column in 0..<m.columns {
                let index = row * m.columns + column
                guard index < subviews.count else { break }
                let x = originX + CGFloat(column) * (m.tileWidth + m.spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: m.tileWidth, height: height))
            }
            y += height + m.spacing
        }
    }
}

// MARK: - Tab Switcher

struct WindowTabSwitcherSettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Setting(Settings.Sidebar.translucent) private var tabSidebarTranslucent
    @Setting(Settings.Sidebar.rowLines) private var tabSidebarRowLines
    @Setting(Settings.Sidebar.autoHideOnSelect) private var autoHideOnSelect

    /// Compact layouts present tabs in a switcher; regular ones in a sidebar.
    static func title(_ sizeClass: UserInterfaceSizeClass?) -> String {
        sizeClass != .regular ? String(localized: "Tab Switcher") : String(localized: "Tab Sidebar")
    }

    var body: some View {
        List {
            Section {
                PreviewSceneCard(
                    values: TabSwitcherSceneValues(translucent: tabSidebarTranslucent, autoHide: autoHideOnSelect,
                                                   titleLines: tabSidebarRowLines,
                                                   sidebar: horizontalSizeClass == .regular).vector,
                    draw: TabSwitcherScene.draw
                )
                .themedRow()
            }

            Section {
                #if !os(visionOS)
                Toggle(isOn: $tabSidebarTranslucent) {
                    HStack(spacing: 6) {
                        Text(horizontalSizeClass != .regular
                            ? String(localized: "Translucent Tab Switcher")
                            : String(localized: "Translucent Tab Sidebar"))
                        SettingPinTag(Settings.Sidebar.translucent.erased)
                    }
                }
                .themedRow()
                .settingContextMenu(Settings.Sidebar.translucent)

                // Compact layouts dismiss the switcher on selection; regular
                // layouts can keep a sidebar open beside the terminal.
                if horizontalSizeClass == .regular {
                    SettingDescribedToggle(
                        Settings.Sidebar.autoHideOnSelect,
                        title: "Auto-Hide Sidebar After Selection",
                        description: "Closes the floating (non-pinned) sidebar after you pick a tab. The pinned sidebar always stays open."
                    )
                    .themedRow()
                }
                #endif

                // Uniform for every row so the list stays symmetric; long
                // titles wrap instead of truncating.
                Stepper(value: $tabSidebarRowLines, in: 1...3) {
                    HStack {
                        Text(horizontalSizeClass != .regular
                            ? String(localized: "Tab Switcher Title Lines")
                            : String(localized: "Sidebar Title Lines"))
                            .settingRow(Settings.Sidebar.rowLines)
                        Spacer()
                        Text("\(tabSidebarRowLines)")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle(Self.title(horizontalSizeClass))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Panes & Padding

struct WindowPanesSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.self) private var environment
    @Setting(Settings.Window.roundedPanes) private var roundedPanes
    @Setting(Settings.Window.showRemotePorts) private var showRemotePorts
    // Padding guides show briefly after a padding change.
    @State private var paddingMoment = false
    @State private var paddingToken = 0
    @Setting(Settings.Window.splitFocusBorderStyle) private var splitFocusBorderStyle
    @Setting(Settings.Window.splitFocusBorderColor) private var splitFocusBorderColor
    @Setting(Settings.Window.splitFocusBorderCustomColor) private var splitFocusBorderCustomHex
    @Bindable private var paddingManager = PaddingManager.shared

    var body: some View {
        List {
            Section {
                PreviewSceneCard(values: sceneValues.vector, draw: PanesScene.draw)
                    .themedRow()
            }

            Section {
                Stepper(value: Binding(
                    get: { paddingManager.userPaddingX },
                    set: { paddingManager.setPaddingX($0) }
                ), in: 0...32) {
                    HStack {
                        Text("Horizontal")
                            .settingRow(Settings.Terminal.paddingXOverride)
                        Spacer()
                        Text("\(paddingManager.userPaddingX) pt")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()

                Stepper(value: Binding(
                    get: { paddingManager.userPaddingY },
                    set: { paddingManager.setPaddingY($0) }
                ), in: 0...32) {
                    HStack {
                        Text("Vertical")
                            .settingRow(Settings.Terminal.paddingYOverride)
                        Spacer()
                        Text("\(paddingManager.userPaddingY) pt")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()

                if paddingManager.isCustom {
                    Button("Reset to Defaults (\(paddingManager.defaultPaddingX) pt / \(paddingManager.defaultPaddingY) pt)") {
                        paddingManager.resetToDefaults()
                    }
                    .foregroundColor(.accentColor)
                    .themedRow()
                }
            } header: {
                SettingGroupHeader("Window Padding", group: .terminal)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(paddingManager.isCustom
                         ? "Custom padding active. Reset to restore the platform default."
                         : "Using platform default. Adjust the inset between terminal text and the window edges.")
                    if paddingManager.roundedPanesRaisesPadding {
                        Text("Rounded Panes uses at least \(PaddingManager.roundedPanesMinimum) pt so text clears the rounded corners.")
                    }
                }
                .font(.caption)
            }

            Section {
                SettingDescribedToggle(
                    Settings.Window.roundedPanes,
                    title: "Rounded Panes",
                    description: "Draws terminal panes, splits, and docked sidebars as rounded cards with gaps between them.")
                .themedRow()

                Picker(selection: $splitFocusBorderStyle) {
                    ForEach(SplitFocusBorderStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style)
                    }
                } label: {
                    Text("Split Focus Border")
                        .settingRow(Settings.Window.splitFocusBorderStyle)
                }
                .themedRow()

                Picker(selection: $splitFocusBorderColor) {
                    ForEach(SplitFocusBorderColor.allCases, id: \.rawValue) { color in
                        Text(color.displayName).tag(color)
                    }
                } label: {
                    Text("Border Color")
                        .settingRow(Settings.Window.splitFocusBorderColor)
                }
                .themedRow()

                if splitFocusBorderColor == .custom {
                    ColorPicker(selection: Binding(
                        get: {
                            Color(hex: splitFocusBorderCustomHex) ?? .blue
                        },
                        set: { newColor in
                            splitFocusBorderCustomHex = UIColor(newColor).hexString
                        }
                    )) {
                        Text("Custom Color")
                            .settingRow(Settings.Window.splitFocusBorderCustomColor)
                    }
                    .themedRow()
                }
            } header: {
                SettingGroupHeader("Split Panes", group: .window)
            } footer: {
                Text("Controls how panes are drawn and how the focused pane stands out in split terminal layouts. Close confirmations are in Terminal › Tabs.")
                    .font(.caption)
            }

            Section {
                SettingDescribedToggle(
                    Settings.Window.showRemotePorts,
                    title: "Show Remote Ports",
                    description: "Shows a globe at the bottom-right of the terminal that lists the TCP ports the connected host listens on. Choosing a port forwards it to this device and opens it in an in-app browser tab.")
                .themedRow()
            } header: {
                SettingGroupHeader("Remote Ports", group: .window)
            } footer: {
                Text("While this is on, each visible terminal polls the host for its listening ports every few seconds. Off by default so the scan only runs when you ask for it.")
                    .font(.caption)
            }
        }
        .themedList()
        .navigationTitle("Panes & Padding")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: paddingManager.paddingXOverride) { _, _ in
            reloadGhosttyConfig()
            showPaddingGuides()
        }
        .onChange(of: paddingManager.paddingYOverride) { _, _ in
            reloadGhosttyConfig()
            showPaddingGuides()
        }
        .task(id: paddingToken) {
            guard paddingToken > 0 else { return }
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            paddingMoment = false
        }
    }

    private func showPaddingGuides() {
        paddingMoment = true
        paddingToken += 1
    }

    private var sceneValues: PanesSceneValues {
        var values = PanesSceneValues()
        values.paddingX = Double(paddingManager.userPaddingX)
        values.paddingY = Double(paddingManager.userPaddingY)
        values.rounded = roundedPanes ? 1 : 0
        values.borderWidth = Double(splitFocusBorderStyle.borderWidth)
        values.borderOpacity = Double(splitFocusBorderStyle.opacity)
        switch splitFocusBorderColor {
        case .accent:
            values.borderColor = WindowPreviewPalette.current(sheetThemeColors: sheetThemeColors, environment: environment).accent
        case .gray:
            values.borderColor = PreviewRGB(0.56, 0.56, 0.6)
        case .custom:
            values.borderColor = PreviewRGB(hex: splitFocusBorderCustomHex) ?? PreviewRGB(0.04, 0.52, 1)
        }
        values.remotePorts = showRemotePorts ? 1 : 0
        values.paddingMoment = paddingMoment ? 1 : 0
        return values
    }

    private func reloadGhosttyConfig() {
        // Rewriting the config via setFontSize regenerates the full file,
        // including the new window-padding-x/y values.
        guard let app = Ghostty.App.shared else { return }
        let currentFontSize = Int(FontManager.shared.currentFontSize)
        if app.config.setFontSize(currentFontSize) {
            app.pushGlobalConfigToApp()
        }
    }
}

// MARK: - Display

struct WindowDisplaySettingsView: View {
    @Environment(\.duoLayout) private var duoLayout
    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    @Setting(Settings.Window.fullScreenMode) private var fullScreenMode
    #endif
    @Bindable private var paddingManager = PaddingManager.shared
    // HDR "brightness boost" — the same global gain the floating brightness HUD
    // drives, surfaced here so it can be set without summoning the overlay.
    @Bindable private var brightnessManager = BrightnessManager.shared
    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    @Bindable private var alwaysOnDisplayManager = AlwaysOnDisplayManager.shared
    #endif

    /// EDR is meaningless on visionOS, so there is no Display page there. On
    /// Catalyst the brightness boost is the page's only content, and its APIs
    /// only exist on 26+.
    static var isAvailable: Bool {
        #if os(visionOS)
        return false
        #elseif targetEnvironment(macCatalyst)
        return brightnessBoostAvailable
        #else
        return true
        #endif
    }

    /// The EDR brightness-boost APIs only exist on 26+; below that the slider
    /// would do nothing, so the control is hidden (not just disabled).
    private static var brightnessBoostAvailable: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }

    /// The display's maximum potential EDR headroom (peak EDR white ÷ SDR white).
    /// 1.0 means no EDR (SDR panel, visionOS, or already at full brightness). We
    /// read `potentialEDRHeadroom` (stable) not `currentEDRHeadroom` (which ramps
    /// and collapses at max brightness) so the slider's range doesn't jump.
    private var potentialEDRHeadroom: CGFloat {
        #if os(visionOS)
        return 1.0
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map { $0.screen.potentialEDRHeadroom }
            .max() ?? 1.0
        #endif
    }

    private var sceneValues: DisplaySceneValues {
        var values = DisplaySceneValues()
        if brightnessSliderMax > 1.0001 {
            values.brightness = min(1, max(0, (brightnessManager.gain - 1) / (brightnessSliderMax - 1)))
        }
        values.duoFrontMode = Double(DuoFrontDisplayMode.allCases.firstIndex(of: duoLayout.frontMode) ?? 0)
        values.duoShowsTabs = duoLayout.behindCameraShowsTabs ? 1 : 0
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        values.fullScreen = fullScreenMode ? 1 : 0
        values.hasHomeIndicator = deviceHasHomeIndicator ? 1 : 0
        values.extendUnderHomeIndicator = paddingManager.extendUnderHomeIndicator ? 1 : 0
        switch alwaysOnDisplayManager.duration {
        case .off: values.alwaysOn = 0
        case .minutes: values.alwaysOn = 1
        case .always: values.alwaysOn = 2
        }
        #endif
        return values
    }

    /// Whether the display currently has usable EDR headroom to boost into.
    private var hasEDRHeadroom: Bool { potentialEDRHeadroom > 1.02 }

    /// Slider upper bound: clamped to the display's headroom and the manager's
    /// hard cap, but never below a sliver so the track stays draggable.
    private var brightnessSliderMax: Double {
        max(min(Double(potentialEDRHeadroom), BrightnessManager.maxGainCap), 1.05)
    }

    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    /// Whether this device has a home indicator (a non-zero bottom safe area).
    /// False on home-button devices, where "Extend Under Home Indicator" would be
    /// meaningless — so we hide the toggle there.
    private var deviceHasHomeIndicator: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.safeAreaInsets.bottom > 0 }
    }
    #endif

    var body: some View {
        List {
            Section {
                PreviewSceneCard(values: sceneValues.vector, draw: DisplayScene.draw)
                    .themedRow()
            }

            #if !os(visionOS)
            Section {
                #if !targetEnvironment(macCatalyst)
                SettingDescribedToggle(
                    Settings.Window.fullScreenMode,
                    title: "Full Screen",
                    description: "Hides the status bar and iPadOS window resize handle for a distraction-free terminal."
                )
                .themedRow()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Always On Display")
                            .settingRow(Settings.Power.alwaysOnDisplayMinutes)
                        Spacer()
                        Text(alwaysOnDisplayManager.duration.displayValue)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            // A floor, not a fixed width: it keeps the slider from
                            // shifting as the value changes without clipping
                            // "Always" at large Dynamic Type sizes.
                            .frame(minWidth: 68, alignment: .trailing)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "moon.zzz")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(
                            value: $alwaysOnDisplayManager.sliderValue,
                            in: AlwaysOnDisplayDuration.sliderRange,
                            step: 1
                        )
                        // The row title is a sibling in the HStack above, so the
                        // slider needs its own name for VoiceOver.
                        .accessibilityLabel(Text("Always On Display"))
                        .accessibilityValue(alwaysOnDisplayManager.duration.displayValue)
                        Image(systemName: "infinity")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(alwaysOnDisplayManager.duration.explanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .themedRow()

                if deviceHasHomeIndicator {
                    SettingDescribedToggle(
                        Settings.Window.extendUnderHomeIndicator,
                        isOn: $paddingManager.extendUnderHomeIndicator,
                        title: "Extend Under Home Indicator",
                        description: "Run the terminal and its keyboard toolbar edge-to-edge under the home indicator. Off keeps a small gap so the home-swipe gesture doesn't interfere with taps and text selection near the bottom."
                    )
                    .themedRow()
                }
                #endif

                if Self.brightnessBoostAvailable {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Brightness Boost")
                                .settingRow(Settings.Power.brightnessGain)
                            Spacer()
                            Text(String(format: "%.2f×", brightnessManager.gain))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "sun.min")
                                .foregroundStyle(.secondary)
                            Slider(value: $brightnessManager.gain, in: 1.0...brightnessSliderMax, step: 0.05)
                                .disabled(!hasEDRHeadroom)
                            Image(systemName: "sun.max.fill")
                                .foregroundStyle(.secondary)
                        }
                        Text(hasEDRHeadroom
                            ? String(localized: "Pushes terminal content above standard brightness using your display's HDR (EDR) headroom. Also available as a floating slider via a keybind or the keyboard toolbar.")
                            : String(localized: "No HDR headroom at the current display brightness (SDR display, or already at maximum brightness). Lower the display brightness to free up headroom."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .themedRow()

                    if brightnessManager.isBoosted {
                        Button("Reset Brightness") {
                            brightnessManager.reset()
                        }
                        .themedRow()
                    }
                }
            }
            #endif
        }
        .themedList()
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Text Selection

struct WindowSelectionSettingsView: View {
    @Setting(Settings.Selection.copyOnSelect) private var copyOnSelect
    @Setting(Settings.Selection.useNativeLoupe) private var useNativeLoupe
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.self) private var environment
    @Bindable private var selectionManager = SelectionManager.shared

    var body: some View {
        List {
            Section {
                PreviewSceneCard(values: sceneValues.vector, draw: SelectionScene.draw)
                    .themedRow()
            }

            Section {
                Picker(selection: $selectionManager.selectionMode) {
                    ForEach(SelectionAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Text("Selection Style")
                        .settingRow(Settings.Selection.appearanceMode)
                }
                .themedRow()

                if selectionManager.selectionMode == .custom {
                    ColorPicker(selection: Binding(
                        get: {
                            Color(hex: selectionManager.customForegroundHex) ?? .white
                        },
                        set: { newColor in
                            selectionManager.customForegroundHex = UIColor(newColor).hexString
                        }
                    )) {
                        Text("Foreground")
                            .settingRow(Settings.Selection.foregroundHex)
                    }
                    .themedRow()

                    ColorPicker(selection: Binding(
                        get: {
                            Color(hex: selectionManager.customBackgroundHex) ?? .blue
                        },
                        set: { newColor in
                            selectionManager.customBackgroundHex = UIColor(newColor).hexString
                        }
                    )) {
                        Text("Background")
                            .settingRow(Settings.Selection.backgroundHex)
                    }
                    .themedRow()
                }
                SettingToggle(Settings.Selection.copyOnSelect, title: "Copy on Select")
                    .padding(.vertical, 4)
                    .themedRow()

                #if os(iOS) && !targetEnvironment(macCatalyst)
                SettingDescribedToggle(
                    Settings.Selection.useNativeLoupe,
                    title: "Use Native Selection Loupe",
                    description: "Keep this off to tap the app's loupe with a second finger for a right click while holding the terminal. Requires Scroll Mode. See Terminal → Gestures → Gesture Help."
                )
                    .padding(.vertical, 4)
                    .themedRow()
                #endif
            } header: {
                SettingGroupHeader("Text Selection", group: .selection)
            } footer: {
                Text(copyOnSelect
                    ? String(localized: "Selected text is automatically copied to the clipboard.")
                    : selectionManager.selectionMode.description)
                    .font(.caption)
            }
        }
        .themedList()
        .navigationTitle("Text Selection")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: copyOnSelect) { _, _ in
            // Rewrite config file with updated copy-on-select and reload
            if let app = Ghostty.App.shared {
                let currentFontSize = Int(FontManager.shared.currentFontSize)
                if app.config.setFontSize(currentFontSize) {
                    app.pushGlobalConfigToApp()
                }
            }
        }
    }
}

extension WindowSelectionSettingsView {
    /// The selection colors each style resolves to, for the preview.
    fileprivate var sceneValues: SelectionSceneValues {
        let palette = WindowPreviewPalette.current(sheetThemeColors: sheetThemeColors, environment: environment)
        var values = SelectionSceneValues()
        switch selectionManager.selectionMode {
        case .rootshell:
            values.selectionForeground = PreviewRGB(hex: SelectionManager.rootshellForegroundHex) ?? palette.background
            values.selectionBackground = PreviewRGB(hex: SelectionManager.rootshellBackgroundHex) ?? palette.foreground
        case .themeDefault:
            // Themes in the preview carry no selection colors; this is the usual look.
            values.selectionForeground = palette.foreground
            values.selectionBackground = palette.foreground.mix(palette.background, 0.7)
        case .invertFgBg:
            values.selectionForeground = palette.background
            values.selectionBackground = palette.foreground
        case .custom:
            values.selectionForeground = PreviewRGB(hex: selectionManager.customForegroundHex) ?? palette.background
            values.selectionBackground = PreviewRGB(hex: selectionManager.customBackgroundHex) ?? palette.accent
        }
        values.copyOnSelect = copyOnSelect ? 1 : 0
        #if os(iOS) && !targetEnvironment(macCatalyst)
        values.touch = 1
        values.nativeLoupe = useNativeLoupe ? 1 : 0
        #else
        values.touch = 0
        #endif
        return values
    }
}
