//
//  EdgeSidebarTabBar.swift
//  rootshell
//
//  The selected tool and the menu of tools assigned to its edge.
//

import SwiftUI

struct EdgeSidebarTitleContext {
    let pages: [EdgeSidebarPage]
    let selection: EdgeSidebarPage
    let side: EdgeSidebarSide
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onSelect: (EdgeSidebarPage) -> Void
}

private struct EdgeSidebarTitleContextKey: EnvironmentKey {
    static let defaultValue: EdgeSidebarTitleContext? = nil
}

extension EnvironmentValues {
    var edgeSidebarTitleContext: EdgeSidebarTitleContext? {
        get { self[EdgeSidebarTitleContextKey.self] }
        set { self[EdgeSidebarTitleContextKey.self] = newValue }
    }
}

struct EdgeSidebarTitleMenu: View {
    @Environment(\.edgeSidebarTitleContext) private var context

    let title: String
    let systemImage: String
    var status: String? = nil
    var statusColor: Color = .secondary

    var body: some View {
        if let context {
            if context.pages.count > 1 {
                Menu {
                    EdgeSidebarToolPicker(context: context)
                } label: {
                    titleLabel(context.selection.title, icon: context.selection.systemImage, showsMenu: true, status: status)
                        .frame(minHeight: 44)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(String(localized: "Sidebar Tool"))
                .accessibilityValue(context.selection.title)
            } else {
                titleLabel(context.selection.title, icon: context.selection.systemImage, showsMenu: false, status: status)
            }
        } else {
            titleLabel(title, icon: systemImage, showsMenu: false)
        }
    }

    @ViewBuilder
    private func titleLabel(_ title: String, icon: String, showsMenu: Bool, status: String? = nil) -> some View {
        if let status {
            VStack(alignment: .leading, spacing: 0) {
                titleLine(title, icon: icon, showsMenu: showsMenu)
                statusLine(status)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        } else {
            titleLine(title, icon: icon, showsMenu: showsMenu)
        }
    }

    private func statusLine(_ status: String) -> some View {
        Text(status)
            .font(.caption)
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func titleLine(_ title: String, icon: String, showsMenu: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                if showsMenu {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                if showsMenu {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

struct EdgeSidebarToolPicker: View {
    let context: EdgeSidebarTitleContext

    var body: some View {
        Picker(String(localized: "Sidebar Tool"), selection: Binding(
            get: { context.selection },
            set: context.onSelect
        )) {
            ForEach(context.pages, id: \.self) { page in
                Label(page.title, systemImage: page.systemImage).tag(page)
            }
        }
    }
}

struct EdgeSidebarHeader<Actions: View>: View {
    @Environment(\.sheetThemeColors) private var themeColors
    @Environment(\.edgeSidebarTitleContext) private var sidebarContext

    let title: String
    let systemImage: String
    var status: String? = nil
    var statusColor: Color = .secondary
    var onBack: (() -> Void)? = nil
    var showsClose = true
    var isCloseEnabled = true
    let onClose: () -> Void
    private let actions: Actions

    init(
        title: String,
        systemImage: String,
        status: String? = nil,
        statusColor: Color = .secondary,
        onBack: (() -> Void)? = nil,
        showsClose: Bool = true,
        isCloseEnabled: Bool = true,
        onClose: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.status = status
        self.statusColor = statusColor
        self.onBack = onBack
        self.showsClose = showsClose
        self.isCloseEnabled = isCloseEnabled
        self.onClose = onClose
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            headerRow
            compactHeader
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 8)
        .background(themeColors?.background)
    }

    private var headerRow: some View {
        HStack(spacing: 4) {
            titleRow
            Spacer(minLength: 0)
            headerActions
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleRow
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                headerActions
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 4) {
            if let onBack {
                headerButton("chevron.backward", accessibilityLabel: String(localized: "Back"), action: onBack)
            }
            EdgeSidebarTitleMenu(title: title, systemImage: systemImage, status: status, statusColor: statusColor)
                .frame(minWidth: 150, minHeight: 44, alignment: .leading)
                .layoutPriority(1)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 4) {
            #if !targetEnvironment(macCatalyst) && !os(visionOS)
            if let sidebarContext {
                Button(action: sidebarContext.onTogglePin) {
                    Image(systemName: sidebarContext.isPinned ? "pin.slash" : "pin")
                        .font(.title3)
                        .foregroundStyle(sidebarContext.isPinned ? Color.accentColor : .secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: sidebarContext.isPinned ? "Unpin Sidebar" : "Pin Sidebar"))
                .accessibilityValue(String(localized: sidebarContext.isPinned ? "Pinned" : "Not pinned"))
                .help(String(localized: sidebarContext.isPinned ? "Unpin Sidebar" : "Pin Sidebar"))
            }
            #endif
            actions
                .fixedSize()
                .frame(minHeight: 44)
            if showsClose {
                headerButton("xmark.circle.fill", accessibilityLabel: String(localized: "Close \(title)"), action: onClose)
                    .disabled(!isCloseEnabled)
            }
        }
    }

    private func headerButton(
        _ systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

extension View {
    func edgeSidebarHeaderActionTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}
