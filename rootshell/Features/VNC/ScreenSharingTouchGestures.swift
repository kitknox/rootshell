//
//  ScreenSharingTouchGestures.swift
//  rootshell
//
//  Live touch gesture settings for VNC and KVM screens.
//

import SwiftUI
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
