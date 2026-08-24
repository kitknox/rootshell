//
//  ExternalSceneAccessoryRegistrar.swift
//  rootshell
//
//  iOS 27 external display path. Starting with apps built against the
//  iOS 27 SDK, the system no longer offers windowExternalDisplayNonInteractive
//  scenes automatically; the app must register a UISceneAccessory on a
//  visible view controller. Binaries built with the iOS 26 SDK keep the
//  legacy automatic behavior even on iOS 27 devices, so the typed
//  UISceneAccessory code is compiled only under Xcode 27+ (Swift 6.4) and
//  this file collapses to a nil factory on today's toolchain.
//

#if !targetEnvironment(macCatalyst)
import UIKit

@MainActor
protocol ExternalSceneAccessoryRegistering: AnyObject {
    func ensureRegistered(on viewController: UIViewController)
    func unregister()
}

@MainActor
enum ExternalSceneAccessoryFactory {
    static func make() -> ExternalSceneAccessoryRegistering? {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return ExternalSceneAccessoryRegistrar()
        }
        #endif
        return nil
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
@MainActor
final class ExternalSceneAccessoryRegistrar: ExternalSceneAccessoryRegistering {
    private var registration: UISceneAccessoryRegistration?
    private weak var registeredViewController: UIViewController?

    func ensureRegistered(on viewController: UIViewController) {
        guard registeredViewController !== viewController else { return }
        unregister()

        let configuration = UISceneConfiguration(
            name: "External Display",
            sessionRole: .windowExternalDisplayNonInteractive
        )
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
        registration = viewController.registerSceneAccessory(accessory)
        registeredViewController = viewController
    }

    func unregister() {
        if let registration, let registeredViewController {
            registeredViewController.unregisterSceneAccessory(registration)
        }
        registration = nil
        registeredViewController = nil
    }
}
#endif
#endif
