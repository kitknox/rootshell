// BackgroundEffectStage.swift
// rootshell
//
// The stage at the top of Settings → Background Effect: the device with each
// area's effect drawn in, beside a live close-up of the area being edited.

import SwiftUI
import UIKit

nonisolated enum BackgroundEffectArea: String, CaseIterable, Hashable, Sendable {
    case terminal, sidebar, keyboard, window

    @MainActor
    static var available: [BackgroundEffectArea] {
        allCases.filter(\.isAvailable)
    }

    @MainActor
    var isAvailable: Bool {
        switch self {
        case .terminal, .window: return true
        case .sidebar:
            #if os(visionOS)
            return false
            #else
            return UIDevice.current.userInterfaceIdiom != .phone
            #endif
        case .keyboard:
            #if os(visionOS) || targetEnvironment(macCatalyst)
            return false
            #else
            return true
            #endif
        }
    }

    var title: String {
        switch self {
        case .terminal: String(localized: "Terminal", comment: "Background effect area: the terminal")
        case .sidebar: String(localized: "Sidebar", comment: "Background effect area: the pinned tab sidebar")
        case .keyboard: String(localized: "Keyboard", comment: "Background effect area: the on-screen keyboard")
        case .window: String(localized: "Window", comment: "Background effect area: the backdrop behind the whole window")
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "apple.terminal"
        case .sidebar: "sidebar.left"
        case .keyboard: "keyboard"
        case .window: "macwindow"
        }
    }
}

/// What each area shows, resolved from the settings.
struct BackgroundEffectStageState {
    var area: BackgroundEffectArea
    var areas: [BackgroundEffectArea]
    var terminal: AnyTerminalEffect?
    var sidebar: AnyTerminalEffect?
    var keyboard: AnyTerminalEffect?
    var keyboardPlacement: TerminalTouchKeyboardModel.BackgroundEffectPlacement
    var backdrop: AnyTerminalEffect?
    var textAbove: Bool

    func effect(for area: BackgroundEffectArea) -> AnyTerminalEffect? {
        switch area {
        case .terminal: terminal
        case .sidebar: sidebar
        case .keyboard: keyboardPlacement == .off ? nil : keyboard
        case .window: backdrop
        }
    }
}

struct BackgroundEffectStage: View {
    let state: BackgroundEffectStageState
    /// 0 shows the device beside the close-up, 1 the close-up alone as a band.
    let collapse: Double
    let expandedHeight: CGFloat
    let collapsedHeight: CGFloat
    /// Lifts the sample text off the effect for a moment after Text Above Effect changes.
    let separation: Double

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.self) private var environment
    @State private var width: CGFloat = 0

    private var height: CGFloat { expandedHeight + (collapsedHeight - expandedHeight) * collapse }
    private var radius: CGFloat { 18 - 4 * collapse }
    private var overviewWidth: CGFloat { max(0, width * 0.4 * (1 - collapse)) }

    var body: some View {
        let palette = WindowPreviewPalette.current(sheetThemeColors: sheetThemeColors, environment: environment)
        ZStack(alignment: .topLeading) {
            StageBackdrop(palette: palette)
            HStack(spacing: 0) {
                if collapse < 0.99 {
                    DeviceOverview(state: state, palette: palette)
                        .frame(width: max(width * 0.4, 1), height: expandedHeight)
                        .frame(width: overviewWidth, height: height, alignment: .topLeading)
                        .clipped()
                        .opacity(1 - collapse)
                }
                AreaCloseUp(state: state, palette: palette, separation: separation)
                    .clipShape(RoundedRectangle(cornerRadius: 12 - 4 * collapse, style: .continuous))
                    .shadow(color: .black.opacity(0.22 * (1 - collapse)), radius: 8, y: 4)
                    .padding(.vertical, 12 - 8 * collapse)
                    .padding(.trailing, 12 - 8 * collapse)
                    .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// The row-colored stage behind the device and close-up.
private struct StageBackdrop: View {
    let palette: WindowPreviewPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        let palette = palette, reduceMotion = reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isVisible || scenePhase != .active)) { timeline in
            let time = reduceMotion ? 3.4 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { context, size in
                guard size.width > 1, size.height > 1 else { return }
                PreviewKit(size: size, time: time, palette: palette, reduceMotion: reduceMotion).stage(&context)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

// MARK: - Device overview

/// The device drawn as itself, each area filled with its effect's portrait and
/// the area being edited outlined.
private struct DeviceOverview: View {
    let state: BackgroundEffectStageState
    let palette: WindowPreviewPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.duoLayout) private var duoLayout
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        let palette = palette, reduceMotion = reduceMotion
        let device = PreviewDevice.current(duoLayout: duoLayout)
        let areas = Set(state.areas)
        let selected = state.area
        let kinds = OverviewKinds(
            terminal: EffectPortraitKind(effect: state.terminal),
            sidebar: areas.contains(.sidebar) ? EffectPortraitKind(effect: state.sidebar) : nil,
            keyboard: areas.contains(.keyboard) ? EffectPortraitKind(effect: state.keyboard) : nil,
            keyboardPlacement: state.keyboardPlacement,
            backdrop: state.backdrop.map { EffectPortraitKind(effect: $0) }
        )
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isVisible || scenePhase != .active)) { timeline in
            let time = reduceMotion ? 6 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { context, size in
                guard size.width > 1, size.height > 1 else { return }
                let kit = PreviewKit(size: size, time: time, palette: palette, reduceMotion: reduceMotion, device: device)
                DeviceOverviewScene.draw(&context, kit: kit, kinds: kinds, selected: selected)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

nonisolated struct OverviewKinds: Sendable {
    var terminal: EffectPortraitKind
    var sidebar: EffectPortraitKind?
    var keyboard: EffectPortraitKind?
    var keyboardPlacement: TerminalTouchKeyboardModel.BackgroundEffectPlacement
    var backdrop: EffectPortraitKind?
}

nonisolated enum DeviceOverviewScene {
    static func draw(_ context: inout GraphicsContext, kit: PreviewKit, kinds: OverviewKinds, selected: BackgroundEffectArea) {
        let p = kit.palette, k = kit.k
        let frame = DeviceFrame(kit: kit, device: kit.device)
        let (screen, shape) = frame.drawBody(&context)
        var g = context
        g.clip(to: shape)
        g.fill(Path(screen), with: .color(p.background.color()))

        let content = kit.contentRect(screen)
        kit.macTitleBar(&g, screen)

        // Keyboard along the bottom on touch devices, sidebar down the leading edge.
        var keyboard: CGRect?
        var body = content
        if kinds.keyboard != nil {
            let fraction = kit.device == .phone || kit.device == .duoClosed ? 0.36 : 0.3
            let rect = CGRect(x: content.minX, y: content.maxY - content.height * fraction, width: content.width, height: content.height * fraction)
            keyboard = rect
            body = CGRect(x: content.minX, y: content.minY, width: content.width, height: content.height - rect.height)
        }
        var sidebar: CGRect?
        if kinds.sidebar != nil {
            let rect = CGRect(x: body.minX, y: body.minY, width: body.width * 0.26, height: body.height)
            sidebar = rect
            body = CGRect(x: rect.maxX, y: body.minY, width: body.width - rect.width, height: body.height)
        }

        // The backdrop fills the window, with the terminal as a rounded pane on it.
        var terminal = body
        if let backdrop = kinds.backdrop {
            EffectPortrait.draw(backdrop, in: content, context: &g, palette: p, time: kit.time)
            terminal = body.insetBy(dx: 6 * k, dy: 6 * k)
            var pane = g
            let paneShape = Path(roundedRect: terminal, cornerRadius: 5 * k, style: .continuous)
            pane.clip(to: paneShape)
            pane.fill(paneShape, with: .color(p.background.color()))
            if kinds.terminal != .none {
                EffectPortrait.draw(kinds.terminal, in: terminal, context: &pane, palette: p, time: kit.time)
            }
        } else if kinds.terminal != .none {
            EffectPortrait.draw(kinds.terminal, in: terminal, context: &g, palette: p, time: kit.time)
        }
        drawText(&g, kit: kit, in: terminal)

        if let sidebar, let kind = kinds.sidebar {
            g.fill(Path(sidebar), with: .color(p.chrome.color()))
            if kind != .none { EffectPortrait.draw(kind, in: sidebar, context: &g, palette: p, time: kit.time + 1.7) }
            g.fill(Path(sidebar), with: .color(p.chrome.color(0.25)))
            for row in 0..<3 {
                let tab = CGRect(x: sidebar.minX + 2.5 * k, y: sidebar.minY + (4 + Double(row) * 7) * k, width: sidebar.width - 5 * k, height: 4.5 * k)
                g.fill(Path(roundedRect: tab, cornerRadius: 1.6 * k), with: .color(p.foreground.color(row == 0 ? 0.35 : 0.16)))
            }
        }

        if let keyboard, let kind = kinds.keyboard {
            g.fill(Path(keyboard), with: .color(p.chrome.color()))
            let toolbar = CGRect(x: keyboard.minX, y: keyboard.minY, width: keyboard.width, height: keyboard.height * 0.24)
            if kind != .none {
                switch kinds.keyboardPlacement {
                case .off: break
                case .toolbar: EffectPortrait.draw(kind, in: toolbar, context: &g, palette: p, time: kit.time + 3.1)
                case .entireKeyboard: EffectPortrait.draw(kind, in: keyboard, context: &g, palette: p, time: kit.time + 3.1)
                }
            }
            let keys = CGRect(x: keyboard.minX + 2 * k, y: toolbar.maxY + 1.5 * k, width: keyboard.width - 4 * k, height: keyboard.maxY - toolbar.maxY - 3.5 * k)
            let columns = 8, rows = 3
            let gap = 1.2 * k
            let keyWidth = (keys.width - gap * Double(columns - 1)) / Double(columns)
            let keyHeight = (keys.height - gap * Double(rows - 1)) / Double(rows)
            for row in 0..<rows {
                for column in 0..<columns {
                    let rect = CGRect(x: keys.minX + Double(column) * (keyWidth + gap), y: keys.minY + Double(row) * (keyHeight + gap), width: keyWidth, height: keyHeight)
                    g.fill(Path(roundedRect: rect, cornerRadius: 1 * k), with: .color(p.foreground.color(0.16)))
                }
            }
        }

        let highlight: CGRect? = switch selected {
        case .terminal: terminal
        case .sidebar: sidebar
        case .keyboard: keyboard
        case .window: content
        }
        if let highlight {
            let outline = Path(roundedRect: highlight.insetBy(dx: 0.9 * k, dy: 0.9 * k), cornerRadius: 2.5 * k, style: .continuous)
            g.stroke(outline, with: .color(p.accent.color()), lineWidth: 1.6 * k)
        }
        frame.drawCamera(&context, screen: screen)
    }

    private static func drawText(_ context: inout GraphicsContext, kit: PreviewKit, in rect: CGRect) {
        let runs = kit.terminalRuns(in: rect, padX: 5, padY: 6, lineHeight: 8)
        var g = context
        g.clip(to: Path(rect))
        kit.drawRuns(&g, runs.flatMap { $0 }, opacity: 0.8)
    }
}

// MARK: - Close-up

/// The area being edited at full size, running its real effect.
private struct AreaCloseUp: View {
    let state: BackgroundEffectStageState
    let palette: WindowPreviewPalette
    let separation: Double

    var body: some View {
        // Sized to the stage, not the content, so the band clips instead of growing.
        palette.background.color()
            .overlay(alignment: state.area == .keyboard ? .bottom : .topLeading) {
                ZStack {
                    switch state.area {
                    case .terminal: terminal
                    case .sidebar: sidebar
                    case .keyboard: keyboard
                    case .window: window
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) { nameChip }
        .animation(.smooth(duration: 0.35), value: state.area)
    }

    @ViewBuilder
    private var terminal: some View {
        let text = SampleTerminalText(palette: palette)
            .offset(y: -6 * separation)
            .scaleEffect(1 + 0.03 * separation, anchor: .topLeading)
            .shadow(color: .black.opacity(0.35 * separation), radius: 6 * separation, y: 3 * separation)
        if let effect = state.terminal {
            // Text below the effect lets it wash over the text, as in the terminal.
            if state.textAbove {
                EffectPreviewSurface(effect: effect).opacity(1 - 0.35 * separation)
                text
            } else {
                text
                EffectPreviewSurface(effect: effect).opacity(1 - 0.35 * separation)
            }
        } else {
            text
        }
    }

    private var sidebar: some View {
        ZStack(alignment: .topLeading) {
            palette.chrome.color()
            if let effect = state.sidebar { EffectPreviewSurface(effect: effect) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<4, id: \.self) { row in
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.foreground.color(row == 0 ? 0.22 : 0.09))
                        .frame(height: 22)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(palette.foreground.color(row == 0 ? 0.7 : 0.4))
                                .frame(width: [70, 54, 62, 44][row], height: 4)
                                .padding(.leading, 10)
                        }
                }
            }
            .frame(maxWidth: 150)
            .padding(10)
        }
    }

    private var keyboard: some View {
        VStack(spacing: 0) {
            ZStack {
                palette.background.color()
                SampleTerminalText(palette: palette)
            }
            .frame(maxHeight: .infinity)
            ZStack(alignment: .top) {
                palette.chrome.color()
                if let effect = state.effect(for: .keyboard) {
                    EffectPreviewSurface(effect: effect)
                        .frame(maxHeight: state.keyboardPlacement == .toolbar ? 26 : .infinity, alignment: .top)
                        .clipped()
                }
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(["esc", "tab", "ctrl", "⌥", "↑", "↓"], id: \.self) { key in
                            Text(key)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(palette.foreground.color(0.85))
                                .frame(maxWidth: .infinity, minHeight: 18)
                        }
                    }
                    .frame(height: 22)
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 4) {
                            ForEach(0..<10, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(palette.foreground.color(0.16))
                            }
                        }
                    }
                }
                .padding(4)
            }
            .frame(height: 82)
        }
    }

    private var window: some View {
        ZStack {
            palette.chrome.color()
            if let effect = state.backdrop { EffectPreviewSurface(effect: effect) }
            ZStack {
                palette.background.color(0.94)
                SampleTerminalText(palette: palette)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(state.backdrop == nil ? 0 : 12)
        }
    }

    @ViewBuilder
    private var nameChip: some View {
        let effect = state.effect(for: state.area)
        Text(effect?.displayName ?? String(localized: "None", comment: "Background effect: no effect"))
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, palette.isLight ? .light : .dark)
            .padding(6)
            .contentTransition(.opacity)
    }
}

/// A few lines of shell in the theme's colors.
struct SampleTerminalText: View {
    let palette: WindowPreviewPalette

    var body: some View {
        // Takes the space offered; lines that don't fit run off the bottom.
        Color.clear
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    prompt("ls -la")
                    Text(verbatim: "drwxr-xr-x  5 user  staff  160 .").foregroundStyle(palette.foreground.color(0.85))
                    Text(verbatim: "-rw-r--r--  1 user  staff  912 notes.md").foregroundStyle(palette.foreground.color(0.85))
                    prompt("")
                }
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .padding(12)
            }
            .allowsHitTesting(false)
    }

    private func prompt(_ command: String) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: "user@host").foregroundStyle(palette.green.color())
            Text(verbatim: " ~ $ \(command)").foregroundStyle(palette.foreground.color())
        }
    }
}

// MARK: - Preview surface

/// An effect drawn the way the terminal draws it: shaders whose light-theme
/// output is white-based multiply, and rare visitors spawn at once and often.
struct EffectPreviewSurface: View {
    let effect: AnyTerminalEffect
    var effectManager = EffectManager.shared

    var body: some View {
        Group {
            if let butterflies = effect.asEffect(ButterfliesEffect.self) {
                ButterfliesView(effect: butterflies, previewMode: true)
            } else if let jellyfish = effect.asEffect(JellyfishEffect.self) {
                JellyfishView(effect: jellyfish, previewMode: true)
                    .blendMode(jellyfish.isLightBackground ? .multiply : .plusLighter)
            } else if Self.blendedIDs.contains(effect.id), effect.asEffect(ThemeGradientEffect.self)?.isBackdrop != true {
                effect.createEffectView()
                    .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
            } else {
                effect.createEffectView()
            }
        }
        .id(effect.id)
        .allowsHitTesting(false)
    }

    private static let blendedIDs: Set<String> = ["aurora", "aquarium", "themeGradient", "liveWeather"]
}
