//
//  MainView+KVM.swift
//  rootshell
//
//  KVM over IP tab and split creation for MainView.
//

import SwiftUI
import os

extension MainView {

    /// Mirrors `makeVNCPane`: window-active and focus stamping before the
    /// pane joins the hierarchy, plus host-key and certificate prompts through
    /// this window's alert queue.
    func makeKVMPane(
        config: KVMConnectionConfig,
        sourceProfileID: UUID?,
        passwordHandoff: RemoteScreenPasswordHandoff? = nil,
        uuid: UUID = UUID(),
        logicallyFocused: Bool = true
    ) -> KVMPaneView {
        let pane = KVMPaneView(config: config, windowId: windowId, uuid: uuid)
        pane.sourceProfileID = sourceProfileID
        pane.passwordHandoff = passwordHandoff
        pane.setWindowActive(isWindowFocused)
        pane.isLogicallyFocused = logicallyFocused

        let alerts = self.alerts
        let sessionLabel = config.displayName
        pane.onHostKeyValidation = { @Sendable request in
            await alerts.handleHostKeyValidation(request: request, sessionLabel: sessionLabel)
        }
        pane.onCertificateValidation = { @Sendable request in
            await alerts.handleVNCCertificateValidation(request: request, sessionLabel: sessionLabel)
        }
        return pane
    }

    func createKVMTab(
        with config: KVMConnectionConfig,
        sourceProfileID: UUID? = nil,
        passwordHandoff: RemoteScreenPasswordHandoff? = nil
    ) {
        let pane = makeKVMPane(config: config, sourceProfileID: sourceProfileID, passwordHandoff: passwordHandoff)
        insertPaneAsTab(pane, title: config.displayName, profileThemeSourceID: sourceProfileID)
    }

    func createKVMSplit(
        with config: KVMConnectionConfig,
        direction: SplitTree<SplitPaneView>.NewDirection,
        sourceProfileID: UUID? = nil,
        passwordHandoff: RemoteScreenPasswordHandoff? = nil
    ) {
        guard terminals.indices.contains(selectedTabIndex) else {
            createKVMTab(with: config, sourceProfileID: sourceProfileID, passwordHandoff: passwordHandoff)
            return
        }
        var focusedPane = terminals[selectedTabIndex].focusedPane
        if focusedPane == nil, let firstPane = terminals[selectedTabIndex].splitTree.first {
            focusedPane = firstPane
            terminals[selectedTabIndex].focusedPane = firstPane
        }
        guard let targetPane = focusedPane else {
            createKVMTab(with: config, sourceProfileID: sourceProfileID, passwordHandoff: passwordHandoff)
            return
        }
        let pane = makeKVMPane(config: config, sourceProfileID: sourceProfileID, passwordHandoff: passwordHandoff)
        insertPaneAsSplit(
            pane,
            at: targetPane,
            inTab: selectedTabIndex,
            direction: direction,
            logLabel: "KVM",
            profileThemeSourceID: sourceProfileID
        )
    }

    /// Claims a password the connect form typed for this route, so only the
    /// pane this call creates can use it.
    func handleKVMConnection(
        config: KVMConnectionConfig,
        splitOption: SSHConnectionView.SplitOption,
        sourceProfileID: UUID? = nil
    ) {
        let handoff = VNCPasswordManager.kvm.takeEphemeralPassword(for: config.passwordKey)
        switch splitOption {
        case .newTab:
            createKVMTab(with: config, sourceProfileID: sourceProfileID, passwordHandoff: handoff)
        case .splitRight:
            createKVMSplit(with: config, direction: .right, sourceProfileID: sourceProfileID, passwordHandoff: handoff)
        case .splitDown:
            createKVMSplit(with: config, direction: .down, sourceProfileID: sourceProfileID, passwordHandoff: handoff)
        }
    }

    /// The pane resolves the password itself (Keychain, then its own prompt).
    func connectToKVMProfile(_ profile: ConnectionProfile, splitOption: SSHConnectionView.SplitOption) {
        guard let kvmConfig = profile.kvmConfig else {
            Ghostty.logger.warning("KVM profile has no KVM configuration - showing alert")
            alerts.showVNCProfileInvalidAlert = true
            return
        }
        handleKVMConnection(config: kvmConfig, splitOption: splitOption, sourceProfileID: profile.id)
    }
}
