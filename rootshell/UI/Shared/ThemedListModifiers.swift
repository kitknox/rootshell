import SwiftUI

/// Hides the default scroll content background when sheet theme colors are active.
/// Apply to Form or List views that should adopt the themed background.
struct ThemedListStyle: ViewModifier {
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    func body(content: Content) -> some View {
        if let sheetThemeColors {
            content
                .scrollContentBackground(.hidden)
                .background(sheetThemeColors.background.ignoresSafeArea())
        } else {
            content
        }
    }
}

/// Applies a themed row background when sheet theme colors are active.
/// Apply to content inside Section blocks.
struct ThemedRowBackground: ViewModifier {
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    func body(content: Content) -> some View {
        if let sheetThemeColors {
            content.listRowBackground(sheetThemeColors.rowBackground)
        } else {
            content
        }
    }
}

/// Applies sheet theme environment, tint, and color scheme.
/// Always applies modifiers to maintain stable view identity — passes nil values
/// when theming is off so SwiftUI properly reverts to system defaults.
struct ThemedSheetContent: ViewModifier {
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?

    func body(content: Content) -> some View {
        content
            .environment(\.sheetThemeColors, themeColors)
            .tint(accentColor)
            .optionalPreferredColorScheme(colorScheme)
            #if canImport(UIKit)
            .background {
                if colorScheme == nil { PresentationStyleOverrideReset() }
            }
            #endif
    }
}

#if canImport(UIKit)
/// SwiftUI turns a sheet's `preferredColorScheme` into style overrides on the
/// presented controller and its presentation controller, and leaves both when
/// the preference goes away, so turning themed UI off kept the theme's scheme.
/// Clears them so the sheet follows the window's appearance override again.
private struct PresentationStyleOverrideReset: UIViewRepresentable {
    func makeUIView(context: Context) -> ResetView {
        let view = ResetView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ResetView, context: Context) {}

    final class ResetView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // After the SwiftUI update that dropped the preference.
            DispatchQueue.main.async { [weak self] in self?.reset() }
        }

        private func reset() {
            var responder = next
            while let current = responder {
                if let controller = current as? UIViewController,
                   controller.presentingViewController?.presentedViewController === controller {
                    if controller.overrideUserInterfaceStyle != .unspecified {
                        controller.overrideUserInterfaceStyle = .unspecified
                    }
                    if let presentation = controller.presentationController,
                       presentation.traitOverrides.contains(UITraitUserInterfaceStyle.self) {
                        presentation.traitOverrides.remove(UITraitUserInterfaceStyle.self)
                    }
                    return
                }
                responder = current.next
            }
        }
    }
}
#endif

extension View {
    func themedList() -> some View { modifier(ThemedListStyle()) }
    func themedRow() -> some View { modifier(ThemedRowBackground()) }

    @ViewBuilder
    func optionalPreferredColorScheme(_ colorScheme: ColorScheme?) -> some View {
        if let colorScheme {
            preferredColorScheme(colorScheme)
        } else {
            self
        }
    }

    @ViewBuilder
    func optionalColorSchemeEnvironment(_ colorScheme: ColorScheme?) -> some View {
        if let colorScheme {
            environment(\.colorScheme, colorScheme)
        } else {
            self
        }
    }

    /// Apply themed sheet styling. When themeColors is nil (theming off),
    /// no tint or colorScheme overrides are applied, preserving system defaults.
    func themedSheet(
        themeColors: SheetThemeColors?,
        accentColor: Color?,
        colorScheme: ColorScheme?
    ) -> some View {
        modifier(ThemedSheetContent(
            themeColors: themeColors,
            accentColor: accentColor,
            colorScheme: colorScheme
        ))
    }

    /// Convenience for sub-sheets that inherit theme from parent environment.
    /// Derives the color scheme from the SheetThemeColors background color.
    func themedSubSheet(_ themeColors: SheetThemeColors?) -> some View {
        let colorScheme: ColorScheme? = themeColors.map { $0.background.isLight ? .light : .dark }
        return modifier(ThemedSheetContent(
            themeColors: themeColors,
            accentColor: themeColors?.accentColor,
            colorScheme: colorScheme
        ))
    }
}
