import SwiftUI

extension View {
    /// Shared glass surface for floating pickers. Glass supplies its own
    /// elevation; the manual shadow belongs only to the pre-26 fallback.
    func floatingHUDPanelBackground() -> some View {
        modifier(FloatingHUDPanelBackground())
    }
}

private struct FloatingHUDPanelBackground: ViewModifier {
    @Environment(\.edgeSidebarTitleContext) private var sidebarContext

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        #if os(visionOS)
        content.background(.regularMaterial, in: shape)
        #else
        if sidebarContext != nil && !SettingsPlatform.isCatalyst {
            content
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 10)
        }
        #endif
    }
}
