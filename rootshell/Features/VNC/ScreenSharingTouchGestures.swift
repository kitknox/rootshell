//
//  ScreenSharingTouchGestures.swift
//  rootshell
//
//  Live touch gesture settings and the local navigation swipe for VNC
//  and KVM screens.
//

import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import rootshellVNC

/// Reads the touch gesture settings as one package configuration. Like
/// pointer speed it is read live, so a change reaches open sessions.
struct ScreenSharingTouchGestureSettings: DynamicProperty {
    @Setting(Settings.ScreenSharing.touchHoldDelay) private var holdDelay
    @Setting(Settings.ScreenSharing.showsHeldButton) private var showsHeldButton
    @Setting(Settings.ScreenSharing.swipeUpAction) private var swipeUp
    @Setting(Settings.ScreenSharing.swipeDownAction) private var swipeDown
    @Setting(Settings.ScreenSharing.swipeLeftAction) private var swipeLeft
    @Setting(Settings.ScreenSharing.swipeRightAction) private var swipeRight

    var configuration: RemoteTouchGestureConfiguration {
        RemoteTouchGestureConfiguration(
            holdDuration: holdDelay,
            swipeUp: swipeUp.remoteAction,
            swipeDown: swipeDown.remoteAction,
            swipeLeft: swipeLeft.remoteAction,
            swipeRight: swipeRight.remoteAction,
            showsButtonIndicator: showsHeldButton)
    }
}

extension ScreenSharingSwipeAction {
    var remoteAction: RemoteSwipeAction {
        switch self {
        case .off: .none
        case .missionControl: .missionControl
        case .applicationWindows: .applicationWindows
        case .moveLeftASpace: .moveLeftASpace
        case .moveRightASpace: .moveRightASpace
        }
    }
}

/// The local tab and pane swipe over a remote screen. It shares fingers with
/// the remote gestures, so it stands down for the ones that claim a stroke.
final class RemoteScreenNavigationPan: UIPanGestureRecognizer {
    private var usesFourFingers: Bool {
        SettingsStore.shared.value(Settings.ScreenSharing.fourFingerNavigation)
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        applyFingerCount()
    }

    /// True when the remote three-finger swipe in `direction` has an action
    /// and this pan uses the same fingers.
    func yieldsToRemoteSwipe(_ direction: SwipeDirection) -> Bool {
        guard !usesFourFingers else { return false }
        let store = SettingsStore.shared
        let action = switch direction {
        case .left: store.value(Settings.ScreenSharing.swipeLeftAction)
        case .right: store.value(Settings.ScreenSharing.swipeRightAction)
        }
        return action != .off
    }

    /// A recognized remote button hold owns its fingers: refusing to run
    /// beside it lets UIKit fail this pan when the hold begins.
    func recognizesSimultaneously(with other: UIGestureRecognizer) -> Bool {
        !(other is MultiFingerHoldGestureRecognizer)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Read per stroke, so a settings change reaches open sessions.
        if numberOfTouches == 0 { applyFingerCount() }
        super.touchesBegan(touches, with: event)
    }

    private func applyFingerCount() {
        let count = usesFourFingers ? 4 : 3
        maximumNumberOfTouches = max(maximumNumberOfTouches, count)
        minimumNumberOfTouches = count
        maximumNumberOfTouches = count
    }
}
