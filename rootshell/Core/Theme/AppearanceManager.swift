import Foundation
import Combine
import SwiftUI
import OSLog

#if canImport(UIKit)
import UIKit
#endif

/// Manages appearance mode (light/dark/system) for the app UI
@MainActor
class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AppearanceManager")

    /// Appearance mode options
    enum AppearanceMode: String, CaseIterable {
        case automatic = "automatic"
        case light = "light"
        case dark = "dark"

        var displayName: String {
            switch self {
            case .automatic: return String(localized: "Automatic", comment: "Appearance mode: follow system setting")
            case .light: return String(localized: "Light", comment: "Appearance mode: light theme")
            case .dark: return String(localized: "Dark", comment: "Appearance mode: dark theme")
            }
        }

        /// Convert to SwiftUI ColorScheme (nil means system default)
        var colorScheme: ColorScheme? {
            switch self {
            case .automatic: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        #if canImport(UIKit)
        /// UIKit trait override equivalent (.unspecified means follow system)
        var interfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .automatic: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
        #endif
    }

    private static let ownedKeys: Set<String> = [
        Settings.Theme.appearanceMode.name, Settings.Theme.themedUI.name,
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    private var isReloading = false

    /// Currently selected appearance mode
    @Published var currentAppearanceMode: AppearanceMode {
        didSet {
            applyWindowOverrides()
            guard ProtectedDataGuard.isAvailable else { return }
            saveAppearanceMode()
            appearanceModeDidChange.send(currentAppearanceMode)
        }
    }

    /// Whether to apply terminal theme colors to sheets and settings
    @Published var themedUIEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable, !isReloading else { return }
            SettingsStore.shared.set(Settings.Theme.themedUI, themedUIEnabled)
        }
    }

    /// Publisher that emits when appearance mode changes
    let appearanceModeDidChange = PassthroughSubject<AppearanceMode, Never>()

    #if canImport(UIKit)
    private var windowObserver: NSObjectProtocol?
    #endif

    private init() {
        self.currentAppearanceMode = SettingsStore.shared.get(Settings.Theme.appearanceMode)
        self.themedUIEnabled = SettingsStore.shared.get(Settings.Theme.themedUI)

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }

        #if canImport(UIKit)
        // Stamp the override onto every window as it appears (covers windows
        // created after a mode change, restored scenes, visor, AI agent).
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppearanceManager.shared.applyWindowOverrides()
            }
        }
        #endif
        // Windows already on screen missed the observer above.
        applyWindowOverrides()
    }

    /// Save current appearance mode through the settings store
    private func saveAppearanceMode() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Theme.appearanceMode, currentAppearanceMode)
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if keys.contains(Settings.Theme.appearanceMode.name) {
            currentAppearanceMode = SettingsStore.shared.get(Settings.Theme.appearanceMode)
        }
        if keys.contains(Settings.Theme.themedUI.name) {
            themedUIEnabled = SettingsStore.shared.get(Settings.Theme.themedUI)
        }
    }

    // MARK: - Window-level appearance enforcement

    /// Forces the window-level appearance to match the selected mode.
    ///
    /// `.preferredColorScheme` only overrides the SwiftUI environment; system
    /// materials (Liquid Glass, blur) resolve against the window's trait
    /// collection, and on Mac Catalyst against the AppKit window appearance.
    /// Without this override, a forced-Dark app with the OS in Light mode
    /// renders the selected-tab glass white whenever the window is inactive
    /// (or whenever Reduce Transparency / Increase Contrast flattens glass to
    /// an appearance-resolved fill). See GitHub issue #250.
    func applyWindowOverrides() {
        #if canImport(UIKit)
        let style = currentAppearanceMode.interfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
        #endif
        applyAppKitAppearance()
    }

    /// Catalyst: also pin NSApplication.appearance so the titlebar and the
    /// AppKit-side material passes (including inactive-window rendering)
    /// resolve to the forced mode. Uses the same ObjC-runtime bridge pattern
    /// as WindowAccessor.
    private func applyAppKitAppearance() {
        #if targetEnvironment(macCatalyst)
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject else {
            Self.logger.warning("Failed to resolve NSApplication for appearance override")
            return
        }

        let appearanceName: String?
        switch currentAppearanceMode {
        case .automatic: appearanceName = nil
        case .light: appearanceName = "NSAppearanceNameAqua"
        case .dark: appearanceName = "NSAppearanceNameDarkAqua"
        }

        var appearance: NSObject?
        if let appearanceName {
            guard let appearanceClass = NSClassFromString("NSAppearance") as? NSObject.Type,
                  let resolved = appearanceClass.perform(
                      NSSelectorFromString("appearanceNamed:"),
                      with: appearanceName
                  )?.takeUnretainedValue() as? NSObject else {
                Self.logger.warning("Failed to resolve NSAppearance \(appearanceName)")
                return
            }
            appearance = resolved
        }

        sharedApp.setValue(appearance, forKey: "appearance")
        #endif
    }
}
