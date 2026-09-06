//
//  InputSourceSwitcher.swift
//  rootshell
//
//  Lists the system input sources the user can pick for a Mod-Tap binding.
//
//  Switching is realized by TerminalView's `preferredInputLanguage` +
//  textInputMode override on iPad/visionOS (see TerminalView+InputMode.swift).
//  On Mac Catalyst, switching uses Carbon TIS — the UIKit override is not
//  honored by AppKit's input-source machinery on Catalyst, and matching
//  UITextInputMode languages against TIS sources is fragile (the two
//  namespaces disagree on identifier granularity), so on Catalyst we
//  enumerate TIS sources directly and persist the TIS source ID
//  (e.g. "com.apple.keylayout.ABC") as the binding's identifier.
//
//  The `InputSourceDescriptor.primaryLanguage` field is therefore a
//  platform-defined opaque identifier: a UITextInputMode primaryLanguage
//  on iPad/visionOS, a TIS source ID on Catalyst. Stored rules round-trip
//  on the device they were created on; cross-platform-sourced rules will
//  silently fall through.
//

import Foundation
import UIKit
import os

// On Mac Catalyst, the TIS entry points used below come from
// InputSourceCarbonShim.swift (the Carbon umbrella header doesn't
// compile under the current Catalyst SDK).

/// A user-selectable input source.
struct InputSourceDescriptor: Hashable, Identifiable, Sendable {
    /// Opaque platform identifier. UITextInputMode primary language on iPad/visionOS,
    /// TIS source ID (e.g. "com.apple.keylayout.ABC") on Mac Catalyst.
    let primaryLanguage: String
    /// Localized name suitable for a picker row.
    let displayName: String

    var id: String { primaryLanguage }
}

@MainActor
enum InputSourceCatalog {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "InputSources")

    /// Input sources the user can pick for a binding.
    static func available() -> [InputSourceDescriptor] {
        #if targetEnvironment(macCatalyst)
        return catalystAvailable()
        #else
        return uikitAvailable()
        #endif
    }

    // MARK: - iPad / visionOS

    private static func uikitAvailable() -> [InputSourceDescriptor] {
        var seen = Set<String>()
        var result: [InputSourceDescriptor] = []
        for mode in UITextInputMode.activeInputModes {
            guard let lang = mode.primaryLanguage, !lang.isEmpty else { continue }
            // "emoji" (and "dictation") are pseudo input modes, not real
            // switchable text keyboards — the textInputMode override can't land
            // on them (the keyboard just flashes and reverts), so never offer
            // them for binding or cycling.
            guard lang != "emoji", lang != "dictation" else { continue }
            guard seen.insert(lang).inserted else { continue }
            let display = Locale.current.localizedString(forIdentifier: lang) ?? lang
            result.append(InputSourceDescriptor(primaryLanguage: lang, displayName: display))
        }
        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Mac Catalyst

    #if targetEnvironment(macCatalyst)

    // UIKit can ask for hundreds of document positions per input event. Each
    // query checks Korean isolation, so cache both positive and negative
    // language matches with the source snapshot, not just the TIS properties.
    // A reference keeps those results shared across all document queries;
    // replacing/invalidating the snapshot discards them together.
    private final class CatalystCurrentInputSourceSnapshot {
        let languages: [String]
        let sourceID: String?
        let expiresAt: TimeInterval
        private var languageMatches: [[String]: Bool] = [:]

        init(languages: [String], sourceID: String?, expiresAt: TimeInterval) {
            self.languages = languages
            self.sourceID = sourceID
            self.expiresAt = expiresAt
        }

        func hasLanguagePrefix(_ prefixes: [String]) -> Bool {
            if let result = languageMatches[prefixes] { return result }
            let result = matchesLanguagePrefixes(prefixes)
            languageMatches[prefixes] = result
            return result
        }

        private func matchesLanguagePrefixes(_ prefixes: [String]) -> Bool {
            let normalizedPrefixes = prefixes.map { $0.lowercased() }
            if languages.contains(where: { language in
                normalizedPrefixes.contains { language.hasPrefix($0) }
            }) {
                return true
            }

            guard let sourceID = sourceID else { return false }

            return normalizedPrefixes.contains { prefix in
                sourceID.contains(".\(prefix)")
                    || sourceID.contains("\(prefix)-")
                    || sourceID.contains("_\(prefix)")
                    || (prefix == "ko" && (sourceID.contains("korean") || sourceID.contains("hangul")))
                    || (prefix == "ja" && (sourceID.contains("japanese") || sourceID.contains("kana")))
                    || (prefix == "zh" && (sourceID.contains("chinese") || sourceID.contains("pinyin")))
            }
        }
    }

    private static var catalystCurrentInputSourceSnapshot: CatalystCurrentInputSourceSnapshot?
    private static let catalystCurrentInputSourceSnapshotTTL: TimeInterval = 0.2

    private static func catalystAvailable() -> [InputSourceDescriptor] {
        guard let listUnmanaged = TISCreateInputSourceList(nil, false) else { return [] }
        let list = listUnmanaged.takeRetainedValue() as [TISInputSourceRef]

        var seen = Set<String>()
        var result: [InputSourceDescriptor] = []

        for source in list {
            guard sourceIsKeyboardCategory(source), sourceIsSelectable(source) else { continue }
            guard let sourceID = sourceStringProperty(source, key: kTISPropertyInputSourceID) else { continue }
            guard seen.insert(sourceID).inserted else { continue }

            let displayName = sourceStringProperty(source, key: kTISPropertyLocalizedName)
                ?? sourceLanguages(source).first.flatMap { Locale.current.localizedString(forIdentifier: $0) }
                ?? sourceID
            result.append(InputSourceDescriptor(primaryLanguage: sourceID, displayName: displayName))
        }

        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Switch the macOS input source via Carbon TIS by source ID.
    /// Returns true if the system accepted the change.
    @discardableResult
    static func catalystSwitch(toPrimaryLanguage target: String) -> Bool {
        guard let source = catalystSelectableSource(matchingID: target) else {
            logger.warning("Catalyst: no enabled TIS source with id \(target, privacy: .public)")
            return false
        }
        let status = TISSelectInputSource(source)
        if status != 0 {
            logger.warning("Catalyst: TISSelectInputSource failed status=\(status, privacy: .public) id=\(target, privacy: .public)")
            return false
        }
        invalidateCatalystCurrentInputSourceSnapshot()
        return true
    }

    /// Current keyboard input source ID, in the same (raw, non-lowercased)
    /// namespace as `available()`. Queried fresh — never cached — so a
    /// just-added/removed source is reflected immediately. Used to compute the
    /// "next" source for `cycleInputSource()`; the lowercased snapshot used by
    /// `catalystCurrentInputSourceHasLanguagePrefix` would mismatch the
    /// raw-case IDs `available()` returns.
    static func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return sourceStringProperty(source, key: kTISPropertyInputSourceID)
    }

    private static func catalystSelectableSource(matchingID target: String) -> TISInputSourceRef? {
        guard let listUnmanaged = TISCreateInputSourceList(nil, false) else { return nil }
        let list = listUnmanaged.takeRetainedValue() as [TISInputSourceRef]

        for source in list {
            guard sourceIsSelectable(source) else { continue }
            if sourceStringProperty(source, key: kTISPropertyInputSourceID) == target {
                return source
            }
        }
        return nil
    }

    /// True when the currently-selected macOS input source advertises any of
    /// the requested BCP-47 language prefixes. Falls back to the source ID for
    /// input methods whose UIKit language identifier is too coarse or absent.
    static func catalystCurrentInputSourceHasLanguagePrefix(_ prefixes: [String]) -> Bool {
        guard let snapshot = catalystCurrentInputSourceSnapshotValue() else { return false }

        return snapshot.hasLanguagePrefix(prefixes)
    }

    private static func catalystCurrentInputSourceSnapshotValue() -> CatalystCurrentInputSourceSnapshot? {
        let now = ProcessInfo.processInfo.systemUptime
        if let snapshot = catalystCurrentInputSourceSnapshot, snapshot.expiresAt > now {
            return snapshot
        }

        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }

        let snapshot = CatalystCurrentInputSourceSnapshot(
            languages: sourceLanguages(source).map { $0.lowercased() },
            sourceID: sourceStringProperty(source, key: kTISPropertyInputSourceID)?.lowercased(),
            expiresAt: now + catalystCurrentInputSourceSnapshotTTL
        )
        catalystCurrentInputSourceSnapshot = snapshot
        return snapshot
    }

    private static func invalidateCatalystCurrentInputSourceSnapshot() {
        catalystCurrentInputSourceSnapshot = nil
    }

    // MARK: - TIS helpers

    private static func sourceIsKeyboardCategory(_ source: TISInputSourceRef) -> Bool {
        guard let category = sourceStringProperty(source, key: kTISPropertyInputSourceCategory) else {
            return false
        }
        return category == (kTISCategoryKeyboardInputSource as String)
    }

    private static func sourceIsSelectable(_ source: TISInputSourceRef) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) else {
            return false
        }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    private static func sourceStringProperty(_ source: TISInputSourceRef, key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func sourceLanguages(_ source: TISInputSourceRef) -> [String] {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return []
        }
        let array = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue()
        return (array as? [String]) ?? []
    }

    #endif
}
