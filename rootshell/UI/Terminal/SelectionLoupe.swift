//
//  SelectionLoupe.swift
//  rootshell
//
//  Thin wrapper over the system text loupe (UITextLoupeSession) shown while
//  selecting text or dragging a selection handle. visionOS has no native
//  loupe, so `begin` returns nil there. Mac Catalyst always uses the custom loupe.
//

import UIKit

extension Ghostty {

    @MainActor
    final class SelectionLoupe {

        #if !os(visionOS)
        private let session: UITextLoupeSession

        private init(session: UITextLoupeSession) {
            self.session = session
        }
        #endif

        /// Coordinates are in `view`'s space. `widget` is the handle the drag
        /// started from (animation origin), nil for finger/caret drags. If the
        /// system declines our custom handle as a widget, retry without it.
        static func begin(at point: CGPoint, in view: UIView, fromSelectionWidgetView widget: UIView?) -> SelectionLoupe? {
            #if os(visionOS)
            return nil
            #else
            guard view.window != nil else { return nil }
            let session = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: widget, in: view)
                ?? (widget == nil ? nil : UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: view))
            guard let session else { return nil }
            return SelectionLoupe(session: session)
            #endif
        }

        /// Pass `tracksCaret: true` with a valid `caretRect` to pin the loupe to
        /// the caret; `false` with `.null` to follow the touch point.
        func move(to point: CGPoint, caretRect: CGRect, tracksCaret: Bool) {
            #if !os(visionOS)
            session.move(to: point, withCaretRect: caretRect, trackingCaret: tracksCaret)
            #endif
        }

        func invalidate() {
            #if !os(visionOS)
            session.invalidate()
            #endif
        }
    }
}

