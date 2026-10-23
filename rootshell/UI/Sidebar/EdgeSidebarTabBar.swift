//
//  EdgeSidebarTabBar.swift
//  rootshell
//
//  The pages assigned to one edge. One page still shows one tab.
//

import SwiftUI

struct EdgeSidebarTabBar: View {
    let pages: [EdgeSidebarPage]
    let selection: EdgeSidebarPage
    let onSelect: (EdgeSidebarPage) -> Void

    var body: some View {
        if !pages.isEmpty {
            HStack(spacing: 6) {
                ForEach(pages, id: \.self) { page in
                    let selected = page == selection
                    Button {
                        onSelect(page)
                    } label: {
                        Label(page.title, systemImage: page.systemImage)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selected ? Color.primary.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Sidebar pages", comment: "Sidebar tab bar"))
        }
    }
}
