import SwiftUI
import UIKit

extension RemoteScreenPane {
    private var edrPotentialHeadroom: CGFloat {
        #if os(visionOS)
        return 1.0
        #else
        return window?.windowScene?.screen.potentialEDRHeadroom ?? 1.0
        #endif
    }

    func toggleBrightnessHUD() {
        if brightnessHUDHost == nil {
            showBrightnessHUD()
        } else {
            hideBrightnessHUD()
        }
    }

    private func showBrightnessHUD() {
        if brightnessHUDHost != nil {
            scheduleBrightnessHUDDismiss()
            return
        }

        let headroom = edrPotentialHeadroom
        let maxGain = min(Double(headroom), BrightnessManager.maxGainCap)
        let hasHeadroom = BrightnessManager.isHDRBoostAvailable && headroom > 1.02
        let hud = BrightnessBoostHUDView(
            maxGain: maxGain,
            hasHeadroom: hasHeadroom,
            onInteract: { [weak self] in self?.scheduleBrightnessHUDDismiss() },
            onReset: { [weak self] in
                BrightnessManager.shared.reset()
                self?.scheduleBrightnessHUDDismiss()
            })

        let host = UIHostingController(rootView: hud)
        host.sizingOptions = [.intrinsicContentSize]
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -80),
        ])
        brightnessHUDHost = host

        host.view.alpha = 0
        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
            host.view.alpha = 1
        }
        scheduleBrightnessHUDDismiss()
    }

    private func scheduleBrightnessHUDDismiss() {
        brightnessHUDHideTask?.cancel()
        brightnessHUDHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hideBrightnessHUD()
        }
    }

    func hideBrightnessHUD(animated: Bool = true) {
        brightnessHUDHideTask?.cancel()
        brightnessHUDHideTask = nil
        guard let host = brightnessHUDHost else { return }

        let finish: () -> Void = { [weak self, weak host] in
            host?.view.removeFromSuperview()
            self?.brightnessHUDHost = nil
        }
        guard animated else {
            finish()
            return
        }
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: .curveEaseIn,
            animations: { host.view.alpha = 0 },
            completion: { _ in finish() })
    }
}
