import UIKit

/// User intent to keep the software keyboard hidden, scoped to a window so
/// tab switches and overlay round trips inside that window re-apply it
/// instead of re-showing the keyboard. Session-only.
indirect enum SoftwareKeyboardHideIntent: Equatable {
    case none
    /// Hidden via the toolbar chevron. `pinned` (long press) survives terminal
    /// taps; only the chevron restores it.
    case hidden(pinned: Bool)
    /// Shown by a one-shot custom key; the next input returns to `returningTo`
    /// (`.none` is the hardware keyboard's toolbar without keys).
    case oneShot(returningTo: SoftwareKeyboardHideIntent)

    var isHidden: Bool { if case .hidden = self { true } else { false } }
    var isPinned: Bool { self == .hidden(pinned: true) }
    var isOneShot: Bool { if case .oneShot = self { true } else { false } }
}

@MainActor
final class SoftwareKeyboardHideIntentStore {
    static let shared = SoftwareKeyboardHideIntentStore()

    private final class Box {
        var intent: SoftwareKeyboardHideIntent
        /// The host that opened a `.oneShot`, and the keyboard state whose
        /// key request it set; the state outlives a closed host.
        weak var oneShotOwner: AnyObject?
        weak var oneShotRequestState: AnyObject?
        init(_ intent: SoftwareKeyboardHideIntent) { self.intent = intent }
    }

    private let intents = NSMapTable<UIWindow, Box>.weakToStrongObjects()

    func intent(for window: UIWindow?) -> SoftwareKeyboardHideIntent {
        guard let window else { return .none }
        return intents.object(forKey: window)?.intent ?? .none
    }

    func oneShotOwner(for window: UIWindow?) -> AnyObject? {
        guard let window else { return nil }
        return intents.object(forKey: window)?.oneShotOwner
    }

    func oneShotRequestState(for window: UIWindow?) -> AnyObject? {
        guard let window else { return nil }
        return intents.object(forKey: window)?.oneShotRequestState
    }

    /// The owner and request state are kept only with a `.oneShot` intent.
    func set(_ intent: SoftwareKeyboardHideIntent, for window: UIWindow?,
             oneShotOwner: AnyObject? = nil, oneShotRequestState: AnyObject? = nil) {
        guard let window else { return }
        guard intent != .none else {
            intents.removeObject(forKey: window)
            return
        }
        let box = Box(intent)
        if intent.isOneShot {
            box.oneShotOwner = oneShotOwner
            box.oneShotRequestState = oneShotRequestState
        }
        intents.setObject(box, forKey: window)
    }
}
