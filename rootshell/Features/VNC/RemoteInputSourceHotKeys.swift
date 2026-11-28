//
//  RemoteInputSourceHotKeys.swift
//  rootshell
//
//  Turns off system shortcuts for this app while a remote screen in the key
//  window holds keyboard capture, so they reach the remote. Modifier presses
//  are kept from the local input method, and active local input methods are
//  temporarily restricted to Roman layouts on the focused input context while
//  reserved shortcuts route to the remote.
//

#if targetEnvironment(macCatalyst) && STANDALONE

import UIKit
import os

/// The window server handles these before any app event, so key commands
/// cannot claim them. The per-connection switch only affects this process.
/// Hot keys other apps register have no such switch, so the global mode is
/// held only while this app is active. Both lapse with the process.
@MainActor
final class RemoteInputSourceHotKeys {
    static let shared = RemoteInputSourceHotKeys()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "RemoteInputSourceHotKeys")

    private static let hotKeys: [Int32] = [
        60, 61,  // Input sources: Ctrl+Space, Ctrl+Option+Space
        64, 65,  // Spotlight: Command+Space, Command+Option+Space
        27,      // Move focus to next window: Command+Grave
    ]

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias IsEnabledForConnection = @convention(c) (Int32, Int32) -> Bool
    private typealias SetEnabledForConnection = @convention(c) (Int32, Int32, Bool) -> Int32
    private typealias SetGlobalMode = @convention(c) (Int32, Int32) -> Int32

    private struct SkyLight {
        let connection: Int32
        let isEnabled: IsEnabledForConnection
        let setEnabled: SetEnabledForConnection
        let setGlobalMode: SetGlobalMode?
    }

    private let skyLight: SkyLight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let main = dlsym(handle, "SLSMainConnectionID"),
              let isEnabled = dlsym(handle, "SLSIsSymbolicHotKeyEnabledForConnection"),
              let setEnabled = dlsym(handle, "SLSSetSymbolicHotKeyEnabledForConnection") else {
            RemoteInputSourceHotKeys.logger.error("SkyLight symbolic hot key entry points unavailable")
            return nil
        }
        return SkyLight(
            connection: unsafeBitCast(main, to: MainConnectionID.self)(),
            isEnabled: unsafeBitCast(isEnabled, to: IsEnabledForConnection.self),
            setEnabled: unsafeBitCast(setEnabled, to: SetEnabledForConnection.self),
            setGlobalMode: dlsym(handle, "SLSSetGlobalHotKeyOperatingMode")
                .map { unsafeBitCast($0, to: SetGlobalMode.self) })
    }()

    private struct Claim {
        weak var owner: AnyObject?
        let isActive: () -> Bool
        let takesOtherAppHotKeys: () -> Bool
    }

    private struct RestrictedInputContext {
        weak var context: NSObject?
        var savedAllowedLocales: Any?
        var deferredObserver: SecureInputModeObserver?
    }

    private var claims: [ObjectIdentifier: Claim] = [:]
    /// Hot keys this class turned off; only these are turned back on.
    private var suspended: [Int32] = []
    private var globalHotKeysSuspended = false
    /// Input contexts whose `allowedInputSourceLocales` we restricted to Roman
    /// layouts while a local input method (e.g. Chinese IME) was active, keyed
    /// per context so a deferred restore in one window never blocks another.
    private var restrictedInputContexts: [ObjectIdentifier: RestrictedInputContext] = [:]

    private init() {
        // AppKit's names: a Catalyst scene can stay active behind another app.
        let names = [
            UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
            Notification.Name("NSApplicationDidBecomeActiveNotification"),
            Notification.Name("NSApplicationDidResignActiveNotification"),
            Notification.Name("NSTextInputContextKeyboardSelectionDidChangeNotification"),
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { RemoteInputSourceHotKeys.shared.update() }
            }
        }
    }

    /// Both are re-read on every update; call `update()` when either changes.
    /// `takesOtherAppHotKeys` leaves a keyboard way out: it also sends
    /// Command-Tab to the remote.
    func register(
        _ owner: AnyObject, isActive: @escaping () -> Bool, takesOtherAppHotKeys: @escaping () -> Bool
    ) {
        claims[ObjectIdentifier(owner)] = Claim(
            owner: owner, isActive: isActive, takesOtherAppHotKeys: takesOtherAppHotKeys)
        update()
    }

    func unregister(_ owner: AnyObject) {
        claims[ObjectIdentifier(owner)] = nil
        update()
    }

    func update() {
        claims = claims.filter { $0.value.owner != nil }
        let wanted = claims.values.contains { $0.isActive() }
        LocalInputMethodModifierGate.hidesModifierChanges =
            wanted && LocalInputMethodModifierGate.installed
        let wantsGlobal = Self.applicationIsActive
            && claims.values.contains { $0.isActive() && $0.takesOtherAppHotKeys() }
        updateInputMethodRestriction(active: wantsGlobal)
        guard let skyLight else { return }
        if wantsGlobal != globalHotKeysSuspended, let setGlobalMode = skyLight.setGlobalMode {
            // 0 enables every registered hot key, 1 disables them.
            _ = setGlobalMode(skyLight.connection, wantsGlobal ? 1 : 0)
            globalHotKeysSuspended = wantsGlobal
        }
        guard wanted == suspended.isEmpty else { return }
        if wanted {
            suspended = Self.hotKeys.filter { skyLight.isEnabled(skyLight.connection, $0) }
            for hotKey in suspended {
                _ = skyLight.setEnabled(skyLight.connection, hotKey, false)
            }
        } else {
            for hotKey in suspended {
                _ = skyLight.setEnabled(skyLight.connection, hotKey, true)
            }
            suspended = []
        }
    }

    private static let romanInputSourcesLocale = "NSAllRomanInputSourcesLocaleIdentifier"

    /// Third-party input methods (e.g. Doubao) watch modifier changes outside
    /// this process even when `UINSInputView` excludes `flagsChanged` from its
    /// input context, and `EnableSecureEventInput` still lets `flagsChanged`
    /// reach external event taps while breaking unrelated key remappers.
    /// Restricting the focused `NSTextInputContext` to Roman input sources
    /// asks TSM to deactivate the local IME only for this document (without
    /// touching plain keyboard layouts or other apps) and automatically
    /// restores it on app switch or process exit.
    private func updateInputMethodRestriction(active: Bool) {
        guard active else {
            restoreInputMethodRestrictions(except: nil)
            return
        }
        let activeContext = Self.activeInputContext
        let activeIsSecure = activeContext?.value(forKey: "isSecureInputMode") as? Bool == true
        restoreInputMethodRestrictions(except: activeIsSecure ? nil : activeContext.map(ObjectIdentifier.init))
        guard let context = activeContext, !activeIsSecure else { return }
        let id = ObjectIdentifier(context)
        if var existing = restrictedInputContexts[id] {
            existing.deferredObserver?.stop()
            existing.deferredObserver = nil
            let current = context.value(forKey: "allowedInputSourceLocales") as? [String]
            if current == [Self.romanInputSourcesLocale] {
                restrictedInputContexts[id] = existing
                return
            }
            // A local field replaced the context's allowed locales while
            // capture was away; drop the stale entry so we re-snapshot below.
            restrictedInputContexts[id] = nil
        }
        guard Self.currentInputSourceIsInputMethod else { return }
        // Record before mutating so a synchronous selection-change notification
        // re-entering `update()` sees the restriction already in place.
        restrictedInputContexts[id] = RestrictedInputContext(
            context: context,
            savedAllowedLocales: context.value(forKey: "allowedInputSourceLocales"),
            deferredObserver: nil
        )
        context.setValue([Self.romanInputSourcesLocale], forKey: "allowedInputSourceLocales")
    }

    private func restoreInputMethodRestrictions(except activeID: ObjectIdentifier?) {
        for id in Array(restrictedInputContexts.keys) where id != activeID {
            guard var entry = restrictedInputContexts[id] else { continue }
            guard let context = entry.context else {
                entry.deferredObserver?.stop()
                restrictedInputContexts[id] = nil
                continue
            }
            // If focus moved onto a secure text field on this input context,
            // defer restoration until secure mode ends so we neither weaken
            // the password field nor lose the saved locales afterward.
            if context.value(forKey: "isSecureInputMode") as? Bool == true {
                if entry.deferredObserver?.observing(context) != true {
                    entry.deferredObserver?.stop()
                    entry.deferredObserver = SecureInputModeObserver(context: context) {
                        RemoteInputSourceHotKeys.shared.update()
                    }
                    restrictedInputContexts[id] = entry
                }
                continue
            }
            entry.deferredObserver?.stop()
            let previous = entry.savedAllowedLocales
            restrictedInputContexts[id] = nil
            let current = context.value(forKey: "allowedInputSourceLocales") as? [String]
            guard current == [Self.romanInputSourcesLocale] else { continue }
            context.setValue(previous, forKey: "allowedInputSourceLocales")
        }
    }

    private static var activeInputContext: NSObject? {
        if let icClass = NSClassFromString("NSTextInputContext") as? NSObject.Type,
           let current = icClass.value(forKey: "currentInputContext") as? NSObject {
            return current
        }
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.value(forKey: "sharedApplication") as? NSObject,
              let keyWindow = app.value(forKey: "keyWindow") as? NSObject,
              let responder = keyWindow.value(forKey: "firstResponder") as? NSObject,
              responder.responds(to: NSSelectorFromString("inputContext")) else { return nil }
        return responder.value(forKey: "inputContext") as? NSObject
    }

    private static var currentInputSourceIsInputMethod: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            return false
        }
        let type = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        return type != (kTISTypeKeyboardLayout as String)
    }

    private static var applicationIsActive: Bool {
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.value(forKey: "sharedApplication") as? NSObject else { return false }
        return app.value(forKey: "isActive") as? Bool ?? false
    }
}

/// Watches `NSTextInputContext.secureInputMode` while a restore is deferred
/// behind a secure text field, then triggers cleanup once secure mode ends.
private final class SecureInputModeObserver: NSObject {
    private static let keyPath = "secureInputMode"
    private weak var observedContext: NSObject?
    private var onEnded: (@MainActor () -> Void)?

    init(context: NSObject, onEnded: @escaping @MainActor () -> Void) {
        self.observedContext = context
        self.onEnded = onEnded
        super.init()
        context.addObserver(self, forKeyPath: Self.keyPath, options: .new, context: nil)
    }

    func observing(_ context: NSObject) -> Bool {
        observedContext === context
    }

    func stop() {
        let context = observedContext
        observedContext = nil
        onEnded = nil
        context?.removeObserver(self, forKeyPath: Self.keyPath)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == Self.keyPath,
              let observed = observedContext,
              observed.value(forKey: "isSecureInputMode") as? Bool != true else { return }
        let callback = onEnded
        stop()
        // Run after `_reflectSecureInput:NO` finishes updating the context.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { callback?() }
        }
    }

    deinit {
        stop()
    }
}

/// The Mac input view offers each modifier change to the local input method
/// before UIKit, where a lone Shift switches its typing mode. Excluding the
/// event skips only that step; UIKit still gets the modifier press.
private enum LocalInputMethodModifierGate {
    nonisolated(unsafe) static var hidesModifierChanges = false

    /// False when the input view has no such check; nothing is hidden then.
    static let installed: Bool = {
        let selector = NSSelectorFromString("_shouldExcludeEventFromInputContext:")
        guard let inputView = NSClassFromString("UINSInputView"),
              let method = class_getInstanceMethod(inputView, selector) else { return false }
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, AnyObject) -> Bool = { view, event in
            // 12 is a modifier flags change.
            if hidesModifierChanges, (event as? NSObject)?.value(forKey: "type") as? UInt == 12 {
                return true
            }
            return original(view, selector, event)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        return true
    }()
}

#endif
