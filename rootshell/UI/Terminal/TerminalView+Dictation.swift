#if canImport(FluidAudio) && !CHINA_BUILD
import UIKit

/// Where dictated text goes. The terminal pane that had focus when listening began.
@MainActor
protocol DictationTarget: AnyObject {
    var dictationCanReceive: Bool { get }
    /// Name of a coding agent running in the pane, for automatic prompt formatting.
    var dictationAgentName: String? { get }
    /// Recent visible text, used to boost identifiers the speaker is likely to say.
    var dictationScreenText: String? { get }
    /// Changes whenever input other than dictation's own reaches the terminal.
    var dictationInputGeneration: UInt64 { get }
    func dictationInsert(_ text: String)
    func dictationSubmit()
    func dictationSend(_ key: DictationKey)
    func dictationDeleteBackward(_ count: Int)
}

extension Ghostty.TerminalView: DictationTarget {
    var dictationCanReceive: Bool {
        window != nil && surface != nil && !aiAgentOverlayActive
    }

    var dictationInputGeneration: UInt64 { userInputGeneration }

    var dictationAgentName: String? {
        AgentAttentionCenter.shared.detectedAgentName(for: self)
    }

    var dictationScreenText: String? {
        guard let surface, let size = surfaceSize, size.rows > 1, size.columns > 1 else { return nil }
        var busy = false
        return Ghostty.Surface.tryReadBottomRows(
            Int(size.rows), gridRows: Int(size.rows), cols: Int(size.columns), surface: surface, busy: &busy)
    }

    /// Agents read a Return that arrives with the text as a pasted newline.
    private static let dictationSubmitGap: Duration = .milliseconds(200)

    func dictationInsert(_ text: String) {
        guard dictationCanReceive, !text.isEmpty else { return }
        dictationEnqueue { $0.deliverDictatedText(text) }
    }

    func dictationSubmit() {
        dictationEnqueue(submit: true) { $0.dictationSendRaw("\r") }
    }

    func dictationSend(_ key: DictationKey) {
        dictationEnqueue { $0.deliverDictatedKey(key) }
    }

    func dictationDeleteBackward(_ count: Int) {
        for _ in 0..<min(count, 2_000) { dictationSend(.backspace) }
    }

    /// Runs now unless a delayed Return is pending, so dictated input keeps its order.
    private func dictationEnqueue(submit: Bool = false, _ work: @escaping @MainActor (Ghostty.TerminalView) -> Void) {
        dictationPending.append((submit, work))
        if dictationDrainTask == nil { drainDictationOutput() }
    }

    /// Sends held output in order, pausing at a Return that still needs its gap.
    private func drainDictationOutput() {
        guard !dictationDelivering else { return }
        dictationDrainTask?.cancel()
        dictationDrainTask = nil
        dictationDelivering = true
        defer { dictationDelivering = false }
        while let next = dictationPending.first {
            if next.submit, let wait = dictationSubmitWait {
                dictationDrainTask = Task { [weak self] in
                    guard (try? await Task.sleep(for: wait)) != nil else { return }
                    self?.dictationDrainTask = nil
                    self?.drainDictationOutput()
                }
                return
            }
            dictationPending.removeFirst()
            next.work(self)
        }
    }

    private var dictationSubmitWait: Duration? {
        guard let last = dictationLastTextAt else { return nil }
        let wait = Self.dictationSubmitGap - last.duration(to: .now)
        return wait > .zero ? wait : nil
    }

    private func deliverDictatedText(_ text: String) {
        guard dictationCanReceive else { return }
        if text.contains("\n") {
            // Bracketed paste keeps line breaks inside the prompt instead of submitting it.
            _ = insertPastedText(text, recordHistory: false)
        } else {
            sendComposedText(text)
        }
        dictationLastTextAt = .now
    }

    private func deliverDictatedKey(_ key: DictationKey) {
        switch key {
        case .escape: dictationPress(.keyboardEscape, fallback: "\u{1b}")
        case .tab: dictationPress(.keyboardTab, fallback: "\t")
        case .up: dictationPress(.keyboardUpArrow, fallback: "\u{1b}[A")
        case .down: dictationPress(.keyboardDownArrow, fallback: "\u{1b}[B")
        case .backspace: dictationSendRaw("\u{7f}")
        case .control(let letter):
            guard let ascii = letter.lowercased().first?.asciiValue, (97...122).contains(ascii) else { return }
            let usage = UIKeyboardHIDUsage(rawValue: UIKeyboardHIDUsage.keyboardA.rawValue + Int(ascii - 97))
            if let usage, sendKeyViaGhostty(keyCode: usage, action: .press, modifiers: .control) {
                _ = sendKeyViaGhostty(keyCode: usage, action: .release, modifiers: .control)
            } else {
                keyPressed(String(letter), modifiers: .control)
            }
        }
    }

    /// Raw bytes like the on-screen Return and Backspace, on the same direct path as
    /// dictated text. Ghostty-encoded keys detour through the response pipe and
    /// could land after input sent behind them.
    private func dictationSendRaw(_ bytes: String) {
        guard dictationCanReceive else { return }
        NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
        sendUserInput(Data(bytes.utf8))
    }

    private func dictationPress(_ usage: UIKeyboardHIDUsage, fallback: String) {
        guard dictationCanReceive else { return }
        NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
        if sendKeyViaGhostty(keyCode: usage, action: .press, modifiers: []) {
            _ = sendKeyViaGhostty(keyCode: usage, action: .release, modifiers: [])
        } else {
            keyPressed(fallback, modifiers: [])
        }
    }
}
#endif
