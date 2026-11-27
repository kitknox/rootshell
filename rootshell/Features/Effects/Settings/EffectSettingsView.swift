//
//  EffectSettingsView.swift
//  rootshell
//
//  Settings → Background Effect: the stage, a gallery for the area being
//  edited, and the effect's main controls. Everything else is on its page.
//

import Combine
import SwiftUI
import UIKit

struct EffectSettingsView: View {
    var effectManager = EffectManager.shared
    var transparencyManager = TransparencyManager.shared

    @Setting(Settings.Shaders.sidebarEffectId) private var sidebarEffectID
    @Setting(Settings.Shaders.effectIncludesPinnedSidebar) private var includesSidebar
    @Setting(Settings.Shaders.keyboardBackgroundEffect) private var keyboardPlacement
    @Setting(Settings.Shaders.keyboardEffectId) private var keyboardEffectID

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.duoLayout) private var duoLayout

    @State private var area: BackgroundEffectArea
    /// 0 with the stage fully shown, 1 once it has shrunk to the band.
    @State private var collapse = 0.0
    @State private var controlsHeight: CGFloat = 52
    @State private var showsVideoLibrary = false
    @State private var textMoment = 0
    @State private var separation = 0.0
    /// Bumped when a gradient's style changes, so its tiles and stage repaint.
    @State private var gradientRevision = 0

    /// Search results for one area open on it.
    init(initialArea: BackgroundEffectArea = .terminal) {
        _area = State(initialValue: initialArea)
    }

    private let headerTopPadding: CGFloat = 8
    private let headerSpacing: CGFloat = 10
    private let headerBottomPadding: CGFloat = 4
    /// The unfolded Duo docks a tab sidebar too, though it reports a phone idiom.
    private var areas: [BackgroundEffectArea] {
        BackgroundEffectArea.allCases.filter { candidate in
            candidate == .sidebar ? candidate.isAvailable || (duoLayout.hasHinge && !duoLayout.isFrontDisplay) : candidate.isAvailable
        }
    }

    private var metrics: (expanded: CGFloat, collapsed: CGFloat) {
        verticalSizeClass == .compact ? (128, 56) : (176, 72)
    }

    private var groundColor: Color {
        sheetThemeColors?.background ?? Color(uiColor: .systemGroupedBackground)
    }

    var body: some View {
        // The stage floats over the list, which reserves room for it fully
        // expanded, so rows stay attached as it shrinks.
        ZStack(alignment: .top) {
            List {
                switch area {
                case .terminal: terminalPanel
                case .sidebar: sidebarPanel
                case .keyboard: keyboardPanel
                case .window: windowPanel
                }
            }
            .themedList()
            .contentMargins(.top, headerHeight, for: .scrollContent)
            .contentMargins(.top, headerHeight, for: .scrollIndicators)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                let next = min(max(offset / (metrics.expanded - metrics.collapsed), 0), 1)
                if next != collapse { collapse = next }
            }

            header
        }
        .background(groundColor.ignoresSafeArea())
        .navigationTitle("Background Effect")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsVideoLibrary) {
            VideoBackgroundLibraryView(area: area)
        }
        .onChange(of: effectManager.isTextAboveEffectEnabled) { _, _ in textMoment += 1 }
        .onChange(of: areas, initial: true) { _, available in
            if !available.contains(area) { area = .terminal }
        }
        .task { await watchGradient(effectManager.effect(withId: "themeGradient")) }
        .task { await watchGradient(effectManager.backdropEffect) }
        .task(id: textMoment) {
            guard textMoment > 0, !reduceMotion else { return }
            withAnimation(.smooth(duration: 0.4)) { separation = 1 }
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.smooth(duration: 0.5)) { separation = 0 }
        }
    }

    private var headerHeight: CGFloat {
        metrics.expanded + headerTopPadding + headerSpacing + controlsHeight + headerBottomPadding
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: headerSpacing) {
            BackgroundEffectStage(state: stageState, collapse: collapse,
                                  expandedHeight: metrics.expanded, collapsedHeight: metrics.collapsed,
                                  separation: separation)
            PreviewSegmentedControl<BackgroundEffectArea>(
                title: "Area",
                options: areas.map { PreviewSegmentedControl<BackgroundEffectArea>.Option(value: $0, symbol: $0.symbol, title: $0.title) },
                selection: area,
                onSelect: { area = $0 },
                labelAxis: horizontalSizeClass == .compact && areas.count > 3 ? .vertical : .horizontal
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
        }
        .padding(.top, headerTopPadding)
        .padding(.horizontal, 16)
        .padding(.bottom, headerBottomPadding)
        .background(groundColor.ignoresSafeArea(edges: .top))
    }

    private func watchGradient(_ effect: AnyTerminalEffect?) async {
        guard let effect else { return }
        for await _ in effect.configurationDidChange.values { gradientRevision &+= 1 }
    }

    private var stageState: BackgroundEffectStageState {
        _ = gradientRevision
        return BackgroundEffectStageState(
            area: area,
            areas: areas,
            terminal: effectManager.activeEffect,
            sidebar: effectManager.selectedEffect(id: sidebarSelection),
            keyboard: effectManager.selectedEffect(id: keyboardEffectID),
            keyboardPlacement: keyboardPlacement,
            backdrop: effectManager.isBackdropEnabled ? effectManager.backdropEffect : nil,
            textAbove: effectManager.isTextAboveEffectEnabled
        )
    }

    // MARK: Terminal

    @ViewBuilder
    private var terminalPanel: some View {
        EffectGallerySection(
            title: "Terminal Effect",
            items: galleryItems(includesFollow: false),
            selectedID: terminalSelection,
            footer: nil,
            onSelect: { select($0, in: .terminal) }
        )

        if let pending = effectManager.pendingVideoActivation {
            PendingVideoSection(videoID: pending)
        }

        if let effect = effectManager.activeEffect {
            tuning(for: effect, in: .terminal)
        }

        Section {
            SettingDescribedToggle(
                Settings.Shaders.textAboveEffect,
                isOn: Binding(get: { effectManager.isTextAboveEffectEnabled },
                              set: { effectManager.isTextAboveEffectEnabled = $0 }),
                title: "Text Above Effect",
                description: "Draws terminal text over the effect in its own colors. Off, the effect washes over the text too. Programs that paint their own background, such as some Neovim color schemes, cover the effect there."
            )
            .themedRow()
        }
    }

    private var terminalSelection: String {
        guard let id = effectManager.activeEffect?.id else { return "" }
        return id.hasPrefix(Self.videoPrefix) ? Self.videoTileID : id
    }

    // MARK: Sidebar

    /// The old Include Pinned Sidebar preference reads as None when off.
    private var sidebarSelection: String {
        sidebarEffectID == BackgroundEffectSelection.followTerminalID && !includesSidebar ? "" : sidebarEffectID
    }

    @ViewBuilder
    private var sidebarPanel: some View {
        EffectGallerySection(
            title: "Sidebar Effect",
            items: galleryItems(includesFollow: true),
            selectedID: tileID(for: sidebarSelection),
            footer: "Same as Terminal extends the terminal's effect across the pinned tab sidebar. Set the terminal to None to show an effect only here.",
            onSelect: { select($0, in: .sidebar) }
        )
        .settingContextMenu(Settings.Shaders.sidebarEffectId)
        areaTuning(selection: sidebarSelection, in: .sidebar)
    }

    // MARK: Keyboard

    @ViewBuilder
    private var keyboardPanel: some View {
        Section {
            PreviewSegmentedControl<TerminalTouchKeyboardModel.BackgroundEffectPlacement>(
                title: "Keyboard Effect Area",
                options: [
                    .init(value: .off, symbol: "circle.slash", title: String(localized: "Off", comment: "Keyboard effect area: none")),
                    .init(value: .toolbar, symbol: "menubar.rectangle", title: String(localized: "Toolbar", comment: "Keyboard effect area: toolbar only")),
                    .init(value: .entireKeyboard, symbol: "keyboard", title: String(localized: "Keyboard", comment: "Keyboard effect area: whole keyboard")),
                ],
                selection: keyboardPlacement,
                onSelect: { keyboardPlacement = $0 }
            )
            .settingContextMenu(Settings.Shaders.keyboardBackgroundEffect)
            .themedRow()
        } header: {
            SettingGroupHeader("Show Behind", group: .shaders)
        } footer: {
            Text("The rootshell keyboard and its toolbar can show an effect of their own, independent of the terminal.")
        }

        if keyboardPlacement != .off {
            EffectGallerySection(
                title: "Keyboard Effect",
                items: galleryItems(includesFollow: true),
                selectedID: tileID(for: keyboardEffectID),
                footer: nil,
                onSelect: { select($0, in: .keyboard) }
            )
            .settingContextMenu(Settings.Shaders.keyboardEffectId)
            areaTuning(selection: keyboardEffectID, in: .keyboard)
        }
    }

    // MARK: Window

    @ViewBuilder
    private var windowPanel: some View {
        Section {
            SettingDescribedToggle(
                Settings.Shaders.themeGradientBackdrop,
                isOn: Binding(get: { effectManager.isBackdropEnabled },
                              set: { effectManager.isBackdropEnabled = $0 }),
                title: "Theme Gradient Backdrop",
                description: "Fills the whole window behind tabs and panes with a soft glow in the theme's colors. It shows around Rounded Panes and through transparent terminals, beneath the other effects."
            )
            .themedRow()
            #if targetEnvironment(macCatalyst)
            if effectManager.isBackdropEnabled {
                SettingDescribedToggle(
                    Settings.Transparency.backdropTransparency,
                    isOn: Binding(get: { transparencyManager.backdropTransparencyEnabled },
                                  set: { transparencyManager.backdropTransparencyEnabled = $0 }),
                    title: "Transparent Backdrop",
                    description: "Apply the window opacity to the gradient too, so the desktop shows through it. When off, transparency only reveals the gradient behind the terminal."
                )
                .themedRow()
            }
            #endif
        } header: {
            SettingGroupHeader("Window Backdrop", group: .shaders)
        }

        if effectManager.isBackdropEnabled {
            tuning(for: effectManager.backdropEffect, in: .window)
        }
    }

    // MARK: Tuning

    /// Areas following the terminal share its effect and settings.
    @ViewBuilder
    private func areaTuning(selection: String, in area: BackgroundEffectArea) -> some View {
        if selection == BackgroundEffectSelection.followTerminalID {
            if effectManager.activeEffect != nil {
                Section {
                    Button {
                        self.area = .terminal
                    } label: {
                        Label("Uses the terminal's effect and its settings", systemImage: "link")
                    }
                    .themedRow()
                }
            }
        } else if let effect = effectManager.selectedEffect(id: selection) {
            tuning(for: effect, in: area)
        }
    }

    @ViewBuilder
    private func tuning(for effect: AnyTerminalEffect, in area: BackgroundEffectArea) -> some View {
        if let gradient = effect.asEffect(ThemeGradientEffect.self) {
            ThemeGradientStyleSection(effect: gradient)
        }
        EffectTuningSection(effect: effect, onChangeVideo: { showsVideoLibrary = true })
    }

    // MARK: Gallery

    private static let videoPrefix = "videoBackground_"
    private static let videoTileID = "video"
    private static let galleryOrder = ["aquarium", "jellyfish", "fireflies", "butterflies", "aurora",
                                       "solarGraph", "liveWeather", "themeGradient", "photoBackground"]

    private func tileID(for selection: String) -> String {
        selection.hasPrefix(Self.videoPrefix) ? Self.videoTileID : selection
    }

    private func galleryItems(includesFollow: Bool) -> [EffectGalleryItem] {
        _ = gradientRevision
        var items: [EffectGalleryItem] = []
        if includesFollow {
            items.append(EffectGalleryItem(id: BackgroundEffectSelection.followTerminalID,
                                           kind: EffectPortraitKind(effect: effectManager.activeEffect),
                                           title: String(localized: "Same as Terminal", comment: "Background effect: follow the terminal's effect"),
                                           badge: "link"))
        }
        items.append(EffectGalleryItem(id: "", kind: .none, title: String(localized: "None", comment: "Background effect: no effect")))
        for id in Self.galleryOrder {
            guard let effect = effectManager.effect(withId: id) else { continue }
            items.append(EffectGalleryItem(id: id, kind: EffectPortraitKind(effect: effect), title: effect.displayName))
        }
        items.append(EffectGalleryItem(id: Self.videoTileID, kind: .video,
                                       title: String(localized: "Video", comment: "Background effect: looping video wallpapers")))
        return items
    }

    private func select(_ id: String, in area: BackgroundEffectArea) {
        if id == Self.videoTileID {
            showsVideoLibrary = true
            return
        }
        switch area {
        case .terminal, .window:
            let wasActive = effectManager.activeEffect?.id == id
            effectManager.cancelPendingVideoActivation()
            effectManager.setActiveEffect(id: id.isEmpty ? nil : id)
            if !wasActive { activate(id) }
        case .sidebar:
            sidebarEffectID = id
            if id == BackgroundEffectSelection.followTerminalID { includesSidebar = true }
            activate(id)
        case .keyboard:
            keyboardEffectID = id
            activate(id)
        }
    }

    /// Effects that fetch their location or weather start when chosen.
    private func activate(_ id: String) {
        guard let effect = effectManager.selectedEffect(id: id) else { return }
        if let solar = effect.asEffect(SolarGraphEffect.self) {
            Task { await solar.onActivated() }
        }
        #if !CHINA_BUILD
        effect.asEffect(LiveWeatherEffect.self)?.onActivated()
        #endif
    }
}

// MARK: - Gallery

struct EffectGalleryItem: Identifiable {
    let id: String
    let kind: EffectPortraitKind
    let title: String
    var badge: String? = nil
}

private struct EffectGallerySection: View {
    let title: LocalizedStringKey
    let items: [EffectGalleryItem]
    let selectedID: String
    let footer: LocalizedStringKey?
    let onSelect: (String) -> Void

    @State private var width: CGFloat = 0

    /// As many columns as fit, one fewer when that would leave a tile alone on the last row.
    private var columns: [GridItem] {
        let fit = max(2, Int((width + 12) / (92 + 12)))
        let count = items.count % fit == 1 && fit > 2 ? fit - 1 : fit
        return Array(repeating: GridItem(.flexible(maximum: 160), spacing: 12), count: count)
    }

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { item in
                    EffectTile(kind: item.kind, title: item.title, badgeSymbol: item.badge, isSelected: item.id == selectedID) {
                        onSelect(item.id)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(.vertical, 6)
            .themedRow()
        } header: {
            SettingGroupHeader(title, group: .shaders)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

// MARK: - Tuning

/// The few controls people reach for, and a link to everything else.
private struct EffectTuningSection: View {
    @ObservedObject var effect: AnyTerminalEffect
    let onChangeVideo: () -> Void

    @State private var intensity = 0.3
    @State private var speed = 1.0

    private var isBackdrop: Bool { effect.asEffect(ThemeGradientEffect.self)?.isBackdrop == true }
    private var showsIntensity: Bool { !isBackdrop && effect.id != "photoBackground" }
    private var showsSpeed: Bool { !["solarGraph", "liveWeather", "photoBackground"].contains(effect.id) }

    var body: some View {
        Section {
            if showsIntensity {
                EffectSliderRow(title: "Intensity", value: $intensity, range: 0.05...0.6,
                                label: intensity.formatted(.percent.precision(.fractionLength(0)))) {
                    effect.intensity = intensity
                }
                .themedRow()
            }
            if showsSpeed {
                EffectSliderRow(title: "Speed", value: $speed, range: 0.25...2.0, label: EffectSpeedLabel.text(speed)) {
                    effect.speed = speed
                }
                .themedRow()
            }

            EffectQuickControls(effect: effect, onChangeVideo: onChangeVideo)

            NavigationLink {
                EffectDetailView(effect: effect)
            } label: {
                if let photo = effect.asEffect(PhotoBackgroundEffect.self), !photo.hasPhoto {
                    Text("Choose a Photo…")
                } else {
                    Text("More \(effect.displayName) Settings")
                }
            }
            .themedRow()
        } header: {
            Text(effect.displayName)
        }
        .onAppear(perform: sync)
        .onChange(of: effect.id) { _, _ in sync() }
    }

    private func sync() {
        intensity = effect.intensity
        speed = effect.speed
    }
}

private struct EffectQuickControls: View {
    let effect: AnyTerminalEffect
    let onChangeVideo: () -> Void

    var body: some View {
        if let aquarium = effect.asEffect(AquariumEffect.self) {
            AquariumQuickControls(effect: aquarium)
        } else if let jellyfish = effect.asEffect(JellyfishEffect.self) {
            JellyfishQuickControls(effect: jellyfish)
        } else if let butterflies = effect.asEffect(ButterfliesEffect.self) {
            ButterfliesQuickControls(effect: butterflies)
        } else if let fireflies = effect.asEffect(FirefliesEffect.self) {
            FirefliesQuickControls(effect: fireflies)
        } else if let aurora = effect.asEffect(AuroraEffect.self) {
            AuroraQuickControls(effect: aurora)
        } else if let solar = effect.asEffect(SolarGraphEffect.self) {
            SolarQuickControls(effect: solar)
        } else if let video = effect.asEffect(VideoBackgroundEffect.self) {
            VideoQuickControls(effect: video, onChangeVideo: onChangeVideo)
        } else if let gradient = effect.asEffect(ThemeGradientEffect.self) {
            GradientQuickControls(effect: gradient)
        } else {
            weather
        }
    }

    @ViewBuilder
    private var weather: some View {
        #if !CHINA_BUILD
        if let weather = effect.asEffect(LiveWeatherEffect.self) {
            WeatherQuickControls(effect: weather)
        }
        #endif
    }
}

private struct AquariumQuickControls: View {
    @ObservedObject var effect: AquariumEffect

    var body: some View {
        Stepper(value: Binding(get: { effect.configuration.fishCount }, set: { effect.configuration.fishCount = $0 }), in: 0...64) {
            LabeledContent("Fish", value: effect.configuration.fishCount, format: .number)
        }
        .themedRow()
        Toggle("Bubbles", isOn: Binding(get: { effect.configuration.bubbles }, set: { effect.configuration.bubbles = $0 }))
            .themedRow()
    }
}

private struct JellyfishQuickControls: View {
    @ObservedObject var effect: JellyfishEffect

    var body: some View {
        Picker("Visits", selection: Binding(get: { effect.visitFrequency }, set: { effect.visitFrequency = $0 })) {
            ForEach(JellyfishVisitState.VisitFrequency.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .themedRow()
        VisitNowButton(symbol: "water.waves", arriving: String(localized: "Jellyfish on the way"), action: effect.requestVisit)
            .themedRow()
    }
}

private struct ButterfliesQuickControls: View {
    @ObservedObject var effect: ButterfliesEffect

    var body: some View {
        Picker("Visits", selection: Binding(get: { effect.visitFrequency }, set: { effect.visitFrequency = $0 })) {
            ForEach(ButterflyVisitState.VisitFrequency.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .themedRow()
        VisitNowButton(symbol: "wind", arriving: String(localized: "Butterflies on the way"), action: effect.requestVisit)
            .themedRow()
    }
}

private struct FirefliesQuickControls: View {
    @ObservedObject var effect: FirefliesEffect

    var body: some View {
        Stepper(value: Binding(get: { effect.fireflyCount }, set: { effect.fireflyCount = $0 }), in: 10...100, step: 5) {
            LabeledContent("Fireflies", value: effect.fireflyCount, format: .number)
        }
        .themedRow()
    }
}

private struct AuroraQuickControls: View {
    @ObservedObject var effect: AuroraEffect

    var body: some View {
        Picker("Colors", selection: Binding(get: { effect.colorMode }, set: { effect.colorMode = $0 })) {
            ForEach(AuroraEffect.ColorMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .themedRow()
    }
}

private struct SolarQuickControls: View {
    @ObservedObject var effect: SolarGraphEffect

    var body: some View {
        Toggle("Ocean Surface", isOn: Binding(get: { effect.showOcean }, set: { effect.showOcean = $0 }))
            .themedRow()
        Toggle("Star Field", isOn: Binding(get: { effect.showStars }, set: { effect.showStars = $0 }))
            .themedRow()
    }
}

private struct VideoQuickControls: View {
    @ObservedObject var effect: VideoBackgroundEffect
    let onChangeVideo: () -> Void

    var body: some View {
        Toggle("Match Theme Color", isOn: Binding(get: { effect.themeTintEnabled }, set: { effect.themeTintEnabled = $0 }))
            .themedRow()
        Button("Choose Another Video…", action: onChangeVideo)
            .themedRow()
    }
}

private struct GradientQuickControls: View {
    @ObservedObject var effect: ThemeGradientEffect

    var body: some View {
        Toggle("Drift", isOn: Binding(get: { effect.drift }, set: { effect.drift = $0 }))
            .themedRow()
    }
}

#if !CHINA_BUILD
private struct WeatherQuickControls: View {
    @ObservedObject var effect: LiveWeatherEffect

    var body: some View {
        Toggle("Demo Mode", isOn: Binding(get: { effect.configuration.demo }, set: { effect.configuration.demo = $0 }))
            .themedRow()
    }
}
#endif

/// Calls a visitor in now, then confirms for a moment.
private struct VisitNowButton: View {
    let symbol: String
    let arriving: String
    let action: () -> Void

    @State private var acknowledged = false

    var body: some View {
        Button {
            action()
            withAnimation(.easeIn(duration: 0.15)) { acknowledged = true }
        } label: {
            Label {
                Text(acknowledged ? arriving : String(localized: "Visit Now"))
                    .foregroundStyle(acknowledged ? .secondary : .primary)
            } icon: {
                Image(systemName: acknowledged ? "checkmark.circle.fill" : symbol)
                    .foregroundStyle(acknowledged ? Color.green : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .disabled(acknowledged)
        .task(id: acknowledged) {
            guard acknowledged else { return }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut(duration: 0.3)) { acknowledged = false }
        }
    }
}

/// The video the terminal switches to once it downloads, in its real download state.
private struct PendingVideoSection: View {
    let videoID: String
    var effectManager = EffectManager.shared
    @ObservedObject private var downloadManager = VideoBackgroundDownloadManager.shared
    @ObservedObject private var videoManager = VideoBackgroundManager.shared

    private var video: RemoteVideoBackground? { videoManager.remoteVideo(for: videoID) }
    private var name: String { video?.displayName ?? String(localized: "Video", comment: "Pending video background without a name") }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                status
                Spacer()
                action
                Button("Cancel") { effectManager.cancelPendingVideoActivation() }
                    .buttonStyle(.borderless)
            }
            .themedRow()
        } footer: {
            Text("The terminal switches to the video when it finishes downloading.")
        }
        // After a relaunch the video list may not be loaded yet.
        .task { if video == nil { await videoManager.fetchRemoteIndex() } }
    }

    @ViewBuilder
    private var status: some View {
        switch downloadManager.downloadStates[videoID] ?? .notDownloaded {
        case .downloading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
            Text("Downloading \(name)…", comment: "Video background download in progress")
        case .paused(let progress):
            Label(String(localized: "\(name) paused at \(progress.formatted(.wholePercent))", comment: "Video background download paused"),
                  systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Label(String(localized: "\(name) didn't download", comment: "Video background download failed"),
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .notDownloaded:
            // No download running, e.g. one that failed before a relaunch.
            Label(String(localized: "\(name) isn't downloaded", comment: "Video background download not running"),
                  systemImage: "arrow.down.circle")
        case .completed:
            ProgressView()
            Text("Preparing \(name)…", comment: "Video background download finishing")
        }
    }

    @ViewBuilder
    private var action: some View {
        if let video {
            switch downloadManager.downloadStates[videoID] ?? .notDownloaded {
            case .paused:
                Button("Resume") { downloadManager.resumeDownload(for: videoID, video: video) }
                    .buttonStyle(.borderless)
            case .failed:
                Button("Retry") { downloadManager.startDownload(for: video) }
                    .buttonStyle(.borderless)
            case .notDownloaded:
                Button("Download") { downloadManager.startDownload(for: video) }
                    .buttonStyle(.borderless)
            default:
                EmptyView()
            }
        }
    }
}
