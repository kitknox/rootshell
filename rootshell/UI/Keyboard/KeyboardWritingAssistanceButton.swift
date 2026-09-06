import UIKit
import Combine

/// A native primary-action menu inside the toolbar's standard-sized key. The
/// child consumes touches, so selecting a mode never emits a terminal key.
final class KeyboardWritingAssistanceButton: KeyboardSymbolButton {
    private let menuButton = UIButton(type: .system)
    private var observation: AnyCancellable?

    init(sizes: KeyboardSizes) {
        super.init(key: "__writingAssistance__", display: .icon(TerminalWritingAssistanceMode.toolbarIcon), sizes: sizes)
        isAccessibilityElement = false
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = String(localized: "Writing Assistance")
        addSubview(menuButton)
        NSLayoutConstraint.activate([
            menuButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuButton.topAnchor.constraint(equalTo: topAnchor),
            menuButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let observer = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observation = AnyCancellable { NotificationCenter.default.removeObserver(observer) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        let mode = SettingsStore.shared.value(Settings.Keyboard.writingAssistance)
        menuButton.accessibilityValue = mode.title
        menuButton.menu = UIMenu(children: TerminalWritingAssistanceMode.allCases.map { choice in
            UIAction(title: choice.title, image: UIImage(systemName: choice.icon),
                     state: choice == mode ? .on : .off) { _ in
                SettingsStore.shared.set(Settings.Keyboard.writingAssistance, choice)
            }
        })
    }
}
