//
//  ExternalEditorBridge.swift
//  rootshell
//
//  Platform handoff for editing files in external applications:
//  - Mac Catalyst: NSWorkspace app discovery, "Open With" listing, and
//    launching files with an explicit editor (falling back to the plain-text
//    handler for extensionless server configs like .env or Dockerfile).
//  - iOS / iPadOS / visionOS: UIDocumentPickerViewController(forExporting:asCopy:false)
//    so external editors can edit the moved file in place while Rootshell holds
//    its security-scoped URL and auto-uploads every save.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

#if targetEnvironment(macCatalyst)
import ObjectiveC

@MainActor
enum ExternalEditorBridge {
    struct ExternalApp: Identifiable, Hashable {
        let url: URL
        let name: String
        let bundleID: String?

        var id: String { url.standardizedFileURL.path }
    }

    enum BridgeError: LocalizedError {
        case workspaceUnavailable
        case noApplicationFound(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .workspaceUnavailable:
                String(localized: "macOS Workspace is unavailable.", comment: "External editor error")
            case .noApplicationFound(let fileName):
                String(localized: "No external editor was found to open “\(fileName)”.", comment: "External editor error; argument is a file name")
            case .launchFailed(let message):
                message
            }
        }
    }

    /// User's saved preferred external editor app on macOS, if configured and still installed.
    static var preferredEditorApp: ExternalApp? {
        guard let path = SettingsStore.shared.value(Settings.Transfer.fileManagerExternalEditorPath),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return makeApp(from: url)
    }

    static func setPreferredEditorApp(_ url: URL?) {
        if let url {
            SettingsStore.shared.set(Settings.Transfer.fileManagerExternalEditorPath, url.standardizedFileURL.path)
        } else {
            SettingsStore.shared.reset(Settings.Transfer.fileManagerExternalEditorPath)
        }
    }

    /// Candidate applications for "Open With", default first, excluding Rootshell itself.
    static func availableApps(for fileURL: URL, includePlainText: Bool = true) -> [ExternalApp] {
        guard let workspace = sharedWorkspace() else { return [] }

        var urls: [URL] = []
        if let direct = performURLArray(workspace, selector: "URLsForApplicationsToOpenURL:", arg: fileURL as NSURL) {
            urls.append(contentsOf: direct)
        }
        if includePlainText,
           let plainText = performURLArray(workspace, selector: "URLsForApplicationsToOpenContentType:", arg: UTType.plainText as AnyObject) {
            urls.append(contentsOf: plainText)
        }

        let defaultURL = resolvedDefaultAppURL(for: fileURL, workspace: workspace, fallbackToPlainText: includePlainText)?
            .standardizedFileURL

        var seen: Set<String> = []
        var apps: [ExternalApp] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            guard !isSelfApp(standardized), seen.insert(standardized.path).inserted else { continue }
            apps.append(makeApp(from: standardized))
        }

        apps.sort { lhs, rhs in
            if lhs.url == defaultURL { return true }
            if rhs.url == defaultURL { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return apps
    }

    /// Default external app for `fileURL`, honoring the user's preferred editor when set
    /// and falling back to the plain-text handler for extensionless configs (.env, Dockerfile).
    static func defaultApp(for fileURL: URL, fallbackToPlainText: Bool = true) -> ExternalApp? {
        if let preferred = preferredEditorApp, !isSelfApp(preferred.url) {
            return preferred
        }
        guard let workspace = sharedWorkspace(),
              let url = resolvedDefaultAppURL(for: fileURL, workspace: workspace, fallbackToPlainText: fallbackToPlainText) else {
            return nil
        }
        return makeApp(from: url)
    }

    /// Opens `fileURL` in `appURL` (or the resolved default editor) and returns the app's display name.
    @discardableResult
    static func open(_ fileURL: URL, withApplication appURL: URL? = nil, fallbackToPlainText: Bool = true) async throws -> String {
        guard let workspace = sharedWorkspace() else { throw BridgeError.workspaceUnavailable }

        let targetAppURL: URL?
        if let appURL, !isSelfApp(appURL) {
            targetAppURL = appURL
        } else if let preferred = preferredEditorApp, !isSelfApp(preferred.url) {
            targetAppURL = preferred.url
        } else {
            targetAppURL = resolvedDefaultAppURL(for: fileURL, workspace: workspace, fallbackToPlainText: fallbackToPlainText)
        }

        guard let targetAppURL else {
            throw BridgeError.noApplicationFound(fileURL.lastPathComponent)
        }

        try await openURLs([fileURL], withApplication: targetAppURL, workspace: workspace)
        return makeApp(from: targetAppURL).name
    }

    /// Reveals `fileURL` in Finder.
    static func revealInFinder(_ fileURL: URL) {
        guard let workspace = sharedWorkspace() else { return }
        let selector = NSSelectorFromString("activateFileViewerSelectingURLs:")
        guard workspace.responds(to: selector) else { return }
        _ = workspace.perform(selector, with: [fileURL] as NSArray)
    }

    // MARK: - Private NSWorkspace helpers

    private static func sharedWorkspace() -> NSObject? {
        guard let cls = NSClassFromString("NSWorkspace") as? NSObject.Type else { return nil }
        return cls.value(forKey: "sharedWorkspace") as? NSObject
    }

    private static func resolvedDefaultAppURL(for fileURL: URL, workspace: NSObject, fallbackToPlainText: Bool) -> URL? {
        if let direct = performURL(workspace, selector: "URLForApplicationToOpenURL:", arg: fileURL as NSURL),
           !isSelfApp(direct) {
            return direct
        }
        guard fallbackToPlainText else { return nil }
        if let plain = performURL(workspace, selector: "URLForApplicationToOpenContentType:", arg: UTType.plainText as AnyObject),
           !isSelfApp(plain) {
            return plain
        }
        if let textEdit = performURL(workspace, selector: "URLForApplicationWithBundleIdentifier:", arg: "com.apple.TextEdit" as NSString) {
            return textEdit
        }
        return nil
    }

    private static func openURLs(_ urls: [URL], withApplication appURL: URL, workspace: NSObject) async throws {
        let selector = NSSelectorFromString("openURLs:withApplicationAtURL:configuration:completionHandler:")
        guard workspace.responds(to: selector),
              let configClass = NSClassFromString("NSWorkspaceOpenConfiguration") as? NSObject.Type,
              let config = configClass.perform(NSSelectorFromString("configuration"))?.takeUnretainedValue() as? NSObject else {
            // Fallback to simple single-URL open if the newer selector isn't reachable.
            let legacy = NSSelectorFromString("openURL:")
            if workspace.responds(to: legacy) {
                _ = workspace.perform(legacy, with: urls.first as NSURL?)
                return
            }
            throw BridgeError.workspaceUnavailable
        }

        let imp = workspace.method(for: selector)
        typealias OpenFunc = @convention(c) (
            NSObject, Selector, NSArray, NSURL, NSObject, (@convention(block) (AnyObject?, NSError?) -> Void)?
        ) -> Void
        let fn = unsafeBitCast(imp, to: OpenFunc.self)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: @convention(block) (AnyObject?, NSError?) -> Void = { _, error in
                if let error {
                    continuation.resume(throwing: BridgeError.launchFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
            fn(workspace, selector, urls as NSArray, appURL as NSURL, config, completion)
        }
    }

    private static func performURL(_ workspace: NSObject, selector name: String, arg: AnyObject) -> URL? {
        let selector = NSSelectorFromString(name)
        guard workspace.responds(to: selector) else { return nil }
        return workspace.perform(selector, with: arg)?.takeUnretainedValue() as? URL
    }

    private static func performURLArray(_ workspace: NSObject, selector name: String, arg: AnyObject) -> [URL]? {
        let selector = NSSelectorFromString(name)
        guard workspace.responds(to: selector) else { return nil }
        return workspace.perform(selector, with: arg)?.takeUnretainedValue() as? [URL]
    }

    private static func isSelfApp(_ appURL: URL) -> Bool {
        if appURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return true }
        if let selfID = Bundle.main.bundleIdentifier,
           let otherID = Bundle(url: appURL)?.bundleIdentifier,
           selfID == otherID {
            return true
        }
        return false
    }

    private static func makeApp(from url: URL) -> ExternalApp {
        let standardized = url.standardizedFileURL
        var displayName = FileManager.default.displayName(atPath: standardized.path)
        if displayName.hasSuffix(".app") {
            displayName = String(displayName.dropLast(4))
        }
        if displayName.isEmpty {
            displayName = standardized.deletingPathExtension().lastPathComponent
        }
        let bundleID = Bundle(url: standardized)?.bundleIdentifier
        return ExternalApp(url: standardized, name: displayName, bundleID: bundleID)
    }
}

/// Mac Catalyst app picker for choosing an external editor application.
struct ExternalAppPickerSheet: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.application], asCopy: false)
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        let onCancel: () -> Void

        init(onPicked: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPicked(url)
            } else {
                onCancel()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

#endif

/// iOS / iPadOS / visionOS document picker that moves a staged remote file to an external
/// editor's folder or iCloud Drive (`asCopy: false`) and returns its live security-scoped URL
/// so Rootshell can watch edits via NSFilePresenter and auto-upload on save.
struct ExternalEditExportPicker: UIViewControllerRepresentable {
    let stagedURL: URL
    let onPicked: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [stagedURL], asCopy: false)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        let onCancel: () -> Void

        init(onPicked: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPicked(url)
            } else {
                onCancel()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

/// System Share / Open-In sheet for handing one or more local files or a folder to another app.
struct ExternalFileActivitySheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
