//
//  SavedPasswordsHeaderView.swift
//  rootshell
//
//  Animated header for Settings → Saved Passwords: a vault door, rendered in
//  3D by VaultDoor.metal, unlocks, swings open onto a wall of drawers, and
//  locks again.
//

import SwiftUI

struct SavedPasswordsHeaderView: View {
    let passwordCount: Int
    /// Bumped by the owner (password saved, refresh finished) to replay the sequence.
    let replayTrigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment
    @State private var sequenceStart: Date?
    @State private var width: CGFloat = 0

    /// VaultDoor.metal's `sequenceEnd`; at and past it the door is shut.
    private static let sequenceLength: TimeInterval = 7.2

    /// Same sizing as the SSH keys header. The scene scales with this, not with
    /// the banner's final height, so larger text adds room without zooming in.
    private var artHeight: CGFloat {
        if verticalSizeClass == .compact { return 72 }
        guard width > 0 else { return 92 }
        return min(max(width * 0.22, 84), 116)
    }

    var body: some View {
        let artHeight = artHeight
        label
            // The open door reaches about 1.5 art heights from the leading edge.
            .frame(maxWidth: width > 0 ? max(width - artHeight * 1.55, 120) : 200, alignment: .trailing)
            .padding(.vertical, 12)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, minHeight: artHeight, alignment: .trailing)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background { vault(artHeight: artHeight) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onTapGesture { play() }
            .onChange(of: replayTrigger) { _, _ in play() }
            .onAppear { play() }
            .task(id: sequenceStart) {
                guard let start = sequenceStart else { return }
                do {
                    try await Task.sleep(for: .seconds(Self.sequenceLength - Date.now.timeIntervalSince(start) + 0.1))
                } catch { return }
                sequenceStart = nil
            }
            .accessibilityElement(children: .combine)
    }

    private func vault(artHeight: CGFloat) -> some View {
        let surface = opaque(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
        let accent = opaque(sheetThemeColors?.accentColor ?? Color.accentColor)
        let isLight: Float = colorScheme == .light ? 1 : 0
        // Paused between sequences: the shut door is a still frame.
        return TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: sequenceStart == nil || scenePhase != .active)) { timeline in
            let seq = Float(min(sequenceStart.map { timeline.date.timeIntervalSince($0) } ?? Self.sequenceLength, Self.sequenceLength))
            Rectangle()
                .fill(.white)
                .visualEffect { content, proxy in
                    content.colorEffect(
                        ShaderLibrary.vaultDoor(
                            .float2(artHeight * 0.75, proxy.size.height / 2),
                            .float(artHeight),
                            .float(seq),
                            .color(surface),
                            .color(accent),
                            .float(isLight)
                        )
                    )
                }
        }
    }

    private var label: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Group {
                if passwordCount == 0 {
                    Text("No saved passwords", comment: "Saved passwords header, empty state title")
                } else {
                    // Inflected so English agrees with no catalog work; translations
                    // carry their own plural variations under this key.
                    Text("^[\(passwordCount) password](inflect: true)", comment: "Saved passwords header: number of saved SSH passwords")
                }
            }
            .font(.headline)
            .foregroundStyle(.primary)
            Text(passwordCount == 0
                 ? String(localized: "Save one the next time you connect", comment: "Saved passwords header, empty state")
                 : String(localized: "Stored in the Keychain", comment: "Saved passwords header subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.trailing)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        // Still scales, but stops before the banner outgrows a header; the rows
        // below carry the same information at full size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// The shader paints an opaque wall, so drop any translucency in the row color.
    private func opaque(_ color: Color) -> Color {
        let resolved = color.resolve(in: environment)
        return Color(Color.Resolved(red: resolved.red, green: resolved.green, blue: resolved.blue))
    }

    private func play() {
        guard !reduceMotion, sequenceStart == nil else { return }
        sequenceStart = .now
    }
}
