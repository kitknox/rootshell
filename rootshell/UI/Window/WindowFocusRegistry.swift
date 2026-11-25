//
//  WindowFocusRegistry.swift
//  rootshell
//
//  Tracks per-window focus state for routing commands and focus updates.
//

import Foundation

@MainActor
final class WindowFocusRegistry {
    static let shared = WindowFocusRegistry()

    private var keyStateBySceneId: [String: Bool] = [:]
    private var lastKeySceneId: String?
    /// Survives the app losing key status; cleared only when its scene goes away.
    private var mostRecentKeySceneId: String?

    private init() {}

    func update(sceneSessionId: String, isKey: Bool) {
        guard !sceneSessionId.isEmpty else { return }
        let previous = activeSceneSessionId()
        defer { notifyIfActiveSceneChanged(from: previous) }
        keyStateBySceneId[sceneSessionId] = isKey
        if isKey {
            lastKeySceneId = sceneSessionId
            mostRecentKeySceneId = sceneSessionId
        } else if lastKeySceneId == sceneSessionId {
            lastKeySceneId = keyStateBySceneId.first(where: { $0.value })?.key
        }
    }

    func remove(sceneSessionId: String) {
        guard !sceneSessionId.isEmpty else { return }
        let previous = activeSceneSessionId()
        defer { notifyIfActiveSceneChanged(from: previous) }
        keyStateBySceneId.removeValue(forKey: sceneSessionId)
        if mostRecentKeySceneId == sceneSessionId {
            mostRecentKeySceneId = nil
        }
        if lastKeySceneId == sceneSessionId {
            lastKeySceneId = keyStateBySceneId.first(where: { $0.value })?.key
        }
    }

    func activeSceneSessionId() -> String? {
        if let lastKeySceneId, keyStateBySceneId[lastKeySceneId] == true {
            return lastKeySceneId
        }
        return keyStateBySceneId.first(where: { $0.value })?.key
    }

    /// Menu shortcuts that follow the focused scene (the file editor's ⌘S) re-check.
    private func notifyIfActiveSceneChanged(from previous: String?) {
        guard activeSceneSessionId() != previous else { return }
        MenuShortcutState.shared.refreshSaveChordRelease()
    }

    /// The key scene, or the last one that was key while another app is active.
    func mostRecentKeySceneSessionId() -> String? {
        activeSceneSessionId() ?? mostRecentKeySceneId
    }
}
