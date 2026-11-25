//
//  PanelTouchChrome.swift
//  rootshell
//
//  Touch sizing and side-rail hosting shared by the trailing panels. Icon
//  buttons keep their glyph size; only the hit area grows. Where the
//  navigation bar runs as a vertical side rail, panel actions move into it.
//

import SwiftUI

extension View {
    /// Grows an icon button's hit area to the touch minimum without changing its glyph.
    func panelTouchTarget(_ enabled: Bool = true, minWidth: CGFloat = 44, minHeight: CGFloat = 44) -> some View {
        frame(minWidth: enabled ? minWidth : nil, minHeight: enabled ? minHeight : nil)
            .contentShape(Rectangle())
    }
}

#if !targetEnvironment(macCatalyst) && !os(visionOS)
@available(iOS 27.1, *)
extension View {
    /// Shows `items` in a phone sheet's side rail while it has one; the bar stays hidden otherwise.
    /// Only for a view inside `PanelSheetNavigation`: elsewhere it would hide the window's own rail.
    @ViewBuilder
    func panelSheetRail<Items: ToolbarContent>(_ active: Bool, @ToolbarContentBuilder items: () -> Items) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            let built = items()
            toolbarVisibility(active ? .visible : .hidden, for: .navigationBar)
                .toolbar {
                    if active { built }
                }
        } else {
            self
        }
    }
}
#endif

enum PanelTouch {
    /// Panel chrome is sized for fingers everywhere but the Mac.
    static var isTouchPlatform: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        true
        #endif
    }
}

/// A phone sheet's own navigation container, so the sheet gets its own bar.
/// On a side-rail display that bar runs vertically beside the sheet.
struct PanelSheetNavigation<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *), UIDevice.current.userInterfaceIdiom == .phone {
            NavigationStack { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// Whether the nearest navigation bar runs as a vertical side rail. Read
/// inside `PanelSheetNavigation`, it describes the sheet's bar, not the window's.
struct PanelSideRailReader<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *) {
            PanelSideRailEdgeReader(content: content)
        } else {
            content(false)
        }
        #else
        content(false)
        #endif
    }
}

#if !targetEnvironment(macCatalyst) && !os(visionOS)
@available(iOS 27.1, *)
private struct PanelSideRailEdgeReader<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let content: (Bool) -> Content

    var body: some View {
        content(verticalEdge != nil)
    }
}
#endif
