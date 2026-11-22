//
//  SystemKeyboardCrashGuard.swift
//  rootshell
//

import UIKit
import os

/// iOS 27.2-27.3: UIKit's space-bar language indicator can read one past its
/// key array, from an input-mode switch or any `reloadInputViews`. Catch that
/// and show no indicator. Remove once Apple fixes it.
enum SystemKeyboardCrashGuard {
    private static var installed = false

    static func install() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard !installed else { return }
        installed = true
        let selector = NSSelectorFromString("activationIndicatorView")
        guard let cls = NSClassFromString("UIKeyboardLayoutStar"),
              let method = class_getInstanceMethod(cls, selector),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding).hasPrefix("@") else { return }
        typealias Original = @convention(c) (AnyObject, Selector) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject) -> AnyObject? = { layout in
            var result: AnyObject?
            if let exception = AVExceptionCatcher.catchException({ result = original(layout, selector) }) {
                Logger(subsystem: "com.rootshell", category: "Keyboard")
                    .error("Keyboard indicator exception caught: \(exception.reason ?? exception.name.rawValue, privacy: .public)")
                return nil
            }
            return result
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        #endif
    }
}
