//
//  GitDiffTouchChrome.swift
//  rootshell
//
//  The git diff panel's actions as standalone controls, shared by its toolbar
//  row and the side rail that carries them on a rail display.
//

import SwiftUI

struct GitDiffExpandAllButton: View {
    let store: GitDiffStore
    var touchSized = false

    var body: some View {
        let collapsed = store.allCollapsed
        let title = collapsed
            ? String(localized: "Expand All Files", comment: "Git diff toolbar button")
            : String(localized: "Collapse All Files", comment: "Git diff toolbar button")
        Button {
            store.setAllExpanded(collapsed)
        } label: {
            Label(title, systemImage: collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                .labelStyle(.iconOnly)
                .panelTouchTarget(touchSized)
        }
        .disabled(store.snapshot?.isClean ?? true)
        .help(title)
    }
}

struct GitDiffRefreshButton: View {
    let store: GitDiffStore
    var touchSized = false

    var body: some View {
        Button {
            store.refresh()
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(store.isRefreshing ? 0 : 1)
                if store.isRefreshing { ProgressView().controlSize(.small) }
            }
            .panelTouchTarget(touchSized)
        }
        .help(String(localized: "Refresh", comment: "Git diff toolbar tooltip"))
        .accessibilityLabel(String(localized: "Refresh", comment: "Git diff toolbar button"))
    }
}

struct GitDiffOptionsButton: View {
    let store: GitDiffStore
    var touchSized = false

    @Setting(Settings.GitDiff.wrapLines) private var wrapLines

    var body: some View {
        GitDiffOptionsMenu(
            wrapLines: wrapLines,
            ignoreWhitespace: store.ignoreWhitespace,
            touchSized: touchSized,
            onWrap: { wrapLines = $0 },
            onIgnoreWhitespace: { store.setIgnoreWhitespace($0) })
            .equatable()
    }
}

#if !targetEnvironment(macCatalyst) && !os(visionOS)
/// The panel's actions as side-rail items, for the window's rail or a sheet's own.
@available(iOS 27.1, *)
struct GitDiffRailItems: ToolbarContent {
    let store: GitDiffStore
    var presentation: PanelPresentation?
    var onSwitchPresentation: ((PanelPresentation) -> Void)?
    var onCollapse: (() -> Void)?
    let onClose: () -> Void

    var body: some ToolbarContent {
        // A gap sets the panel's items apart from the window's own.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onClose) {
                Label(String(localized: "Close Git Diff", comment: "Git diff close button"), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
        }
        .visibilityPriority(.high)
        if let onCollapse {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onCollapse) {
                    Label(String(localized: "Show Summary Only", comment: "Git diff panel button"),
                          systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .labelStyle(.iconOnly)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            GitDiffRailFilesMenu(store: store)
        }
        .visibilityPriority(.high)
        ToolbarItem(placement: .topBarTrailing) {
            GitDiffExpandAllButton(store: store)
        }
        ToolbarItem(placement: .topBarTrailing) {
            GitDiffOptionsButton(store: store)
        }
        ToolbarItem(placement: .topBarTrailing) {
            GitDiffRefreshButton(store: store)
        }
        if let presentation, let onSwitchPresentation {
            ToolbarItem(placement: .topBarTrailing) {
                PanelPresentationMenu(current: presentation, onSwitch: onSwitchPresentation)
                    .equatable()
            }
            .visibilityPriority(.low)
        }
    }
}

/// A fixed rail slot, so it disables rather than leaving while there is nothing to jump to.
private struct GitDiffRailFilesMenu: View {
    let store: GitDiffStore

    var body: some View {
        let files = store.snapshot?.files ?? []
        GitDiffFilesMenu(files: files) { store.reveal($0) }
            .equatable()
            .disabled(files.count < 2)
    }
}
#endif

/// The phone sheet's own rail, inside `PanelSheetNavigation`.
struct GitDiffSheetRail: ViewModifier {
    let active: Bool
    let store: GitDiffStore
    let onCollapse: () -> Void
    let onClose: () -> Void

    func body(content: Content) -> some View {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *) {
            content.panelSheetRail(active) {
                GitDiffRailItems(store: store, onCollapse: onCollapse, onClose: onClose)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Expand or collapse all, plus the view options, in one menu for a toolbar
/// too narrow to give each its own button.
struct GitDiffMoreButton: View {
    let store: GitDiffStore
    var touchSized = false

    @Setting(Settings.GitDiff.wrapLines) private var wrapLines

    var body: some View {
        GitDiffMoreMenu(
            allCollapsed: store.allCollapsed,
            isClean: store.snapshot?.isClean ?? true,
            wrapLines: wrapLines,
            ignoreWhitespace: store.ignoreWhitespace,
            touchSized: touchSized,
            onToggleAll: { store.setAllExpanded(store.allCollapsed) },
            onWrap: { wrapLines = $0 },
            onIgnoreWhitespace: { store.setIgnoreWhitespace($0) })
            .equatable()
    }
}

/// Equatable so a refresh never rebuilds the menu while it is open.
private struct GitDiffMoreMenu: View, Equatable {
    let allCollapsed: Bool
    let isClean: Bool
    let wrapLines: Bool
    let ignoreWhitespace: Bool
    let touchSized: Bool
    let onToggleAll: () -> Void
    let onWrap: (Bool) -> Void
    let onIgnoreWhitespace: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.allCollapsed == rhs.allCollapsed && lhs.isClean == rhs.isClean && lhs.wrapLines == rhs.wrapLines
            && lhs.ignoreWhitespace == rhs.ignoreWhitespace && lhs.touchSized == rhs.touchSized
    }

    var body: some View {
        Menu {
            Button(action: onToggleAll) {
                Label(allCollapsed
                    ? String(localized: "Expand All Files", comment: "Git diff toolbar button")
                    : String(localized: "Collapse All Files", comment: "Git diff toolbar button"),
                      systemImage: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .disabled(isClean)
            Divider()
            Toggle(isOn: Binding(get: { wrapLines }, set: { onWrap($0) })) {
                Label(String(localized: "Wrap Lines", comment: "Git diff option"), systemImage: "text.word.spacing")
            }
            Toggle(isOn: Binding(get: { ignoreWhitespace }, set: { onIgnoreWhitespace($0) })) {
                Label(String(localized: "Hide Whitespace Changes", comment: "Git diff option"), systemImage: "space")
            }
        } label: {
            Label(String(localized: "More", comment: "Git diff toolbar overflow menu"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .panelTouchTarget(touchSized)
        }
    }
}
