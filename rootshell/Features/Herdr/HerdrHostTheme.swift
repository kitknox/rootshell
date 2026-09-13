// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

/// Host defaults, not colors changed by an application through OSC. Kept apart
/// from the renderer so the stock endpoint codec can be tested without UIKit.
nonisolated struct HerdrHostTheme: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        var r: UInt8
        var g: UInt8
        var b: UInt8
    }

    var foreground: RGB
    var background: RGB
    var palette: [RGB]

    /// Same background classification used by rootshell's theme UI.
    var isLight: Bool {
        0.2126 * Double(background.r) + 0.7152 * Double(background.g)
            + 0.0722 * Double(background.b) > 127.5
    }
}

extension HerdrEndpointWire {
    /// Frozen vanilla 0.9.0 ClientMessage::ClientShellHostTheme (tag 17).
    /// Send appearance first: otherwise the background update can infer an
    /// intermediate appearance using upstream's different luminance threshold.
    static func hostTheme(_ theme: HerdrHostTheme, previous: HerdrHostTheme? = nil) -> Data {
        var result = Data()
        func message(_ body: (inout Writer) -> Void) {
            var writer = Writer()
            writer.uint(17)
            body(&writer)
            result.append(writer.framed())
        }
        if previous?.isLight != theme.isLight {
            message { $0.uint(2); $0.uint(theme.isLight ? 1 : 0) }
        }
        for (kind, color, old) in [(0, theme.foreground, previous?.foreground),
                                    (1, theme.background, previous?.background)] where color != old {
            message {
                $0.uint(0); $0.uint(UInt64(kind))
                $0.byte(color.r); $0.byte(color.g); $0.byte(color.b)
            }
        }
        let changed = theme.palette.enumerated().filter { index, color in
            previous?.palette.indices.contains(index) != true || previous?.palette[index] != color
        }
        if !changed.isEmpty {
            message {
                $0.uint(1); $0.uint(UInt64(changed.count))
                for (index, color) in changed {
                    $0.byte(UInt8(index)); $0.byte(color.r); $0.byte(color.g); $0.byte(color.b)
                }
            }
        }
        return result
    }

    static func hostFocus(_ focused: Bool) -> Data {
        var writer = Writer()
        writer.uint(18) // ClientMessage::ClientShellFocus
        writer.bool(focused)
        return writer.framed()
    }
}
