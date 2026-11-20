//
//  KeySequenceTracker.swift
//  rootshell
//
//  Tracks pending key sequences for multi-key shortcuts
//

import Foundation
import Combine
import os
import UIKit

/// Result of processing a key press through the sequence tracker
enum KeySequenceResult: Sendable {
    /// Binding matched and should be executed
    case keybind(Keybind)

    /// Waiting for next key in sequence
    case pendingSequence(prefix: KeyTrigger, possibleBindings: [Keybind])

    /// No binding found, key should be passed through
    case passthrough
}

/// Tracks pending key sequences for multi-key shortcuts like Ctrl+A > N
@MainActor
final class KeySequenceTracker: ObservableObject {
    private static let logger = Logger(subsystem: "com.rootshell", category: "KeySequenceTracker")

    /// Shared instance used by the runtime input path. One tracker suffices because
    /// only one terminal holds key-focus at a time and the tracker auto-resets on
    /// timeout; per-view state would add complexity without benefit.
    static let shared = KeySequenceTracker()

    /// The first trigger of a pending sequence
    @Published private(set) var pendingTrigger: KeyTrigger?

    /// Whether we're waiting for the second key in a sequence
    @Published var isAwaitingSecondKey: Bool = false

    /// Possible bindings that match the current prefix
    @Published private(set) var possibleBindings: [Keybind] = []

    /// Installed by the input path. Fires when a pending prefix times out and the
    /// prefix trigger also had a direct single-key binding — tmux-style semantics
    /// where the direct action is deferred but not lost when the prefix is
    /// ambiguous. Captured by value into the timer task at arm-time so a later
    /// install from a different view can't redirect an already-armed fallback.
    var onTimeoutDirectAction: ((Keybind) -> Void)?

    /// Fires when a pending prefix times out, with or without a direct
    /// action, passing the view that armed it and that arming's
    /// `pendingGeneration`. Captured at arm-time too.
    var onPrefixExpired: ((AnyObject?, UInt64) -> Void)?

    /// Identifies the view/caller that armed the current pending prefix. When a
    /// different owner dispatches a key — or when the owner deallocated without
    /// calling `resetIfOwnedBy` and this weak ref nil'd — the prior state is
    /// dropped so one terminal's Ctrl+A can't arm the next view.
    private weak var pendingOwner: AnyObject?

    /// Monotonic counter that timer tasks capture at arm-time. Checked inside
    /// the MainActor hop so a stale timer whose sleep completed just before
    /// `reset()` fired can't wipe a freshly-armed prefix and fire the previous
    /// prefix's fallback in its place.
    private(set) var pendingGeneration: UInt64 = 0

    /// Timeout for waiting for second key (1 second)
    private let timeout: TimeInterval = 1.0

    /// Task for timeout handling
    private var timeoutTask: Task<Void, Never>?

    /// Reference to keybind manager
    private let keybindManager: KeybindManager

    // MARK: - Initialization

    init(keybindManager: KeybindManager) {
        self.keybindManager = keybindManager
    }

    convenience init() {
        self.init(keybindManager: KeybindManager.shared)
    }

    // MARK: - Processing

    /// Process a key press and return the result
    /// - Parameter trigger: The key trigger to process
    /// - Returns: The result of processing the trigger
    func process(trigger: KeyTrigger) -> KeySequenceResult {
        // Cancel any existing timeout
        timeoutTask?.cancel()
        timeoutTask = nil

        // If we're awaiting second key, try to complete the sequence
        if let pending = pendingTrigger, isAwaitingSecondKey {
            let sequence = KeySequence(triggers: [pending, trigger])

            // Check if this completes a valid sequence
            if let keybind = keybindManager.keybind(for: sequence) {
                let actionName = keybind.action.rawValue
                let seqFormat = sequence.ghosttyFormat
                Self.logger.info("Sequence completed: \(seqFormat) -> \(actionName)")
                reset()
                return .keybind(keybind)
            }

            // Invalid second key - reset and pass through
            Self.logger.info("Invalid second key in sequence, resetting")
            reset()

            // Check if this trigger itself starts a new sequence or has a direct binding
            return processFirstKey(trigger)
        }

        // Process as first key
        return processFirstKey(trigger)
    }

    /// High-level convenience for the input dispatch path. Only intervenes when
    /// there is something sequence-related to do; otherwise the caller keeps its
    /// existing single-trigger lookup.
    ///
    /// - Parameters:
    ///   - owner: The dispatching view. If a different owner had armed the
    ///     prior pending prefix (or the owner has deallocated), that prefix is
    ///     dropped before processing so sequence state can't leak between
    ///     terminal views/windows.
    ///   - trigger: The key trigger being dispatched.
    /// - Returns: `handled` is true when the tracker consumed the press (either
    ///   a sequence completed or a prefix is now pending). `keybind` is set when
    ///   the caller should execute an action immediately.
    func consume(owner: AnyObject, trigger: KeyTrigger) -> (handled: Bool, keybind: Keybind?) {
        // Drop stale pending state in two cases:
        //   1. Another view had armed a prefix (cross-view leak).
        //   2. The owning view deallocated without calling `resetIfOwnedBy`
        //      and the weak reference nil'd — otherwise the next view's first
        //      key would be consumed as the stale sequence's second key.
        // `!==` on `AnyObject?` returns true when `pendingOwner` is nil, so
        // one check covers both cases.
        if isAwaitingSecondKey, pendingOwner !== owner {
            Self.logger.info("Pending prefix is stale (owner absent or different view), resetting")
            reset()
        }
        if !isAwaitingSecondKey && !keybindManager.isSequencePrefix(trigger) {
            return (handled: false, keybind: nil)
        }
        switch process(trigger: trigger) {
        case .keybind(let kb):
            return (true, kb)
        case .pendingSequence:
            // A prefix was just armed — tag this view as the owner so future
            // consume() calls from a different view trigger the cross-view
            // reset and so resetIfOwnedBy can clean up on focus loss.
            pendingOwner = owner
            return (true, nil)
        case .passthrough:
            // Can happen when an invalid second key falls through processFirstKey
            // and is itself neither bound nor a prefix. Let the caller handle it.
            return (false, nil)
        }
    }

    /// Process a key as the first (or only) key in a potential sequence
    private func processFirstKey(_ trigger: KeyTrigger) -> KeySequenceResult {
        // First, check for direct single-key bindings
        let singleSequence = KeySequence(trigger: trigger)
        let directKeybind = keybindManager.keybind(for: singleSequence)

        // Check if this trigger is a prefix for any sequences
        let sequenceBindings = keybindManager.bindingsStartingWith(trigger: trigger)
            .filter { $0.sequence.isSequence }

        // Check for direct binding
        if let directKeybind {
            // If there are also sequences starting with this trigger, we need to wait
            if !sequenceBindings.isEmpty {
                // Exception: when the direct binding is just a built-in
                // control-character default (ctrl_a…ctrl_z), arming a 1-second
                // pending prefix would break terminal typing speed in
                // vim/emacs/readline. Pass through so the existing pressesBegan
                // fast path (or Catalyst's handleControlKey) sends the control
                // byte immediately. The sequence binding is unreachable in this
                // case — users who want tmux-style prefixes should pick a key
                // whose default isn't a control char.
                if directKeybind.source == .default && directKeybind.action.isControlCharacter {
                    let trigFormat = trigger.ghosttyFormat
                    Self.logger.info("Default control-char shadows sequence prefix, passing through: \(trigFormat)")
                    return .passthrough
                }
                startPendingSequence(
                    trigger: trigger,
                    bindings: sequenceBindings,
                    directKeybind: directKeybind
                )
                let trigFormat = trigger.ghosttyFormat
                Self.logger.info("Trigger may be sequence prefix, waiting: \(trigFormat)")
                return .pendingSequence(prefix: trigger, possibleBindings: sequenceBindings)
            }

            // Direct match, no conflict
            let trigFormat = trigger.ghosttyFormat
            let actionName = directKeybind.action.rawValue
            Self.logger.info("Direct binding: \(trigFormat) -> \(actionName)")
            return .keybind(directKeybind)
        }

        // No direct binding - check if it's a sequence prefix
        if !sequenceBindings.isEmpty {
            startPendingSequence(
                trigger: trigger,
                bindings: sequenceBindings,
                directKeybind: nil
            )
            let trigFormat = trigger.ghosttyFormat
            Self.logger.info("Sequence prefix detected: \(trigFormat)")
            return .pendingSequence(prefix: trigger, possibleBindings: sequenceBindings)
        }

        // No binding at all
        return .passthrough
    }

    /// Start waiting for second key in sequence
    private func startPendingSequence(
        trigger: KeyTrigger,
        bindings: [Keybind],
        directKeybind: Keybind?
    ) {
        pendingTrigger = trigger
        isAwaitingSecondKey = true
        possibleBindings = bindings

        pendingGeneration &+= 1
        let generation = pendingGeneration
        // Capture fallback + callback by value so the timer task is insulated
        // from any later arm/install. Together with the generation check below
        // this closes the race where a sleep that completed just before a new
        // prefix armed would otherwise wipe the new state and fire the old
        // prefix's direct action in its place.
        let capturedFallback = directKeybind
        let capturedCallback = onTimeoutDirectAction
        let capturedExpiry = onPrefixExpired
        let timeoutInterval = timeout

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutInterval * 1_000_000_000))

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                // Bail if a new prefix armed between sleep completion and this
                // MainActor hop — otherwise we'd reset the new prefix's state
                // and fire a stale fallback.
                guard self.pendingGeneration == generation else { return }
                guard self.isAwaitingSecondKey else { return }
                Self.logger.info("Sequence timeout, resetting")
                let owner = self.pendingOwner
                self.reset()
                if let capturedFallback {
                    capturedCallback?(capturedFallback)
                }
                capturedExpiry?(owner, generation)
            }
        }
    }

    /// Reset only if the given view was the one that armed the current prefix.
    /// Call from `resignFirstResponder` so a terminal losing focus clears its
    /// own pending state without clobbering a prefix armed elsewhere.
    func resetIfOwnedBy(_ owner: AnyObject) {
        guard let pendingOwner, pendingOwner === owner else { return }
        reset()
    }

    /// Reset the sequence tracker state
    func reset() {
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingTrigger = nil
        isAwaitingSecondKey = false
        possibleBindings = []
        pendingOwner = nil
    }

    /// Get display string for current pending state (for UI indicator)
    var pendingDisplayString: String? {
        guard let trigger = pendingTrigger, isAwaitingSecondKey else {
            return nil
        }
        return "\(trigger.symbolDescription) ..."
    }
}

// MARK: - Convenience Extensions

extension KeySequenceTracker {
    /// Process a UIPress event
    func process(press: UIPress) -> KeySequenceResult {
        guard let trigger = KeyTrigger(press: press) else {
            return .passthrough
        }
        return process(trigger: trigger)
    }

    /// Process a UIKeyCommand
    func process(command: UIKeyCommand) -> KeySequenceResult {
        guard let trigger = KeyTrigger(uiKeyCommand: command) else {
            return .passthrough
        }
        return process(trigger: trigger)
    }
}
