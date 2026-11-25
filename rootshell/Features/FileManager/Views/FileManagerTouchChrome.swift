//
//  FileManagerTouchChrome.swift
//  rootshell
//
//  The file manager's touch controls for the active pane: a bottom bar in
//  thumb reach, or the side rail where the display has one. Both show
//  navigation, or the selection's actions while selecting.
//

import SwiftUI

/// Which controls a file manager layout carries.
enum FileManagerChrome {
    /// Hardware keyboard or Mac: per-pane navigation buttons and key hints.
    case pointer
    /// Touch: one location row per pane and a bottom bar for the active pane.
    case touch
    /// Touch beside a side rail, which carries the bar's actions.
    case rail
}

enum FileManagerInput {
    /// Click and cursor semantics; touch taps open and multi-select needs Select mode.
    static var usesPointerSemantics: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return KeyboardTracker.shared.isHardwareKeyboard
        #endif
    }
}

enum FileManagerTouchAction {
    /// One Back on touch: history first, then the parent folder. Separate
    /// Up and Forward stay with the keyboard layout.
    case back, refresh, select
    case done, selectAll, copy, move, delete

    static func isSelecting(_ pane: FilePaneModel) -> Bool {
        pane.isSelecting || (!FileManagerInput.usesPointerSemantics && !pane.selection.isEmpty)
    }

    /// The rail's fixed slots. A slot swaps its action rather than the rail
    /// swapping items, which UIKit can drop during a remount. Browsing fills
    /// the first three; the last two are hidden until selecting.
    static func railSlots(selecting: Bool) -> [Self?] {
        selecting ? [.done, .selectAll, .copy, .move, .delete] : [.select, .back, .refresh, nil, nil]
    }

    /// The folder Back leads to, by name.
    static func backDestinationName(_ pane: FilePaneModel) -> String? {
        guard let target = pane.touchBackTarget else { return nil }
        return target == "/" ? "/" : (target as NSString).lastPathComponent
    }

    var title: String {
        switch self {
        case .back: FileManagerShortcut.shortcut(for: .back).title
        case .refresh: FileManagerShortcut.shortcut(for: .refresh).title
        case .select: String(localized: "Select", comment: "File manager: enter selection mode")
        case .done: String(localized: "Done", comment: "File manager: leave selection mode")
        case .selectAll: FileManagerShortcut.shortcut(for: .selectAll).title
        case .copy: FileManagerShortcut.shortcut(for: .copyToOther).title
        case .move: FileManagerShortcut.shortcut(for: .moveToOther).title
        case .delete: FileManagerShortcut.shortcut(for: .delete).title
        }
    }

    var systemImage: String {
        switch self {
        case .back: "chevron.left"
        case .refresh: "arrow.clockwise"
        case .select: "checkmark.circle"
        case .done: "checkmark.circle.fill"
        case .selectAll: "checklist.checked"
        case .copy: "doc.on.doc"
        case .move: "arrow.right.doc.on.clipboard"
        case .delete: "trash"
        }
    }

    var role: ButtonRole? { self == .delete ? .destructive : nil }

    func isEnabled(_ pane: FilePaneModel) -> Bool {
        switch self {
        case .back: pane.touchBackTarget != nil
        case .refresh: !pane.isBusy
        case .select, .selectAll: !pane.visibleEntries.isEmpty
        case .done: true
        case .copy, .move, .delete: !pane.selection.isEmpty
        }
    }

    /// Acts on `side` (making it active), else on the active pane.
    func perform(in manager: FileManagerModel, side: FilePaneModel.Side? = nil) {
        if let side { manager.activeSide = side }
        let pane = manager.activePane
        switch self {
        case .back: pane.goBackOrUp()
        case .refresh: pane.refresh()
        case .select: pane.isSelecting = true
        case .done:
            pane.isSelecting = false
            pane.selection.clear()
        case .selectAll:
            pane.isSelecting = true
            pane.selection.selectAll(pane.visibleRowIDs)
        case .copy, .move:
            manager.transferToOther(move: self == .move)
            pane.isSelecting = false
        case .delete:
            let entries = pane.actionEntries
            if !entries.isEmpty { manager.sheet = .confirmDelete(entries) }
        }
    }
}

/// The bottom bar under a touch layout: one for the active pane, or one
/// under each pane when two sit side by side.
struct FileManagerTouchBar: View {
    let manager: FileManagerModel
    var side: FilePaneModel.Side?

    var body: some View {
        let pane = manager.pane(side ?? manager.activeSide)
        HStack(spacing: 0) {
            if FileManagerTouchAction.isSelecting(pane) {
                textButton(.done, pane: pane)
                Text("\(pane.selection.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.leading, 4)
                Spacer(minLength: 4)
                iconButton(.selectAll, pane: pane)
                iconButton(.copy, pane: pane)
                iconButton(.move, pane: pane)
                iconButton(.delete, pane: pane)
            } else {
                backButton(pane: pane)
                Spacer(minLength: 4)
                iconButton(.refresh, pane: pane)
                textButton(.select, pane: pane)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
    }

    /// Named like a navigation back button, so it says where it goes.
    private func backButton(pane: FilePaneModel) -> some View {
        let destination = FileManagerTouchAction.backDestinationName(pane)
        return Button {
            FileManagerTouchAction.back.perform(in: manager, side: side)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: FileManagerTouchAction.back.systemImage)
                    .font(.body.weight(.semibold))
                Text(verbatim: destination ?? FileManagerTouchAction.back.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 220, alignment: .leading)
            .panelTouchTarget()
        }
        .disabled(destination == nil)
        .accessibilityLabel(destination.map {
            String(localized: "Back to \($0)", comment: "File manager touch back button; argument is a folder name")
        } ?? FileManagerTouchAction.back.title)
    }

    private func iconButton(_ action: FileManagerTouchAction, pane: FilePaneModel) -> some View {
        Button(role: action.role) {
            action.perform(in: manager, side: side)
        } label: {
            Image(systemName: action.systemImage)
                .font(.body.weight(.medium))
                .panelTouchTarget()
        }
        .disabled(!action.isEnabled(pane))
        .accessibilityLabel(action.title)
    }

    private func textButton(_ action: FileManagerTouchAction, pane: FilePaneModel) -> some View {
        Button {
            action.perform(in: manager, side: side)
        } label: {
            Text(action.title)
                .fontWeight(action == .done ? .semibold : .regular)
                .padding(.horizontal, 10)
                .panelTouchTarget()
        }
        .disabled(!action.isEnabled(pane))
    }
}

#if !targetEnvironment(macCatalyst) && !os(visionOS)
/// The file manager's actions as side-rail items, for the window's rail or a sheet's own.
@available(iOS 27.1, *)
struct FileManagerRailItems: ToolbarContent {
    let manager: FileManagerModel
    var presentation: PanelPresentation?
    var onSwitchPresentation: ((PanelPresentation) -> Void)?
    let onClose: () -> Void

    var body: some ToolbarContent {
        // A gap sets the panel's items apart from the window's own.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onClose) {
                Label(String(localized: "Close File Manager", comment: "File manager close button"), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
        }
        .visibilityPriority(.high)
        slot(0).visibilityPriority(.high)
        slot(1).visibilityPriority(.high)
        slot(2).visibilityPriority(.high)
        // Selection-only slots leave the rail while browsing.
        if FileManagerTouchAction.isSelecting(manager.activePane) {
            slot(3)
            slot(4)
        }
        ToolbarItem(placement: .topBarTrailing) {
            FileManagerMoreMenu(manager: manager)
                .equatable()
        }
        if let presentation, let onSwitchPresentation {
            ToolbarItem(placement: .topBarTrailing) {
                PanelPresentationMenu(current: presentation, onSwitch: onSwitchPresentation)
                    .equatable()
            }
            .visibilityPriority(.low)
        }
    }

    private func slot(_ index: Int) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            FileManagerRailSlot(manager: manager, index: index)
        }
    }
}

private struct FileManagerRailSlot: View {
    let manager: FileManagerModel
    let index: Int

    var body: some View {
        let pane = manager.activePane
        if let action = FileManagerTouchAction.railSlots(selecting: FileManagerTouchAction.isSelecting(pane))[index] {
            Button(role: action.role) {
                action.perform(in: manager)
            } label: {
                Label(action == .back ? backTitle(pane) : action.title, systemImage: action.systemImage)
            }
            .labelStyle(.iconOnly)
            .disabled(!action.isEnabled(pane))
        }
    }

    private func backTitle(_ pane: FilePaneModel) -> String {
        FileManagerTouchAction.backDestinationName(pane).map {
            String(localized: "Back to \($0)", comment: "File manager touch back button; argument is a folder name")
        } ?? FileManagerTouchAction.back.title
    }
}
#endif

/// The phone sheet's own rail, inside `PanelSheetNavigation`.
struct FileManagerSheetRail: ViewModifier {
    let active: Bool
    let manager: FileManagerModel
    let onClose: () -> Void

    func body(content: Content) -> some View {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *) {
            content.panelSheetRail(active) {
                FileManagerRailItems(manager: manager, onClose: onClose)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
