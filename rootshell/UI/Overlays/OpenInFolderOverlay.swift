//
//  OpenInFolderOverlay.swift
//  rootshell
//
//  Keyboard-first HUD, in the Quick Settings mould, that opens a new tab or
//  split on the focused pane's target starting in a chosen folder.
//

import SwiftUI

/// MainView owns the model for the palette's lifetime; this wrapper only
/// hosts it, so parent re-renders never construct a second model.
struct OpenInFolderHUD: View {
    @Binding var isPresented: Bool
    let model: OpenInFolderModel
    /// A placement chord the menu rail caught on the palette's behalf.
    let shortcut: OpenInFolderShortcut?
    /// Returns true when the pane opened; false keeps the HUD up with an error.
    let onOpen: (String, OpenInFolderPlacement) -> Bool

    var body: some View {
        DraggableHUDContainer(
            resizing: .openInFolder,
            dismissShortcuts: [.escape],
            forwardsFindToggle: true,
            forwardsOpenInFolderToggle: true,
            onForwardedToggle: { isPresented = false },
            onFind: { model.focusRequest += 1 },
            onDismiss: { isPresented = false }
        ) {
            GeometryReader { geometry in
                OpenInFolderOverlay(
                    model: model,
                    isPresented: $isPresented,
                    shortcut: shortcut,
                    onOpen: onOpen,
                    width: geometry.size.width,
                    height: geometry.size.height
                )
            }
        }
    }
}

extension HUDResizing {
    static let openInFolder = HUDResizing(
        minSize: CGSize(width: 280, height: 220),
        widthKey: Settings.Tabs.openInFolderHUDWidth,
        heightKey: Settings.Tabs.openInFolderHUDHeight)
}

struct OpenInFolderOverlay: View {
    @Bindable var model: OpenInFolderModel
    @Binding var isPresented: Bool
    @Environment(\.edgeSidebarTitleContext) private var edgeSidebarTitleContext
    let shortcut: OpenInFolderShortcut?
    let onOpen: (String, OpenInFolderPlacement) -> Bool
    let width: CGFloat
    let height: CGFloat
    @State private var arrowRepeat = ArrowKeyRepeatManager()
    @State private var isOpening = false
    /// The segmented control binds to local state, as the Theme Picker's does:
    /// a UIKit control bound straight to the observable model is reset by the
    /// model-driven rebuild that its own click triggers.
    @State private var pickerSelection: OpenInFolderPlacement

    init(
        model: OpenInFolderModel,
        isPresented: Binding<Bool>,
        shortcut: OpenInFolderShortcut?,
        onOpen: @escaping (String, OpenInFolderPlacement) -> Bool,
        width: CGFloat,
        height: CGFloat
    ) {
        self.model = model
        _isPresented = isPresented
        self.shortcut = shortcut
        self.onOpen = onOpen
        self.width = width
        self.height = height
        _pickerSelection = State(initialValue: model.placement)
    }

    private var sideBySide: Bool { width >= 600 }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchRow
            Divider()
            if let reason = model.unavailableReason, model.allCandidates.isEmpty, model.query.isEmpty {
                Text(reason).foregroundStyle(.secondary).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if sideBySide {
                HStack(spacing: 0) {
                    results.frame(width: width * 0.55)
                    Divider()
                    previewPane
                }
            } else {
                VStack(spacing: 0) {
                    results
                    Divider()
                    previewPane.frame(height: min(180, height * 0.35))
                }
            }
            Divider()
            placementRow
            Divider()
            footer
        }
        .frame(width: width, height: height)
        .floatingHUDPanelBackground()
        .onChange(of: model.query) { _, _ in arrowRepeat.stop(); model.queryChanged() }
        .onChange(of: shortcut) { _, shortcut in
            guard let shortcut, model.target.availablePlacements.contains(shortcut.placement) else { return }
            arrowRepeat.stop()
            open(with: shortcut.placement)
        }
        .onChange(of: pickerSelection) { _, selection in
            if model.placement != selection { model.placement = selection }
        }
        .onChange(of: model.placement) { _, placement in
            if pickerSelection != placement { pickerSelection = placement }
        }
        .onDisappear { arrowRepeat.stop() }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if edgeSidebarTitleContext != nil {
            EdgeSidebarHeader(
                title: String(localized: "Open in Folder"),
                systemImage: "folder.badge.plus",
                status: subtitle,
                onClose: { isPresented = false }
            ) {
                EmptyView()
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open in Folder").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .accessibilityLabel(String(localized: "Close Open in Folder"))
            }
            .buttonStyle(.plain)
            .padding(16)
        }
    }

    private var subtitle: String {
        if let cwd = model.target.currentDirectory {
            return "\(model.target.displayName) · \(model.display(cwd))"
        }
        return model.target.displayName
    }

    // MARK: Search

    private var searchRow: some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            SidebarSearchField(
                text: $model.query,
                placeholder: String(localized: "Folder path", comment: "Open in Folder placeholder"),
                fontSize: 17,
                canFocus: isPresented,
                focusRequestID: model.focusRequest,
                selectsAllOnFocus: true,
                onMoveUpBegan: { beginMovement(-1, .up) },
                onMoveUpEnded: { arrowRepeat.stop(direction: .up) },
                onMoveDownBegan: { beginMovement(1, .down) },
                onMoveDownEnded: { arrowRepeat.stop(direction: .down) },
                onEscape: { isPresented = false },
                onSubmit: { arrowRepeat.stop(); open(with: model.placement) },
                onFocusChange: { focused in if !focused { arrowRepeat.stop() } },
                onQuickSelect: { digit in model.setPlacement(index: digit - 1) },
                onTab: { arrowRepeat.stop(); model.tabComplete() },
                onBackTab: { arrowRepeat.stop(); model.goToParent() },
                extraCommands: placementCommands
            )
            .frame(height: 24)
            .accessibilityLabel(String(localized: "Folder path"))
            if model.isListing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// The user's own split / new-tab chords open straight into that placement.
    private var placementCommands: [SidebarSearchExtraCommand] {
        var commands: [SidebarSearchExtraCommand] = []
        let bindings: [(KeybindAction, OpenInFolderPlacement)] = [
            (.new_local_shell, .newTab), (.split_right, .splitRight), (.split_down, .splitDown),
        ]
        for (action, placement) in bindings where model.target.availablePlacements.contains(placement) {
            guard let sequence = KeybindManager.shared.sequence(for: action),
                  !sequence.isSequence, let trigger = sequence.first else { continue }
            commands.append(SidebarSearchExtraCommand(
                input: trigger.uiKeyInput, modifiers: trigger.uiModifierFlags,
                handler: { open(with: placement) }
            ))
        }
        return commands
    }

    // MARK: Results

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.sections.isEmpty {
                        Text(model.isListing
                             ? String(localized: "Listing…", comment: "Open in Folder status")
                             : String(localized: "No matching folders", comment: "Open in Folder status"))
                            .foregroundStyle(.secondary).padding()
                    }
                    ForEach(model.sections) { section in
                        Text(section.title)
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                        ForEach(section.candidates) { candidate in
                            row(candidate)
                        }
                    }
                }.padding(8)
            }
            .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private func row(_ candidate: OpenInFolderModel.Candidate) -> some View {
        Button {
            arrowRepeat.stop()
            model.select(candidate)
            open(with: model.placement, candidate: candidate)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: candidate.kind)).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title).foregroundStyle(.primary).lineLimit(1)
                    if let detail = candidate.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(10)
            .background(model.selectedCandidate?.id == candidate.id ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(String(localized: "Open a shell here"))
        .id(candidate.id)
    }

    private func icon(for kind: OpenInFolderModel.Candidate.Kind) -> String {
        switch kind {
        case .openPane: return "rectangle.on.rectangle"
        case .recent: return "clock"
        case .folder: return "folder"
        }
    }

    // MARK: Preview

    /// Scrolls rather than grows: a tall preview must never push the header
    /// and footer outside the fixed panel frame.
    private var previewPane: some View {
        ScrollView {
            previewContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.preview {
            case .idle:
                Text("Select a folder to preview it").font(.caption).foregroundStyle(.secondary)
            case .loading(let path):
                Text(path).font(.callout).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let path, let message):
                Text(path).font(.callout).lineLimit(2).truncationMode(.middle)
                Text(message).font(.caption).foregroundStyle(.secondary)
            case .loaded(let info):
                Text(info.path).font(.callout).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 10) {
                    Label("\(info.folders) folders", systemImage: "folder")
                    Label("\(info.files) files", systemImage: "doc")
                    if info.hasGit {
                        Label("git", systemImage: "arrow.triangle.branch")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.primary.opacity(0.08), in: Capsule())
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                if info.head.isEmpty {
                    Text("Empty folder").font(.caption).foregroundStyle(.secondary)
                }
                let shown = sideBySide ? info.head : Array(info.head.prefix(6))
                ForEach(shown, id: \.name) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc").frame(width: 18)
                            .foregroundStyle(entry.isDirectory ? .primary : .secondary)
                        Text(entry.name).lineLimit(1)
                    }
                    .font(.caption)
                }
                let remaining = info.folders + info.files - shown.count
                if remaining > 0 {
                    Text(info.truncated ? "+\(remaining) more (partial)" : "+\(remaining) more")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Placement

    private var placementRow: some View {
        HStack(spacing: 12) {
            Picker("", selection: $pickerSelection) {
                ForEach(model.target.availablePlacements, id: \.self) { placement in
                    Image(systemName: placement.systemImage)
                        .accessibilityLabel(placement.title)
                        .tag(placement)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Fixed width so the label never re-lays out the control mid-click.
            Text(model.placement.title)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let error = model.error {
                Text(error).foregroundStyle(.red).accessibilityLabel(String(localized: "Error: \(error)"))
            } else if let hint = model.supportHint {
                Text(hint).foregroundStyle(.secondary)
            }
            Text("↑↓ Navigate   ⇥ Complete   ⇧⇥ Parent   ↵ Open   ⌃1–\(model.target.availablePlacements.count) Placement   Esc Close")
                .foregroundStyle(.secondary)
            if let chords = placementChordHint {
                Text(chords).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var placementChordHint: String? {
        var parts: [String] = []
        let bindings: [(KeybindAction, OpenInFolderPlacement)] = [
            (.new_local_shell, .newTab), (.split_right, .splitRight), (.split_down, .splitDown),
        ]
        for (action, placement) in bindings where model.target.availablePlacements.contains(placement) {
            guard let sequence = KeybindManager.shared.sequence(for: action), !sequence.isSequence else { continue }
            parts.append("\(sequence.symbolDescription) \(placement.title)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }

    // MARK: Actions

    private func beginMovement(_ offset: Int, _ direction: ArrowKeyRepeatManager.Direction) {
        model.move(offset)
        arrowRepeat.start(direction: direction) { model.move(offset) }
    }

    private func open(with placement: OpenInFolderPlacement, candidate: OpenInFolderModel.Candidate? = nil) {
        guard !isOpening, !model.isEnded else { return }
        isOpening = true
        model.submissionTask = Task { @MainActor in
            defer { isOpening = false }
            guard let directory = await model.resolveSubmission(candidate: candidate) else {
                model.focusRequest += 1
                return
            }
            // Escape may have landed while the host was validating.
            guard !Task.isCancelled, !model.isEnded, isPresented else { return }
            if onOpen(directory, placement) {
                model.rememberOpened(directory)
                isPresented = false
            } else {
                model.error = String(localized: "That session is no longer available.", comment: "Open in Folder error")
                model.focusRequest += 1
            }
        }
    }
}
