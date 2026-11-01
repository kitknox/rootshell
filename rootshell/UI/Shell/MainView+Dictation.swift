#if canImport(FluidAudio) && !CHINA_BUILD
import SwiftUI

// MARK: - Dictation HUD

extension MainView {
    var dictationTarget: DictationTarget? {
        guard terminals.indices.contains(selectedTabIndex) else { return nil }
        return terminals[selectedTabIndex].focusedTerminal
    }

    /// First press opens the HUD and starts listening; a second press dismisses
    /// it, like the other HUDs. Dismissal stops listening via `onChange`.
    func toggleDictationHUD(from terminal: Ghostty.TerminalView?) {
        if showDictationHUD {
            showDictationHUD = false
            return
        }
        let controller = DictationController.shared
        let terminal = terminal ?? (terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].focusedTerminal : nil)
        let target: DictationTarget? = terminal
        adoptEdgeSidebarPage(.dictation)
        showDictationHUD = true
        guard let target, controller.modelReady, !controller.isActive else { return }
        controller.dismissError()
        controller.start(target: target, owner: DictationController.hudOwner)
    }
}
#endif
