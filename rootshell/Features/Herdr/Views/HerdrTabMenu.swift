//
//  HerdrTabMenu.swift
//  rootshell
//
//  Context menu items and dialogs for herdr control-mode tabs: rename, new
//  tab, show the hidden gateway, and the destructive Detach that ends
//  control mode while the herdr session keeps running on the host.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

/// Dialog state for the herdr menu items; one per host view as `@State`.
@MainActor @Observable
final class HerdrTabDialogCoordinator {
    var renameTab: TabModel?
    var renameText = ""
    var detachConfirmTab: TabModel?

    func requestRename(_ tab: TabModel) {
        renameText = tab.title
        renameTab = tab
    }

    func requestDetach(_ tab: TabModel) {
        detachConfirmTab = tab
    }
}

extension HerdrController {
    /// The controller behind a projected tab or a gateway tab.
    static func controller(forAnyTab tab: TabModel) -> HerdrController? {
        if let controller = controller(forTab: tab) { return controller }
        guard tab.isHerdrGateway else { return nil }
        return tab.splitTree.terminalLeaves.first(where: { $0.herdrController != nil })?.herdrController
    }
}

/// Non-destructive herdr section of a tab context menu. Renders nothing for
/// tabs that are not part of a herdr control-mode session.
struct HerdrTabMenuItems: View {
    let tab: TabModel
    let dialogs: HerdrTabDialogCoordinator

    private var controller: HerdrController? { HerdrController.controller(forAnyTab: tab) }

    var body: some View {
        if let controller, controller.isActive {
            if tab.isHerdrWindow {
                Button {
                    dialogs.requestRename(tab)
                } label: {
                    Label("Rename Tab", systemImage: "pencil")
                }
            }
            Button {
                controller.requestNewTab(inWorkspaceOf: tab.isHerdrWindow ? tab : nil)
            } label: {
                Label("New herdr Tab", systemImage: "plus.rectangle.on.rectangle")
            }
            .disabled(controller.emptySessionCreationID != nil)
            if tab.isHerdrWindow, controller.isGatewayTabHidden {
                Button {
                    controller.showGatewayTab()
                } label: {
                    Label("Show Gateway Tab", systemImage: "eye")
                }
            }
        }
    }
}

/// Destructive "Detach" item, placed by each host next to Close.
struct HerdrGatewayDetachMenuItem: View {
    let tab: TabModel
    let dialogs: HerdrTabDialogCoordinator

    var body: some View {
        if let controller = HerdrController.controller(forAnyTab: tab), controller.isActive {
            Button(role: .destructive) {
                dialogs.requestDetach(tab)
            } label: {
                Label("Detach from herdr", systemImage: "eject")
            }
        }
    }
}

private struct HerdrTabDialogsModifier: ViewModifier {
    @Bindable var dialogs: HerdrTabDialogCoordinator

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                renameDialog
                detachDialog
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private var renameDialog: some View {
        Color.clear.alert("Rename Tab", isPresented: Binding(
            get: { dialogs.renameTab != nil },
            set: { if !$0 { dialogs.renameTab = nil } }
        )) {
            TextField("Tab name", text: $dialogs.renameText)
                .autocorrectionDisabled()
                #if !os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("Rename") {
                guard let tab = dialogs.renameTab,
                      let controller = HerdrController.controller(forAnyTab: tab) else { return }
                let label = dialogs.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return }
                controller.requestRenameTab(tab, label: label)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var detachDialog: some View {
        Color.clear.confirmationDialog(
            "Detach from herdr?",
            isPresented: Binding(
                get: { dialogs.detachConfirmTab != nil },
                set: { if !$0 { dialogs.detachConfirmTab = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Detach", role: .destructive) {
                guard let tab = dialogs.detachConfirmTab,
                      let controller = HerdrController.controller(forAnyTab: tab) else { return }
                controller.detach(closeGateway: false)
            }
            Button("Detach & Close Gateway", role: .destructive) {
                guard let tab = dialogs.detachConfirmTab,
                      let controller = HerdrController.controller(forAnyTab: tab) else { return }
                controller.detach(closeGateway: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leaves herdr control mode. The herdr session and its panes keep running on the host; the gateway tab returns to its shell.")
        }
    }
}

extension View {
    /// Attach the herdr rename and detach dialogs driven by `coordinator`.
    func herdrTabDialogs(coordinator: HerdrTabDialogCoordinator) -> some View {
        modifier(HerdrTabDialogsModifier(dialogs: coordinator))
    }
}
