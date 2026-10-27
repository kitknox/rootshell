import SwiftUI

enum StatusBarVisibility: String, CaseIterable, Codable, Identifiable {
    case always
    case whileScrolling

    var id: Self { self }

    var displayName: String {
        switch self {
        case .always: return String(localized: "Always", comment: "Status bar visibility: always shown")
        case .whileScrolling: return String(localized: "While Scrolling", comment: "Status bar visibility: shown in scrollback")
        }
    }
}

#if os(iOS)
struct ScrollbackStatusBarModifier: ViewModifier {
    let focusedTerminal: Ghostty.TerminalView?

    @Setting(Settings.Window.statusBar) private var visibility
    @State private var showsScrollback = false
    @State private var hideAfterReturn: Task<Void, Never>?
    @State private var topInsetWithStatusBar: CGFloat = 0
    @State private var topInset: CGFloat = 0

    private static let hideDelay: Duration = .milliseconds(400)

    private var hidesStatusBar: Bool {
        visibility == .whileScrolling && !showsScrollback
    }

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.top, hidesStatusBar ? max(0, topInsetWithStatusBar - topInset) : 0)
            .statusBarHidden(hidesStatusBar)
            .animation(.easeInOut(duration: 0.2), value: hidesStatusBar)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { top in
                topInset = top
                if !hidesStatusBar { topInsetWithStatusBar = top }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidUpdateScrollbar)) { notification in
                guard let terminal = notification.object as? Ghostty.TerminalView,
                      terminal === focusedTerminal else { return }
                follow(terminal)
            }
            .onChange(of: focusedTerminal.map(ObjectIdentifier.init), initial: true) {
                follow(focusedTerminal)
            }
    }

    private func follow(_ terminal: Ghostty.TerminalView?) {
        let inScrollback = terminal.map {
            $0.scrollbarTotal != 0 && $0.scrollbarOffset + $0.scrollbarLen < $0.scrollbarTotal
        } ?? false
        hideAfterReturn?.cancel()
        if inScrollback {
            showsScrollback = true
            return
        }
        hideAfterReturn = Task {
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled else { return }
            showsScrollback = false
        }
    }
}
#endif
