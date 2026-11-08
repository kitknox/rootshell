//
//  KVMConnectionInfo.swift
//  rootshell
//
//  Connection Info payload for KVM over IP panes
//

import Foundation

/// A KVM pane's connection identity plus its live session for device and
/// stream details.
struct KVMConnectionInfo: Sendable {
    let host: String
    let port: Int
    let username: String
    let transportDescription: String
    let connectedAt: Date
    let session: KVMSession
}
