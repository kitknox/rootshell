//
//  ToolbarAddKeySheet.swift
//  rootshell
//
//  Picks keys for one row of a toolbar: every built-in and custom key, grouped
//  by kind and searchable. A key that is hidden is added; one placed in
//  another row moves.
//

import SwiftUI

struct ToolbarAddKeySheet: View {
    /// The layout the keys go into, and the toolbar its settings were opened for.
    let context: ToolbarContext
    let section: KeyboardToolbarManager.ToolbarSection
    /// Puts a key in the row. The host records undo.
    let add: (KeySlot) -> Void
    /// Saves a new custom key and puts it in the row.
    let create: (CustomKey) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var manager = KeyboardToolbarManager.shared
    @State private var search = ""

    private var drawerRows: Int { manager.layout(for: context).drawerRows.count }

    private struct Group: Identifiable {
        let title: String
        let slots: [KeySlot]
        /// Ends in a row that makes a new custom key.
        var offersNew = false
        var id: String { title }
    }

    private var groups: [Group] {
        let builtIn = KeyID.allCases.filter(\.isAvailable)
        func keys(_ categories: KeyID.KeyCategory...) -> [KeySlot] {
            builtIn.filter { categories.contains($0.category) }.map(KeySlot.builtIn)
        }
        let all = [
            Group(title: String(localized: "Custom Keys"), slots: manager.customKeys.map { .custom($0.id) },
                  offersNew: true),
            Group(title: String(localized: "Modifiers"), slots: keys(.modifier)),
            Group(title: String(localized: "Navigation"), slots: keys(.special, .navigation)),
            Group(title: String(localized: "Actions"), slots: keys(.action, .toggle)),
            Group(title: String(localized: "Symbols"), slots: keys(.symbol)),
        ]
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.map { group in
            Group(title: group.title, slots: group.slots.filter { matches($0, query) })
        }.filter { !$0.slots.isEmpty }
    }

    private func matches(_ slot: KeySlot, _ query: String) -> Bool {
        if ToolbarKeyChip.label(for: slot, manager: manager).localizedCaseInsensitiveContains(query) { return true }
        return slot.keyID?.keyValue.localizedCaseInsensitiveContains(query) ?? false
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.slots, id: \.self) { keyRow($0) }
                        if group.offersNew {
                            NavigationLink {
                                CustomKeyEditorView(context: context, onSave: create)
                            } label: {
                                Label("New Custom Key", systemImage: "plus.circle")
                            }
                            .themedRow()
                        }
                    }
                }
            }
            .themedList()
            .searchable(text: $search, prompt: "Search Keys")
            .navigationTitle("Add to \(section.title(drawerRows: drawerRows))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func keyRow(_ slot: KeySlot) -> some View {
        let location = manager.section(holding: slot, in: context)
        return Button {
            add(slot)
        } label: {
            HStack(spacing: 12) {
                ToolbarKeyBadge(slot: slot)
                Text(ToolbarKeyChip.label(for: slot, manager: manager))
                    .foregroundStyle(Color(uiColor: location == section ? .secondaryLabel : .label))
                Spacer()
                if location == section {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                } else if let location {
                    Text(location.title(drawerRows: drawerRows))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .disabled(location == section)
        .themedRow()
    }
}

/// A key's badge as the toolbar lists draw it.
struct ToolbarKeyBadge: View {
    let slot: KeySlot
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The badge is a drawn image, so its colors are settled for this appearance here.
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let tint = sheetThemeColors?.accentColor.map { UIColor($0) } ?? .tintColor
        let background = sheetThemeColors.map { UIColor($0.rowBackground) } ?? .tertiarySystemGroupedBackground
        Image(uiImage: ToolbarKeyChip.image(for: slot, manager: .shared, tint: tint.resolvedColor(with: traits),
                                            background: background.resolvedColor(with: traits)))
    }
}
