import Foundation
import Combine
import SwiftUI
import UIKit
import os.log
#if targetEnvironment(macCatalyst)
import ObjectiveC.runtime

/// Squircle path used by the Mac Catalyst dock-icon and About-panel image
/// composition (`shapedForMacDock`, `maskedAppIconPreview`). The runtime
/// SwiftUI clip on in-app previews has been retired in favor of the assets'
/// own baked-in alpha; this path stays so that Catalyst dock-icon work that
/// also adds Apple's 824×824 safe-zone padding has a single shape source.
private enum AppIconShape {
    private static let canonicalCanvas: CGFloat = 1024
    private static let canonicalCornerRadius: CGFloat = 185.4
    private static let cornerLimitFactor: CGFloat = 1.52866483

    static let safeZoneInset: CGFloat = 100
    static let safeZoneContentSize: CGFloat = canonicalCanvas - (safeZoneInset * 2)

    static func cgPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let minimumSide = min(rect.width, rect.height)
        let scaledRadius = canonicalCornerRadius * minimumSide / canonicalCanvas
        let lim = min(scaledRadius, minimumSide / 2 / cornerLimitFactor)

        func tl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * lim, y: rect.minY + y * lim) }
        func tr(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * lim, y: rect.minY + y * lim) }
        func br(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * lim, y: rect.maxY - y * lim) }
        func bl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * lim, y: rect.maxY - y * lim) }

        path.move(to: tl(1.52866483, 0))
        path.addLine(to: tr(1.52866471, 0))
        path.addCurve(to: tr(0.66993427, 0.06549600), control1: tr(1.08849323, 0), control2: tr(0.86840689, 0))
        path.addLine(to: tr(0.63149399, 0.07491100))
        path.addCurve(to: tr(0.07491176, 0.63149399), control1: tr(0.37282392, 0.16905899), control2: tr(0.16906013, 0.37282401))
        path.addCurve(to: tr(0, 1.52866483), control1: tr(0, 0.86840701), control2: tr(0, 1.08849299))
        path.addLine(to: br(0, 1.52866471))
        path.addCurve(to: br(0.06549569, 0.66993493), control1: br(0, 1.08849323), control2: br(0, 0.86840689))
        path.addLine(to: br(0.07491111, 0.63149399))
        path.addCurve(to: br(0.63149399, 0.07491111), control1: br(0.16905883, 0.37282392), control2: br(0.37282392, 0.16905883))
        path.addCurve(to: br(1.52866471, 0), control1: br(0.86840689, 0), control2: br(1.08849323, 0))
        path.addLine(to: bl(1.52866483, 0))
        path.addCurve(to: bl(0.66993397, 0.06549569), control1: bl(1.08849299, 0), control2: bl(0.86840701, 0))
        path.addLine(to: bl(0.63149399, 0.07491111))
        path.addCurve(to: bl(0.07491100, 0.63149399), control1: bl(0.37282401, 0.16905883), control2: bl(0.16906001, 0.37282392))
        path.addCurve(to: bl(0, 1.52866471), control1: bl(0, 0.86840689), control2: bl(0, 1.08849323))
        path.addLine(to: tl(0, 1.52866483))
        path.addCurve(to: tl(0.06549600, 0.66993397), control1: tl(0, 1.08849299), control2: tl(0, 0.86840701))
        path.addLine(to: tl(0.07491100, 0.63149399))
        path.addCurve(to: tl(0.63149399, 0.07491100), control1: tl(0.16906001, 0.37282401), control2: tl(0.37282401, 0.16906001))
        path.addCurve(to: tl(1.52866483, 0), control1: tl(0.86840701, 0), control2: tl(1.08849299, 0))

        path.closeSubpath()
        return path
    }

    static func bezierPath(in rect: CGRect) -> UIBezierPath {
        UIBezierPath(cgPath: cgPath(in: rect))
    }
}
#endif

/// Manages the user-selected app icon (primary vs. alternate bundles) and keeps
/// the in-app display image and the Live Activity widget in sync with the choice.
@MainActor
final class AppIconManager: ObservableObject {
    static let shared = AppIconManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AppIconManager")

    private static let storageKey = "selectedAppIconVariant"
    private static let appGroupIdentifier = AppIdentifiers.defaultAppGroupID

    /// Selectable app-icon variants. Raw values match the alternate-icon names
    /// declared in the Xcode build setting `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`.
    /// The empty string represents the primary icon (passed as `nil` to
    /// `setAlternateIconName`).
    enum AppIconVariant: String, CaseIterable, Codable, Identifiable, Sendable {
        case defaultIcon = ""
        case black = "AppIconBlack"
        case crt = "AppIconCRT"
        case noBorder = "AppIconNoBorder"
        case underscore = "AppIconUnderscore"
        case sixColors = "AppIconSixColors"
        case sixColorsDark = "AppIconSixColorsDark"
        case original = "AppIconOrig"
        case radicalSolarizedDark = "AppIconRadicalSolarizedDark"
        case radicalSolarizedLight = "AppIconRadicalSolarizedLight"
        case radicalDracula = "AppIconRadicalDracula"
        case radicalNord = "AppIconRadicalNord"
        case radicalGruvboxDark = "AppIconRadicalGruvboxDark"
        case radicalTokyoNight = "AppIconRadicalTokyoNight"
        case radicalCatppuccin = "AppIconRadicalCatppuccin"
        case radicalBases = "AppIconRadicalBases"
        case radicalMonoLight = "AppIconRadicalMonoLight"
        case radicalMonokai = "AppIconRadicalMonokai"
        case radicalMonoDark = "AppIconRadicalMonoDark"
        case radicalRosePine = "AppIconRadicalRosePine"

        var id: String { rawValue }

        static let standardVariants: [AppIconVariant] = [
            .defaultIcon,
            .black,
            .crt,
            .noBorder,
            .underscore,
            .sixColors,
            .sixColorsDark,
            .original
        ]

        static let radicalOfTheUnknownVariants: [AppIconVariant] = [
            .radicalSolarizedDark,
            .radicalSolarizedLight,
            .radicalDracula,
            .radicalNord,
            .radicalGruvboxDark,
            .radicalTokyoNight,
            .radicalCatppuccin,
            .radicalBases,
            .radicalMonoLight,
            .radicalMonokai,
            .radicalMonoDark,
            .radicalRosePine
        ]

        /// Human-visible label for settings.
        var displayName: String {
            switch self {
            case .defaultIcon:
                return String(localized: "Blue", comment: "App icon choice: the current default icon")
            case .black:
                return String(localized: "Black", comment: "App icon choice: black variant")
            case .crt:
                return String(localized: "CRT", comment: "App icon choice: retro CRT variant")
            case .noBorder:
                return String(localized: "Blue - No Border", comment: "App icon choice: borderless variant")
            case .underscore:
                return String(localized: "Underscore", comment: "App icon choice: underscore variant")
            case .sixColors:
                return String(localized: "Six Colors", comment: "App icon choice: retro rainbow-stripe variant")
            case .sixColorsDark:
                return String(localized: "Six Colors Dark", comment: "App icon choice: dark retro rainbow-stripe variant")
            case .original:
                return String(localized: "Original", comment: "App icon choice: the previous default blue icon")
            case .radicalSolarizedDark:
                return String(localized: "Solarized Dark", comment: "App icon choice: Radical of the Unknown Solarized Dark variant")
            case .radicalSolarizedLight:
                return String(localized: "Solarized Light", comment: "App icon choice: Radical of the Unknown Solarized Light variant")
            case .radicalDracula:
                return String(localized: "Dracula", comment: "App icon choice: Radical of the Unknown Dracula variant")
            case .radicalNord:
                return String(localized: "Nord", comment: "App icon choice: Radical of the Unknown Nord variant")
            case .radicalGruvboxDark:
                return String(localized: "Gruvbox Dark", comment: "App icon choice: Radical of the Unknown Gruvbox Dark variant")
            case .radicalTokyoNight:
                return String(localized: "Tokyo Night", comment: "App icon choice: Radical of the Unknown Tokyo Night variant")
            case .radicalCatppuccin:
                return String(localized: "Catppuccin", comment: "App icon choice: Radical of the Unknown Catppuccin variant")
            case .radicalBases:
                return String(localized: "Bases", comment: "App icon choice: Radical of the Unknown Bases variant")
            case .radicalMonoLight:
                return String(localized: "Mono Light", comment: "App icon choice: Radical of the Unknown Mono Light variant")
            case .radicalMonokai:
                return String(localized: "Monokai", comment: "App icon choice: Radical of the Unknown Monokai variant")
            case .radicalMonoDark:
                return String(localized: "Mono Dark", comment: "App icon choice: Radical of the Unknown Mono Dark variant")
            case .radicalRosePine:
                return String(localized: "Rose Pine", comment: "App icon choice: Radical of the Unknown Rose Pine variant")
            }
        }

        /// Asset-catalog name for the composed display preview PNG. These are
        /// flat 1024px renders of each icon (including gradient + glass) and
        /// are safe to load as a runtime `UIImage`. They are NOT the actual
        /// `.icon` bundles — those are system-icon-only and crash when loaded
        /// via `UIImage(named:)`.
        var previewAssetName: String {
            switch self {
            case .defaultIcon:    return "AppIconPreview"
            case .black:          return "AppIconBlackPreview"
            case .crt:            return "AppIconCRTPreview"
            case .noBorder:       return "AppIconNoBorderPreview"
            case .underscore:     return "AppIconUnderscorePreview"
            case .sixColors:      return "AppIconSixColorsPreview"
            case .sixColorsDark:  return "AppIconSixColorsDarkPreview"
            case .original:       return "AppIconOrigPreview"
            case .radicalSolarizedDark,
                 .radicalSolarizedLight,
                 .radicalDracula,
                 .radicalNord,
                 .radicalGruvboxDark,
                 .radicalTokyoNight,
                 .radicalCatppuccin,
                 .radicalBases,
                 .radicalMonoLight,
                 .radicalMonokai,
                 .radicalMonoDark,
                 .radicalRosePine:
                return "\(rawValue)Preview"
            }
        }

        /// Value passed to `UIApplication.setAlternateIconName(_:)`.
        var alternateIconName: String? {
            self == .defaultIcon ? nil : rawValue
        }

        init(alternateIconName: String?) {
            guard let name = alternateIconName,
                  let variant = AppIconVariant(rawValue: name) else {
                self = .defaultIcon
                return
            }
            self = variant
        }
    }

    /// True when the running platform supports alternate icons. Hides the
    /// settings UI on visionOS. Mac Catalyst reports
    /// `supportsAlternateIcons == false` in some Xcode / macOS combinations
    /// even when `CFBundleAlternateIcons` is present in the Info.plist, so we
    /// trust our build-time configuration there — `setAlternateIconName` still
    /// works and any failure is logged.
    static var isSupported: Bool {
        #if os(visionOS)
        return false
        #elseif targetEnvironment(macCatalyst)
        return true
        #else
        return UIApplication.shared.supportsAlternateIcons
        #endif
    }

    @Published var selectedVariant: AppIconVariant {
        didSet {
            guard oldValue != selectedVariant else { return }
            guard ProtectedDataGuard.isAvailable else { return }
            if isReloading {
                mirrorToAppGroup(selectedVariant)
            } else {
                persist(selectedVariant)
            }
            applyToSystem(selectedVariant)
            notifyLiveActivity()
        }
    }

    private var isReloading = false

    private init() {
        // Prefer the system's current alternate icon name so we stay in sync if
        // the user swapped it through the iOS Settings app while rootshell was
        // suspended. Mac Catalyst uses a runtime-only dock icon that doesn't
        // persist, so there the stored value is authoritative.
        let storedVariant = SettingsStore.shared.get(Settings.Theme.appIconVariant)

        #if targetEnvironment(macCatalyst)
        let initial = storedVariant
        #else
        let systemVariant = AppIconVariant(alternateIconName: UIApplication.shared.alternateIconName)
        // A `.defaultIcon` systemVariant (nil alternateIconName) is ambiguous on
        // iOS 26: it can mean "primary icon is really active" OR an early-launch
        // misread against an `.icon` bundle alternate. Only let the system
        // override storage when it reports a concrete non-default alternate —
        // otherwise trust the user's last explicit pick, so a misread can't
        // silently reset the Settings/About UI to "Blue".
        let initial: AppIconVariant =
            (systemVariant != .defaultIcon && systemVariant != storedVariant)
                ? systemVariant
                : storedVariant
        #endif

        self.selectedVariant = initial

        // Sync UserDefaults back to the system value if they drifted.
        if initial != storedVariant, ProtectedDataGuard.isAvailable {
            persist(initial)
        }

        SettingsRefreshHub.shared.register(keys: [Settings.Theme.appIconVariant.name]) { [weak self] keys in
            self?.reload(keys: keys)
        }

        #if targetEnvironment(macCatalyst)
        // Mac Catalyst: reapply the stored choice so the dock icon matches
        // across launches (the AppKit dock image doesn't persist on its own).
        // Defer to after UIApplicationDidFinishLaunching — NSApplication's
        // icon slot isn't ready during our own init, so an immediate call is
        // silently swallowed and the dock keeps the primary icon.
        if initial != .defaultIcon {
            NotificationCenter.default.addObserver(
                forName: UIApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Delivered on .main, so the hop is already made.
                MainActor.assumeIsolated {
                    self?.applyMacCatalystDockIcon(initial)
                }
            }
            // Belt-and-suspenders: if the notification already fired (we
            // instantiated after launch finished) run on the next runloop tick.
            DispatchQueue.main.async { [weak self] in
                self?.applyMacCatalystDockIcon(initial)
            }
        }
        #else
        // iOS / iPadOS: reconcile when the app becomes active. An App
        // Intent (Shortcut/Siri) running in a separate process can persist
        // a new variant to the app group but can't actually swap the
        // home-screen icon — `setAlternateIconName` only takes effect from
        // the main app's UIApplication. Same logic also catches the case
        // where the intent ran in-process but the app wasn't yet `.active`,
        // which silently no-ops the call without firing the system alert.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileFromAppGroup()
            }
        }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    /// Reads the variant persisted to the shared app group and applies it to
    /// the system if the home-screen icon hasn't caught up. Safe to call
    /// repeatedly — short-circuits when the system already matches.
    @MainActor
    private func reconcileFromAppGroup() {
        guard ProtectedDataGuard.isAvailable else { return }
        guard let groupDefaults = UserDefaults(suiteName: Self.appGroupIdentifier) else { return }
        let storedRaw = groupDefaults.string(forKey: Self.storageKey) ?? ""
        let storedVariant = AppIconVariant(rawValue: storedRaw) ?? .defaultIcon
        let systemVariant = AppIconVariant(alternateIconName: UIApplication.shared.alternateIconName)
        guard storedVariant != systemVariant else { return }

        Self.logger.info("Reconciling app icon: stored=\(storedRaw, privacy: .public) system=\(systemVariant.rawValue, privacy: .public)")

        // If the in-memory @Published also drifted, set it — didSet handles
        // persist/apply/Live Activity. Otherwise call apply directly, since
        // didSet won't fire on a no-op assignment.
        if selectedVariant != storedVariant {
            selectedVariant = storedVariant
        } else {
            applyToSystem(storedVariant)
        }
    }
    #endif

    // MARK: - Persistence

    private func persist(_ variant: AppIconVariant) {
        SettingsStore.shared.set(Settings.Theme.appIconVariant, variant)
        mirrorToAppGroup(variant)
    }

    /// App-group copy read by the App Intent process; kept raw on purpose.
    private func mirrorToAppGroup(_ variant: AppIconVariant) {
        if let groupDefaults = UserDefaults(suiteName: Self.appGroupIdentifier) {
            groupDefaults.set(variant.rawValue, forKey: Self.storageKey)
        }
    }

    func reload(keys: Set<String>) {
        isReloading = true
        selectedVariant = SettingsStore.shared.get(Settings.Theme.appIconVariant)
        isReloading = false
    }

    // MARK: - System Icon

    private func applyToSystem(_ variant: AppIconVariant) {
        #if targetEnvironment(macCatalyst)
        applyMacCatalystDockIcon(variant)
        #else
        guard UIApplication.shared.supportsAlternateIcons else {
            Self.logger.warning("supportsAlternateIcons is false — skipping setAlternateIconName")
            return
        }
        let targetName = variant.alternateIconName
        if UIApplication.shared.alternateIconName == targetName {
            return
        }
        UIApplication.shared.setAlternateIconName(targetName) { error in
            if let error {
                let message = error.localizedDescription
                Self.logger.error("setAlternateIconName failed: \(message)")
            }
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Builds an AppKit image for the currently selected in-app icon preview so
    /// Catalyst UI such as the About panel can mirror the user's chosen icon.
    func makeMacCatalystAboutPanelIcon() -> AnyObject? {
        let assetName = selectedVariant.previewAssetName
        guard let uiImage = UIImage(named: assetName) else {
            Self.logger.error("UIImage(named: \(assetName)) returned nil")
            return nil
        }
        let masked = Self.maskedAppIconPreview(uiImage)
        guard let pngData = masked.pngData(),
              let nsImage = Self.makeNSImage(pngData: pngData) else {
            Self.logger.error("Failed to build NSImage for About panel icon \(assetName)")
            return nil
        }
        return nsImage
    }

    /// Mac Catalyst does not emit `CFBundleAlternateIcons` for `.icon` / mixed
    /// catalogs (Xcode 26.3 actool limitation), so `setAlternateIconName`
    /// has nothing to swap to. Instead we set the dock icon at runtime via
    /// AppKit's `NSApplication.applicationIconImage`, bridged through KVC to
    /// avoid linking AppKit directly from a Mac Catalyst target. The raw
    /// preview PNGs are flat full-bleed squares (no mac-style padding or
    /// rounded corners), so we reshape them to match the macOS 26 dock-icon
    /// silhouette before handing off.
    /// On Standalone (non-sandboxed) builds we additionally call
    /// `NSWorkspace.setIcon(_:forFile:)` to write the icon into the .app
    /// bundle so Finder/Dock keep showing the user's choice even when the
    /// app isn't running. The runtime KVC step still runs first so the
    /// in-session swap is instant. `AppIconManager.init` re-applies the
    /// stored variant on every launch to keep both paths consistent.
    private func applyMacCatalystDockIcon(_ variant: AppIconVariant) {
        guard let nsApplication = NSClassFromString("NSApplication") as? NSObject.Type,
              let shared = nsApplication.value(forKey: "sharedApplication") as? NSObject else {
            Self.logger.warning("NSApplication unavailable — can't set dock icon on Mac Catalyst")
            return
        }
        // Every variant — including .defaultIcon — has a preview asset
        // (AppIconPreview for default). We don't try to "clear" the icon
        // back to the bundle's compiled-in default: setting
        // applicationIconImage = nil + setIcon(nil, forFile:) leaves the
        // running dock tile stuck on whatever AppKit had cached, and Dock
        // / Finder don't refetch the bundle icon reliably after the xattr
        // is cleared. Treating default as just another variant keeps the
        // runtime KVC swap and the bundle xattr in sync.
        let assetName = variant.previewAssetName
        guard let uiImage = UIImage(named: assetName) else {
            Self.logger.error("UIImage(named: \(assetName)) returned nil")
            return
        }
        let masked = Self.shapedForMacDock(uiImage)
        guard let pngData = masked.pngData(),
              let nsImage = Self.makeNSImage(pngData: pngData) else {
            Self.logger.error("Failed to build NSImage from masked dock icon for \(assetName)")
            return
        }
        shared.setValue(nsImage, forKey: "applicationIconImage")
        #if STANDALONE
        persistIconToBundle(nsImage)
        #endif
    }

    #if STANDALONE
    /// Writes the selected icon into the .app bundle so Finder and the Dock
    /// show the user's choice when the app isn't running. Calls
    /// `-[NSWorkspace setIcon:forFile:options:]` (the same primitive Ghostty
    /// uses for its `macos-icon = custom` feature), then nudges Finder/Dock
    /// to refresh their caches via `noteFileSystemChanged:`. Pass `nil` for
    /// `nsImage` to clear the override and restore the compiled-in icon.
    ///
    /// Only safe in non-sandboxed builds. AppKit isn't directly importable
    /// from a Mac Catalyst target, so the calls go through the Objective-C
    /// runtime — same pattern as `applyMacCatalystDockIcon` above.
    private func persistIconToBundle(_ nsImage: AnyObject?) {
        guard let workspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type,
              let shared = workspaceClass.value(forKey: "sharedWorkspace") as? NSObject else {
            Self.logger.warning("NSWorkspace unavailable — skipping bundle icon persistence")
            return
        }

        let bundlePath = Bundle.main.bundlePath as NSString
        let setIconSel = NSSelectorFromString("setIcon:forFile:options:")

        guard let method = class_getInstanceMethod(workspaceClass, setIconSel) else {
            Self.logger.error("setIcon:forFile:options: not found — bundle persistence unavailable")
            return
        }

        // Three-argument selector with NSUInteger + BOOL — perform(...) tops out
        // at two object args, so we call the IMP directly through a typed cast.
        typealias SetIconIMP = @convention(c) (NSObject, Selector, AnyObject?, NSString, UInt) -> Bool
        let imp = unsafeBitCast(method_getImplementation(method), to: SetIconIMP.self)
        let success = imp(shared, setIconSel, nsImage, bundlePath, 0)

        if !success {
            Self.logger.error("NSWorkspace.setIcon returned false (write-protected bundle?) — runtime icon still applied")
        }

        _ = shared.perform(NSSelectorFromString("noteFileSystemChanged:"), with: bundlePath as String)
    }
    #endif

    /// Draws `source` into Apple's `824×824` safe zone on a `1024×1024` canvas
    /// and clips with the same squircle path used by the local icon-generator
    /// reference implementation.
    private static func shapedForMacDock(_ source: UIImage) -> UIImage {
        let side: CGFloat = 1024
        let inset = AppIconShape.safeZoneInset
        let contentSize = AppIconShape.safeZoneContentSize
        let pixelWidth = source.cgImage.map { CGFloat($0.width) } ?? source.size.width
        let pixelHeight = source.cgImage.map { CGFloat($0.height) } ?? source.size.height
        let scale = min(contentSize / pixelWidth, contentSize / pixelHeight)
        let scaledWidth = pixelWidth * scale
        let scaledHeight = pixelHeight * scale
        let drawRect = CGRect(
            x: inset + (contentSize - scaledWidth) / 2,
            y: inset + (contentSize - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )
        let contentRect = CGRect(x: inset, y: inset, width: contentSize, height: contentSize)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        )
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
            cgContext.addPath(AppIconShape.cgPath(in: contentRect))
            cgContext.clip()

            source.draw(in: drawRect)
        }
    }

    /// Matches the in-app preview treatment used by Settings/About: same icon
    /// artwork, but clipped to the shared squircle app-icon shape.
    private static func maskedAppIconPreview(_ source: UIImage) -> UIImage {
        let side: CGFloat = 1024

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        )
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            AppIconShape.bezierPath(in: rect).addClip()
            source.draw(in: rect)
        }
    }

    /// Bridges PNG bytes to an NSImage on Mac Catalyst without importing
    /// AppKit. Uses the ObjC runtime to allocate an uninitialized NSImage and
    /// call `-[NSImage initWithData:]`.
    private static func makeNSImage(pngData: Data) -> AnyObject? {
        guard let cls = NSClassFromString("NSImage") else { return nil }
        guard let instance = class_createInstance(cls, 0) else { return nil }
        guard let nsObj = instance as? NSObject else { return nil }
        _ = nsObj.perform(NSSelectorFromString("initWithData:"), with: pngData)
        return nsObj
    }
    #endif

    // MARK: - Live Activity

    private func notifyLiveActivity() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        LiveActivityManager.shared.refreshIconVariant()
        #endif
    }
}
