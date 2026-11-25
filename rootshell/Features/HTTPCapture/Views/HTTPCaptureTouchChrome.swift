//
//  HTTPCaptureTouchChrome.swift
//  rootshell
//
//  HTTP capture's header actions as standalone controls, shared by the
//  header and the side rail that carries them on a rail display.
//

#if !CHINA_BUILD

import SwiftUI

/// Record, or Clear and Stop while recording.
struct CaptureRecordControls: View {
    var touchSized = false
    /// Icons only, for the side rail.
    var iconOnly = false

    private var controller: CaptureController { .shared }

    var body: some View {
        if controller.isStarting {
            ProgressView().controlSize(.small)
                .panelTouchTarget(touchSized)
        } else if controller.isRecording {
            Button {
                Task { await controller.clearActiveSession() }
            } label: {
                Label(String(localized: "Clear", comment: "HTTP capture: clear the recording session"), systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .panelTouchTarget(touchSized)
            }
            .disabled(controller.isStopping)
            .help(String(localized: "Clear the captured requests and keep recording", comment: "HTTP capture clear tooltip"))
            stopButton
        } else {
            Button {
                Task { await controller.start() }
            } label: {
                label(String(localized: "Record", comment: "HTTP capture: start recording"), systemImage: "record.circle")
            }
            .help(String(localized: "Start a new capture session", comment: "HTTP capture record tooltip"))
        }
    }

    private var stopButton: some View {
        Button {
            Task { await controller.stop() }
        } label: {
            label(String(localized: "Stop", comment: "HTTP capture: stop recording"), systemImage: "stop.circle.fill")
                .foregroundStyle(.red)
        }
        .disabled(controller.isStopping)
        .help(String(localized: "Stop recording", comment: "HTTP capture stop tooltip"))
    }

    @ViewBuilder
    private func label(_ title: String, systemImage: String) -> some View {
        if iconOnly {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
                .panelTouchTarget(touchSized, minWidth: 0)
        }
    }
}

#if !targetEnvironment(macCatalyst) && !os(visionOS)
/// The panel's actions as side-rail items, for the window's rail or a sheet's own.
@available(iOS 27.1, *)
struct HTTPCaptureRailItems: ToolbarContent {
    let model: HTTPCaptureModel
    var presentation: PanelPresentation?
    var onSwitchPresentation: ((PanelPresentation) -> Void)?
    let onClose: () -> Void

    var body: some ToolbarContent {
        // A gap sets the panel's items apart from the window's own.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onClose) {
                Label(String(localized: "Close HTTP Capture", comment: "HTTP capture close button"), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
        }
        .visibilityPriority(.high)
        // One slot that swaps Record and Stop; UIKit can drop items that come and go.
        ToolbarItem(placement: .topBarTrailing) {
            CaptureRecordRailButton()
        }
        .visibilityPriority(.high)
        ToolbarItem(placement: .topBarTrailing) {
            CaptureClearRailButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
            CaptureMoreMenu(model: model)
                .equatable()
        }
        if let presentation, let onSwitchPresentation {
            ToolbarItem(placement: .topBarTrailing) {
                PanelPresentationMenu(current: presentation, onSwitch: onSwitchPresentation)
                    .equatable()
            }
            .visibilityPriority(.low)
        }
    }
}

private struct CaptureRecordRailButton: View {
    private var controller: CaptureController { .shared }

    var body: some View {
        let recording = controller.isRecording
        Button {
            Task { recording ? await controller.stop() : await controller.start() }
        } label: {
            Label(recording
                  ? String(localized: "Stop", comment: "HTTP capture: stop recording")
                  : String(localized: "Record", comment: "HTTP capture: start recording"),
                  systemImage: recording ? "stop.circle.fill" : "record.circle")
        }
        .labelStyle(.iconOnly)
        .tint(recording ? .red : nil)
        .disabled(controller.isStarting || controller.isStopping)
    }
}

private struct CaptureClearRailButton: View {
    private var controller: CaptureController { .shared }

    var body: some View {
        Button {
            Task { await controller.clearActiveSession() }
        } label: {
            Label(String(localized: "Clear", comment: "HTTP capture: clear the recording session"), systemImage: "trash")
        }
        .labelStyle(.iconOnly)
        // A clear in flight replaces the session; a queued second one would empty the new one.
        .disabled(!controller.isRecording || controller.isStopping || controller.isStarting)
    }
}
#endif

/// Rail hosting for the phone sheet, applied inside the narrow layout's own
/// navigation stack. The list root hides the bar off a rail display; a
/// pushed detail keeps its own bar and only gains the items.
struct HTTPCaptureSheetRail: ViewModifier {
    let active: Bool
    let isRoot: Bool
    let model: HTTPCaptureModel
    let onClose: () -> Void

    func body(content: Content) -> some View {
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        if #available(iOS 27.1, *), UIDevice.current.userInterfaceIdiom == .phone {
            if isRoot {
                content.panelSheetRail(active) {
                    HTTPCaptureRailItems(model: model, onClose: onClose)
                }
            } else {
                content.toolbar {
                    if active { HTTPCaptureRailItems(model: model, onClose: onClose) }
                }
            }
        } else {
            rootFallback(content)
        }
        #else
        rootFallback(content)
        #endif
    }

    @ViewBuilder
    private func rootFallback(_ content: Content) -> some View {
        if isRoot {
            content.toolbar(.hidden, for: .navigationBar)
        } else {
            content
        }
    }
}

#endif
