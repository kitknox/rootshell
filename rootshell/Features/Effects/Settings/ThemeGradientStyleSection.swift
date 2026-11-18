// ThemeGradientStyleSection.swift
// rootshell

import SwiftUI
import UIKit

extension ThemeGradientStyle {
    var displayName: String {
        switch self {
        case .theme: return String(localized: "Theme", comment: "Theme Gradient style: the theme's own colors")
        case .glow: return String(localized: "Glow", comment: "Theme Gradient style: dark base with a bright glow")
        case .contrast: return String(localized: "Contrast", comment: "Theme Gradient style: opposite theme hues")
        case .spectrum: return String(localized: "Spectrum", comment: "Theme Gradient style: three theme hues")
        case .tonal: return String(localized: "Tonal", comment: "Theme Gradient style: one hue at several depths")
        case .warm: return String(localized: "Warm", comment: "Theme Gradient style: the theme's warm colors")
        case .cool: return String(localized: "Cool", comment: "Theme Gradient style: the theme's cool colors")
        case .mist: return String(localized: "Mist", comment: "Theme Gradient style: subtle, close to the background")
        case .custom: return String(localized: "Custom", comment: "Theme Gradient style: user-picked colors")
        }
    }
}

/// Style picker with live previews, custom colors and adjustments.
struct ThemeGradientStyleSection: View {
    @ObservedObject var effect: ThemeGradientEffect

    /// Slider and color picker edits not yet committed; the effect's look otherwise.
    @State private var pending: ThemeGradientLook?
    @State private var commitTask: Task<Void, Never>?

    private var draft: ThemeGradientLook { pending ?? effect.look }

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 160), spacing: 12)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(ThemeGradientStyle.allCases) { style in
                    ThemeGradientStyleTile(
                        name: style.displayName,
                        palette: ThemeGradientPalette(themeColors: effect.themeColors, look: previewLook(style)),
                        themeColors: effect.themeColors,
                        isBackdrop: effect.isBackdrop,
                        intensity: effect.intensity,
                        isCustom: style == .custom,
                        isSelected: draft.style == style
                    ) {
                        select(style)
                    }
                }
            }
            .padding(.vertical, 6)
            .themedRow()
        } header: {
            Text("Style")
        } footer: {
            Text("Each style is built from the current theme's colors, so it changes with the theme. Custom keeps your own colors.")
        }

        if draft.style == .custom {
            Section {
                ColorPicker("Base", selection: customBinding(0), supportsOpacity: false)
                    .themedRow()
                ColorPicker("Glow", selection: customBinding(1), supportsOpacity: false)
                    .themedRow()
                ColorPicker("Blend", selection: customBinding(2), supportsOpacity: false)
                    .themedRow()
                Menu {
                    ForEach(ThemeGradientStyle.presets) { style in
                        Button(style.displayName) {
                            var look = draft
                            look.customColors = seedColors(from: style)
                            commit(look)
                        }
                    }
                } label: {
                    Label("Start From a Style", systemImage: "wand.and.stars")
                }
                .themedRow()
            } header: {
                Text("Custom Colors")
            } footer: {
                Text("Base fills the window, Glow lights the top corner and center, and Blend softens the space between them.")
            }
        }

        Section("Adjust") {
            adjustmentSlider("Vibrance", value: draftBinding(\.vibrance), range: ThemeGradientLook.vibranceRange)
            adjustmentSlider("Brightness", value: draftBinding(\.brightness), range: ThemeGradientLook.brightnessRange)
            if draft.hasAdjustments {
                Button("Reset Adjustments") {
                    var look = draft
                    look.vibrance = 1
                    look.brightness = 1
                    commit(look)
                }
                .themedRow()
            }
        }
    }

    // MARK: Actions

    private func select(_ style: ThemeGradientStyle) {
        var look = draft
        if style == .custom, look.customColors == nil {
            look.customColors = seedColors(from: look.style)
        }
        look.style = style
        commit(look)
    }

    private func commit(_ look: ThemeGradientLook? = nil) {
        commitTask?.cancel()
        commitTask = nil
        effect.look = look ?? draft
        pending = nil
    }

    /// Color pickers report every drag step.
    private func commitSoon() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func seedColors(from style: ThemeGradientStyle) -> [SIMD3<Double>] {
        ThemeGradientPalette.styleColors(themeColors: effect.themeColors, style: style).map { Self.quantized($0) }
    }

    /// Previews share the draft's adjustments; Custom shows what it would start from.
    private func previewLook(_ style: ThemeGradientStyle) -> ThemeGradientLook {
        var look = draft
        look.style = style
        if style == .custom, look.customColors == nil {
            look.customColors = seedColors(from: draft.style)
        }
        return look
    }

    // MARK: Controls

    private func customBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let colors = draft.customColors ?? seedColors(from: .theme)
                return Color(red: colors[index].x, green: colors[index].y, blue: colors[index].z)
            },
            set: { color in
                var look = draft
                var colors = look.customColors ?? seedColors(from: .theme)
                colors[index] = Self.rgb(color)
                look.customColors = colors
                pending = look
                commitSoon()
            }
        )
    }

    private func draftBinding(_ key: WritableKeyPath<ThemeGradientLook, Double>) -> Binding<Double> {
        Binding(
            get: { draft[keyPath: key] },
            set: { value in
                var look = draft
                look[keyPath: key] = value
                pending = look
            }
        )
    }

    private func adjustmentSlider(_ title: LocalizedStringKey, value: Binding<Double>,
                                  range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range) { editing in
                if !editing { commit() }
            }
        }
        .padding(.vertical, 4)
        .themedRow()
    }

    // MARK: Color math

    /// sRGB rounded to bytes, so saved colors read back equal.
    private static func quantized(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        (rgb.clamped(lowerBound: .zero, upperBound: .one) * 255).rounded(.toNearestOrAwayFromZero) / 255
    }

    private static func rgb(_ color: Color) -> SIMD3<Double> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return quantized(SIMD3(Double(r), Double(g), Double(b)))
    }
}

// MARK: - Tile

/// One style's gradient behind a small terminal pane.
private struct ThemeGradientStyleTile: View {
    let name: String
    let palette: ThemeGradientPalette
    let themeColors: EffectThemeColors
    let isBackdrop: Bool
    let intensity: Double
    let isCustom: Bool
    let isSelected: Bool
    let action: () -> Void

    private var background: Color { Color(hex: themeColors.background) ?? .black }
    private var foreground: Color { Color(hex: themeColors.foreground) ?? .white }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                swatch
                    .aspectRatio(1.4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                          lineWidth: isSelected ? 2.5 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.body)
                                .padding(5)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if isCustom {
                            Image(systemName: "paintbrush.pointed.fill")
                                .font(.caption2)
                                .foregroundStyle(foreground)
                                .padding(5)
                                .background(background.opacity(0.7), in: Circle())
                                .padding(5)
                        }
                    }
                Text(name)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var swatch: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                if isBackdrop {
                    gradient(size: geometry.size)
                } else {
                    // The area effect blends over the terminal like MainView draws it
                    background
                    gradient(size: geometry.size)
                        .blendMode(palette.isLight ? .multiply : .plusLighter)
                }
                pane(size: geometry.size)
            }
        }
    }

    private func gradient(size: CGSize) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .colorEffect(
                ShaderLibrary.themeGradient(
                    .float2(size),
                    .float4(0, 0, 0, 0),
                    .float4(0, 0, 0, 0),
                    .color(Self.color(palette.primary)),
                    .color(Self.color(palette.accent)),
                    .color(Self.color(palette.mid)),
                    .float(Float(intensity)),
                    .float(isBackdrop ? 1 : 0),
                    .float(palette.isLight ? 1 : 0)
                )
            )
    }

    /// A rounded pane with a few lines of text, as panes sit over the backdrop.
    private func pane(size: CGSize) -> some View {
        let lineHeight = max(2, size.height * 0.045)
        return VStack(alignment: .leading, spacing: lineHeight) {
            ForEach([0.7, 0.45, 0.85, 0.3], id: \.self) { fraction in
                Capsule()
                    .fill(foreground.opacity(0.85))
                    .frame(width: size.width * 0.5 * fraction, height: lineHeight)
            }
        }
        .padding(size.width * 0.05)
        .frame(width: size.width * 0.6, height: size.height * 0.55, alignment: .topLeading)
        .background(background.opacity(isBackdrop ? 0.88 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(size.width * 0.06)
    }

    private static func color(_ c: SIMD3<Double>) -> Color {
        Color(red: c.x, green: c.y, blue: c.z)
    }
}
