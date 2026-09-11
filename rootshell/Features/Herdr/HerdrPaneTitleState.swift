import Foundation

/// Metadata can seed a pane before its stream reports a title. Once live OSC
/// titles arrive, only that attachment can replace them, including an explicit
/// empty title. Keep the complete string so agent spinners remain animated.
nonisolated struct HerdrPaneTitleState {
    private(set) var attachmentID: UUID?
    private var seedTitle: String?
    private var liveTitle: String?

    var reportedTitle: String? { liveTitle ?? seedTitle }

    mutating func beginAttachment() {
        endAttachment()
        attachmentID = UUID()
    }

    mutating func endAttachment() {
        // Keep the last title visible while reconnecting, but allow fresh
        // metadata to seed the next attachment.
        seedTitle = reportedTitle
        liveTitle = nil
        attachmentID = nil
    }

    mutating func seed(_ title: String?) {
        guard liveTitle == nil else { return }
        seedTitle = title
    }

    @discardableResult
    mutating func receive(_ title: String, from attachmentID: UUID) -> Bool {
        guard self.attachmentID == attachmentID else { return false }
        liveTitle = title
        return true
    }

    func resolvedTitle(override: String?, fallback: String) -> String {
        if let override, !override.isEmpty { return override }
        if let title = reportedTitle, !title.isEmpty { return title }
        return fallback
    }
}
