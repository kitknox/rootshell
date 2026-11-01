import Foundation
import Combine
import CoreText
import UIKit
import UniformTypeIdentifiers
import os

/// An OpenType font feature discovered from a font via CoreText
struct FontFeature: Identifiable, Hashable {
    let tag: String           // "ss01", "zero", etc.
    let name: String          // Human-readable name from font name table
    let aatTypeID: Int        // AAT feature type identifier
    let aatSelectorOn: Int    // AAT selector to enable the feature
    let aatSelectorOff: Int   // AAT selector to disable the feature
    var id: String { tag }
}

/// Manages font selection and registration for the app
@MainActor
class FontManager: ObservableObject {
    static let shared = FontManager()

    /// Information about a bundled font family
    nonisolated struct FontFamilyInfo: Identifiable, Equatable, Sendable {
        let id: String
        let displayName: String
        let configName: String  // Name to use in Ghostty config
        let sampleSource: SampleSource

        /// Where a preview font comes from. Holding a UIFont here would keep
        /// every family's parsed tables alive for the process lifetime.
        nonisolated enum SampleSource: Sendable {
            case file(URL)
            case postScriptName(String)  // The specific face discovery matched
        }

        func makeSampleFont(size: CGFloat = 16) -> UIFont? {
            switch sampleSource {
            case .file(let url):
                FontCatalogLoader.createFont(from: url, size: size)
            case .postScriptName(let name):
                UIFont(name: name, size: size)
            }
        }

        static func == (lhs: FontFamilyInfo, rhs: FontFamilyInfo) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Per-font cell box adjustments (percentage deltas).
    /// Maps to Ghostty `adjust-cell-width` / `adjust-cell-height` config keys.
    struct CellAdjustments: Codable, Equatable {
        var widthPercent: Int = 0
        var heightPercent: Int = 0

        var isZero: Bool { widthPercent == 0 && heightPercent == 0 }

        static let zero = CellAdjustments()
    }

    /// Sentinel key for cell adjustments stored against the Ghostty default font (nil family).
    static let defaultFontKey = "__default__"

    /// A user-imported custom font family with one or more style variants
    nonisolated struct CustomFontFamily: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        var displayName: String
        let configName: String
        var fontFiles: [FontFile]
        let importDate: Date

        nonisolated struct FontFile: Codable, Equatable, Sendable {
            let filename: String       // UUID-prefixed filename in Documents
            let originalName: String   // Original filename for display
            let styleName: String?     // "Regular", "Bold", "Italic", etc.
        }
    }

    /// Errors that can occur during font import
    enum FontImportError: LocalizedError {
        case accessDenied
        case invalidFormat(String)
        case invalidFont(String)
        case registrationFailed(String)
        case noFontsFound
        case reservedFamily(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Could not access the selected file"
            case .invalidFormat(let name):
                return "\(name) is not a valid font file (TTF or OTF required)"
            case .invalidFont(let name):
                return "\(name) could not be read as a font"
            case .registrationFailed(let name):
                return "Failed to register \(name) with the system"
            case .noFontsFound:
                return "No valid font files were found in the selection"
            case .reservedFamily(let name):
                return "\(name) is reserved for the app's interface and cannot be imported"
            }
        }
    }

    // MARK: - Keys

    private static let customFontFamiliesKey = "customFontFamilies"
    private static let replacedBundledFamiliesKey = "replacedBundledFamilies"
    private static let nerdFontMigrationKey = "nerdFontFamilyMigrationDone"

    /// Registered keys this manager reloads from the store; file-backed font lists stay raw.
    private static let ownedKeys: Set<String> = [
        Settings.Font.size.name, Settings.Font.family.name, Settings.Font.ligatures.name,
        Settings.Font.featurePrefs.name, Settings.Font.cellAdjustmentPrefs.name,
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    private var isReloading = false

    /// Maps old Nerd Font Mono family names to their unpatched replacements.
    /// Used for one-time migration when users had a nerd font family selected.
    private static let nerdFontFamilyMigration: [String: String] = [
        "0xProto Nerd Font Mono": "0xProto",
        "FiraCode Nerd Font Mono": "Fira Code",
        "GeistMono Nerd Font Mono": "Geist Mono",
    ]

    /// Bundled fonts used only for UI glyph rendering (profile icons, etc.).
    /// Registered with CoreText but never offered as terminal fonts.
    private static let hiddenUtilityFontFamilies: Set<String> = [
        "Symbols Nerd Font Mono",
    ]

    // MARK: - Published Properties

    /// All available bundled font families
    @Published private(set) var availableFamilies: [FontFamilyInfo] = [] {
        didSet { catalogRevision &+= 1 }
    }

    /// User-imported custom font families
    @Published private(set) var customFontFamilies: [CustomFontFamily] = []

    /// System-installed monospace font families (e.g., from Font Case)
    @Published private(set) var systemFontFamilies: [FontFamilyInfo] = [] {
        didSet { catalogRevision &+= 1 }
    }

    /// Bumped on every catalog refresh so preview caches can drop stale fonts.
    /// FontFamilyInfo equality is by id, so the arrays alone can't signal this.
    private(set) var catalogRevision = 0

    /// True once remaining bundled/custom registration and catalog discovery finish.
    /// Font settings awaits this via `ensureFontsLoaded()`; the terminal only needs
    /// the selected family, which is registered on the critical path.
    @Published private(set) var isCatalogLoaded = false

    /// Bundled font families that have been replaced by custom imports
    private(set) var replacedBundledFamilies: Set<String> = []

    /// Background catalog build kicked off from `init`.
    private var catalogLoadTask: Task<Void, Never>?
    private var catalogLoad: FontCatalogLoad?

    /// Currently selected font size
    @Published var currentFontSize: Double {
        didSet {
            // Imports assign directly; callers convert this to Int, which traps on huge values.
            let safeSize = Settings.Font.size.sanitized(currentFontSize)
            if safeSize != currentFontSize { currentFontSize = safeSize }
            guard ProtectedDataGuard.isAvailable else { return }
            saveFontSize()
            fontSizeDidChange.send(currentFontSize)
        }
    }

    /// Currently selected font family (nil = Ghostty default)
    @Published var currentFontFamily: String? {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            saveFontFamily()
            fontFamilyDidChange.send(currentFontFamily)
        }
    }

    /// Whether font ligatures are enabled
    @Published var ligaturesEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            saveLigaturesEnabled()
            ligaturesDidChange.send(ligaturesEnabled)
        }
    }

    /// Per-font enabled feature tags: [fontFamilyName: Set<tag>]
    @Published private(set) var enabledFontFeatures: [String: Set<String>] = [:]

    /// Per-font cell box adjustments. Key is font family configName, or
    /// `defaultFontKey` for the Ghostty default font (nil family).
    @Published private(set) var cellAdjustments: [String: CellAdjustments] = [:]

    // MARK: - Publishers

    let fontSizeDidChange = PassthroughSubject<Double, Never>()
    let fontFamilyDidChange = PassthroughSubject<String?, Never>()
    /// The selected family became resolvable after surfaces may have fallen back.
    let fontFamilyDidBecomeAvailable = PassthroughSubject<Void, Never>()
    let ligaturesDidChange = PassthroughSubject<Bool, Never>()
    let fontFeaturesDidChange = PassthroughSubject<Void, Never>()
    let cellAdjustmentsDidChange = PassthroughSubject<Void, Never>()

    private let logger = Logger(subsystem: "com.rootshell", category: "FontManager")
    private var fontRegistrationObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        let store = SettingsStore.shared

        // A stored 0 or out-of-range size falls back to the default
        self.currentFontSize = Settings.Font.size.sanitized(store.get(Settings.Font.size))

        // Load saved font family (nil = use Ghostty default)
        self.currentFontFamily = store.get(Settings.Font.family)

        self.ligaturesEnabled = store.get(Settings.Font.ligatures)

        // Clean up any previously-seeded legacy defaults (from earlier migration code)
        if UserDefaults.standard.bool(forKey: "fontFeatureMigrationV1Done") {
            store.reset(Settings.Font.featurePrefs)
            UserDefaults.standard.removeObject(forKey: "fontFeatureMigrationV1Done")
        }
        self.enabledFontFeatures = Self.decodeFontFeatures(store.get(Settings.Font.featurePrefs))
        self.cellAdjustments = Self.decodeCellAdjustments(store.get(Settings.Font.cellAdjustmentPrefs))

        // One-time migration: map old Nerd Font Mono family names to unpatched equivalents.
        // Skip when protected data is unavailable — bool(forKey:) returns false (not migrated)
        // which would write the migration-done flag to an empty/encrypted plist.
        if ProtectedDataGuard.isAvailable,
           !UserDefaults.standard.bool(forKey: Self.nerdFontMigrationKey) {
            if let current = self.currentFontFamily,
               let migrated = Self.nerdFontFamilyMigration[current] {
                self.currentFontFamily = migrated
                store.set(Settings.Font.family, migrated)
            }
            UserDefaults.standard.set(true, forKey: Self.nerdFontMigrationKey)
        }

        // Load replaced bundled families before registration
        if let saved = UserDefaults.standard.stringArray(forKey: Self.replacedBundledFamiliesKey) {
            replacedBundledFamilies = Set(saved)
        }

        // Critical path: register only what the first terminal needs (selected
        // family + UI utility glyphs). Full catalog discovery is expensive
        // (every bundled file + device-wide monospace scan) and runs on a
        // utility queue without occupying MainActor during the first frame.
        let critical = LaunchSignposts.begin("launch.fonts.critical")
        registerCriticalPathFonts()
        LaunchSignposts.end("launch.fonts.critical", critical)

        startBackgroundCatalogLoad()

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Await full font catalog registration/discovery. Font settings uses this;
    /// terminal launch does not.
    func ensureFontsLoaded() async {
        if isCatalogLoaded { return }
        await catalogLoadTask?.value
    }

    /// Register the selected family (and utility fonts) so Ghostty can resolve
    /// the user's font before the deferred catalog finishes.
    private func registerCriticalPathFonts() {
        // UI glyph font used by profile icons — small, needed early.
        registerBundledFonts(matching: Self.hiddenUtilityFontFamilies)

        // Decode custom-font metadata without registering every file yet.
        loadCustomFontMetadata()

        guard let selected = currentFontFamily else { return }

        if let custom = customFontFamilies.first(where: { $0.configName == selected }) {
            registerCustomFontFamilyFiles(custom)
        } else {
            // Bundled or system-installed. System fonts need no registration;
            // bundled registration is a no-op when the family isn't in the bundle.
            registerBundledFonts(matching: Set([selected]))
            requestInstalledFontIfMissing(selected)
        }
    }

    /// Only immutable bundle metadata is cached; custom imports and replacement
    /// state are captured anew for every loader.
    private lazy var bundledFontCatalog = FontCatalogLoader.readBundledFonts(at: findFontsDirectory())

    /// Capture mutable manager state before crossing to the catalog worker.
    private func makeCatalogLoader() -> FontCatalogLoader {
        FontCatalogLoader(
            bundledFonts: bundledFontCatalog,
            customFontsDirectory: customFontsDirectory,
            customFontFamilies: customFontFamilies,
            hiddenUtilityFontFamilies: Self.hiddenUtilityFontFamilies,
            replacedBundledFamilies: replacedBundledFamilies
        )
    }

    /// Run the entire registration/discovery pass on a utility queue. Merely
    /// yielding a MainActor task does not let SwiftUI reliably paint first.
    private func startBackgroundCatalogLoad() {
        let load = FontCatalogLoad(input: makeCatalogLoader())
        catalogLoad = load
        catalogLoadTask = Task { @MainActor [weak self] in
            let result = await load.loadInBackground()
            guard let self, !self.isCatalogLoaded else { return }
            self.applyCatalog(result)
        }
    }

    private func applyCatalog(_ result: FontCatalogLoader.Result) {
        if replacedBundledFamilies != result.replacedBundledFamilies {
            replacedBundledFamilies = result.replacedBundledFamilies
            saveReplacedBundledFamilies()
        }
        availableFamilies = result.availableFamilies
        systemFontFamilies = result.systemFontFamilies
        if fontRegistrationObserver == nil {
            setupFontRegistrationObserver()
        }
        isCatalogLoaded = true
        catalogLoad = nil
        catalogLoadTask = nil
        LaunchSignposts.event("fonts.catalogReady")
    }

    /// Mutations must finish the same load, not cancel it and start another
    /// registration pass. After this returns the worker can only deliver its
    /// cached result, which the isCatalogLoaded guard above ignores.
    private func completeCatalogLoadIfNeeded() {
        guard !isCatalogLoaded, let catalogLoad else { return }
        applyCatalog(catalogLoad.load())
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Font.size.name) {
            currentFontSize = Settings.Font.size.sanitized(store.get(Settings.Font.size))
        }
        if keys.contains(Settings.Font.family.name) {
            currentFontFamily = store.get(Settings.Font.family)
            // External reload can select a family before deferred registration finishes.
            if !isCatalogLoaded, let family = currentFontFamily {
                if let custom = customFontFamilies.first(where: { $0.configName == family }) {
                    registerCustomFontFamilyFiles(custom)
                } else {
                    registerBundledFonts(matching: Set([family]))
                }
            }
            if let family = currentFontFamily { requestInstalledFontIfMissing(family) }
        }
        if keys.contains(Settings.Font.ligatures.name) { ligaturesEnabled = store.get(Settings.Font.ligatures) }
        if keys.contains(Settings.Font.featurePrefs.name) {
            enabledFontFeatures = Self.decodeFontFeatures(store.get(Settings.Font.featurePrefs))
            fontFeaturesDidChange.send()
        }
        if keys.contains(Settings.Font.cellAdjustmentPrefs.name) {
            cellAdjustments = Self.decodeCellAdjustments(store.get(Settings.Font.cellAdjustmentPrefs))
            cellAdjustmentsDidChange.send()
        }
    }

    private static func decodeFontFeatures(_ data: Data?) -> [String: Set<String>] {
        guard let data, let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return decoded.mapValues { Set($0) }
    }

    private static func decodeCellAdjustments(_ data: Data?) -> [String: CellAdjustments] {
        guard let data, let decoded = try? JSONDecoder().decode([String: CellAdjustments].self, from: data) else { return [:] }
        return decoded
    }

    // MARK: - Font Registration

    /// Register bundled TTF/OTF fonts with CoreText.
    /// - Parameter matching: When non-nil, only families in this set are registered.
    ///   Pass `nil` to register every non-replaced bundled font (deferred catalog path).
    private func registerBundledFonts(matching families: Set<String>? = nil) {
        makeCatalogLoader().registerBundledFonts(matching: families)
    }

    /// Find the fonts directory in the app bundle
    private func findFontsDirectory() -> URL? {
        let fileManager = FileManager.default

        // Try multiple possible locations (similar to ThemeManager)
        let possiblePaths: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent("fonts"),
            Bundle.main.resourceURL?.appendingPathComponent("fonts"),
            Bundle.main.resourceURL?
                .appendingPathComponent("Resources")
                .appendingPathComponent("ghostty")
                .appendingPathComponent("fonts"),
            Bundle.main.bundleURL
                .appendingPathComponent("Resources")
                .appendingPathComponent("ghostty")
                .appendingPathComponent("fonts")
        ]

        for path in possiblePaths.compactMap({ $0 }) {
            if fileManager.fileExists(atPath: path.path) {
                logger.info("Found fonts directory at: \(path.path)")
                return path
            }
        }

        return nil
    }

    // MARK: - Custom Font Storage

    /// Directory for user-imported font files
    private var customFontsDirectory: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fontsDir = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("fonts", isDirectory: true)

        if !FileManager.default.fileExists(atPath: fontsDir.path) {
            try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        }

        return fontsDir
    }

    /// Full path for a custom font file
    private func documentsPathForCustomFont(_ filename: String) -> URL {
        customFontsDirectory.appendingPathComponent(filename)
    }

    /// Decode custom-font metadata from UserDefaults without CoreText registration.
    private func loadCustomFontMetadata() {
        guard let data = UserDefaults.standard.data(forKey: Self.customFontFamiliesKey),
              let families = try? JSONDecoder().decode([CustomFontFamily].self, from: data) else {
            customFontFamilies = []
            return
        }
        customFontFamilies = families
    }

    /// Register every file belonging to one custom family.
    @discardableResult
    private func registerCustomFontFamilyFiles(_ family: CustomFontFamily) -> Bool {
        makeCatalogLoader().registerCustomFontFamilyFiles(family)
    }

    /// Register all previously-imported custom fonts with CoreText.
    /// Returns the set of family configNames that successfully registered at least one file.
    @discardableResult
    private func registerCustomFonts() -> Set<String> {
        loadCustomFontMetadata()
        return makeCatalogLoader().registerCustomFonts()
    }

    // MARK: - Custom Font Import

    /// Import font files, grouping by family name. Returns newly created or updated families.
    @discardableResult
    func importFonts(from urls: [URL]) throws -> [CustomFontFamily] {
        completeCatalogLoadIfNeeded()

        struct ImportedFile {
            let familyName: String
            let styleName: String?
            let filename: String
            let originalName: String
        }

        var importedFiles: [ImportedFile] = []
        // Track bundled families unregistered during this import for rollback on failure
        var unregisteredBundledFamilies: Set<String> = []

        // Rollback helper: undo imported custom files first, then restore bundled families.
        // Order matters: bundled re-registration can fail if custom fonts with the same
        // family name are still registered.
        func rollbackOnFailure() {
            for file in importedFiles {
                let fileURL = documentsPathForCustomFont(file.filename)
                var error: Unmanaged<CFError>?
                CTFontManagerUnregisterFontsForURL(fileURL as CFURL, .process, &error)
                try? FileManager.default.removeItem(at: fileURL)
            }
            for family in unregisteredBundledFamilies {
                reregisterBundledFontsForFamily(family)
            }
        }

        for url in urls {
            // Start security-scoped access
            guard url.startAccessingSecurityScopedResource() else {
                rollbackOnFailure()
                throw FontImportError.accessDenied
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // Validate file extension
            let ext = url.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else {
                let name = url.lastPathComponent
                rollbackOnFailure()
                throw FontImportError.invalidFormat(name)
            }

            // Validate font data
            guard let data = try? Data(contentsOf: url),
                  let provider = CGDataProvider(data: data as CFData),
                  let cgFont = CGFont(provider) else {
                let name = url.lastPathComponent
                rollbackOnFailure()
                throw FontImportError.invalidFont(name)
            }

            // Extract metadata
            let ctFont = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
            let familyName = CTFontCopyFamilyName(ctFont) as String
            let styleName = CTFontCopyName(ctFont, kCTFontStyleNameKey) as String?

            // UI-only utility families would collide with the bundled copy and
            // surface in the terminal font list via customFontFamilies
            if Self.hiddenUtilityFontFamilies.contains(familyName) {
                rollbackOnFailure()
                throw FontImportError.reservedFamily(familyName)
            }

            // Copy to Documents with UUID prefix
            let originalName = url.lastPathComponent
            let uniqueFilename = "\(UUID().uuidString)_\(originalName)"
            let destinationURL = documentsPathForCustomFont(uniqueFilename)

            do {
                try data.write(to: destinationURL)
            } catch {
                rollbackOnFailure()
                throw error
            }

            // Register with CoreText immediately
            var regError: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(destinationURL as CFURL, .process, &regError) {
                if isBundledFontFamily(familyName) {
                    // Conflict with bundled font — unregister bundled version and retry
                    unregisterBundledFontsForFamily(familyName)
                    unregisteredBundledFamilies.insert(familyName)
                    var retryError: Unmanaged<CFError>?
                    if !CTFontManagerRegisterFontsForURL(destinationURL as CFURL, .process, &retryError) {
                        try? FileManager.default.removeItem(at: destinationURL)
                        rollbackOnFailure()
                        throw FontImportError.registrationFailed(originalName)
                    }
                } else if isAlreadyRegisteredError(regError) && UIFont.familyNames.contains(familyName) {
                    // Font is already registered on the system (e.g., via Font Case).
                    // Keep the file; Ghostty resolves by family name so it will work.
                    logger.info("Font \(originalName) already available via system, storing metadata only")
                } else {
                    // Genuine registration failure — not a duplicate conflict
                    try? FileManager.default.removeItem(at: destinationURL)
                    rollbackOnFailure()
                    throw FontImportError.registrationFailed(originalName)
                }
            }

            importedFiles.append(ImportedFile(
                familyName: familyName,
                styleName: styleName,
                filename: uniqueFilename,
                originalName: originalName
            ))
        }

        if importedFiles.isEmpty {
            throw FontImportError.noFontsFound
        }

        // Group by family name and merge into existing families
        var updatedFamilyIDs: Set<UUID> = []
        let groupedByFamily = Dictionary(grouping: importedFiles, by: \.familyName)

        for (familyName, files) in groupedByFamily {
            let newFontFiles = files.map { file in
                CustomFontFamily.FontFile(
                    filename: file.filename,
                    originalName: file.originalName,
                    styleName: file.styleName
                )
            }

            if let existingIndex = customFontFamilies.firstIndex(where: { $0.configName == familyName }) {
                // Merge new styles, skip duplicates by style name
                let existingStyles = Set(customFontFamilies[existingIndex].fontFiles.compactMap(\.styleName))
                for newFile in newFontFiles {
                    if let style = newFile.styleName, existingStyles.contains(style) {
                        continue
                    }
                    customFontFamilies[existingIndex].fontFiles.append(newFile)
                }
                updatedFamilyIDs.insert(customFontFamilies[existingIndex].id)
            } else {
                let family = CustomFontFamily(
                    id: UUID(),
                    displayName: familyName,
                    configName: familyName,
                    fontFiles: newFontFiles,
                    importDate: Date()
                )
                customFontFamilies.append(family)
                updatedFamilyIDs.insert(family.id)
            }
        }

        // Sort custom families alphabetically
        customFontFamilies.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        saveCustomFontFamilies()

        // Now that the import transaction has fully succeeded, persist replacement state
        if !unregisteredBundledFamilies.isEmpty {
            saveReplacedBundledFamilies()
            loadAvailableFamilies()
        }

        // Refresh system fonts so newly-imported families don't appear in both sections
        loadSystemFonts()

        return customFontFamilies.filter { updatedFamilyIDs.contains($0.id) }
    }

    /// Delete a custom font family, unregistering from CoreText and removing files
    func deleteCustomFontFamily(id: UUID) {
        completeCatalogLoadIfNeeded()

        guard let index = customFontFamilies.firstIndex(where: { $0.id == id }) else { return }

        let family = customFontFamilies[index]
        let configName = family.configName
        let wasReplacingBundled = replacedBundledFamilies.contains(configName)

        // Unregister each font file from CoreText and delete from disk
        for file in family.fontFiles {
            let fileURL = documentsPathForCustomFont(file.filename)

            var error: Unmanaged<CFError>?
            CTFontManagerUnregisterFontsForURL(fileURL as CFURL, .process, &error)

            try? FileManager.default.removeItem(at: fileURL)
        }

        // If the deleted font was selected, reset to Ghostty Default
        if currentFontFamily == configName {
            currentFontFamily = nil
        }

        customFontFamilies.remove(at: index)
        saveCustomFontFamilies()

        // If this custom font was replacing a bundled font, restore the bundled version
        if wasReplacingBundled {
            reregisterBundledFontsForFamily(configName)
            saveReplacedBundledFamilies()
            loadAvailableFamilies()
        }

        // Refresh system fonts so deleted family can reappear in System section if applicable
        loadSystemFonts()
    }

    /// Re-reads custom font families from UserDefaults, registers any new fonts with CoreText,
    /// and refreshes the available families list. Call after restoring fonts from a backup.
    func reloadCustomFonts() {
        completeCatalogLoadIfNeeded()
        registerCustomFonts()
        loadAvailableFamilies()
        loadSystemFonts()
    }

    /// Create a preview font for a custom font family (Regular style preferred)
    func sampleFontForCustomFamily(_ family: CustomFontFamily) -> UIFont? {
        // Prefer Regular variant, fall back to first available
        let regularFile = family.fontFiles.first { $0.styleName?.contains("Regular") == true }
        let file = regularFile ?? family.fontFiles.first

        guard let file else { return nil }

        let fileURL = documentsPathForCustomFont(file.filename)
        return createFont(from: fileURL, size: 16)
    }

    // MARK: - Load Available Families

    /// Scan the fonts directory and build list of available font families
    private func loadAvailableFamilies() {
        var loader = makeCatalogLoader()
        loader.availableFamilies = availableFamilies
        loader.loadAvailableFamilies()
        availableFamilies = loader.availableFamilies
    }

    // MARK: - System Font Discovery

    /// Discover monospace fonts installed on the device (e.g., via Font Case)
    private func loadSystemFonts() {
        var loader = makeCatalogLoader()
        loader.availableFamilies = availableFamilies
        loader.loadSystemFonts()
        systemFontFamilies = loader.systemFontFamilies
    }

    // MARK: - Installed Font Access

    /// Outcome of choosing a font in the system font picker.
    enum InstalledFontSelection {
        case selected
        case notMonospace(family: String)
    }

    /// Select a font chosen in `UIFontPickerViewController`. iOS hides fonts
    /// another app installed (Font Case etc.) until this app asks for them.
    /// Request the whole family so bold and italic resolve too.
    func selectInstalledFont(_ descriptor: UIFontDescriptor) async -> InstalledFontSelection {
        let family = descriptor.object(forKey: .family) as? String
            ?? UIFont(descriptor: descriptor, size: 16).familyName
        await Self.requestFonts([Self.familyDescriptor(family)])
        refreshSystemFonts()

        let isListed = availableFamilies.contains { $0.configName == family }
            || systemFontFamilies.contains { $0.configName == family }
            || customFontFamilies.contains { $0.configName == family }
        guard isListed else { return .notMonospace(family: family) }
        // Reselecting the same family would keep Ghostty's fallback grid.
        if currentFontFamily == family {
            fontFamilyDidBecomeAvailable.send()
        } else {
            currentFontFamily = family
        }
        return .selected
    }

    /// Ask for a selected family Core Text can't find, e.g. one chosen on
    /// another device. Access, once granted, survives relaunches.
    private func requestInstalledFontIfMissing(_ family: String) {
        #if !targetEnvironment(macCatalyst)
        let descriptor = Self.familyDescriptor(family)
        let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatory) as? [CTFontDescriptor]
        guard matches?.isEmpty ?? true else { return }

        Task { [weak self] in
            guard await Self.requestFonts([descriptor]),
                  let self, self.currentFontFamily == family else { return }
            self.logger.info("Granted access to installed font family '\(family)'")
            if self.isCatalogLoaded { self.refreshSystemFonts() }
            self.fontFamilyDidBecomeAvailable.send()
        }
        #endif
    }

    /// Rescan after a grant: gaining access to a font isn't known to post
    /// kCTFontManagerRegisteredFontsChangedNotification.
    private func refreshSystemFonts() {
        completeCatalogLoadIfNeeded()
        FontCatalogLoader.invalidateMonospaceCache()
        loadSystemFonts()
    }

    private nonisolated static func familyDescriptor(_ family: String) -> CTFontDescriptor {
        CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
    }

    /// Returns true when every descriptor resolved.
    @discardableResult
    private nonisolated static func requestFonts(_ descriptors: [CTFontDescriptor]) async -> Bool {
        await withCheckedContinuation { continuation in
            CTFontManagerRequestFonts(descriptors as CFArray) { unresolved in
                continuation.resume(returning: CFArrayGetCount(unresolved) == 0)
            }
        }
    }

    private func setupFontRegistrationObserver() {
        fontRegistrationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCatalogLoaded else { return }
                FontCatalogLoader.invalidateMonospaceCache()
                self.loadSystemFonts()
            }
        }
    }

    /// Extract font family name and config name from a font file
    private func extractFontInfo(from url: URL) -> (displayName: String, configName: String)? {
        FontCatalogLoader.extractFontInfo(from: url)
    }

    /// Create a UIFont from a TTF file URL
    private func createFont(from url: URL, size: CGFloat) -> UIFont? {
        FontCatalogLoader.createFont(from: url, size: size)
    }

    /// Check if a CTFontManager registration error indicates a duplicate/already-registered font
    private func isAlreadyRegisteredError(_ error: Unmanaged<CFError>?) -> Bool {
        FontCatalogLoader.isAlreadyRegisteredError(error)
    }

    // MARK: - Bundled Font Replacement Helpers

    /// Check if a font family name matches one of our bundled font families
    private func isBundledFontFamily(_ familyName: String) -> Bool {
        // Utility fonts can never be replaced by imports; the profile icon UI depends on them
        guard !Self.hiddenUtilityFontFamilies.contains(familyName) else { return false }
        guard let fontsURL = findFontsDirectory() else { return false }
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: fontsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }

            if let (_, configName) = extractFontInfo(from: fileURL), configName == familyName {
                return true
            }
        }
        return false
    }

    /// Unregister all bundled font files for a given family from CoreText.
    /// Updates in-memory state only; call `saveReplacedBundledFamilies()` to persist after the transaction succeeds.
    private func unregisterBundledFontsForFamily(_ familyName: String) {
        guard let fontsURL = findFontsDirectory() else { return }
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: fontsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }

            if let (_, configName) = extractFontInfo(from: fileURL), configName == familyName {
                var error: Unmanaged<CFError>?
                CTFontManagerUnregisterFontsForURL(fileURL as CFURL, .process, &error)
                let filename = fileURL.lastPathComponent
                logger.debug("Unregistered bundled font: \(filename)")
            }
        }

        replacedBundledFamilies.insert(familyName)
    }

    /// Re-register bundled font files for a family that was previously replaced
    private func reregisterBundledFontsForFamily(_ familyName: String) {
        var loader = makeCatalogLoader()
        loader.reregisterBundledFontsForFamily(familyName)
        replacedBundledFamilies = loader.replacedBundledFamilies
    }

    private func saveReplacedBundledFamilies() {
        UserDefaults.standard.set(Array(replacedBundledFamilies), forKey: Self.replacedBundledFamiliesKey)
    }

    // MARK: - Persistence

    private func saveFontSize() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Font.size, currentFontSize)
    }

    private func saveFontFamily() {
        guard !isReloading else { return }
        if let family = currentFontFamily {
            SettingsStore.shared.set(Settings.Font.family, family)
        } else {
            SettingsStore.shared.reset(Settings.Font.family)
        }
    }

    private func saveLigaturesEnabled() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Font.ligatures, ligaturesEnabled)
    }

    private func saveCustomFontFamilies() {
        if let data = try? JSONEncoder().encode(customFontFamilies) {
            UserDefaults.standard.set(data, forKey: Self.customFontFamiliesKey)
        }
    }

    private func saveFontFeaturePrefs() {
        let serializable = enabledFontFeatures.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(serializable) {
            SettingsStore.shared.set(Settings.Font.featurePrefs, data)
        }
    }

    private func saveCellAdjustments() {
        // Drop zeroed entries so the dict stays clean across launches.
        let pruned = cellAdjustments.filter { !$0.value.isZero }
        if let data = try? JSONEncoder().encode(pruned) {
            SettingsStore.shared.set(Settings.Font.cellAdjustmentPrefs, data)
        }
    }

    // MARK: - Config Application

    /// Apply the current font size to a Ghostty configuration
    func applyFontSize(to config: Ghostty.Config) -> Bool {
        return config.setFontSize(Int(currentFontSize))
    }

    /// Apply the current font family to a Ghostty configuration
    func applyFontFamily(to config: Ghostty.Config) -> Bool {
        guard let family = currentFontFamily else {
            // nil = use Ghostty default, nothing to apply
            return true
        }
        return config.setFontFamily(family)
    }

    // MARK: - Helper Properties

    /// Display name for the current font family
    var currentFontFamilyDisplayName: String {
        if let family = currentFontFamily {
            if let bundled = availableFamilies.first(where: { $0.configName == family }) {
                return bundled.displayName
            }
            if let custom = customFontFamilies.first(where: { $0.configName == family }) {
                return custom.displayName
            }
            if let system = systemFontFamilies.first(where: { $0.configName == family }) {
                return system.displayName
            }
            return family
        }
        return "Ghostty Default"
    }

    // MARK: - Font Feature Discovery & Management

    /// AAT type/selector mappings for OpenType stylistic set features.
    /// Type 35 = kStylisticAlternativesType, Type 14 = kTypographicExtrasType.
    private static let aatToOpenType: [(aatTypeID: Int, aatSelectorOn: Int, aatSelectorOff: Int, tag: String)] = [
        (35, 2, 3, "ss01"),
        (35, 4, 5, "ss02"),
        (35, 6, 7, "ss03"),
        (35, 8, 9, "ss04"),
        (35, 10, 11, "ss05"),
        (35, 12, 13, "ss06"),
        (35, 14, 15, "ss07"),
        (35, 16, 17, "ss08"),
        (35, 18, 19, "ss09"),
        (35, 20, 21, "ss10"),
        (35, 22, 23, "ss11"),
        (35, 24, 25, "ss12"),
        (35, 26, 27, "ss13"),
        (35, 28, 29, "ss14"),
        (35, 30, 31, "ss15"),
        (35, 32, 33, "ss16"),
        (35, 34, 35, "ss17"),
        (35, 36, 37, "ss18"),
        (35, 38, 39, "ss19"),
        (35, 40, 41, "ss20"),
        (14, 4, 5, "zero"),
    ]

    /// Discover available OpenType font features for the given font family.
    /// Uses CoreText AAT feature tables and maps to OpenType tags.
    func discoverFeatures(for fontFamily: String?) -> [FontFeature] {
        guard let familyName = fontFamily else { return [] }

        // Create a CTFont from the family name
        let ctFont = CTFontCreateWithName(familyName as CFString, 16, nil)

        // Verify we got the right font (CoreText may substitute)
        let resolvedFamily = CTFontCopyFamilyName(ctFont) as String
        guard resolvedFamily == familyName else {
            logger.debug("Font family mismatch: requested '\(familyName)', got '\(resolvedFamily)'")
            return []
        }

        // Get AAT feature tables
        guard let features = CTFontCopyFeatures(ctFont) as? [[String: Any]] else {
            return []
        }

        // Build lookup of available AAT type+selector pairs and their names
        var availableSelectors: [String: String] = [:]  // "typeID:selectorID" -> name
        for feature in features {
            guard let typeID = feature[kCTFontFeatureTypeIdentifierKey as String] as? Int,
                  let selectors = feature[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] else {
                continue
            }

            for selector in selectors {
                guard let selectorID = selector[kCTFontFeatureSelectorIdentifierKey as String] as? Int else {
                    continue
                }
                let name = selector[kCTFontFeatureSelectorNameKey as String] as? String ?? ""
                let key = "\(typeID):\(selectorID)"
                availableSelectors[key] = name
            }
        }

        // Cross-reference with our mapping table
        var result: [FontFeature] = []
        for mapping in Self.aatToOpenType {
            let onKey = "\(mapping.aatTypeID):\(mapping.aatSelectorOn)"
            guard let name = availableSelectors[onKey] else { continue }

            let displayName = name.isEmpty ? mapping.tag.uppercased() : name
            result.append(FontFeature(
                tag: mapping.tag,
                name: displayName,
                aatTypeID: mapping.aatTypeID,
                aatSelectorOn: mapping.aatSelectorOn,
                aatSelectorOff: mapping.aatSelectorOff
            ))
        }

        return result
    }

    /// Get the set of enabled feature tags for a font family
    func enabledFeatureTags(for fontFamily: String?) -> Set<String> {
        guard let family = fontFamily else { return [] }
        return enabledFontFeatures[family] ?? []
    }

    /// Toggle a font feature on or off for a font family
    func setFeatureEnabled(_ tag: String, enabled: Bool, for fontFamily: String?) {
        guard let family = fontFamily else { return }

        var tags = enabledFontFeatures[family] ?? []
        if enabled {
            tags.insert(tag)
        } else {
            tags.remove(tag)
        }
        enabledFontFeatures[family] = tags

        saveFontFeaturePrefs()
        fontFeaturesDidChange.send()
    }

    /// Return a copy of the font with the user's enabled features applied via AAT attributes.
    func applyEnabledFeatures(to font: UIFont, for fontFamily: String?) -> UIFont {
        guard let family = fontFamily else { return font }
        let enabledTags = enabledFontFeatures[family] ?? []
        guard !enabledTags.isEmpty else { return font }

        var featureSettings: [[UIFontDescriptor.FeatureKey: Int]] = []
        for mapping in Self.aatToOpenType where enabledTags.contains(mapping.tag) {
            featureSettings.append([
                .type: mapping.aatTypeID,
                .selector: mapping.aatSelectorOn
            ])
        }
        guard !featureSettings.isEmpty else { return font }

        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: featureSettings
        ])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// Generate Ghostty config lines for the current font's enabled features
    func fontFeatureConfigLines() -> [String] {
        let tags = enabledFeatureTags(for: currentFontFamily)
        return tags.sorted().map { "font-feature = \($0)" }
    }

    // MARK: - Cell Adjustments

    /// Storage key for a given font family (`defaultFontKey` when nil).
    private func cellAdjustmentKey(for fontFamily: String?) -> String {
        fontFamily ?? Self.defaultFontKey
    }

    /// Returns the saved cell adjustments for a font family, or `.zero` if none.
    func cellAdjustments(for fontFamily: String?) -> CellAdjustments {
        cellAdjustments[cellAdjustmentKey(for: fontFamily)] ?? .zero
    }

    /// Replace the cell adjustments for a font family. Persists and notifies.
    func setCellAdjustments(_ adjustments: CellAdjustments, for fontFamily: String?) {
        let key = cellAdjustmentKey(for: fontFamily)
        if adjustments.isZero {
            cellAdjustments.removeValue(forKey: key)
        } else {
            cellAdjustments[key] = adjustments
        }
        saveCellAdjustments()
        cellAdjustmentsDidChange.send()
    }

    /// Update only the width percentage for a font family.
    func setCellWidth(_ percent: Int, for fontFamily: String?) {
        var adj = cellAdjustments(for: fontFamily)
        adj.widthPercent = percent
        setCellAdjustments(adj, for: fontFamily)
    }

    /// Update only the height percentage for a font family.
    func setCellHeight(_ percent: Int, for fontFamily: String?) {
        var adj = cellAdjustments(for: fontFamily)
        adj.heightPercent = percent
        setCellAdjustments(adj, for: fontFamily)
    }

    /// Generate Ghostty config lines for the current font's cell adjustments.
    /// Zero-valued axes are omitted so the config stays minimal.
    func cellAdjustmentConfigLines() -> [String] {
        let adj = cellAdjustments(for: currentFontFamily)
        var lines: [String] = []
        if adj.widthPercent != 0 {
            lines.append("adjust-cell-width = \(adj.widthPercent)%")
        }
        if adj.heightPercent != 0 {
            lines.append("adjust-cell-height = \(adj.heightPercent)%")
        }
        return lines
    }
}
