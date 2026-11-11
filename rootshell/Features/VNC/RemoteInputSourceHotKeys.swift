//
//  RemoteInputSourceHotKeys.swift
//  rootshell
//
//  Turns off the system input-source shortcuts for this app while a remote
//  screen in the key window holds keyboard capture, so they reach the remote.
//

#if targetEnvironment(macCatalyst) && STANDALONE

import UIKit
import os

/// The window server handles Ctrl+Space before any app event, so key commands
/// cannot claim it. The per-connection switch only affects this process and
/// lapses with it.
@MainActor
final class RemoteInputSourceHotKeys {
    static let shared = RemoteInputSourceHotKeys()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "RemoteInputSourceHotKeys")

    /// Select the previous input source (Ctrl+Space) and select the next
    /// source in the Input menu (Ctrl+Option+Space).
    private static let hotKeys: [Int32] = [60, 61]

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias IsEnabledForConnection = @convention(c) (Int32, Int32) -> Bool
    private typealias SetEnabledForConnection = @convention(c) (Int32, Int32, Bool) -> Int32

    private struct SkyLight {
        let connection: Int32
        let isEnabled: IsEnabledForConnection
        let setEnabled: SetEnabledForConnection
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
            setEnabled: unsafeBitCast(setEnabled, to: SetEnabledForConnection.self))
    }()

    private struct Claim {
        weak var owner: AnyObject?
        let isActive: () -> Bool
    }

    private var claims: [ObjectIdentifier: Claim] = [:]
    /// Hot keys this class turned off; only these are turned back on.
    private var suspended: [Int32] = []

    private init() {
        for name in [UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { RemoteInputSourceHotKeys.shared.update() }
            }
        }
    }

    /// `isActive` is re-read on every update; call `update()` when it changes.
    func register(_ owner: AnyObject, isActive: @escaping () -> Bool) {
        claims[ObjectIdentifier(owner)] = Claim(owner: owner, isActive: isActive)
        update()
    }

    func unregister(_ owner: AnyObject) {
        claims[ObjectIdentifier(owner)] = nil
        update()
    }

    func update() {
        claims = claims.filter { $0.value.owner != nil }
        let wanted = claims.values.contains { $0.isActive() }
        guard wanted == suspended.isEmpty, let skyLight else { return }
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
}

#endif
