//
//  GhosttyCommandRouting.swift
//  rootshell
//
//  Shared keys for command routing notifications
//

import Foundation

enum GhosttyCommandRouting {
    static let windowSceneSessionIDKey = "windowSceneSessionID"
    /// Explicit MainView windowId target; wins over scene routing.
    static let windowIdKey = "routedWindowId"
}
