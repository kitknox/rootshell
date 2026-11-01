import Foundation
import CoreText
import UIKit
import os

/// A value snapshot of font inputs. Registration and discovery never access
/// FontManager, UserDefaults, or published UI state on the worker thread.
/// UIFont is immutable and Sendable; CoreText's individual functions are thread-safe.
nonisolated struct FontCatalogLoader: Sendable {
    typealias FontFamilyInfo = FontManager.FontFamilyInfo
    typealias CustomFontFamily = FontManager.CustomFontFamily

    /// Bundle resources do not change during a process lifetime. Share their
    /// parsed names across critical registration and the background catalog.
    struct BundledFont: Sendable {
        let url: URL
        let displayName: String
        let configName: String
    }

    let bundledFonts: [BundledFont]
    let customFontsDirectory: URL
    let customFontFamilies: [CustomFontFamily]
    let hiddenUtilityFontFamilies: Set<String>
    var replacedBundledFamilies: Set<String>
    var availableFamilies: [FontFamilyInfo] = []
    var systemFontFamilies: [FontFamilyInfo] = []
    private let logger = Logger(subsystem: "com.rootshell", category: "FontManager")

    init(
        bundledFonts: [BundledFont],
        customFontsDirectory: URL,
        customFontFamilies: [CustomFontFamily],
        hiddenUtilityFontFamilies: Set<String>,
        replacedBundledFamilies: Set<String>
    ) {
        self.bundledFonts = bundledFonts
        self.customFontsDirectory = customFontsDirectory
        self.customFontFamilies = customFontFamilies
        self.hiddenUtilityFontFamilies = hiddenUtilityFontFamilies
        self.replacedBundledFamilies = replacedBundledFamilies
    }

    nonisolated struct Result: Sendable {
        let availableFamilies: [FontFamilyInfo]
        let systemFontFamilies: [FontFamilyInfo]
        let replacedBundledFamilies: Set<String>
    }

    mutating func load() -> Result {
        let deferred = LaunchSignposts.begin("launch.fonts.deferred")
        defer { LaunchSignposts.end("launch.fonts.deferred", deferred) }

        registerBundledFonts()
        let registeredCustomFamilies = registerCustomFonts()
        let staleReplacements = replacedBundledFamilies.subtracting(registeredCustomFamilies)
        for family in staleReplacements {
            logger.warning("Stale bundled replacement for '\(family)' — restoring bundled font")
            reregisterBundledFontsForFamily(family)
        }
        loadAvailableFamilies()
        loadSystemFonts()
        return Result(
            availableFamilies: availableFamilies,
            systemFontFamilies: systemFontFamilies,
            replacedBundledFamilies: replacedBundledFamilies
        )
    }

    static func readBundledFonts(at fontsURL: URL?) -> [BundledFont] {
        guard let fontsURL, let enumerator = FileManager.default.enumerator(
            at: fontsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var fonts: [BundledFont] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }
            guard let (displayName, configName) = extractFontInfo(from: fileURL) else { continue }
            fonts.append(BundledFont(url: fileURL, displayName: displayName, configName: configName))
        }
        return fonts
    }

    func registerBundledFonts(matching families: Set<String>? = nil) {
        var registeredCount = 0
        for font in bundledFonts {
            let fileURL = font.url
            let filename = fileURL.lastPathComponent
            let configName = font.configName

            // Skip fonts whose family has been replaced by a custom import
            if replacedBundledFamilies.contains(configName) {
                logger.debug("Skipping replaced bundled font: \(filename)")
                continue
            }

            if let families, !families.contains(configName) {
                continue
            }

            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error) {
                registeredCount += 1
                logger.debug("Registered font: \(filename)")
            } else if let cfError = error?.takeRetainedValue() {
                // Font might already be registered - not necessarily an error
                logger.debug("Font registration note for \(filename): \(cfError)")
            }
        }

        logger.info("Registered \(registeredCount) bundled fonts")
    }

    func registerCustomFontFamilyFiles(_ family: CustomFontFamily) -> Bool {
        var registeredAny = false
        for file in family.fontFiles {
            let fileURL = customFontsDirectory.appendingPathComponent(file.filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                let name = file.originalName
                logger.warning("Custom font file missing: \(name)")
                continue
            }

            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error) {
                registeredAny = true
            } else if Self.isAlreadyRegisteredError(error) {
                registeredAny = true
                let name = file.originalName
                logger.debug("Custom font already registered: \(name)")
            } else if let cfError = error?.takeRetainedValue() {
                let name = file.originalName
                logger.debug("Custom font registration note for \(name): \(cfError)")
            }
        }
        return registeredAny
    }

    func registerCustomFonts() -> Set<String> {
        var registeredCount = 0
        var successfulFamilies: Set<String> = []

        for family in customFontFamilies {
            let before = successfulFamilies.count
            if registerCustomFontFamilyFiles(family) {
                successfulFamilies.insert(family.configName)
                // Count files roughly for the log (one per successful family is enough signal)
                if successfulFamilies.count > before {
                    registeredCount += family.fontFiles.count
                }
            }
        }

        let count = registeredCount
        logger.info("Registered \(count) custom font files")
        return successfulFamilies
    }

    mutating func loadAvailableFamilies() {
        var familyMap: [String: (displayName: String, configName: String, fontURL: URL)] = [:]

        for font in bundledFonts {
            let fileURL = font.url
            let filename = fileURL.lastPathComponent
            let familyName = font.displayName
            let configName = font.configName
            // Skip UI-only utility fonts and families replaced by custom imports
            guard !hiddenUtilityFontFamilies.contains(familyName) else { continue }
            guard !replacedBundledFamilies.contains(configName) else { continue }

            // Prefer Regular weight for preview
            let isRegular = filename.contains("Regular")
            if familyMap[familyName] == nil || isRegular {
                familyMap[familyName] = (familyName, configName, fileURL)
            }
        }

        // Build FontFamilyInfo array
        var families: [FontFamilyInfo] = []
        for (id, info) in familyMap {
            families.append(FontFamilyInfo(
                id: id,
                displayName: info.displayName,
                configName: info.configName,
                sampleSource: .file(info.fontURL)
            ))
        }

        // Sort alphabetically
        families.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        self.availableFamilies = families
        logger.info("Loaded \(families.count) font families")
    }

    mutating func loadSystemFonts() {
        let bundledConfigNames = Set(availableFamilies.map(\.configName))
        let customConfigNames = Set(customFontFamilies.map(\.configName))

        var systemFonts: [FontFamilyInfo] = []
        var seenFamilies = Set<String>()

        // Use descriptor matching to discover monospace fonts system-wide. On iOS this
        // sees fonts another app installed (Font Case etc.) only once this app has
        // been granted access to them: see FontManager.selectInstalledFont(_:).
        // Read family names off descriptors so discovery never instantiates a font.
        let monoDescriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue]
        ] as CFDictionary)
        let matchedDescriptors = CTFontDescriptorCreateMatchingFontDescriptors(monoDescriptor, nil) as? [CTFontDescriptor] ?? []
        let matchCount = matchedDescriptors.count
        logger.info("[SystemFonts] Monospace trait matches: \(matchCount)")

        for descriptor in matchedDescriptors {
            guard let familyName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else {
                continue
            }

            guard !seenFamilies.contains(familyName),
                  !bundledConfigNames.contains(familyName),
                  !customConfigNames.contains(familyName),
                  !hiddenUtilityFontFamilies.contains(familyName) else { continue }

            let faceName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? familyName
            systemFonts.append(FontFamilyInfo(
                id: familyName,
                displayName: familyName,
                configName: familyName,
                sampleSource: .postScriptName(faceName)
            ))
            seenFamilies.insert(familyName)
        }

        let traitCount = systemFonts.count
        logger.info("[SystemFonts] From trait matching: \(traitCount) monospace families")

        // Also check UIFont.familyNames with glyph-advance fallback for fonts that
        // don't set the monospace trait but are actually monospace (e.g., Berkeley Mono)
        for familyName in UIFont.familyNames {
            guard !seenFamilies.contains(familyName),
                  !bundledConfigNames.contains(familyName),
                  !customConfigNames.contains(familyName),
                  !hiddenUtilityFontFamilies.contains(familyName) else { continue }

            guard let faceName = Self.monospaceFaceName(forFamily: familyName) else { continue }

            logger.info("[SystemFonts] Glyph-advance detected mono: '\(familyName)'")
            systemFonts.append(FontFamilyInfo(
                id: familyName,
                displayName: familyName,
                configName: familyName,
                sampleSource: .postScriptName(faceName)
            ))
            seenFamilies.insert(familyName)
        }

        systemFonts.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        self.systemFontFamilies = systemFonts
        let totalCount = systemFonts.count
        logger.info("[SystemFonts] Total: \(totalCount) system monospace font families")
        for sf in systemFonts {
            let name = sf.displayName
            logger.info("[SystemFonts]   -> \(name)")
        }
    }

    /// Family name -> PostScript name of its monospace face, or nil when not
    /// monospace. Spares reopening every family on each refresh; cleared when
    /// font registrations change.
    private static let glyphAdvanceMonoCache = OSAllocatedUnfairLock(initialState: [String: String?]())

    static func invalidateMonospaceCache() {
        glyphAdvanceMonoCache.withLock { $0.removeAll() }
    }

    private static func monospaceFaceName(forFamily familyName: String) -> String? {
        if let cached = glyphAdvanceMonoCache.withLock({ $0[familyName] }) { return cached }
        let faceName = UIFont(name: familyName, size: 16)
            .flatMap { isMonospaceByGlyphAdvance($0) ? $0.fontName : nil }
        glyphAdvanceMonoCache.withLock { $0[familyName] = faceName }
        return faceName
    }

    /// Include fonts that have fixed glyph advances but lack the monospace trait.
    private static func isMonospaceByGlyphAdvance(_ font: UIFont) -> Bool {
        let ctFont = font as CTFont
        var characters: [UniChar] = [0x004D, 0x0069, 0x0057, 0x002E] // M, i, W, .
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, characters.count) else { return false }
        guard glyphs.allSatisfy({ $0 != 0 }) else { return false }
        var advances = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, characters.count)
        let ref = advances[0].width
        guard ref > 0 else { return false }
        return advances.allSatisfy { abs($0.width - ref) < 0.01 }
    }

    static func extractFontInfo(from url: URL) -> (displayName: String, configName: String)? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider) else {
            return nil
        }

        // Create a CTFont to get the family name
        let ctFont = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
        let familyName = CTFontCopyFamilyName(ctFont) as String

        // The config name is the font family name as-is
        return (familyName, familyName)
    }

    static func createFont(from url: URL, size: CGFloat) -> UIFont? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider) else {
            return nil
        }

        let ctFont = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
        return ctFont as UIFont
    }

    static func isAlreadyRegisteredError(_ error: Unmanaged<CFError>?) -> Bool {
        guard let cfError = error?.takeUnretainedValue() else { return false }
        let domain = CFErrorGetDomain(cfError) as String
        let code = CFErrorGetCode(cfError)
        // CTFontManagerError codes: .alreadyRegistered = 105, .duplicatedName = 106
        guard domain == kCTFontManagerErrorDomain as String else { return false }
        return code == 105 || code == 106
    }

    mutating func reregisterBundledFontsForFamily(_ familyName: String) {
        for font in bundledFonts where font.configName == familyName {
            let fileURL = font.url
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error) {
                let filename = fileURL.lastPathComponent
                logger.debug("Re-registered bundled font: \(filename)")
            }
        }

        replacedBundledFamilies.remove(familyName)
    }
}

/// One startup load, shared by asynchronous settings callers and synchronous
/// import/delete/restore paths. The lock protects the cached result AND the full
/// registration pass: cancellation must not allow a mutation to race a worker
/// that is still registering fonts. Loading never hops to MainActor, so a
/// synchronous mutation can safely wait here without a main-thread deadlock.
nonisolated final class FontCatalogLoad: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.rootshell.fontCatalog", qos: .utility)
    private let lock = NSLock()
    private let input: FontCatalogLoader
    private var result: FontCatalogLoader.Result?

    init(input: FontCatalogLoader) {
        self.input = input
    }

    func loadInBackground() async -> FontCatalogLoader.Result {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.load())
            }
        }
    }

    func load() -> FontCatalogLoader.Result {
        lock.lock()
        defer { lock.unlock() }
        if let result { return result }
        var loader = input
        let loaded = loader.load()
        result = loaded
        return loaded
    }
}
