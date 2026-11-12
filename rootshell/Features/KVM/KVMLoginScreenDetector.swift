//
//  KVMLoginScreenDetector.swift
//  rootshell
//
//  On-device OCR that recognizes a login, lock or disk-unlock screen in a
//  KVM video frame. The computer behind a KVM can run any OS, so this looks
//  for macOS, Windows and Linux sign-in screens and pre-boot unlock prompts.
//

import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// One recognized line in Vision's normalized, bottom-left image space.
nonisolated struct KVMLoginTextLine: Equatable, Sendable {
    let text: String
    let confidence: Float
    let bounds: CGRect
}

nonisolated struct KVMLoginScreenAnalysis: Equatable, Sendable {
    let isLoginScreen: Bool
    /// Which rule matched; never the recognized text.
    let evidence: String
}

/// Conservative: a match only offers a confirmation dialog, but a desktop
/// that merely shows the word "password" must not.
nonisolated enum KVMLoginScreenDetector {
    static func recognize(pixelBuffer: CVPixelBuffer) throws -> KVMLoginScreenAnalysis {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        let fast = VNRecognizeTextRequest()
        fast.recognitionLevel = .fast
        fast.usesLanguageCorrection = false
        fast.automaticallyDetectsLanguage = true
        fast.minimumTextHeight = 0.012
        fast.preferBackgroundProcessing = true
        try handler.perform([fast])
        let fastAnalysis = analyze(lines(from: fast))
        if fastAnalysis.isLoginScreen { return fastAnalysis }

        // Password labels are small next to a lock screen's clock; an
        // accurate pass over the central band finds them.
        let focused = VNRecognizeTextRequest()
        focused.recognitionLevel = .accurate
        focused.usesLanguageCorrection = true
        focused.automaticallyDetectsLanguage = true
        focused.minimumTextHeight = 0.001
        focused.preferBackgroundProcessing = true
        focused.regionOfInterest = CGRect(x: 0.15, y: 0.0, width: 0.70, height: 0.75)
        try handler.perform([focused])
        return analyze(lines(from: focused))
    }

    static func analyze(_ lines: [KVMLoginTextLine]) -> KVMLoginScreenAnalysis {
        let confident = lines.filter { $0.confidence >= 0.35 }
        let all = confident.map { normalize($0.text) }
        // Pre-boot prompts are specific enough to trust anywhere on screen.
        if all.contains(where: { line in preBootPhrases.contains { contains(line, $0) } }) {
            return KVMLoginScreenAnalysis(isLoginScreen: true, evidence: "disk unlock prompt")
        }

        let central = confident.filter { isCentral($0.bounds) }.map { normalize($0.text) }
        if central.contains(where: { line in strongPhrases.contains { contains(line, $0) } }) {
            return KVMLoginScreenAnalysis(isLoginScreen: true, evidence: "central sign-in phrase")
        }

        let combined = central.joined(separator: " ")
        let hasSecret = secretWords.contains { contains(combined, $0) }
        let hasBiometric = contains(combined, "touch id") || contains(combined, "windows hello")
        let actions = loginActions.filter { contains(combined, $0) }.count
        if hasSecret, hasBiometric || actions >= 2 {
            return KVMLoginScreenAnalysis(
                isLoginScreen: true,
                evidence: hasBiometric ? "password and biometric" : "password and sign-in actions")
        }
        return KVMLoginScreenAnalysis(
            isLoginScreen: false,
            evidence: hasSecret ? "password word only" : "no sign-in text")
    }

    // MARK: - Matching

    private static func lines(from request: VNRecognizeTextRequest) -> [KVMLoginTextLine] {
        (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return KVMLoginTextLine(
                text: candidate.string,
                confidence: candidate.confidence,
                bounds: observation.boundingBox)
        }
    }

    /// macOS puts the field near the bottom, Windows and GDM near the middle.
    private static func isCentral(_ bounds: CGRect) -> Bool {
        (0.14...0.86).contains(bounds.midX) && (0.0...0.78).contains(bounds.midY)
    }

    /// Lowercased, accent-folded words separated by single spaces.
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Latin phrases match whole words ("pin" never matches "spinning");
    /// CJK text has no spaces, so it matches as a substring.
    static func contains(_ text: String, _ phrase: String) -> Bool {
        if phrase.unicodeScalars.allSatisfy(\.isASCII) {
            return " \(text) ".contains(" \(phrase) ")
        }
        return text.contains(phrase)
    }

    private static let preBootPhrases = [
        "unlock this drive", "passphrase for disk", "enter passphrase for",
        "please enter passphrase", "bitlocker recovery",
    ]

    private static let strongPhrases = [
        "enter password", "enter your password", "type password", "type your password",
        "password required", "password is required", "enter pin", "enter your pin",
        "i forgot my password", "i forgot my pin", "sign in options",
        "passwort eingeben", "saisissez le mot de passe", "introduce la contrasena",
        "ingresa tu contrasena", "inserisci password", "digite a senha", "voer wachtwoord in",
        "パスワードを入力", "输入密码", "輸入密碼", "암호 입력",
    ]

    private static let secretWords = [
        "password", "passphrase", "pin", "passwort", "mot de passe", "contrasena", "senha",
        "wachtwoord", "パスワード", "密码", "密碼", "암호",
    ]

    private static let loginActions = [
        "cancel", "switch user", "other user", "not listed", "sign in", "log in", "unlock",
        "sleep", "restart", "shut down", "power",
        "annuler", "changer d utilisateur", "redemarrer", "eteindre",
        "abbrechen", "benutzer wechseln", "neustart", "ausschalten", "anmelden",
        "cancelar", "cambiar usuario", "reiniciar", "apagar",
    ]
}
