//
//  ScrollbackPersistenceManager.swift
//  rootshell
//
//  Manages periodic persistence of terminal scrollback buffers to disk,
//  and restoration on session reconnect. Scrollback is dumped as ANSI-styled
//  text from Ghostty's primary screen buffer, preserving colors and styles.
//  Active full-screen UIs also retain their styled alternate viewport.
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
    private nonisolated static let maxFileSize = 10 * 1024 * 1024

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

    /// Saves gather on the main actor and capture and write off it, so they
    /// pass through here to stay in capture order.
    nonisolated private static let saveOrder = TerminalSaveOrder()

    /// What the last save that reached the disk captured. `hash` covers the
    /// dumped bytes and mode flags; `inputs` lets an idle terminal skip the
    /// capture altogether.
    private nonisolated struct LandedSave {
        let hash: Int
        let inputs: SaveInputs
    }

    nonisolated private static let lastSaves = OSAllocatedUnfairLock(
        initialState: [UUID: LandedSave]()
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

    private func terminalStateURL(for uuid: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent("\(uuid.uuidString).terminalstate.enc")
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
        // Saves still in flight for an earlier terminal under this UUID
        // hold its surface and must not land over this one's.
        _ = Self.saveOrder.register(uuid)
        Self.logger.debug("Registered terminal \(uuid.uuidString.prefix(8)) for scrollback persistence")
        startPeriodicTimerIfNeeded()
    }

    func unregisterTerminal(uuid: UUID) {
        // The registration in `saveOrder` stays: a save gathered before a
        // scene teardown is still in flight and is the terminal's last.
        registeredTerminals.removeValue(forKey: uuid)
        Self.lastSaves.withLock { $0[uuid] = nil }
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
            guard !Task.isCancelled, let self else { return }
            self.saveInBackground(self.gatherRefs(for: [uuid], skippingUnchanged: true))
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

    nonisolated private static func isSurfaceInFlight(_ surface: ghostty_surface_t) -> Bool {
        nonisolated(unsafe) let surface = surface
        return inFlightSurfaces.withLock { $0[surface] != nil }
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
        let inputs: SaveInputs
        let contents: TerminalPersistedContents
        let registration: UInt64
    }

    /// Everything a capture depends on that is cheap to read. Parsed bytes
    /// only grow, so equal inputs on the same surface mean the screen is the
    /// one the last landed save captured. `totalRows` catches a reset or
    /// clear that drops history without parsing output, from any path.
    nonisolated struct SaveInputs: Equatable {
        let surface: UInt
        let parsedBytes: UInt64
        let columns: UInt16
        let rows: UInt16
        let totalRows: UInt
        let snapshotParseTarget: UInt64?
        let isAtPrompt: Bool
        // Read again right after the capture: see `resamplingModes`.
        var isAlternate: Bool
        var isMouseCaptured: Bool
        var isCursorKeyMode: Bool
        var isFocusEventMode: Bool

        /// The modes as they are just after a capture. A capture Ghostty
        /// numbers later must not write modes read before an earlier one.
        func resamplingModes(_ surface: ghostty_surface_t) -> SaveInputs {
            var inputs = self
            inputs.isAlternate = ghostty_surface_is_alternate_active(surface)
            inputs.isMouseCaptured = ghostty_surface_mouse_captured(surface)
            inputs.isCursorKeyMode = ghostty_surface_cursor_key_mode(surface)
            inputs.isFocusEventMode = ghostty_surface_focus_event_mode(surface)
            return inputs
        }
    }

    /// Gather terminal references for background save. MainActor, no I/O.
    /// The app-background save leaves `skippingUnchanged` off: a reset or a
    /// resize can change the screen without changing the cached inputs.
    /// Also cancels pending debounce tasks since the caller will perform a full save.
    /// Marks gathered surfaces as in-flight to prevent premature free by cleanup().
    func gatherTerminalRefs(skippingUnchanged: Bool = false) -> [BackgroundTerminalRef] {
        guard Self.isEnabled else { return [] }
        outputDebounceTasks.values.forEach { $0.cancel() }
        outputDebounceTasks.removeAll()
        return gatherRefs(for: Array(registeredTerminals.keys), skippingUnchanged: skippingUnchanged)
    }

    /// Terminals whose screen may differ from their saved files, retained
    /// for the background save.
    private func gatherRefs(for uuids: [UUID], skippingUnchanged: Bool) -> [BackgroundTerminalRef] {
        var refs: [BackgroundTerminalRef] = []
        for uuid in uuids {
            guard let terminal = registeredTerminals[uuid]?.terminal,
                  let contents = terminal.persistableTerminalContents,
                  let registration = Self.saveOrder.registration(of: uuid),
                  let surface = terminal.surface else { continue }

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

            let size = ghostty_surface_size(surface)
            let inputs = SaveInputs(
                surface: UInt(bitPattern: surface),
                parsedBytes: ghostty_surface_parsed_bytes(surface),
                columns: size.columns,
                rows: size.rows,
                totalRows: ghostty_surface_total_rows(surface),
                snapshotParseTarget: contents.snapshotParseTarget,
                isAtPrompt: isAtPrompt,
                isAlternate: ghostty_surface_is_alternate_active(surface),
                isMouseCaptured: ghostty_surface_mouse_captured(surface),
                isCursorKeyMode: ghostty_surface_cursor_key_mode(surface),
                isFocusEventMode: ghostty_surface_focus_event_mode(surface)
            )
            // Only while no earlier save is gathered, accepted or failed but
            // unwritten: the disk then holds the landed save's screen. The
            // in-flight check comes first: only the main actor starts saves,
            // so none can finish and update the cache after it.
            let unchanged = skippingUnchanged
                && !Self.isSurfaceInFlight(surface)
                && Self.saveOrder.isSettled(uuid)
                && Self.lastSaves.withLock { $0[uuid]?.inputs == inputs }
            guard !unchanged else { continue }

            refs.append(BackgroundTerminalRef(
                surfacePointer: surface,
                uuid: uuid,
                inputs: inputs,
                contents: contents,
                registration: registration
            ))
        }

        // Mark all gathered surfaces as in-flight before the background task starts.
        // This closes the race window between gathering and the Task.detached running.
        // Uses refcounting so overlapping save passes for the same surface are safe.
        for ref in refs {
            Self.retainSurface(ref.surfacePointer)
        }
        return refs
    }

    /// Captures, encrypts and writes `refs` off the main actor.
    private func saveInBackground(_ refs: [BackgroundTerminalRef]) {
        guard !refs.isEmpty else { return }
        let key: SymmetricKey
        do {
            key = try ScrollbackEncryptionManager.shared.getKey()
        } catch {
            Self.logger.warning("Key fetch failed, skipping scrollback save: \(error.localizedDescription)")
            Self.clearInFlightSurfaces(refs)
            return
        }
        Task.detached(priority: .utility) {
            for ref in refs {
                Self.saveScrollbackInBackground(ref: ref, encryptionKey: key)
            }
        }
    }

    /// Save scrollback for a single terminal in the background. Thread-safe.
    /// The C API call `ghostty_surface_dump_primary_screen` acquires its own mutex.
    /// Removes the surface from the in-flight set when done (even on failure).
    nonisolated static func saveScrollbackInBackground(
        ref: BackgroundTerminalRef,
        encryptionKey: SymmetricKey
    ) {
        defer { releaseSurface(ref.surfacePointer) }

        // Dump the screen (thread-safe C API call), newest content kept.
        guard let contents = captureContents(surface: ref.surfacePointer, ref.contents) else { return }
        let inputs = ref.inputs.resamplingModes(ref.surfacePointer)
        let standing = saveOrder.accept(ref.uuid, capture: contents.capture, registration: ref.registration)
        guard standing != .superseded else { return }
        let data = contents.scrollback
        let terminalState = contents.terminalState
        let alternateScreen = inputs.isAlternate ? dumpAlternateScreen(ref.surfacePointer) : nil

        // Change detection: skip encrypt+write if content and mode flags are
        // unchanged since the last *successful* save. The hash is only
        // recorded after the write completes below, so a failed encrypt or
        // I/O error will be retried on the next save tick.
        var hasher = Hasher()
        hasher.combine(data)
        hasher.combine(alternateScreen)
        hasher.combine(terminalState)
        hasher.combine(inputs.isAlternate)
        hasher.combine(inputs.isAtPrompt)
        hasher.combine(inputs.isMouseCaptured)
        hasher.combine(inputs.isCursorKeyMode)
        hasher.combine(inputs.isFocusEventMode)
        let contentHash = hasher.finalize()
        // An unchanged screen still took its place in the order above, so an
        // older save that has not written yet can no longer land. If one is
        // pending, the disk may not hold this screen: write it anyway.
        let alreadySaved = lastSaves.withLock { $0[ref.uuid]?.hash == contentHash }
        if alreadySaved, standing == .current {
            // Nothing to write, but recorded under the write lock: a newer
            // capture's write must not land between the check and the record.
            guard saveOrder.beginWrite(ref.uuid, capture: contents.capture, registration: ref.registration) else { return }
            lastSaves.withLock { $0[ref.uuid] = LandedSave(hash: contentHash, inputs: inputs) }
            saveOrder.endWrite(ref.uuid, capture: contents.capture, succeeded: true)
            return
        }

        // Encrypt
        let encryptedData: Data
        let encryptedTerminalState: Data?
        let encryptedAltFlag: Data?
        let encryptedAtPromptFlag: Data?
        let encryptedMouseFlag: Data?
        let encryptedCursorKeyFlag: Data?
        let encryptedFocusEventFlag: Data?
        do {
            encryptedData = try ScrollbackEncryptionManager.encrypt(data, using: encryptionKey)
            encryptedTerminalState = try terminalState.map {
                try ScrollbackEncryptionManager.encrypt($0, using: encryptionKey)
            }
            encryptedAltFlag = inputs.isAlternate
                ? try ScrollbackEncryptionManager.encrypt(
                    TerminalAlternateScreenSnapshot.encode(alternateScreen), using: encryptionKey)
                : nil
            encryptedAtPromptFlag = inputs.isAtPrompt
                ? try ScrollbackEncryptionManager.encrypt(Data([1]), using: encryptionKey)
                : nil
            encryptedMouseFlag = inputs.isMouseCaptured
                ? try ScrollbackEncryptionManager.encrypt(Data([1]), using: encryptionKey)
                : nil
            encryptedCursorKeyFlag = inputs.isCursorKeyMode
                ? try ScrollbackEncryptionManager.encrypt(Data([1]), using: encryptionKey)
                : nil
            encryptedFocusEventFlag = inputs.isFocusEventMode
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
        let terminalStateURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).terminalstate.enc")
        let promptFlagURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).atprompt.enc")
        let mouseFlagURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).mousecapture.enc")
        let cursorKeyFlagURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).cursorkeys.enc")
        let focusEventFlagURL = scrollbackDir.appendingPathComponent("\(ref.uuid.uuidString).focusevent.enc")

        // A save that read the surface later has taken this one's place, or
        // the terminal has been replaced since.
        guard saveOrder.beginWrite(ref.uuid, capture: contents.capture, registration: ref.registration) else { return }
        var written = false
        defer { saveOrder.endWrite(ref.uuid, capture: contents.capture, succeeded: written) }

        do {
            try FileManager.default.createDirectory(at: scrollbackDir, withIntermediateDirectories: true)
            try encryptedData.write(to: fileURL, options: .atomic)
            if let encryptedTerminalState {
                try encryptedTerminalState.write(to: terminalStateURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: terminalStateURL)
            }
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
            lastSaves.withLock { $0[ref.uuid] = LandedSave(hash: contentHash, inputs: inputs) }
            written = true
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

    private func periodicSave() {
        saveInBackground(gatherTerminalRefs(skippingUnchanged: true))
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
                terminal.outputPipeline.writeRestoreTrailer(trailer)
            }
            if !keepGateOpen {
                terminal.outputPipeline.finishScrollbackRestoreGate()
                TerminalBellSuppressor.suppress(
                    terminal.uuid, untilDrained: terminal.outputPipeline)
                terminal.didQueueScrollbackRestoreReplay()
            }
        }

        // A complete replay resets the terminal and carries the scrollback
        // itself. The saved copy queued ahead of it would be parsed only to
        // be discarded, and the two together can overflow the writer.
        if let trailer, TerminalRestorationSnapshot.isReplay(trailer) { return }

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

    /// What one save writes: the primary screen dump, and for a tssh terminal
    /// the restoration snapshot built around that same dump. Ghostty reads
    /// both, how far it had parsed and the number that orders the capture
    /// among the others of its surface under one lock, so the files always
    /// describe one moment and a later moment always has the higher number.
    /// Nil skips the save and keeps the previous files.
    private nonisolated static func captureContents(
        surface: ghostty_surface_t,
        _ contents: TerminalPersistedContents
    ) -> (scrollback: Data, terminalState: Data?, capture: UInt64)? {
        // A terminal that saves scrollback alone gets a capture of the
        // primary screen alone: its alternate screen and state would be
        // serialized under the renderer lock only to be discarded.
        var snapshot = ghostty_surface_restoration_s()
        let captured = contents.snapshotParseTarget != nil
            ? ghostty_surface_restoration_snapshot(surface, &snapshot)
            : ghostty_surface_scrollback_capture(surface, &snapshot)
        guard captured, let ptr = snapshot.ptr else { return nil }
        defer { ghostty_surface_free_dump(ptr, snapshot.len) }
        let primary = Int(snapshot.primary_offset)..<Int(snapshot.primary_offset + snapshot.primary_len)
        guard primary.upperBound <= Int(snapshot.len) else { return nil }

        let scrollback: Data
        var terminalState: Data?
        if let parseTarget = contents.snapshotParseTarget {
            // Connection progress is on screen until Ghostty has parsed the
            // remote program's first write.
            guard snapshot.parsed_bytes >= parseTarget else { return nil }
            guard let parts = TerminalRestorationSnapshot.parts(
                of: Data(bytes: ptr, count: Int(snapshot.len)), primary: primary, maxScrollbackBytes: maxFileSize),
                  let replay = parts.replay else { return nil }
            scrollback = parts.scrollback
            terminalState = replay
        } else {
            let dump = Data(bytes: UnsafeRawPointer(ptr) + primary.lowerBound, count: primary.count)
            scrollback = TerminalRestorationSnapshot.trimmed(dump, maxBytes: maxFileSize).data
        }
        // Another session took over the terminal after this save was
        // gathered, or its surface was replaced: what to write was decided
        // for the previous session, and what was read is the previous
        // surface. Checked after reading the surface, so a change in
        // between is caught.
        guard contents.session.isCurrent else { return nil }
        return (scrollback, terminalState, snapshot.capture)
    }

    /// A complete snapshot must replace the heuristic mode trailer, not precede
    /// it: the guessed modes/cursor reset would corrupt the restored protocol.
    func terminalStateRestorationBytes(for uuid: UUID) -> Data? {
        guard let encrypted = try? Data(contentsOf: terminalStateURL(for: uuid)),
              let bytes = try? ScrollbackEncryptionManager.shared.decrypt(encrypted),
              let replay = TerminalRestorationSnapshot.replay(fromSaved: bytes) else { return nil }
        ResumeDebugLogger.shared.log("[Restore] RootShell terminal snapshot \(uuid.uuidString.prefix(8)): \(replay.count) bytes")
        return replay
    }

    /// Both save paths must include the alternate viewport in change detection;
    /// full-screen apps can update continuously while the primary screen is idle.
    private nonisolated static func dumpAlternateScreen(_ surface: ghostty_surface_t) -> Data? {
        var len: UInt = 0
        guard let ptr = ghostty_surface_dump_alternate_screen(surface, &len) else { return nil }
        defer { ghostty_surface_free_dump(ptr, len) }
        return Data(bytes: ptr, count: Int(len))
    }

    /// Mode switch and saved viewport are replayed together inside the output
    /// restore gate, ahead of any incremental output from the surviving TUI.
    func alternateScreenRestorationBytes(for uuid: UUID) -> Data? {
        let url = alternateScreenFlagURL(for: uuid)
        guard let encrypted = try? Data(contentsOf: url),
              let saved = try? ScrollbackEncryptionManager.shared.decrypt(encrypted) else { return nil }
        return TerminalAlternateScreenSnapshot.restorationBytes(from: saved)
    }

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
            } else if filename.hasSuffix(".terminalstate.enc") {
                uuidString = String(filename.dropLast(".terminalstate.enc".count))
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
        Self.lastSaves.withLock { $0.removeAll() }
        Self.logger.info("Removed all scrollback files")
    }
}
