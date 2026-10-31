//
//  SwipeGestureManager.swift
//  rootshell
//
//  Stores user-customized horizontal-swipe bindings for the terminal.
//  Single source of truth for both the iOS direct-touch swipe gestures and
//  the Mac Catalyst trackpad swipe pan gesture.
//

import Foundation
import SwiftUI
import Observation
import os

enum TerminalSwipeArea {
    case top, bottom
}

@MainActor
@Observable
final class SwipeGestureManager {
    static let shared = SwipeGestureManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SwipeGestureManager")

    static let bindingsDidChangeNotification = Notification.Name("SwipeGestureBindingsDidChange")

    // MARK: - Defaults

    static let defaultLeftBinding: SwipeGestureBinding = .preset(.nextTab)
    static let defaultRightBinding: SwipeGestureBinding = .preset(.previousTab)

    // MARK: - Observable Properties

    /// When true, didSet skips `save()` so a batch update can save once at the end.
    private var isBatching = false

    var separateAreasEnabled = false {
        didSet { if !isBatching { save() } }
    }
    private(set) var topLeftBinding: SwipeGestureBinding = SwipeGestureManager.defaultLeftBinding {
        didSet { if !isBatching { save() } }
    }
    private(set) var topRightBinding: SwipeGestureBinding = SwipeGestureManager.defaultRightBinding {
        didSet { if !isBatching { save() } }
    }
    private(set) var bottomLeftBinding: SwipeGestureBinding = SwipeGestureManager.defaultLeftBinding {
        didSet { if !isBatching { save() } }
    }
    private(set) var bottomRightBinding: SwipeGestureBinding = SwipeGestureManager.defaultRightBinding {
        didSet { if !isBatching { save() } }
    }

    var activeTouchBindings: [SwipeGestureBinding] {
        separateAreasEnabled
            ? [topLeftBinding, topRightBinding, bottomLeftBinding, bottomRightBinding]
            : [leftBinding, rightBinding]
    }

    private(set) var leftBinding: SwipeGestureBinding {
        didSet { if !isBatching { save() } }
    }

    private(set) var rightBinding: SwipeGestureBinding {
        didSet { if !isBatching { save() } }
    }

    var isCustomized: Bool {
        separateAreasEnabled || leftBinding != Self.defaultLeftBinding || rightBinding != Self.defaultRightBinding
            || topLeftBinding != Self.defaultLeftBinding || topRightBinding != Self.defaultRightBinding
            || bottomLeftBinding != Self.defaultLeftBinding || bottomRightBinding != Self.defaultRightBinding
    }

    // MARK: - Init

    private init() {
        let stored = Self.load()
        leftBinding = stored?.left ?? Self.defaultLeftBinding
        rightBinding = stored?.right ?? Self.defaultRightBinding
        isBatching = true
        restoreAreas(stored)
        isBatching = false

        SettingsRefreshHub.shared.register(keys: [Settings.Gestures.swipeBindings.name]) { [weak self] keys in
            self?.reload(keys: keys)
        }

        // Observe toolbar custom-key changes so we can clear any swipe binding
        // that referenced a now-deleted custom key. Without this the recognizer
        // would stay enabled and silently consume the gesture. Singleton lives
        // for the app's lifetime so we don't track the observer for removal.
        NotificationCenter.default.addObserver(
            forName: KeyboardToolbarManager.layoutDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearOrphanedReferences()
            }
        }
    }

    /// Reset any `customKeyRef` binding whose target has been deleted from
    /// KeyboardToolbarManager. Called whenever the toolbar layout changes.
    private func clearOrphanedReferences() {
        let manager = KeyboardToolbarManager.shared
        for area in [TerminalSwipeArea.top, .bottom] {
            for direction in [SwipeDirection.left, .right] {
                if case .customKeyRef(let id) = areaBinding(for: direction, area: area), manager.customKey(for: id) == nil {
                    setBinding(.preset(.none), for: direction, area: area)
                }
            }
        }
        if case .customKeyRef(let id) = leftBinding, manager.customKey(for: id) == nil {
            leftBinding = .preset(.none)
        }
        if case .customKeyRef(let id) = rightBinding, manager.customKey(for: id) == nil {
            rightBinding = .preset(.none)
        }
    }

    // MARK: - Public API

    func binding(for direction: SwipeDirection, area: TerminalSwipeArea? = nil) -> SwipeGestureBinding {
        if separateAreasEnabled, let area { return areaBinding(for: direction, area: area) }
        switch direction {
        case .left: return leftBinding
        case .right: return rightBinding
        }
    }

    func areaBinding(for direction: SwipeDirection, area: TerminalSwipeArea) -> SwipeGestureBinding {
        switch (area, direction) {
        case (.top, .left): return topLeftBinding
        case (.top, .right): return topRightBinding
        case (.bottom, .left): return bottomLeftBinding
        case (.bottom, .right): return bottomRightBinding
        }
    }

    func setBinding(_ binding: SwipeGestureBinding, for direction: SwipeDirection, area: TerminalSwipeArea? = nil) {
        if let area {
            switch (area, direction) {
            case (.top, .left): topLeftBinding = binding
            case (.top, .right): topRightBinding = binding
            case (.bottom, .left): bottomLeftBinding = binding
            case (.bottom, .right): bottomRightBinding = binding
            }
            return
        }
        switch direction {
        case .left: leftBinding = binding
        case .right: rightBinding = binding
        }
    }

    /// Set both bindings in one operation. Saves and posts the change
    /// notification once instead of twice — important so the gesture
    /// recognizer doesn't rebuild itself in the middle of the update.
    func setBindings(left: SwipeGestureBinding, right: SwipeGestureBinding) {
        guard left != leftBinding || right != rightBinding else { return }
        isBatching = true
        leftBinding = left
        rightBinding = right
        isBatching = false
        save()
    }

    /// Swap the left and right bindings.
    func swapBindings() {
        setBindings(left: rightBinding, right: leftBinding)
    }

    func resetToDefaults() {
        isBatching = true
        restoreAreas(nil)
        leftBinding = Self.defaultLeftBinding
        rightBinding = Self.defaultRightBinding
        isBatching = false
        save()
    }

    // MARK: - Persistence

    private struct StoredBindings: Codable {
        let left: SwipeGestureBinding
        let right: SwipeGestureBinding
        var separateAreasEnabled: Bool?
        var topLeft: SwipeGestureBinding?
        var topRight: SwipeGestureBinding?
        var bottomLeft: SwipeGestureBinding?
        var bottomRight: SwipeGestureBinding?
    }

    private func restoreAreas(_ stored: StoredBindings?) {
        separateAreasEnabled = stored?.separateAreasEnabled ?? false
        topLeftBinding = stored?.topLeft ?? stored?.left ?? Self.defaultLeftBinding
        topRightBinding = stored?.topRight ?? stored?.right ?? Self.defaultRightBinding
        bottomLeftBinding = stored?.bottomLeft ?? stored?.left ?? Self.defaultLeftBinding
        bottomRightBinding = stored?.bottomRight ?? stored?.right ?? Self.defaultRightBinding
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        guard keys.contains(Settings.Gestures.swipeBindings.name) else { return }
        isBatching = true
        let stored = Self.load()
        restoreAreas(stored)
        leftBinding = stored?.left ?? Self.defaultLeftBinding
        rightBinding = stored?.right ?? Self.defaultRightBinding
        isBatching = false
        NotificationCenter.default.post(name: Self.bindingsDidChangeNotification, object: nil)
    }

    private func save() {
        let stored = StoredBindings(left: leftBinding, right: rightBinding,
            separateAreasEnabled: separateAreasEnabled, topLeft: topLeftBinding,
            topRight: topRightBinding, bottomLeft: bottomLeftBinding, bottomRight: bottomRightBinding)
        do {
            let data = try JSONEncoder().encode(stored)
            SettingsStore.shared.set(Settings.Gestures.swipeBindings, data)
        } catch {
            Self.logger.error("Failed to save swipe gesture bindings: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: Self.bindingsDidChangeNotification, object: nil)
    }

    private static func load() -> StoredBindings? {
        guard let data = SettingsStore.shared.get(Settings.Gestures.swipeBindings) else { return nil }
        do {
            return try JSONDecoder().decode(StoredBindings.self, from: data)
        } catch {
            logger.error("Failed to load swipe gesture bindings: \(error.localizedDescription)")
            return nil
        }
    }
}
