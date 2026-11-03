#if !os(visionOS) && !targetEnvironment(macCatalyst)
import SwiftUI

struct TerminalTouchKeyboardSettingsView: View {
    @Setting(Settings.Keyboard.touchStyle) private var keyboardStyle
    @Setting(Settings.Keyboard.touchLayout) private var keyboardLayout
    @Setting(Settings.Keyboard.touchThemeAware) private var themeAware
    @Setting(Settings.Keyboard.touchPhosphorColor) private var phosphorColor
    @Setting(Settings.Keyboard.touchHeight) private var keyboardHeight
    @Setting(Settings.Keyboard.touchHeightDuoFront) private var frontKeyboardHeight
    @Environment(\.duoLayout) private var duoLayout
    @Setting(Settings.Keyboard.touchFloatingGlassStyle) private var floatingGlassStyle
    @Setting(Settings.Keyboard.touchFloatingGlassTintOpacity) private var floatingGlassTintOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var sample = ""
    @State private var previewHeight: CGFloat = 280
    @State private var previewFloating = false

    private var tintOpacity: Binding<Double> {
        Binding(
            get: { TerminalTouchKeyboardModel.floatingGlassTintOpacity(floatingGlassTintOpacity) },
            set: { floatingGlassTintOpacity = $0 }
        )
    }

    private var frontHeight: Binding<TerminalTouchKeyboardModel.Height> {
        Binding(
            get: { frontKeyboardHeight ?? keyboardHeight },
            set: { frontKeyboardHeight = $0 }
        )
    }

    private var showsDuoHeights: Bool {
        if #available(iOS 27.1, *) { return duoLayout.hasHinge }
        return false
    }

    private func heightPicker(_ title: LocalizedStringKey, selection: Binding<TerminalTouchKeyboardModel.Height>) -> some View {
        Picker(title, selection: selection) {
            ForEach(TerminalTouchKeyboardModel.Height.allCases, id: \.self) { height in
                Text(height.displayName).tag(height)
            }
        }
    }

    var body: some View {
        List {
            Section {
                SettingToggle(Settings.Keyboard.touchEnabled, title: "Terminal Keyboard", icon: "keyboard.badge.ellipsis")
                    .themedRow()
                Picker("Keyboard Layout", selection: $keyboardLayout) {
                    ForEach(TerminalTouchKeyboardModel.Layout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .settingContextMenu(Settings.Keyboard.touchLayout)
                .themedRow()
            } footer: {
                Text("An optional terminal keyboard with layouts for English and most European languages, and long-press accents that match Apple's keyboards. Long-press the keyboard switch key to change the layout, style, or placement. Switch to Apple's keyboard for other languages, swipe typing, emoji, or dictation.")
            }
            Section {
                Picker("Preview Placement", selection: $previewFloating) {
                    Text("Docked").tag(false)
                    Text("Detached").tag(true)
                }
                .pickerStyle(.segmented)
                .themedRow()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("❯").foregroundStyle(.secondary)
                        Text(sample.isEmpty ? "Type a command or prompt…" : sample)
                            .foregroundStyle(sample.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { sample = "" } label: { Image(systemName: "arrow.counterclockwise") }
                            .accessibilityLabel("Clear keyboard preview")
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .frame(minHeight: 58)
                    TerminalTouchKeyboardPreview(sample: $sample, height: $previewHeight, floating: previewFloating)
                        .frame(height: previewHeight)
                        .frame(maxWidth: previewFloating ? 320 : .infinity)
                        .padding(previewFloating ? 12 : 0)
                        .frame(maxWidth: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Try it")
            } footer: {
                Text("This preview stays on your device and sends nothing to a terminal. Hold Space to move the cursor; tap a modifier for one key, double-tap to lock, or hold it while typing.")
            }
            Section {
                SettingToggle(Settings.Keyboard.touchStatePerTab, title: "Separate State per Tab", icon: "square.on.square")
                    .themedRow()
            } footer: {
                Text("Off by default. Keep the keyboard’s page, shortcuts, drawers, sticky modifiers, and keyboard choice as you switch tabs. Turn this on to remember a separate state for each tab. Split panes in the same tab share their keyboard state.")
            }
            Section {
                SettingToggle(Settings.Keyboard.touchLetterPrediction, title: "Letter Prediction", icon: "textformat.abc")
                    .disabled(!keyboardLayout.usesEnglishTextModels)
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchSuggestions, title: "Suggestions", icon: "textformat.abc")
                    .disabled(!keyboardLayout.usesEnglishTextModels)
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchHaptics, title: "Haptic Feedback", icon: "hand.tap")
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchClickSound, title: "Key Click Sounds", icon: "speaker.wave.2")
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchCharacterPreview, title: "Character Preview", icon: "character.magnify")
                    .themedRow()
            } header: {
                Text("Typing")
            } footer: {
                Text("Letter Prediction uses recent English typing to help choose between nearby letters. Turn it off for literal key targeting. Suggestions are local spelling guesses and completions; tap to apply one. Words are never automatically replaced. Both are English-only and stay off with other layouts. The double-space period shortcut follows your Terminal keyboard setting. Key Click Sounds match the keyboard style and are muted in Silent Mode. Character Preview shows the pressed letter above your finger; turn it off to only highlight the key.")
            }
            Section {
                if showsDuoHeights {
                    heightPicker("Inner Display Height", selection: $keyboardHeight)
                        .settingContextMenu(Settings.Keyboard.touchHeight)
                        .themedRow()
                    heightPicker("Front Display Height", selection: frontHeight)
                        .settingContextMenu(Settings.Keyboard.touchHeightDuoFront)
                        .themedRow()
                } else {
                    heightPicker("Keyboard Height", selection: $keyboardHeight)
                        .settingContextMenu(Settings.Keyboard.touchHeight)
                        .themedRow()
                }
                SettingToggle(Settings.Keyboard.touchGlyphs, title: "Key Glyphs", icon: "command")
                    .themedRow()
            } header: {
                Text("Layout")
            } footer: {
                Text("Extra Large keeps the keyboard above the bottom safe area. Large moves every row, including Space, down into the bottom safe area without reducing key height. The bottom corners adapt to your iPhone. Medium, Small, and Extra Small also reduce the height of the keys and toolbar to leave more room for the terminal. Swipe up or down across the keys to step between heights. Key Glyphs shows symbols for Escape, Tab, and modifiers; turn it off to show their names.")
                if showsDuoHeights {
                    Text("On iPhone Duo, the inner and front displays each keep their own height, and swiping changes the display you’re using. The front display matches the inner one until you change it.")
                }
            }
            Section {
                Picker("Keyboard Style", selection: $keyboardStyle) {
                    ForEach(TerminalTouchKeyboardModel.Style.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .settingContextMenu(Settings.Keyboard.touchStyle)
                .themedRow()
                SettingToggle(Settings.Keyboard.touchThemeAware, title: "Follow Terminal Theme", icon: "paintpalette")
                    .themedRow()
                if keyboardStyle == .steampunk {
                    SettingToggle(Settings.Keyboard.touchSteampunkThemeAwareKeycaps, title: "Theme-Aware Keycaps", icon: "keyboard")
                        .disabled(!themeAware)
                        .themedRow()
                }
                if keyboardStyle == .phosphor {
                    Picker("Phosphor Color", selection: $phosphorColor) {
                        ForEach(TerminalTouchKeyboardModel.PhosphorColor.allCases, id: \.self) { color in
                            Text(color.displayName).tag(color)
                        }
                    }
                    .settingContextMenu(Settings.Keyboard.touchPhosphorColor)
                    .themedRow()
                }
                KeyboardBackgroundEffectPicker()
                    .themedRow()
            } header: {
                Text("Appearance")
            } footer: {
                Text("Flat is the original keyboard style. Sculpted adds raised keycaps and depth. Steampunk adds brass-rimmed instrument keys and a mechanical drive that responds to touch. Phosphor draws glowing keys on a dark CRT screen. Beige Box has tall keys like a classic office keyboard. Neon Grid puts glowing keys over a synthwave horizon whose grid moves as you type. Circuit Board sends a pulse along the board’s traces with each key press. Animations stop when idle, with Reduce Motion, or in Low Power Mode. Follow Terminal Theme matches the active terminal’s colors, including tab and window themes. Key labels keep their contrast in every mode.")
                if keyboardStyle == .steampunk {
                    Text("Steampunk uses matching ivory and dark enamel keycaps by default. With Follow Terminal Theme on, enable Theme-Aware Keycaps to also match the keycaps to your terminal’s colors.")
                }
            }
            if UIDevice.current.userInterfaceIdiom == .pad {
                Section {
                    SettingToggle(Settings.Keyboard.touchSystemFloating, title: "Use System Detached Keyboard", icon: "keyboard")
                        .themedRow()
                } footer: {
                    Text("Use iPadOS’s floating keyboard container so the keyboard can move beyond the app window. Drag the … handle to move it. To float or dock in this mode, switch to Apple’s keyboard, change its placement, then switch back using the toolbar’s keyboard button. Turn this off to keep the detached keyboard inside rootshell and use pinch gestures on our keyboard.")
                }
            }
            Section {
                Picker("Glass Style", selection: $floatingGlassStyle) {
                    ForEach(TerminalTouchKeyboardModel.FloatingGlassStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .settingContextMenu(Settings.Keyboard.touchFloatingGlassStyle)
                .themedRow()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tint Strength")
                            .settingRow(Settings.Keyboard.touchFloatingGlassTintOpacity)
                        Spacer()
                        Text(tintOpacity.wrappedValue, format: .wholePercent)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: tintOpacity, in: 0...1, step: 0.05) {
                        Text("Tint Strength")
                    }
                }
                .disabled(floatingGlassStyle == .solid || reduceTransparency)
                .themedRow()
                Button {
                    _floatingGlassStyle.reset()
                    _floatingGlassTintOpacity.reset()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
                .themedRow()
            } header: {
                Text("Detached Keyboard")
            } footer: {
                Text("Customize the detached keyboard’s background. Clear reveals more content; Solid removes transparency. Tint Strength adjusts how much of the keyboard’s background color is added. Older system versions use blur. Reduce Transparency always uses a solid background.")
            }
            Section("Terminal tools") {
                Group {
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("With Use System Detached Keyboard off, pinch inward, or long-press the keyboard switch key and choose Placement, then Detached, to float the keyboard. Drag the … handle to move it. Spread two fingers, double-tap the handle, or choose Docked to dock. Docking hides the keys when a hardware keyboard is connected.")
                            Text("Choose Placement, then Split, to divide the docked keys into two halves at the screen edges for thumb typing.")
                        }
                    } else {
                        Text("Long-press the keyboard switch key and choose Placement, then Detached, to float a smaller keyboard over the terminal, freeing the rest of the screen. Drag the … handle to move it. Double-tap the handle or choose Docked to dock.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .themedRow()
                NavigationLink(value: SettingsSearchDestination.toolbarKeys) {
                    Label("Customize Toolbar", systemImage: "command")
                }
                .themedRow()
                Text("Swipe left or right across the keys to reach Symbols, Navigation, and Shortcuts. A temporary overlay shows your position. The toolbar follows your customized button layout. Tap … to open your custom drawer rows, using the same stack or cycle setting as the regular keyboard toolbar. Choose Agent, Shell, Vim, Emacs, or Nano on the Shortcuts page. Shortcuts use each application's standard bindings; customized bindings may behave differently.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Terminal Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TerminalTouchKeyboardPreview: UIViewRepresentable {
    @Binding var sample: String
    @Binding var height: CGFloat
    var floating: Bool
    var style: TerminalTouchKeyboardModel.Style?
    var onPageChanged: ((TerminalTouchKeyboardModel.ToolPage) -> Void)?

    final class Coordinator: TerminalTouchKeyboardHost {
        var parent: TerminalTouchKeyboardPreview
        var predictionContext = TerminalTouchKeyboardModel.PredictionContext()
        var lastSample = ""
        init(_ parent: TerminalTouchKeyboardPreview) { self.parent = parent }
        var touchKeyboardCanSend: Bool { true }
        var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? { nil }
        var touchKeyboardPredictionContext: TerminalTouchKeyboardModel.PredictionSnapshot? { predictionContext.snapshot }
        func touchKeyboardInsert(_ text: String) {
            parent.sample = String((parent.sample + text).suffix(180))
            lastSample = parent.sample
            predictionContext.append(text)
        }
        func touchKeyboardSend(_ key: String, modifiers: KeyModifiers, shifted: Character?) {
            if key == "\u{7f}", modifiers.isEmpty {
                if !parent.sample.isEmpty { parent.sample.removeLast() }
                lastSample = parent.sample
                predictionContext.backspace()
                return
            }
            if modifiers.isEmpty, key == "\r" { touchKeyboardInsert("\n"); return }
            if modifiers.isEmpty, key == "\t" { touchKeyboardInsert("    "); return }
            let label = ["\u{1b}": "Esc", "\u{1b}[A": "↑", "\u{1b}[B": "↓", "\u{1b}[C": "→", "\u{1b}[D": "←", "\r": "Return", "\t": "Tab"][key] ?? key
            touchKeyboardInsert("⟨" + (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.alt) ? "⌥" : "")
                                + (modifiers.contains(.shift) ? "⇧" : "") + label + "⟩")
            predictionContext.reset()
        }
        func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext) {}
        func touchKeyboardInvalidateSuggestions() { predictionContext.reset() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> TerminalTouchKeyboardView {
        let view = TerminalTouchKeyboardView()
        view.isEmbeddedPreview = true
        view.useContainerSizing()
        view.styleOverride = style
        view.host = context.coordinator
        view.setFloating(floating)
        view.onHeightChanged = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.parent.height = view.intrinsicContentSize.height
        }
        view.onPageChanged = { [weak coordinator = context.coordinator] page in
            coordinator?.parent.onPageChanged?(page)
        }
        // A docked preview may already have its final height at creation, so
        // onHeightChanged alone never replaces the caller's placeholder height.
        DispatchQueue.main.async { [weak view] in view?.onHeightChanged?() }
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TerminalTouchKeyboardView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: uiView.intrinsicContentSize.height)
    }
    func updateUIView(_ view: TerminalTouchKeyboardView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.styleOverride = style
        view.setFloating(floating)
        if coordinator.lastSample != sample {
            coordinator.predictionContext.reset()
            coordinator.lastSample = sample
        }
        view.updatePrediction()
    }
    static func dismantleUIView(_ view: TerminalTouchKeyboardView, coordinator: Coordinator) { view.cancelInteraction() }
}

#endif
