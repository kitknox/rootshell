//
//  RemoteScreenHUDKeys.swift
//  rootshell
//
//  The keyboard's share of a remote screen's HUD bar: the toolbar row and the
//  buttons that fold it away, show the keys, and float or dock the bar.
//

#if !os(visionOS) && !targetEnvironment(macCatalyst)
import Observation
import SwiftUI
import UIKit
import rootshellVNC

/// State the HUD bar draws from. The coordinator keeps it current.
@Observable
final class RemoteScreenHUDKeysModel {
    /// The toolbar's own key metrics for the pane's size class.
    struct Metrics: Equatable {
        var keyCount = 0
        var edgePadding: CGFloat = 0
        /// One key's width where the bar is fitted to its keys.
        var slotWidth: CGFloat = 46
        var minimumSlotWidth: CGFloat = 30
        var rowHeight: CGFloat = 46
        var symbolPointSize: CGFloat = 17
    }

    var keysRequested = false
    /// The bar floats, draggable, rather than docking along the bottom.
    /// Starts from the app setting; a long press on the fold button switches it.
    var isFloating = SettingsStore.shared.value(Settings.ScreenSharing.floatingToolbarDefault)
    /// False while the docked toolbar is the terminal keyboard's own row.
    var barEnabled = true
    /// The bar carries the toolbar row.
    var stripAvailable = false
    var stripHeight: CGFloat = 0
    var metrics = Metrics()
    var stripExpanded = SettingsStore.shared.value(Settings.KeyboardToolbar.remoteScreenStripExpanded) {
        didSet {
            guard stripExpanded != oldValue else { return }
            SettingsStore.shared.set(Settings.KeyboardToolbar.remoteScreenStripExpanded, stripExpanded)
        }
    }

    /// The hardware-keyboard toolbar setting hid the keys; the chevron still
    /// shows them, for this attachment only and without saving.
    var keysHiddenBySetting = false {
        didSet { if !keysHiddenBySetting { shownDespiteSetting = false } }
    }
    private var shownDespiteSetting = false

    /// What the chevron folds and shows.
    var keysExpanded: Bool {
        get { keysHiddenBySetting ? shownDespiteSetting : stripExpanded }
        set {
            if keysHiddenBySetting { shownDespiteSetting = newValue } else { stripExpanded = newValue }
        }
    }

    /// A hardware keyboard has no on-screen keys to summon.
    var showsKeysButton: Bool { !KeyboardTracker.shared.isHardwareKeyboard }

    /// Buttons over the toolbar's trailing end: fold, keys, and the HUD menu.
    private var trailingButtonCount: CGFloat { showsKeysButton ? 3 : 2 }

    /// Pinned along the bottom, with the screen fitted above it.
    var docksToBottom: Bool { !isFloating && stripAvailable && keysExpanded }

    /// Docked, the keys share the full width; floating, each keeps its natural size.
    func slotWidth(availableWidth: CGFloat) -> CGFloat {
        guard docksToBottom else { return metrics.slotWidth }
        let slots = CGFloat(metrics.keyCount) + trailingButtonCount
        return max(metrics.minimumSlotWidth, (availableWidth - metrics.edgePadding * 2) / slots)
    }

    func buttonStyle(availableWidth: CGFloat) -> VNCHUDButtonStyle {
        VNCHUDButtonStyle(
            size: CGSize(width: slotWidth(availableWidth: availableWidth), height: metrics.rowHeight),
            symbolPointSize: metrics.symbolPointSize)
    }

    func trailingReserve(availableWidth: CGFloat) -> CGFloat {
        slotWidth(availableWidth: availableWidth) * trailingButtonCount
    }

    /// A narrow pane squeezes the keys, then moves the rest to a drawer.
    func barWidth(availableWidth: CGFloat) -> CGFloat {
        guard !docksToBottom else { return availableWidth }
        let fitted = CGFloat(metrics.keyCount) * metrics.slotWidth + metrics.edgePadding * 2
            + trailingReserve(availableWidth: availableWidth)
        return min(availableWidth, fitted)
    }
}

/// The toolbar row, spanning the bar behind the HUD's buttons. Its drawer
/// rows open above them at full width.
struct RemoteScreenHUDToolbar: View {
    let coordinator: VNCKeyboardAccessoryCoordinator
    /// Width the HUD may occupy.
    let availableWidth: CGFloat

    var body: some View {
        let model = coordinator.hudModel
        if model.stripAvailable, model.keysExpanded {
            RemoteScreenHUDKeyStrip(
                coordinator: coordinator,
                trailingReserve: model.trailingReserve(availableWidth: availableWidth),
                allowsDrag: model.isFloating)
                .frame(width: model.barWidth(availableWidth: availableWidth), height: max(model.stripHeight, 1))
        }
    }
}

/// Buttons beside the HUD's menu button, in the toolbar's own key size.
struct RemoteScreenHUDButtons: View {
    let coordinator: VNCKeyboardAccessoryCoordinator
    let style: VNCHUDButtonStyle

    var body: some View {
        let model = coordinator.hudModel
        HStack(spacing: 0) {
            if model.stripAvailable {
                foldButton(model)
            }
            if model.showsKeysButton {
                Button {
                    coordinator.toggleKeysFromHUD()
                } label: {
                    glyph(model.keysRequested ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .accessibilityLabel(model.keysRequested
                    ? String(localized: "Hide Keyboard") : String(localized: "Show Keyboard"))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: style.symbolPointSize, weight: .medium))
            .frame(width: style.size.width, height: style.size.height)
            .contentShape(Rectangle())
    }

    /// Tap folds the keys away; a long press floats or docks the bar.
    /// Not a Button: its action would also fire when a long press lifts.
    private func foldButton(_ model: RemoteScreenHUDKeysModel) -> some View {
        let modeLabel = model.isFloating
            ? String(localized: "Dock Toolbar") : String(localized: "Float Toolbar")
        return glyph(model.keysExpanded ? "chevron.forward" : "chevron.backward")
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in coordinator.setToolbarFloating(!model.isFloating) }
                    .exclusively(before: TapGesture().onEnded { model.keysExpanded.toggle() }))
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(model.keysExpanded
                ? String(localized: "Hide Toolbar Keys") : String(localized: "Show Toolbar Keys"))
            .accessibilityAction { model.keysExpanded.toggle() }
            .accessibilityAction(named: Text(modeLabel)) { coordinator.setToolbarFloating(!model.isFloating) }
    }
}

/// Hosts the keyboard toolbar's own row, on loan from the input accessory.
private struct RemoteScreenHUDKeyStrip: UIViewRepresentable {
    let coordinator: VNCKeyboardAccessoryCoordinator
    /// Width of the HUD's buttons over the main row's trailing end.
    let trailingReserve: CGFloat
    /// A floating bar drags from its keys; a docked one stays put.
    let allowsDrag: Bool

    /// The keys track their own touches. This view's own recognizer drags the
    /// HUD from any of them that has no drag of its own.
    final class Container: UIView, VNCHUDInteractiveContent, UIGestureRecognizerDelegate {
        weak var toolbar: KeyboardToolbarView?
        var allowsDrag = true

        override init(frame: CGRect) {
            super.init(frame: frame)
            let drag = VNCHUDDragGestureRecognizer()
            drag.delegate = self
            addGestureRecognizer(drag)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard allowsDrag else { return false }
            guard let view = touch.view else { return true }
            return toolbar?.allowsHostDrag(startingIn: view) ?? true
        }
    }

    final class Coordinator {
        weak var keyboard: VNCKeyboardAccessoryCoordinator?
    }

    func makeCoordinator() -> Coordinator {
        let holder = Coordinator()
        holder.keyboard = coordinator
        return holder
    }

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.backgroundColor = .clear
        update(container)
        return container
    }

    func updateUIView(_ uiView: Container, context: Context) {
        update(uiView)
    }

    private func update(_ container: Container) {
        container.allowsDrag = allowsDrag
        container.toolbar = coordinator.mountToolbarInHUD(container, trailingReserve: trailingReserve)
    }

    static func dismantleUIView(_ uiView: Container, coordinator: Coordinator) {
        coordinator.keyboard?.unmountToolbarFromHUD(uiView)
    }
}

/// The Session menu's way to float or dock the toolbar.
struct RemoteScreenFloatingToolbarMenuToggle: View {
    let coordinator: VNCKeyboardAccessoryCoordinator

    var body: some View {
        Toggle(isOn: Binding(
            get: { coordinator.hudModel.isFloating },
            set: { coordinator.setToolbarFloating($0) }
        )) {
            Label("Floating Toolbar", systemImage: "rectangle.bottomthird.inset.filled")
        }
    }
}
#endif
