// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

/// Checks the running server, not the CLI binary that happens to launch it.
nonisolated enum HerdrVersionRequirement {
    static let minimum = "0.9.0"

    @discardableResult
    static func validate(_ reported: String?) throws -> String {
        let version = reported?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Herdr's fork/preview builds report MAJOR.MINOR.PATCH-channel.build.
        // Compare their base release so 0.9.0-rootshell is supported too.
        let pattern = #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        guard version.range(of: pattern, options: .regularExpression) != nil else {
            throw HerdrVersionError(reported: reported)
        }
        let core = version.prefix { $0 != "-" && $0 != "+" }
        let numbers = core.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3,
              !numbers.lexicographicallyPrecedes([0, 9, 0]) else {
            throw HerdrVersionError(reported: reported)
        }
        return version
    }
}

nonisolated struct HerdrVersionError: Error, LocalizedError {
    let reported: String?

    var errorDescription: String? {
        // This is also written to a terminal. Never echo control characters
        // supplied by an unrecognized server version into the gateway shell.
        let detected = reported.map {
            String(String.UnicodeScalarView($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100)))
        }.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        return String(localized: "herdr control mode requires herdr \(HerdrVersionRequirement.minimum) or newer. The running server reported: \(detected). Update regular herdr on the host, save your work, restart the herdr session, and attach again.")
    }
}
