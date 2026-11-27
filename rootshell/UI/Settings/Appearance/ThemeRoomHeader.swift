//
//  ThemeRoomHeader.swift
//  rootshell
//
//  The room card at the top of Settings → Theme. It collapses into a slim
//  band as the theme list scrolls, and repaints itself when the theme changes.
//

import SwiftUI

struct ThemeRoomHeader: View {
    let theme: ThemeManager.ThemeInfo?
    /// 0 is the full room, 1 the slim band.
    let collapse: Double
    let expandedHeight: CGFloat
    let collapsedHeight: CGFloat
    /// Sun or moon when picking a Day or Night theme.
    let slotSymbol: String?
    let onLocate: () -> Void
    /// Tapping or pinching the room opens or closes it in place.
    let onTap: () -> Void
    let onPinch: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardWidth: CGFloat = 0
    @State private var current: ThemeRoomState?
    @State private var previous: ThemeRoomState?
    /// Counts repaints. Each change animates it up by one from `paintStart`; setting
    /// 0 then animating to 1 in one update would coalesce and never animate.
    @State private var paint = 0.0
    @State private var paintStart = 0.0
    @State private var changedAt = Date.distantPast

    private var height: CGFloat { expandedHeight + (collapsedHeight - expandedHeight) * collapse }
    private var radius: CGFloat { 18 - 4 * collapse }

    var body: some View {
        ZStack(alignment: .top) {
            if let current {
                ThemeRoomCanvas(from: previous, to: current, paint: paint, paintStart: paintStart, reduceMotion: reduceMotion)
                    .frame(height: expandedHeight)
                    // The band shows the middle of the room: window, art, sofa back.
                    .offset(y: -ThemeRoomScene.bandOffset(size: CGSize(width: cardWidth, height: expandedHeight),
                                                         band: collapsedHeight) * collapse)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) { nameChip.padding(10) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .simultaneousGesture(MagnifyGesture().onEnded { onPinch($0.magnification) })
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Show or Hide Room"), onTap)
        .onAppear { if current == nil { current = theme.map { Self.state($0) } } }
        .onChange(of: theme?.id) { _, _ in repaint() }
    }

    private var nameChip: some View {
        HStack(spacing: 6) {
            if let slotSymbol {
                Image(systemName: slotSymbol)
                    .foregroundStyle(slotSymbol.hasPrefix("sun") ? Color.orange : Color.indigo)
            }
            Text(theme?.displayName ?? "")
                .lineLimit(1)
                .contentTransition(.opacity)
            Button(action: onLocate) {
                Image(systemName: "scope")
                    .padding(.leading, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Show Current Theme in List"))
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, (current?.palette.isLight ?? false) ? .light : .dark)
        .animation(.easeInOut(duration: 0.25), value: theme?.id)
    }

    private func repaint() {
        guard let theme else { return }
        let next = Self.state(theme)
        guard next != current else { return }
        // Mid-change, start from whichever room is mostly showing.
        let showing = Date().timeIntervalSince(changedAt) < Self.paintDuration / 2 ? previous : current
        if reduceMotion || showing == nil {
            previous = nil
            current = next
            return
        }
        previous = showing
        current = next
        changedAt = Date()
        paintStart = paint.rounded(.up)
        withAnimation(.easeInOut(duration: Self.paintDuration)) { paint = paintStart + 1 }
    }

    private static let paintDuration = 1.5

    private static func state(_ theme: ThemeManager.ThemeInfo) -> ThemeRoomState {
        let colors = theme.colors
        let palette = ThemeRoomPalette(background: colors.background, foreground: colors.foreground,
                                       cursor: colors.cursor, palette: colors.palette)
        return ThemeRoomState(palette: palette, room: ThemeRoom(name: theme.name, isLight: palette.isLight))
    }
}

/// SwiftUI interpolates `paint`; the timeline adds the room's ambient life.
private struct ThemeRoomCanvas: View, Animatable {
    let from: ThemeRoomState?
    let to: ThemeRoomState
    var paint: Double
    let paintStart: Double
    let reduceMotion: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var animatableData: Double {
        get { paint }
        set { paint = newValue }
    }

    var body: some View {
        let from = from, to = to, reduceMotion = reduceMotion
        let progress = min(max(paint - paintStart, 0), 1)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isVisible || scenePhase != .active)) { timeline in
            let time = reduceMotion ? 3.4 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { context, size in
                ThemeRoomScene.draw(&context, size: size, from: from, to: to, progress: progress, time: time, reduceMotion: reduceMotion)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}
