#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit

@MainActor
extension TerminalTouchSteampunkMechanics.RGB {
    init(_ color: UIColor, traits: UITraitCollection) {
        let color = color.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            _ = color.getWhite(&r, alpha: &a); g = r; b = r
        }
        self.init(Double(r), Double(g), Double(b))
    }
    var ui: UIColor { UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }
}

/// Cached, resolution-independent instrument parts. No glyphs are baked into
/// textures; typing only swaps prepared images and transforms retained layers.
@MainActor
enum TerminalTouchSteampunkArtwork {
    typealias RGB = TerminalTouchSteampunkMechanics.RGB
    enum Role: Int { case letter, utility, toolbar, preview }
    static let padding: CGFloat = 5

    struct Material: Equatable {
        let face: RGB
        let ink: RGB
        let brass: RGB
        let steel: RGB
        let highContrast: Bool
        var minimumContrast: Double { highContrast ? 7 : 4.5 }
        var key: String { "\(face.cacheKey)/\(ink.cacheKey)/\(brass.cacheKey)/\(steel.cacheKey)/\(highContrast)" }

        @MainActor
        init(palette: TerminalTouchKeyboardPalette?, traits: UITraitCollection, utility: Bool = false, selected: Bool = false) {
            highContrast = UIAccessibility.isDarkerSystemColorsEnabled || traits.accessibilityContrast == .high
            let dark = palette.map { !$0.isLight } ?? (traits.userInterfaceStyle == .dark)
            let ivory = RGB(0.90, 0.85, 0.72)
            let enamel = RGB(0.105, 0.14, 0.145)
            let base: RGB
            let preferred: RGB
            if let palette {
                base = RGB(selected ? palette.ink : palette.key, traits: traits)
                preferred = RGB(selected ? palette.key : palette.ink, traits: traits)
            } else {
                base = selected ? RGB(0.89, 0.65, 0.28) : (utility || dark ? enamel : ivory)
                preferred = base.luminance < 0.25 ? ivory : RGB(0.11, 0.075, 0.04)
            }
            // High Contrast gets a light or dark face, not merely a brighter rim.
            let face = highContrast ? (base.luminance < 0.32 ? RGB(0.045, 0.055, 0.06) : RGB(0.97, 0.95, 0.90)) : base
            self.face = face
            ink = face.ink(preferred: preferred, minimum: highContrast ? 7 : 4.5)
            brass = RGB(0.68, 0.43, 0.19)
            steel = dark ? RGB(0.075, 0.085, 0.085) : RGB(0.19, 0.18, 0.15)
        }
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let value = NSCache<NSString, UIImage>()
        value.countLimit = 180
        value.totalCostLimit = 16 * 1024 * 1024
        return value
    }()

    private static func image(_ key: String, size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> UIImage? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
              size.width > 1, size.height > 1, size.width * scale <= 8192, size.height * scale <= 8192,
              size.width * size.height * scale * scale <= 4_194_304 else { return nil }
        let cacheKey = "\(key)/\(size.width)/\(size.height)/\(scale)" as NSString
        if let existing = cache.object(forKey: cacheKey) { return existing }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let result = UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
        let cost = result.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(result, forKey: cacheKey, cost: cost)
        return result
    }

    static func cap(size: CGSize, scale: CGFloat, material: Material, role: Role, pressed: Bool) -> UIImage? {
        guard size.width.isFinite, size.height.isFinite, size.width > 6, size.height > 6,
              scale.isFinite, scale > 0 else { return nil }
        let size = CGSize(width: ceil(size.width * scale) / scale, height: ceil(size.height * scale) / scale)
        let imageSize = CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
        return image("cap/\(material.key)/\(role.rawValue)/\(pressed)", size: imageSize, scale: scale) { c in
            let outer = CGRect(origin: CGPoint(x: padding, y: padding), size: size)
            let radius = radius(size: size, role: role)
            let depth: CGFloat = pressed ? 0.4 : (role == .toolbar ? 1.3 : 2.3)
            let skirt = UIBezierPath(roundedRect: outer.offsetBy(dx: 0, dy: depth), cornerRadius: radius)
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: 1), blur: pressed ? 1 : 2.5,
                        color: UIColor.black.withAlphaComponent(0.65).cgColor)
            UIColor(white: 0.035, alpha: 1).setFill(); skirt.fill()
            c.restoreGState()
            let outline = UIBezierPath(roundedRect: outer, cornerRadius: radius)
            c.saveGState(); outline.addClip()
            linear(c, colors: [RGB(0.97, 0.83, 0.51).ui, material.brass.ui, RGB(0.28, 0.15, 0.055).ui,
                               RGB(0.80, 0.62, 0.31).ui], stops: [0, 0.36, 0.76, 1], rect: outer)
            c.restoreGState()
            // Recessed concentric ferrules: rolled brass, black gasket, porcelain.
            let gasket = outer.insetBy(dx: 1.6, dy: 1.6)
            fill(c, rect: gasket, radius: max(0, radius - 1.6), color: RGB(0.16, 0.10, 0.04).ui)
            let face = outer.insetBy(dx: 2.8, dy: 2.8)
            let facePath = UIBezierPath(roundedRect: face, cornerRadius: max(0, radius - 2.8))
            c.saveGState(); facePath.addClip()
            let top = material.face.lit(toward: pressed ? .black : .white, amount: pressed ? 0.035 : 0.065,
                                       ink: material.ink, minimum: material.minimumContrast)
            let bottom = material.face.lit(toward: .black, amount: pressed ? 0.025 : 0.065,
                                          ink: material.ink, minimum: material.minimumContrast)
            linear(c, colors: [top.ui, material.face.ui, material.face.ui, bottom.ui],
                   stops: [0, 0.25, 0.73, 1], rect: face)
            c.restoreGState()
            stroke(c, path: outline, color: UIColor.black.withAlphaComponent(0.72), width: 1 / scale)
            stroke(c, path: UIBezierPath(roundedRect: outer.insetBy(dx: 0.65, dy: 0.65), cornerRadius: max(0, radius - 0.65)),
                   color: RGB(0.98, 0.86, 0.59).ui.withAlphaComponent(pressed ? 0.38 : 0.70), width: 0.5)
            stroke(c, path: facePath, color: material.highContrast ? material.ink.ui : UIColor.black.withAlphaComponent(0.38),
                   width: material.highContrast ? 1 : 0.6)
            // Fine tool marks are clipped to the annular brass band, never the face.
            if !material.highContrast {
                c.saveGState()
                let band = UIBezierPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, radius - 0.5))
                band.append(UIBezierPath(roundedRect: gasket, cornerRadius: max(0, radius - 1.6)))
                band.usesEvenOddFillRule = true; band.addClip()
                c.setStrokeColor(UIColor.white.withAlphaComponent(0.17).cgColor); c.setLineWidth(0.4)
                for i in 0..<Int(ceil(outer.width / 3)) {
                    let x = outer.minX + CGFloat(i) * 3
                    c.move(to: CGPoint(x: x, y: outer.minY)); c.addLine(to: CGPoint(x: x - 5, y: outer.maxY))
                }
                c.strokePath(); c.restoreGState()
            }
            if role == .utility || role == .toolbar {
                // Wide utility keys have inset fasteners rather than shrunken legends.
                if outer.width > 54 {
                    screw(c, center: CGPoint(x: outer.minX + 4.2, y: outer.midY), radius: 1.1, angle: 0.7)
                    screw(c, center: CGPoint(x: outer.maxX - 4.2, y: outer.midY), radius: 1.1, angle: -0.7)
                }
            }
        }
    }

    static func radius(size: CGSize, role: Role) -> CGFloat {
        role == .letter || role == .preview ? min(size.width, size.height) * 0.44 : min(8, min(size.width, size.height) * 0.28)
    }

    static func gear(radius: CGFloat, teeth: Int, scale: CGFloat, copper: Bool) -> UIImage? {
        let extent = ceil(radius + 4)
        return image("gear/\(teeth)/\(copper)/\(radius)", size: CGSize(width: extent * 2, height: extent * 2), scale: scale) { c in
            c.translateBy(x: extent, y: extent)
            let gear = UIBezierPath()
            for tooth in 0..<teeth {
                for (part, radial): (Int, CGFloat) in [(0, 0.87), (1, 0.88), (2, 1), (4, 1), (5, 0.88), (6, 0.87)] {
                    let a = (CGFloat(tooth) + CGFloat(part) / 6) * 2 * .pi / CGFloat(teeth)
                    let p = CGPoint(x: cos(a) * radius * radial, y: sin(a) * radius * radial)
                    if tooth == 0 && part == 0 { gear.move(to: p) } else { gear.addLine(to: p) }
                }
            }
            gear.close()
            // Five pierced spokes, with light showing through to the engine bed.
            for spoke in 0..<5 {
                let a = CGFloat(spoke) * 2 * .pi / 5
                let hole = UIBezierPath(ovalIn: CGRect(x: radius * 0.28, y: -radius * 0.13,
                                                      width: radius * 0.43, height: radius * 0.26))
                hole.apply(CGAffineTransform(rotationAngle: a)); gear.append(hole)
            }
            gear.usesEvenOddFillRule = true
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: 1.2), blur: 1.8, color: UIColor.black.withAlphaComponent(0.8).cgColor)
            RGB(0.25, 0.16, 0.07).ui.setFill(); gear.fill()
            c.restoreGState()
            c.saveGState(); gear.addClip()
            let mid = copper ? RGB(0.56, 0.26, 0.13) : RGB(0.60, 0.43, 0.20)
            linear(c, colors: [RGB(0.95, 0.80, 0.46).ui, mid.ui, RGB(0.24, 0.16, 0.08).ui, mid.ui],
                   stops: [0, 0.37, 0.83, 1], rect: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            c.restoreGState()
            stroke(c, path: gear, color: RGB(0.94, 0.77, 0.43).ui.withAlphaComponent(0.8), width: 0.55)
            // Machined circumferential grooves and engraved tooth-registration marks.
            for factor: CGFloat in [0.77, 0.81] {
                let ring = UIBezierPath(ovalIn: CGRect(x: -radius * factor, y: -radius * factor, width: radius * factor * 2, height: radius * factor * 2))
                stroke(c, path: ring, color: UIColor.black.withAlphaComponent(0.45), width: 0.55)
            }
            for i in 0..<teeth {
                let a = CGFloat(i) * 2 * .pi / CGFloat(teeth)
                line(c, from: CGPoint(x: cos(a) * radius * 0.83, y: sin(a) * radius * 0.83),
                     to: CGPoint(x: cos(a) * radius * 0.86, y: sin(a) * radius * 0.86),
                     color: RGB(1, 0.88, 0.56).ui.withAlphaComponent(0.65), width: 0.5)
            }
            screw(c, center: .zero, radius: max(2, radius * 0.16), angle: 0.4)
        }
    }

    static func bed(size: CGSize, scale: CGFloat, material: Material, rows: [CGRect], banks: [CGFloat], solid: Bool) -> UIImage? {
        let geometryKey = rows.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }.joined(separator: ";")
        return image("bed/\(material.key)/\(geometryKey)/\(banks)/\(solid)", size: size, scale: scale) { c in
            let bounds = CGRect(origin: .zero, size: size)
            // A tinted cutaway, not an opaque replacement for the floating glass.
            fill(c, rect: bounds, radius: 0, color: material.steel.ui.withAlphaComponent(solid ? 1 : 0.78))
            if !material.highContrast {
                c.setLineWidth(0.35)
                for y in stride(from: CGFloat(1), to: size.height, by: 3) {
                    c.setStrokeColor(UIColor.white.withAlphaComponent(Int(y) % 2 == 0 ? 0.025 : 0.045).cgColor)
                    c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: size.width, y: y)); c.strokePath()
                }
            }
            for (i, band) in rows.enumerated() {
                let y = band.maxY - 1
                let rail = CGRect(x: band.minX + 4, y: y - 1.4, width: max(0, band.width - 8), height: 2.8)
                fill(c, rect: rail, radius: 1.4, color: RGB(0.12, 0.085, 0.045).ui)
                line(c, from: CGPoint(x: rail.minX, y: y - 0.8), to: CGPoint(x: rail.maxX, y: y - 0.8),
                     color: material.brass.ui.withAlphaComponent(0.8), width: 0.7)
                for x in stride(from: band.minX + 10, through: band.maxX - 10, by: 44) {
                    screw(c, center: CGPoint(x: x, y: y), radius: 1.45, angle: CGFloat(i) * 0.7 + x * 0.03)
                }
            }
            // Oil channels, copper pipe elbows, and compression collars frame
            // the drive trains; these all live behind the original hit cells.
            for x in banks {
                let top = rows.first?.minY ?? 0
                let bottom = rows.last?.maxY ?? size.height
                let pipe = UIBezierPath()
                pipe.move(to: CGPoint(x: x - 21, y: top + 7))
                pipe.addLine(to: CGPoint(x: x - 21, y: bottom - 13))
                pipe.addQuadCurve(to: CGPoint(x: x - 14, y: bottom - 6), controlPoint: CGPoint(x: x - 21, y: bottom - 6))
                pipe.addLine(to: CGPoint(x: x + 17, y: bottom - 6))
                stroke(c, path: pipe, color: RGB(0.075, 0.045, 0.025).ui, width: 4)
                stroke(c, path: pipe, color: RGB(0.47, 0.24, 0.12).ui, width: 2.8)
                stroke(c, path: pipe, color: RGB(0.87, 0.54, 0.28).ui.withAlphaComponent(0.7), width: 0.65)
                for y in [top + 12, bottom - 19] {
                    fill(c, rect: CGRect(x: x - 24, y: y, width: 6, height: 4), radius: 0.7, color: material.brass.ui)
                    line(c, from: CGPoint(x: x - 24, y: y + 1), to: CGPoint(x: x - 18, y: y + 1), color: RGB(0.92, 0.77, 0.48).ui, width: 0.5)
                }
            }
        }
    }

    static func gauge(diameter: CGFloat, scale: CGFloat) -> UIImage? {
        image("gauge", size: CGSize(width: diameter, height: diameter), scale: scale) { c in
            let r = diameter / 2
            let circle = CGRect(x: 1, y: 1, width: diameter - 2, height: diameter - 2)
            fill(c, rect: circle, radius: r, color: RGB(0.66, 0.43, 0.19).ui)
            fill(c, rect: circle.insetBy(dx: 1.4, dy: 1.4), radius: r, color: RGB(0.88, 0.84, 0.69).ui)
            for index in 0...12 {
                let angle = (-0.78 + CGFloat(index) / 12 * 1.56) * .pi
                let outer = CGPoint(x: r + sin(angle) * r * 0.68, y: r - cos(angle) * r * 0.68)
                let inner = CGPoint(x: r + sin(angle) * r * (index % 3 == 0 ? 0.47 : 0.57), y: r - cos(angle) * r * (index % 3 == 0 ? 0.47 : 0.57))
                line(c, from: inner, to: outer, color: index > 9 ? RGB(0.60, 0.19, 0.07).ui : RGB(0.19, 0.14, 0.08).ui, width: 0.65)
            }
            screw(c, center: CGPoint(x: r, y: r), radius: 1.1, angle: 0.8)
            let glass = UIBezierPath(arcCenter: CGPoint(x: r, y: r), radius: r - 2.7, startAngle: -.pi * 0.95, endAngle: -.pi * 0.35, clockwise: true)
            stroke(c, path: glass, color: UIColor.white.withAlphaComponent(0.6), width: 0.6)
        }
    }

    static func glow(scale: CGFloat) -> UIImage? {
        image("amber-oil-lamp", size: CGSize(width: 64, height: 32), scale: scale) { c in
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                RGB(1, 0.68, 0.24).ui.withAlphaComponent(0.7).cgColor,
                RGB(0.91, 0.37, 0.06).ui.withAlphaComponent(0.2).cgColor,
                UIColor.clear.cgColor] as CFArray, locations: [0, 0.30, 1]) else { return }
            c.translateBy(x: 32, y: 16); c.scaleBy(x: 1, y: 0.5)
            c.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 32, options: [])
        }
    }

    static func linear(_ c: CGContext, colors: [UIColor], stops: [CGFloat], rect: CGRect) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: stops) else { return }
        c.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX * 0.35 + rect.minX * 0.65, y: rect.maxY),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    static func fill(_ c: CGContext, rect: CGRect, radius: CGFloat, color: UIColor) {
        guard rect.width > 0, rect.height > 0 else { return }
        color.setFill(); UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
    }
    static func stroke(_ c: CGContext, path: UIBezierPath, color: UIColor, width: CGFloat) {
        c.saveGState(); c.addPath(path.cgPath); c.setStrokeColor(color.cgColor); c.setLineWidth(width); c.strokePath(); c.restoreGState()
    }
    static func line(_ c: CGContext, from: CGPoint, to: CGPoint, color: UIColor, width: CGFloat) {
        c.saveGState(); c.move(to: from); c.addLine(to: to); c.setStrokeColor(color.cgColor); c.setLineWidth(width); c.strokePath(); c.restoreGState()
    }
    static func screw(_ c: CGContext, center: CGPoint, radius: CGFloat, angle: CGFloat) {
        c.saveGState(); c.translateBy(x: center.x, y: center.y); c.rotate(by: angle)
        fill(c, rect: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), radius: radius, color: RGB(0.14, 0.095, 0.055).ui)
        fill(c, rect: CGRect(x: -radius + 0.4, y: -radius + 0.1, width: radius * 2 - 0.6, height: radius * 2 - 0.6), radius: radius, color: RGB(0.77, 0.61, 0.35).ui)
        line(c, from: CGPoint(x: -radius * 0.6, y: 0), to: CGPoint(x: radius * 0.6, y: 0), color: RGB(0.12, 0.08, 0.04).ui, width: 0.65)
        c.restoreGState()
    }
}
#endif
