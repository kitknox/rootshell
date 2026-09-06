//
//  WindowSessionCensus.swift
//  rootshell
//
//  Pure, per-window census of terminal sessions, extracted from
//  MainViewLifecycle. Stateless value computation over the tab tree; the
//  single impure edge is `publish`, which forwards the counts to
//  SessionTracker for background-task and Live Activity bookkeeping.
//

import SwiftUI

/// Per-window session census. MainActor by the project's default isolation
/// (inputs are MainActor-bound view models); no stored state.
enum WindowSessionCensus {

    /// Per-type counts and host names for all session types.
    struct Details {
        var sshCount: Int
        var k8sCount: Int
        var consoleCount: Int
        var hostNames: [String]
        var localTaskCount: Int
        var roamCount: Int
        var roamHostNames: [String]
        var profileCounts: [UUID: Int]
    }

    /// Count remote sessions (SSH, Mosh, Trzsz, Kubernetes, Console, EC2 Console) in this window
    static func remoteSessionCount(in tabs: [TabModel]) -> Int {
        tabs.flatMap { $0.splitTree.terminalLeaves }.filter { terminal in
            switch terminal.connectionConfig {
            case .ssh, .mosh, .trzsz, .trzszTransfer, .kubernetes, .console, .ec2Console, .shellLaunchedSSH, .shellLaunchedMosh, .shellLaunchedTrzsz, .vnc:
                return true
            case .local:
                return false
            }
        }.count
    }

    /// Count non-resilient sessions that require background execution
    /// Includes remote sessions (SSH, K8s, Console) and local shells with active long-running tasks
    /// Roam (Mosh, Trzsz) excluded - their UDP state-sync survives network changes and app suspension
    static func nonResilientSessionCount(in tabs: [TabModel]) -> Int {
        tabs.flatMap { $0.splitTree.terminalLeaves }.filter { terminal in
            switch terminal.connectionConfig {
            case .ssh, .kubernetes, .console, .ec2Console, .shellLaunchedSSH, .vnc:
                // VNC rides TCP with no roam-style resilience
                return true
            case .local:
                return terminal.hasActiveLocalTask
            case .mosh, .trzsz, .trzszTransfer, .shellLaunchedMosh, .shellLaunchedTrzsz:
                return false
            }
        }.count
    }

    /// Independent profile-associated connections, not tmux display panes.
    static func profileCounts(in tabs: [TabModel]) -> [UUID: Int] {
        var profileCounts: [UUID: Int] = [:]

        // Count independent pane owners, including VNC. Hidden gateways remain
        // in tabs; their tmux display panes share the connection and add nothing.
        var countedPaneIDs: Set<UUID> = []
        for pane in tabs.flatMap({ Array($0.splitTree) }) where countedPaneIDs.insert(pane.uuid).inserted {
            let profileID: UUID?
            if let terminal = pane.asTerminal {
                profileID = terminal.isTmuxPane ? nil : terminal.sourceProfileID
            } else {
                profileID = (pane as? VNCPaneView)?.sourceProfileID
            }
            if let profileID {
                profileCounts[profileID, default: 0] += 1
            }
        }

        return profileCounts
    }

    /// Gather per-type counts and host names for all session types
    static func details(in tabs: [TabModel]) -> Details {
        var sshCount = 0
        var k8sCount = 0
        var consoleCount = 0
        var hostNames: [String] = []
        var localTaskCount = 0
        var roamCount = 0
        var roamHostNames: [String] = []
        let profileCounts = Self.profileCounts(in: tabs)

        for terminal in tabs.flatMap({ $0.splitTree.terminalLeaves }) {
            switch terminal.connectionConfig {
            case .ssh(let config):
                sshCount += 1
                if !hostNames.contains(config.host) {
                    hostNames.append(config.host)
                }
            case .shellLaunchedSSH(let sshConfig, _):
                sshCount += 1
                if !hostNames.contains(sshConfig.host) {
                    hostNames.append(sshConfig.host)
                }
            case .kubernetes(let config):
                k8sCount += 1
                if !hostNames.contains(config.nodeName) {
                    hostNames.append(config.nodeName)
                }
            case .console(let config):
                consoleCount += 1
                if !hostNames.contains(config.instanceLabel) {
                    hostNames.append(config.instanceLabel)
                }
            case .ec2Console(let config):
                consoleCount += 1
                if !hostNames.contains(config.instanceLabel) {
                    hostNames.append(config.instanceLabel)
                }
            case .local:
                if terminal.hasActiveLocalTask {
                    localTaskCount += 1
                }
            case .mosh(let config):
                roamCount += 1
                if !roamHostNames.contains(config.sshConfig.host) {
                    roamHostNames.append(config.sshConfig.host)
                }
            case .trzsz(let config):
                roamCount += 1
                if !roamHostNames.contains(config.sshConfig.host) {
                    roamHostNames.append(config.sshConfig.host)
                }
            case .shellLaunchedMosh(let moshConfig, _):
                roamCount += 1
                if !roamHostNames.contains(moshConfig.sshConfig.host) {
                    roamHostNames.append(moshConfig.sshConfig.host)
                }
            case .shellLaunchedTrzsz(let trzszConfig, _):
                roamCount += 1
                if !roamHostNames.contains(trzszConfig.sshConfig.host) {
                    roamHostNames.append(trzszConfig.sshConfig.host)
                }
            case .trzszTransfer(_, _, let host):
                roamCount += 1
                if !roamHostNames.contains(host) {
                    roamHostNames.append(host)
                }
            case .vnc(let config):
                // Counted with SSH so a window with a live remote desktop
                // reads as having remote sessions
                sshCount += 1
                if !hostNames.contains(config.host) {
                    hostNames.append(config.host)
                }
            }
        }

        // hostNames capped at 3 — SessionTracker / Live Activity displays
        // depend on this truncation.
        return Details(
            sshCount: sshCount,
            k8sCount: k8sCount,
            consoleCount: consoleCount,
            hostNames: Array(hostNames.prefix(3)),
            localTaskCount: localTaskCount,
            roamCount: roamCount,
            roamHostNames: Array(roamHostNames.prefix(3)),
            profileCounts: profileCounts
        )
    }

    /// Count total tabs (including splits) in this window
    static func totalTabCount(in tabs: [TabModel]) -> Int {
        tabs.count
    }

    /// Measure the window's sessions and forward the counts to SessionTracker.
    static func publish(tabs: [TabModel], windowId: String, sceneSessionId: String?) {
        let remoteCount = remoteSessionCount(in: tabs)
        let nonResilientCount = nonResilientSessionCount(in: tabs)
        let tabCount = totalTabCount(in: tabs)
        let details = details(in: tabs)

        SessionTracker.shared.updateWindowCounts(
            remoteCount: remoteCount,
            nonResilientCount: nonResilientCount,
            tabCount: tabCount,
            windowId: windowId,
            sceneSessionId: sceneSessionId,
            sshCount: details.sshCount,
            k8sCount: details.k8sCount,
            consoleCount: details.consoleCount,
            hostNames: details.hostNames,
            localTaskCount: details.localTaskCount,
            roamCount: details.roamCount,
            roamHostNames: details.roamHostNames,
            profileCounts: details.profileCounts
        )
    }
}
