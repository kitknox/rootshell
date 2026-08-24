//
//  MainView+ChangeHandlers.swift
//  rootshell
//
//  Lifecycle and onChange handler pipeline for MainView's body.
//  Extracted from MainView.swift for build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

extension MainView {

    // MARK: - Lifecycle and Change Handler Pipeline

    @ViewBuilder
    func applyLifecycleHandlers<V: View>(_ view: V) -> some View {
        // Note: embedded mosh/trzsz/ghostty session-change notifications used to
        // bump `tabBarVersion` here to force the tab bar to re-render. Combined
        // with `.id(tabBarVersion)` (since removed) that tore down and rebuilt
        // the entire tab subtree on every session-change. Phase 3 introduces
        // per-tab @Observable observation; until then the roam-protocol
        // indicator may lag a frame on these transitions, which is acceptable.
        let base = view
            .onAppear(perform: handleOnAppear)
            .onDisappear(perform: handleOnDisappear)
            // An already-open terminal window should claim document URLs
            // before the WindowGroup scene matcher creates another window.
            // `allowing` MUST stay "*": it is the set of events an existing
            // window may receive at all, and narrowing it makes iPadOS spawn
            // a new empty window for anything outside the set — including
            // plain app-icon activations and ssh/mosh/rootshell URLs.
            .handlesExternalEvents(preferring: ["file://"], allowing: ["*"])
            .onOpenURL { url in
                guard url.isFileURL else { return }
                FileOpenCoordinator.shared.handleIncomingFileURL(
                    url,
                    targetWindowID: windowId
                )
            }

        applyChangeHandlers(base)
    }

    @ViewBuilder
    private func applyChangeHandlers<V: View>(_ view: V) -> some View {
        let base = view
            // Single deterministic keyboard-ownership gate. Whenever ANY
            // overlay/sheet presence changes, push the new state to every
            // terminal in the window: gate up → terminals refuse first
            // responder (the overlay's field owns the keyboard); gate down →
            // `setOverlayOwnsKeyboard(false)` reconciles first responder back to
            // the focused terminal. Overlay→overlay handoffs (e.g. tab sidebar
            // "+" → connection sidebar, or → settings) keep `isAnySheetPresented`
            // true throughout, so the gate never flaps mid-transition. This
            // replaces the racing per-view +50/250/300/350/450/600ms retries
            // that used to fight the sidebar's search field.
            .onChange(of: isAnySheetPresented) { oldValue, newValue in
                Ghostty.logger.info("onChange(isAnySheetPresented) \(oldValue) -> \(newValue) showingTabSwitcher=\(showingTabSwitcher)")
                setOverlayOwnsKeyboardForAllTerminals(newValue)
            }
            .onChange(of: terminals.count) { oldCount, newCount in
                if newCount > 0 {
                    windowClosingAfterTabTransfer = false
                }
                handleTerminalCountChange(oldCount: oldCount, newCount: newCount)
            }
            .onChange(of: selectedTabIndex) { oldValue, newValue in
                handleSelectedTabChange(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: showConnectionSidebar) { oldValue, newValue in
                handleShowConnectionSheetChange(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: showSettings) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: showToolbarSettings) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: showClipboardManager) { oldValue, newValue in
                if oldValue && !newValue {
                    // Single reset point for every close path (Esc, Enter-paste,
                    // 3rd Cmd+Shift+C press, X button, menu action).
                    clipboardManagerKeyboardMode = false
                    if UIDevice.current.userInterfaceIdiom != .phone {
                        restoreFirstResponderAfterHUDDismissal()
                    }
                }
            }
            .onChange(of: showingTabSwitcher) { oldValue, newValue in
                if newValue {
                    if tabSidebarIsDocked {
                        // Docked sidebar sits beside the terminal and never owns
                        // the keyboard; its search field does NOT auto-focus on
                        // appear (VerticalTabSidebar gates on !isDocked). Resigning
                        // here would leave first responder nowhere — the terminal
                        // loses it and nothing reclaims it (typing beeps on a
                        // toggle off→on). Keep/repair terminal focus instead (a
                        // no-op when the terminal already holds it).
                        restoreFirstResponderAfterSheetDismissal()
                    } else {
                        resignFirstResponderForSheetPresentation()
                    }
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: connectionInfoToShow != nil) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: tmuxDashboardRequest != nil) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal(includeCatalystDismissalRetry: true)
                }
            }

        applyRemainingHandlers(base)
    }

    @ViewBuilder
    private func applyRemainingHandlers<V: View>(_ view: V) -> some View {
        let chained = view
            .onChange(of: showPasswordPromptSheet) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: showKeyResolutionSheet) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: trzszTransferOriginRequest != nil) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: trzszTransferIncomingOffer != nil) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: alerts.showNewHostAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.newHost)
                } else if oldValue {
                    if alerts.presentedKind == .newHost {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: alerts.showKeyChangedAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.keyChanged)
                } else if oldValue {
                    if alerts.presentedKind == .keyChanged {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: alerts.showAgentApprovalAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.agentApproval)
                } else if oldValue {
                    if alerts.presentedKind == .agentApproval {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: alerts.showGPGAgentApprovalAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.gpgAgentApproval)
                } else if oldValue {
                    if alerts.presentedKind == .gpgAgentApproval {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }

        applyTailHandlers(chained)
    }

    // Split from applyRemainingHandlers: the single chain outgrew the
    // type-checker's budget when the VNC alert handler joined it.
    @ViewBuilder
    private func applyTailHandlers<V: View>(_ view: V) -> some View {
        applyVNCFullScreenHandlers(view)
            .onChange(of: alerts.showHelperMissingAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.helperMissing)
                } else if oldValue {
                    if alerts.presentedKind == .helperMissing {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: alerts.showVNCProfileInvalidAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.vncProfileInvalid)
                } else if oldValue {
                    if alerts.presentedKind == .vncProfileInvalid {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: alerts.showVNCHighPerformanceTransportAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.vncHighPerformanceTransport)
                } else if oldValue {
                    if alerts.presentedKind == .vncHighPerformanceTransport {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            #if !CHINA_BUILD
            .onChange(of: alerts.showAIAgentSSHRequiredAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.aiAgentUnsupported)
                } else if oldValue {
                    if alerts.presentedKind == .aiAgentUnsupported {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: alerts.showVoiceAgentAPIKeyAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.voiceAgentAPIKey)
                } else if oldValue {
                    if alerts.presentedKind == .voiceAgentAPIKey {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            #endif
            #if !targetEnvironment(macCatalyst)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                transitionLifecycleScenePhase(to: .inactive)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                transitionLifecycleScenePhase(to: .background)
                // Cancel any in-flight Trzsz transfer so its Continuity
                // streams close before the 5s graceful-termination watchdog
                // window opens. The receiver listens on its own observer
                // inside TrzszTransferReceiveSheet.
                trzszTransferOriginRequest?.originator.cancel()
                trzszTransferOriginRequest = nil
                NotificationCenter.default.post(name: .trzszTransferShouldCancelForBackground, object: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                transitionLifecycleScenePhase(to: .active)
            }
            #else
            // Mac Catalyst intentionally does not synthesize MainView lifecycle
            // transitions from AppKit focus changes. Losing app focus is not an
            // iOS-style background transition: terminals should keep running,
            // renderers should not be paused, SSH reminders should not fire, and
            // heavy scrollback/window persistence should not run on every Cmd-Tab.
            // Catalyst activation-only work remains in CatalystAppDelegate.
            #endif
            .onChange(of: windowIsKeyWindow) { _, newValue in
                // External window never becomes key; never claim device intents.
                guard !isExternalDisplayWindow else { return }
                updateWindowFocusState()
                if newValue {
                    refreshSelectionAfterExternalTabMutation(allowFocus: true)
                    consumePendingFileOpens()
                    consumePendingIntentRequests()
                }
            }
            .onChange(of: isAnySheetPresented) { _, sheetPresented in
                #if !targetEnvironment(macCatalyst)
                setSelectionUIOccludedByPresentation(sheetPresented)
                #endif
                if !sheetPresented {
                    resyncSelectionHandlesAfterTransientOcclusion()
                }
            }
            #if !CHINA_BUILD
            .modifier(NotificationHandlersModifier(
                tabBarHidden: $tabBarHidden,
                restorationVersion: $restorationVersion,
                sessionDiscoveryVersion: $sessionDiscoveryVersion,
                tabsModel: tabsModel,
                handleFileOpen: { consumePendingFileOpens() },
                handleAIAgentModeSwitch: handleAIAgentModeSwitch,
                handleIntentRequests: { consumePendingIntentRequests() },
                handleVPNIntent: handleVPNIntent,
                shouldHandleNotification: shouldHandleNotification
            ))
            #else
            .modifier(NotificationHandlersModifier(
                tabBarHidden: $tabBarHidden,
                restorationVersion: $restorationVersion,
                sessionDiscoveryVersion: $sessionDiscoveryVersion,
                tabsModel: tabsModel,
                handleFileOpen: { consumePendingFileOpens() },
                handleIntentRequests: { consumePendingIntentRequests() },
                shouldHandleNotification: shouldHandleNotification
            ))
            #endif
#if targetEnvironment(macCatalyst)
            .onChange(of: tabsInTitlebarEnabled) { _, _ in
                handleTabsInTitlebarEnabledChange()
            }
            .onChange(of: hideWindowTitleBar) { _, _ in
                // Same layout consequence as moving tabs in/out of the
                // titlebar: surfaces must resize into/out of the top strip.
                handleTabsInTitlebarEnabledChange()
            }
            #if STANDALONE
            .onChange(of: ghosttyApp.readiness) { _, readiness in
                handleVisorGhosttyReadinessChange(readiness)
            }
            #endif
#else
            .onChange(of: tabBarHidden) { _, isHidden in
                // If the tab bar was just hidden while no terminals exist,
                // show the connection sheet so the user isn't stranded.
                guard !isExternalDisplayWindow else { return }
                if isHidden && terminals.isEmpty && !showConnectionSidebar {
                    showConnectionSidebar = true
                }
            }
#endif
    }
}
