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
                plainTitle(context.selection.title, status: status)
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

    @ViewBuilder
    private func plainTitle(_ title: String, status: String?) -> some View {
        if let status {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                statusLine(status)
            }
            .frame(minHeight: 44, alignment: .leading)
        } else {
            Text(title)
                .font(.headline)
                .lineLimit(1)
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
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            if showsMenu {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
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
        HStack(spacing: 8) {
            if let onBack {
                headerButton("chevron.backward", accessibilityLabel: String(localized: "Back"), action: onBack)
            }

            VStack(alignment: .leading, spacing: 1) {
                EdgeSidebarTitleMenu(title: title, systemImage: systemImage, status: status, statusColor: statusColor)
                    .frame(minHeight: 44, alignment: .leading)
                    .layoutPriority(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 4)
            actions
                .frame(minHeight: 44)
            if showsClose {
                headerButton("xmark.circle.fill", accessibilityLabel: String(localized: "Close \(title)"), action: onClose)
                    .disabled(!isCloseEnabled)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(.horizontal, 12)
        .background(themeColors?.background)
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
