// EffectDetailView.swift
// rootshell
//
// Every setting for one background effect, under a live preview of it.

import SwiftUI
import PhotosUI
import UIKit

struct EffectDetailView: View {
    @ObservedObject var effect: AnyTerminalEffect
    var transparencyManager = TransparencyManager.shared

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.self) private var environment

    // Sliders commit on release.
    @State private var localIntensity: Double = 0.3
    @State private var localSpeed: Double = 1.0

    @State private var solarDemoMode = false
    @State private var solarDemoSpeed = 60.0
    @State private var solarUseLocation = true
    @State private var selectedTimezoneId = TimeZone.current.identifier

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false

    // Kept outside recycled List sections, which can leave the visible list
    // during the first sheet layout and dismiss their sheet.
    @State private var showcaseEffect: AnyTerminalEffect?

    private var isBackdrop: Bool { effect.asEffect(ThemeGradientEffect.self)?.isBackdrop == true }

    var body: some View {
        List {
            Section {
                hero
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let gradientEffect = effect.asEffect(ThemeGradientEffect.self) {
                ThemeGradientStyleSection(effect: gradientEffect)
            }

            lookSection
            effectSections

            Section {
                Button("Reset to Defaults") {
                    effect.resetToDefaults()
                    syncLocalState()
                    solarDemoMode = false
                    solarDemoSpeed = 60.0
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle(effect.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showcaseEffect = effect
                } label: {
                    Label("Full-Screen Preview", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        }
        .sheet(item: $showcaseEffect) { effect in
            EffectShowcaseView(effect: effect)
        }
        .onAppear(perform: syncLocalState)
    }

    // MARK: Hero

    private var hero: some View {
        let palette = WindowPreviewPalette.current(sheetThemeColors: sheetThemeColors, environment: environment)
        return ZStack {
            palette.background.color()
            if isBackdrop {
                EffectPreviewSurface(effect: effect)
                ZStack {
                    palette.background.color(0.94)
                    SampleTerminalText(palette: palette)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(18)
            } else if EffectManager.shared.isTextAboveEffectEnabled {
                EffectPreviewSurface(effect: effect)
                SampleTerminalText(palette: palette)
            } else {
                SampleTerminalText(palette: palette)
                EffectPreviewSurface(effect: effect)
            }
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    // MARK: Look

    @ViewBuilder
    private var lookSection: some View {
        let showsIntensity = !isBackdrop && effect.id != "photoBackground"
        let showsSpeed = effect.id != "solarGraph" && effect.id != "liveWeather" && effect.id != "photoBackground"
        if showsIntensity || showsSpeed {
            Section("Look") {
                if showsIntensity {
                    EffectSliderRow(title: "Intensity", value: $localIntensity, range: 0.05...0.6,
                                    label: localIntensity.formatted(.percent.precision(.fractionLength(0)))) {
                        effect.intensity = localIntensity
                    }
                    .themedRow()
                }
                if showsSpeed {
                    EffectSliderRow(title: "Speed", value: $localSpeed, range: 0.25...2.0, label: EffectSpeedLabel.text(localSpeed)) {
                        effect.speed = localSpeed
                    }
                    .themedRow()
                }
            }
        }
    }

    // MARK: Per-effect sections

    @ViewBuilder
    private var effectSections: some View {
        if let solarEffect = effect.asEffect(SolarGraphEffect.self) {
            solarSections(solarEffect)
        }
        if let photoEffect = effect.asEffect(PhotoBackgroundEffect.self) {
            PhotoBackgroundSettingsSection(effect: photoEffect, selectedPhotoItem: $selectedPhotoItem, isLoadingPhoto: $isLoadingPhoto)
        }
        if let videoEffect = effect.asEffect(VideoBackgroundEffect.self) {
            VideoThemeTintSection(effect: videoEffect)
        }
        if let firefliesEffect = effect.asEffect(FirefliesEffect.self) {
            FirefliesSettingsSection(effect: firefliesEffect)
        }
        if let butterfliesEffect = effect.asEffect(ButterfliesEffect.self) {
            ButterfliesSettingsSection(effect: butterfliesEffect)
        }
        if let jellyfishEffect = effect.asEffect(JellyfishEffect.self) {
            JellyfishSettingsSection(effect: jellyfishEffect) { showcaseEffect = effect }
        }
        if let aquariumEffect = effect.asEffect(AquariumEffect.self) {
            AquariumSettingsSection(effect: aquariumEffect, onShowcase: { showcaseEffect = effect }) {
                aquariumEffect.resetToDefaults()
                syncLocalState()
            }
        }
        #if !CHINA_BUILD
        if let weatherEffect = effect.asEffect(LiveWeatherEffect.self) {
            LiveWeatherSettingsSection(effect: weatherEffect) { showcaseEffect = effect }
        }
        #endif
        if let auroraEffect = effect.asEffect(AuroraEffect.self) {
            AuroraSettingsSection(effect: auroraEffect)
        }
        if let gradientEffect = effect.asEffect(ThemeGradientEffect.self) {
            ThemeGradientSettingsSection(effect: gradientEffect)
        }
    }

    @ViewBuilder
    private func solarSections(_ solarEffect: SolarGraphEffect) -> some View {
        if transparencyManager.effectiveBackgroundOpacity < 1.0 {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transparency Enabled")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Window transparency can cause visual artifacts with the solar background. Set transparency to \(1.0.formatted(.wholePercent)) for optimal quality.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        effect.speed = solarDemoSpeed
                    } else {
                        effect.speed = 1.0
                    }
                }
                .themedRow()

            if solarDemoMode {
                EffectSliderRow(title: "Cycle Speed", value: $solarDemoSpeed, range: 30...1440, step: 30,
                                label: solarDemoSpeedLabel(solarDemoSpeed)) {
                    effect.speed = solarDemoSpeed
                }
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
                            // Permission may have been denied.
                            solarUseLocation = solarEffect.useLocation
                        }
                    }
                }
                .themedRow()

            if solarUseLocation {
                if let locality = solarEffect.locationService.locality {
                    Label(locality, systemImage: "mappin.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .themedRow()
                } else if solarEffect.locationService.isRequestingLocation {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Getting location...")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .themedRow()
                } else {
                    Text("Accurate sunrise & sunset times")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .themedRow()
                }
            } else {
                Picker("Timezone", selection: $selectedTimezoneId) {
                    ForEach(Self.commonTimezones, id: \.self) { tz in
                        Text(Self.formatTimezone(tz)).tag(tz)
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
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        }

        Section("Display") {
            Toggle(isOn: Binding(get: { solarEffect.showArcTrack }, set: { solarEffect.showArcTrack = $0 })) {
                EffectToggleLabel(title: "Solar Arc", detail: "Show sun path indicator")
            }
            .themedRow()

            Toggle(isOn: Binding(get: { solarEffect.showSunHotspot }, set: { solarEffect.showSunHotspot = $0 })) {
                EffectToggleLabel(title: "Sun Hotspot", detail: "3D depth highlight on sun disc")
            }
            .themedRow()
        }

        Section {
            Toggle(isOn: Binding(get: { solarEffect.showStars }, set: { solarEffect.showStars = $0 })) {
                EffectToggleLabel(title: "Star Field", detail: "Real astronomical positions")
            }
            .themedRow()

            if solarEffect.showStars {
                Toggle(isOn: Binding(get: { solarEffect.starTwinkle }, set: { solarEffect.starTwinkle = $0 })) {
                    EffectToggleLabel(title: "Twinkling", detail: "Atmospheric shimmer effect")
                }
                .themedRow()
            }
        } header: {
            Text("Night Sky")
        } footer: {
            if solarEffect.showStars {
                Text("Includes Milky Way, nebulae, and diffraction spikes for brightest stars")
            }
        }

        Section("Ocean") {
            OceanSettingsView(effect: solarEffect)
                .themedRow()
        }
    }

    private func syncLocalState() {
        localIntensity = effect.intensity
        localSpeed = effect.speed
        if let solarEffect = effect.asEffect(SolarGraphEffect.self) {
            solarDemoMode = effect.speed > 1.0
            if solarDemoMode { solarDemoSpeed = effect.speed }
            solarUseLocation = solarEffect.useLocation
            selectedTimezoneId = solarEffect.manualTimezone.identifier
        }
    }

    private func solarDemoSpeedLabel(_ speed: Double) -> String {
        // Real seconds per simulated second: 60 is a 24 min day, 1440 a 1 min day.
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

    private static let commonTimezones = [
        "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "America/Anchorage",
        "Pacific/Honolulu", "America/Toronto", "America/Vancouver", "America/Mexico_City", "America/Sao_Paulo",
        "America/Buenos_Aires",
        "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Rome", "Europe/Madrid", "Europe/Amsterdam",
        "Europe/Stockholm", "Europe/Moscow",
        "Asia/Dubai", "Asia/Kolkata", "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Shanghai",
        "Asia/Tokyo", "Asia/Seoul",
        "Australia/Sydney", "Australia/Melbourne", "Australia/Perth", "Pacific/Auckland",
        "Africa/Cairo", "Africa/Johannesburg", "Africa/Lagos",
    ]

    private static func formatTimezone(_ identifier: String) -> String {
        guard let tz = TimeZone(identifier: identifier) else { return identifier }
        let city = identifier.components(separatedBy: "/").last?.replacingOccurrences(of: "_", with: " ") ?? identifier
        let hours = tz.secondsFromGMT() / 3600
        return "\(city) (UTC\(hours >= 0 ? "+" : "")\(hours))"
    }
}

// MARK: - Shared rows

/// A titled slider with its value on the right, committing when released.
struct EffectSliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let label: String
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Group {
                if let step {
                    Slider(value: $value, in: range, step: step) { editing in if !editing { onCommit() } }
                } else {
                    Slider(value: $value, in: range) { editing in if !editing { onCommit() } }
                }
            }
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(label))
        }
        .padding(.vertical, 4)
    }
}

enum EffectSpeedLabel {
    static func text(_ speed: Double) -> String {
        switch speed {
        case ..<0.4: String(localized: "Very Slow", comment: "Effect speed")
        case ..<0.65: String(localized: "Slow", comment: "Effect speed")
        case ..<0.9: String(localized: "Slower", comment: "Effect speed")
        case ..<1.15: String(localized: "Normal", comment: "Effect speed")
        case ..<1.4: String(localized: "Faster", comment: "Effect speed")
        case ..<1.85: String(localized: "Fast", comment: "Effect speed")
        default: String(localized: "Very Fast", comment: "Effect speed")
        }
    }
}

private struct EffectToggleLabel: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    Text("Slowly moves the glow. Turn off for a still gradient that uses no GPU after drawing")
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
