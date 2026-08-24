//
//  ExternalDisplayTabBarButton.swift
//  rootshell
//
//  Tab-bar chrome button for external display control (device windows only).
//  Self-contained state driven by ExternalDisplayManager notifications so
//  MainView gains no new observable dependencies.
//

#if !targetEnvironment(macCatalyst)
import SwiftUI

struct ExternalDisplayTabBarButton: View {
    let tint: Color
    let windowId: String

    @State private var isSessionActive = ExternalDisplayManager.shared.isExternalSessionActive
    @State private var isExternalFocused = ExternalDisplayManager.shared.focusTarget == .external

    var body: some View {
        Group {
            if isSessionActive {
                Button {
                    ExternalDisplayManager.shared.toggleFocus()
                } label: {
                    Image(systemName: isExternalFocused ? "tv.fill" : "tv")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isExternalFocused ? .accentColor : tint)
                        .frame(width: TabMetrics.tabBarHeight, height: TabMetrics.tabBarHeight)
                }
                .layoutPriority(1)
                .contextMenu {
                    Button {
                        guard let model = TerminalWindowRegistry.tabsModel(for: windowId),
                              let tabID = model.selectedTabID else { return }
                        ExternalDisplayManager.shared.moveTabToExternal(tabID: tabID, from: windowId)
                    } label: {
                        Label("Move Tab to External Display", systemImage: "tv")
                    }
                }
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task { await observe(.externalDisplayDidConnect) }
        .task { await observe(.externalDisplayDidDisconnect) }
        .task { await observe(.externalDisplayFocusChanged) }
    }

    private func observe(_ name: Notification.Name) async {
        for await _ in NotificationCenter.default.notifications(named: name) {
            refresh()
        }
    }

    private func refresh() {
        isSessionActive = ExternalDisplayManager.shared.isExternalSessionActive
        isExternalFocused = ExternalDisplayManager.shared.focusTarget == .external
    }
}
#endif
