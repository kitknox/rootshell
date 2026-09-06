//
//  ScrollbackPersistenceManager.swift
//  rootshell
//
//  Manages periodic persistence of terminal scrollback buffers to disk,
//  and restoration on session reconnect. Scrollback is dumped as ANSI-styled
//  text from Ghostty's primary screen buffer, preserving colors and styles.
//

import Crypto
import Foundation
import os
import UIKit

/// Manages per-terminal scrollback save/restore lifecycle.
@MainActor
final class ScrollbackPersistenceManager {
    static let shared = ScrollbackPersistenceManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ScrollbackPersistence")

    // MARK: - Settings

    static let enabledKey = "scrollbackPersistenceEnabled"

    static var isEnabled: Bool {
        SettingsStore.shared.value(Settings.SessionRestore.scrollbackPersistence)
    }

    // MARK: - Configuration

    /// Maximum file size before truncation (10 MB)
    private let maxFileSize = 10 * 1024 * 1024

    /// Debounce interval after output stops before saving
    private let debounceDuration: TimeInterval = 2.0

    /// Periodic save interval as fallback for continuous output
    private let periodicInterval: TimeInterval = 30.0

    /// Orphan file age threshold before cleanup (72 hours)
    private let orphanAgeThreshold: TimeInterval = 72 * 3600

    // MARK: - State

    private struct TerminalRef {
        weak var terminal: Ghostty.TerminalView?
    }

    private var registeredTerminals: [UUID: TerminalRef] = [:]
    private var outputDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var periodicTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Per-terminal hash of (dump bytes + mode flags) used to skip redundant saves.
    /// Shared between the main-actor debounce path and the background periodic path,
    /// so either path can observe the other's most recent save.
    nonisolated private static let lastSavedHashes = OSAllocatedUnfairLock(
        initialState: [UUID: Int]()
    )

    // MARK: - Storage

    private var scrollbackDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(".ghostty/scrollback", isDirectory: true)
    }

    private func scrollbackFileURL(for uuid: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent("\(uuid.uuidString).ansi.enc")
    }

    private func legacyScrollbackFileURL(for uuid: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent("\(uuid.uuidString).ansi")
    }

    private func alternateScreenFlagURL(for uuid: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent("\(uuid.uuidString).altscreen.enc")
    }

    private func atPromptFlagURL(for uuid: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent("\(uuid.uuidString).atprompt.enc")
    }

    private func mouseCaptureURL(for uuid: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent("\(uuid.uuidString).mousecapture.enc")
    }

    private func cursorKeyModeURL(for uuid: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent("\(uuid.uuidString).cursorkeys.enc")
    }

    private func focusEventModeURL(for uuid: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent("\(uuid.uuidString).focusevent.enc")
    }

    // MARK: - Init

    private init() {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDidEnterBackground()
                }
            }
        )

        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    ForegroundActivationGate.shared.runWhenSafe(
                        reason: "scrollback.periodicTimer",
                        timeoutPolicy: .fireIfNotBackgrounded
                    ) {
                        self?.startPeriodicTimerIfNeeded()
                    }
                }
            }
        )
    }

    // MARK: - Registration

    func registerTerminal(_ terminal: Ghostty.TerminalView) {
        guard Self.isEnabled else { return }
        let uuid = terminal.uuid
        registeredTerminals[uuid] = TerminalRef(terminal: terminal)
        Self.logger.debug("Registered terminal \(uuid.uuidString.prefix(8)) for scrollback persistence")
        startPeriodicTimerIfNeeded()
    }

    func unregisterTerminal(uuid: UUID) {
        registeredTerminals.removeValue(forKey: uuid)
        Self.lastSavedHashes.withLock { $0[uuid] = nil }
        outputDebounceTasks[uuid]?.cancel()
        outputDebounceTasks.removeValue(forKey: uuid)

        if registeredTerminals.isEmpty {
            stopPeriodicTimer()
        }
    }

    // MARK: - Save Triggers

    /// Called when a terminal receives output. Starts/resets debounce timer.
    func notifyOutputReceived(terminalUUID uuid: UUID) {
        guard Self.isEnabled else { return }
        guard registeredTerminals[uuid] != nil else { return }

        outputDebounceTasks[uuid]?.cancel()
        outputDebounceTasks[uuid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveScrollback(for: uuid)
        }
    }

    /// Save all registered terminals immediately (e.g., on app background).
    func forceSaveAll() {
        guard Self.isEnabled else { return }
        for uuid in registeredTerminals.keys {
            outputDebounceTasks[uuid]?.cancel()
            outputDebounceTasks.removeValue(forKey: uuid)
            saveScrollback(for: uuid)
        }
    }

    // MARK: - Background Save Support

    /// Per-surface refcount and semaphore for surfaces being saved in background tasks.
    /// Multiple overlapping save passes can target the same surface (e.g., two scenes
    /// backgrounding concurrently). The semaphore is only signaled when the refcount
    /// reaches zero, ensuring cleanup() waits for ALL saves to finish.
    private struct SurfaceGuard {
        var count: Int
        let semaphore: DispatchSemaphore
    }

    // uncheckedState: the keys are raw surface pointers, which carry no
    // Sendable conformance. The lock itself is what makes access safe.
    nonisolated private static let inFlightSurfaces = OSAllocatedUnfairLock(
        uncheckedState: [ghostty_surface_t: SurfaceGuard]()
    )

    /// Increment the in-flight refcount for a surface. Creates the guard if first save.
    nonisolated private static func retainSurface(_ surface: ghostty_surface_t) {
        nonisolated(unsafe) let surface = surface
        inFlightSurfaces.withLock { dict in
            if var guard_ = dict[surface] {
                guard_.count += 1
                dict[surface] = guard_
            } else {
                dict[surface] = SurfaceGuard(count: 1, semaphore: DispatchSemaphore(value: 0))
            }
        }
    }

    /// Decrement the in-flight refcount. Signals the semaphore when it reaches zero.
    nonisolated private static func releaseSurface(_ surface: ghostty_surface_t) {
        nonisolated(unsafe) let surface = surface
        let shouldSignal = inFlightSurfaces.withLock { dict -> DispatchSemaphore? in
            guard var guard_ = dict[surface] else { return nil }
            guard_.count -= 1
            if guard_.count <= 0 {
                dict.removeValue(forKey: surface)
                return guard_.semaphore
            } else {
                dict[surface] = guard_
                return nil
            }
        }
        shouldSignal?.signal()
    }

    /// Block until all background saves for this surface complete, with a
    /// 500 ms cap. Callers use this before `ghostty_surface_free` to avoid
    /// use-after-free, since the in-flight save dumps the surface's primary
    /// screen. Returns `true` if all saves completed; returns `false` on
    /// timeout, in which case the caller MUST NOT free the surface (the
    /// save is still using it). Accepting a leak is the right tradeoff —
    /// a wedged save would otherwise saturate `ghosttyAPIQueue` and stall
    /// every subsequent occlusion/render call queued behind it.
    @discardableResult
    nonisolated static func waitForSurfaceSave(_ surface: ghostty_surface_t) -> Bool {
        nonisolated(unsafe) let surface = surface
        guard let sem = inFlightSurfaces.withLock({ $0[surface]?.semaphore }) else { return true }
        let result = sem.wait(timeout: .now() + 0.5)
        return result != .timedOut
    }

    /// Release in-flight markers for refs that won't be saved (e.g., encryption key unavailable).
    nonisolated static func clearInFlightSurfaces(_ refs: [BackgroundTerminalRef]) {
        guard !refs.isEmpty else { return }
        for ref in refs {
            releaseSurface(ref.surfacePointer)
        }
    }

    /// Lightweight snapshot of terminal state gathered on MainActor for background save.
    /// @unchecked because the raw surface pointer has no Sendable conformance;
    /// the retain/release refcount above is what keeps it alive across the hop.
    nonisolated struct BackgroundTerminalRef: @unchecked Sendable {
        let surfacePointer: ghostty_surface_t
        let uuid: UUID
        let isAtPrompt: Bool
        let isAlternate: Bool
        let isMouseCaptured: Bool
        let isCursorKeyMode: Bool
        let isFocusEventMode: Bool
    }

    /// Gather terminal references for background save. MainActor, no I/O.
    /// Also cancels pending debounce tasks since the caller will perform a full save.
    /// Marks gathered surfaces as in-flight to prevent premature free by cleanup().
    func gatherTerminalRefs() -> [BackgroundTerminalRef] {
        guard Self.isEnabled else { return [] }

        var refs: [BackgroundTerminalRef] = []
        for (uuid, termRef) in registeredTerminals {
            guard let terminal = termRef.terminal,
                  let surface = terminal.surface else { continue }

            let isAlternate = ghostty_surface_is_alternate_active(surface)
            let isMouseCaptured = ghostty_surface_mouse_captured(surface)
            let isCursorKeyMode = ghostty_surface_cursor_key_mode(surface)
            let isFocusEventMode = ghostty_surface_focus_event_mode(surface)

            let isAtPrompt: Bool = {
                #if targetEnvironment(macCatalyst)
                return false
                #else
                guard let localSession = terminal.session as? LocalShellSession else { return false }
                let mode = localSession.stdinLock.withLock { localSession.inputMode }
                guard mode == .lineEditor else { return false }
                if case .localShell = localSession.sessionMode { return true }
                return false
                #endif
            }()

            refs.append(BackgroundTerminalRef(
                surfacePointer: surface,
                uuid: uuid,
                isAtPrompt: isAtPrompt,
                isAlternate: isAlternate,
                isMouseCaptured: isMouseCaptured,
                isCursorKeyMode: isCursorKeyMode,
                isFocusEventMode: isFocusEventMode
            ))
        }

        // Mark all gathered surfaces as in-flight before the background task starts.
        // This closes the race window between gathering and the Task.detached running.
        // Uses refcounting so overlapping save passes for the same surface are safe.
        for ref in refs {
            Self.retainSurface(ref.surfacePointer)
        }

        // Cancel pending debounce tasks since we're doing a full save
        for uuid in registeredTerminals.keys {
            outputDebounceTasks[uuid]?.cancel()
            outputDebounceTasks.removeValue(forKey: uuid)
        }

        return refs
    }

    /// Save scrollback for a single terminal in the background. Thread-safe.
    /// The C API call `ghostty_surface_dump_primary_screen` acquires its own mutex.
    /// Removes the surface from the in-flight set when done (even on failure).
    nonisolated static func saveScrollbackInBackground(
        ref: BackgroundTerminalRef,
        encryptionKey: SymmetricKey
    ) {
        defer { releaseSurface(ref.surfacePointer) }

        // Dump the primary screen (thread-safe C API call)
        var len: UInt = 0
        guard let ptr = ghostty_surface_dump_primary_screen(ref.surfacePointer, &len) else { return }
        var data = Data(bytes: ptr, count: Int(len))
        ghostty_surface_free_dump(ptr, len)

        // Truncate from front if too large (keep most recent content)
        let maxSize = 10 * 1024 * 1024
        if data.count > maxSize {
            let excess = data.count - maxSize
            if let newlineOffset = data[excess...].firstIndex(of: UInt8(ascii: "\n")) {
                data = Data(data[(newlineOffset + 1)...])
            } else {
                data = Data(data[excess...])
            }
        }

        // Change detection: skip encrypt+write if content and mode flags are
        // unchanged since the last *successful* save. The hash is only
        // recorded after the write completes below, so a failed encrypt or
        // I/O error will be retried on the next save tick. Shared with the
        // main-actor path via `lastSavedHashes`.
        var hasher = Hasher()
        hasher.combine(data)
        hasher.combine(ref.isAlternate)
        hasher.combine(ref.isAtPrompt)
        hasher.combine(ref.isMouseCaptured)
        hasher.combine(ref.isCursorKeyMode)
        hasher.combine(ref.isFocusEventMode)
        let contentHash = hasher.finalize()
        let alreadySaved = lastSavedHashes.withLock { $0[ref.uuid] == contentHash }
        guard !alreadySaved else { return }

        // Encrypt
        let encryptedData: Data
        let encryptedAltFlag: Data?
        let encryptedAtPromptFlag: Data?
        let encryptedMouseFlag: Data?
        let encryptedCursorKeyFlag: Data?
        let encryptedFocusEventFlag: Data?
        do {
            encryptedData = try ScrollbackEncryptionManager.encrypt(data, using: encryptionKey)
            encryptedAltFlag = ref.isAlternate
                ? try ScrollbackEncryptionManager.encrypt(Data([1]), using: encryptionKey)
                : nil
            encryptedAtPromptFlag = ref.isAtPrompt
                ? try ScrollbackEncryptionManager.encrypt(Data([1]), using: encryptionKey)
                : nil
            encryptedMouseFlag = ref.isMouseCaptured
                ? try ScrollbackEncryptionManager.encrypt(Data([1]), using: encryptionKey)
                : nil
            encryptedCursorKeyFlag = ref.isCursorKeyMode
                ? try ScrollbackEncryptionManager.encrypt(Data([1]), using: encryptionKey)
                : nil
            encryptedFocusEventFlag = ref.isFocusEventMode
                ? try ScrollbackEncryptionManager.encrypt(Data([1]), using: encryptionKey)
                : nil
        } catch {
            logger.warning("Background encryption failed for \(ref.uuid.uuidString.prefix(8)): \(error.localizedDescription)")
            return
        }

        // Write to disk
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let scrollbackDir = docs.appendingPathComponent(".ghostty/scrollback", isDirectory: true)
        let fileURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).ansi.enc")
        let legacyURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).ansi")
        let altFlagURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).altscreen.enc")
        let promptFlagURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).atprompt.enc")
        let mouseFlagURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).mousecapture.enc")
        let cursorKeyFlagURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).cursorkeys.enc")
        let focusEventFlagURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).focusevent.enc")

        do {
            try FileManager.default.createDirectory(at: scrollbackDir, withIntermediateDirectories: true)
            try encryptedData.write(to: fileURL, options: .atomic)
            try? FileManager.default.removeItem(at: legacyURL)

            if let encryptedAltFlag {
                try encryptedAltFlag.write(to: altFlagURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: altFlagURL)
            }
            if let encryptedAtPromptFlag {
                try encryptedAtPromptFlag.write(to: promptFlagURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: promptFlagURL)
            }
            if let encryptedMouseFlag {
                try encryptedMouseFlag.write(to: mouseFlagURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: mouseFlagURL)
            }
            if let encryptedCursorKeyFlag {
                try encryptedCursorKeyFlag.write(to: cursorKeyFlagURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: cursorKeyFlagURL)
            }
            if let encryptedFocusEventFlag {
                try encryptedFocusEventFlag.write(to: focusEventFlagURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: focusEventFlagURL)
            }

            // Record the hash only after the write succeeds — a failed save
            // above must not short-circuit the next save tick.
            lastSavedHashes.withLock { $0[ref.uuid] = contentHash }
        } catch {
            logger.warning("Background save failed for \(ref.uuid.uuidString.prefix(8)): \(error.localizedDescription)")
        }
    }

    // MARK: - Periodic Timer

    private func startPeriodicTimerIfNeeded() {
        guard periodicTimer == nil else { return }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: periodicInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.periodicSave()
            }
        }
    }

    private func stopPeriodicTimer() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    private func handleDidEnterBackground() {
        outputDebounceTasks.values.forEach { $0.cancel() }
        outputDebounceTasks.removeAll()
        stopPeriodicTimer()
    }

    /// Periodic save intentionally uses the background-save API so the
    /// main actor never does a dump+hash+encrypt during a scene update.
    /// The debounce path still uses `saveScrollback(for:)`: its payloads
    /// are smaller (one terminal at a time) and it does not race with
    /// foreground transitions.
    private func periodicSave() {
        guard Self.isEnabled else { return }
        let refs = gatherTerminalRefs()
        guard !refs.isEmpty else { return }
        let key: SymmetricKey
        do {
            key = try ScrollbackEncryptionManager.shared.getKey()
        } catch {
            let msg = error.localizedDescription
            Self.logger.warning("periodicSave: key fetch failed, skipping: \(msg)")
            Self.clearInFlightSurfaces(refs)
            return
        }
        Task.detached(priority: .utility) {
            for ref in refs {
                Self.saveScrollbackInBackground(ref: ref, encryptionKey: key)
            }
        }
    }

    // MARK: - Save

    private func saveScrollback(for uuid: UUID) {
        guard let ref = registeredTerminals[uuid],
              let terminal = ref.terminal,
              let surface = terminal.surface else { return }

        // Check terminal mode state for persistence
        let isAlternate = ghostty_surface_is_alternate_active(surface)
        let isMouseCaptured = ghostty_surface_mouse_captured(surface)
        let isCursorKeyMode = ghostty_surface_cursor_key_mode(surface)
        let isFocusEventMode = ghostty_surface_focus_event_mode(surface)

        // Check if the local shell is at a prompt (for seamless restore)
        let isAtPrompt: Bool = {
            #if targetEnvironment(macCatalyst)
            return false
            #else
            guard let localSession = terminal.session as? LocalShellSession else { return false }
            let mode = localSession.stdinLock.withLock { localSession.inputMode }
            guard mode == .lineEditor else { return false }
            if case .localShell = localSession.sessionMode { return true }
            return false
            #endif
        }()

        // Dump the primary screen with ANSI styling
        var len: UInt = 0
        guard let ptr = ghostty_surface_dump_primary_screen(surface, &len) else { return }
        var data = Data(bytes: ptr, count: Int(len))
        ghostty_surface_free_dump(ptr, len)

        // Truncate from front if too large (keep most recent content).
        // Must happen *before* hashing so both save paths (main-actor here
        // and the background periodic path) hash the same bytes and share
        // `lastSavedHashes` coherently. Hashing the untruncated dump would
        // cause the two paths to record different hashes for the same
        // on-disk file when the dump exceeds maxFileSize, preventing the
        // dedupe from ever stabilizing.
        if data.count > maxFileSize {
            let excess = data.count - maxFileSize
            // Find the next newline after the cut point to avoid splitting a line
            if let newlineOffset = data[excess...].firstIndex(of: UInt8(ascii: "\n")) {
                data = Data(data[(newlineOffset + 1)...])
            } else {
                data = Data(data[excess...])
            }
        }

        // Change detection: skip save if content and mode flags are unchanged
        // since the last *successful* write. The hash is recorded only after
        // the Task.detached write below completes, so encrypt/I-O failures
        // retry on the next tick. We hash the dumped content rather than
        // checking row counts, because operations like CTRL-L change screen
        // layout without changing total rows.
        var hasher = Hasher()
        hasher.combine(data)
        hasher.combine(isAlternate)
        hasher.combine(isAtPrompt)
        hasher.combine(isMouseCaptured)
        hasher.combine(isCursorKeyMode)
        hasher.combine(isFocusEventMode)
        let contentHash = hasher.finalize()
        let alreadySaved = Self.lastSavedHashes.withLock { $0[uuid] == contentHash }
        guard !alreadySaved else { return }

        // Encrypt on MainActor before handing off to background write
        let encryptedData: Data
        let encryptedAltFlag: Data?
        let encryptedAtPromptFlag: Data?
        let encryptedMouseFlag: Data?
        let encryptedCursorKeyFlag: Data?
        let encryptedFocusEventFlag: Data?
        do {
            encryptedData = try ScrollbackEncryptionManager.shared.encrypt(data)
            encryptedAltFlag = isAlternate
                ? try ScrollbackEncryptionManager.shared.encrypt(Data([1]))
                : nil
            encryptedAtPromptFlag = isAtPrompt
                ? try ScrollbackEncryptionManager.shared.encrypt(Data([1]))
                : nil
            encryptedMouseFlag = isMouseCaptured
                ? try ScrollbackEncryptionManager.shared.encrypt(Data([1]))
                : nil
            encryptedCursorKeyFlag = isCursorKeyMode
                ? try ScrollbackEncryptionManager.shared.encrypt(Data([1]))
                : nil
            encryptedFocusEventFlag = isFocusEventMode
                ? try ScrollbackEncryptionManager.shared.encrypt(Data([1]))
                : nil
        } catch {
            Self.logger.warning("Encryption failed for \(uuid.uuidString.prefix(8)), skipping save: \(error.localizedDescription)")
            return
        }

        let fileURL = scrollbackFileURL(for: uuid)
        let legacyURL = legacyScrollbackFileURL(for: uuid)
        let altFlagURL = alternateScreenFlagURL(for: uuid)
        let atPromptFlagURL = atPromptFlagURL(for: uuid)
        let mouseFlagURL = mouseCaptureURL(for: uuid)
        let cursorKeyFlagURL = cursorKeyModeURL(for: uuid)
        let focusEventFlagURL = focusEventModeURL(for: uuid)

        // Write atomically on a utility queue
        let directory = scrollbackDirectory
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encryptedData.write(to: fileURL, options: .atomic)
                // Remove legacy plaintext file if it exists
                try? FileManager.default.removeItem(at: legacyURL)
                // Save or remove encrypted alternate screen flag
                if let encryptedAltFlag {
                    try encryptedAltFlag.write(to: altFlagURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: altFlagURL)
                }
                // Save or remove encrypted at-prompt flag
                if let encryptedAtPromptFlag {
                    try encryptedAtPromptFlag.write(to: atPromptFlagURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: atPromptFlagURL)
                }
                // Save or remove encrypted mouse capture flag
                if let encryptedMouseFlag {
                    try encryptedMouseFlag.write(to: mouseFlagURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: mouseFlagURL)
                }
                // Save or remove encrypted cursor key mode flag
                if let encryptedCursorKeyFlag {
                    try encryptedCursorKeyFlag.write(to: cursorKeyFlagURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: cursorKeyFlagURL)
                }
                // Save or remove encrypted focus event mode flag
                if let encryptedFocusEventFlag {
                    try encryptedFocusEventFlag.write(to: focusEventFlagURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: focusEventFlagURL)
                }

                // Record the hash only after the write succeeds — failures
                // above must not short-circuit the next save tick.
                Self.lastSavedHashes.withLock { $0[uuid] = contentHash }
            } catch {
                ScrollbackPersistenceManager.logger.warning("Failed to save scrollback for \(uuid.uuidString.prefix(8)): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Restore

    /// Restore scrollback for a terminal by writing saved ANSI data through the bufferedWriter.
    ///
    /// - Parameter trailer: Optional bytes appended to the scrollback byte stream
    ///   **before** `gate.finish()` releases buffered live output. Used by the
    ///   trzsz resume path to atomically inject DECSET sequences (alt screen,
    ///   mouse capture, cursor key mode, bracketed paste) so the resumed remote
    ///   TUI's redraw is processed by ghostty with the correct modes already
    ///   set, without any live data racing ahead of the trailer.
    /// - Parameter keepGateOpen: When true, do **not** finish the
    ///   scrollback-restore gate or schedule the post-drain replay-render here.
    ///   The caller is taking responsibility for closing the gate later — used
    ///   by shellLaunchedTrzsz restorations where layout fires before the
    ///   embedded trzsz session reaches `.running`. The saved scrollback is
    ///   written now (so the user sees their pre-eviction screen immediately),
    ///   but the gate keeps buffering subsequent embedded-spinner frames /
    ///   server attach response / resize-jiggle redraw until
    ///   `applyResumeTrailer` writes the trailer and explicitly finishes the
    ///   gate, preserving the desired
    ///       saved-scrollback → trailer → buffered-server-output → live
    ///   ordering.
    func restoreScrollback(for terminal: Ghostty.TerminalView, trailer: Data? = nil, keepGateOpen: Bool = false) {
        // Saved scrollback is replayed verbatim, BELs and all. Stripping
        // 0x07 is not an option (it also terminates OSC sequences), so mute
        // instead. This deadline covers the direct writes below; the gated
        // output released with the gate is held until it has drained, since
        // `keepGateOpen` can wait on `.running` for an unbounded time.
        TerminalBellSuppressor.suppress(
            terminal.uuid, for: TerminalBellSuppressor.forcedRedraw)
        // Deliberately NOT a rebuild window for agent detection. A restore
        // lands on a brand-new pane, so the notification router's discovery
        // guard already treats whatever it finds as pre-existing, and the
        // monitor's birth settle covers the replayed OSC 133. Arming here
        // instead froze every restored tab at launch.

        defer {
            if let trailer, !trailer.isEmpty {
                terminal.outputPipeline.writeDirect(trailer)
            }
            if !keepGateOpen {
                terminal.outputPipeline.finishScrollbackRestoreGate()
                TerminalBellSuppressor.suppress(
                    terminal.uuid, untilDrained: terminal.outputPipeline)
                terminal.didQueueScrollbackRestoreReplay()
            }
        }

        let uuid = terminal.uuid
        let encryptedURL = scrollbackFileURL(for: uuid)
        let legacyURL = legacyScrollbackFileURL(for: uuid)

        // Try encrypted file first
        if FileManager.default.fileExists(atPath: encryptedURL.path) {
            do {
                let combined = try Data(contentsOf: encryptedURL)
                guard !combined.isEmpty else { return }

                let data = try ScrollbackEncryptionManager.shared.decrypt(combined)
                let byteCount = data.count
                Self.logger.info("Restoring \(byteCount) bytes of encrypted scrollback for \(uuid.uuidString.prefix(8))")
                terminal.outputPipeline.writeDirect(data)
                return
            } catch {
                Self.logger.warning("Decryption failed for \(uuid.uuidString.prefix(8)), deleting corrupted file: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: encryptedURL)
                return
            }
        }

        // Fall back to legacy plaintext file (migration path)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            do {
                let data = try Data(contentsOf: legacyURL)
                guard !data.isEmpty else { return }

                let byteCount = data.count
                Self.logger.info("Restoring \(byteCount) bytes of legacy scrollback for \(uuid.uuidString.prefix(8))")
                terminal.outputPipeline.writeDirect(data)

                // Delete legacy file; next save cycle will write encrypted
                try? FileManager.default.removeItem(at: legacyURL)
                return
            } catch {
                Self.logger.warning("Failed to restore legacy scrollback for \(uuid.uuidString.prefix(8)): \(error.localizedDescription)")
            }
        }

        Self.logger.debug("No scrollback file for \(uuid.uuidString.prefix(8))")
    }

    // MARK: - Alternate Screen Query

    /// Check if the alternate screen was active when scrollback was last saved.
    func wasAlternateScreenActive(for uuid: UUID) -> Bool {
        let url = alternateScreenFlagURL(for: uuid)
        guard let combined = try? Data(contentsOf: url), !combined.isEmpty else {
            return false
        }
        guard let data = try? ScrollbackEncryptionManager.shared.decrypt(combined) else {
            // Corrupted — clean it up
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return data.first == 1
    }

    // MARK: - At-Prompt Query

    /// Check if the local shell was at a prompt when scrollback was last saved.
    /// Used to decide whether to suppress the initial prompt on session restore.
    func wasAtPrompt(for uuid: UUID) -> Bool {
        let url = atPromptFlagURL(for: uuid)
        guard let combined = try? Data(contentsOf: url), !combined.isEmpty else {
            return false
        }
        guard let data = try? ScrollbackEncryptionManager.shared.decrypt(combined) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return data.first == 1
    }

    // MARK: - Mouse Capture Query

    /// Check if mouse capture was active when scrollback was last saved.
    func wasMouseCaptureActive(for uuid: UUID) -> Bool {
        let url = mouseCaptureURL(for: uuid)
        guard let combined = try? Data(contentsOf: url), !combined.isEmpty else {
            return false
        }
        guard let data = try? ScrollbackEncryptionManager.shared.decrypt(combined) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return data.first == 1
    }

    // MARK: - Cursor Key Mode Query

    /// Check if application cursor key mode was active when scrollback was last saved.
    func wasCursorKeyModeActive(for uuid: UUID) -> Bool {
        let url = cursorKeyModeURL(for: uuid)
        guard let combined = try? Data(contentsOf: url), !combined.isEmpty else {
            return false
        }
        guard let data = try? ScrollbackEncryptionManager.shared.decrypt(combined) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return data.first == 1
    }

    // MARK: - Focus Event Mode Query

    /// Check if focus event reporting (DEC mode 1004) was active when scrollback was last saved.
    func wasFocusEventModeActive(for uuid: UUID) -> Bool {
        let url = focusEventModeURL(for: uuid)
        guard let combined = try? Data(contentsOf: url), !combined.isEmpty else {
            return false
        }
        guard let data = try? ScrollbackEncryptionManager.shared.decrypt(combined) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return data.first == 1
    }

    // MARK: - Cleanup

    /// Remove scrollback files for terminals not in the active set, if older than threshold.
    func cleanupOrphanedFiles(activeTerminalIds: Set<UUID>) {
        let dir = scrollbackDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        var cleanedCount = 0
        for file in files {
            // Extract UUID from filename, handling all flag file extensions
            let filename = file.lastPathComponent
            let uuidString: String
            if filename.hasSuffix(".ansi.enc") {
                uuidString = String(filename.dropLast(".ansi.enc".count))
            } else if filename.hasSuffix(".ansi") {
                uuidString = String(filename.dropLast(".ansi".count))
            } else if filename.hasSuffix(".altscreen.enc") {
                uuidString = String(filename.dropLast(".altscreen.enc".count))
            } else if filename.hasSuffix(".atprompt.enc") {
                uuidString = String(filename.dropLast(".atprompt.enc".count))
            } else if filename.hasSuffix(".mousecapture.enc") {
                uuidString = String(filename.dropLast(".mousecapture.enc".count))
            } else if filename.hasSuffix(".cursorkeys.enc") {
                uuidString = String(filename.dropLast(".cursorkeys.enc".count))
            } else if filename.hasSuffix(".focusevent.enc") {
                uuidString = String(filename.dropLast(".focusevent.enc".count))
            } else if filename.hasSuffix(".altscreen") {
                // Legacy unencrypted flag
                uuidString = String(filename.dropLast(".altscreen".count))
            } else {
                continue
            }

            guard let uuid = UUID(uuidString: uuidString) else { continue }
            guard !activeTerminalIds.contains(uuid) else { continue }

            // Check age
            if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = attrs.contentModificationDate,
               Date().timeIntervalSince(modDate) > orphanAgeThreshold {
                try? FileManager.default.removeItem(at: file)
                cleanedCount += 1
            }
        }

        if cleanedCount > 0 {
            Self.logger.info("Cleaned up \(cleanedCount) orphaned scrollback files")
        }
    }

    /// Remove all scrollback files (when feature is disabled).
    func removeAllScrollbackFiles() {
        try? FileManager.default.removeItem(at: scrollbackDirectory)
        Self.lastSavedHashes.withLock { $0.removeAll() }
        Self.logger.info("Removed all scrollback files")
    }
}
