#if canImport(FluidAudio) && !CHINA_BUILD
//
//  DictationController.swift
//  rootshell
//
//  The single listening session shared by the keyboard pane and the HUD.
//  Only one microphone owner exists at a time, so this is app-wide.
//

import AVFoundation
import Foundation
import Observation
import UIKit
import os

@MainActor
@Observable
final class DictationController {
    static let shared = DictationController()
    /// Owner token for sessions started from the floating HUD.
    static let hudOwner = NSObject()

    enum Phase: Equatable {
        case idle, preparing, listening, finishing
        case failed(String)
    }

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "Dictation")

    private(set) var phase: Phase = .idle
    /// Preview phrases, formatted and waiting for Insert.
    private(set) var phrases: [String] = []
    /// The phrase still being spoken.
    private(set) var partial = ""
    private(set) var level: Float = 0
    private(set) var style: DictationFormatter.Style = .command
    private(set) var agentName: String?
    private(set) var commitMode: DictationCommitMode = SettingsStore.shared.get(Settings.Dictation.commitMode)
    /// Phrases inserted directly since the last Return, for Undo.
    private(set) var insertedCount = 0

    var isActive: Bool { phase == .preparing || phase == .listening || phase == .finishing }
    var isListening: Bool { phase == .listening }
    var previewText: String { phrases.reduce("") { DictationFormatter.joining($0, $1, style: style) } }
    var canUndo: Bool { commitMode == .preview ? !phrases.isEmpty : insertedCount > 0 }

    var model: DictationModel { SettingsStore.shared.get(Settings.Dictation.model) }
    var modelReady: Bool { DictationModelStore.shared.isReady(model) }

    @ObservationIgnored private weak var target: DictationTarget?
    /// The surface that started listening, so hiding another one never stops it.
    @ObservationIgnored private weak var owner: AnyObject?
    /// Target input generation after our last delivery; any other input invalidates Undo.
    @ObservationIgnored private var deliveredGeneration: UInt64?
    @ObservationIgnored private var formatter = DictationFormatter(.init(style: .command))
    @ObservationIgnored private var recognizer: DictationRecognizer?
    @ObservationIgnored private let capture = DictationAudioCapture()
    @ObservationIgnored private let audioSession = AudioSessionManager()
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var insertedChunks: [String] = []
    /// Hands-Free: the current utterance typed text that still needs its Return.
    @ObservationIgnored private var utteranceTyped = false
    /// The session holding a use of the engine's models, released exactly once.
    @ObservationIgnored private var leasedSession: UUID?
    @ObservationIgnored private var pendingInsert: Bool?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        capture.onLevel = { [weak self] in self?.level = $0 }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .microphoneCaptureWillBegin, object: nil, queue: .main) { [weak self] note in
            let other = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, other != ObjectIdentifier(self) else { return }
                self.cancel()
            }
        })
        // Leaving the foreground or losing the audio route ends listening cleanly.
        for name in [UIApplication.didEnterBackgroundNotification, AVAudioSession.interruptionNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.isActive == false else { return }
                Task { await DictationEngine.shared.unload() }
            }
        })
    }

    // MARK: - Session

    func toggle(target: DictationTarget, agentHint: Bool = false, owner: AnyObject? = nil) {
        isActive ? stop() : start(target: target, agentHint: agentHint, owner: owner)
    }

    func start(target: DictationTarget, agentHint: Bool = false, owner: AnyObject? = nil) {
        guard !isActive else { return }
        let settings = SettingsStore.shared
        let model = settings.get(Settings.Dictation.model)
        guard DictationModelStore.shared.isReady(model) else {
            phase = .failed(DictationError.modelMissing.localizedDescription)
            return
        }
        let mode = settings.get(Settings.Dictation.commitMode)
        if self.target !== target || commitMode != mode { insertedChunks = []; insertedCount = 0 }
        self.target = target
        self.owner = owner
        commitMode = mode
        agentName = target.dictationAgentName
        style = Self.style(settings.get(Settings.Dictation.formatting), agent: agentHint || agentName != nil)
        formatter = DictationFormatter(.init(
            style: style,
            removeFillers: settings.get(Settings.Dictation.removeFillers),
            spokenCode: settings.get(Settings.Dictation.spokenCode),
            voiceCommands: settings.get(Settings.Dictation.voiceCommands),
            quickReplies: settings.get(Settings.Dictation.quickReplies)))
        partial = ""
        utteranceTyped = false
        phase = .preparing
        let session = UUID()
        self.session = session
        startTask = Task { await self.begin(session: session, model: model, target: target) }
    }

    /// Stops listening; the phrase in progress is still decoded.
    func stop() {
        switch phase {
        case .preparing:
            cancel()
        case .listening:
            phase = .finishing
            capture.stop()
            let recognizer = recognizer
            Task { await recognizer?.finish() }
        default:
            break
        }
    }

    /// Stops only a session the given surface started.
    func stop(ownedBy owner: AnyObject) {
        guard isActive, self.owner === owner else { return }
        stop()
    }

    /// Stops listening and drops the phrase in progress.
    func cancel() {
        releaseModels()
        startTask?.cancel()
        startTask = nil
        session = UUID()
        capture.stop()
        let recognizer = recognizer
        self.recognizer = nil
        Task { await recognizer?.cancel() }
        eventsTask?.cancel()
        eventsTask = nil
        audioSession.deactivate()
        partial = ""
        level = 0
        pendingInsert = nil
        utteranceTyped = false
        if isActive { phase = .idle }
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Preview actions

    /// Sends the preview to the terminal. While listening, finishes the phrase first.
    func insert(submit: Bool, into target: DictationTarget? = nil) {
        if let target { self.target = target }
        if phase == .listening || phase == .finishing {
            pendingInsert = submit
            stop()
            return
        }
        commitPreview(submit: submit)
    }

    private func commitPreview(submit: Bool) {
        guard let target else { return }
        let text = previewText
        if !text.isEmpty { target.dictationInsert(text) }
        if submit { target.dictationSubmit() }
        phrases = []
        // Live-mode chunks before this text can no longer be undone by length.
        resetInsertions()
    }

    /// Return from the pane or HUD. Ends the phrase run, so Undo and spacing start fresh.
    func submit(to target: DictationTarget?) {
        guard let target = target ?? self.target else { return }
        target.dictationSubmit()
        resetInsertions()
    }

    /// Hands-Free's pending Return belongs to text still on the line.
    private var handsFreeReturnPending: Bool {
        utteranceTyped && !insertedChunks.isEmpty && target?.dictationInputGeneration == deliveredGeneration
    }

    func clear() {
        phrases = []
        partial = ""
    }

    /// Replaces the preview with hand-edited text.
    func replacePreview(with text: String) {
        phrases = text.isEmpty ? [] : [text]
    }

    func undo() {
        if commitMode == .preview {
            _ = phrases.popLast()
            return
        }
        discardStaleInsertions()
        guard let target, let chunk = insertedChunks.popLast() else { return }
        target.dictationDeleteBackward(chunk.count)
        deliveredGeneration = target.dictationInputGeneration
        insertedCount = insertedChunks.count
        if insertedChunks.isEmpty { utteranceTyped = false }
    }

    /// Typing, pasting or Return since our last insertion moved the cursor
    /// context; deleting "the last phrase" would then remove someone else's text.
    private func discardStaleInsertions() {
        guard !insertedChunks.isEmpty, target?.dictationInputGeneration != deliveredGeneration else { return }
        resetInsertions()
    }

    /// Also drops a pending Hands-Free Return: the text it was for is gone or sent.
    private func resetInsertions() {
        insertedChunks = []
        insertedCount = 0
        utteranceTyped = false
        deliveredGeneration = target?.dictationInputGeneration
    }

    /// Returns this session's use of the models, once. Other sessions' uses keep them loaded.
    private func releaseModels() {
        guard leasedSession != nil else { return }
        leasedSession = nil
        let minutes = SettingsStore.shared.get(Settings.Dictation.keepLoadedMinutes)
        Task { await DictationEngine.shared.release(keepLoadedMinutes: minutes) }
    }

    // MARK: - Private

    private func begin(session: UUID, model: DictationModel, target: DictationTarget) async {
        guard await AVAudioApplication.requestRecordPermission() else {
            fail(DictationError.microphoneDenied, session: session)
            return
        }
        guard self.session == session else { return }
        NotificationCenter.default.post(name: .microphoneCaptureWillBegin, object: self)
        let settings = SettingsStore.shared
        let engine = DictationEngine.shared
        // Cancelled on every exit that doesn't hand it to self.recognizer; its task
        // would otherwise wait forever for audio.
        var pendingRecognizer: DictationRecognizer?
        do {
            try await engine.acquire(model: model, precision: settings.get(Settings.Dictation.encoderPrecision))
            guard self.session == session else {
                // Cancelled while loading; this use was never recorded, so return it here.
                let minutes = settings.get(Settings.Dictation.keepLoadedMinutes)
                await engine.release(keepLoadedMinutes: minutes)
                return
            }
            leasedSession = session
            let boost = settings.get(Settings.Dictation.vocabularyEnabled) && model.supportsVocabularyBoost
                && DictationModelStore.shared.state(.vocabulary) == .ready
            await engine.configureVocabulary(boost ? vocabulary(for: target) : [])
            let vad = try await engine.vadManager()
            // A cancel since the lease was taken already released it.
            guard self.session == session else { return }

            let language = settings.get(Settings.Dictation.language)
            var silence = settings.get(Settings.Dictation.autoStopSilence)
            // Prompts and hands-free conversations run long; give them room to think.
            if silence > 0, style == .agent || commitMode == .handsFree { silence = max(silence, 60) }
            let recognizer = DictationRecognizer(engine: engine, vad: vad, configuration: .init(
                language: language.isEmpty ? nil : language,
                speechThreshold: settings.get(Settings.Dictation.speechThreshold),
                pauseDuration: settings.get(Settings.Dictation.pauseDuration),
                autoStopSilence: silence,
                normalizeNumbers: settings.get(Settings.Dictation.numberNormalization) && model.usesNumberNormalizer,
                boost: boost))
            pendingRecognizer = recognizer
            await recognizer.start()
            guard self.session == session else {
                await recognizer.cancel()
                return
            }

            // No suspension from here to handoff, so a cancel cannot slip in between.
            try audioSession.activateForDictation()
            try capture.start { samples in recognizer.append(samples) }
            self.recognizer = recognizer
            pendingRecognizer = nil
            phase = .listening
            eventsTask = Task { [weak self] in
                for await event in recognizer.events {
                    self?.handle(event, session: session)
                }
                self?.finished(session: session)
            }
        } catch {
            await pendingRecognizer?.cancel()
            fail(error, session: session)
        }
    }

    private func handle(_ event: DictationRecognizer.Event, session: UUID) {
        guard self.session == session else { return }
        switch event {
        case .speechStarted:
            break
        case .partial(let text):
            partial = formatter.format(text)
        case .phrase(let text, let isWholeUtterance):
            partial = ""
            if isWholeUtterance {
                apply(formatter.actions(for: text))
            } else {
                // A piece of a long utterance: commands only ever match a whole one.
                let formatted = formatter.format(text)
                apply(formatted.isEmpty ? [] : [.text(formatted)])
            }
        case .utteranceEnded:
            if commitMode == .handsFree, handsFreeReturnPending, let target {
                target.dictationSubmit()
            }
            // Hands-Free starts every utterance on a fresh line; Live keeps spacing across pauses.
            if commitMode == .handsFree { resetInsertions() }
            utteranceTyped = false
        case .silenceTimeout:
            stop()
        case .failed(let message):
            Self.logger.error("Dictation failed: \(message, privacy: .public)")
            fail(DictationError.audioUnavailable(message), session: session)
        }
    }

    private func apply(_ actions: [DictationAction]) {
        guard let target, target.dictationCanReceive || commitMode == .preview else { return }
        if commitMode != .preview { discardStaleInsertions() }
        for action in actions {
            switch action {
            case .text(let text) where commitMode == .preview:
                phrases.append(text)
            case .text(let text):
                let chunk = DictationFormatter.separator(insertedChunks.last ?? "", text, style: style) + text
                target.dictationInsert(chunk)
                insertedChunks.append(chunk)
                deliveredGeneration = target.dictationInputGeneration
                utteranceTyped = true
            case .submit where commitMode == .preview:
                commitPreview(submit: true)
            case .submit:
                target.dictationSubmit()
                resetInsertions()
            case .scratchThat:
                undo()
            case .key(let key):
                target.dictationSend(key)
                resetInsertions()
            }
        }
        insertedCount = insertedChunks.count
    }

    private func finished(session: UUID) {
        guard self.session == session else { return }
        capture.stop()
        audioSession.deactivate()
        recognizer = nil
        eventsTask = nil
        startTask = nil
        partial = ""
        level = 0
        if isActive { phase = .idle }
        releaseModels()
        if let submit = pendingInsert {
            pendingInsert = nil
            commitPreview(submit: submit)
        }
    }

    private func fail(_ error: Error, session: UUID) {
        guard self.session == session else { return }
        cancel()
        phase = .failed(error.localizedDescription)
    }

    private func vocabulary(for target: DictationTarget) -> [DictationVocabulary.Entry] {
        let settings = SettingsStore.shared
        var entries = settings.get(Settings.Dictation.vocabulary).compactMap(DictationVocabulary.parse)
        if settings.get(Settings.Dictation.screenVocabulary), let text = target.dictationScreenText {
            let known = Set(entries.map { $0.term.lowercased() })
            entries += DictationVocabulary.screenTerms(from: text).filter { !known.contains($0.term.lowercased()) }
        }
        return entries
    }

    static func style(_ formatting: DictationFormatting, agent: Bool) -> DictationFormatter.Style {
        switch formatting {
        case .auto: agent ? .agent : .command
        case .command: .command
        case .prose: .prose
        case .agent: .agent
        }
    }
}
#endif
