//
//  ExternalInputProxy.swift
//  rootshell
//
//  Residual input forwarding for the external display: keyboard input that
//  originates on a DEVICE terminal while typing focus targets a VNC pane on
//  the external display. The terminal-typed redirectTarget() cannot express
//  that sink (it resolves TerminalViews only).
//

#if !targetEnvironment(macCatalyst)
import UIKit
import rootshellVNC

@MainActor
final class ExternalInputProxy {

    enum Sink {
        case terminal(Ghostty.TerminalView)
        case vnc(VNCPaneView)
        case none
    }

    func currentSink() -> Sink {
        guard let pane = ExternalDisplayManager.shared.redirectPane() else { return .none }
        if let terminal = pane as? Ghostty.TerminalView { return .terminal(terminal) }
        if let vnc = pane as? VNCPaneView { return .vnc(vnc) }
        return .none
    }

    /// Returns false when the sink is not VNC (callers fall through).
    func forwardInsertTextToVNC(_ text: String) -> Bool {
        guard case .vnc(let pane) = currentSink() else { return false }
        pane.remoteInputBridge.injectText(text)
        return true
    }

    func forwardDeleteBackwardToVNC() -> Bool {
        guard case .vnc(let pane) = currentSink() else { return false }
        pane.remoteInputBridge.injectKeysymTap(KeyboardInputHandler.keysymBackspace)
        return true
    }

    /// Special keys and modifiers go over as keysyms; plain character keys
    /// are not consumed so UIKit's insertText delivers them.
    func forwardPressesToVNC(_ presses: Set<UIPress>, down: Bool) -> Bool {
        guard case .vnc(let pane) = currentSink() else { return false }
        let bridge = pane.remoteInputBridge
        for press in presses {
            guard let key = press.key,
                  let keysym = Self.keysym(forKeyCode: key.keyCode) else { continue }
            bridge.injectKeysym(downFlag: down, keysym: keysym)
        }
        return true
    }

    private static func keysym(forKeyCode keyCode: UIKeyboardHIDUsage) -> UInt32? {
        switch keyCode {
        case .keyboardReturnOrEnter: return KeyboardInputHandler.keysymReturn
        case .keyboardEscape: return KeyboardInputHandler.keysymEscape
        case .keyboardDeleteOrBackspace: return KeyboardInputHandler.keysymBackspace
        case .keyboardDeleteForward: return KeyboardInputHandler.keysymDelete
        case .keyboardTab: return KeyboardInputHandler.keysymTab
        case .keyboardUpArrow: return KeyboardInputHandler.keysymUp
        case .keyboardDownArrow: return KeyboardInputHandler.keysymDown
        case .keyboardLeftArrow: return KeyboardInputHandler.keysymLeft
        case .keyboardRightArrow: return KeyboardInputHandler.keysymRight
        case .keyboardHome: return KeyboardInputHandler.keysymHome
        case .keyboardEnd: return KeyboardInputHandler.keysymEnd
        case .keyboardPageUp: return KeyboardInputHandler.keysymPageUp
        case .keyboardPageDown: return KeyboardInputHandler.keysymPageDown
        case .keyboardF1: return KeyboardInputHandler.keysymF1
        case .keyboardF2: return KeyboardInputHandler.keysymF2
        case .keyboardF3: return KeyboardInputHandler.keysymF3
        case .keyboardF4: return KeyboardInputHandler.keysymF4
        case .keyboardF5: return KeyboardInputHandler.keysymF5
        case .keyboardF6: return KeyboardInputHandler.keysymF6
        case .keyboardF7: return KeyboardInputHandler.keysymF7
        case .keyboardF8: return KeyboardInputHandler.keysymF8
        case .keyboardF9: return KeyboardInputHandler.keysymF9
        case .keyboardF10: return KeyboardInputHandler.keysymF10
        case .keyboardF11: return KeyboardInputHandler.keysymF11
        case .keyboardF12: return KeyboardInputHandler.keysymF12
        case .keyboardLeftShift: return KeyboardInputHandler.keysymShiftL
        case .keyboardRightShift: return KeyboardInputHandler.keysymShiftR
        case .keyboardLeftControl: return KeyboardInputHandler.keysymControlL
        case .keyboardRightControl: return KeyboardInputHandler.keysymControlR
        case .keyboardLeftAlt: return KeyboardInputHandler.keysymAltL
        case .keyboardRightAlt: return KeyboardInputHandler.keysymAltR
        case .keyboardLeftGUI: return KeyboardInputHandler.keysymSuperL
        case .keyboardRightGUI: return KeyboardInputHandler.keysymSuperR
        default: return nil
        }
    }
}
#endif
