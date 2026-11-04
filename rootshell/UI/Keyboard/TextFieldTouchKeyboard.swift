#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit

/// Puts the terminal keyboard under rootshell's ordinary text fields. Fields
/// that handle terminal toolbar keys themselves get its toolbar; the rest get
/// keys only. Secure, numeric, and excluded fields keep Apple's keyboard.
final class TextFieldTouchKeyboard: NSObject {
    static let shared = TextFieldTouchKeyboard()

    private final class Presentation {
        let keyboard: TerminalTouchKeyboardView
        let input: TerminalTouchKeyboardInputView
        let host = TextInputTouchKeyboardHost()

        init(window: UIWindow, onSwitchKeyboard: @escaping () -> Void) {
            keyboard = TerminalTouchKeyboardView(textFieldMode: .keysOnly)
            input = TerminalTouchKeyboardInputView(keyboard: keyboard)
            input.setUsesSystemPlacement(true)
            input.hostSize = { [weak window] in window?.bounds.size ?? .zero }
            input.shouldHideAfterDocking = { KeyboardTracker.shared.isHardwareKeyboard }
            keyboard.host = host
            keyboard.onSwitchKeyboard = onSwitchKeyboard
            keyboard.onDismiss = { [weak host] in host?.dismiss() }
            keyboard.onPinHidden = { [weak host] in host?.dismiss() }
            keyboard.onPaste = { [weak host] in host?.paste() }
        }
    }

    private static let appleOnlyKeyboardTypes: Set<UIKeyboardType> = [
        .numberPad, .phonePad, .namePhonePad, .decimalPad, .asciiCapableNumberPad
    ]
    private static let appleOnlyContentTypes: Set<UITextContentType> = [.password, .newPassword, .oneTimeCode]

    private let presentations = NSMapTable<UIWindow, Presentation>.weakToStrongObjects()
    private let excluded = NSHashTable<UIResponder>.weakObjects()
    private weak var activeField: UIView?
    /// Switched to Apple's keyboard with the switch key, until editing ends.
    private weak var appleKeyboardField: UIView?
    private var tasks: [Task<Void, Never>] = []

    func start() {
        guard tasks.isEmpty else { return }
        let center = NotificationCenter.default
        // Synchronous, so the input view is set before UIKit shows a keyboard.
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            center.addObserver(self, selector: #selector(didBeginEditing(_:)), name: name, object: nil)
        }
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            center.addObserver(self, selector: #selector(didEndEditing(_:)), name: name, object: nil)
        }
        let hardware = KeyboardTracker.shared.hardwareKeyboardStateDidChangeStream()
        let settings = SettingsStore.shared.changes()
        let names: Set = [Settings.Keyboard.touchEnabled.name, Settings.Keyboard.touchInTextFields.name]
        tasks = [
            Task { [weak self] in
                for await _ in hardware { self?.refreshActiveField() }
            },
            Task { [weak self] in
                for await change in settings where change.intersects(names) { self?.refreshActiveField() }
            }
        ]
    }

    /// Keeps Apple's keyboard on a responder that has its own keyboard handling.
    static func exclude(_ responder: UIResponder) {
        shared.excluded.add(responder)
    }

    @objc private func didBeginEditing(_ note: Notification) {
        guard let field = note.object as? UIView, field is UITextInput else { return }
        if appleKeyboardField !== field { appleKeyboardField = nil }
        activeField = field
        update(field)
    }

    @objc private func didEndEditing(_ note: Notification) {
        guard let field = note.object as? UIView else { return }
        if field.inputView is TerminalTouchKeyboardInputView { Self.setInputView(nil, on: field) }
        if appleKeyboardField === field { appleKeyboardField = nil }
        if activeField === field { activeField = nil }
    }

    private func refreshActiveField() {
        guard let field = activeField, field.isFirstResponder else { return }
        update(field)
    }

    private func switchToAppleKeyboard() {
        guard let field = activeField, field.inputView is TerminalTouchKeyboardInputView else { return }
        appleKeyboardField = field
        update(field)
    }

    private func update(_ field: UIView) {
        guard let window = field.window, wants(field) else {
            guard field.inputView is TerminalTouchKeyboardInputView else { return }
            Self.setInputView(nil, on: field)
            Self.reload(field)
            return
        }
        let presentation = presentation(for: window)
        let retargeted = presentation.host.target !== field
        presentation.host.target = field as? (UIView & UITextInput)
        if retargeted { presentation.keyboard.dictationTargetDidChange() }
        // A field that took the terminal toolbar with Apple's keyboard keeps it.
        presentation.keyboard.textFieldMode = field is KeyboardButtonDelegate ? .toolbar : .keysOnly
        presentation.keyboard.updateSuggestions()
        guard field.inputView !== presentation.input else { return }
        Self.setInputView(presentation.input, on: field)
        Self.reload(field)
    }

    private func wants(_ field: UIView) -> Bool {
        let store = SettingsStore.shared
        guard store.value(Settings.Keyboard.touchEnabled), store.value(Settings.Keyboard.touchInTextFields),
              !KeyboardTracker.shared.isHardwareKeyboard, field !== appleKeyboardField, !excluded.contains(field),
              field.inputView == nil || field.inputView is TerminalTouchKeyboardInputView else { return false }
        let traits: (secure: Bool, keyboard: UIKeyboardType, content: UITextContentType?)
        if let textField = field as? UITextField {
            traits = (textField.isSecureTextEntry, textField.keyboardType, textField.textContentType)
        } else if let textView = field as? UITextView, textView.isEditable {
            traits = (textView.isSecureTextEntry, textView.keyboardType, textView.textContentType)
        } else {
            return false
        }
        return !traits.secure && !Self.appleOnlyKeyboardTypes.contains(traits.keyboard)
            && !(traits.content.map { Self.appleOnlyContentTypes.contains($0) } ?? false)
    }

    private func presentation(for window: UIWindow) -> Presentation {
        if let existing = presentations.object(forKey: window) { return existing }
        let created = Presentation(window: window) { [weak self] in self?.switchToAppleKeyboard() }
        presentations.setObject(created, forKey: window)
        return created
    }

    private static func setInputView(_ view: UIView?, on field: UIView) {
        (field as? UITextField)?.inputView = view
        (field as? UITextView)?.inputView = view
    }

    /// Never reload an inactive responder, or draw under lock (FrontBoard 0x2BAD45EC).
    private static func reload(_ field: UIView) {
        guard field.isFirstResponder, field.window != nil, !Ghostty.isSecureDrawProhibitedAtomic else { return }
        field.reloadInputViews()
    }
}

/// Types into a UIKit text input. Terminal-only keys (Esc, F-keys, chords,
/// custom sequences) are ignored; Tab goes to a field that handles it.
final class TextInputTouchKeyboardHost: TerminalTouchKeyboardHost {
    weak var target: (UIView & UITextInput)? {
        didSet {
            guard oldValue !== target else { return }
            #if canImport(FluidAudio) && !CHINA_BUILD
            // Invalidate before retargeting: a phrase still decoding must not reach the new field.
            dictationSession?.invalidate()
            dictationSession = target.map { TextFieldDictationTarget(field: $0) }
            #endif
        }
    }
    /// The fixed end of a Shift-extended selection.
    private var selectionAnchor: UITextPosition?
    #if canImport(FluidAudio) && !CHINA_BUILD
    /// The only strong reference; the dictation controller and pane hold it weakly.
    private var dictationSession: TextFieldDictationTarget?
    var touchKeyboardDictationTarget: DictationTarget? { dictationSession }
    #endif

    private enum Motion { case left, right, up, down, start, end }

    var touchKeyboardThemeColors: ThemeManager.ThemeInfo.ThemeColors? {
        ThemeManager.shared.currentThemeInfo?.colors
    }

    var touchKeyboardCanSend: Bool { target?.isFirstResponder == true && target?.window != nil }

    var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? {
        guard let line = typingContext() else { return nil }
        return TerminalTouchKeyboardModel.SuggestionContext(
            document: line, eligibleCount: line.utf16.count, generation: 0, documentGeneration: 0)
    }

    var touchKeyboardPredictionContext: TerminalTouchKeyboardModel.PredictionSnapshot? {
        guard let line = typingContext() else { return nil }
        var context = TerminalTouchKeyboardModel.PredictionContext()
        context.append(line)
        return context.snapshot
    }

    func touchKeyboardInsert(_ text: String) {
        guard touchKeyboardCanSend, let target else { return }
        selectionAnchor = nil
        target.insertText(text)
    }

    func touchKeyboardSend(_ key: String, modifiers: KeyModifiers, shifted: Character?) {
        guard touchKeyboardCanSend, let target else { return }
        let extending = modifiers.contains(.shift)
        switch key {
        case "\u{7f}":
            selectionAnchor = nil
            target.deleteBackward()
        case "\u{1b}[3~": deleteForward(target)
        case "\r":
            selectionAnchor = nil
            Self.submit(target)
        case "\t": Self.tab(target)
        case "\u{1b}[D": move(.left, extending: extending)
        case "\u{1b}[C": move(.right, extending: extending)
        case "\u{1b}[A": move(.up, extending: extending)
        case "\u{1b}[B": move(.down, extending: extending)
        case "\u{1b}[H": move(.start, extending: extending)
        case "\u{1b}[F": move(.end, extending: extending)
        default: break
        }
    }

    func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext) {
        guard touchKeyboardCanSend, let target, touchKeyboardSuggestionContext == context,
              let caret = target.selectedTextRange?.start,
              let start = target.position(from: caret, offset: -context.range.length),
              let range = target.textRange(from: start, to: caret) else { return }
        target.replace(range, withText: text + " ")
    }

    func touchKeyboardInvalidateSuggestions() {}

    func dismiss() {
        _ = target?.resignFirstResponder()
    }

    func paste() {
        guard touchKeyboardCanSend, let target,
              target.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil) else { return }
        _ = target.perform(#selector(UIResponderStandardEditActions.paste(_:)), with: nil)
    }

    /// An input view's "\n" is not a Return to a text field; take UIKit's Return path.
    static func submit(_ target: UIView & UITextInput) {
        guard let field = target as? UITextField else {
            target.insertText("\n")
            return
        }
        if field.delegate?.textFieldShouldReturn?(field) ?? true {
            field.sendActions(for: .editingDidEndOnExit)
        }
    }

    /// Quick Connect completes on Tab; a text view takes a tab character.
    static func tab(_ target: UIView & UITextInput) {
        if let field = target as? KeyboardButtonDelegate {
            field.keyPressed("\t", modifiers: [])
        } else if target is UITextView {
            target.insertText("\t")
        }
    }

    private func deleteForward(_ target: UIView & UITextInput) {
        selectionAnchor = nil
        if let selection = target.selectedTextRange, selection.isEmpty {
            guard let next = target.position(from: selection.end, offset: 1) else { return }
            target.selectedTextRange = target.textRange(from: next, to: next)
        }
        target.deleteBackward()
    }

    /// Home and End come only from the toolbar, which single-line fields use.
    private func move(_ motion: Motion, extending: Bool) {
        guard let target, let selection = target.selectedTextRange else { return }
        let backward = motion == .left || motion == .up || motion == .start
        if !extending, !selection.isEmpty, motion == .left || motion == .right {
            let edge = backward ? selection.start : selection.end
            target.selectedTextRange = target.textRange(from: edge, to: edge)
            selectionAnchor = nil
            return
        }
        // A tap elsewhere invalidates the remembered anchor.
        let remembered = selectionAnchor.flatMap { anchor in
            [selection.start, selection.end].contains { target.compare($0, to: anchor) == .orderedSame } ? anchor : nil
        }
        let anchor: UITextPosition? = extending ? (remembered ?? selection.start) : nil
        let focus = anchor.map { target.compare($0, to: selection.start) == .orderedSame ? selection.end : selection.start }
            ?? selection.start
        let moved: UITextPosition? = switch motion {
        case .left: target.position(from: focus, offset: -1)
        case .right: target.position(from: focus, offset: 1)
        case .up: target.position(from: focus, in: .up, offset: 1)
        case .down: target.position(from: focus, in: .down, offset: 1)
        case .start, .end: nil
        }
        let next = moved ?? (backward ? target.beginningOfDocument : target.endOfDocument)
        selectionAnchor = anchor
        guard let anchor else {
            target.selectedTextRange = target.textRange(from: next, to: next)
            return
        }
        target.selectedTextRange = target.compare(next, to: anchor) == .orderedAscending
            ? target.textRange(from: next, to: anchor) : target.textRange(from: anchor, to: next)
    }

    /// Host names, users, paths, and commands turn corrections off.
    static func correctsText(_ target: UIView) -> Bool {
        ((target as? UITextField)?.autocorrectionType ?? (target as? UITextView)?.autocorrectionType) != .no
    }

    /// The current line up to an empty caret, at most 200 characters back.
    /// nil where the field opts out of corrections.
    private func typingContext() -> String? {
        guard let target, Self.correctsText(target), target.markedTextRange == nil,
              let selection = target.selectedTextRange, selection.isEmpty,
              let range = target.textRange(
                  from: target.position(from: selection.start, offset: -200) ?? target.beginningOfDocument,
                  to: selection.start),
              let text = target.text(in: range) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init)
    }
}

#if canImport(FluidAudio) && !CHINA_BUILD
/// Dictation into one field, shaped for form input: sentences, or Command's
/// spoken symbols where corrections are off; hands-free never presses Return.
/// Invalidated when focus moves, so a late phrase never reaches the next field.
final class TextFieldDictationTarget: DictationTarget {
    private weak var field: (UIView & UITextInput)?

    init(field: UIView & UITextInput) { self.field = field }

    func invalidate() { field = nil }

    private var receiver: (UIView & UITextInput)? {
        guard let field, field.isFirstResponder, field.window != nil else { return nil }
        return field
    }

    var dictationCanReceive: Bool { receiver != nil }
    var dictationAgentName: String? { nil }
    var dictationAllowsAutoSubmit: Bool { false }
    var dictationPreferredStyle: DictationFormatter.Style? {
        field.map { TextInputTouchKeyboardHost.correctsText($0) ? .prose : .command }
    }

    var dictationScreenText: String? { field.flatMap(Self.text(of:)).map { String($0.suffix(2000)) } }

    /// The text and selection, hashed: a caret move or edit outside dictation
    /// changes it, so Undo never deletes at a position dictation didn't type.
    var dictationInputGeneration: UInt64 {
        guard let field, let selection = field.selectedTextRange else { return 0 }
        var hasher = Hasher()
        hasher.combine(Self.text(of: field))
        hasher.combine(field.offset(from: field.beginningOfDocument, to: selection.start))
        hasher.combine(field.offset(from: field.beginningOfDocument, to: selection.end))
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    func dictationInsert(_ text: String) {
        receiver?.insertText(text)
    }

    func dictationSubmit() {
        guard let receiver else { return }
        TextInputTouchKeyboardHost.submit(receiver)
    }

    func dictationSend(_ key: DictationKey) {
        guard let receiver else { return }
        switch key {
        case .tab: TextInputTouchKeyboardHost.tab(receiver)
        case .up, .down:
            guard let caret = receiver.selectedTextRange?.start else { return }
            let next = receiver.position(from: caret, in: key == .up ? .up : .down, offset: 1)
                ?? (key == .up ? receiver.beginningOfDocument : receiver.endOfDocument)
            receiver.selectedTextRange = receiver.textRange(from: next, to: next)
        case .backspace: receiver.deleteBackward()
        case .escape, .control: break
        }
    }

    func dictationDeleteBackward(_ count: Int) {
        guard let receiver else { return }
        for _ in 0..<max(0, count) { receiver.deleteBackward() }
    }

    private static func text(of field: UIView & UITextInput) -> String? {
        field.textRange(from: field.beginningOfDocument, to: field.endOfDocument).flatMap { field.text(in: $0) }
    }
}
#endif

#endif
