//
//  PushAgentLogoAttachment.swift
//  RootshellPushKit
//
//  Pre-rendered agent artwork for hook-notification thumbnails. Shipped as
//  package resources so the notification extension never opens the app's
//  asset catalog. Best-effort: a missing file must never prevent delivery.
//

import Foundation
import UserNotifications

public enum PushAgentLogoAttachment {
    private static let assetNames = [
        "claude-code": "ClaudeLogo",
        "codex": "CodexLogo",
        "pi": "PiLogo",
        "omp": "OMPLogo",
    ]

    static func assetName(for agent: String?) -> String? {
        agent.flatMap { assetNames[$0] }
    }

    static func resourceURL(for agent: String?) -> URL? {
        assetName(for: agent).flatMap { Bundle.module.url(forResource: $0, withExtension: "png") }
    }

    /// Copies the matching PNG to a temporary path (the system takes ownership
    /// of an attachment's file) and wraps it as a notification attachment.
    public static func attachment(
        for agent: String?,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> UNNotificationAttachment? {
        guard let agent, let source = resourceURL(for: agent) else { return nil }
        let directory = temporaryDirectory.appendingPathComponent("rootshell-notification-logos", isDirectory: true)
        let url = directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: url)
            return try UNNotificationAttachment(identifier: "agent-logo-\(agent)", url: url)
        } catch {
            return nil
        }
    }
}
