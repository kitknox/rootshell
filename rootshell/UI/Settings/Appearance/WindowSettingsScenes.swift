//
//  WindowSettingsScenes.swift
//  rootshell
//
//  The illustrated scenes for the Tab Switcher, Panes & Padding, Display,
//  and Text Selection pages. Each is a pure function of the kit and its
//  values, so a setting change animates and the loops need no state.
//

import SwiftUI

// MARK: - Tab Switcher

nonisolated struct TabSwitcherSceneValues: Equatable, Sendable {
    var translucent = 1.0
    var autoHide = 1.0
    var titleLines = 1.0
    /// 1 for a sidebar beside the terminal (regular width), 0 for the switcher sheet.
    var sidebar = 0.0

    var vector: PreviewVector { PreviewVector([translucent, autoHide, titleLines, sidebar]) }

    init(translucent: Bool, autoHide: Bool, titleLines: Int, sidebar: Bool) {
        self.translucent = translucent ? 1 : 0
        self.autoHide = autoHide ? 1 : 0
        self.titleLines = Double(titleLines)
        self.sidebar = sidebar ? 1 : 0
    }

    init(_ v: PreviewVector) {
        translucent = v[0]; autoHide = v[1]; titleLines = v[2]; sidebar = v[3]
    }
}

nonisolated enum TabSwitcherScene {
    static func draw(_ context: inout GraphicsContext, _ kit: PreviewKit, _ vector: PreviewVector) {
        let v = TabSwitcherSceneValues(vector)
        kit.stage(&context)
        let win = kit.windowRect()
        let shape = kit.windowShell(&context, win)
        let (_, phase) = kit.cycle(6.5)

        let content = kit.contentRect(win)
        context.drawLayer { layer in
            layer.clip(to: shape)
            kit.terminal(&layer, in: content)
            if v.sidebar > 0.5 {
                drawSidebar(&layer, kit, v, window: content, phase: phase)
            } else {
                drawSheet(&layer, kit, v, window: content, phase: phase)
            }
            kit.macTitleBar(&layer, win)
        }
        kit.windowEdge(&context, shape)
    }

    /// The switcher sheet rises over the terminal, a row is tapped, and it
    /// drops away again, which is what happens on a phone.
    private static func drawSheet(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: TabSwitcherSceneValues,
                                  window: CGRect, phase: Double) {
        let k = kit.k
        let rise = PreviewKit.ease(phase / 0.16) * (1 - PreviewKit.ease((phase - 0.62) / 0.16))
        guard rise > 0.001 else { return }
        let height = window.height * 0.78
        let panel = CGRect(x: window.minX + 6 * k, y: window.maxY - height * rise, width: window.width - 12 * k, height: height + 12 * k)
        let selected = phase > 0.5 ? 2 : 0
        let tap = phase > 0.42 && phase < 0.62 ? PreviewKit.ease((phase - 0.42) / 0.06) * (1 - PreviewKit.ease((phase - 0.54) / 0.08)) : 0
        drawPanel(&context, kit, v, panel: panel, radius: 12 * k, window: window, selected: selected,
                  tapRow: 2, tap: tap, rowsInset: CGPoint(x: 10 * k, y: 12 * k))
        // Grabber.
        context.fill(Path(roundedRect: CGRect(x: panel.midX - 10 * k, y: panel.minY + 4 * k, width: 20 * k, height: 2.4 * k), cornerRadius: 1.2 * k),
                     with: .color(kit.palette.foreground.color(0.3)))
    }

    /// The sidebar sits beside the terminal; with auto-hide it slides away
    /// after a pick and comes back.
    private static func drawSidebar(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: TabSwitcherSceneValues,
                                    window: CGRect, phase: Double) {
        let k = kit.k
        let hide = v.autoHide * PreviewKit.ease((phase - 0.5) / 0.12) * (1 - PreviewKit.ease((phase - 0.85) / 0.12))
        let width = window.width * 0.36
        let panel = CGRect(x: window.minX + 6 * k - (width + 8 * k) * hide, y: window.minY + 6 * k, width: width, height: window.height - 12 * k)
        let selected = phase > 0.44 ? 2 : 0
        let tap = phase > 0.36 && phase < 0.56 ? PreviewKit.ease((phase - 0.36) / 0.06) * (1 - PreviewKit.ease((phase - 0.48) / 0.08)) : 0
        drawPanel(&context, kit, v, panel: panel, radius: 9 * k, window: window, selected: selected,
                  tapRow: 2, tap: tap, rowsInset: CGPoint(x: 6 * k, y: 7 * k))
    }

    private static func drawPanel(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: TabSwitcherSceneValues,
                                  panel: CGRect, radius: Double, window: CGRect, selected: Int,
                                  tapRow: Int, tap: Double, rowsInset: CGPoint) {
        let k = kit.k, p = kit.palette
        let shape = Path(roundedRect: panel, cornerRadius: radius, style: .continuous)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.3), radius: 6 * k, y: 2 * k))
            layer.fill(shape, with: .color(p.chrome.color(1 - 0.5 * v.translucent)))
        }
        // Translucent: the terminal shows through, softened.
        if v.translucent > 0.01 {
            context.drawLayer { layer in
                layer.clip(to: shape)
                layer.opacity = 0.55 * v.translucent
                layer.addFilter(.blur(radius: 3 * k))
                kit.terminal(&layer, in: window, typing: false)
            }
            context.fill(shape, with: .linearGradient(Gradient(colors: [.white.opacity(0.1 * v.translucent), .clear]),
                                                      startPoint: CGPoint(x: panel.midX, y: panel.minY),
                                                      endPoint: CGPoint(x: panel.midX, y: panel.minY + 30 * k)))
        }
        context.stroke(shape, with: .color(.white.opacity(0.14)), lineWidth: 0.6 * k)

        let lines = max(1, min(3, v.titleLines))
        let rowHeight = (13 + 5.5 * (lines - 1)) * k
        let colors = [p.green, p.blue, p.magenta]
        let widths: [[Double]] = [[0.72, 0.58, 0.4], [0.6, 0.7, 0.32], [0.8, 0.5, 0.44]]
        var y = panel.minY + rowsInset.y + 6 * k
        for row in 0..<3 {
            let rect = CGRect(x: panel.minX + rowsInset.x, y: y, width: panel.width - rowsInset.x * 2, height: rowHeight)
            guard rect.maxY < panel.maxY - 2 * k else { break }
            if row == selected {
                kit.glass(&context, rect, radius: 6 * k, tint: p.accent)
            }
            if row == tapRow && tap > 0.01 {
                context.fill(Path(roundedRect: rect, cornerRadius: 6 * k), with: .color(p.foreground.color(0.12 * tap)))
            }
            let icon = CGRect(x: rect.minX + 5 * k, y: rect.minY + 3.5 * k, width: 7 * k, height: 7 * k)
            context.fill(Path(roundedRect: icon, cornerRadius: 1.8 * k), with: .color(colors[row].color()))
            let textX = icon.maxX + 5 * k
            let textWidth = rect.maxX - textX - 6 * k
            // Long titles wrap to as many lines as the setting allows.
            for line in 0..<3 {
                let visible = min(1, max(0, lines - Double(line)))
                guard visible > 0.01 else { continue }
                kit.bar(&context, x: textX, y: icon.midY + Double(line) * 5.5 * k, width: textWidth * widths[row][line],
                        height: 3.2, color: row == selected ? p.foreground : p.dim, opacity: visible)
            }
            if row == tapRow && tap > 0.01 {
                let point = CGPoint(x: rect.midX + 10 * k, y: rect.midY)
                if kit.device.isMac {
                    kit.pointer(&context, tip: point, opacity: min(1, tap * 2), pressed: tap)
                } else {
                    kit.touch(&context, at: point, opacity: tap, pressed: tap)
                }
            }
            y += rowHeight + 4 * k
        }
    }
}

// MARK: - Panes & Padding

nonisolated struct PanesSceneValues: Equatable, Sendable {
    var paddingX = 8.0
    var paddingY = 8.0
    var rounded = 0.0
    var borderWidth = 2.0
    var borderOpacity = 1.0
    var borderColor = PreviewRGB(0.54, 0.71, 0.98)
    var remotePorts = 0.0
    /// 1 shortly after a padding change: the insets are drawn as guides.
    var paddingMoment = 0.0

    var vector: PreviewVector {
        PreviewVector([paddingX, paddingY, rounded, borderWidth, borderOpacity] + borderColor.components + [remotePorts, paddingMoment])
    }

    init() {}

    init(_ v: PreviewVector) {
        paddingX = v[0]; paddingY = v[1]; rounded = v[2]; borderWidth = v[3]; borderOpacity = v[4]
        borderColor = PreviewRGB(v[5], v[6], v[7]); remotePorts = v[8]; paddingMoment = v[9]
    }
}

nonisolated enum PanesScene {
    static func draw(_ context: inout GraphicsContext, _ kit: PreviewKit, _ vector: PreviewVector) {
        let v = PanesSceneValues(vector)
        let k = kit.k, p = kit.palette
        kit.stage(&context)
        let win = kit.windowRect(widthFraction: 0.76, heightFraction: 0.72)
        let shape = kit.windowShell(&context, win, fill: p.background.mix(p.chrome, v.rounded))

        // Focus moves between the panes every few seconds.
        let (index, phase) = kit.cycle(3.4)
        let flip = PreviewKit.ease(phase / 0.12)
        let previous = index.truncatingRemainder(dividingBy: 2)
        let focusRight = previous == 0 ? flip : 1 - flip

        let gap = 5 * k * v.rounded
        let radius = 8 * k * v.rounded
        let inner = kit.contentRect(win).insetBy(dx: gap, dy: gap)
        let half = (inner.width - gap) / 2
        let panes = [
            CGRect(x: inner.minX, y: inner.minY, width: half, height: inner.height),
            CGRect(x: inner.minX + half + gap, y: inner.minY, width: half, height: inner.height),
        ]
        // Points the padding setting maps to in the scene.
        let padX = (3 + v.paddingX * 0.42), padY = (3 + v.paddingY * 0.42)

        context.drawLayer { layer in
            layer.clip(to: shape)
            for (paneIndex, pane) in panes.enumerated() {
                let paneShape = Path(roundedRect: pane, cornerRadius: max(radius, 0.01), style: .continuous)
                layer.fill(paneShape, with: .color(p.background.color()))
                let focus = paneIndex == 1 ? focusRight : 1 - focusRight
                layer.drawLayer { paneLayer in
                    paneLayer.clip(to: paneShape)
                    paneLayer.opacity = 0.62 + 0.38 * focus
                    kit.terminal(&paneLayer, in: pane, padX: padX, padY: padY, lineHeight: 9.5, typing: paneIndex == 1)
                }
                if v.paddingMoment > 0.01 {
                    let guide = pane.insetBy(dx: padX * k, dy: padY * k)
                    layer.stroke(Path(roundedRect: guide, cornerRadius: 2 * k),
                                 with: .color(p.accent.color(0.8 * v.paddingMoment)),
                                 style: StrokeStyle(lineWidth: 0.8 * k, dash: [3 * k, 2 * k]))
                }
            }
            // Flush panes share a hairline divider instead of a gap.
            if v.rounded < 0.99 {
                layer.fill(Path(CGRect(x: panes[0].maxX - 0.4 * k, y: inner.minY, width: 0.8 * k, height: inner.height)),
                           with: .color(p.foreground.color(0.16 * (1 - v.rounded))))
            }
            kit.macTitleBar(&layer, win)
        }
        kit.windowEdge(&context, shape)

        // Split focus border around whichever pane has focus.
        if v.borderWidth > 0.01 && v.borderOpacity > 0.01 {
            for (paneIndex, pane) in panes.enumerated() {
                let focus = paneIndex == 1 ? focusRight : 1 - focusRight
                guard focus > 0.01 else { continue }
                let width = v.borderWidth * 0.9 * k
                let rect = pane.insetBy(dx: width / 2, dy: width / 2)
                context.stroke(Path(roundedRect: rect, cornerRadius: max(0.01, radius - width / 2), style: .continuous),
                               with: .color(v.borderColor.color(v.borderOpacity * focus)), lineWidth: width)
            }
        }

        if v.remotePorts > 0.01 {
            drawRemotePorts(&context, kit, v, pane: focusRight > 0.5 ? panes[1] : panes[0])
        }
    }

    /// The globe in the terminal's corner, opening its list of listening ports.
    private static func drawRemotePorts(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: PanesSceneValues, pane: CGRect) {
        let k = kit.k, p = kit.palette
        let alpha = v.remotePorts
        let globe = CGRect(x: pane.maxX - 20 * k, y: pane.maxY - 20 * k, width: 14 * k, height: 14 * k)
        context.drawLayer { layer in
            layer.opacity = alpha
            kit.glass(&layer, globe)
            kit.symbol(&layer, "globe", in: globe.insetBy(dx: 3 * k, dy: 3 * k), color: p.accent)
        }
        let (_, phase) = kit.cycle(5, offset: 1.2)
        let open = PreviewKit.ease((phase - 0.2) / 0.1) * (1 - PreviewKit.ease((phase - 0.7) / 0.1)) * alpha
        guard open > 0.01 else { return }
        let list = CGRect(x: globe.maxX - 58 * k, y: globe.minY - 44 * k * open - 4 * k, width: 58 * k, height: 44 * k * open)
        context.drawLayer { layer in
            layer.opacity = open
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 4 * k, y: 2 * k))
            layer.fill(Path(roundedRect: list, cornerRadius: 7 * k, style: .continuous), with: .color(p.chrome.mix(p.foreground, 0.08).color()))
        }
        context.drawLayer { layer in
            layer.opacity = open
            layer.clip(to: Path(roundedRect: list, cornerRadius: 7 * k))
            for (row, port) in ["3000", "5432", "8080"].enumerated() {
                let y = list.minY + (9 + Double(row) * 12.5) * k
                kit.symbol(&layer, "arrow.up.right.square", in: CGRect(x: list.minX + 6 * k, y: y - 3.5 * k, width: 7 * k, height: 7 * k),
                           color: row == 0 ? p.accent : p.dim)
                kit.label(&layer, port, at: CGPoint(x: list.minX + 17 * k, y: y), size: 6.4, weight: .semibold,
                          color: row == 0 ? p.foreground : p.dim, anchor: .leading)
            }
        }
    }
}

// MARK: - Devices

/// The hardware drawn as itself: the Duo closed (its front display, with a
/// punch-hole camera and the side rail) or open (the fold down the middle),
/// iPhone with its Dynamic Island, iPad in landscape, and a MacBook.
nonisolated struct DeviceFrame {
    let kit: PreviewKit
    let device: PreviewDevice

    var k: Double { kit.k }

    /// The device body, sized to the stage.
    var body: CGRect {
        let w = kit.w, h = kit.h
        let (height, aspect): (Double, Double) = switch device {
        case .phone: (h * 0.84, 0.48)
        case .duoClosed: (h * 0.84, 0.69)
        case .duoOpen: (h * 0.78, 1.18)
        case .pad, .vision: (h * 0.66, 1.42)
        case .mac: (h * 0.62, 1.55)
        }
        let width = min(height * aspect, w * 0.62)
        return CGRect(x: (w - width) / 2, y: h * (device == .mac ? 0.05 : 0.06), width: width, height: width / aspect)
    }

    private var cornerRadius: Double {
        switch device {
        case .phone: 17
        case .duoClosed, .duoOpen: 13
        case .pad, .vision: 11
        case .mac: 6
        }
    }

    /// Bezel, shadows, and (on the Mac) the keyboard deck. Returns the screen.
    func drawBody(_ context: inout GraphicsContext) -> (screen: CGRect, shape: Path) {
        let body = body
        if device == .mac {
            // Aluminum deck under the lid.
            let deck = CGRect(x: body.minX - body.width * 0.07, y: body.maxY, width: body.width * 1.14, height: 5.5 * k)
            kit.windowShell(&context, body, radius: cornerRadius, fill: PreviewRGB(0.08, 0.08, 0.09), groundY: deck.maxY + 3 * k)
            var deckPath = Path()
            deckPath.addRoundedRect(in: deck, cornerSize: CGSize(width: 3 * k, height: 3 * k))
            context.fill(deckPath, with: .linearGradient(Gradient(colors: [PreviewRGB(0.86, 0.87, 0.89).color(), PreviewRGB(0.6, 0.61, 0.64).color()]),
                                                         startPoint: CGPoint(x: deck.midX, y: deck.minY), endPoint: CGPoint(x: deck.midX, y: deck.maxY)))
            context.fill(Path(roundedRect: CGRect(x: deck.midX - 11 * k, y: deck.minY, width: 22 * k, height: 1.8 * k), cornerRadius: 0.9 * k),
                         with: .color(PreviewRGB(0.5, 0.51, 0.54).color()))
            let screen = CGRect(x: body.minX + 3 * k, y: body.minY + 3 * k, width: body.width - 6 * k, height: body.height - 4 * k)
            return (screen, Path(roundedRect: screen, cornerRadius: 3 * k, style: .continuous))
        }
        kit.windowShell(&context, body, radius: cornerRadius, fill: PreviewRGB(0.07, 0.07, 0.08), groundY: body.maxY + 6 * k)
        context.stroke(Path(roundedRect: body, cornerRadius: cornerRadius * k, style: .continuous), with: .color(.white.opacity(0.18)), lineWidth: 0.8 * k)
        let inset = (device == .pad || device == .vision ? 4.5 : 3) * k
        let screen = body.insetBy(dx: inset, dy: inset)
        return (screen, Path(roundedRect: screen, cornerRadius: max(2, cornerRadius - 3) * k, style: .continuous))
    }

    /// Camera hardware drawn over the screen content.
    func drawCamera(_ context: inout GraphicsContext, screen: CGRect) {
        switch device {
        case .phone:
            context.fill(Path(roundedRect: CGRect(x: screen.midX - 11 * k, y: screen.minY + 3.5 * k, width: 22 * k, height: 6.5 * k), cornerRadius: 3.25 * k),
                         with: .color(.black))
        case .duoClosed:
            context.fill(kit.circle(CGPoint(x: screen.maxX - 9 * k, y: screen.minY + 9 * k), 3.6 * k), with: .color(.black))
        case .duoOpen:
            // Inner display camera, in the top middle of the right half.
            context.fill(kit.circle(CGPoint(x: screen.midX + screen.width * 0.25, y: screen.minY + 5 * k), 2.6 * k), with: .color(.black))
            // The fold catches a little light down the middle of the inner display.
            let crease = CGRect(x: screen.midX - 2 * k, y: screen.minY, width: 4 * k, height: screen.height)
            context.fill(Path(crease), with: .linearGradient(Gradient(colors: [.black.opacity(0), .black.opacity(0.22), .white.opacity(0.08), .black.opacity(0.22), .black.opacity(0)]),
                                                             startPoint: CGPoint(x: crease.minX, y: crease.midY), endPoint: CGPoint(x: crease.maxX, y: crease.midY)))
        case .pad, .vision:
            context.fill(kit.circle(CGPoint(x: screen.midX, y: screen.minY - 2.2 * k), 1.1 * k), with: .color(PreviewRGB(0.25, 0.27, 0.3).color()))
        case .mac:
            context.fill(Path(roundedRect: CGRect(x: screen.midX - 9 * k, y: screen.minY - 0.5 * k, width: 18 * k, height: 4.5 * k), cornerRadius: 2 * k),
                         with: .color(.black))
        }
    }
}

// MARK: - Duo front display

nonisolated struct DuoFrontSceneValues: Equatable, Sendable {
    /// `DuoFrontDisplayMode` index: side rail, below camera, behind camera.
    var mode = 0.0
    var showsTabs = 1.0

    var vector: PreviewVector { PreviewVector([mode, showsTabs]) }

    init(mode: Int, showsTabs: Bool) {
        self.mode = Double(mode)
        self.showsTabs = showsTabs ? 1 : 0
    }

    init(_ v: PreviewVector) {
        mode = v[0]; showsTabs = v[1]
    }
}

nonisolated enum DuoFrontScene {
    static func draw(_ context: inout GraphicsContext, _ kit: PreviewKit, _ vector: PreviewVector) {
        let v = DuoFrontSceneValues(vector)
        kit.stage(&context)
        let frame = DeviceFrame(kit: kit, device: .duoClosed)
        let (screen, shape) = frame.drawBody(&context)
        context.drawLayer { layer in
            layer.clip(to: shape)
            drawScreen(&layer, kit, screen: screen, mode: v.mode, showsTabs: v.showsTabs)
        }
        frame.drawCamera(&context, screen: screen)
    }

    /// The closed Duo's front display in each layout, cross-faded by `mode`.
    static func drawScreen(_ context: inout GraphicsContext, _ kit: PreviewKit, screen: CGRect, mode: Double, showsTabs: Double,
                           status: Double = 1, glow: Double = 0) {
        let k = kit.k, p = kit.palette
        context.fill(Path(screen), with: .color(p.background.color()))
        let weights = (0..<3).map { max(0, 1 - abs(mode - Double($0))) }
        let selection = TabBarScene.selection(kit, animationsOff: 0)

        // Side Rail: tabs, the clock, and controls in a rail beside the camera.
        if weights[0] > 0.01 {
            context.drawLayer { layer in
                layer.opacity = weights[0]
                let railWidth = screen.width * 0.2
                let terminal = CGRect(x: screen.minX, y: screen.minY, width: screen.width - railWidth, height: screen.height)
                kit.terminal(&layer, in: terminal, padX: 5, padY: 6, lineHeight: 8, glow: glow)
                let rail = CGRect(x: terminal.maxX, y: screen.minY, width: railWidth, height: screen.height)
                if status > 0.01 {
                    kit.label(&layer, "9:41", at: CGPoint(x: rail.midX, y: rail.minY + 20 * k), size: 5.6, color: p.foreground, opacity: status)
                    kit.symbol(&layer, "wifi", in: CGRect(x: rail.midX - 3.5 * k, y: rail.minY + 26 * k, width: 7 * k, height: 5.5 * k),
                               color: p.foreground, opacity: status)
                }
                let capsule = CGRect(x: rail.midX - 7 * k, y: rail.minY + 38 * k, width: 14 * k, height: 44 * k)
                kit.glass(&layer, capsule)
                kit.symbol(&layer, "plus", in: CGRect(x: capsule.midX - 3 * k, y: capsule.minY + 5 * k, width: 6 * k, height: 6 * k), color: p.foreground)
                let badge = CGRect(x: capsule.midX - 4.5 * k, y: capsule.midY - 4 * k, width: 9 * k, height: 8 * k)
                layer.fill(Path(roundedRect: badge, cornerRadius: 2 * k), with: .color(p.accent.color(0.35)))
                kit.label(&layer, "3", at: CGPoint(x: badge.midX, y: badge.midY), size: 5.4, color: p.foreground)
                kit.symbol(&layer, "gearshape", in: CGRect(x: capsule.midX - 3.2 * k, y: capsule.maxY - 11 * k, width: 6.4 * k, height: 6.4 * k), color: p.foreground)
            }
        }

        // Below Camera: top tabs under the camera band, full width beneath.
        if weights[1] > 0.01 {
            context.drawLayer { layer in
                layer.opacity = weights[1]
                let band = 17 * k
                if status > 0.01 {
                    kit.label(&layer, "9:41", at: CGPoint(x: screen.minX + 8 * k, y: screen.minY + band / 2), size: 5.4,
                              color: p.foreground, opacity: status, anchor: .leading)
                }
                let strip = CGRect(x: screen.minX, y: screen.minY + band, width: screen.width, height: 20 * k)
                layer.fill(Path(strip), with: .color(p.chrome.color()))
                TabStripPainter(kit: kit, k: k * 0.8, selection: selection).paint(&layer, layout: .pills, strip: strip, terminalBelow: true)
                let terminal = CGRect(x: screen.minX, y: strip.maxY, width: screen.width, height: screen.maxY - strip.maxY)
                kit.terminal(&layer, in: terminal, padX: 5, padY: 6, lineHeight: 8, glow: glow)
            }
        }

        // Behind Camera: the terminal runs to the top edge, under the camera;
        // the top tabs, if shown, sit behind it too.
        if weights[2] > 0.01 {
            context.drawLayer { layer in
                layer.opacity = weights[2]
                let stripHeight = 20 * k * showsTabs
                if stripHeight > 0.5 {
                    let strip = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 20 * k)
                    layer.drawLayer { tabs in
                        tabs.opacity = showsTabs
                        tabs.fill(Path(strip), with: .color(p.chrome.color()))
                        TabStripPainter(kit: kit, k: k * 0.8, selection: selection).paint(&tabs, layout: .pills, strip: strip, terminalBelow: true)
                    }
                }
                let terminal = CGRect(x: screen.minX, y: screen.minY + stripHeight, width: screen.width, height: screen.height - stripHeight)
                kit.terminal(&layer, in: terminal, padX: 5, padY: 5, lineHeight: 8, glow: glow)
            }
        }
    }
}

// MARK: - Display

nonisolated struct DisplaySceneValues: Equatable, Sendable {
    var fullScreen = 0.0
    var hasHomeIndicator = 1.0
    var extendUnderHomeIndicator = 0.0
    /// 0 sleeps when idle, 1 stays on for a while, 2 always on.
    var alwaysOn = 0.0
    var brightness = 0.0
    /// Closed Duo only: the front display layout and its top tabs.
    var duoFrontMode = 0.0
    var duoShowsTabs = 1.0

    var vector: PreviewVector {
        PreviewVector([fullScreen, hasHomeIndicator, extendUnderHomeIndicator, alwaysOn, brightness, duoFrontMode, duoShowsTabs])
    }

    init() {}

    init(_ v: PreviewVector) {
        fullScreen = v[0]; hasHomeIndicator = v[1]; extendUnderHomeIndicator = v[2]
        alwaysOn = v[3]; brightness = v[4]; duoFrontMode = v[5]; duoShowsTabs = v[6]
    }
}

nonisolated enum DisplayScene {
    static func draw(_ context: inout GraphicsContext, _ kit: PreviewKit, _ vector: PreviewVector) {
        let v = DisplaySceneValues(vector)
        kit.stage(&context)
        let frame = DeviceFrame(kit: kit, device: kit.device)
        let (screen, screenShape) = frame.drawBody(&context)

        if kit.device == .mac {
            drawMacDesktop(&context, kit, v, screen: screen, shape: screenShape)
            frame.drawCamera(&context, screen: screen)
            drawBoostGlow(&context, kit, v, around: frame.body)
            return
        }

        let k = kit.k, p = kit.palette
        // Idle dimming: off sleeps soon, a duration later, always never.
        let (_, phase) = kit.cycle(7)
        let sleepStart = v.alwaysOn < 0.5 ? 0.38 : 0.62
        let sleepDepth = max(0, 1 - v.alwaysOn / 2) * (v.alwaysOn < 0.5 ? 0.88 : 0.45)
        let dim = kit.reduceMotion ? 0 : sleepDepth * PreviewKit.ease((phase - sleepStart) / 0.1) * (1 - PreviewKit.ease((phase - 0.9) / 0.05))
        let status = 1 - v.fullScreen
        let homeGap = 9 * k * v.hasHomeIndicator * (1 - v.extendUnderHomeIndicator)

        context.drawLayer { layer in
            layer.clip(to: screenShape)
            layer.fill(screenShape, with: .color(p.chrome.color()))
            let usable = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - homeGap)
            if kit.device == .duoClosed {
                DuoFrontScene.drawScreen(&layer, kit, screen: usable, mode: v.duoFrontMode, showsTabs: v.duoShowsTabs,
                                         status: status, glow: v.brightness)
            } else {
                let isTablet = kit.device == .pad || kit.device == .duoOpen || kit.device == .vision
                let statusHeight = 13 * k * status
                let content = CGRect(x: usable.minX, y: usable.minY + statusHeight, width: usable.width, height: usable.height - statusHeight)
                layer.fill(Path(content), with: .color(p.background.color()))
                kit.terminal(&layer, in: content, padX: isTablet ? 8 : 6, padY: 7, lineHeight: isTablet ? 9 : 8.5, glow: v.brightness)
                if status > 0.01 {
                    // On iPhone the clock and icons sit in the ears beside the Dynamic Island.
                    let y = screen.minY + 7 * k
                    let ear = kit.device == .phone ? (screen.width / 2 - 11 * k) / 2 : 14 * k
                    kit.label(&layer, "9:41", at: CGPoint(x: screen.minX + ear, y: y), size: 5.6, color: p.foreground, opacity: status)
                    let iconsX = screen.maxX - ear
                    kit.symbol(&layer, "wifi", in: CGRect(x: iconsX - 8 * k, y: y - 2.6 * k, width: 6.5 * k, height: 5.2 * k), color: p.foreground, opacity: status)
                    kit.symbol(&layer, "battery.75percent", in: CGRect(x: iconsX - 0.5 * k, y: y - 2.4 * k, width: 9 * k, height: 4.8 * k), color: p.foreground, opacity: status)
                }
            }
            if v.hasHomeIndicator > 0.5 {
                let indicator = CGRect(x: screen.midX - screen.width * 0.17, y: screen.maxY - 5 * k, width: screen.width * 0.34, height: 2.2 * k)
                layer.fill(Path(roundedRect: indicator, cornerRadius: 1.1 * k), with: .color(p.foreground.color(0.75)))
            }
        }
        frame.drawCamera(&context, screen: screen)
        if dim > 0.01 {
            context.fill(screenShape, with: .color(.black.opacity(dim)))
        }
        drawBoostGlow(&context, kit, v, around: frame.body)
        drawIdleBadge(&context, kit, v, beside: frame.body, phase: phase, sleepStart: sleepStart)
    }

    /// macOS: a menu bar over a tinted desktop, with the terminal window on it.
    private static func drawMacDesktop(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: DisplaySceneValues, screen: CGRect, shape: Path) {
        let k = kit.k, p = kit.palette
        context.drawLayer { layer in
            layer.clip(to: shape)
            layer.fill(Path(screen), with: .linearGradient(Gradient(colors: [p.accent.mix(.black, 0.35).color(), p.accent.mix(.black, 0.7).color()]),
                                                           startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
            let menuBar = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 6 * k)
            layer.fill(Path(menuBar), with: .color(.white.opacity(0.14)))
            kit.symbol(&layer, "apple.logo", in: CGRect(x: menuBar.minX + 4 * k, y: menuBar.minY + 1.2 * k, width: 3.4 * k, height: 3.6 * k), color: .white, opacity: 0.85)
            for (index, width) in [10.0, 8, 9].enumerated() {
                kit.bar(&layer, x: menuBar.minX + (12 + Double(index) * 13) * k, y: menuBar.midY, width: width * k, height: 1.8, color: .white, opacity: 0.6)
            }
            let window = CGRect(x: screen.minX + screen.width * 0.12, y: menuBar.maxY + 6 * k, width: screen.width * 0.76, height: screen.height - menuBar.height - 12 * k)
            let windowShape = Path(roundedRect: window, cornerRadius: 5 * k, style: .continuous)
            layer.drawLayer { shadowed in
                shadowed.addFilter(.shadow(color: .black.opacity(0.4), radius: 4 * k, y: 2 * k))
                shadowed.fill(windowShape, with: .color(p.background.color()))
            }
            layer.drawLayer { inside in
                inside.clip(to: windowShape)
                let titleHeight = 9 * k
                let content = CGRect(x: window.minX, y: window.minY + titleHeight, width: window.width, height: window.height - titleHeight)
                kit.terminal(&inside, in: content, padX: 5, padY: 5, lineHeight: 7.5, glow: v.brightness)
                inside.fill(Path(CGRect(x: window.minX, y: window.minY, width: window.width, height: titleHeight)), with: .color(p.chrome.color()))
                let colors = [PreviewRGB(1, 0.37, 0.34), PreviewRGB(1, 0.74, 0.18), PreviewRGB(0.16, 0.78, 0.25)]
                for (index, color) in colors.enumerated() {
                    inside.fill(kit.circle(CGPoint(x: window.minX + (5 + Double(index) * 5) * k, y: window.minY + titleHeight / 2), 1.6 * k),
                                with: .color(color.color()))
                }
            }
        }
    }

    /// A warm bloom behind the device that grows with the brightness boost.
    private static func drawBoostGlow(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: DisplaySceneValues, around rect: CGRect) {
        let k = kit.k
        guard v.brightness > 0.01 else { return }
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.fill(Path(ellipseIn: rect.insetBy(dx: -24 * k * v.brightness, dy: -18 * k * v.brightness)),
                       with: .radialGradient(Gradient(colors: [kit.palette.yellow.mix(.white, 0.4).color(0.25 * v.brightness), .clear]),
                                             center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                                             endRadius: max(rect.width, rect.height) * 0.8))
        }
    }

    /// A glass badge beside the device for the Always On Display choice.
    private static func drawIdleBadge(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: DisplaySceneValues,
                                      beside device: CGRect, phase: Double, sleepStart: Double) {
        let k = kit.k, p = kit.palette
        let badge = CGRect(x: device.maxX + 14 * k, y: device.minY + 8 * k, width: 22 * k, height: 22 * k)
        kit.glass(&context, badge)
        let name = v.alwaysOn > 1.5 ? "infinity" : (v.alwaysOn > 0.5 ? "timer" : "moon.zzz.fill")
        kit.symbol(&context, name, in: badge.insetBy(dx: 5.5 * k, dy: 5.5 * k), color: p.accent)
        // The countdown to sleep, drawn as a ring around the badge.
        guard v.alwaysOn < 1.5, !kit.reduceMotion else { return }
        let progress = min(1, phase / sleepStart)
        var ring = Path()
        ring.addArc(center: CGPoint(x: badge.midX, y: badge.midY), radius: badge.width / 2 + 2.5 * k,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * progress), clockwise: false)
        context.stroke(ring, with: .color(p.accent.color(0.8)), style: StrokeStyle(lineWidth: 1.4 * k, lineCap: .round))
    }
}

// MARK: - Text Selection

nonisolated struct SelectionSceneValues: Equatable, Sendable {
    var selectionForeground = PreviewRGB(0.12, 0.12, 0.18)
    var selectionBackground = PreviewRGB(0.96, 0.88, 0.86)
    var copyOnSelect = 0.0
    var nativeLoupe = 0.0
    /// 1 on touch screens (finger and loupe), 0 with a pointer.
    var touch = 1.0

    var vector: PreviewVector {
        PreviewVector(selectionForeground.components + selectionBackground.components + [copyOnSelect, nativeLoupe, touch])
    }

    init() {}

    init(_ v: PreviewVector) {
        selectionForeground = PreviewRGB(v[0], v[1], v[2])
        selectionBackground = PreviewRGB(v[3], v[4], v[5])
        copyOnSelect = v[6]; nativeLoupe = v[7]; touch = v[8]
    }
}

nonisolated enum SelectionScene {
    static func draw(_ context: inout GraphicsContext, _ kit: PreviewKit, _ vector: PreviewVector) {
        let v = SelectionSceneValues(vector)
        let k = kit.k
        kit.stage(&context)
        let win = kit.windowRect()
        let shape = kit.windowShell(&context, win)
        let content = kit.contentRect(win)
        let lines = kit.terminalRuns(in: content)
        guard lines.count > 3 else { return }
        let target = lines[lines.count - 4]
        let startX = target.first?.rect.minX ?? win.minX
        let endX = target.last?.rect.maxX ?? win.maxX
        let lineY = target.first?.rect.midY ?? win.midY

        // Press, drag across the line, let go, then the selection clears.
        let (_, phase) = kit.cycle(6)
        let drag = kit.reduceMotion ? 1 : PreviewKit.ease((phase - 0.14) / 0.36)
        let present = kit.reduceMotion ? 1 : PreviewKit.ease(phase / 0.1) * (1 - PreviewKit.ease((phase - 0.86) / 0.08))
        let released = kit.reduceMotion ? 1 : PreviewKit.ease((phase - 0.54) / 0.06)
        let selectionEnd = startX + (endX - startX) * drag

        context.drawLayer { layer in
            layer.clip(to: shape)
            kit.terminal(&layer, in: content, typing: false)
            kit.macTitleBar(&layer, win)
            // Selected text, in the selection colors.
            if present > 0.01 && drag > 0.01 {
                let highlight = CGRect(x: startX - 2 * k, y: lineY - 4.6 * k, width: selectionEnd - startX + 4 * k, height: 9.2 * k)
                layer.fill(Path(roundedRect: highlight, cornerRadius: 1.5 * k), with: .color(v.selectionBackground.color(present)))
                layer.drawLayer { selected in
                    selected.clip(to: Path(highlight))
                    selected.opacity = present
                    kit.drawRuns(&selected, target.map { PreviewTextRun(color: v.selectionForeground, rect: $0.rect) }, opacity: 1)
                }
            }
        }
        kit.windowEdge(&context, shape)

        let hand = CGPoint(x: selectionEnd, y: lineY + (v.touch > 0.5 ? 9 * k : 2 * k))
        if v.touch > 0.5 {
            let holding = present * (1 - released)
            if holding > 0.01 {
                kit.touch(&context, at: hand, opacity: holding)
                drawLoupe(&context, kit, v, lines: lines, focus: CGPoint(x: selectionEnd, y: lineY), selectionStart: startX, opacity: holding)
            }
        } else {
            kit.pointer(&context, tip: CGPoint(x: selectionEnd, y: lineY), opacity: present)
        }

        let feedback = released * present
        if feedback > 0.01 {
            drawFeedback(&context, kit, v, above: CGRect(x: startX, y: lineY - 5 * k, width: endX - startX, height: 10 * k), opacity: feedback)
        }
    }

    /// Magnifies the text under the finger: the app's own loupe, or the system one.
    private static func drawLoupe(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: SelectionSceneValues,
                                  lines: [[PreviewTextRun]], focus: CGPoint, selectionStart: Double, opacity: Double) {
        let k = kit.k, p = kit.palette
        let native = v.nativeLoupe
        let width = (52 + 6 * native) * k, height = (24 - 4 * native) * k
        let frame = CGRect(x: focus.x - width / 2, y: focus.y - height - 14 * k, width: width, height: height)
        let radius = native > 0.5 ? height / 2 : 7 * k
        let shape = Path(roundedRect: frame, cornerRadius: radius, style: .continuous)
        context.drawLayer { layer in
            layer.opacity = opacity
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 4 * k, y: 2 * k))
            layer.fill(shape, with: .color(p.background.color()))
        }
        context.drawLayer { layer in
            layer.opacity = opacity
            layer.clip(to: shape)
            let zoom = 1.7
            layer.translateBy(x: frame.midX, y: frame.midY)
            layer.scaleBy(x: zoom, y: zoom)
            layer.translateBy(x: -focus.x, y: -focus.y)
            for line in lines {
                for run in line {
                    let selected = abs(run.rect.midY - focus.y) < 1 && run.rect.minX < focus.x
                    if selected {
                        layer.fill(Path(CGRect(x: max(run.rect.minX, selectionStart) - 1 * k, y: run.rect.midY - 4.6 * k,
                                               width: min(run.rect.maxX, focus.x) - max(run.rect.minX, selectionStart) + 2 * k, height: 9.2 * k)),
                                   with: .color(v.selectionBackground.color()))
                    }
                    layer.fill(Path(roundedRect: run.rect, cornerRadius: run.rect.height / 2),
                               with: .color((selected ? v.selectionForeground : run.color).color(0.9)))
                }
            }
        }
        if native > 0.5 {
            context.stroke(shape, with: .color(.white.opacity(0.35 * opacity)), lineWidth: 0.8 * k)
        } else {
            context.stroke(shape, with: .color(p.accent.color(0.9 * opacity)), lineWidth: 1.2 * k)
        }
    }

    /// After letting go: a Copied badge with Copy on Select, else the edit menu.
    private static func drawFeedback(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: SelectionSceneValues,
                                     above line: CGRect, opacity: Double) {
        let k = kit.k, p = kit.palette
        let copied = v.copyOnSelect
        if copied > 0.01 {
            let badge = CGRect(x: line.midX - 20 * k, y: line.minY - 20 * k, width: 40 * k, height: 14 * k)
            context.drawLayer { layer in
                layer.opacity = opacity * copied
                kit.glass(&layer, badge, tint: p.accent)
                kit.symbol(&layer, "doc.on.doc.fill", in: CGRect(x: badge.minX + 6 * k, y: badge.midY - 3.5 * k, width: 6 * k, height: 7 * k), color: p.accent)
                kit.symbol(&layer, "checkmark", in: CGRect(x: badge.maxX - 15 * k, y: badge.midY - 3 * k, width: 7 * k, height: 6 * k), color: p.green)
                kit.bar(&layer, x: badge.minX + 15 * k, y: badge.midY, width: 6 * k, height: 2.6, color: p.foreground, opacity: 0.8)
            }
        }
        if copied < 0.99 {
            let menu = CGRect(x: line.midX - 30 * k, y: line.minY - 22 * k, width: 60 * k, height: 15 * k)
            context.drawLayer { layer in
                layer.opacity = opacity * (1 - copied)
                layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 4 * k, y: 2 * k))
                layer.fill(Path(roundedRect: menu, cornerRadius: menu.height / 2), with: .color(PreviewRGB(0.16, 0.16, 0.18).color()))
            }
            context.drawLayer { layer in
                layer.opacity = opacity * (1 - copied)
                kit.bar(&layer, x: menu.minX + 9 * k, y: menu.midY, width: 16 * k, height: 3, color: .white, opacity: 0.9)
                layer.fill(Path(CGRect(x: menu.midX - 0.3 * k, y: menu.minY + 4 * k, width: 0.6 * k, height: menu.height - 8 * k)),
                           with: .color(.white.opacity(0.3)))
                kit.bar(&layer, x: menu.midX + 6 * k, y: menu.midY, width: 18 * k, height: 3, color: .white, opacity: 0.9)
            }
        }
    }
}
