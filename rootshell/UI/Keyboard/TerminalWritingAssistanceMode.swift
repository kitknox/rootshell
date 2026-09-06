import Foundation

nonisolated enum TerminalWritingAssistanceMode: String, Codable, CaseIterable, Hashable, Sendable {
    case off, suggestions, autocorrect

    /// Stable feature identity for the toolbar and customization palette.
    /// Mode-specific icons belong only to the choices inside the menu.
    static let toolbarIcon = "textformat.abc"

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .suggestions: String(localized: "Suggestions")
        case .autocorrect: String(localized: "Autocorrect")
        }
    }

    var icon: String {
        switch self {
        case .off: "textformat.abc.dottedunderline"
        case .suggestions: "textformat.abc"
        case .autocorrect: "wand.and.stars"
        }
    }
}
