//
//  MainView+HTTPCapture.swift
//  rootshell
//
//  Presents HTTP capture like the file manager: a resizable column beside the
//  terminal, a HUD over it (floating or covering it), or a sheet on iPhone.
//  The two panels share the trailing docked slot (and the overlay layer):
//  opening one in a spot the other occupies hides the other, keeping its
//  state for next time. Full size occupies every spot.
//

import SwiftUI

/// Build-agnostic accessors for shared layout and keyboard code (China builds have no HTTP capture).
extension MainView {
    var httpCaptureHoldsKeyboard: Bool {
        #if !CHINA_BUILD
        httpCaptureOwnsKeyboard
        #else
        false
        #endif
    }

    var httpCaptureDockedWidth: CGFloat {
        #if !CHINA_BUILD
        httpCaptureSidebarCurrentWidth
        #else
        0
        #endif
    }

    /// Handed to Settings so its capture rows can jump to the panel.
    var settingsOpenHTTPCapture: OpenHTTPCaptureAction? {
        #if !CHINA_BUILD && (!targetEnvironment(macCatalyst) || STANDALONE)
        OpenHTTPCaptureAction { openHTTPCaptureFromSettings() }
        #else
        nil
        #endif
    }

    /// The iPhone Settings sheet is still sliding away; the capture sheet takes focus after it.
    var httpCaptureWaitsForSettingsSheet: Bool {
        #if !CHINA_BUILD
        pendingHTTPCaptureOpen && isPhone
        #else
        false
        #endif
    }

    /// Settings has closed: open the panel it asked for.
    func flushPendingHTTPCaptureOpen() {
        #if !CHINA_BUILD
        guard pendingHTTPCaptureOpen else { return }
        pendingHTTPCaptureOpen = false
        if !showHTTPCapture { openHTTPCapture() }
        #endif
    }
}

#if !CHINA_BUILD

extension MainView {
    var httpCaptureShowsSidebar: Bool {
        showHTTPCapture && !isPhone && httpCapturePresentation == .sidebar && httpCaptureModel != nil
    }

    /// The floating or full-size HUD.
    var httpCaptureShowsOverlay: Bool {
        showHTTPCapture && !isPhone && httpCapturePresentation != .sidebar && httpCaptureModel != nil
    }

    /// The HUD and the iPhone sheet own the keyboard; the sidebar shares the window with the terminal.
    var httpCaptureOwnsKeyboard: Bool {
        showHTTPCapture && (isPhone || httpCapturePresentation.ownsKeyboard)
    }

    var httpCaptureSidebarCurrentWidth: CGFloat {
        httpCaptureShowsSidebar ? httpCaptureSidebarWidth : 0
    }

    // MARK: - Toggle

    func toggleHTTPCapture() {
        if showHTTPCapture {
            closeHTTPCapture()
        } else {
            openHTTPCapture()
        }
    }

    func openHTTPCapture() {
        let model = httpCaptureModel ?? HTTPCaptureModel()
        httpCaptureModel = model

        // Floating tools yield first, as they do for the file manager.
        showThemePickerOverlay = false
        showClipboardManager = false
        showQuickSettingsOverlay = false
        showOpenInFolderOverlay = false
        showIPLookup = false
        yieldSlotToHTTPCapture(httpCapturePresentation)
        yieldAgentInboxSlot(to: httpCapturePresentation)

        if isPhone {
            resignFirstResponderForSheetPresentation()
        } else if httpCapturePresentation == .sidebar {
            scheduleTerminalRelayout()
        }
        showHTTPCapture = true
        if httpCaptureOwnsKeyboard { setOverlayOwnsKeyboardForAllTerminals(true) }
    }

    /// Opens after Settings closes, like the connection view's Files tab: a
    /// sheet flushes from its onDismiss, the iPad panel as soon as it hides.
    func openHTTPCaptureFromSettings() {
        pendingHTTPCaptureOpen = true
        showSettings = false
    }

    func closeHTTPCapture() {
        guard showHTTPCapture else { return }
        let wasSidebar = httpCaptureShowsSidebar
        showHTTPCapture = false
        setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented)
        if wasSidebar {
            if terminals.indices.contains(selectedTabIndex) {
                _ = terminals[selectedTabIndex].focusedTerminal?.becomeFirstResponder()
            }
            scheduleTerminalRelayout()
        } else {
            restoreFirstResponderAfterSheetDismissal()
        }
    }

    func switchHTTPCapturePresentation(_ presentation: PanelPresentation) {
        guard presentation != httpCapturePresentation else { return }
        yieldSlotToHTTPCapture(presentation)
        yieldAgentInboxSlot(to: presentation)
        httpCapturePresentation = presentation
        SettingsStore.shared.set(Settings.HTTPCapture.presentation, presentation)
        setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented || httpCaptureOwnsKeyboard || fileManagerOwnsKeyboard)
        scheduleTerminalRelayout()
    }

    /// HTTP capture is about to show as `presentation`: hide the file manager
    /// if it holds that spot (docked column or overlay), or either covers the terminal.
    private func yieldSlotToHTTPCapture(_ presentation: PanelPresentation) {
        guard !isPhone, showFileManager, fileManagerPresentation.sharesSlot(with: presentation) else { return }
        closeFileManager()
    }

    /// The file manager is about to show as `presentation`: hide HTTP capture
    /// if it holds that spot.
    func yieldSlotToFileManager(_ presentation: PanelPresentation) {
        guard !isPhone, showHTTPCapture, httpCapturePresentation.sharesSlot(with: presentation) else { return }
        closeHTTPCapture()
    }

    // MARK: - Views

    @ViewBuilder
    func httpCaptureSidebarColumn(width: CGFloat, totalWidth: CGFloat) -> some View {
        if httpCaptureShowsSidebar, let model = httpCaptureModel {
            HTTPCaptureSidebarView(
                model: model,
                width: $httpCaptureSidebarWidth,
                isDragging: $httpCaptureSidebarIsDragging,
                totalWidth: totalWidth,
                theme: resolvedSheetTheme(),
                onClose: { closeHTTPCapture() },
                onSwitchPresentation: { switchHTTPCapturePresentation($0) }
            )
            .frame(width: width)
            .transition(.move(edge: .trailing))
        }
    }

    /// `fullSize` picks the full-size panel's layer or the floating one.
    @ViewBuilder
    func httpCaptureOverlays(fullSize: Bool) -> some View {
        if httpCaptureShowsOverlay, (httpCapturePresentation == .full) == fullSize, let model = httpCaptureModel {
            HTTPCaptureHUD(
                model: model,
                fills: fullSize,
                theme: resolvedSheetTheme(),
                onClose: { closeHTTPCapture() },
                onSwitchPresentation: { switchHTTPCapturePresentation($0) },
                integratedTabJoin: integratedTabsJoinCards && showsHorizontalTabHeader ? integratedTabJoin : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A fresh host per presentation; the HUD host sets up dragging and resizing once.
            .id(httpCapturePresentation)
        }
    }

    func httpCapturePhoneSheetModifier(sheetTheme: ResolvedSheetTheme) -> HTTPCapturePhoneSheetModifier {
        HTTPCapturePhoneSheetModifier(
            isPresented: Binding(
                get: { showHTTPCapture && isPhone },
                set: { if !$0 { closeHTTPCapture() } }
            ),
            model: httpCaptureModel,
            sheetTheme: sheetTheme,
            onClose: { closeHTTPCapture() }
        )
    }
}

struct HTTPCapturePhoneSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let model: HTTPCaptureModel?
    let sheetTheme: ResolvedSheetTheme
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let model {
                HTTPCaptureView(model: model, style: .sheet, onClose: onClose, onSwitchPresentation: nil)
                    .presentationDetents([.large])
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
        }
    }
}

#endif
