//
//  KeybindEditorView.swift
//  rootshell
//
//  Editor view for customizing individual keyboard shortcuts
//

import SwiftUI
import UIKit

/// Result reported back from `KeybindEditorView` to its parent. The parent
/// applies the corresponding `KeybindManager` mutation in the sheet's
/// onDismiss so the @Published cascade runs after the sheet has finished
/// tearing down, not during the dismiss animation.
enum KeybindEditorOutcome {
    case captured(KeySequence)
    case restoreDefault
    case unbind
}

struct KeybindEditorView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject private var keybindManager = KeybindManager.shared

    /// Reports the user's choice to the parent. All paths that mutate
    /// `KeybindManager` route through this callback so the actual write
    /// happens in the parent's sheet-onDismiss closure. Includes the action
    /// currently on screen, which may have changed if the user jumped to a
    /// conflicting shortcut without dismissing the sheet.
    var onOutcome: (KeybindAction, KeybindEditorOutcome) -> Void = { _, _ in }
    /// Optional: parent can follow an in-sheet jump to another action (e.g. to
    /// keep the shortcuts list on the matching category). The sheet stays open.
    var onSwitchAction: ((KeybindAction) -> Void)?

    @State private var currentAction: KeybindAction
    @State private var isCapturing = false
    @State private var showSequenceCapture = false
    @State private var captureError: String?
    @State private var pendingCapture: KeySequence?
    @State private var conflictingBindings: [Keybind] = []

    init(
        action: KeybindAction,
        onOutcome: @escaping (KeybindAction, KeybindEditorOutcome) -> Void = { _, _ in },
        onSwitchAction: ((KeybindAction) -> Void)? = nil
    ) {
        self.onOutcome = onOutcome
        self.onSwitchAction = onSwitchAction
        _currentAction = State(initialValue: action)
    }

    /// Current binding for this action (may be nil if displaced by external config)
    private var binding: Keybind? {
        keybindManager.keybind(for: currentAction)
    }

    /// Single conflicting action the user can jump to from the warning, if any.
    private var editableConflictAction: KeybindAction? {
        guard conflictingBindings.count == 1,
              let conflict = conflictingBindings.first?.action,
              conflict != currentAction,
              KeybindAction.customizableActions.contains(conflict)
        else { return nil }
        return conflict
    }

    private var overrideButtonTitle: String {
        if conflictingBindings.count == 1, let name = conflictingBindings.first?.action.displayName {
            return "Unbind \(name)"
        }
        return "Unbind Other Shortcuts"
    }

    private var conflictMessage: String {
        let chord = pendingCapture?.symbolDescription ?? "This shortcut"
        if conflictingBindings.count == 1, let conflict = conflictingBindings.first {
            if conflict.sequence == pendingCapture {
                return "\(chord) is currently bound to \(conflict.action.displayName). Overriding will remove it from that action."
            }
            return "\(chord) conflicts with \(conflict.sequence.symbolDescription) (\(conflict.action.displayName)). Overriding will unbind that shortcut."
        }
        let details = conflictingBindings
            .map { "\($0.action.displayName) (\($0.sequence.symbolDescription))" }
            .joined(separator: ", ")
        return "\(chord) conflicts with: \(details). Overriding will unbind those shortcuts."
    }

    private var sheetBackground: Color {
        sheetThemeColors?.background ?? Color(uiColor: .systemGroupedBackground)
    }

    private var rowBackground: Color {
        sheetThemeColors?.rowBackground ?? Color(uiColor: .tertiarySystemGroupedBackground)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Action info
                VStack(spacing: 8) {
                    Text(currentAction.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(currentAction.category.displayName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(rowBackground)
                        .cornerRadius(8)
                }
                .padding(.top, 16)

                Divider()

                // Current shortcut
                VStack(spacing: 12) {
                    Text("Current Shortcut")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    if let binding {
                        Text(binding.sequence.symbolDescription)
                            .font(.system(size: 28, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .background(rowBackground)
                            .cornerRadius(12)

                        if binding.isUserOverride {
                            Label("Custom", systemImage: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                    } else {
                        Text("No Shortcut")
                            .font(.system(size: 28, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .italic()
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .background(rowBackground)
                            .cornerRadius(12)
                    }

                    if conflictingBindings.isEmpty {
                        if (binding != nil && binding!.isUserOverride) || keybindManager.isActionUnbound(currentAction) {
                            Button("Restore Default") {
                                onOutcome(currentAction, .restoreDefault)
                                dismiss()
                            }
                            .foregroundColor(.orange)
                        }

                        if binding != nil {
                            Button("Unbind Shortcut") {
                                onOutcome(currentAction, .unbind)
                                dismiss()
                            }
                            .foregroundColor(.red)
                        }
                    }
                }

                // Capture area
                if isCapturing {
                    ShortcutCaptureView(
                        isSequenceMode: showSequenceCapture,
                        themeColors: sheetThemeColors,
                        onCapture: handleCapture,
                        onCancel: {
                            isCapturing = false
                            showSequenceCapture = false
                        }
                    )
                    .frame(height: 120)
                } else if pendingCapture != nil, !conflictingBindings.isEmpty {
                    conflictWarningCard
                        .padding(.horizontal)
                } else {
                    VStack(spacing: 12) {
                        Button {
                            beginCapture(sequenceMode: false)
                        } label: {
                            Label("Record New Shortcut", systemImage: "keyboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        if currentAction != .toggle_visor {
                            Button {
                                beginCapture(sequenceMode: true)
                            } label: {
                                Label("Record Key Sequence", systemImage: "keyboard.badge.ellipsis")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        if let captureError {
                            Text(captureError)
                                .font(.caption)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
            .animation(.easeInOut(duration: 0.2), value: currentAction)
            .animation(.easeInOut(duration: 0.2), value: conflictingBindings.isEmpty)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(sheetBackground.ignoresSafeArea())
            .navigationTitle("Edit Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var conflictWarningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Shortcut Already in Use", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(conflictMessage)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let pendingCapture {
                Text(pendingCapture.symbolDescription)
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(rowBackground)
                    .cornerRadius(8)
            }

            VStack(spacing: 8) {
                Button(role: .destructive) {
                    confirmOverride()
                } label: {
                    Text(overrideButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                if let editableConflictAction {
                    Button {
                        openConflictingAction(editableConflictAction)
                    } label: {
                        Text("Edit \(editableConflictAction.displayName) Instead")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    clearPendingConflict()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(12)
    }

    // MARK: - Capture Handler

    private func beginCapture(sequenceMode: Bool) {
        captureError = nil
        clearPendingConflict()
        isCapturing = true
        showSequenceCapture = sequenceMode
    }

    private func handleCapture(_ sequence: KeySequence) {
        // Reject sequences whose first trigger is a default control-character
        // binding. `KeySequenceTracker.processFirstKey` passes those through
        // to preserve terminal typing speed, which would make the sequence
        // unreachable at runtime. Tell the user instead of silently saving a
        // dead binding.
        if sequence.isSequence,
           let firstTrigger = sequence.first,
           let shadowing = KeybindManager.shared.keybind(for: firstTrigger),
           shadowing.source == .default,
           shadowing.action.isControlCharacter {
            captureError = "\(firstTrigger.symbolDescription) can't be used as a sequence prefix — it's the terminal control character for \(shadowing.action.displayName)."
            isCapturing = false
            showSequenceCapture = false
            return
        }

        let conflicts = keybindManager.conflicts(for: sequence, excluding: currentAction)
        isCapturing = false
        showSequenceCapture = false

        if !conflicts.isEmpty {
            // Keep the sheet open and ask before stealing another action's chord.
            pendingCapture = sequence
            conflictingBindings = conflicts
            return
        }

        commitCapture(sequence)
    }

    private func confirmOverride() {
        guard let sequence = pendingCapture else { return }
        clearPendingConflict()
        commitCapture(sequence)
    }

    private func openConflictingAction(_ conflict: KeybindAction) {
        withAnimation(.easeInOut(duration: 0.2)) {
            clearPendingConflict()
            captureError = nil
            isCapturing = false
            showSequenceCapture = false
            currentAction = conflict
        }
        onSwitchAction?(conflict)
    }

    private func clearPendingConflict() {
        pendingCapture = nil
        conflictingBindings = []
    }

    private func commitCapture(_ sequence: KeySequence) {
        // Hand the outcome to the parent. The parent applies it in the sheet's
        // onDismiss closure — i.e. after the sheet has fully dismissed — so the
        // @Published cascade in setOverride runs in a quiescent view hierarchy
        // rather than mid-dismissal.
        onOutcome(currentAction, .captured(sequence))
        dismiss()
    }
}

// MARK: - Shortcut Capture View

struct ShortcutCaptureView: UIViewRepresentable {
    let isSequenceMode: Bool
    let themeColors: SheetThemeColors?
    let onCapture: (KeySequence) -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> ShortcutCaptureUIView {
        let view = ShortcutCaptureUIView()
        view.configure(isSequenceMode: isSequenceMode, themeColors: themeColors)
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateUIView(_ uiView: ShortcutCaptureUIView, context: Context) {
        uiView.configure(isSequenceMode: isSequenceMode, themeColors: themeColors)
        uiView.claimFirstResponder()
    }
}

/// UIView that captures keyboard input for shortcut editing
class ShortcutCaptureUIView: UIView {
    var isSequenceMode = false
    var onCapture: ((KeySequence) -> Void)?
    var onCancel: (() -> Void)?

    private var firstTrigger: KeyTrigger?
    private var firstTriggerTime: Date?
    private var hasCompleted = false
    private var isSuppressingMenuShortcuts = false
    private let instructionLabel = UILabel()
    private let captureLabel = UILabel()
    private var themeColors: SheetThemeColors?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        layer.cornerRadius = 12
        layer.borderWidth = 2

        // Instruction label
        instructionLabel.textAlignment = .center
        instructionLabel.font = .preferredFont(forTextStyle: .headline)
        instructionLabel.numberOfLines = 0
        addSubview(instructionLabel)

        // Capture label (shows captured keys)
        captureLabel.textAlignment = .center
        captureLabel.font = .monospacedSystemFont(ofSize: 24, weight: .medium)
        captureLabel.textColor = .label
        captureLabel.isHidden = true
        addSubview(captureLabel)

        applyTheme(nil)
        updateInstructions()

        // Replaces the deprecated traitCollectionDidChange override: only the
        // traits that actually feed applyTheme's colors are observed.
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]
        ) { (view: ShortcutCaptureUIView, _) in
            view.applyTheme(view.themeColors)
        }
    }

    func configure(isSequenceMode: Bool, themeColors: SheetThemeColors?) {
        if self.isSequenceMode != isSequenceMode {
            self.isSequenceMode = isSequenceMode
            firstTrigger = nil
            firstTriggerTime = nil
            captureLabel.isHidden = true
            updateInstructions()
        }
        applyTheme(themeColors)
    }

    func applyTheme(_ themeColors: SheetThemeColors?) {
        self.themeColors = themeColors

        let accent = themeColors?.accentColor.map { UIColor($0) } ?? tintColor ?? .systemBlue
        if let themeColors {
            backgroundColor = UIColor(themeColors.rowBackground)
        } else {
            backgroundColor = accent.withAlphaComponent(0.10)
        }

        layer.borderColor = accent.cgColor
        instructionLabel.textColor = accent
        captureLabel.textColor = .label
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyTheme(themeColors)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = bounds.insetBy(dx: 16, dy: 16)
        if captureLabel.isHidden {
            instructionLabel.frame = inset
        } else {
            // Split vertically so the instruction text and the captured-key
            // symbol don't overlap once the first key of a sequence is shown.
            let half = inset.height / 2
            instructionLabel.frame = CGRect(
                x: inset.minX, y: inset.minY,
                width: inset.width, height: half
            )
            captureLabel.frame = CGRect(
                x: inset.minX, y: inset.minY + half,
                width: inset.width, height: half
            )
        }
    }

    private func updateInstructions() {
        if isSequenceMode {
            if firstTrigger == nil {
                instructionLabel.text = "Press the first key combination...\n(e.g., Ctrl+A)"
            } else {
                instructionLabel.text = "Now press the second key...\n(e.g., N)"
                captureLabel.text = firstTrigger?.symbolDescription
                captureLabel.isHidden = false
            }
        } else {
            instructionLabel.text = "Press the key combination...\n(e.g., Cmd+T)"
        }
        // The split layout depends on `captureLabel.isHidden`, which just changed.
        setNeedsLayout()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            claimFirstResponder()
            suppressMenuShortcutsForCapture()
        } else {
            restoreMenuShortcutsAfterCapture()
        }
    }

    deinit {
        restoreMenuShortcutsAfterCapture()
    }

    func claimFirstResponder() {
        guard window != nil, !isFirstResponder else { return }
        _ = becomeFirstResponder()
    }

    // MARK: - Key Commands for Capturing Shortcuts

    /// Override keyCommands to intercept system shortcuts on Mac Catalyst
    /// Without this, shortcuts like CMD+T are captured by the system
    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []

        // Generate key commands for all printable characters with common modifiers
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./"
        let modifierCombinations: [UIKeyModifierFlags] = [
            .command,
            [.command, .shift],
            [.command, .alternate],
            [.command, .shift, .alternate],
            [.command, .control],
            .control,
            [.control, .shift],
            [.control, .alternate],
            .alternate,
            [.alternate, .shift]
        ]

        for char in chars {
            for mods in modifierCombinations {
                let cmd = UIKeyCommand(
                    input: String(char),
                    modifierFlags: mods,
                    action: #selector(handleCapturedKey(_:))
                )
                cmd.wantsPriorityOverSystemBehavior = true
                commands.append(cmd)
            }
        }

        // Add special keys (arrows, function keys, etc.)
        let specialInputs = [
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow,
            UIKeyCommand.inputPageUp,
            UIKeyCommand.inputPageDown,
            UIKeyCommand.inputHome,
            UIKeyCommand.inputEnd,
            UIKeyCommand.inputDelete
        ]

        for input in specialInputs {
            for mods in modifierCombinations + [[]] {
                let cmd = UIKeyCommand(
                    input: input,
                    modifierFlags: mods,
                    action: #selector(handleCapturedKey(_:))
                )
                cmd.wantsPriorityOverSystemBehavior = true
                commands.append(cmd)
            }
        }

        // Function keys F1-F12
        for i in 1...12 {
            // UIKeyCommand uses special input strings for function keys
            let input = String(format: "%c", 0xF700 + i - 1)
            for mods in modifierCombinations + [[]] {
                let cmd = UIKeyCommand(
                    input: input,
                    modifierFlags: mods,
                    action: #selector(handleCapturedKey(_:))
                )
                cmd.wantsPriorityOverSystemBehavior = true
                commands.append(cmd)
            }
        }

        return commands
    }

    @objc private func handleCapturedKey(_ command: UIKeyCommand) {
        guard let trigger = KeyTrigger(uiKeyCommand: command) else { return }
        processCapture(trigger: trigger)
    }

    /// Max interval between two processCapture deliveries that we treat as a
    /// duplicate dispatch of the same physical press. UIKit routes a single
    /// press through keyCommands and pressesBegan within ~milliseconds; humans
    /// can't press two distinct keys this quickly, so this window separates
    /// the two cases without scheduling assumptions.
    private static let duplicateDeliveryWindow: TimeInterval = 0.05

    private func processCapture(trigger: KeyTrigger) {
        guard !hasCompleted else { return }
        if isSequenceMode {
            if firstTrigger == nil {
                // Capture first key
                firstTrigger = trigger
                firstTriggerTime = Date()
                updateInstructions()
            } else if trigger == firstTrigger,
                      let ts = firstTriggerTime,
                      Date().timeIntervalSince(ts) < Self.duplicateDeliveryWindow {
                // Same physical press re-delivered through the other dispatch path.
                // A legitimate "A, A" sequence still works because the user's two
                // deliberate presses are separated by ≫50ms.
                return
            } else {
                // Capture second key - complete sequence
                hasCompleted = true
                let sequence = KeySequence(triggers: [firstTrigger!, trigger])
                onCapture?(sequence)
            }
        } else {
            // Single key mode
            hasCompleted = true
            let sequence = KeySequence(trigger: trigger)
            onCapture?(sequence)
        }
    }

    private func cancelCapture() {
        guard !hasCompleted else { return }
        hasCompleted = true
        onCancel?()
    }

    /// Catalyst delivers the reserved Cmd+Period chord only through the menu
    /// rail (nil-target menuSystemCancel action). That reserved chord never
    /// arrives as a key event, so recording still has to implement this one
    /// selector. Every other menu-owned shortcut is handled by temporarily
    /// clearing `MenuShortcutState` so `keyCommands` sees the physical press.
    @objc func menuSystemCancel(_ sender: Any?) {
        processCapture(trigger: .commandPeriod)
    }

    private func suppressMenuShortcutsForCapture() {
        guard !isSuppressingMenuShortcuts else { return }
        isSuppressingMenuShortcuts = true
        let apply = {
            MenuShortcutState.shared.beginRecordingCapture()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(apply)
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func restoreMenuShortcutsAfterCapture() {
        guard isSuppressingMenuShortcuts else { return }
        isSuppressingMenuShortcuts = false
        DispatchQueue.main.async {
            MenuShortcutState.shared.endRecordingCapture()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }

            // Skip modifier-only keys
            let modifierOnlyKeys: Set<UIKeyboardHIDUsage> = [
                .keyboardLeftShift, .keyboardRightShift,
                .keyboardLeftControl, .keyboardRightControl,
                .keyboardLeftAlt, .keyboardRightAlt,
                .keyboardLeftGUI, .keyboardRightGUI
            ]
            guard !modifierOnlyKeys.contains(key.keyCode) else { continue }

            // iPadOS may deliver the reserved Cmd+Period chord as Period with
            // Command stripped or as a translated Escape. Normalize either
            // representation so the chord is recordable; the twin keyCommands
            // delivery dedups via duplicateDeliveryWindow since both produce
            // the identical trigger.
            if (key.keyCode != .keyboardEscape && KeyCode.sentinelKey(for: key.characters) == .escape)
                || ((key.keyCode == .keyboardPeriod || key.keyCode == .keyboardEscape)
                    && KeyboardTracker.isSystemCancelChordPhysicallyDown()) {
                processCapture(trigger: .commandPeriod)
                return
            }

            // Handle Escape to cancel
            if key.keyCode == .keyboardEscape && key.modifierFlags.isEmpty {
                cancelCapture()
                return
            }

            // Use pressesBegan as fallback for keys not caught by keyCommands
            guard let trigger = KeyTrigger(press: press) else { continue }
            processCapture(trigger: trigger)
            return
        }

        super.pressesBegan(presses, with: event)
    }
}

// MARK: - Preview

#Preview {
    KeybindEditorView(action: .new_local_shell)
}
