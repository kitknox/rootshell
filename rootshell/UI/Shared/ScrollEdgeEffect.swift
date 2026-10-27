import SwiftUI

enum ScrollEdgeEffectMode: String, CaseIterable, Codable, Identifiable {
    case hard
    case soft
    case hidden

    var id: Self { self }

    var displayName: String {
        switch self {
        case .hard: return String(localized: "Hard", comment: "Scroll edge effect: opaque band")
        case .soft: return String(localized: "Soft", comment: "Scroll edge effect: fade under bars")
        case .hidden: return String(localized: "Hidden", comment: "Scroll edge effect: no band")
        }
    }

    func terminalUnderlapsTopChrome(bandOpacity: Double) -> Bool {
        switch self {
        case .hard: return bandOpacity < 1
        case .soft, .hidden: return true
        }
    }
}

struct ScrollEdgeEffectModifier: ViewModifier {
    @Setting(Settings.Theme.scrollEdgeEffect) private var mode

    func body(content: Content) -> some View {
        #if os(visionOS)
        content
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            switch mode {
            case .hard: content.scrollEdgeEffectStyle(.hard, for: .all)
            case .soft: content.scrollEdgeEffectStyle(.soft, for: .all)
            case .hidden: content.scrollEdgeEffectHidden(true, for: .all)
            }
        } else {
            content
        }
        #endif
    }
}
