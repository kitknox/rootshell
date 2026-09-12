// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation
import UIKit
import GhosttyKit

/// The selection belongs to the remote buffer. Ghostty is only its renderer;
/// its local alternate-screen rows must never anchor a fallback selection.
@MainActor
final class HerdrEndpointPane {
    typealias Surface = HerdrEndpointSurface
    weak var view: Ghostty.TerminalView?
    weak var controller: HerdrController?
    private(set) var pane: Surface.Pane?
    private(set) var selection: HerdrEndpointSelection?
    private var frame: Surface.Frame?
    private var pending: (Surface.Frame, Surface.Pane)?
    private var painter = HerdrEndpointPainter()
    private var dragPoint: CGPoint?
    private var autoScroll: Task<Void, Never>?
    private var pointer = HerdrEndpointPointer()
    private var scrollTarget: UInt64?
    private var scrollAcknowledgedAt: UInt64?
    private var scrollRequest: UInt64 = 0
    private var epoch = UUID()
    private var lastClick = Date.distantPast
    private var lastClickCell: HerdrEndpointSelection.Point?
    private var clickCount = 0

    init(view: Ghostty.TerminalView, controller: HerdrController) {
        self.view = view; self.controller = controller
    }

    var hasSelection: Bool { selection?.visible == true }
    var capturesMouse: Bool { (frame?.popup?.mouseReporting ?? pane?.mouseReporting) == true && view?.mouseCaptureOverrideActive != true }
    private var channel: HerdrEndpointChannel? {
        guard let view, let controller, controller.endpointActive,
              controller.endpointTabID == view.herdrPaneBinding?.tabId else { return nil }
        return controller.endpoint
    }

    func receive(frame: Surface.Frame, pane: Surface.Pane) {
        if self.frame?.boot == frame.boot, self.frame?.revision == frame.revision, pending == nil { return }
        pending = (frame, pane)
        guard let view, let terminal = view.herdrPaneBinding?.terminalId else { return }
        if let size = view.surfaceSize, Int(size.columns) == pane.inner.width, Int(size.rows) == pane.inner.height {
            controller?.paneSessions[terminal]?.confirmParserGrid(cols: pane.inner.width, rows: pane.inner.height)
        }
        commitPendingFrame()
    }

    func commitPendingFrame() {
        guard let (nextFrame, nextPane) = pending, let view,
              let terminal = view.herdrPaneBinding?.terminalId,
              let session = controller?.paneSessions[terminal],
              session.parserGrid == .init(cols: nextPane.inner.width, rows: nextPane.inner.height),
              let size = view.surfaceSize, Int(size.columns) == nextPane.inner.width,
              Int(size.rows) == nextPane.inner.height else { return }
        if let old = pane, frame?.boot != nextFrame.boot || !HerdrEndpointSelection.survives(from: old, to: nextPane) {
            clearSelection()
            epoch = UUID()
            painter.reset()
            pointer = .init()
        }
        if frame?.popup?.id != nextFrame.popup?.id {
            clearSelection()
            pointer = .init()
        }
        pending = nil
        frame = nextFrame; pane = nextPane
        if scrollTarget == nextPane.scroll?.offset_from_bottom
            || scrollAcknowledgedAt.map({ nextFrame.revision > $0 }) == true {
            scrollTarget = nil
            scrollAcknowledgedAt = nil
        }
        if selection?.dragging == true, let dragPoint {
            selection?.move(to: point(at: dragPoint, pane: nextPane))
        }
        paint()
        view.applyHerdrEndpointScroll(nextFrame.popup == nil ? nextPane.scroll : nil)
        view.updateMouseCaptureState()
        syncSelectionUI()
    }

    func disconnect() {
        cancelInteraction()
        clearSelection()
        epoch = UUID()
        frame = nil; pane = nil; pending = nil
        painter.reset()
        pointer = .init()
        view?.applyHerdrEndpointScroll(nil)
    }

    private func paint() {
        guard let frame, let pane, let view, let terminal = view.herdrPaneBinding?.terminalId,
              let bytes = painter.render(frame: frame, pane: pane, selection: selection, selectionColors: selectionColors) else { return }
        controller?.paneSessions[terminal]?.outputSink.emit(bytes)
    }

    /// Selection colors are local settings, so they can change without a
    /// remote content revision. Repaint the retained frame without retiring
    /// selection, scrolling, or retained graphics.
    func refreshAppearance() {
        guard channel != nil else { return }
        paint()
    }

    private var selectionColors: (foreground: UInt32, background: UInt32)? {
        let manager = SelectionManager.shared
        switch manager.selectionMode {
        case .rootshell: return (0x021e1e2e, 0x02f5e0dc)
        case .custom:
            guard let fg = UInt32(manager.customForegroundHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16),
                  let bg = UInt32(manager.customBackgroundHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
            return (0x02000000 | (fg & 0xffffff), 0x02000000 | (bg & 0xffffff))
        case .themeDefault, .invertFgBg: return nil
        }
    }

    var geometry: (cellWidth: CGFloat, cellHeight: CGFloat, padX: CGFloat, padY: CGFloat)? {
        guard let view, let size = view.surfaceSize, view.contentScaleFactor > 0 else { return nil }
        let width = CGFloat(size.cell_width_px) / view.contentScaleFactor
        let height = CGFloat(size.cell_height_px) / view.contentScaleFactor
        guard width > 0, height > 0 else { return nil }
        return (width, height, HerdrGeometry.padding(PaddingManager.shared.effectivePaddingX, scale: view.contentScaleFactor),
                HerdrGeometry.padding(PaddingManager.shared.effectivePaddingY, scale: view.contentScaleFactor))
    }

    private func point(at location: CGPoint, pane: Surface.Pane) -> HerdrEndpointSelection.Point {
        guard let geometry else { return .init(row: pane.scroll?.top ?? 0, column: 0) }
        return HerdrEndpointSelection.point(row: Int(floor((location.y - geometry.padY) / geometry.cellHeight)),
            column: Int(floor((location.x - geometry.padX) / geometry.cellWidth)), pane: pane)
    }

    func beginSelection(at location: CGPoint, extending: Bool = false) {
        guard let pane, channel != nil, pending == nil, frame?.popup == nil else { return }
        endDrag()
        let point = point(at: location, pane: pane)
        if extending, selection != nil {
            selection?.dragging = true
            selection?.move(to: point)
        } else { selection = .init(anchor: point, cursor: point) }
        dragPoint = location
        paint(); syncSelectionUI()
    }

    func beginHandle(start: Bool, at location: CGPoint) {
        guard let selection, hasSelection else { return }
        let (first, last) = selection.ordered
        self.selection = .init(anchor: start ? last : first, cursor: start ? first : last, dragging: true, visible: true)
        drag(to: location)
    }

    func drag(to location: CGPoint) {
        guard let pane, selection?.dragging == true else { return }
        dragPoint = location
        if pending == nil { selection?.move(to: point(at: location, pane: pane)) }
        paint(); syncSelectionUI()
        view?.noteSelectionScrollIndicatorActivity()
        if edgeDirection(at: location) != 0, autoScroll == nil {
            autoScroll = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard let self, let point = self.dragPoint, self.selection?.dragging == true,
                          self.view?.isLogicallyFocused == true, self.channel != nil else { return }
                    guard self.view?.window != nil, self.view?.selectionUIExternallyOccluded != true,
                          self.view?.selectionUISwipeSuppressed != true else {
                        self.cancelInteraction()
                        return
                    }
                    let direction = self.edgeDirection(at: point)
                    guard direction != 0 else { self.autoScroll = nil; return }
                    // Extend only on committed frames. At most one viewport
                    // advance waits on the network while a finger holds still.
                    if self.scrollTarget == nil, self.pending == nil { self.scroll(rows: direction) }
                }
            }
        } else if edgeDirection(at: location) == 0 {
            autoScroll?.cancel(); autoScroll = nil
        }
    }

    private func edgeDirection(at point: CGPoint) -> Int {
        guard let geometry, let pane, pane.scroll != nil else { return 0 }
        let top = geometry.padY, bottom = top + CGFloat(pane.inner.height) * geometry.cellHeight
        let margin = min(24, geometry.cellHeight)
        if point.y < top + margin { return min(8, max(1, Int((top + margin - point.y) / geometry.cellHeight) + 1)) }
        if point.y > bottom - margin { return -min(8, max(1, Int((point.y - bottom + margin) / geometry.cellHeight) + 1)) }
        return 0
    }

    func endDrag() {
        autoScroll?.cancel(); autoScroll = nil
        dragPoint = nil
        selection?.dragging = false
        if let pane { channel?.cancelQueuedScroll(pane: pane.id) }
        scrollTarget = nil
        scrollAcknowledgedAt = nil
    }

    func clearSelection() {
        endDrag()
        selection = nil
        if pending == nil { paint() }
        syncSelectionUI()
    }

    func cancelInteraction() {
        if view?.mousePressed == true, capturesMouse, let point = view?.lastMousePosition { mouseUp(at: point) }
        endDrag()
        view?.stopCaptureAutoScroll()
        view?.mousePressed = false
        view?.selectionMouseDragActive = false
        view?.isSelecting = false
    }

    private func syncSelectionUI() {
        #if !targetEnvironment(macCatalyst)
        view?.updateSelectionHandlePositions()
        view?.syncSelectionHandlesForSurfaceActivity()
        #endif
    }

    func copy() {
        guard let selection, hasSelection, let pane, let channel else { return }
        let epoch = epoch
        // Upstream manual selections omit content_revision too: output stays
        // live, and the server resolves the absolute buffer range at copy time.
        channel.command("pane.selection.read", ["pane_id": pane.id,
            "anchor": selection.anchor.json, "cursor": selection.cursor.json]) { [weak self] result in
            guard let self, self.epoch == epoch, self.selection?.anchor == selection.anchor,
                  self.selection?.cursor == selection.cursor else { return }
            do {
                let bytes = try result.get()
                guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let value = response["result"] as? [String: Any], let text = value["text"] as? String else {
                    throw HerdrEndpointWire.Failure.invalid("invalid selection response")
                }
                UIPasteboard.general.string = text
                ClipboardHistoryManager.shared.record(text, source: .explicitCopy)
            } catch { self.controller?.legacyNotice(error.localizedDescription) }
        }
    }

    func action(_ action: String) -> Bool {
        if action.hasPrefix("scroll_to_row:"), let row = Int(action.dropFirst("scroll_to_row:".count)) {
            scrollToRow(row)
            return true
        }
        switch action {
        case "copy_to_clipboard": copy()
        case "clear_selection": clearSelection()
        case "select_all":
            guard let pane, frame?.popup == nil else { return true }
            endDrag()
            selection = .init(anchor: .init(row: 0, column: 0),
                cursor: .init(row: min(UInt64(UInt32.max), max(1, pane.scroll?.total ?? UInt64(pane.inner.height)) - 1),
                              column: pane.inner.width - 1), dragging: false, visible: true)
            paint(); syncSelectionUI()
        case "scroll_to_top": setScroll(pane?.scroll?.max_offset_from_bottom ?? 0)
        case "scroll_to_bottom": setScroll(0)
        case "scroll_page_up": scroll(rows: max(1, (pane?.inner.height ?? 1) - 1))
        case "scroll_page_down": scroll(rows: -max(1, (pane?.inner.height ?? 1) - 1))
        default: return false
        }
        return true
    }

    func scroll(deltaX: CGFloat, deltaY: CGFloat, at location: CGPoint) {
        guard let geometry else { return }
        let mouseCaptureOverride = view?.mouseCaptureOverrideActive == true
        let events = pointer.scroll(deltaX: Double(deltaX), deltaY: Double(deltaY),
            cellWidth: Double(geometry.cellWidth), cellHeight: Double(geometry.cellHeight),
            capturesMouse: capturesMouse, alternateScreen: pane?.alternateScreen == true, popup: frame?.popup != nil,
            mouseCaptureOverride: mouseCaptureOverride)
        for event in events {
            if mouseCaptureOverride {
                // The override is local: herdr still sees the child's mouse
                // reporting mode. Only pane.scroll bypasses that routing.
                if case .viewport(let rows) = event { scroll(rows: rows) }
            } else {
                // Relative wheel input does not wait for the command lane or
                // rebase new movement on a viewport from an older round trip.
                mouse(kind: event.kind, at: location, lines: event.lines, repeatCount: event.repeatCount)
            }
        }
        if !events.isEmpty { view?.noteUserScrollForScrollIndicator() }
    }

    private func scroll(rows: Int) {
        guard let scroll = pane?.scroll else { return }
        let offset = scrollTarget ?? scroll.offset_from_bottom
        let target = rows >= 0 ? offset + min(UInt64(rows), scroll.max_offset_from_bottom - min(offset, scroll.max_offset_from_bottom))
            : offset - min(offset, UInt64(-rows))
        setScroll(target)
    }

    func scrollToRow(_ row: Int) {
        guard let scroll = pane?.scroll else { return }
        setScroll(scroll.max_offset_from_bottom - min(scroll.max_offset_from_bottom, UInt64(max(0, row))))
    }

    private func setScroll(_ offset: UInt64) {
        guard let pane, let scroll = pane.scroll, let channel, frame?.popup == nil else { return }
        let target = min(offset, scroll.max_offset_from_bottom)
        guard target != (scrollTarget ?? scroll.offset_from_bottom) else { return }
        scrollTarget = target
        scrollAcknowledgedAt = nil
        scrollRequest &+= 1
        let request = scrollRequest
        view?.noteUserScrollForScrollIndicator()
        channel.command("pane.scroll", ["pane_id": pane.id, "offset_from_bottom": target],
                        coalescingKey: "scroll:\(pane.id)") { [weak self] result in
            guard let self, self.scrollRequest == request else { return }
            if case .failure(let error) = result {
                self.scrollTarget = nil
                if !(error is CancellationError) { self.controller?.legacyNotice(error.localizedDescription) }
            } else if self.pane?.scroll?.offset_from_bottom == target {
                self.scrollTarget = nil
            } else {
                self.scrollAcknowledgedAt = self.frame?.revision
            }
        }
    }

    func focus() {
        guard let pane, let channel else { return }
        channel.command("pane.focus", ["pane_id": pane.id], coalescingKey: "focus-pane")
    }

    func sendText(_ text: String, paste: Bool = false) {
        guard !text.isEmpty else { return }
        clearSelection()
        send(HerdrEndpointWire.text(text, paste: paste))
    }

    private func send(_ event: HerdrEndpointWire.Writer, repeatCount: Int = 1) {
        guard let pane, let channel else { return }
        channel.enqueue(HerdrEndpointWire.input(pane: frame?.popup?.id ?? pane.id, popup: frame?.popup != nil,
                                               event: event, repeatCount: repeatCount))
    }

    private func modifiers(_ mods: Ghostty.Input.Mods) -> UInt8 {
        (mods.contains(.shift) ? 1 : 0) | (mods.contains(.ctrl) ? 2 : 0)
            | (mods.contains(.alt) ? 4 : 0) | (mods.contains(.cmd) ? 8 : 0)
    }

    func sendKey(_ key: UIKeyboardHIDUsage, action: Ghostty.Input.Action,
                 mods: Ghostty.Input.Mods, text: String?, unshifted: UInt32) {
        let special: [UIKeyboardHIDUsage: UInt64] = [.keyboardDeleteOrBackspace: 0, .keyboardReturnOrEnter: 1,
            .keyboardLeftArrow: 2, .keyboardRightArrow: 3, .keyboardUpArrow: 4, .keyboardDownArrow: 5,
            .keyboardHome: 6, .keyboardEnd: 7, .keyboardPageUp: 8, .keyboardPageDown: 9,
            .keyboardTab: mods.contains(.shift) ? 11 : 10, .keyboardDeleteForward: 12,
            .keyboardInsert: 13, .keyboardEscape: 14]
        let code: UInt64
        var character: String?, function: UInt8?
        if let value = special[key] { code = value }
        else if key.rawValue >= UIKeyboardHIDUsage.keyboardF1.rawValue && key.rawValue <= UIKeyboardHIDUsage.keyboardF12.rawValue {
            code = 16; function = UInt8(key.rawValue - UIKeyboardHIDUsage.keyboardF1.rawValue + 1)
        } else if (104...115).contains(Int(key.rawValue)) {
            code = 16; function = UInt8(key.rawValue - 104 + 13)
        } else if let scalar = UnicodeScalar(unshifted), unshifted >= 32 {
            code = 15; character = String(scalar)
        } else if let scalar = text?.unicodeScalars.first, scalar.value >= 32 {
            code = 15; character = String(scalar)
        } else if key.rawValue >= 4 && key.rawValue <= 29 {
            code = 15; character = String(UnicodeScalar(UInt32(key.rawValue - 4 + 97))!)
        } else {
            let fallback: [Int: String] = [30:"1",31:"2",32:"3",33:"4",34:"5",35:"6",36:"7",37:"8",38:"9",39:"0",
                44:" ",45:"-",46:"=",47:"[",48:"]",49:"\\",50:"#",51:";",52:"'",53:"`",54:",",55:".",56:"/",
                84:"/",85:"*",86:"-",87:"+",89:"1",90:"2",91:"3",92:"4",93:"5",94:"6",95:"7",96:"8",97:"9",98:"0",99:"."]
            if key.rawValue == 88 { code = 1 }
            else if let value = fallback[Int(key.rawValue)] { code = 15; character = value }
            else { return }
        }
        let kind: UInt64
        switch action { case .press: kind = 0; case .repeat: kind = 1; case .release: kind = 2 }
        if kind != 2 { clearSelection() }
        send(HerdrEndpointWire.key(code: code, character: character, function: function,
            modifiers: modifiers(mods), kind: kind, text: kind == 2 ? nil : text, physical: UInt32(key.rawValue),
            shifted: mods.contains(.shift) ? text?.unicodeScalars.first?.value : nil))
    }

    func mouse(kind: UInt64, button: UInt64? = nil, at location: CGPoint, lines: Int = 1, repeatCount: Int = 1) {
        guard let pane, let view else { return }
        if let frame, let popup = frame.popup, let geometry {
            let originX = max(0, (frame.grid.width - popup.grid.width) / 2)
            let originY = max(0, (frame.grid.height - popup.grid.height) / 2)
            let column = Int((location.x - geometry.padX) / geometry.cellWidth) + pane.inner.x - originX
            let row = Int((location.y - geometry.padY) / geometry.cellHeight) + pane.inner.y - originY
            send(HerdrEndpointWire.mouse(kind: kind, button: button,
                column: max(0, min(column, popup.grid.width - 1)), row: max(0, min(row, popup.grid.height - 1)),
                modifiers: modifiers(.init(cMods: view.currentMouseMods())), lines: lines), repeatCount: repeatCount)
            return
        }
        let point = point(at: location, pane: pane)
        var pixels: (x: UInt32, y: UInt32, cols: Int, rows: Int, width: UInt32, height: UInt32)?
        if pane.pixelMouse, let geometry,
           let x = HerdrEndpointPointer.pixelCoordinate(Double(location.x), padding: Double(geometry.padX),
               scale: Double(view.contentScaleFactor), extent: pane.pixelWidth),
           let y = HerdrEndpointPointer.pixelCoordinate(Double(location.y), padding: Double(geometry.padY),
               scale: Double(view.contentScaleFactor), extent: pane.pixelHeight) {
            pixels = (x, y, pane.inner.width, pane.inner.height, pane.pixelWidth, pane.pixelHeight)
        }
        send(HerdrEndpointWire.mouse(kind: kind, button: button, column: point.column,
            row: Int(point.row - (pane.scroll?.top ?? 0)), modifiers: modifiers(.init(cMods: view.currentMouseMods())),
            lines: lines, pixels: pixels), repeatCount: repeatCount)
    }

    func mouseDown(at location: CGPoint, right: Bool) {
        guard let view, let pane else { return }
        view.invalidateWritingAssistance()
        view.stopCaptureAutoScroll()
        NotificationCenter.default.post(name: .focusSplit, object: view)
        view.lastMousePosition = location
        if right && !capturesMouse { return }
        view.mousePressed = true
        Ghostty.TerminalView.pressedMouseButton = right ? GHOSTTY_MOUSE_RIGHT : GHOSTTY_MOUSE_LEFT
        view.selectionMouseDragActive = !capturesMouse
        if capturesMouse { mouse(kind: 0, button: right ? 1 : 0, at: location); return }
        let mods = Ghostty.Input.Mods(cMods: view.currentMouseMods())
        if mods.contains(.cmd), let link = link(at: location), let url = URL(string: link) {
            view.mousePressed = false; view.selectionMouseDragActive = false
            UIApplication.shared.open(url); return
        }
        beginSelection(at: location, extending: mods.contains(.shift))
        let cell = point(at: location, pane: pane)
        clickCount = Date().timeIntervalSince(lastClick) < 0.4 && lastClickCell == cell ? clickCount % 3 + 1 : 1
        lastClick = Date(); lastClickCell = cell
        if clickCount > 1 { selectUnit(at: location, line: clickCount == 3) }
    }

    func mouseMove(at location: CGPoint) {
        view?.lastMousePosition = location
        if capturesMouse {
            let down = view?.mousePressed == true
            mouse(kind: down ? 2 : 3, button: down ? (Ghostty.TerminalView.pressedMouseButton == GHOSTTY_MOUSE_RIGHT ? 1 : 0) : nil, at: location)
            if down { view?.updateCaptureAutoScroll(at: location) }
        } else if view?.selectionMouseDragActive == true { drag(to: location) }
    }

    func mouseUp(at location: CGPoint) {
        view?.stopCaptureAutoScroll()
        if capturesMouse { mouse(kind: 1, button: Ghostty.TerminalView.pressedMouseButton == GHOSTTY_MOUSE_RIGHT ? 1 : 0, at: location) }
        endDrag()
        if hasSelection, SettingsStore.shared.value(Settings.Selection.copyOnSelect) { copy() }
        view?.mousePressed = false; view?.selectionMouseDragActive = false
    }

    private func link(at location: CGPoint) -> String? {
        guard let pane, let frame else { return nil }
        let point = point(at: location, pane: pane)
        let row = Int(point.row - (pane.scroll?.top ?? 0))
        let cell = frame.grid.cells[(pane.inner.y + row) * frame.grid.width + pane.inner.x + point.column]
        guard let link = cell.hyperlink, Int(link) < frame.grid.hyperlinks.count else { return nil }
        return frame.grid.hyperlinks[Int(link)]
    }

    private func selectUnit(at location: CGPoint, line: Bool) {
        guard let pane, let frame, frame.popup == nil else { return }
        let point = point(at: location, pane: pane)
        let row = Int(point.row - (pane.scroll?.top ?? 0))
        let index = (pane.inner.y + row) * frame.grid.width + pane.inner.x
        var start = line ? 0 : point.column, end = line ? pane.inner.width - 1 : point.column
        if !line {
            let whitespace = frame.grid.cells[index + point.column].symbol.allSatisfy(\.isWhitespace)
            while start > 0 && frame.grid.cells[index + start - 1].symbol.allSatisfy(\.isWhitespace) == whitespace { start -= 1 }
            while end + 1 < pane.inner.width && frame.grid.cells[index + end + 1].symbol.allSatisfy(\.isWhitespace) == whitespace { end += 1 }
        }
        selection = .init(anchor: .init(row: point.row, column: start), cursor: .init(row: point.row, column: end), dragging: false, visible: true)
        paint(); syncSelectionUI()
    }
}
