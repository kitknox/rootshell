import Foundation
import UIKit

extension Ghostty.TerminalView {
    var hasActiveKoreanComposition: Bool {
        koreanCompositionModel.hasActiveComposition
    }

    var koreanPreeditTextForTextInput: String? {
        koreanCompositionModel.preeditText
    }

    private var isKoreanInputMethodActive: Bool {
        #if targetEnvironment(macCatalyst)
        InputSourceCatalog.catalystCurrentInputSourceHasLanguagePrefix(["ko"])
        #else
        textInputMode?.primaryLanguage?.hasPrefix("ko") == true
        #endif
    }

    private var shouldUseKoreanCompositionModel: Bool {
        (isKoreanInputMethodActive || koreanCompositionModel.hasActiveComposition)
            && markedTextString == nil
            && !isHandlingDictationResult
            && !isLikelyThirdPartyKeyboard
    }

    var usesIsolatedKoreanTextInputDocument: Bool {
        shouldUseKoreanCompositionModel || koreanCompositionModel.hasActiveComposition
    }

    func beginKoreanCompositionInputKey(allowNoActiveDelete: Bool = false) {
        guard isKoreanInputMethodActive || koreanCompositionModel.hasActiveComposition else {
            return
        }

        let allowNoActiveDelete = allowNoActiveDelete && isKoreanInputMethodActive
        guard koreanCompositionModel.beginInputKey(allowNoActiveDelete: allowNoActiveDelete) else {
            return
        }

        syncIMEPreedit(nil)
        notifyInputDelegateOfExternalChange { }
    }

    func handleKoreanCompositionInsertIfNeeded(_ text: String) -> Bool {
        guard shouldUseKoreanCompositionModel else {
            return false
        }

        let insertText = text

        let result: TerminalKoreanCompositionModel.InsertResult?
        #if targetEnvironment(macCatalyst)
        result = koreanCompositionModel.handleCatalystInsert(insertText)
        #else
        result = koreanCompositionModel.handleInsert(insertText)
        #endif

        guard let result else {
            if koreanCompositionModel.isAwaitingReplacementInsert,
               TerminalKoreanCompositionModel.isTransientHardwareTextDuringReplacement(insertText) {
                return true
            }

            return false
        }

        commitKoreanText(result.committedText, external: false)
        syncIMEPreedit(result.preeditText)
        if let replacementWindowToken = koreanCompositionModel.activeReplacementWindowToken {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.koreanCompositionModel.expireReplacementWindow(token: replacementWindowToken) else {
                    return
                }
            }
        }
        return true
    }

    func handleKoreanCompositionDeleteIfNeeded() -> Bool {
        guard shouldUseKoreanCompositionModel else {
            return false
        }

        #if targetEnvironment(macCatalyst)
        guard koreanCompositionModel.handleCatalystDeleteBackward() else {
            return false
        }
        syncIMEPreedit(koreanCompositionModel.preeditText)
        notifyInputDelegateOfExternalChange { }
        return true
        #else
        guard koreanCompositionModel.handleDeleteBackward() else {
            return false
        }

        guard let pendingReplacementToken = koreanCompositionModel.activePendingReplacementToken else {
            return true
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.koreanCompositionModel.finishPendingDeleteIfUnreplaced(
                token: pendingReplacementToken
            ) {
                self.syncIMEPreedit(nil)
                self.notifyInputDelegateOfExternalChange { }
            }
        }
        return true
        #endif
    }

    @discardableResult
    func commitKoreanCompositionIfNeeded(external: Bool) -> Bool {
        guard koreanCompositionModel.hasActiveComposition else { return false }
        guard let text = koreanCompositionModel.commitPreedit(), !text.isEmpty else {
            syncIMEPreedit(nil)
            return false
        }

        commitKoreanText(text, external: external)
        syncIMEPreedit(nil)
        return true
    }

    func clearKoreanCompositionIfNeeded(external: Bool) {
        guard koreanCompositionModel.clear() else { return }
        syncIMEPreedit(nil)
        if external {
            notifyInputDelegateOfExternalChange { }
        }
    }

    func commitKoreanReplacementText(_ text: String, external: Bool) {
        _ = koreanCompositionModel.clear()
        syncIMEPreedit(nil)
        commitKoreanText(text, external: external)
    }

    private func commitKoreanText(_ text: String, external: Bool) {
        guard !text.isEmpty else { return }

        NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
        if let data = text.data(using: .utf8) {
            sendUserInput(data, documentMutation: .text(text, eligible: false))
        }

        if external {
            DispatchQueue.main.async { [weak self] in
                self?.notifyInputDelegateOfExternalChange { }
            }
        }
    }
}
