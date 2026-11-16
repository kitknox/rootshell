//
//  RemoteInputSourceHotKeys.swift
//  rootshell
//
//  Turns off system shortcuts for this app while a remote screen in the key
//  window holds keyboard capture, so they reach the remote. Modifier presses
//  are kept from the local input method for the same reason.
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

    private var claims: [ObjectIdentifier: Claim] = [:]
    /// Hot keys this class turned off; only these are turned back on.
    private var suspended: [Int32] = []
    private var globalHotKeysSuspended = false

    private init() {
        // AppKit's names: a Catalyst scene can stay active behind another app.
        let names = [
            UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
            Notification.Name("NSApplicationDidBecomeActiveNotification"),
            Notification.Name("NSApplicationDidResignActiveNotification"),
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
        guard let skyLight else { return }
        let wantsGlobal = Self.applicationIsActive
            && claims.values.contains { $0.isActive() && $0.takesOtherAppHotKeys() }
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

    private static var applicationIsActive: Bool {
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.value(forKey: "sharedApplication") as? NSObject else { return false }
        return app.value(forKey: "isActive") as? Bool ?? false
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
