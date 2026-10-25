#if canImport(FluidAudio) && !CHINA_BUILD
//
//  DictationHUD.swift
//  rootshell
//
//  Floating dictation panel for Mac, and for iPad with a hardware keyboard
//  or the system keyboard. Passthrough: the terminal keeps the keyboard
//  unless the transcript is being edited.
//

import SwiftUI

struct DictationHUD: View {
    @Binding var isPresented: Bool
    /// The pane text goes to; resolved on use so focus changes are followed.
    let target: () -> DictationTarget?

    var body: some View {
        GeometryReader { geometry in
            DraggableHUDContainer(
                dismissShortcuts: [.escape],
                onDismiss: { isPresented = false }
            ) {
                DictationPanel(isPresented: $isPresented, target: target,
                               width: min(380, max(260, geometry.size.width - 24)))
            }
        }
    }
}

struct DictationPanel: View {
    @Binding var isPresented: Bool
    let target: () -> DictationTarget?
    let width: CGFloat

    private var controller: DictationController { .shared }
    private var store: DictationModelStore { .shared }
    @Setting(Settings.Dictation.formatting) private var formatting
    @Setting(Settings.Dictation.commitMode) private var commitMode
    @Setting(Settings.Dictation.encoderPrecision) private var precision
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if controller.modelReady {
                transcript
                Divider()
                controls
            } else {
                download
            }
        }
        .frame(width: width)
        .floatingHUDPanelBackground()
        .onChange(of: controller.phase) { _, phase in
            if phase == .listening { editing = false }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictation", comment: "Dictation HUD title").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(statusIsError ? .red : .secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Picker("Formatting", selection: $formatting) {
                    ForEach(DictationFormatting.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Insert Text", selection: $commitMode) {
                    ForEach(DictationCommitMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.title3).foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Dictation Options"))
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text("Close Dictation", comment: "Dictation HUD close button"))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var statusIsError: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    private var statusText: String {
        switch controller.phase {
        case .preparing: return String(localized: "Loading \(controller.model.displayName)…")
        case .listening:
            if let agent = controller.agentName {
                return String(localized: "Listening · \(controller.style.displayName) for \(agent)")
            }
            return String(localized: "Listening · \(controller.style.displayName)")
        case .finishing: return String(localized: "Finishing…")
        case .failed(let message): return message
        case .idle: return String(localized: "\(controller.model.displayName) · On device · \(controller.commitMode.displayName)")
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        Group {
            if editing {
                TextField("Transcript", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3...8)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        transcriptText
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id("end")
                    }
                    .onChange(of: controller.partial) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .frame(minHeight: 72, maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var transcriptText: some View {
        let committed = controller.commitMode == .preview ? controller.previewText : ""
        let partial = controller.partial
        if committed.isEmpty && partial.isEmpty {
            Text(placeholder).foregroundStyle(.secondary).font(.callout)
        } else {
            let tail = committed.isEmpty || partial.isEmpty ? partial : " " + partial
            Text("\(Text(verbatim: committed))\(Text(verbatim: tail).foregroundStyle(.secondary))")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var placeholder: String {
        if controller.isListening { return String(localized: "Speak now") }
        switch controller.commitMode {
        case .preview: return String(localized: "Click the mic and speak. Nothing is sent until you choose Insert or Run.")
        case .live: return String(localized: "Click the mic and speak. Each phrase is typed when you pause.")
        case .handsFree: return String(localized: "Click the mic and speak. Each phrase is typed and run when you pause.")
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            micButton
            Spacer()
            Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!controller.canUndo)
                .help(Text("Undo"))
                .accessibilityLabel(Text("Undo"))
            if controller.commitMode == .preview {
                Button {
                    if editing { controller.replacePreview(with: draft) } else { draft = controller.previewText }
                    editing.toggle()
                } label: { Image(systemName: editing ? "checkmark" : "pencil") }
                    .disabled(controller.isActive)
                    .help(editing ? Text("Done Editing") : Text("Edit"))
                    .accessibilityLabel(editing ? Text("Done Editing") : Text("Edit"))
                Button("Insert") { commit(submit: false) }
                    .disabled(!hasPreview)
                Button("Run") { commit(submit: true) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(DictationHUDButtonStyle(prominent: true))
                    .disabled(!hasPreview)
            } else {
                Button("Return") { controller.submit(to: target()) }
            }
        }
        .buttonStyle(DictationHUDButtonStyle(prominent: false))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var hasPreview: Bool {
        editing ? !draft.isEmpty : !controller.phrases.isEmpty || !controller.partial.isEmpty
    }

    private var micButton: some View {
        let listening = controller.isListening
        let busy = controller.phase == .preparing || controller.phase == .finishing
        return Button { toggleMic() } label: {
            ZStack {
                Circle()
                    .stroke(listening ? Color.red : Color.secondary.opacity(0.4), lineWidth: 3)
                    .scaleEffect(listening ? 1 + CGFloat(controller.level) * 0.15 : 1)
                    .opacity(listening ? 0.4 + Double(controller.level) * 0.6 : 1)
                Circle()
                    .fill(listening ? Color.red : Color.secondary.opacity(0.15))
                    .padding(5)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(listening ? Color.white : Color.primary)
                }
            }
            .frame(width: 46, height: 46)
            .animation(.easeOut(duration: 0.08), value: controller.level)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? Text("Stop Dictation") : Text("Start Dictation"))
    }

    private func toggleMic() {
        guard let target = target() else { return }
        if editing {
            controller.replacePreview(with: draft)
            editing = false
        }
        controller.dismissError()
        controller.toggle(target: target, owner: DictationController.hudOwner)
    }

    private func commit(submit: Bool) {
        if editing {
            controller.replacePreview(with: draft)
            editing = false
        }
        controller.insert(submit: submit, into: target())
    }

    // MARK: - Download

    private var download: some View {
        let model = controller.model
        let speech = store.state(.speech(model))
        return VStack(alignment: .leading, spacing: 10) {
            Text("On-device dictation uses \(model.displayName) (\(model.downloadMegabytes(precision)) MB). Audio never leaves this device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch speech {
            case .downloading(let value):
                ProgressView(value: value)
                Button("Cancel") { store.cancel(.speech(model)) }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Try Again") { store.downloadForListening(model) }
                    .buttonStyle(.borderedProminent)
            default:
                Button("Download") { store.downloadForListening(model) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

/// Stock bordered styles turn flat grey on glass when disabled; this keeps the
/// look and dims instead, matching the keyboard's Dictation page.
private struct DictationHUDButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(minWidth: 32, minHeight: 28)
            .background(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.08)), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
#endif
