import SwiftUI
import UIKit

// MARK: - Brightness Boost HUD SwiftUI View

/// Floating "liquid glass" HUD with a slider that drives the global HDR
/// brightness-boost gain. Reachable from a hardware keybind and the on-screen
/// keyboard toolbar button. Cross-platform (iOS/iPadOS/Catalyst/visionOS) so it
/// works wherever the keybind/toolbar can fire — unlike the Catalyst-gated
/// dimension overlay it is modeled on.
struct BrightnessBoostHUDView: View {
    /// Upper bound for the slider, already clamped to the display's EDR headroom
    /// and `BrightnessManager.maxGainCap`.
    let maxGain: Double

    /// Whether the display currently has usable EDR headroom. When false the
    /// slider is disabled and a hint is shown (SDR panel, or display already at
    /// full brightness with no headroom left).
    let hasHeadroom: Bool

    /// Called on every interaction so the host can restart the auto-dismiss timer.
    var onInteract: () -> Void

    /// Reset the gain back to SDR.
    var onReset: () -> Void

    private var sliderMax: Double { max(maxGain, 1.05) }

    var body: some View {
        // `@Bindable` on the shared singleton inside `body` is the recommended
        // pattern for binding a Slider to a global @Observable; reads of
        // `manager.gain` here still register SwiftUI dependencies so external
        // changes re-render the HUD.
        @Bindable var manager = BrightnessManager.shared
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "sun.min")
                    .foregroundStyle(.secondary)
                Slider(value: $manager.gain, in: 1.0...sliderMax, step: 0.05)
                    .frame(width: 200)
                    .disabled(!hasHeadroom)
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.2f×", manager.gain))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            .foregroundStyle(.primary)
            .onChange(of: manager.gain) { _, _ in onInteract() }

            if !hasHeadroom {
                Text("No HDR headroom at this display brightness")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Always present so the HUD keeps a constant height as the gain
            // crosses 1.0; greyed out and disabled when there's nothing to reset.
            Button("Reset", action: onReset)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(manager.isBoosted ? .primary : .secondary)
                .disabled(!manager.isBoosted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .brightnessHUDBackground()
    }
}

private extension View {
    /// Liquid-glass background matching `dimensionOverlayBackground()`, but not
    /// Catalyst-gated so the brightness HUD can use it everywhere.
    @ViewBuilder
    func brightnessHUDBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        #if os(visionOS)
        self
            .background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        }
        #endif
    }
}

// MARK: - Brightness HUD lifecycle

extension Ghostty.TerminalView {
    /// The display's maximum potential EDR headroom (ratio of peak EDR white to
    /// SDR white). 1.0 means no EDR (SDR panel, visionOS, or at full brightness).
    /// We use `potentialEDRHeadroom` (stable) rather than `currentEDRHeadroom`
    /// (which ramps and collapses at max brightness) so the slider doesn't jump.
    var edrPotentialHeadroom: CGFloat {
        #if os(visionOS)
        return 1.0
        #else
        return window?.windowScene?.screen.potentialEDRHeadroom ?? 1.0
        #endif
    }

    /// The HUD's bottom offset, clear of the band drawn under the toolbar and keyboard.
    /// A short pane shrinks the 80 pt gap; one shorter than the HUD keeps its top
    /// (the slider) at the pane's top.
    private func brightnessHUDBottomOffset(hudHeight: CGFloat) -> CGFloat {
        let room = bounds.height - bottomUnderlap - hudHeight
        let gap = room >= 0 ? min(80, room / 2) : room
        return -(bottomUnderlap + gap)
    }

    private func brightnessHUDHeight(_ host: UIHostingController<BrightnessBoostHUDView>) -> CGFloat {
        let height = host.view.intrinsicContentSize.height
        return height > 0 ? height : host.sizeThatFits(in: bounds.size).height
    }

    /// Re-fit the HUD after the pane's size or underlap changes.
    func updateBrightnessHUDPlacement() {
        guard let host = brightnessHUDHost, let constraint = brightnessHUDBottomConstraint else { return }
        let offset = brightnessHUDBottomOffset(hudHeight: brightnessHUDHeight(host))
        if constraint.constant != offset { constraint.constant = offset }
    }

    /// Toggle the brightness HUD: open it if hidden, dismiss it if shown.
    func toggleBrightnessHUD() {
        if brightnessHUDHost != nil {
            hideBrightnessHUD()
        } else {
            showBrightnessHUD()
        }
    }

    /// Show the brightness HUD (or just re-arm its dismiss timer if already up).
    func showBrightnessHUD() {
        if brightnessHUDHost != nil {
            scheduleBrightnessHUDDismiss()
            return
        }

        let headroom = edrPotentialHeadroom
        let maxGain = min(Double(headroom), BrightnessManager.maxGainCap)
        let hasHeadroom = BrightnessManager.isHDRBoostAvailable && headroom > 1.02

        let view = BrightnessBoostHUDView(
            maxGain: maxGain,
            hasHeadroom: hasHeadroom,
            onInteract: { [weak self] in self?.scheduleBrightnessHUDDismiss() },
            onReset: { [weak self] in
                BrightnessManager.shared.reset()
                self?.scheduleBrightnessHUDDismiss()
            }
        )

        let host = UIHostingController(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addSubview(host.view)
        let bottom = host.view.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: brightnessHUDBottomOffset(hudHeight: brightnessHUDHeight(host)))
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottom,
        ])
        brightnessHUDHost = host
        brightnessHUDBottomConstraint = bottom

        LifecycleDebugLogger.shared.checkpoint("FG.hdr.hud.show", ms: nil, [
            ("headroom", Double(headroom)),
            ("maxGain", maxGain),
            ("hasHeadroom", hasHeadroom),
        ])

        // Animate in (alpha only — scale transforms cause position artifacts).
        host.view.alpha = 0
        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
            host.view.alpha = 1.0
        }
        scheduleBrightnessHUDDismiss()
    }

    /// (Re)start the auto-dismiss timer. Called on every slider interaction so
    /// the HUD stays visible while the user is adjusting it.
    private func scheduleBrightnessHUDDismiss() {
        brightnessHUDHideTask?.cancel()
        brightnessHUDHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hideBrightnessHUD()
        }
    }

    /// Animate the HUD out and remove it.
    func hideBrightnessHUD() {
        brightnessHUDHideTask?.cancel()
        brightnessHUDHideTask = nil
        guard let host = brightnessHUDHost else { return }
        LifecycleDebugLogger.shared.checkpoint("FG.hdr.hud.hide", ms: nil, [
            ("gain", BrightnessManager.shared.gain),
        ])
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn, animations: {
            host.view.alpha = 0
        }, completion: { [weak self] _ in
            host.view.removeFromSuperview()
            self?.brightnessHUDHost = nil
            self?.brightnessHUDBottomConstraint = nil
        })
    }
}
