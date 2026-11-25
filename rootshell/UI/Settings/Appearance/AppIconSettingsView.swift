import SwiftUI
import UIKit

/// Lets the user pick between the primary and alternate app icons. Hidden on
/// platforms where `UIApplication.supportsAlternateIcons` is false (visionOS).
struct AppIconSettingsView: View {
    @ObservedObject private var iconManager = AppIconManager.shared

    var body: some View {
        List {
            Section {
                AppIconGrid(variants: AppIconManager.AppIconVariant.standardVariants)
            } header: {
                Text(String(
                    localized: "Standard",
                    comment: "Settings section title: the standard app icons"
                ))
            }

            Section {
                AppIconGrid(variants: AppIconManager.AppIconVariant.radicalOfTheUnknownVariants)
            } header: {
                Text(String(
                    localized: "Radical of the Unknown",
                    comment: "Settings section title: Radical of the Unknown app icon collection"
                ))
            } footer: {
                Text(String(
                    localized: "Changes the home-screen icon. Updates here also apply to the animated icon in Settings and the Live Activity widget.",
                    comment: "Footer explaining what the app icon picker affects"
                ))
            }
        }
        .themedList()
        .sensoryFeedback(.selection, trigger: iconManager.selectedVariant)
        .navigationTitle(String(localized: "App Icon", comment: "Settings navigation title: app icon picker"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsScreenPinMenu(groups: [.theme]) }
    }
}

/// One list row holding a grid of icon tiles; columns follow the row width.
private struct AppIconGrid: View {
    let variants: [AppIconManager.AppIconVariant]
    @ScaledMetric(relativeTo: .caption) private var minimumTileWidth: CGFloat = 80

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumTileWidth), spacing: 8, alignment: .top)],
            spacing: 14
        ) {
            ForEach(variants) { variant in
                AppIconTile(variant: variant)
            }
        }
        .padding(.vertical, 10)
        .themedRow()
    }
}

private struct AppIconTile: View {
    @ObservedObject private var iconManager = AppIconManager.shared
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 60
    let variant: AppIconManager.AppIconVariant

    private var isSelected: Bool { iconManager.selectedVariant == variant }

    private var rowBackground: Color {
        sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground)
    }

    var body: some View {
        Button {
            iconManager.selectedVariant = variant
        } label: {
            VStack(spacing: 6) {
                Image(variant.previewAssetName)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
                    .padding(4)
                    .overlay {
                        // Ring radius tracks the preview's baked-in squircle plus the padding.
                        RoundedRectangle(cornerRadius: iconSize * 0.2237 + 4, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            .opacity(isSelected ? 1 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.system(size: 20, weight: .semibold))
                                .background(Circle().fill(rowBackground).padding(-2))
                                .offset(x: 6, y: -6)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                Text(variant.displayName)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(variant.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
