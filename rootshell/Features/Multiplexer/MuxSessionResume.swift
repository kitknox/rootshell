//
//  MuxSessionResume.swift
//  rootshell
//
//  Resume-or-focus: when a mux auto-start profile is opened while a live
//  attachment to the same host/session already exists, focus that UI instead
//  of spawning a second unrelated-looking control client.
//

import Foundation
import UIKit

@MainActor
enum MuxSessionResume {
    struct Match: Equatable {
        let windowId: String
        let tabID: UUID
        let displayName: String
    }

    /// Payload for the post-detach reconnect banner.
    struct ReconnectOffer: Equatable {
        let displayName: String
        let sshConfig: SSHConfig
        let connectionProtocol: ConnectionProtocol
        let profileID: UUID?
    }

    /// Find a live multiplexer attachment that matches this profile's auto-start
    /// target. Returns nil when the profile does not auto-start a mux, or when
    /// no matching attachment is open.
    static func findLiveAttachment(for config: SSHConfig) -> Match? {
        guard let target = autoStartTarget(for: config) else { return nil }
        let gatewayKey = TmuxGatewaySessionStore.connectionKey(
            host: config.host,
            port: config.port,
            username: config.username
        )

        for (windowId, model) in TmuxWindowRegistry.allWindows() {
            for tab in model.tabs {
                if let match = matchTmuxControl(
                    tab: tab,
                    model: model,
                    windowId: windowId,
                    gatewayKey: gatewayKey,
                    sessionName: target.sessionName,
                    wantsControl: target.wantsControlMode
                ) {
                    return match
                }
                if let match = matchRawOrPassthrough(
                    tab: tab,
                    windowId: windowId,
                    config: config,
                    type: target.type,
                    sessionName: target.sessionName
                ) {
                    return match
                }
            }
        }
        return nil
    }

    /// Focus an existing attachment: activate its window scene if needed, then
    /// select the tab. Returns true when focus was requested.
    @discardableResult
    static func focus(
        _ match: Match,
        in currentWindowId: String,
        selectTab: (UUID) -> Void
    ) -> Bool {
        if match.windowId != currentWindowId,
           let sceneSessionId = TerminalWindowRegistry.sceneSessionId(for: match.windowId),
           let scene = UIApplication.shared.connectedScenes
               .compactMap({ $0 as? UIWindowScene })
               .first(where: { $0.session.persistentIdentifier == sceneSessionId }) {
            UIApplication.shared.requestSceneSessionActivation(
                scene.session,
                userActivity: nil,
                options: nil,
                errorHandler: nil
            )
            // Selecting across windows: ask the owning TabsModel directly.
            if let model = TmuxWindowRegistry.tabsModel(for: match.windowId) {
                model.selectedTabID = match.tabID
                return true
            }
        }
        selectTab(match.tabID)
        return true
    }

    // MARK: - Private

    private struct AutoStartTarget {
        let type: MultiplexerType
        let sessionName: String?
        let wantsControlMode: Bool
    }

    private static func autoStartTarget(for config: SSHConfig) -> AutoStartTarget? {
        if config.tmuxAutoEnable {
            return AutoStartTarget(
                type: .tmux,
                sessionName: config.tmuxSessionNameForConnection,
                wantsControlMode: config.tmuxAutoMode == .control
            )
        }
        if config.herdrAutoEnable {
            return AutoStartTarget(
                type: .herdr,
                sessionName: config.herdrSessionNameForConnection,
                wantsControlMode: false
            )
        }
        if config.zmxAutoEnable {
            return AutoStartTarget(
                type: .zmx,
                sessionName: config.zmxSessionNameForConnection,
                wantsControlMode: false
            )
        }
        return nil
    }

    private static func matchTmuxControl(
        tab: TabModel,
        model: TabsModel,
        windowId: String,
        gatewayKey: String,
        sessionName: String?,
        wantsControl: Bool
    ) -> Match? {
        guard wantsControl else { return nil }
        let controller =
            TmuxController.controller(forWindowTab: tab)
            ?? TmuxController.controller(forGatewayTab: tab)
            ?? tab.splitTree.terminalLeaves.first(where: { $0.tmuxController != nil })?.tmuxController
        guard let controller, controller.isActive else { return nil }
        if let key = controller.connectionKey, key != gatewayKey { return nil }
        if let sessionName,
           let current = controller.currentSessionName,
           current != sessionName {
            return nil
        }
        let ownerID = controller.ownerTerminalUUIDForNotifications
        let focusTab = model.tabs.first(where: {
            $0.isTmuxWindow
                && !$0.isHiddenTmuxWindow
                && $0.owningGatewayTerminalUUID == ownerID
        }) ?? model.tabs.first(where: {
            $0.isTmuxGateway
                && $0.splitTree.terminalLeaves.contains(where: { $0.tmuxController === controller })
        }) ?? tab
        let name = controller.currentSessionName ?? sessionName ?? "tmux"
        return Match(
            windowId: windowId,
            tabID: focusTab.id,
            displayName: "tmux “\(name)”"
        )
    }

    private static func matchRawOrPassthrough(
        tab: TabModel,
        windowId: String,
        config: SSHConfig,
        type: MultiplexerType,
        sessionName: String?
    ) -> Match? {
        for view in tab.splitTree.terminalLeaves {
            guard let ssh = view.connectionConfig.sshConfigForHistory,
                  ssh.host == config.host,
                  ssh.port == config.port,
                  ssh.username == config.username else { continue }

            let bindingType: MultiplexerType?
            let bindingSession: String?
            if let raw = view.rawMultiplexer {
                bindingType = raw.type
                bindingSession = raw.sessionName
            } else if let pass = view.passthroughMultiplexer {
                bindingType = pass.type
                bindingSession = pass.sessionName
            } else if type == .zmx, ssh.zmxAutoEnable {
                // Binding may not be applied yet on a just-opened pane; still
                // treat an in-flight zmx auto-start as the live attachment.
                bindingType = .zmx
                bindingSession = ssh.zmxSessionNameForConnection
            } else if type == .herdr, ssh.herdrAutoEnable {
                bindingType = .herdr
                bindingSession = ssh.herdrSessionNameForConnection
            } else if type == .tmux, ssh.tmuxAutoEnable, ssh.tmuxAutoMode == .regular {
                bindingType = .tmux
                bindingSession = ssh.tmuxSessionNameForConnection
            } else {
                bindingType = nil
                bindingSession = nil
            }
            guard bindingType == type else { continue }
            if let sessionName, let bindingSession, sessionName != bindingSession {
                continue
            }
            let label = bindingSession.map { "\(type.rawValue) “\($0)”" } ?? type.rawValue
            return Match(windowId: windowId, tabID: tab.id, displayName: label)
        }
        return nil
    }
}

