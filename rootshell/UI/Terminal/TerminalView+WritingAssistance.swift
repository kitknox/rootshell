import UIKit
import Combine

extension Ghostty.TerminalView {
    func setupWritingAssistance() {
        writingAssistanceMode = SettingsStore.shared.value(Settings.Keyboard.writingAssistance)
        for name in [Notification.Name.settingsDidChange,
                     UITextInputMode.currentInputModeDidChangeNotification,
                     UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidHideNotification,
                     UIApplication.didBecomeActiveNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == .settingsDidChange {
                        let mode = SettingsStore.shared.value(Settings.Keyboard.writingAssistance)
                        if mode != self.writingAssistanceMode {
                            self.writingAssistanceMode = mode
                            self.invalidateWritingAssistance()
                        }
                    } else if name == UIResponder.keyboardDidHideNotification,
                              !KeyboardTracker.shared.isSoftwareKeyboardVisible {
                        self.invalidateWritingAssistance()
                        self.writingAssistanceSource = nil
                    } else if name == UITextInputMode.currentInputModeDidChangeNotification {
                        self.syncDictationSessionWithSignals()
                    } else if name == UIApplication.didBecomeActiveNotification,
                              self.writingAssistanceRequeryDeferred {
                        self.writingAssistanceRequeryDeferred = false
                        self.requestWritingAssistanceRequery()
                    }
                    // Repeated show notifications (including trait reloads)
                    // are not input-source changes. refresh compares identity.
                    self.refreshWritingAssistanceTraits()
                }
            }
            cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(observer) })
        }
        keyboardAccessoryController.onActiveKeyboardModifiersChanged = { [weak self] _ in
            self?.invalidateWritingAssistance()
        }
        refreshWritingAssistanceTraits()
    }

    /// UIKit exposes expected input sources, not authenticated keyboard identity.
    /// Accept only known system input-mode classes; unknown subclasses fail closed.
    /// Do not inspect private properties or assume any non-extension is Apple.
    var eligibleWritingAssistanceSource: String? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if keyboardAccessoryController?.usesTouchKeyboard == true {
            guard SettingsStore.shared.value(Settings.Keyboard.touchSuggestions),
                  SettingsStore.shared.value(Settings.Keyboard.touchLayout).usesEnglishTextModels, touchKeyboardCanSend,
                  keyboardAccessoryController?.touchKeyboard?.window != nil,
                  (keyboardAccessoryController?.touchKeyboard?.isFloating == true || KeyboardTracker.shared.isSoftwareKeyboardVisible),
                  markedTextString == nil, !koreanCompositionModel.hasActiveComposition,
                  activeKeyboardModifiers.isEmpty, virtualModTapModifier == nil, heldHardwareModifiers == .none else { return nil }
            if let binding = tmuxPaneBinding {
                guard let gateway = TmuxWindowRegistry.gatewayView(ownerTerminalUUID: binding.parentUUID),
                      gateway.session?.isRunning == true else { return nil }
            } else if session?.isRunning != true { return nil }
            if let lastHardwareTextInputTime,
               ProcessInfo.processInfo.systemUptime - lastHardwareTextInputTime < 0.25 { return nil }
            return "rootshell-touch:en"
        }
        #endif
        guard KeyboardTracker.shared.isSoftwareKeyboardVisible,
              let mode = textInputMode, let language = mode.primaryLanguage,
              language != "dictation", language != "emoji",
              markedTextString == nil, !koreanCompositionModel.hasActiveComposition,
              activeKeyboardModifiers.isEmpty, virtualModTapModifier == nil,
              heldHardwareModifiers == .none else { return nil }
        if let binding = tmuxPaneBinding {
            guard let gateway = TmuxWindowRegistry.gatewayView(ownerTerminalUUID: binding.parentUUID),
                  gateway.session?.isRunning == true else { return nil }
        } else if session?.isRunning != true {
            return nil
        }
        let modeClass = NSStringFromClass(type(of: mode))
        guard modeClass == "UIKeyboardInputMode" || modeClass == "UITextInputMode" else { return nil }
        if let context = UITextInputContext.current(),
           context.isHardwareKeyboardInputExpected || context.isDictationInputExpected || context.isPencilInputExpected {
            return nil
        }
        if let lastHardwareTextInputTime,
           ProcessInfo.processInfo.systemUptime - lastHardwareTextInputTime < 0.25 { return nil }
        return modeClass + ":" + language
        #endif
    }

    @discardableResult
    func refreshWritingAssistanceTraits() -> Bool {
        let source = eligibleWritingAssistanceSource
        if writingAssistanceSource != source {
            invalidateWritingAssistance()
            writingAssistanceSource = source
        }
        let customSource = source == "rootshell-touch:en"
        let mode = source == nil ? TerminalWritingAssistanceMode.off : (customSource ? .suggestions : writingAssistanceMode)
        let spelling: UITextSpellCheckingType = mode == .off || customSource ? .no : .yes
        let correction: UITextAutocorrectionType = mode == .autocorrect ? .yes : .no
        if spellCheckingType != spelling || autocorrectionType != correction {
            spellCheckingType = spelling
            autocorrectionType = correction
            writingAssistanceNeedsTraitReload = true
        }
        requestWritingAssistanceTraitReload()
        return mode != .off && surface != nil && isFirstResponder
    }

    private func requestWritingAssistanceTraitReload() {
        guard writingAssistanceNeedsTraitReload, !writingAssistanceTraitReloadPending,
              markedTextString == nil, !koreanCompositionModel.hasActiveComposition else { return }
        writingAssistanceTraitReloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.writingAssistanceTraitReloadPending = false
            guard self.markedTextString == nil, !self.koreanCompositionModel.hasActiveComposition else { return }
            // Keep the reload owed; the guarded reloadInputViews() would drop it.
            guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
            self.writingAssistanceNeedsTraitReload = false
            // Never reload inside an insert/replace/marked-text callback, and
            // never park or replace the first responder to change traits.
            if self.isFirstResponder { self.reloadInputViews() }
        }
    }

    func requestWritingAssistanceRequery() {
        guard !writingAssistanceRequeryPending else { return }
        writingAssistanceRequeryPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.writingAssistanceRequeryPending = false
            // A tab handoff resets both terminals' documents. By the time this
            // deferred callback runs, only the new responder owns UIKit's
            // input session; notifying the old delegate starts unnecessary
            // keyboard work and can query the wrong document during the switch.
            guard self.isFirstResponder, self.window != nil else { return }
            // Suggestion rebuilds draw into the keyboard window (0x2BAD45EC).
            guard !Ghostty.isSecureDrawProhibitedAtomic else {
                self.writingAssistanceRequeryDeferred = true
                return
            }
            self.notifyInputDelegateOfExternalChange { }
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            self.keyboardAccessoryController?.touchKeyboard?.updateSuggestions()
            #endif
        }
    }

    /// Revocation ends QuickType authority only. A reset is a document
    /// boundary and closes any dictation session with it.
    func invalidateWritingAssistance(resetDocument: Bool = false) {
        mutateInputDocument(resetDocument ? .reset : .invalidate)
        if resetDocument {
            dictationSettleDeadline = nil
            pendingDictationPlaceholderTokens.removeAll()
        }
    }

    func rejectWritingAssistanceReplacement() {
        invalidateWritingAssistance()
        // A rejected UIKit edit needs a fresh document even if its authority
        // was already revoked. Ordinary repeated scroll invalidations do not.
        requestWritingAssistanceRequery()
    }

    @discardableResult
    func mutateInputDocument(_ mutation: TerminalCorrectionContext.Mutation) -> Bool {
        let generation = correctionContext.generation
        let documentGeneration = correctionContext.documentGeneration
        let hadSelection = writingAssistanceSelection != nil
        guard correctionContext.apply(mutation) else { return false }
        touchPredictionContext.apply(mutation, attributed: touchKeyboardInputDepth > 0)
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        keyboardAccessoryController?.touchKeyboard?.updatePrediction()
        #endif
        if case .invalidate = mutation {
            // Revocation cancels the local QuickType selection only.
            writingAssistanceSelection = nil
        }
        if documentGeneration != correctionContext.documentGeneration {
            writingAssistanceSelection = nil
        }
        if generation != correctionContext.generation || documentGeneration != correctionContext.documentGeneration
            || (hadSelection && writingAssistanceSelection == nil) {
            // Resets before focus acquisition are read by UIKit when it
            // installs the new responder. Only an existing input session
            // needs a subsequent external-document-change notification.
            if isFirstResponder {
                requestWritingAssistanceRequery()
            }
        }
        if keyboardAccessoryController?.usesTouchKeyboard == true { requestWritingAssistanceRequery() }
        return true
    }

    /// Corrections target the application's logical input, not its painted
    /// screen. Redraws and terminal status reports must not revoke that input.
    /// User navigation and session/source changes still revoke the local suffix.
    /// Returns false without side effects so the caller can try other
    /// authorities before rejecting.
    func applyWritingAssistanceReplacement(_ range: NSRange, text: String, generation: UInt64) -> Bool {
        guard refreshWritingAssistanceTraits(),
              let replacement = correctionContext.replacement(in: range, with: text, generation: generation) else {
            return false
        }
        // Commit exactly once at input convergence. Keep the corrected suffix
        // eligible for subsequent corrections and ordinary deletion.
        sendUserInput(replacement.payload, documentMutation: .correction(replacement))
        requestWritingAssistanceRequery()
        return true
    }
}
