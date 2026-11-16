import SwiftUI
import UIKit

/// A reference for less discoverable gestures. Optional features stay visible;
/// platform gates follow the controls and recognizers that implement them.
struct GestureHelpView: View {
    #if os(visionOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        List {
            #if !targetEnvironment(macCatalyst)
            toolbarAndKeyboardSection
            #endif
            terminalSection
            tabsAndPanesSection
            #if os(iOS) && !targetEnvironment(macCatalyst)
            specializedSection
            #endif
        }
        .themedList()
        .navigationTitle("Gesture Help")
        .navigationBarTitleDisplayMode(.inline)
        #if os(visionOS)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private var toolbarAndKeyboardSection: some View {
        Section {
            #if !os(visionOS)
            helpRow(
                .pinKeyboard,
                "Keep keyboard hidden",
                "Touch and hold the toolbar chevron to keep the keyboard hidden while you use the terminal. Tap the chevron, or hold it again, to bring the keyboard back.",
                requirement: "Requires the chevron in your toolbar layout."
            )
            helpRow(
                .collapseToolbar,
                "Collapse toolbar",
                "With the keyboard showing, double-tap the toolbar chevron to collapse the toolbar into a floating keyboard button. Tap that button to restore the toolbar.",
                requirement: "Available on the toolbar above Apple's keyboard."
            )
            helpRow(
                .moveRestore,
                "Move restore button",
                "After collapsing the toolbar, drag the floating keyboard button to a convenient spot on the terminal."
            )
            #endif
            helpRow(
                .lockModifier,
                "Lock a modifier",
                "Double-tap a modifier such as Control, Option, Shift, or Command to keep it active for multiple keys. Tap it again to unlock it. A single tap applies the modifier to the next key only.",
                requirement: "Requires the modifier in your on-screen toolbar or keyboard."
            )
            #if !os(visionOS)
            helpRow(
                .joystickMode,
                "Joystick mode",
                "Hold the arrow joystick still for 1.5 seconds to switch between joystick mode and an arrow-drawer toggle. Hold it again to switch back.",
                requirement: "Requires the arrow joystick in the toolbar above Apple's keyboard."
            )
            helpRow(
                .joystickMove,
                "Arrow joystick",
                "Drag from the arrow joystick in the direction you want to move. Keep holding away from its center to repeat arrow keys; release to stop.",
                requirement: "Requires an arrow joystick in your layout. On the toolbar above Apple's keyboard, use joystick mode."
            )
            helpRow(
                .spaceCursor,
                "Spacebar cursor",
                "Hold Space, then drag left, right, up, or down to send arrow keys and move the terminal cursor. Release to return to typing.",
                requirement: "Requires the built-in Terminal Keyboard."
            )
            helpRow(
                .keyboardPages,
                "Keyboard pages",
                "Swipe left or right across the built-in keyboard's keys to cycle through Typing, Symbols, Navigation, and Shortcuts.",
                requirement: "Requires the built-in Terminal Keyboard."
            )
            if UIDevice.current.userInterfaceIdiom == .pad {
                helpRow(
                    .floatKeyboard,
                    "Float or dock",
                    "Pinch inward on the docked terminal keyboard to make it float. Spread two fingers apart on the floating keyboard to dock it again. You can also long-press the keyboard switch key, open Placement, and choose Docked or Detached.",
                    requirement: "Requires the built-in Terminal Keyboard with Use System Detached Keyboard turned off."
                )
            } else {
                helpRow(
                    .floatKeyboard,
                    "Float or dock",
                    "Long-press the keyboard switch key, open Placement, and choose Detached to float a smaller keyboard over the terminal. Choose Docked to put it back.",
                    requirement: "Requires the built-in Terminal Keyboard."
                )
            }
            helpRow(
                .moveKeyboard,
                "Move keyboard",
                "Drag the floating keyboard's ellipsis handle to move it. Double-tap the handle to dock it when Use System Detached Keyboard is turned off.",
                requirement: "Requires the built-in Terminal Keyboard in floating mode."
            )
            #endif
        } header: {
            Text("Toolbar and Keyboard")
        }
    }
    #endif

    private var terminalSection: some View {
        Section {
            // These gestures require contacts on the screen, not spatial input.
            #if os(iOS) && !targetEnvironment(macCatalyst)
            helpRow(
                .menuTwoFinger,
                "Two-finger menu",
                "Tap the terminal with two fingers to open its context menu, including when a terminal application is using mouse input.",
                requirement: "Requires Scroll Mode."
            )
            helpRow(
                .menuDoubleTap,
                "Double-tap menu",
                "Double-tap the terminal with one finger to open its context menu. This is a touch gesture; mouse and trackpad clicks keep their normal behavior."
            )
            helpRow(
                .newConnection,
                "New connection",
                "Touch and hold the terminal with two fingers to open the new connection sheet. Adjust the hold duration, or turn this gesture off, under Terminal → Gestures → Two-Finger Long Press.",
                requirement: "Requires Scroll Mode and an enabled Two-Finger Long Press duration."
            )
            helpRow(
                .fontSize,
                "Font size",
                "Spread two fingers apart on the terminal to enlarge the text, or pinch inward to shrink it. The overlay shows the terminal's columns and rows; tap Reset to restore the configured font size.",
                requirement: "Requires Scroll Mode. In tmux control mode, the change applies to the whole tmux window."
            )
            #endif
            horizontalSwipeRow
            NavigationLink(value: SettingsSearchDestination.swipeGestures) {
                Label("Customize Swipe Gestures", systemImage: "hand.draw")
            }
            .themedRow()
            #if os(iOS) && !targetEnvironment(macCatalyst)
            helpRow(
                .selection,
                "Select or click",
                "Touch and hold, then drag to select text with a magnifier. If the terminal application is capturing mouse input, the same gesture clicks and drags inside that application instead. Release to finish.",
                requirement: "Requires Scroll Mode."
            )
            helpRow(
                .loupeRightClick,
                "Right click with the loupe",
                "Touch and hold the terminal until the magnifier appears. Keep that finger down and tap the magnifier with another finger. A brief Right Click indicator confirms the switch. In an application using mouse input, this releases the primary button and holds the secondary button; move the original finger to drag, then lift it to release at its final position. Otherwise, lifting the original finger opens the terminal context menu there. The switch lasts only for this hold.",
                requirement: "Requires Scroll Mode and the app's loupe. Turn off Use Native Selection Loupe in Appearance → Window → Text Selection. The system loupe doesn't support this gesture."
            )
            helpRow(
                .selectionMode,
                "Selection mode",
                "Drag one finger to select text and use two fingers to scroll. Hold one finger still to open the context menu. If the terminal application captures mouse input, one-finger dragging and holding send mouse input instead.",
                requirement: "Applies when Scroll Mode is turned off."
            )
            #endif
        } header: {
            Text("Terminal")
        } footer: {
            #if !targetEnvironment(macCatalyst)
            Text("Scroll Mode is on by default. Change it in Terminal → Shell. Expand a gesture for details and requirements.")
            #else
            Text("Expand a gesture for details and requirements.")
            #endif
        }
    }

    private var horizontalSwipeRow: some View {
        #if targetEnvironment(macCatalyst)
        helpRow(
            .tabSwipe,
            "Switch tabs",
            "Swipe horizontally with two fingers on the trackpad over the terminal. By default, swiping left selects the next app tab and swiping right selects the previous one. Your Swipe Gestures settings can change or disable either action.",
            requirement: "Requires a trackpad."
        )
        #elseif os(visionOS)
        helpRow(
            .tabSwipe,
            "Switch tabs",
            "Swipe horizontally with two fingers on a connected trackpad over the terminal. By default, swiping left selects the next app tab and swiping right selects the previous one. Your Swipe Gestures settings can change or disable either action.",
            requirement: "Requires a trackpad and Scroll Mode."
        )
        #else
        helpRow(
            .tabSwipe,
            "Switch tabs",
            "Swipe left or right with one finger across the terminal. By default, left selects the next app tab and right selects the previous one. Two-finger horizontal trackpad swipes use the same bindings. Customize or disable either direction in Swipe Gestures.",
            requirement: "Requires Scroll Mode."
        )
        #endif
    }

    private var tabsAndPanesSection: some View {
        Section {
            #if !os(visionOS)
            tabExposeRows
            if UIDevice.current.userInterfaceIdiom != .phone {
                helpRow(
                    .hoverPreview,
                    "Hover previews",
                    "Rest the pointer over a tab in the top bar or sidebar to show a live preview. Pinch to resize the preview, or click it to open Tab Exposé with that tab highlighted.",
                    requirement: "Requires Tab Hover Previews and a pointer. If preview activation requires a modifier, hold that key while hovering. Use a trackpad to pinch, or two fingers on an iPad screen."
                )
            }
            #if !targetEnvironment(macCatalyst)
            if UIDevice.current.userInterfaceIdiom == .pad {
                helpRow(
                    .sidebarReveal,
                    "Tab sidebar",
                    "Start at the left edge of the screen and swipe right to open the tab sidebar. A pinned sidebar opens as a docked column."
                )
            }
            #endif
            #endif
            #if targetEnvironment(macCatalyst)
            helpRow(
                .equalizeSplits,
                "Equalize panes",
                "Double-click a divider between split panes to give the panes equal sizes."
            )
            helpRow(
                .rearrangePanes,
                "Rearrange panes",
                "Move the pointer near the top of a pane to reveal its grab handle. Drag the handle toward another pane and follow the highlighted destination to move or swap it within the current tab.",
                requirement: "Requires multiple panes that support rearrangement, with no pane zoomed or in fullscreen."
            )
            #else
            helpRow(
                .equalizeSplits,
                "Equalize panes",
                "Double-tap a divider between split panes to give the panes equal sizes."
            )
            #if !os(visionOS)
            helpRow(
                .rearrangePanes,
                "Rearrange panes",
                "Tap a split divider to reveal the pane grab handles. Drag a handle toward another pane and follow the highlighted destination to move or swap it within the current tab. With a pointer, hover near a pane's top edge to reveal its handle.",
                requirement: "Requires multiple panes that support rearrangement, with no pane zoomed or in fullscreen."
            )
            #endif
            #endif
            if UIDevice.current.userInterfaceIdiom != .phone {
                #if targetEnvironment(macCatalyst)
                helpRow(
                    .sidebarReset,
                    "Sidebar width",
                    "Double-click a resizable sidebar's divider to return it to its default width.",
                    requirement: "Applies to docked sidebars with a resize divider."
                )
                #else
                helpRow(
                    .sidebarReset,
                    "Sidebar width",
                    "Double-tap a resizable sidebar's divider to return it to its default width.",
                    requirement: "Applies to docked sidebars with a resize divider."
                )
                #endif
            }
        } header: {
            Text("Tabs and Panes")
        }
    }

    #if !os(visionOS)
    @ViewBuilder
    private var tabExposeRows: some View {
        #if targetEnvironment(macCatalyst)
        helpRow(
            .exposeReveal,
            "Tab Exposé",
            "With the pointer over the top tab bar, scroll down with two fingers on the trackpad to show live tab previews.",
            requirement: "Requires Pull Down for Tab Exposé in Terminal → Gestures."
        )
        helpRow(
            .exposePages,
            "Browse tab groups",
            "Swipe horizontally with two fingers on the trackpad over Tab Exposé to move between available tab groups, projects, and multiplexer tabs.",
            requirement: "Requires more than one group, project, or multiplexer scope."
        )
        helpRow(
            .exposeResize,
            "Preview size",
            "Pinch on the trackpad while Tab Exposé is open to resize its previews and change how many fit in the grid."
        )
        #else
        helpRow(
            .exposeReveal,
            "Tab Exposé",
            "Swipe down with one finger from the top tab bar to show live tab previews. Two fingers can also start above the terminal or just inside its top edge. With a trackpad, scroll down over the tab bar.",
            requirement: "Requires Pull Down for Tab Exposé in Terminal → Gestures."
        )
        helpRow(
            .exposePages,
            "Browse tab groups",
            "Swipe left or right over Tab Exposé to move between available tab groups, projects, and multiplexer tabs. One or two fingers work, as does a two-finger trackpad swipe.",
            requirement: "Requires more than one group, project, or multiplexer scope."
        )
        helpRow(
            .exposeResize,
            "Preview size",
            "Pinch in Tab Exposé to resize its previews and change how many fit in the grid. You can also pinch on a connected trackpad."
        )
        #endif
    }
    #endif

    #if os(iOS) && !targetEnvironment(macCatalyst)
    @ViewBuilder
    private var specializedSection: some View {
        if UIDevice.current.userInterfaceIdiom == .phone || UIDevice.current.userInterfaceIdiom == .pad {
            Section {
                if UIDevice.current.userInterfaceIdiom == .phone {
                    helpRow(
                        .remoteTabs,
                        "Screen Sharing tabs",
                        "Swipe horizontally with three fingers over a Screen Sharing session to switch app tabs, even in fullscreen. Screen Sharing settings can move this to four fingers.",
                        requirement: "Requires the swipe direction to be assigned to app-tab navigation in Swipe Gestures and, with three fingers, its Three-Finger Swipe in Screen Sharing settings to be Off."
                    )
                } else {
                    helpRow(
                        .pencil,
                        "Pencil shortcut",
                        "Double-tap the Pencil barrel to open the terminal context menu at its hover position or recent contact point. If the terminal application captures mouse input, this sends a right-click instead.",
                        requirement: "Requires a compatible Apple Pencil with double-tap enabled. Without hover, touch the terminal with the Pencil shortly before double-tapping."
                    )
                }
            } header: {
                Text("Specialized Gestures")
            }
        }
    }
    #endif

    private func helpRow(
        _ kind: GestureHelpDemo.Kind,
        _ title: LocalizedStringKey,
        _ instructions: LocalizedStringKey,
        requirement: LocalizedStringKey? = nil
    ) -> some View {
        GestureHelpRow(kind: kind, title: title, instructions: instructions, requirement: requirement)
            .themedRow()
    }
}

private struct GestureHelpRow: View {
    let kind: GestureHelpDemo.Kind
    let title: LocalizedStringKey
    let instructions: LocalizedStringKey
    let requirement: LocalizedStringKey?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(instructions)
                if let requirement {
                    Text(requirement)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
        } label: {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                GestureHelpDemo(kind: kind)
                    .frame(width: 104, height: 78)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(kind.compactSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let badge = kind.badge {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.primary.opacity(0.06), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
