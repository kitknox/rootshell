import Foundation

/// The first byte retains the legacy alternate-screen flag. New saves append
/// the styled viewport and cursor position to the same encrypted, atomic file.
nonisolated enum TerminalAlternateScreenSnapshot {
    static func encode(_ viewport: Data?) -> Data {
        var data = Data([1])
        if let viewport { data.append(viewport) }
        return data
    }

    static func restorationBytes(from saved: Data) -> Data? {
        guard saved.first == 1 else { return nil }
        var bytes = Data("\u{1b}[?1049h".utf8)
        if saved.count > 1 {
            // Enter alternate first: otherwise this viewport would overwrite
            // the shell's primary screen, and 1049h would then hide it.
            bytes.append(Data("\u{1b}[0m\u{1b}[H\u{1b}[2J".utf8))
            bytes.append(saved.dropFirst())
        }
        return bytes
    }
}
