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

        context.drawLayer { layer in
            layer.clip(to: shape)
            kit.terminal(&layer, in: win)
            if v.sidebar > 0.5 {
                drawSidebar(&layer, kit, v, window: win, phase: phase)
            } else {
                drawSheet(&layer, kit, v, window: win, phase: phase)
            }
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
                kit.touch(&context, at: CGPoint(x: rect.midX + 10 * k, y: rect.midY), opacity: tap, pressed: tap)
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
        let inner = win.insetBy(dx: gap, dy: gap)
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

// MARK: - Display

nonisolated struct DisplaySceneValues: Equatable, Sendable {
    /// 0 phone, 1 tablet, 2 Mac window.
    var device = 0.0
    var fullScreen = 0.0
    var hasHomeIndicator = 1.0
    var extendUnderHomeIndicator = 0.0
    /// 0 sleeps when idle, 1 stays on for a while, 2 always on.
    var alwaysOn = 0.0
    var brightness = 0.0

    var vector: PreviewVector {
        PreviewVector([device, fullScreen, hasHomeIndicator, extendUnderHomeIndicator, alwaysOn, brightness])
    }

    init() {}

    init(_ v: PreviewVector) {
        device = v[0]; fullScreen = v[1]; hasHomeIndicator = v[2]; extendUnderHomeIndicator = v[3]
        alwaysOn = v[4]; brightness = v[5]
    }
}

nonisolated enum DisplayScene {
    static func draw(_ context: inout GraphicsContext, _ kit: PreviewKit, _ vector: PreviewVector) {
        let v = DisplaySceneValues(vector)
        let k = kit.k, p = kit.palette
        kit.stage(&context)

        if v.device > 1.5 {
            // Mac: only the brightness boost applies.
            let win = kit.windowRect()
            let shape = kit.windowShell(&context, win)
            context.drawLayer { layer in
                layer.clip(to: shape)
                kit.terminal(&layer, in: win, glow: v.brightness)
            }
            kit.windowEdge(&context, shape)
            drawBoostRays(&context, kit, v, around: win)
            return
        }

        let isTablet = v.device > 0.5
        let deviceHeight = kit.h * (isTablet ? 0.66 : 0.84)
        let deviceWidth = isTablet ? deviceHeight * 1.42 : deviceHeight * 0.48
        let body = CGRect(x: (kit.w - deviceWidth) / 2, y: kit.h * 0.06, width: deviceWidth, height: deviceHeight)
        let bezel = Path(roundedRect: body, cornerRadius: (isTablet ? 11 : 17) * k, style: .continuous)
        kit.windowShell(&context, body, radius: isTablet ? 11 : 17, fill: PreviewRGB(0.07, 0.07, 0.08), groundY: body.maxY + 6 * k)
        context.stroke(bezel, with: .color(.white.opacity(0.18)), lineWidth: 0.8 * k)
        let screen = body.insetBy(dx: 3 * k, dy: 3 * k)
        let screenShape = Path(roundedRect: screen, cornerRadius: (isTablet ? 8.5 : 14.5) * k, style: .continuous)

        // Idle dimming: off sleeps soon, a duration later, always never.
        let (_, phase) = kit.cycle(7)
        let sleepStart = v.alwaysOn < 0.5 ? 0.38 : 0.62
        let sleepDepth = max(0, 1 - v.alwaysOn / 2) * (v.alwaysOn < 0.5 ? 0.88 : 0.45)
        let dim = kit.reduceMotion ? 0 : sleepDepth * PreviewKit.ease((phase - sleepStart) / 0.1) * (1 - PreviewKit.ease((phase - 0.9) / 0.05))

        let statusHeight = 13 * k * (1 - v.fullScreen)
        let homeGap = 10 * k * v.hasHomeIndicator * (1 - v.extendUnderHomeIndicator)
        let content = CGRect(x: screen.minX, y: screen.minY + statusHeight + 2 * k * (1 - v.fullScreen),
                             width: screen.width, height: screen.height - statusHeight - homeGap - 2 * k * (1 - v.fullScreen))

        context.drawLayer { layer in
            layer.clip(to: screenShape)
            layer.fill(screenShape, with: .color(p.chrome.color()))
            layer.fill(Path(content), with: .color(p.background.color()))
            kit.terminal(&layer, in: content, padX: isTablet ? 8 : 6, padY: 7, lineHeight: isTablet ? 9 : 8.5, glow: v.brightness)

            // Status bar.
            let status = 1 - v.fullScreen
            if status > 0.01 {
                let y = screen.minY + 7 * k
                kit.label(&layer, "9:41", at: CGPoint(x: screen.minX + (isTablet ? 14 : 12) * k, y: y), size: 5.6, weight: .semibold,
                          color: p.foreground, opacity: status, anchor: .leading)
                kit.symbol(&layer, "wifi", in: CGRect(x: screen.maxX - 22 * k, y: y - 2.6 * k, width: 6.5 * k, height: 5.2 * k), color: p.foreground, opacity: status)
                kit.symbol(&layer, "battery.75percent", in: CGRect(x: screen.maxX - 14 * k, y: y - 2.4 * k, width: 9 * k, height: 4.8 * k), color: p.foreground, opacity: status)
            }
            if !isTablet {
                // Camera housing.
                layer.fill(Path(roundedRect: CGRect(x: screen.midX - 11 * k, y: screen.minY + 3.5 * k, width: 22 * k, height: 6.5 * k), cornerRadius: 3.25 * k),
                           with: .color(.black))
            }
            if v.hasHomeIndicator > 0.5 {
                let indicator = CGRect(x: screen.midX - screen.width * 0.17, y: screen.maxY - 5 * k, width: screen.width * 0.34, height: 2.2 * k)
                layer.fill(Path(roundedRect: indicator, cornerRadius: 1.1 * k), with: .color(p.foreground.color(0.75)))
            }
            if dim > 0.01 {
                layer.fill(screenShape, with: .color(.black.opacity(dim)))
            }
        }
        drawBoostRays(&context, kit, v, around: body)
        drawIdleBadge(&context, kit, v, beside: body, phase: phase, sleepStart: sleepStart)
    }

    /// Sun rays behind the device that grow with the brightness boost.
    private static func drawBoostRays(_ context: inout GraphicsContext, _ kit: PreviewKit, _ v: DisplaySceneValues, around rect: CGRect) {
        let k = kit.k
        guard v.brightness > 0.01 else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.fill(Path(ellipseIn: rect.insetBy(dx: -24 * k * v.brightness, dy: -18 * k * v.brightness)),
                       with: .radialGradient(Gradient(colors: [kit.palette.yellow.mix(.white, 0.4).color(0.25 * v.brightness), .clear]),
                                             center: center, startRadius: 0, endRadius: max(rect.width, rect.height) * 0.8))
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
        let lines = kit.terminalRuns(in: win)
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
            kit.terminal(&layer, in: win, typing: false)
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
