// Copyright (c) 2026 Kit Knox / Rootshell LLC

import Foundation
import UIKit

extension HerdrController {
    var showsGatewayStatus: Bool { !didEnd && tabs.isEmpty }

    func publishSessionState() {
        gateway?.updateHerdrGatewayOverlay()
        NotificationCenter.default.post(name: .herdrControlStateDidChange, object: gatewayUUID)
    }

    /// Temporary visibility for an empty session must not consume the user's
    /// auto-hide preference, or change selection in an unrelated session.
    func revealEmptyGatewayIfNeeded() {
        guard let gatewayTabID, let tab = tabsModel.tab(withID: gatewayTabID), tab.isHiddenTmuxWindow else { return }
        rehideGatewayAfterEmpty = !didEnd && didAutoHideGateway
        tab.isHiddenTmuxWindow = false
    }

    func cancelNewTabRequests() {
        for task in newTabTasks.values { task.cancel() }
        newTabTasks.removeAll()
        emptySessionCreationID = nil
    }

    /// Empty-session errors live in the gateway view. A failed New Tab from
    /// a populated, selected session needs feedback without navigating away.
    func presentNewTabErrorIfNeeded() {
        guard !tabs.isEmpty, let message = newTabError,
              let selected = tabsModel.selectedTabID,
              selected == gatewayTabID || tabs.values.contains(where: { $0.id == selected }),
              let window = tabsModel.tab(withID: selected)?.focusedTerminal?.window ?? gateway?.window,
              window.isKeyWindow,
              let root = window.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !(presenter is UIAlertController) else { return }
        let alert = UIAlertController(
            title: String(localized: "Couldn’t Create herdr Tab"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        presenter.present(alert, animated: true)
    }
}
