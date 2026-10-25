//
//  EdgeSidebarTabBar.swift
//  rootshell
//
//  The selected tool and the menu of tools assigned to its edge.
//

import SwiftUI

struct EdgeSidebarTabBar: View {
    let pages: [EdgeSidebarPage]
    let selection: EdgeSidebarPage
    let onSelect: (EdgeSidebarPage) -> Void

    var body: some View {
        if !pages.isEmpty {
            Menu {
                Picker(String(localized: "Sidebar Tool"), selection: Binding(get: { selection }, set: onSelect)) {
                    ForEach(pages, id: \.self) { page in
                        Label(page.title, systemImage: page.systemImage).tag(page)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Label(selection.title, systemImage: selection.systemImage)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .menuOrder(.fixed)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .accessibilityLabel(String(localized: "Sidebar Tool"))
            .accessibilityValue(selection.title)
        }
    }
}
