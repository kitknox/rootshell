//
//  DraggableTabBar.swift
//  rootshell
//
//  Catalyst window-drag regions used by the integrated top tab bar.
//

import SwiftUI

#if targetEnvironment(macCatalyst)
import AppKit
import UIKit

extension View {
    /// Placeholder modifier - drag blocking is now handled by WindowAccessor
    func blockWindowDrag(when enabled: Bool) -> some View {
        self  // Pass through unchanged - AppKit DragBlockerView handles this
    }
}

/// A UIKit-hosted region that starts AppKit's native window drag using the
/// current mouse-down event. Hosting a real UIView is important: a clear
/// SwiftUI shape does not reliably win hit testing over a UIViewRepresentable
/// terminal beneath it on Catalyst.
struct CatalystWindowDragRegion: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = CatalystWindowDragView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class CatalystWindowDragView: UIView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let sceneID = window?.windowScene?.session.persistentIdentifier,
              let nsApplicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let nsApplication = nsApplicationClass.value(forKey: "sharedApplication") as? NSObject,
              let nsWindows = nsApplication.value(forKey: "windows") as? [NSObject],
              let nsWindow = nsWindows.first(where: {
                  WindowAccessor.sceneSessionId(for: $0) == sceneID
              }),
              !isFullScreen(nsWindow),
              let mouseEvent = nsApplication.value(forKey: "currentEvent") as? NSObject else {
            super.touchesBegan(touches, with: event)
            return
        }

        let performWindowDragSelector = NSSelectorFromString("performWindowDragWithEvent:")
        guard nsWindow.responds(to: performWindowDragSelector) else {
            super.touchesBegan(touches, with: event)
            return
        }

        WindowDragObserver.shared.dragStripTouchBegan()
        nsWindow.perform(performWindowDragSelector, with: mouseEvent)
        WindowDragObserver.shared.dragStripTouchEnded()
    }

    private func isFullScreen(_ nsWindow: NSObject) -> Bool {
        guard let styleMask = nsWindow.value(forKey: "styleMask") as? UInt else {
            return false
        }
        // NSWindowStyleMaskFullScreen. Referenced by raw value because
        // NSWindow/NSApplication APIs are unavailable at compile time to
        // Mac Catalyst even though the backing AppKit objects exist.
        let fullScreenStyleMask: UInt = 1 << 14
        return styleMask & fullScreenStyleMask != 0
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        WindowDragObserver.shared.dragStripTouchEnded()
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        WindowDragObserver.shared.dragStripTouchEnded()
        super.touchesCancelled(touches, with: event)
    }
}

#endif
