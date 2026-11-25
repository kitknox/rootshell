import Foundation
import NIOSSH
import NIOCore
import os.log

/// A single keyboard-interactive (RFC 4256) prompt to present to the user.
/// Value type so it is safe to hand across the NIO event-loop ↔ MainActor boundary.
struct KeyboardInteractivePrompt: Sendable, Hashable {
    let prompt: String
    /// Whether the typed response should be echoed. `false` for secrets
    /// (passwords, one-time codes); `true` for visible fields.
    let echo: Bool

    /// Server text above the input line. OpenSSH's PAM bridge prepends info
    /// messages (QR codes, login URLs) to the prompt, so only the text after
    /// the last newline labels the field.
    var message: String { KeyboardInteractiveText.split(prompt).message }

    /// The field label; empty when the prompt ends in a newline.
    var label: String { KeyboardInteractiveText.split(prompt).label }

    /// The label decides; the message only when the label names no kind
    /// (empty, or generic like "Response:"), so QR or URL text can't override it.
    var secretKind: KeyboardInteractiveSecretKind {
        let parts = KeyboardInteractiveText.split(prompt)
        return .signal(parts.label) ?? .signal(parts.message) ?? .password
    }

    /// http(s) URLs anywhere in the prompt, the label line included.
    var urls: [URL] {
        let parts = KeyboardInteractiveText.split(prompt)
        return SSHBanner.extractHTTPURLs(from: parts.message + "\n" + parts.label)
    }
}

/// Splits server-supplied keyboard-interactive text into sanitized display parts.
nonisolated enum KeyboardInteractiveText {
    static func split(_ raw: String) -> (message: String, label: String) {
        let normalized = paintingANSIBackgrounds(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let newline = normalized.lastIndex(of: "\n") else {
            return ("", SSHBanner.terminalSafe(normalized))
        }
        let message = SSHBanner.plainText(String(normalized[..<newline]), trimsIndentation: false)
        let label = SSHBanner.terminalSafe(String(normalized[normalized.index(after: newline)...]))
        // "Verification code:\n" is still just a label.
        if label.isEmpty, !message.contains("\n") {
            return ("", SSHBanner.terminalSafe(message))
        }
        return (message, label)
    }

    /// Instruction text keeps its line layout (text-art must not reflow).
    static func message(_ raw: String) -> String {
        SSHBanner.plainText(paintingANSIBackgrounds(raw), trimsIndentation: false)
    }

    /// QR codes drawn as spaces on colored backgrounds would vanish when
    /// `plainText` strips SGR, so spaces on a dark background become `█`
    /// first. Only rows whose visible text is all spaces and block glyphs are
    /// converted, so colored prose keeps the spaces that delimit its URLs.
    /// The SGR sequences stay for `plainText` to strip.
    static func paintingANSIBackgrounds(_ raw: String) -> String {
        guard raw.contains("\u{1B}[") else { return raw }
        // "\r\n" is one Character, so normalize before splitting into rows.
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var dark = false
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let scalars = Array(line.unicodeScalars)
            var painted = String.UnicodeScalarView()
            var isArtRow = true
            var i = 0
            while i < scalars.count {
                if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "[" {
                    var end = i + 2
                    while end < scalars.count, !(0x40...0x7E).contains(scalars[end].value) { end += 1 }
                    guard end < scalars.count else { break }
                    if scalars[end] == "m" {
                        let params = String(String.UnicodeScalarView(scalars[(i + 2)..<end]))
                        dark = applySGR(params, dark: dark)
                    }
                    painted.append(contentsOf: scalars[i...end])
                    i = end + 1
                    continue
                }
                let scalar = scalars[i]
                if scalar != " ", !(0x2580...0x259F).contains(scalar.value) {
                    isArtRow = false
                }
                painted.append(dark && scalar == " " ? "\u{2588}" : scalar)
                i += 1
            }
            return isArtRow ? String(painted) : String(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Tracks whether the SGR background is dark (by luminance); other
    /// attributes are skipped, including 38;5;n and 38;2;r;g;b operands.
    private static func applySGR(_ params: String, dark: Bool) -> Bool {
        let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var dark = dark
        var k = 0
        while k < codes.count {
            switch codes[k] {
            case 0, 49: dark = false
            case 40...47: dark = isDarkPalette(codes[k] - 40)
            case 100...107: dark = isDarkPalette(codes[k] - 100 + 8)
            case 38, 48:
                let isBackground = codes[k] == 48
                if k + 2 < codes.count, codes[k + 1] == 5 {
                    if isBackground { dark = isDarkPalette(codes[k + 2]) }
                    k += 2
                } else if k + 4 < codes.count, codes[k + 1] == 2 {
                    if isBackground { dark = isDark(r: codes[k + 2], g: codes[k + 3], b: codes[k + 4]) }
                    k += 4
                }
            default: break
            }
            k += 1
        }
        return dark
    }

    /// xterm 256-color palette: 16 system colors, 6x6x6 cube, gray ramp.
    private static func isDarkPalette(_ n: Int) -> Bool {
        switch n {
        case 0..<16: return [0, 1, 4, 5, 8].contains(n)
        case 16...231:
            let levels = [0, 95, 135, 175, 215, 255]
            let c = n - 16
            return isDark(r: levels[c / 36], g: levels[(c / 6) % 6], b: levels[c % 6])
        case 232...255: return n < 244
        default: return false
        }
    }

    private static func isDark(r: Int, g: Int, b: Int) -> Bool {
        0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b) < 128
    }
}

/// Semantic classification of a no-echo keyboard-interactive prompt, derived
/// from the server-supplied prompt text, used to pick the right iOS AutoFill
/// content type. Visible (echo) prompts are not classified here.
enum KeyboardInteractiveSecretKind: Sendable {
    case password      // -> .textContentType(.password)
    case oneTimeCode   // -> .textContentType(.oneTimeCode)

    /// OTP-like phrases are checked FIRST (note "one-time password" contains
    /// "password"); otherwise password-like; otherwise default to `.password`
    /// so the OS password manager remains reachable for unrecognised secrets.
    static func classify(_ promptText: String) -> KeyboardInteractiveSecretKind {
        signal(promptText) ?? .password
    }

    /// The kind the text names, or nil when it names neither.
    static func signal(_ promptText: String) -> KeyboardInteractiveSecretKind? {
        let t = promptText.lowercased()
        let otp = ["one-time", "one time", "onetime", "otp", "totp", "hotp",
                   "verification", "authenticator", "two-factor", "two factor",
                   "2fa", "token", "duo", "passcode", "yubikey", "security code"]
        if otp.contains(where: t.contains) { return .oneTimeCode }
        if t.contains("password") || t.contains("passphrase") { return .password }
        return nil
    }
}

/// One round of a keyboard-interactive challenge from the server.
/// Built on the event loop, consumed on the MainActor; strings are copied at
/// init to avoid any lifetime/bridging issues across the boundary.
struct KeyboardInteractiveChallenge: Sendable {
    /// A human label for the connection being authenticated (e.g. "user@host"
    /// or "[Jump Host] user@bastion"), used for the prompt UI title.
    let sessionName: String
    /// The SSH login username. Used as a hidden AutoFill anchor so the OS
    /// password manager can match the saved credential for a password prompt.
    let username: String
    /// The server-supplied challenge name (may be empty).
    let name: String
    /// The server-supplied instruction text (may be empty).
    let instruction: String
    /// The prompts to present, in order. May be empty (information-only round).
    let prompts: [KeyboardInteractivePrompt]

    /// `instruction`, sanitized for native display with its lines intact.
    var instructionMessage: String { KeyboardInteractiveText.message(instruction) }
}

/// Thrown to abort keyboard-interactive auth when the user cancels.
struct KeyboardInteractiveCancelledError: Error, LocalizedError {
    var errorDescription: String? { "Keyboard-interactive authentication was cancelled" }
}

/// An auth delegate that wraps a primary "inner" offer delegate (key/password/
/// none) and additionally answers keyboard-interactive (RFC 4256) challenges.
///
/// Citadel's `.custom(_)` wraps a single delegate and forwards both
/// `nextAuthenticationType` and `respondToKeyboardInteractiveChallenge` to it,
/// so the keyboard-interactive responder must live on the same object that
/// makes the primary offer. This composing delegate is that object.
///
/// Offer ordering:
///  1. Forward to the inner delegate. While it has offers (e.g. a key, or a
///     password), use them.
///  2. Once the inner delegate is exhausted, offer keyboard-interactive once.
///     This covers "publickey + 2FA", PAM-password (server only advertises
///     keyboard-interactive), and the explicit keyboard-interactive method
///     (no inner delegate at all). The offer is proactive — it is not gated on
///     `availableMethods` because the client only learns a server's
///     keyboard-interactive support from a USERAUTH_FAILURE, and a server that
///     does not support it simply replies with another failure (harmless).
///
/// Marked `nonisolated` + `@unchecked Sendable` because NIO invokes it from the
/// event loop; all MainActor work is funnelled through `Task { @MainActor in }`,
/// mirroring ``SSHHostKeyDelegate``. There is no timeout coordinator: the active
/// Citadel path relies on its 5-minute login timeout, which covers human input.
nonisolated final class KeyboardInteractiveAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let sessionName: String
    private let inner: NIOSSHClientUserAuthenticationDelegate?
    private nonisolated(unsafe) let onChallenge: (KeyboardInteractiveChallenge) async -> [String]?

    /// One-shot password reused to auto-answer a single hidden prompt (OpenSSH
    /// parity for PAM-password servers). Consumed on first use, then nil so any
    /// further rounds (e.g. an OTP) always prompt the user.
    private nonisolated(unsafe) var autoAnswerPassword: String?
    private nonisolated(unsafe) var triedKeyboardInteractive = false

    private static let logger = Logger(subsystem: "com.rootshell", category: "SSHKbdInteractive")

    init(
        username: String,
        sessionName: String,
        inner: NIOSSHClientUserAuthenticationDelegate?,
        autoAnswerPassword: String? = nil,
        onChallenge: @escaping (KeyboardInteractiveChallenge) async -> [String]?
    ) {
        self.username = username
        self.sessionName = sessionName
        self.inner = inner
        self.autoAnswerPassword = autoAnswerPassword
        self.onChallenge = onChallenge
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard let inner = inner else {
            // Explicit keyboard-interactive: no primary method, offer it directly.
            offerKeyboardInteractiveOrFinish(promise: nextChallengePromise, serverOffersIt: true)
            return
        }

        // As a fallback, only offer what the server actually advertised. The `none`
        // probe means this list is the server's own, not NIOSSH's initial placeholder.
        let serverOffersIt = availableMethods.contains(.keyboardInteractive)

        let eventLoop = nextChallengePromise.futureResult.eventLoop
        let wrapper = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        wrapper.futureResult.whenComplete { [self] result in
            switch result {
            case .success(let offer):
                if let offer = offer {
                    // Inner delegate still has a method to try.
                    nextChallengePromise.succeed(offer)
                } else {
                    // Inner delegate exhausted — fall back to keyboard-interactive.
                    self.offerKeyboardInteractiveOrFinish(promise: nextChallengePromise, serverOffersIt: serverOffersIt)
                }
            case .failure(let error):
                // Inner delegate failed hard. Try keyboard-interactive once before
                // giving up, then propagate the original error.
                if !self.triedKeyboardInteractive {
                    self.offerKeyboardInteractiveOrFinish(promise: nextChallengePromise, serverOffersIt: serverOffersIt)
                } else {
                    nextChallengePromise.fail(error)
                }
            }
        }
        inner.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: wrapper)
    }

    func serverSignatureAlgorithmsReceived(_ algorithms: [String]) {
        inner?.serverSignatureAlgorithmsReceived(algorithms)
    }

    private func offerKeyboardInteractiveOrFinish(
        promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>,
        serverOffersIt: Bool
    ) {
        guard !triedKeyboardInteractive, serverOffersIt else {
            // Already attempted, or the server never advertised it.
            promise.succeed(nil)
            return
        }
        triedKeyboardInteractive = true
        Self.logger.info("Offering keyboard-interactive authentication")
        promise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .keyboardInteractive(.init())
        ))
    }

    func authenticationSucceededPartially() {
        // A prior method (e.g. the password) was accepted and the server now
        // requires a further factor. Drop the stored password so it is never
        // auto-submitted to the next keyboard-interactive prompt (e.g. an OTP).
        autoAnswerPassword = nil
    }

    func respondToKeyboardInteractiveChallenge(
        name: String,
        instruction: String,
        prompts: [NIOSSHKeyboardInteractivePrompt],
        responsePromise: EventLoopPromise<[String]>
    ) {
        // A zero-prompt INFO_REQUEST (RFC 4256) is an information-only round —
        // common in PAM right before success. Respond immediately with an empty
        // answer instead of surfacing a "no input required" prompt to the user.
        if prompts.isEmpty {
            responsePromise.succeed([])
            return
        }

        // Auto-answer OpenSSH-style: a single hidden prompt with a stored/typed
        // password. One-shot, so a later round (e.g. an OTP) still prompts.
        // Never when the round carries server text the sheet would show (a QR
        // code, instruction or login link the user must see before answering).
        // The label must positively name a password: an ambiguous "Code:" is
        // left to the user rather than risk sending the password as an OTP.
        let mappedPrompts = prompts.map { KeyboardInteractivePrompt(prompt: String($0.prompt), echo: $0.echo) }
        if let password = autoAnswerPassword, mappedPrompts.count == 1, !mappedPrompts[0].echo,
           KeyboardInteractiveSecretKind.signal(mappedPrompts[0].label) == .password,
           mappedPrompts[0].message.isEmpty, mappedPrompts[0].urls.isEmpty,
           KeyboardInteractiveText.message(instruction).isEmpty {
            autoAnswerPassword = nil
            Self.logger.info("Auto-answering single hidden keyboard-interactive prompt with stored password")
            responsePromise.succeed([password])
            return
        }
        // A round the user answers consumes the one-shot password too, so a
        // later "Verification code:" round can never receive it.
        autoAnswerPassword = nil

        // Copy to Sendable value types before crossing to the MainActor.
        let challenge = KeyboardInteractiveChallenge(
            sessionName: String(sessionName),
            username: String(username),
            name: String(name),
            instruction: String(instruction),
            prompts: mappedPrompts
        )
        let promptCount = mappedPrompts.count
        Self.logger.info("Presenting keyboard-interactive challenge with \(promptCount) prompt(s)")

        Task { @MainActor [self] in
            if let responses = await self.onChallenge(challenge) {
                responsePromise.succeed(responses)
            } else {
                // User cancelled — fail this method; auth then tries the next or fails.
                responsePromise.fail(KeyboardInteractiveCancelledError())
            }
        }
    }
}

/// A minimal offer-only delegate that proposes password authentication once.
///
/// `SSHConnectionHelper` previously used Citadel's `.passwordBased(...)` (a
/// `.user` offer), but Citadel only forwards keyboard-interactive challenges to
/// `.custom` delegates. Routing password auth through this delegate (wrapped in
/// ``KeyboardInteractiveAuthDelegate``) makes keyboard-interactive reachable for
/// PAM-password servers while preserving plain password auth.
nonisolated final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let password: String
    private nonisolated(unsafe) var tried = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !tried, availableMethods.contains(.password) else {
            nextChallengePromise.succeed(nil)
            return
        }
        tried = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .password(.init(password: password))
        ))
    }
}
