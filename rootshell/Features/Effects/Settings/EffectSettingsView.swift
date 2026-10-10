//
//  EffectSettingsView.swift
//  rootshell
//
//  Settings view for configuring terminal background effects
//

import SwiftUI
import PhotosUI
import CoreLocation
import UniformTypeIdentifiers

struct EffectSettingsView: View {
    /// Open an effect's controls without selecting it for the main terminal.
    var configurationEffect: AnyTerminalEffect? = nil
    var effectManager = EffectManager.shared
    var themeManager = ThemeManager.shared
    var transparencyManager = TransparencyManager.shared
    @ObservedObject private var videoManager = VideoBackgroundManager.shared
    @ObservedObject private var downloadManager = VideoBackgroundDownloadManager.shared
    @ObservedObject private var localVideoManager = LocalVideoBackgroundManager.shared

    // Local state for sliders - only commit on release
    @State private var localIntensity: Double = 0.3
    @State private var localSpeed: Double = 1.0
    @State private var isDraggingIntensity = false
    @State private var isDraggingSpeed = false

    // SolarGraph-specific state
    @State private var solarDemoMode: Bool = false
    @State private var solarDemoSpeed: Double = 60.0
    @State private var solarUseLocation: Bool = true
    @State private var selectedTimezoneId: String = TimeZone.current.identifier

    // Photo picker state
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isLoadingPhoto: Bool = false

    // Video section expansion
    @State private var showVideoList = false

    // Local video import state
    @State private var showVideoFileImporter = false
    @State private var videoImportError: String?
    @State private var isImportingVideo = false
    @State private var selectedPhotosVideoItem: PhotosPickerItem?

    // Keep the presenter outside recycled List sections. A section can leave
    // the visible list during the first sheet layout, dismissing its sheet.
    @State private var showcaseEffect: AnyTerminalEffect?

    // Built-in effect IDs (non-video)
    private let builtInEffectIds = ["aquarium", "aurora", "themeGradient", "solarGraph", "fireflies", "butterflies", "jellyfish", "photoBackground"]

    /// Built-in effects only (not video backgrounds)
    private var builtInEffects: [AnyTerminalEffect] {
        effectManager.availableEffects.filter { builtInEffectIds.contains($0.id) }
    }

    private var effectBeingConfigured: AnyTerminalEffect? {
        configurationEffect ?? effectManager.activeEffect
    }

    /// Whether to show the video backgrounds list section
    private var isVideoBackgroundMode: Bool {
        showVideoList
        || effectManager.activeEffect?.id.hasPrefix("videoBackground_") == true
        || effectManager.pendingVideoActivation != nil
    }

    var body: some View {
        List {
            if configurationEffect == nil {
            // Built-in Effect Selection
            Section {
                // None option
                Button(action: {
                    effectManager.setActiveEffect(id: nil)
                    effectManager.cancelPendingVideoActivation()
                    showVideoList = false
                }) {
                    HStack {
                        Image(systemName: "circle.slash")
                            .foregroundColor(.secondary)
                            .frame(width: 24)
                        Text("None")
                            .foregroundColor(.primary)
                        Spacer()
                        if effectManager.activeEffect == nil && effectManager.pendingVideoActivation == nil && !showVideoList {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()

                // Built-in effects only
                ForEach(builtInEffects) { effect in
                    Button(action: {
                        let wasActive = effectManager.activeEffect?.id == effect.id
                        effectManager.setActiveEffect(id: effect.id)
                        effectManager.cancelPendingVideoActivation()
                        showVideoList = false

                        // Trigger activation callback for newly selected effects
                        if !wasActive, effect.id == "solarGraph",
                           let solarEffect = effect.asEffect(SolarGraphEffect.self) {
                            Task { await solarEffect.onActivated() }
                        }
                    }) {
                        HStack {
                            Image(systemName: effect.previewIcon)
                                .foregroundColor(.blue)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(effect.displayName)
                                    .foregroundColor(.primary)
                                Text(effect.effectDescription)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if effectManager.activeEffect?.id == effect.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }

                // Video Background option
                Button(action: {
                    showVideoList = true
                    // Clear any non-video active effect so only video shows checkmark
                    if effectManager.activeEffect?.id.hasPrefix("videoBackground_") != true {
                        effectManager.setActiveEffect(id: nil)
                    }
                }) {
                    HStack {
                        Image(systemName: "film")
                            .foregroundColor(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Video Background")
                                .foregroundColor(.primary)
                            Text("Looping video wallpapers")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if isVideoBackgroundMode {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()
            } header: {
                SettingGroupHeader("Terminal Effect", group: .shaders)
            }

            Section {
                #if !os(visionOS)
                if UIDevice.current.userInterfaceIdiom != .phone {
                    SidebarBackgroundEffectPicker()
                        .themedRow()
                }
                #endif
                #if !os(visionOS) && !targetEnvironment(macCatalyst)
                KeyboardBackgroundEffectPicker()
                    .themedRow()
                #endif
            } header: {
                SettingGroupHeader("Layout", group: .shaders)
            }

            Section {
                SettingDescribedToggle(
                    Settings.Shaders.themeGradientBackdrop,
                    isOn: Binding(get: { effectManager.isBackdropEnabled },
                                  set: { effectManager.isBackdropEnabled = $0 }),
                    title: "Theme Gradient",
                    description: "Fills the whole window behind tabs and panes with a soft glow in the theme's colors. It shows around Rounded Panes and through transparent terminals, beneath the effects above."
                )
                .themedRow()
                if effectManager.isBackdropEnabled {
                    #if targetEnvironment(macCatalyst)
                    SettingDescribedToggle(
                        Settings.Transparency.backdropTransparency,
                        isOn: Binding(get: { transparencyManager.backdropTransparencyEnabled },
                                      set: { transparencyManager.backdropTransparencyEnabled = $0 }),
                        title: "Transparent Backdrop",
                        description: "Apply the window opacity to the gradient too, so the desktop shows through it. When off, transparency only reveals the gradient behind the terminal."
                    )
                    .themedRow()
                    #endif
                    NavigationLink {
                        EffectSettingsView(configurationEffect: effectManager.backdropEffect)
                    } label: {
                        Text("Configure Backdrop")
                    }
                    .themedRow()
                }
            } header: {
                SettingGroupHeader("Backdrop", group: .shaders)
            }

            // My Videos Section (user-imported local videos)
            if isVideoBackgroundMode {
            Section {
                Button {
                    showVideoFileImporter = true
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                            .foregroundColor(.blue)
                            .frame(width: 24)
                        Text(localVideoManager.localVideos.isEmpty ? "Choose Local Video…" : "Add Another Video…")
                            .foregroundColor(.primary)
                        if isImportingVideo {
                            Spacer()
                            ProgressView()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isImportingVideo)
                .themedRow()

                PhotosPicker(
                    selection: $selectedPhotosVideoItem,
                    matching: .videos,
                    preferredItemEncoding: .current
                ) {
                    HStack {
                        Image(systemName: "photo.on.rectangle.angled")
                            .foregroundColor(.blue)
                            .frame(width: 24)
                        Text("Choose from Photos…")
                            .foregroundColor(.primary)
                        if isImportingVideo {
                            Spacer()
                            ProgressView()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(isImportingVideo)
                .themedRow()
                .onChange(of: selectedPhotosVideoItem) { _, newItem in
                    guard let newItem else { return }
                    handlePhotosVideoImport(item: newItem)
                }

                ForEach(localVideoManager.localVideos) { video in
                    LocalVideoBackgroundRow(
                        video: video,
                        isActive: effectManager.activeEffect?.id == "videoBackground_\(video.id)",
                        onSelect: {
                            effectManager.requestVideoEffectActivation(video.id)
                        }
                    )
                    .themedRow()
                }

                if let error = videoImportError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .themedRow()
                }
            } header: {
                Text("My Videos")
            } footer: {
                Text("Import an MP4 (H.264 or HEVC) or MOV file. Looping works best when the first and last frames match. Audio tracks are ignored.")
            }
            .fileImporter(
                isPresented: $showVideoFileImporter,
                allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: false
            ) { result in
                handleVideoImport(result: result)
            }
            }

            // Video Backgrounds Section (only shown when video mode selected)
            if isVideoBackgroundMode {
            Section("Video Backgrounds") {
                if videoManager.isLoadingIndex && videoManager.remoteVideos.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading available videos...")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                } else if let error = videoManager.indexError, videoManager.remoteVideos.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("Failed to load videos")
                                .foregroundColor(.primary)
                        }
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            Task { await videoManager.fetchRemoteIndex() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    .themedRow()
                } else if videoManager.remoteVideos.isEmpty {
                    Text("No video backgrounds available")
                        .foregroundColor(.secondary)
                        .themedRow()
                } else {
                    ForEach(videoManager.remoteVideos) { video in
                        VideoBackgroundRow(
                            video: video,
                            isActive: effectManager.activeEffect?.id == "videoBackground_\(video.id)",
                            isPending: effectManager.pendingVideoActivation == video.id,
                            onSelect: {
                                effectManager.requestVideoEffectActivation(video.id)
                            }
                        )
                        .themedRow()
                    }
                }
            }
            }
            } // Terminal effect selection and layout

            // Keyboard and sidebar controls do not activate the terminal effect.
            if let activeEffect = effectBeingConfigured {
                Section("Settings") {
                    // Intensity slider; the backdrop is always opaque
                    if activeEffect.asEffect(ThemeGradientEffect.self)?.isBackdrop != true {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Intensity")
                                Spacer()
                                Text(localIntensity, format: .wholePercent)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 50, alignment: .trailing)
                            }
                            Slider(value: $localIntensity, in: 0.05...0.6) { editing in
                                isDraggingIntensity = editing
                                if !editing {
                                    // Commit value when drag ends
                                    activeEffect.intensity = localIntensity
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .themedRow()
                    }

                    // Speed slider (for non-SolarGraph effects)
                    if activeEffect.id != "solarGraph" {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Speed")
                                Spacer()
                                Text(speedLabel(localSpeed))
                                    .foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .trailing)
                            }
                            Slider(value: $localSpeed, in: 0.25...2.0) { editing in
                                isDraggingSpeed = editing
                                if !editing {
                                    // Commit value when drag ends
                                    activeEffect.speed = localSpeed
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .themedRow()
                    }

                    // Reset button
                    Button("Reset to Defaults") {
                        activeEffect.resetToDefaults()
                        localIntensity = activeEffect.intensity
                        localSpeed = activeEffect.speed
                        if activeEffect.id == "solarGraph" {
                            solarDemoMode = false
                            solarDemoSpeed = 60.0
                        }
                    }
                    .themedRow()
                }

                // SolarGraph-specific settings
                if activeEffect.id == "solarGraph", let solarEffect = activeEffect.asEffect(SolarGraphEffect.self) {
                    // Transparency warning
                    if transparencyManager.effectiveBackgroundOpacity < 1.0 {
                        Section {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Transparency Enabled")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Window transparency can cause visual artifacts with the solar background. Set transparency to \(1.0.formatted(.wholePercent)) for optimal quality.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .themedRow()

                            Button("Set Opacity to \(1.0.formatted(.wholePercent))") {
                                transparencyManager.backgroundOpacity = 1.0
                            }
                            .themedRow()
                        }
                    }

                    Section("Time Mode") {
                        Toggle("Demo Mode", isOn: $solarDemoMode)
                            .onChange(of: solarDemoMode) { _, newValue in
                                if newValue {
                                    // Reset demo start time so all views sync
                                    solarEffect.demoStartTime = Date.now
                                    activeEffect.speed = solarDemoSpeed
                                } else {
                                    activeEffect.speed = 1.0
                                }
                            }
                            .themedRow()

                        if solarDemoMode {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Cycle Speed")
                                    Spacer()
                                    Text(solarDemoSpeedLabel(solarDemoSpeed))
                                        .foregroundColor(.secondary)
                                        .frame(width: 100, alignment: .trailing)
                                }
                                Slider(value: $solarDemoSpeed, in: 30...1440, step: 30) { editing in
                                    if !editing {
                                        activeEffect.speed = solarDemoSpeed
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .themedRow()
                        }
                    }

                    Section("Location") {
                        Toggle("Use Device Location", isOn: $solarUseLocation)
                            .onChange(of: solarUseLocation) { _, newValue in
                                solarEffect.useLocation = newValue
                                if newValue {
                                    Task {
                                        await solarEffect.refreshLocation()
                                        // Update local state if permission was denied
                                        solarUseLocation = solarEffect.useLocation
                                    }
                                }
                            }
                            .themedRow()

                        if solarUseLocation {
                            // Location enabled - show status
                            if let locality = solarEffect.locationService.locality {
                                HStack {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundColor(.green)
                                    Text(locality)
                                        .foregroundColor(.secondary)
                                }
                                .font(.caption)
                                .themedRow()
                            } else if solarEffect.locationService.isRequestingLocation {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Getting location...")
                                        .foregroundColor(.secondary)
                                }
                                .font(.caption)
                                .themedRow()
                            } else {
                                Text("Accurate sunrise & sunset times")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .themedRow()
                            }
                        } else {
                            // Location disabled - show timezone picker
                            Picker("Timezone", selection: $selectedTimezoneId) {
                                ForEach(commonTimezones, id: \.self) { tz in
                                    Text(formatTimezone(tz)).tag(tz)
                                }
                            }
                            .onChange(of: selectedTimezoneId) { _, newValue in
                                if let tz = TimeZone(identifier: newValue) {
                                    solarEffect.manualTimezone = tz
                                }
                            }
                            .themedRow()

                            Text("Using timezone estimate for sunrise & sunset")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .themedRow()
                        }
                    }

                    Section("Display") {
                        Toggle(isOn: Binding(
                            get: { solarEffect.showArcTrack },
                            set: { solarEffect.showArcTrack = $0 }
                        )) {
                            HStack {
                                Image(systemName: "sun.horizon.circle")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Solar Arc")
                                    Text("Show sun path indicator")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .themedRow()

                        Toggle(isOn: Binding(
                            get: { solarEffect.showSunHotspot },
                            set: { solarEffect.showSunHotspot = $0 }
                        )) {
                            HStack {
                                Image(systemName: "sun.max.circle")
                                    .foregroundColor(.yellow)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sun Hotspot")
                                    Text("3D depth highlight on sun disc")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .themedRow()
                    }

                    Section("Night Sky") {
                        Toggle(isOn: Binding(
                            get: { solarEffect.showStars },
                            set: { solarEffect.showStars = $0 }
                        )) {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Star Field")
                                    Text("Real astronomical positions")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .themedRow()

                        if solarEffect.showStars {
                            Toggle(isOn: Binding(
                                get: { solarEffect.starTwinkle },
                                set: { solarEffect.starTwinkle = $0 }
                            )) {
                                HStack {
                                    Image(systemName: "star.fill")
                                        .foregroundColor(.yellow)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Twinkling")
                                        Text("Atmospheric shimmer effect")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .themedRow()

                            HStack {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                Text("Includes Milky Way, nebulae, and diffraction spikes for brightest stars")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .themedRow()
                        }
                    }

                    Section("Ocean") {
                        OceanSettingsView(effect: solarEffect)
                            .themedRow()
                    }
                }

                // Photo background settings
                if activeEffect.id == "photoBackground",
                   let photoEffect = activeEffect.asEffect(PhotoBackgroundEffect.self) {
                    PhotoBackgroundSettingsSection(
                        effect: photoEffect,
                        selectedPhotoItem: $selectedPhotoItem,
                        isLoadingPhoto: $isLoadingPhoto
                    )
                }

                // Video background theme tint
                if activeEffect.id.hasPrefix("videoBackground_"),
                   let videoEffect = activeEffect.asEffect(VideoBackgroundEffect.self) {
                    VideoThemeTintSection(effect: videoEffect)
                }

                // Fireflies-specific settings
                if activeEffect.id == "fireflies",
                   let firefliesEffect = activeEffect.asEffect(FirefliesEffect.self) {
                    FirefliesSettingsSection(effect: firefliesEffect)
                }

                // Butterflies-specific settings
                if activeEffect.id == "butterflies",
                   let butterfliesEffect = activeEffect.asEffect(ButterfliesEffect.self) {
                    ButterfliesSettingsSection(effect: butterfliesEffect)
                }

                // Jellyfish-specific settings
                if activeEffect.id == "jellyfish",
                   let jellyfishEffect = activeEffect.asEffect(JellyfishEffect.self) {
                    JellyfishSettingsSection(effect: jellyfishEffect) {
                        showcaseEffect = activeEffect
                    }
                }

                // Aquarium-specific settings
                if activeEffect.id == "aquarium",
                   let aquariumEffect = activeEffect.asEffect(AquariumEffect.self) {
                    AquariumSettingsSection(effect: aquariumEffect, onShowcase: {
                        showcaseEffect = activeEffect
                    }) {
                        aquariumEffect.resetToDefaults()
                        localIntensity = aquariumEffect.intensity
                        localSpeed = aquariumEffect.speed
                    }
                }

                // Aurora-specific settings
                if activeEffect.id == "aurora",
                   let auroraEffect = activeEffect.asEffect(AuroraEffect.self) {
                    AuroraSettingsSection(effect: auroraEffect)
                }

                // Both the area effect and the window backdrop
                if let gradientEffect = activeEffect.asEffect(ThemeGradientEffect.self) {
                    ThemeGradientSettingsSection(effect: gradientEffect)
                }

                // Live Preview
                Section("Preview") {
                    ZStack {
                        // Background
                        previewBackgroundColor
                            .ignoresSafeArea()

                        // Effect layer. Butterflies visit too rarely for a
                        // passive preview, so give it a preview-mode view
                        // that spawns immediately and often.
                        if activeEffect.id == "butterflies",
                           let butterfliesEffect = activeEffect.asEffect(ButterfliesEffect.self) {
                            ButterfliesView(effect: butterfliesEffect, previewMode: true)
                        } else if activeEffect.id == "jellyfish",
                                  let jellyfishEffect = activeEffect.asEffect(JellyfishEffect.self) {
                            // Jellyfish visits are rare and slow, so the
                            // preview also uses a fast-spawning view
                            JellyfishView(effect: jellyfishEffect, previewMode: true)
                                .blendMode(jellyfishEffect.isLightBackground ? .multiply : .plusLighter)
                        } else if activeEffect.id == "aurora" || activeEffect.id == "aquarium"
                                    || activeEffect.id == "themeGradient" {
                            // These shaders' light-theme output is white-based
                            // and needs the same blend mode MainView applies.
                            activeEffect.createEffectView()
                                .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
                        } else {
                            activeEffect.createEffectView()
                        }

                        // Sample terminal text
                        VStack(alignment: .leading, spacing: 4) {
                            Text("user@host ~ $")
                            Text("ls -la")
                            Text("total 42")
                            Text("drwxr-xr-x  5 user staff  160 Nov 24 12:00 .")
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(previewForegroundColor)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .themedRow()
                }
            }
        }
        .themedList()
        .navigationTitle(configurationEffect?.displayName ?? String(localized: "Background Effect"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $showcaseEffect) { effect in
            EffectShowcaseView(effect: effect)
        }
        .onAppear {
            syncLocalState()
            // Pre-fetch video index if already in video mode
            if configurationEffect == nil && isVideoBackgroundMode {
                Task { await videoManager.fetchRemoteIndex() }
            }
        }
        .onChange(of: effectBeingConfigured?.id) { _, _ in
            syncLocalState()
        }
        .onChange(of: showVideoList) { _, newValue in
            if configurationEffect == nil && newValue {
                Task { await videoManager.fetchRemoteIndex() }
            }
        }
    }

    /// Sync local slider state from the active effect
    private func syncLocalState() {
        if let effect = effectBeingConfigured {
            localIntensity = effect.intensity
            localSpeed = effect.speed

            // Show video list if a video background is active
            if effect.id.hasPrefix("videoBackground_") {
                showVideoList = true
            }

            // Sync SolarGraph-specific state
            if effect.id == "solarGraph",
               let solarEffect = effect.asEffect(SolarGraphEffect.self) {
                solarDemoMode = effect.speed > 1.0
                if solarDemoMode {
                    solarDemoSpeed = effect.speed
                }
                solarUseLocation = solarEffect.useLocation
                selectedTimezoneId = solarEffect.manualTimezone.identifier
            }
        }
    }

    // MARK: - Helpers

    private func speedLabel(_ speed: Double) -> String {
        switch speed {
        case 0.25: return "Very Slow"
        case 0.5: return "Slow"
        case 0.75: return "Slower"
        case 1.0: return "Normal"
        case 1.25: return "Faster"
        case 1.5: return "Fast"
        case 1.75: return "Faster"
        case 2.0: return "Very Fast"
        default: return String(format: "%.1fx", speed)
        }
    }

    private func solarDemoSpeedLabel(_ speed: Double) -> String {
        // Speed represents how many real seconds = 1 simulated day second
        // So speed of 60 means 60x faster = 24 min cycle
        // speed of 1440 means 1440x = 1 min cycle
        let cycleMinutes = 24 * 60 / speed
        if cycleMinutes >= 60 {
            let hours = Int(cycleMinutes / 60)
            let mins = Int(cycleMinutes.truncatingRemainder(dividingBy: 60))
            if mins == 0 {
                return "\(hours)h cycle"
            }
            return String(localized: "\(hours)h \(mins)m cycle", comment: "Effect schedule duration")
        } else if cycleMinutes >= 1 {
            return "\(Int(cycleMinutes))m cycle"
        } else {
            return "\(Int(cycleMinutes * 60))s cycle"
        }
    }

    private var previewBackgroundColor: Color {
        if let hex = themeManager.currentThemeInfo?.colors.background,
           let color = Color(hex: hex) {
            return color
        }
        return Color(uiColor: .systemBackground)
    }

    private var previewForegroundColor: Color {
        if let hex = themeManager.currentThemeInfo?.colors.foreground,
           let color = Color(hex: hex) {
            return color
        }
        return .primary
    }

    // MARK: - Timezone Helpers

    /// Common timezones organized by region for picker
    private var commonTimezones: [String] {
        // Return a curated list of common timezones
        return [
            // Americas
            "America/New_York",
            "America/Chicago",
            "America/Denver",
            "America/Los_Angeles",
            "America/Anchorage",
            "Pacific/Honolulu",
            "America/Toronto",
            "America/Vancouver",
            "America/Mexico_City",
            "America/Sao_Paulo",
            "America/Buenos_Aires",
            // Europe
            "Europe/London",
            "Europe/Paris",
            "Europe/Berlin",
            "Europe/Rome",
            "Europe/Madrid",
            "Europe/Amsterdam",
            "Europe/Stockholm",
            "Europe/Moscow",
            // Asia
            "Asia/Dubai",
            "Asia/Kolkata",
            "Asia/Bangkok",
            "Asia/Singapore",
            "Asia/Hong_Kong",
            "Asia/Shanghai",
            "Asia/Tokyo",
            "Asia/Seoul",
            // Oceania
            "Australia/Sydney",
            "Australia/Melbourne",
            "Australia/Perth",
            "Pacific/Auckland",
            // Africa
            "Africa/Cairo",
            "Africa/Johannesburg",
            "Africa/Lagos"
        ]
    }

    private func formatTimezone(_ identifier: String) -> String {
        guard let tz = TimeZone(identifier: identifier) else {
            return identifier
        }

        // Get city name from identifier (e.g., "America/New_York" -> "New York")
        let city = identifier.components(separatedBy: "/").last?
            .replacingOccurrences(of: "_", with: " ") ?? identifier

        // Get UTC offset
        let offset = tz.secondsFromGMT()
        let hours = offset / 3600
        let sign = hours >= 0 ? "+" : ""

        return "\(city) (UTC\(sign)\(hours))"
    }

    // MARK: - Local Video Import

    private func handleVideoImport(result: Result<[URL], Error>) {
        videoImportError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImportingVideo = true
            Task {
                defer { isImportingVideo = false }
                do {
                    _ = try await localVideoManager.importVideo(from: url)
                } catch {
                    videoImportError = error.localizedDescription
                }
            }
        case .failure(let error):
            videoImportError = error.localizedDescription
        }
    }

    private func handlePhotosVideoImport(item: PhotosPickerItem) {
        videoImportError = nil
        isImportingVideo = true
        Task {
            defer {
                isImportingVideo = false
                selectedPhotosVideoItem = nil
            }
            do {
                guard let transferable = try await item.loadTransferable(type: PhotosVideoTransferable.self) else {
                    videoImportError = "Could not load selected video."
                    return
                }
                defer { try? FileManager.default.removeItem(at: transferable.url) }
                _ = try await localVideoManager.importVideo(from: transferable.url)
            } catch {
                videoImportError = error.localizedDescription
            }
        }
    }
}

// MARK: - Photo Background Settings

private struct PhotoBackgroundSettingsSection: View {
    @ObservedObject var effect: PhotoBackgroundEffect
    @Binding var selectedPhotoItem: PhotosPickerItem?
    @Binding var isLoadingPhoto: Bool

    @State private var localTintAmount: Double = 0.6
    @State private var isDraggingTintAmount: Bool = false
    @State private var photoImportError: String?

    var body: some View {
        Section {
            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .images
            ) {
                HStack {
                    Image(systemName: "photo.badge.plus")
                        .foregroundColor(.blue)
                        .frame(width: 24)
                    Text(effect.photos.isEmpty ? "Choose Photo" : "Add Another Photo")
                    if isLoadingPhoto {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isLoadingPhoto)
            .themedRow()
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                photoImportError = nil
                isLoadingPhoto = true
                Task {
                    defer {
                        isLoadingPhoto = false
                        selectedPhotoItem = nil
                    }
                    do {
                        guard let data = try await newItem.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else {
                            photoImportError = "Could not load the selected photo."
                            return
                        }
                        try effect.savePhoto(image)
                    } catch {
                        photoImportError = error.localizedDescription
                    }
                }
            }

            ForEach(effect.photos) { photo in
                PhotoBackgroundRow(
                    photo: photo,
                    effect: effect,
                    isSelected: effect.selectedPhotoID == photo.id,
                    onSelect: { effect.selectPhoto(id: photo.id) },
                    onDelete: {
                        do {
                            try effect.removePhoto(id: photo.id)
                            photoImportError = nil
                        } catch {
                            photoImportError = error.localizedDescription
                        }
                    }
                )
                .themedRow()
            }

            if let photoImportError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(photoImportError)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .themedRow()
            }
        } header: {
            Text("My Photos")
        } footer: {
            if !effect.photos.isEmpty {
                Text("Photos are stored on this device. Tap a photo to use it as the terminal background.")
            }
        }

        if effect.hasPhoto {
            Section("Opacity") {
                ForEach(PhotoOpacityPreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                    Button {
                        effect.opacityPreset = preset
                    } label: {
                        HStack {
                            Text(preset.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(preset.intensity, format: .wholePercent)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                            if effect.opacityPreset == preset {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Custom")
                            .foregroundColor(effect.opacityPreset == .custom ? .primary : .secondary)
                        Spacer()
                        Text(effect.intensity, format: .wholePercent)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                    Slider(value: Binding(
                        get: { effect.intensity },
                        set: {
                            effect.opacityPreset = .custom
                            effect.intensity = $0
                        }
                    ), in: 0.05...0.9)
                }
                .padding(.vertical, 4)
                .themedRow()
            }

            Section("Filter") {
                Picker("Image Filter", selection: Binding(
                    get: { effect.imageFilter },
                    set: { effect.imageFilter = $0 }
                )) {
                    ForEach(PhotoImageFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .themedRow()
            }

            Section {
                Toggle(isOn: Binding(
                    get: { effect.themeTintEnabled },
                    set: { effect.themeTintEnabled = $0 }
                )) {
                    HStack {
                        Image(systemName: "paintpalette.fill")
                            .foregroundColor(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Match Theme Color")
                            Text("Recolor photo toward theme palette")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .themedRow()

                if effect.themeTintEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Tint Strength")
                            Spacer()
                            Text(localTintAmount, format: .wholePercent)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                        Slider(value: $localTintAmount, in: 0.0...1.0) { editing in
                            isDraggingTintAmount = editing
                            if !editing {
                                effect.themeTintAmount = localTintAmount
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .onAppear {
                        if !isDraggingTintAmount {
                            localTintAmount = effect.themeTintAmount
                        }
                    }
                    .themedRow()
                }
            } header: {
                Text("Theme Tint")
            } footer: {
                Text("Smoothly remaps the photo's colors toward the current theme's palette using a Gaussian-weighted color cube.")
            }

            Section("Animation") {
                Toggle(isOn: Binding(
                    get: { effect.kenBurnsEnabled },
                    set: { effect.kenBurnsEnabled = $0 }
                )) {
                    HStack {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ken Burns")
                            Text("Slow cinematic pan & zoom")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .themedRow()

                if effect.kenBurnsEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text(kenBurnsSpeedLabel(effect.speed))
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        Slider(value: Binding(
                            get: { effect.speed },
                            set: { effect.speed = $0 }
                        ), in: 0.25...2.0)
                    }
                    .padding(.vertical, 4)
                    .themedRow()
                }
            }
        }
    }

    private func kenBurnsSpeedLabel(_ speed: Double) -> String {
        switch speed {
        case 0.0..<0.5: return "Very Slow"
        case 0.5..<0.8: return "Slow"
        case 0.8..<1.2: return "Normal"
        case 1.2..<1.6: return "Fast"
        default: return "Very Fast"
        }
    }
}

private struct PhotoBackgroundRow: View {
    let photo: PhotoBackground
    let effect: PhotoBackgroundEffect
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PhotoBackgroundThumbnailView(photo: photo, effect: effect)
            .frame(width: 60, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(isSelected ? "Current Photo" : "Background Photo")
                    .foregroundColor(.primary)
                Text(photo.importedAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.blue)
            }

            Menu {
                if !isSelected {
                    Button {
                        onSelect()
                    } label: {
                        Label("Use This Photo", systemImage: "checkmark.circle")
                    }
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct PhotoBackgroundThumbnailView: View {
    let photo: PhotoBackground
    let effect: PhotoBackgroundEffect

    @State private var thumbnailData: Data?

    var body: some View {
        Group {
            if let thumbnailData, let image = UIImage(data: thumbnailData) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .task(id: photo.id) {
            thumbnailData = await effect.thumbnailData(for: photo)
        }
    }
}

// MARK: - Video Theme Tint Section

private struct VideoThemeTintSection: View {
    @ObservedObject var effect: VideoBackgroundEffect

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { effect.themeTintEnabled },
                set: { effect.themeTintEnabled = $0 }
            )) {
                HStack {
                    Image(systemName: "paintpalette.fill")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Match Theme Color")
                        Text("Recolor video toward theme palette")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .themedRow()

            if effect.themeTintEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tint Strength")
                        Spacer()
                        Text(effect.themeTintAmount, format: .wholePercent)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                    Slider(value: Binding(
                        get: { effect.themeTintAmount },
                        set: { effect.themeTintAmount = $0 }
                    ), in: 0.0...1.0)
                }
                .padding(.vertical, 4)
                .themedRow()
            }
        } header: {
            Text("Theme Tint")
        } footer: {
            Text("Smoothly remaps each video frame toward the current theme's palette. Applied in real-time on the GPU.")
        }
    }
}

// MARK: - Fireflies Settings Section

/// Separate view that properly observes FirefliesEffect for reactive updates.
/// Without `@ObservedObject`, mutations to `colorMode`, `fireflyCount`, etc. wouldn't
/// invalidate the parent body, leaving the picker label and slider value labels stale.
private struct FirefliesSettingsSection: View {
    @ObservedObject var effect: FirefliesEffect

    var body: some View {
        Section("Particles") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Firefly Count")
                    Spacer()
                    Text("\(effect.fireflyCount)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Slider(value: Binding(
                    get: { Double(effect.fireflyCount) },
                    set: { effect.fireflyCount = Int($0) }
                ), in: 10...100, step: 5)
            }
            .padding(.vertical, 4)
            .themedRow()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Glow Size")
                    Spacer()
                    Text(glowSizeLabel(effect.glowSize))
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                Slider(value: Binding(
                    get: { effect.glowSize },
                    set: { effect.glowSize = $0 }
                ), in: 0.5...2.0)
            }
            .padding(.vertical, 4)
            .themedRow()
        }

        Section("Color Mode") {
            Picker("Style", selection: Binding(
                get: { effect.colorMode },
                set: { effect.colorMode = $0 }
            )) {
                ForEach(FirefliesEffect.ColorMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .themedRow()

            if effect.colorMode == .themeAdaptive {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Warm on dark themes, cool on light themes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        }
    }

    private func glowSizeLabel(_ size: Double) -> String {
        switch size {
        case 0.0..<0.7: return "Small"
        case 0.7..<1.2: return "Normal"
        case 1.2..<1.6: return "Large"
        default: return "Huge"
        }
    }
}

// MARK: - Butterflies Settings Section

/// Separate view that properly observes ButterfliesEffect for reactive updates
private struct ButterfliesSettingsSection: View {
    @ObservedObject var effect: ButterfliesEffect

    /// Transient confirmation after tapping Visit Now
    @State private var visitAcknowledged = false

    var body: some View {
        Section("Visits") {
            Picker("Frequency", selection: Binding(
                get: { effect.visitFrequency },
                set: { effect.visitFrequency = $0 }
            )) {
                ForEach(ButterflyVisitState.VisitFrequency.allCases, id: \.self) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }
            .themedRow()

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text(effect.visitFrequency.intervalDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .themedRow()

            Toggle(isOn: Binding(
                get: { effect.moreButterflies },
                set: { effect.moreButterflies = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("More Butterflies")
                    Text("Larger groups per visit")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()

            Button {
                effect.requestVisit()
                withAnimation(.easeIn(duration: 0.15)) {
                    visitAcknowledged = true
                }
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation(.easeOut(duration: 0.3)) {
                        visitAcknowledged = false
                    }
                }
            } label: {
                HStack {
                    Image(systemName: visitAcknowledged ? "checkmark.circle.fill" : "wind")
                        .foregroundColor(visitAcknowledged ? .green : .blue)
                        .contentTransition(.symbolEffect(.replace))
                    Text(visitAcknowledged ? "Butterflies on the way" : "Visit Now")
                        .foregroundColor(visitAcknowledged ? .secondary : .primary)
                }
            }
            .disabled(visitAcknowledged)
            .themedRow()
        }

        Section("Flight") {
            Toggle(isOn: Binding(
                get: { effect.flutterEnabled },
                set: { effect.flutterEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wing Flutter")
                    Text("Rapid wing beats in flight. Turn off for calm, less distracting gliding")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()

            Toggle(isOn: Binding(
                get: { effect.perchingEnabled },
                set: { effect.perchingEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Perching")
                    Text("Butterflies sometimes pause to rest")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()

            Toggle(isOn: Binding(
                get: { effect.textAvoidanceEnabled },
                set: { effect.textAvoidanceEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text Avoidance")
                    Text("Butterflies steer around on-screen text and the cursor")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()
        }

        Section("Color Mode") {
            Picker("Style", selection: Binding(
                get: { effect.colorMode },
                set: { effect.colorMode = $0 }
            )) {
                ForEach(ButterfliesEffect.ColorMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .themedRow()

            if effect.colorMode == .themeAdaptive {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Luminous blue on dark themes, warm orange on light themes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            } else if effect.colorMode == .glasswing {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Translucent wings with amber borders — the terminal shows through")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        }
    }
}

// MARK: - Jellyfish Settings Section

/// Separate view that properly observes JellyfishEffect for reactive updates
private struct JellyfishSettingsSection: View {
    @ObservedObject var effect: JellyfishEffect
    let onShowcase: () -> Void
    @State private var bloomDraft = 0.55
    @State private var editingBloom = false

    /// Transient confirmation after tapping Visit Now
    @State private var visitAcknowledged = false

    var body: some View {
        Section {
            Picker("Rendering", selection: Binding(
                get: { effect.renderingStyle },
                set: { effect.renderingStyle = $0 }
            )) {
                ForEach(JellyfishEffect.RenderingStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .themedRow()
        } footer: {
            Text("Original uses simpler graphics for lower GPU usage. Enhanced adds translucent detail and richer glow.")
        }

        Section("Visits") {
            Picker("Frequency", selection: Binding(
                get: { effect.visitFrequency },
                set: { effect.visitFrequency = $0 }
            )) {
                ForEach(JellyfishVisitState.VisitFrequency.allCases, id: \.self) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }
            .themedRow()

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text(effect.visitFrequency.intervalDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .themedRow()

            Toggle(isOn: Binding(
                get: { effect.moreJellyfish },
                set: { effect.moreJellyfish = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("More Jellyfish")
                    Text("Larger blooms per visit")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()

            Button {
                effect.requestVisit()
                withAnimation(.easeIn(duration: 0.15)) {
                    visitAcknowledged = true
                }
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation(.easeOut(duration: 0.3)) {
                        visitAcknowledged = false
                    }
                }
            } label: {
                HStack {
                    Image(systemName: visitAcknowledged ? "checkmark.circle.fill" : "water.waves")
                        .foregroundColor(visitAcknowledged ? .green : .blue)
                        .contentTransition(.symbolEffect(.replace))
                    Text(visitAcknowledged ? "Jellyfish on the way" : "Visit Now")
                        .foregroundColor(visitAcknowledged ? .secondary : .primary)
                }
            }
            .disabled(visitAcknowledged)
            .themedRow()
        }

        Section("Drift") {
            Toggle(isOn: Binding(
                get: { effect.textAvoidanceEnabled },
                set: { effect.textAvoidanceEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text Avoidance")
                    Text("Jellyfish drift clear of on-screen text and the cursor")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()
        }

        Section("Glow") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Bloom")
                    Spacer()
                    Text(bloomDraft, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $bloomDraft, in: 0...1) { editing in
                    editingBloom = editing
                    if !editing { effect.bloom = bloomDraft }
                }
                    .accessibilityLabel(Text("Bloom"))
            }
            .onAppear { bloomDraft = effect.bloom }
            .onChange(of: effect.bloom) { _, value in
                if !editingBloom { bloomDraft = value }
            }
            .themedRow()

            Toggle(isOn: Binding(
                get: { effect.shimmerEnabled },
                set: { effect.shimmerEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bioluminescent Shimmer")
                    Text("Rare brightening ripple down the tentacles, on dark themes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()
        }

        Section("Color Mode") {
            Picker("Style", selection: Binding(
                get: { effect.colorMode },
                set: { effect.colorMode = $0 }
            )) {
                ForEach(JellyfishEffect.ColorMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .themedRow()

            if effect.colorMode == .themeAdaptive {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Glows cyan on dark themes, reads as ink wash on light themes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        }

        Section {
            Button(action: onShowcase) {
                Label("Full-screen Jellyfish Preview", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .themedRow()
        } footer: {
            Text("Translucent bells, flowing oral arms, and luminous tentacles. Battery Saver reduces detail automatically. Reduce Motion softens swimming and disables shimmer.")
        }
    }
}

// MARK: - Aurora Settings Section

/// Separate view that properly observes AuroraEffect for reactive updates
private struct AuroraSettingsSection: View {
    @ObservedObject var effect: AuroraEffect

    var body: some View {
        Section("Color Mode") {
            Picker("Style", selection: Binding(
                get: { effect.colorMode },
                set: { effect.colorMode = $0 }
            )) {
                ForEach(AuroraEffect.ColorMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .themedRow()

            if effect.colorMode == .theme {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Curtain colors follow the terminal theme palette")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        }

        Section("Motion") {
            Toggle(isOn: Binding(
                get: { effect.rayShimmer },
                set: { effect.rayShimmer = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ray Shimmer")
                    Text("Fast flicker of individual rays. Turn off for calm, slow drift only")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()
        }
    }
}

// MARK: - Theme Gradient Settings Section

private struct ThemeGradientSettingsSection: View {
    @ObservedObject var effect: ThemeGradientEffect

    var body: some View {
        Section("Motion") {
            Toggle(isOn: Binding(
                get: { effect.drift },
                set: { effect.drift = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drift")
                    Text("Colors follow the terminal theme palette. Turn off for a still gradient that uses no GPU after drawing")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()
        }
    }
}

// MARK: - Ocean Settings View

/// Separate view that properly observes SolarGraphEffect for reactive updates
private struct OceanSettingsView: View {
    @ObservedObject var effect: SolarGraphEffect

    // Local state to ensure view updates
    @State private var showOcean: Bool = true

    var body: some View {
        Toggle(isOn: $showOcean) {
            HStack {
                Image(systemName: "water.waves")
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ocean Surface")
                    Text("Animated waves below horizon")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            showOcean = effect.showOcean
        }
        .onChange(of: showOcean) { _, newValue in
            effect.showOcean = newValue
        }

        if showOcean {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Wave Intensity")
                    Spacer()
                    Text(waveIntensityLabel(effect.oceanWaveAmplitude))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(width: 70, alignment: .trailing)
                }
                Slider(value: Binding(
                    get: { effect.oceanWaveAmplitude },
                    set: { effect.oceanWaveAmplitude = $0 }
                ), in: 0.1...1.0)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sun Reflection")
                    Spacer()
                    Text(effect.oceanReflectionStrength, format: .wholePercent)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
                Slider(value: Binding(
                    get: { effect.oceanReflectionStrength },
                    set: { effect.oceanReflectionStrength = $0 }
                ), in: 0.0...1.0)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Wave Speed")
                    Spacer()
                    Text(waveSpeedLabel(effect.oceanWaveSpeed))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(width: 70, alignment: .trailing)
                }
                Slider(value: Binding(
                    get: { effect.oceanWaveSpeed },
                    set: { effect.oceanWaveSpeed = $0 }
                ), in: 0.2...3.0)
            }
            .padding(.vertical, 4)

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("Realistic Gerstner waves with sun reflection path")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func waveSpeedLabel(_ speed: Double) -> String {
        switch speed {
        case 0.0..<0.5: return "Slow"
        case 0.5..<0.9: return "Gentle"
        case 0.9..<1.2: return "Normal"
        case 1.2..<2.0: return "Fast"
        default: return "Rapid"
        }
    }

    private func waveIntensityLabel(_ amplitude: Double) -> String {
        switch amplitude {
        case 0.0..<0.25: return "Calm"
        case 0.25..<0.45: return "Gentle"
        case 0.45..<0.65: return "Moderate"
        case 0.65..<0.85: return "Choppy"
        default: return "Stormy"
        }
    }
}

private struct PhotosVideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let tempURL = tempDir.appendingPathComponent("photos-video-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return PhotosVideoTransferable(url: tempURL)
        }
    }
}

#Preview {
    NavigationView {
        EffectSettingsView()
    }
}
