import SwiftUI

/// Owns the draft separately from persisted settings: incoming sync/config
/// changes update result values without replacing text the user is editing.
@MainActor @Observable
final class QuickSettingsModel {
    let entries: [QuickSetting]
    private(set) var results: [QuickSetting]

    init() {
        let entries = QuickSettingsCatalog.makeEntries()
        self.entries = entries
        self.results = entries
        self.selection = entries.first?.id
    }
    var query = ""
    var selection: String?
    var editing: QuickSetting?
    var draft = ""
    private(set) var choiceQuery = ""
    var choiceSelection: String?
    var error: String?
    var feedback: String?
    var focusRequest = 1
    var catalogRevision = 0

    private func matchingResults() -> [QuickSetting] {
        return entries.compactMap { entry -> (QuickSetting, Int)? in
            let metadata = [entry.definition.group.title, entry.definition.configKey ?? "", entry.keywords].joined(separator: " ")
            guard let score = QuickSettingsInput.searchScore(query: query, title: entry.title, metadata: metadata) else { return nil }
            return (entry, score)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return (lhs.0.definition.group.title, lhs.0.title, lhs.0.id) < (rhs.0.definition.group.title, rhs.0.title, rhs.0.id)
        }.map(\.0)
    }

    var choices: [QuickSetting.Choice] {
        _ = catalogRevision
        guard let editing, case .choices(let values) = editing.editor else { return [] }
        let tokens = QuickSettingsInput.normalized(choiceQuery).split(whereSeparator: \.isWhitespace).map(String.init)
        return values().filter { choice in tokens.allSatisfy(QuickSettingsInput.normalized(choice.title).contains) }
    }

    var selectedEntry: QuickSetting? { results.first { $0.id == selection } ?? results.first }
    var selectedChoice: QuickSetting.Choice? { choices.first { $0.id == choiceSelection } ?? choices.first }

    func searchChanged() {
        results = matchingResults()
        selection = results.first?.id
        error = nil
        feedback = nil
    }

    /// Only edits from the search field move selection to the first match.
    /// activate() clears the query programmatically and selects the saved value.
    func editChoiceQuery(_ query: String) {
        choiceQuery = query
        choiceSelection = choices.first?.id
    }

    func move(_ offset: Int) {
        if let editing {
            if case .number(let range, let step, let integral) = editing.editor {
                let current = Double(draft) ?? 0
                let value = min(range.upperBound, max(range.lowerBound, current - Double(offset) * step))
                draft = integral ? String(Int(value)) : QuickSettingsInput.numberText(value)
            } else {
                choiceSelection = QuickSettingsInput.movedID(choices.map(\.id), current: choiceSelection, offset: offset)
            }
        } else {
            selection = QuickSettingsInput.movedID(results.map(\.id), current: selection, offset: offset)
        }
    }

    func activate(_ entry: QuickSetting) {
        selection = entry.id
        feedback = nil
        if let reason = entry.disabledReason { error = reason; return }
        if case .toggle = entry.editor {
            guard case .bool(let value) = entry.read() else { return }
            apply(entry, value: .bool(!value))
            return
        }
        editing = entry
        choiceQuery = ""
        let value = entry.read()
        switch value {
        case .string(let text): draft = text
        case .int(let number): draft = String(number)
        case .double(let number): draft = QuickSettingsInput.numberText(number)
        default: draft = ""
        }
        choiceSelection = choices.first { $0.value == value }?.id ?? choices.first?.id
        error = nil
        focusRequest += 1
    }

    func submit() {
        guard let editing else {
            if let selectedEntry { activate(selectedEntry) }
            return
        }
        switch editing.editor {
        case .choices:
            if let selectedChoice { apply(editing, value: selectedChoice.value) }
        case .number(_, _, let integral):
            if integral {
                guard let number = Int(draft) else { error = String(localized: "Enter a whole number."); return }
                apply(editing, value: .int(number))
            } else {
                guard let number = Double(draft), number.isFinite else { error = String(localized: "Enter a number."); return }
                apply(editing, value: .double(number))
            }
        case .color:
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            apply(editing, value: text.isEmpty && editing.definition.isOptional ? nil : .string(text))
        case .text: apply(editing, value: .string(draft))
        case .toggle: break
        }
    }

    func apply(_ entry: QuickSetting, value: CodableValue?) {
        error = entry.commit(value)
        guard error == nil else { return }
        feedback = "\(entry.title): \(entry.valueLabel)"
        editing = nil
        focusRequest += 1
    }

    func cancelEditor() {
        editing = nil
        error = nil
        focusRequest += 1
    }

    func focusSearch() {
        cancelEditor()
        focusRequest += 1
    }
}

struct QuickSettingsHUD: View {
    @Binding var isPresented: Bool
    var inSidebar = false
    @State private var model = QuickSettingsModel()

    @ViewBuilder
    var body: some View {
        if inSidebar {
            panelContent
        } else {
            DraggableHUDContainer(
                resizing: .quickSettings,
                dismissShortcuts: [.escape],
                forwardsQuickSettingsToggle: true,
                forwardsFindToggle: true,
                onForwardedToggle: { isPresented = false },
                onFind: { model.focusSearch() },
                onDismiss: {
                    if model.editing != nil { model.cancelEditor() } else { isPresented = false }
                }
            ) {
                panelContent
            }
        }
    }

    private var panelContent: some View {
        GeometryReader { geometry in
            QuickSettingsOverlay(model: model, isPresented: $isPresented,
                width: geometry.size.width, height: geometry.size.height)
        }
    }
}

extension HUDResizing {
    static let quickSettings = HUDResizing(
        minSize: CGSize(width: 240, height: 200),
        widthKey: Settings.Window.quickSettingsHUDWidth,
        heightKey: Settings.Window.quickSettingsHUDHeight)
}

struct QuickSettingsOverlay: View {
    @Bindable var model: QuickSettingsModel
    @Binding var isPresented: Bool
    @Environment(\.edgeSidebarTitleContext) private var edgeSidebarTitleContext
    let width: CGFloat
    let height: CGFloat
    @State private var arrowRepeat = ArrowKeyRepeatManager()
    // FontManager uses Combine rather than Observation.
    @ObservedObject private var fonts = FontManager.shared

    private var isChoiceEditor: Bool {
        if let entry = model.editing, case .choices = entry.editor { return true }
        return false
    }

    private var fieldText: Binding<String> {
        if model.editing == nil { return $model.query }
        if isChoiceEditor {
            return Binding(
                get: { model.choiceQuery },
                set: { query in
                    arrowRepeat.stop()
                    model.editChoiceQuery(query)
                }
            )
        }
        return $model.draft
    }

    @ViewBuilder
    private var header: some View {
        if edgeSidebarTitleContext != nil {
            EdgeSidebarHeader(
                title: String(localized: "Quick Settings"),
                systemImage: "slider.horizontal.3",
                status: model.editing?.title ?? String(localized: "Global preferences"),
                onBack: model.editing == nil ? nil : { model.cancelEditor() },
                onClose: { isPresented = false }
            ) {
                EmptyView()
            }
        } else {
            HStack {
                if model.editing != nil {
                    Button { model.cancelEditor() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back to Quick Settings")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.editing?.title ?? String(localized: "Quick Settings")).font(.headline)
                    Text(model.editing?.definition.group.title ?? String(localized: "Global preferences"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .accessibilityLabel("Close Quick Settings")
            }
            .buttonStyle(.plain)
            .padding(16)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack {
                Image(systemName: model.editing == nil || isChoiceEditor ? "magnifyingglass" : "pencil")
                    .foregroundStyle(.secondary)
                SidebarSearchField(
                    text: fieldText,
                    placeholder: model.editing == nil ? String(localized: "Search settings") : isChoiceEditor ? String(localized: "Search values") : String(localized: "Enter a value"),
                    fontSize: 17,
                    canFocus: isPresented,
                    focusRequestID: model.focusRequest,
                    selectsAllOnFocus: true,
                    onMoveUpBegan: { beginMovement(-1, .up) },
                    onMoveUpEnded: { arrowRepeat.stop(direction: .up) },
                    onMoveDownBegan: { beginMovement(1, .down) },
                    onMoveDownEnded: { arrowRepeat.stop(direction: .down) },
                    onEscape: {
                        if model.editing != nil { model.cancelEditor() } else { isPresented = false }
                    },
                    onSubmit: { arrowRepeat.stop(); model.submit() },
                    onFocusChange: { focused in if !focused { arrowRepeat.stop() } }
                )
                .frame(height: 24)
                .accessibilityLabel(model.editing == nil ? String(localized: "Search settings") : String(localized: "Setting value"))
            }
            .padding(10)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            Divider()
            if model.editing == nil { results }
            else if isChoiceEditor { choiceResults }
            else { valueEditor }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                if let error = model.error {
                    Text(error).foregroundStyle(.red).accessibilityLabel(String(localized: "Error: \(error)"))
                } else if let feedback = model.feedback {
                    Label(feedback, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
                Text(model.editing == nil ? "↑↓ Navigate   ↵ Change   ⌘F Search   Esc Close" : "↵ Apply   ⌘F Search   Esc Back")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(width: width, height: height)
        .floatingHUDPanelBackground()
        .onChange(of: model.query) { _, _ in arrowRepeat.stop(); model.searchChanged() }
        .onChange(of: model.editing?.id) { _, _ in arrowRepeat.stop() }
        .onChange(of: model.draft) { _, _ in model.error = nil }
        .onDisappear { arrowRepeat.stop() }
        .task {
            await ThemeManager.shared.ensureThemesLoaded()
            await fonts.ensureFontsLoaded()
            model.catalogRevision += 1
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.results.isEmpty { Text("No matching settings").foregroundStyle(.secondary).padding() }
                    ForEach(model.results) { entry in
                        Button { arrowRepeat.stop(); model.activate(entry) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.definition.group.systemImage).frame(width: 22).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title).foregroundStyle(.primary)
                                    Text(entry.definition.group.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if entry.disabledReason != nil { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                                Text(entry.valueLabel).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 160, alignment: .trailing)
                            }
                            .padding(10)
                            .background(model.selectedEntry?.id == entry.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(entry.valueLabel)
                        .accessibilityHint(entry.disabledReason ?? String(localized: "Change setting"))
                        .id(entry.id)
                    }
                }.padding(8)
            }
            .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private var choiceResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.choices.isEmpty { Text("No matching values").foregroundStyle(.secondary).padding() }
                    ForEach(model.choices) { choice in
                        Button {
                            if let entry = model.editing { model.apply(entry, value: choice.value) }
                        } label: {
                            HStack {
                                Text(choice.title)
                                Spacer()
                                if model.editing?.read() == choice.value { Image(systemName: "checkmark") }
                            }
                            .padding(10)
                            .background(model.selectedChoice?.id == choice.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).id(choice.id)
                    }
                }.padding(8)
            }
            .onAppear { if let id = model.choiceSelection { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: model.choiceSelection) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private var valueEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let entry = model.editing {
                Text("Current value: \(entry.valueLabel)").foregroundStyle(.secondary)
                if !entry.note.isEmpty { Text(entry.note).font(.callout) }
                if case .number(let range, let step, _) = entry.editor {
                    Text("Range: \(range.lowerBound.formatted())–\(range.upperBound.formatted()). Step: \(step.formatted()).")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button { model.move(1) } label: { Label("Decrease", systemImage: "minus") }
                        Button { model.move(-1) } label: { Label("Increase", systemImage: "plus") }
                    }
                    Text("Use ↑ and ↓ to adjust the value, then Return to apply.").font(.caption).foregroundStyle(.secondary)
                }
                if case .color = entry.editor {
                    Text(entry.definition.isOptional ? "Enter #RRGGBB, or leave empty to use the theme default." : "Enter a color as #RRGGBB.")
                        .font(.callout).foregroundStyle(.secondary)
                    if QuickSettingsInput.isHexColor(model.draft), let color = Color(hex: model.draft) {
                        RoundedRectangle(cornerRadius: 8).fill(color).frame(height: 44)
                            .accessibilityLabel("Color preview")
                    }
                }
                Button("Apply") { model.submit() }.buttonStyle(.borderedProminent)
                if let reason = entry.disabledReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func beginMovement(_ offset: Int, _ direction: ArrowKeyRepeatManager.Direction) {
        model.move(offset)
        arrowRepeat.start(direction: direction) { model.move(offset) }
    }
}
