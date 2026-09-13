import Foundation

extension Ghostty.TerminalView {
    func beginHerdrTitleAttachment() {
        titleChangeTimer?.invalidate()
        titleChangeTimer = nil
        herdrTitlePublicationUptime = nil
        herdrTitleState.beginAttachment()
    }

    func endHerdrTitleAttachment() {
        titleChangeTimer?.invalidate()
        titleChangeTimer = nil
        herdrTitlePublicationUptime = nil
        herdrTitleState.endAttachment()
    }

    func seedHerdrTitle(_ title: String?) {
        herdrTitleState.seed(title)
        publishHerdrTitle()
    }

    func handleHerdrTitleChange(_ title: String) {
        guard let attachmentID = herdrTitleState.attachmentID else { return }
        // Claim live authority immediately, before the publication timer. A
        // metadata event in this interval must not restore an older title.
        herdrTitleState.receive(title, from: attachmentID)
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = herdrTitlePublicationUptime.map { now - $0 } ?? 0.075
        if elapsed >= 0.075 {
            publishPendingHerdrTitle()
            return
        }
        guard titleChangeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.075 - elapsed, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.herdrTitleState.attachmentID == attachmentID else { return }
                self.publishPendingHerdrTitle()
            }
        }
        titleChangeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func publishPendingHerdrTitle() {
        titleChangeTimer?.invalidate()
        titleChangeTimer = nil
        herdrTitlePublicationUptime = ProcessInfo.processInfo.systemUptime
        if let title = herdrTitleState.reportedTitle {
            AgentAttentionCenter.shared.noteTitleChanged(terminal: self, title: title)
        }
        publishHerdrTitle()
    }

    /// Pane chrome, foreground replay, and the controller all use the same
    /// resolved state. Never publish the payload of a delayed metadata event.
    func publishHerdrTitle() {
        sessionProvidedTitle = herdrTitleState.reportedTitle
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        let manualName = herdrPaneBinding.flatMap { binding in
            HerdrController.controller(forGateway: binding.gatewayUUID)?.paneInfos[binding.paneId]?.label
        }
        let resolved = herdrTitleState.resolvedTitle(override: manualName ?? userOverrideTitle, fallback: "")
        if title != resolved { title = resolved }
        guard let binding = herdrPaneBinding,
              let controller = HerdrController.controller(forGateway: binding.gatewayUUID),
              controller.paneViews[binding.terminalId] === self,
              let tab = controller.tabs[binding.tabId] else { return }
        controller.refreshTitle(of: tab)
    }
}
