import SwiftUI

extension MainView {
    var terminalUnderlapsTopChrome: Bool {
        #if targetEnvironment(macCatalyst) || os(visionOS)
        return false
        #else
        guard !roundedPanes, !duoLayout.hasHinge else { return false }
        return scrollEdgeEffect.terminalUnderlapsTopChrome(bandOpacity: scrollEdgeOpacity)
        #endif
    }

    func topChromeHeight(above geometry: GeometryProxy) -> CGFloat {
        terminalUnderlapsTopChrome ? max(0, geometry.frame(in: .global).minY) : 0
    }

    @ViewBuilder
    func topChromeBand(height: CGFloat, theme: ResolvedTabBarTheme) -> some View {
        let chrome = tabBarChromeBackground(theme)
        Group {
            switch scrollEdgeEffect {
            case .hard:
                chrome.opacity(scrollEdgeOpacity)
            case .soft:
                LinearGradient(colors: [chrome, chrome.opacity(0)], startPoint: .top, endPoint: .bottom)
            case .hidden:
                Color.clear
            }
        }
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
