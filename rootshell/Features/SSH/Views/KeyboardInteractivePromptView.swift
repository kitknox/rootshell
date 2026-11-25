import SwiftUI
import UIKit

/// Modal for answering a keyboard-interactive (RFC 4256) SSH challenge: the
/// server supplies a name/instruction and one or more prompts (each marked echo
/// or no-echo), commonly used for OTP/2FA or PAM password flows. Mirrors
/// ``PasswordPromptSheet`` styling.
struct KeyboardInteractivePromptView: View {
    let challenge: KeyboardInteractiveChallenge
    let sessionLabel: String
    let onSubmit: ([String]) -> Void
    let onCancel: () -> Void
    /// Factory for the session's live auth-banner state stream, shown
    /// display-only above the prompts. The sheet covers the pane's
    /// auth-banner card on iPhone, so OTP-style banner instructions (and
    /// their URLs) must appear here too.
    let authBannerStates: (@MainActor () -> AsyncStream<SSHAuthBannerCardState?>)?

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var responses: [String]
    @State private var bannerState: SSHAuthBannerCardState?
    @FocusState private var focusedIndex: Int?

    init(
        challenge: KeyboardInteractiveChallenge,
        sessionLabel: String,
        onSubmit: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void,
        authBannerStates: (@MainActor () -> AsyncStream<SSHAuthBannerCardState?>)? = nil
    ) {
        self.challenge = challenge
        self.sessionLabel = sessionLabel
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.authBannerStates = authBannerStates
        _responses = State(initialValue: Array(repeating: "", count: challenge.prompts.count))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading) {
                            Text(sessionLabel)
                                .font(.headline)
                            if !challenge.name.isEmpty {
                                Text(challenge.name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .themedRow()

                    let instruction = challenge.instructionMessage
                    if !instruction.isEmpty {
                        serverMessageRow(instruction, urls: SSHBanner.extractHTTPURLs(from: instruction))
                    }
                } header: {
                    Text("Connection")
                }

                if let bannerState {
                    Section {
                        SSHAuthBannerContentView(
                            state: bannerState,
                            onOpenURL: openURL,
                            onCopyURL: copyURL
                        )
                        .themedRow()
                    } header: {
                        Text("Server Message")
                    }
                }

                if challenge.prompts.isEmpty {
                    Section {
                        Text("No input required. Tap Continue to proceed.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .themedRow()
                    }
                } else {
                    Section {
                        ForEach(challenge.prompts.indices, id: \.self) { index in
                            let prompt = challenge.prompts[index]
                            if !prompt.message.isEmpty || !prompt.urls.isEmpty {
                                serverMessageRow(prompt.message, urls: prompt.urls)
                            }
                            promptField(index: index)
                        }
                    } header: {
                        Text(challenge.prompts.count > 1 ? "Server Prompts" : "Server Prompt")
                    }
                }
            }
            .themedList()
            .navigationTitle("Authentication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(challenge.prompts.isEmpty ? "Continue" : "Submit") {
                        onSubmit(responses)
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                // The keyboard would cover a QR code or link the user must act on first.
                guard !challenge.prompts.isEmpty, !hasServerMessage else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedIndex = 0
                }
            }
            .task {
                guard let authBannerStates else { return }
                for await state in authBannerStates() {
                    bannerState = state
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var hasServerMessage: Bool {
        !challenge.instructionMessage.isEmpty
            || challenge.prompts.contains { !$0.message.isEmpty || !$0.urls.isEmpty }
    }

    private func openURL(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private func copyURL(_ url: URL) {
        UIPasteboard.general.string = url.absoluteString
        ClipboardHistoryManager.shared.record(url.absoluteString, source: .copyLink)
    }

    /// Server text plus Open/Copy actions for each http(s) URL it carries.
    private func serverMessageRow(_ message: String, urls: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.isEmpty {
                ServerMessageText(text: message)
            }
            ForEach(urls, id: \.absoluteString) { url in
                SSHAuthBannerURLRow(url: url, onOpenURL: openURL, onCopyURL: copyURL)
            }
        }
        .themedRow()
    }

    /// Index of the first password-like (no-echo) prompt, if any. The hidden
    /// username AutoFill anchor is attached to this field so the OS password
    /// manager can match the saved credential. Nil for OTP-only challenges,
    /// which have no saved-password credential to match.
    private var usernameAnchorIndex: Int? {
        guard !challenge.username.isEmpty else { return nil }
        return challenge.prompts.firstIndex {
            !$0.echo && $0.secretKind == .password
        }
    }

    /// Zero-size, invisible username field. Attached as a `.background` (not a
    /// list row) so it stays in the hierarchy for AutoFill association without
    /// adding any visible row or layout space to the form.
    @ViewBuilder
    private var usernameAnchor: some View {
        TextField("", text: .constant(challenge.username))
            .textContentType(.username)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    /// The label is the placeholder when it fits on one line; otherwise it
    /// wraps as text above the field instead of truncating.
    private func promptField(index: Int) -> some View {
        let label = challenge.prompts[index].label
        return ViewThatFits(in: .horizontal) {
            promptInput(index: index, placeholder: label.isEmpty ? "Response" : label)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: label)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                promptInput(index: index, placeholder: "Response")
            }
        }
        .themedRow()
    }

    @ViewBuilder
    private func promptInput(index: Int, placeholder: String) -> some View {
        let prompt = challenge.prompts[index]
        Group {
            if prompt.echo {
                TextField(placeholder, text: $responses[index])
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                // Hidden field. Pick the AutoFill content type from the prompt
                // text: `.password` surfaces the OS password-manager key,
                // `.oneTimeCode` surfaces the 2FA/OTP suggestion strip.
                SecureField(placeholder, text: $responses[index])
                    .textContentType(prompt.secretKind == .password ? .password : .oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .background { if index == usernameAnchorIndex { usernameAnchor } }
            }
        }
        .focused($focusedIndex, equals: index)
        .submitLabel(index == challenge.prompts.count - 1 ? .go : .next)
        .onSubmit {
            if index < challenge.prompts.count - 1 {
                focusedIndex = index + 1
            } else {
                onSubmit(responses)
            }
        }
    }
}

/// Server text with any text-art kept on its grid. Runs of lines holding
/// block, box-drawing or braille glyphs (a terminal QR code) render in Menlo,
/// unwrapped, shrunk so the widest art line fits the row, scrolling sideways
/// below the minimum size. Menlo's block glyphs are one cell wide and fill the
/// line height, so QR modules stay square and gapless. Prose keeps Dynamic Type.
private struct ServerMessageText: View {
    let text: String

    @State private var width: CGFloat = 0

    private enum Segment {
        case prose(String)
        case art(String)
    }

    private static let fontName = "Menlo-Regular"
    private static let defaultSize: CGFloat = 12
    private static let minimumSize: CGFloat = 6

    private static let advancePerPoint: CGFloat = {
        let font = UIFont(name: fontName, size: 100) ?? .monospacedSystemFont(ofSize: 100, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width / 100
    }()

    private static func isArt(_ line: Substring) -> Bool {
        line.unicodeScalars.contains {
            (0x2500...0x259F).contains($0.value) || (0x2800...0x28FF).contains($0.value)
        }
    }

    /// Blank lines between art lines stay in the art run so the grid holds;
    /// blank lines at prose edges are dropped in favor of stack spacing.
    private static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        var art: [Substring] = []
        // Blank lines after an art line; they join the run only if art resumes.
        var blanks: [Substring] = []
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose = []
        }
        func closeArt() {
            guard !art.isEmpty else { return }
            segments.append(.art(art.joined(separator: "\n")))
            art = []
            prose = blanks
            blanks = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isArt(line) {
                if art.isEmpty { flushProse() }
                art += blanks
                blanks = []
                art.append(line)
            } else if !art.isEmpty, line.allSatisfy(\.isWhitespace) {
                blanks.append(line)
            } else {
                closeArt()
                prose.append(line)
            }
        }
        closeArt()
        flushProse()
        return segments
    }

    /// One size for every art run, from the widest art line in the message.
    private func artFontSize(_ segments: [Segment]) -> CGFloat {
        let columns = segments.compactMap { segment -> Int? in
            guard case .art(let art) = segment else { return nil }
            return art.split(separator: "\n").map(\.count).max()
        }.max() ?? 0
        guard columns > 0, width > 0 else { return Self.defaultSize }
        let fit = (width - 1) / (CGFloat(columns) * Self.advancePerPoint)
        return min(Self.defaultSize, max(Self.minimumSize, (fit * 4).rounded(.down) / 4))
    }

    var body: some View {
        let segments = Self.segments(text)
        let artSize = artFontSize(segments)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments.indices, id: \.self) { index in
                switch segments[index] {
                case .prose(let prose):
                    Text(verbatim: prose)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                case .art(let art):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: art)
                            .font(.custom(Self.fontName, fixedSize: artSize))
                            .fixedSize()
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
