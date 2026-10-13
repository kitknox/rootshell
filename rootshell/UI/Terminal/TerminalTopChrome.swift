import UIKit

extension Notification.Name {
    static let terminalTopChromeChanged = Notification.Name("com.rootshell.terminalTopChromeChanged")
}

@MainActor
enum TerminalTopChrome {
    private static var heightByWindowID: [String: CGFloat] = [:]

    static func height(forWindow windowID: String) -> CGFloat {
        heightByWindowID[windowID] ?? 0
    }

    static func setHeight(_ height: CGFloat, forWindow windowID: String) {
        guard Self.height(forWindow: windowID) != height else { return }
        heightByWindowID[windowID] = height > 0 ? height : nil
        NotificationCenter.default.post(name: .terminalTopChromeChanged, object: windowID)
    }
}
