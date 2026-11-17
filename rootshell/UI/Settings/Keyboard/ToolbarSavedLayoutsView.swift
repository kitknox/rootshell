//
//  ToolbarSavedLayoutsView.swift
//  rootshell
//
//  Copies one toolbar's layout onto another, and keeps named saves of a
//  layout to return to after experimenting.
//

import SwiftUI

struct ToolbarSavedLayoutsView: View {
    /// The toolbar a copy or a restore lands on, and the one a save is taken from.
    let context: ToolbarContext

    @State private var manager = KeyboardToolbarManager.shared
    @State private var previewMetrics = ToolbarLayoutPreviewMetrics()
    @State private var sort = Sort.newest
    @State private var replacement: Replacement?
    @State private var showingSave = false
    @State private var saveName = ""
    @State private var renaming: SavedToolbarLayout?
    @State private var renameText = ""

    enum Sort: CaseIterable {
        case newest
        case oldest
        case name

        var title: String {
            switch self {
            case .newest: return String(localized: "Newest First")
            case .oldest: return String(localized: "Oldest First")
            case .name: return String(localized: "Name")
            }
        }
    }

    /// A layout about to take the place of this toolbar's.
    private enum Replacement {
        case copy(ToolbarContext)
        case restore(SavedToolbarLayout)
    }

    private var sortedLayouts: [SavedToolbarLayout] {
        switch sort {
        case .newest: return manager.savedLayouts.sorted { $0.date > $1.date }
        case .oldest: return manager.savedLayouts.sorted { $0.date < $1.date }
        case .name:
            return manager.savedLayouts.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    var body: some View {
        List {
            Section {
                ToolbarLayoutPreview(toolbar: context, showsDrawers: true, metrics: $previewMetrics)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .themedRow()
            } header: {
                Text(context.toolbarTitle)
            }
            copySection
            savedSection
        }
        .themedList()
        .navigationTitle("Copy and Save")
        .navigationBarTitleDisplayMode(.inline)
        // `presenting` hands the choice to the buttons; the binding may clear first.
        .confirmationDialog(replacementTitle, isPresented: replacementBinding, titleVisibility: .visible,
                            presenting: replacement) { replacement in
            Button("Replace", role: .destructive) { apply(replacement, savingFirst: false) }
            Button("Save Current Layout, Then Replace") { apply(replacement, savingFirst: true) }
        } message: { _ in
            Text(replacementMessage)
        }
        .alert("Save Layout", isPresented: $showingSave) {
            TextField("Name", text: $saveName)
            Button("Save") { manager.saveLayout(of: context, named: saveName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the \(context.displayName) toolbar as it is now.")
        }
        .alert("Rename Layout", isPresented: renamingBinding, presenting: renaming) { saved in
            TextField("Name", text: $renameText)
            Button("Rename") { manager.renameSavedLayout(id: saved.id, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Copy

    @ViewBuilder
    private var copySection: some View {
        let sources = manager.copySources(for: context)
        if !sources.isEmpty {
            Section {
                ForEach(sources, id: \.self) { source in
                    Button {
                        replacement = .copy(source)
                    } label: {
                        Label(source.toolbarTitle, systemImage: source.iconName)
                    }
                    .themedRow()
                }
            } header: {
                Text("Copy From")
            } footer: {
                Text("Puts a copy of another toolbar's layout on the \(context.displayName) toolbar. The toolbar it came from is left as it is.")
            }
        }
    }

    // MARK: - Saved Layouts

    private var savedSection: some View {
        Section {
            Button {
                saveName = manager.suggestedSaveName(for: context)
                showingSave = true
            } label: {
                Label("Save Current Layout", systemImage: "plus")
            }
            .themedRow()

            ForEach(sortedLayouts) { saved in
                Button {
                    replacement = .restore(saved)
                } label: {
                    savedRow(saved)
                }
                .themedRow()
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        manager.deleteSavedLayout(id: saved.id)
                    }
                    Button("Rename", systemImage: "pencil") { beginRenaming(saved) }
                }
                .contextMenu {
                    Button("Restore", systemImage: "arrow.uturn.backward") { replacement = .restore(saved) }
                    Button("Rename", systemImage: "pencil") { beginRenaming(saved) }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        manager.deleteSavedLayout(id: saved.id)
                    }
                }
            }
        } header: {
            HStack {
                Text("Saved Layouts")
                Spacer()
                if manager.savedLayouts.count > 1 {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases, id: \.self) { sort in
                                Text(sort.title).tag(sort)
                            }
                        }
                    } label: {
                        Label(sort.title, systemImage: "arrow.up.arrow.down")
                            .font(.footnote)
                            .textCase(nil)
                    }
                }
            }
        } footer: {
            Text(manager.savedLayouts.isEmpty
                 ? "Save a layout before you experiment, then tap it here to bring it back. A save can go on any toolbar."
                 : "Tap a save to put it on the \(context.displayName) toolbar. Swipe a save to rename or delete it. Saves are kept when toolbars are reset.")
        }
    }

    private func savedRow(_ saved: SavedToolbarLayout) -> some View {
        HStack(spacing: 12) {
            Image(systemName: saved.source.iconName)
                .foregroundStyle(.tint)
                .frame(width: 24, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                // Explicit colors: inside a button the hierarchical styles follow its tint.
                Text(saved.name)
                    .foregroundStyle(Color.primary)
                Text("\(saved.source.displayName), \(saved.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func beginRenaming(_ saved: SavedToolbarLayout) {
        renameText = saved.name
        renaming = saved
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    // MARK: - Replacing

    private var replacementBinding: Binding<Bool> {
        Binding(get: { replacement != nil }, set: { if !$0 { replacement = nil } })
    }

    private var replacementTitle: String {
        switch replacement {
        case .copy(let source):
            return String(localized: "Copy the \(source.displayName) toolbar to the \(context.displayName) toolbar?")
        case .restore(let saved):
            return String(localized: "Put \"\(saved.name)\" on the \(context.displayName) toolbar?")
        case nil:
            return ""
        }
    }

    private var replacementMessage: String {
        if !manager.hasOwnLayout(context) {
            return String(localized: "\(context.displayName) gets a layout of its own. The Terminal toolbar is left as it is.")
        }
        let followers = KeyboardToolbarManager.secondaryContexts.filter { !manager.hasOwnLayout($0) }
        if context == .terminal, !followers.isEmpty {
            let names = followers.map(\.displayName).formatted(.list(type: .and))
            return String(localized: "This replaces the Terminal toolbar's layout. \(names) use the Terminal toolbar and change with it.")
        }
        return String(localized: "This replaces the \(context.displayName) toolbar's layout.")
    }

    private func apply(_ replacement: Replacement, savingFirst: Bool) {
        if savingFirst { manager.saveLayout(of: context, named: "") }
        switch replacement {
        case .copy(let source): manager.copyLayout(from: source, to: context)
        case .restore(let saved): manager.restore(saved, to: context)
        }
    }
}
