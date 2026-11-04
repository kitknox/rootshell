//
//  QuickConnectField.swift
//  rootshell
//
//  Bash-style quick connect field with inline tab auto-completion
//

import SwiftUI
import UIKit

/// UITextField subclass that handles Tab key for auto-completion
class QuickConnectTextField: UITextField, KeyboardButtonDelegate {
    var onTab: ((QuickConnectTextField) -> Void)?
    var onEnter: (() -> Void)?

    private var keyboardAccessory: KeyboardAccessoryView?
    private var activeKeyboardModifiers: KeyModifiers = []
    private var keyboardStateTask: Task<Void, Never>?
    private var keyboardVisibilityTask: Task<Void, Never>?
    private var keyboardAnimationTask: Task<Void, Never>?
    private var pendingInputViewReload = false
    private var wantsFocus = false
    private var focusRequestScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupAccessoryView()
        observeKeyboardChanges()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupAccessoryView()
        observeKeyboardChanges()
    }

    private func setupAccessoryView() {
        // Use the new keyboard toolbar
        keyboardAccessory = KeyboardAccessoryView(sizes: .current(traitCollection: traitCollection))
        keyboardAccessory?.delegate = self
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
            (field: QuickConnectTextField, _: UITraitCollection) in
            field.keyboardAccessory?.updateForTraitCollection(field.traitCollection)
        }

        // Listen for modifier changes from toolbar
        keyboardAccessory?.onModifiersChanged = { [weak self] modifiers in
            self?.activeKeyboardModifiers = modifiers
        }
    }

    private func observeKeyboardChanges() {
        // Update input accessory view when keyboard state changes
        keyboardStateTask = Task { @MainActor [weak self] in
            for await _ in KeyboardTracker.shared.hardwareKeyboardStateDidChangeStream() {
                self?.reloadInputViews()
            }
        }

        // Also refresh when software keyboard visibility changes
        keyboardVisibilityTask = Task { @MainActor [weak self] in
            for await _ in KeyboardTracker.shared.softwareKeyboardVisibilityDidChangeStream() {
                self?.reloadInputViews()
            }
        }

        // iPadOS 27 can leave the remote-keyboard placeholder in a transient
        // hierarchy while its placement animation finishes. Flush at most one
        // reload after that transition, and only if this field still owns the
        // keyboard (the connection form may have navigated elsewhere by then).
        keyboardAnimationTask = Task { @MainActor [weak self] in
            for await animating in KeyboardTracker.shared.keyboardAnimationDidChangeStream() {
                guard let self else { break }
                if !animating {
                    self.flushPendingInputViewReloadIfNeeded()
                }
            }
        }
    }

    deinit {
        keyboardStateTask?.cancel()
        keyboardVisibilityTask?.cancel()
        keyboardAnimationTask?.cancel()
    }

    /// KeyboardTracker measures keyboard frames against the input owner's
    /// window. Terminals register it from their input-view getters; this
    /// field never goes through those, so claim it before UIKit posts the
    /// show notifications.
    override func becomeFirstResponder() -> Bool {
        KeyboardTracker.shared.setInputOwnerWindow(window)
        return super.becomeFirstResponder()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        guard window != nil else {
            pendingInputViewReload = false
            focusRequestScheduled = false
            return
        }
        scheduleFocusRequestIfNeeded()
    }

    /// Apply SwiftUI's requested focus only after UIKit has attached the field
    /// to a window. Calling becomeFirstResponder from updateUIView while the
    /// hosting controller is still being mounted can start a stale InputUI
    /// session on iPadOS 27.
    func setFocusRequested(_ requested: Bool) {
        wantsFocus = requested
        if requested {
            scheduleFocusRequestIfNeeded()
        } else if isFirstResponder {
            _ = resignFirstResponder()
        }
    }

    private func scheduleFocusRequestIfNeeded() {
        guard wantsFocus,
              window != nil,
              !isFirstResponder,
              !focusRequestScheduled else { return }

        focusRequestScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusRequestScheduled = false
            guard self.wantsFocus,
                  self.window != nil,
                  !self.isFirstResponder,
                  // Raising the keyboard under lock draws into the lock
                  // snapshot (FrontBoard 0x2BAD45EC).
                  !Ghostty.isSecureDrawProhibitedAtomic else { return }
            _ = self.becomeFirstResponder()
        }
    }

    /// `reloadInputViews()` is only meaningful for the active, attached
    /// responder. In particular, the Quick Connect field remains alive behind
    /// NavigationStack destinations such as Add Port Forward; allowing its
    /// process-wide keyboard subscriptions to reload while inactive can make
    /// UIKit attach its accessory to another field's remote-keyboard host.
    override func reloadInputViews() {
        guard isFirstResponder, window != nil else {
            pendingInputViewReload = false
            return
        }
        // The placement move this triggers draws; under lock that is a
        // FrontBoard 0x2BAD45EC kill.
        guard !Ghostty.isSecureDrawProhibitedAtomic else {
            pendingInputViewReload = false
            return
        }
        guard !KeyboardTracker.shared.isKeyboardAnimating else {
            pendingInputViewReload = true
            return
        }

        pendingInputViewReload = false
        super.reloadInputViews()
    }

    private func flushPendingInputViewReloadIfNeeded() {
        guard pendingInputViewReload else { return }
        guard isFirstResponder, window != nil else {
            pendingInputViewReload = false
            return
        }
        reloadInputViews()
    }

    #if !os(visionOS)
    override var inputAccessoryView: UIView? {
        get {
            // Only show toolbar when software keyboard is active
            // Hide for hardware keyboards and macOS compatibility mode
            // UITextField is always accessed on main thread, so we can safely assume main actor
            return MainActor.assumeIsolated { () -> UIView? in
                #if !targetEnvironment(macCatalyst)
                // The terminal keyboard brings its own toolbar.
                if inputView is TerminalTouchKeyboardInputView { return nil }
                #endif
                let tracker = KeyboardTracker.shared
                let shouldShow = !tracker.isHardwareKeyboard || tracker.isSoftwareKeyboardVisible
                return shouldShow ? keyboardAccessory : nil
            }
        }
        set {
            // Ignore setter - we compute the value dynamically
        }
    }
    #endif

    // MARK: - KeyboardButtonDelegate

    func keyPressed(_ key: String, modifiers: KeyModifiers) {
        // Handle Tab key for auto-completion
        if key == "\t" {
            onTab?(self)
            return
        }

        // Handle other keys by inserting text
        // Note: Modifiers from toolbar buttons are already included in the 'modifiers' parameter
        // For QuickConnectField, we typically don't need control sequences, so just insert the key
        if let data = key.data(using: .utf8), let text = String(data: data, encoding: .utf8) {
            self.insertText(text)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }

            // Handle Tab key
            if key.keyCode == .keyboardTab {
                onTab?(self)
                handled = true
            }
            // Handle Enter/Return key
            else if key.keyCode == .keyboardReturnOrEnter {
                onEnter?()
                handled = true
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }
}

/// SwiftUI wrapper for QuickConnectTextField with inline auto-completion
struct QuickConnectField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let placeholder: String
    let suggestionProvider: QuickConnectSuggestionProvider
    let onCommit: () -> Void
    let onSuggestionAccepted: ((AnyQuickConnectSuggestion) -> Void)?

    /// Optional themed background color for the container (overrides .systemBackground)
    var containerBackgroundColor: UIColor?

    @State private var currentSuggestionIndex = 0

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = containerBackgroundColor ?? .systemBackground
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.systemGray4.cgColor
        container.tag = 200 // Tag for container lookup

        // Background label for suggestion (greyed out)
        let suggestionLabel = UILabel()
        suggestionLabel.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        suggestionLabel.textColor = .systemGray3
        suggestionLabel.translatesAutoresizingMaskIntoConstraints = false
        suggestionLabel.isUserInteractionEnabled = false // Don't block touches to text field
        suggestionLabel.lineBreakMode = .byTruncatingMiddle
        suggestionLabel.tag = 100 // Tag for lookup
        container.addSubview(suggestionLabel)

        // Foreground text field
        let textField = QuickConnectTextField()
        textField.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        textField.placeholder = placeholder
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.keyboardType = .URL
        textField.returnKeyType = .go
        textField.textContentType = .URL
        textField.delegate = context.coordinator
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.backgroundColor = .clear
        textField.tag = 101 // Tag for lookup
        container.addSubview(textField)

        // Layout constraints with padding
        NSLayoutConstraint.activate([
            suggestionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            suggestionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            suggestionLabel.topAnchor.constraint(equalTo: container.topAnchor),
            suggestionLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            textField.topAnchor.constraint(equalTo: container.topAnchor),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Tab key handler
        textField.onTab = { textField in
            context.coordinator.handleTab(textField: textField)
        }

        // Enter key handler
        textField.onEnter = {
            onCommit()
        }

        // Tap gesture on container to ensure field gets focus when tapped
        // This acts as a fallback when tapping empty space around the text field
        let containerTapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleContainerTap(_:)))
        containerTapGesture.cancelsTouchesInView = false
        containerTapGesture.delegate = context.coordinator
        container.addGestureRecognizer(containerTapGesture)

        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let textField = container.viewWithTag(101) as? QuickConnectTextField else {
            return
        }

        // Update parent reference so coordinator has access to latest state/suggestions
        context.coordinator.parent = self

        // Update container background color for theme changes
        container.backgroundColor = containerBackgroundColor ?? .systemBackground

        // Update text if different (avoid loops)
        if textField.text != text {
            textField.text = text

            // Clear suggestion label when text is set programmatically
            // This prevents stale suggestions from browse selections or other programmatic updates
            if let suggestionLabel = container.viewWithTag(100) as? UILabel {
                suggestionLabel.text = ""
            }

            // Also update coordinator state to prevent debounce timer from re-showing suggestion
            context.coordinator.lastUserTypedText = text
            context.coordinator.debounceTimer?.invalidate()
        }

        // Update focus state. The field applies an affirmative request only
        // after it is attached to a window, avoiding an iPadOS 27 InputUI
        // session against a not-yet-mounted hosting hierarchy.
        textField.setFocusRequested(isFocused)

        // Update visual focus indicator
        if isFocused {
            container.layer.borderColor = UIColor.systemBlue.cgColor
            container.layer.borderWidth = 2
        } else {
            container.layer.borderColor = UIColor.systemGray4.cgColor
            container.layer.borderWidth = 1
        }

        // We do NOT call updateSuggestion here to avoid defeating the debounce timer.
        // The timer in textFieldDidChangeSelection will handle showing the suggestion
        // after the user stops typing.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        guard let textField = container.viewWithTag(101) as? QuickConnectTextField else { return }
        textField.setFocusRequested(false)
    }

    class Coordinator: NSObject, UITextFieldDelegate, UIGestureRecognizerDelegate {
        var parent: QuickConnectField
        var currentSuggestionIndex = 0
        var isUpdatingProgrammatically = false
        var cachedSuggestions: [AnyQuickConnectSuggestion] = []
        var cachedFilterPrefix: String = ""
        var lastUserTypedText: String = ""

        // Debounce timer for suggestions
        var debounceTimer: Timer?

        // Double-tab detection for substring matching
        var lastTabTime: Date?
        var matchingMode: MatchingMode = .prefix
        let doubleTabThreshold: TimeInterval = 0.5 // seconds

        init(_ parent: QuickConnectField) {
            self.parent = parent
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            // Don't process if we're updating programmatically
            guard !isUpdatingProgrammatically else {
                return
            }

            let newText = textField.text ?? ""

            // Update binding
            parent.text = newText

            // Track user-typed text and reset completion state when it changes
            if newText != lastUserTypedText {
                lastUserTypedText = newText
                currentSuggestionIndex = 0
                cachedSuggestions = []
                cachedFilterPrefix = ""
                matchingMode = .prefix // Reset to prefix mode when user types
                lastTabTime = nil // Reset double-tab detection

                // Clear suggestion immediately when typing
                if let container = textField.superview,
                   let suggestionLabel = container.viewWithTag(100) as? UILabel {
                    suggestionLabel.text = ""
                }

                // Debounce suggestion update
                debounceTimer?.invalidate()
                debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                    guard let self = self,
                          let container = textField.superview,
                          let suggestionLabel = container.viewWithTag(100) as? UILabel else { return }

                    self.updateSuggestion(textField: textField, suggestionLabel: suggestionLabel)
                }
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isFocused = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onCommit()
            return false
        }

        func handleTab(textField: UITextField) {
            let currentFieldText = textField.text?.trimmingCharacters(in: .whitespaces) ?? ""

            // Double-tab detection: If tab pressed within threshold, switch to substring mode
            let now = Date()
            if let lastTime = lastTabTime, now.timeIntervalSince(lastTime) < doubleTabThreshold {
                // Double-tab detected!
                if matchingMode == .prefix {
                    // Switch to substring mode
                    matchingMode = .substring
                    // Clear cache to force rebuild with new mode
                    cachedSuggestions = []
                    cachedFilterPrefix = ""
                    currentSuggestionIndex = 0

                    // Update suggestion label immediately to show mode change
                    if let container = textField.superview,
                       let suggestionLabel = container.viewWithTag(100) as? UILabel {
                        updateSuggestion(textField: textField, suggestionLabel: suggestionLabel)
                    }
                }
            }
            lastTabTime = now

            // Build cache on first Tab press (when cache is empty)
            if cachedSuggestions.isEmpty {
                cachedFilterPrefix = currentFieldText

                // Get suggestions from provider with the current matching mode
                // The provider will filter by searchText and mode internally
                cachedSuggestions = parent.suggestionProvider.getSuggestions(
                    matching: currentFieldText,
                    mode: matchingMode
                )

                currentSuggestionIndex = 0
            }

            guard !cachedSuggestions.isEmpty else {
                return
            }

            // Ensure index is within bounds
            if currentSuggestionIndex >= cachedSuggestions.count {
                currentSuggestionIndex = 0
            }

            let selectedSuggestion = cachedSuggestions[currentSuggestionIndex]

            // Final safety check: ensure selected suggestion matches the original filter
            if !currentFieldText.isEmpty && !selectedSuggestion.matches(cachedFilterPrefix, mode: matchingMode) {
                // Cache is corrupted somehow, rebuild it
                cachedSuggestions = []
                handleTab(textField: textField) // Retry
                return
            }

            // Set flag to prevent delegate from clearing cache
            isUpdatingProgrammatically = true
            defer { isUpdatingProgrammatically = false }

            // Update text field with completionString (e.g., "root@192.168.1.1" for cloud instances)
            textField.text = selectedSuggestion.completionString

            // Also update binding so Enter key can use the completed value
            parent.text = selectedSuggestion.completionString

            // Update lastUserTypedText to prevent cache clearing on next change detection
            lastUserTypedText = selectedSuggestion.completionString

            // Clear the suggestion label since we just accepted the suggestion
            if let container = textField.superview,
               let suggestionLabel = container.viewWithTag(100) as? UILabel {
                suggestionLabel.text = ""
            }

            // Notify parent that a suggestion was accepted (for auth restoration)
            parent.onSuggestionAccepted?(selectedSuggestion)

            // Advance to next suggestion for next Tab press (if multiple exist)
            if cachedSuggestions.count > 1 {
                currentSuggestionIndex = (currentSuggestionIndex + 1) % cachedSuggestions.count
            }
        }

        func updateSuggestion(textField: UITextField, suggestionLabel: UILabel) {
            let currentText = parent.text

            guard !currentText.isEmpty else {
                suggestionLabel.text = ""
                return
            }

            // Check for HSS shorthand (starts with "!")
            if HSSConfigManager.isHSSShorthand(currentText) {
                updateHSSSuggestion(currentText: currentText, suggestionLabel: suggestionLabel)
                return
            }

            // Get suggestions from provider with current matching mode
            let matchingSuggestions = parent.suggestionProvider.getSuggestions(
                matching: currentText,
                mode: matchingMode
            )

            guard !matchingSuggestions.isEmpty else {
                suggestionLabel.text = ""
                currentSuggestionIndex = 0
                return
            }

            // Ensure index is within bounds
            if currentSuggestionIndex >= matchingSuggestions.count {
                currentSuggestionIndex = 0
            }

            // Show current suggestion
            let suggestion = matchingSuggestions[currentSuggestionIndex]
            let suggestionText = suggestion.displayString

            // Display the full suggestion text (with mode indicator if in substring mode)
            if matchingMode == .substring {
                suggestionLabel.text = suggestionText + " [substring]"
            } else {
                suggestionLabel.text = suggestionText
            }
        }

        /// Update suggestion label for HSS shorthand input
        private func updateHSSSuggestion(currentText: String, suggestionLabel: UILabel) {
            // For HSS mode, don't show anything in the suggestion label.
            // The expanded values are already shown in the form fields below,
            // and showing the full expansion here would overlap with the user's
            // typed shorthand text (e.g., "!prod" vs "user@server.example.com").
            suggestionLabel.text = ""
        }
        
        @objc func handleContainerTap(_ gesture: UITapGestureRecognizer) {
            // When the container is tapped, ensure the text field gets focus
            guard let container = gesture.view,
                  let textField = container.viewWithTag(101) as? UITextField else { return }

            // Make the text field first responder to show keyboard
            if !textField.isFirstResponder {
                textField.becomeFirstResponder()
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                              shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Allow container tap to work alongside text field's built-in gestures
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Only recognize container taps, let text field handle its own touches
            guard let container = gestureRecognizer.view,
                  let textField = container.viewWithTag(101) as? UITextField else {
                return true
            }

            // Convert touch location to container coordinate space
            let locationInContainer = touch.location(in: container)
            let textFieldFrame = textField.frame

            // If touch is inside the text field bounds, let text field handle it
            // Container gesture should only handle touches in the padding area
            if textFieldFrame.contains(locationInContainer) {
                return false
            }

            return true
        }
    }
}

/// Parsed result from quick connect string
struct ParsedConnection {
    var username: String?
    var host: String?
    var port: Int?

    // Jump host fields (optional)
    var jumpUsername: String?
    var jumpHost: String?
    var jumpPort: Int?

    // Protocol (SSH or Mosh) - determined by prefix
    var connectionProtocol: ConnectionProtocol = .ssh

    /// Whether this connection has a jump host configured
    var hasJumpHost: Bool {
        jumpHost != nil && !jumpHost!.isEmpty
    }

    /// Whether this is a Mosh connection
    var isMosh: Bool {
        connectionProtocol == .mosh
    }
}

/// Parse a quick connect string into components
/// Supports formats:
///   - user@host
///   - user@host:port
///   - user@target via jump@proxy
///   - user@target:port via jump@proxy:port
///   - mosh user@host (Mosh protocol)
///   - mosh://user@host (Mosh URL scheme)
///   - ssh://user@host (SSH URL scheme)
struct QuickConnectParser {
    /// Parse a quick connect string, returning basic target info
    /// For backward compatibility with existing code
    static func parse(_ input: String) -> (username: String?, host: String?, port: Int?) {
        let result = parseWithJumpHost(input)
        return (result.username, result.host, result.port)
    }

    /// Parse a quick connect string with full jump host and protocol support
    static func parseWithJumpHost(_ input: String) -> ParsedConnection {
        var result = ParsedConnection()

        var trimmed = input.trimmingCharacters(in: .whitespaces)

        // Check for protocol prefix (mosh:// or ssh:// or "mosh " prefix)
        if trimmed.lowercased().hasPrefix("mosh://") {
            result.connectionProtocol = .mosh
            trimmed = String(trimmed.dropFirst(7))  // Remove "mosh://"
        } else if trimmed.lowercased().hasPrefix("ssh://") {
            result.connectionProtocol = .ssh
            trimmed = String(trimmed.dropFirst(6))  // Remove "ssh://"
        } else if trimmed.lowercased().hasPrefix("mosh ") {
            result.connectionProtocol = .mosh
            trimmed = String(trimmed.dropFirst(5))  // Remove "mosh "
        }

        // Trim again after prefix removal
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)

        // Check for "via" syntax: user@target via jump@proxy
        if let viaRange = trimmed.range(of: " via ", options: .caseInsensitive) {
            let targetPart = String(trimmed[..<viaRange.lowerBound])
            let jumpPart = String(trimmed[viaRange.upperBound...])

            // Parse target
            let target = parseHostString(targetPart)
            result.username = target.username
            result.host = target.host
            result.port = target.port

            // Parse jump host
            let jump = parseHostString(jumpPart)
            result.jumpUsername = jump.username
            result.jumpHost = jump.host
            result.jumpPort = jump.port

            return result
        }

        // No "via" - parse as simple connection
        let simple = parseHostString(trimmed)
        result.username = simple.username
        result.host = simple.host
        result.port = simple.port

        return result
    }

    /// Parse a single host string: user@host:port
    private static func parseHostString(_ input: String) -> (username: String?, host: String?, port: Int?) {
        var username: String?
        var host: String?
        var port: Int?

        var remaining = input.trimmingCharacters(in: .whitespaces)

        // Check for port (user@host:port or host:port)
        if let colonRange = remaining.range(of: ":", options: .backwards) {
            let portString = String(remaining[colonRange.upperBound...])
            if let parsedPort = Int(portString) {
                port = parsedPort
                remaining = String(remaining[..<colonRange.lowerBound])
            }
        }

        // Check for username (user@host) — split on LAST @ so usernames containing @
        // (e.g. Active-Directory-style user@domain) survive host separation.
        if let atRange = remaining.range(of: "@", options: .backwards) {
            username = String(remaining[..<atRange.lowerBound])
            host = String(remaining[atRange.upperBound...])
        } else {
            // No @ symbol, treat entire string as host
            host = remaining
        }

        return (username, host, port)
    }
}
