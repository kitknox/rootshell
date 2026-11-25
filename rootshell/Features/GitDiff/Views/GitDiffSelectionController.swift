//
//  GitDiffSelectionController.swift
//  rootshell
//
//  Text selection for the diff list. Rows report their frames in the list's
//  content space; points map to columns through TextKit laid out as the rows
//  draw. Points arrive in `GitDiffSelectionAnchorView` space, which is the
//  same content space because the anchor backs the whole list.
//

import SwiftUI
import UIKit

@MainActor
@Observable
final class GitDiffSelectionController {
    nonisolated static let coordinateSpace = "gitDiffContent"

    enum HandleEnd { case start, end }

    private(set) var selection: GitDiffSelection?
    private(set) var showsHandles = false
    /// Bumped when an endpoint row lays out again, since the row registry is not observed.
    private(set) var handleLayout = 0

    @ObservationIgnored private var files: [GitDiffFile] = []
    @ObservationIgnored private var fileIndices: [String: Int] = [:]
    @ObservationIgnored private var isExpanded: (Int) -> Bool = { _ in true }
    @ObservationIgnored private var style: GitDiffRowStyle?
    @ObservationIgnored var headerHeight: CGFloat = 40
    /// Keyed like the rows' view identity, so a row that survives a refresh
    /// under a new file index still leaves through `unregister`.
    @ObservationIgnored private var rows: [GitDiffRowKey: CGRect] = [:]
    @ObservationIgnored weak var anchorView: GitDiffSelectionAnchorView?

    private enum DragMode {
        /// A long press grew from this word.
        case word(GitDiffTextPosition, GitDiffTextPosition)
        /// Finger offset from the caret it grabbed.
        case handle(CGPoint)
        case pointer
    }

    @ObservationIgnored private var dragMode: DragMode?
    @ObservationIgnored private weak var dragRecognizer: UIGestureRecognizer?
    @ObservationIgnored private var dragStart: CGPoint = .zero
    @ObservationIgnored private var dragHasMoved = false
    @ObservationIgnored private var autoscroll: Task<Void, Never>?
    @ObservationIgnored private var loupe: Ghostty.SelectionLoupe?
    @ObservationIgnored private var lastTap: (time: TimeInterval, point: CGPoint, count: Int)?
    @ObservationIgnored var lastTapWasPointer = false
    /// The line a right-click landed on, for Copy Line.
    @ObservationIgnored private var menuLineID: GitDiffLineID?
    /// The open menu came from a right-click, so its Select All should take the keyboard.
    @ObservationIgnored private var menuIsPointer = false

    @ObservationIgnored private let storage = NSTextStorage()
    @ObservationIgnored private let layoutManager = NSLayoutManager()
    @ObservationIgnored private let container = NSTextContainer()

    init() {
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    var hasSelection: Bool { selection.map { !$0.isEmpty } ?? false }

    func update(files: [GitDiffFile], style: GitDiffRowStyle, isExpanded: @escaping (Int) -> Bool) {
        if self.files.map(\.id) != files.map(\.id) {
            fileIndices = Dictionary(files.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        self.files = files
        self.style = style
        self.isExpanded = isExpanded
    }

    // MARK: Row registry

    func register(_ key: GitDiffRowKey, frame: CGRect) {
        guard rows[key] != frame else { return }
        rows[key] = frame
        noteEndpointLayout(key)
    }

    func unregister(_ key: GitDiffRowKey) {
        guard rows.removeValue(forKey: key) != nil else { return }
        noteEndpointLayout(key)
    }

    private func noteEndpointLayout(_ key: GitDiffRowKey) {
        guard showsHandles, let selection,
              [selection.start.lineID, selection.end.lineID].contains(where: { self.key(for: $0) == key }) else { return }
        handleLayout &+= 1
    }

    private func key(for id: GitDiffLineID) -> GitDiffRowKey? {
        files.indices.contains(id.file) ? GitDiffRowKey(fileID: files[id.file].id, hunk: id.hunk, line: id.line) : nil
    }

    private func lineID(for key: GitDiffRowKey) -> GitDiffLineID? {
        fileIndices[key.fileID].map { GitDiffLineID(file: $0, hunk: key.hunk, line: key.line) }
    }

    private func frame(for id: GitDiffLineID) -> CGRect? {
        key(for: id).flatMap { rows[$0] }
    }

    /// Registered rows of the current snapshot, by position.
    private var liveRows: [(id: GitDiffLineID, frame: CGRect)] {
        rows.compactMap { key, frame in lineID(for: key).map { ($0, frame) } }
    }

    /// Counts the text only for rows inside the selection.
    func lineSelection(for id: GitDiffLineID, text: String) -> GitDiffLineSelection? {
        guard let selection, selection.start.lineID <= id, id <= selection.end.lineID else { return nil }
        return selection.lineSelection(for: id, length: text.count)
    }

    // MARK: Geometry

    private func line(_ id: GitDiffLineID) -> GitDiffLine? {
        guard files.indices.contains(id.file), files[id.file].hunks.indices.contains(id.hunk),
              files[id.file].hunks[id.hunk].lines.indices.contains(id.line) else { return nil }
        return files[id.file].hunks[id.hunk].lines[id.line]
    }

    /// Where a row's code text starts: past the gutter and marker, under the row's top padding.
    private func textOrigin(_ row: CGRect, _ style: GitDiffRowStyle) -> CGPoint {
        CGPoint(x: row.minX + style.gutterWidth + style.markerWidth, y: row.minY + 1.5)
    }

    private func textWidth(_ row: CGRect, _ style: GitDiffRowStyle) -> CGFloat {
        style.wrap ? max(1, row.width - style.gutterWidth - style.markerWidth - 8) : 1_000_000
    }

    private func font(_ style: GitDiffRowStyle) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular)
    }

    private func layOut(_ text: String, width: CGFloat, _ style: GitDiffRowStyle) {
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font(style)]))
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
    }

    private static func characterOffset(ofUTF16 target: Int, in text: String) -> Int {
        var utf16 = 0, offset = 0
        for character in text {
            guard utf16 < target else { break }
            utf16 += character.utf16.count
            offset += 1
        }
        return offset
    }

    /// `characterUnder` answers the character the point is on; otherwise the
    /// nearest insertion point, which is what a drag endpoint wants.
    private func column(for line: GitDiffLine, at local: CGPoint, width: CGFloat, characterUnder: Bool,
                        _ style: GitDiffRowStyle) -> Int {
        guard !line.text.isEmpty else { return 0 }
        layOut(line.text, width: width, style)
        let used = layoutManager.usedRect(for: container)
        let point = CGPoint(x: max(0, local.x), y: min(max(0, local.y), max(0, used.height - 0.5)))
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let roundsForward = !characterUnder && fraction > 0.5
        let utf16 = min(index + (roundsForward ? 1 : 0), line.text.utf16.count)
        return Self.characterOffset(ofUTF16: utf16, in: line.text)
    }

    /// `exact` wants a point on a code row; otherwise the nearest row answers,
    /// at its start or end when the point lies above or below it.
    func position(at point: CGPoint, exact: Bool, characterUnder: Bool = false) -> GitDiffTextPosition? {
        guard let style else { return nil }
        let live = liveRows
        var hit = live.first { $0.frame.minY <= point.y && point.y < $0.frame.maxY }
        if hit == nil, !exact {
            func distance(_ frame: CGRect) -> CGFloat {
                point.y < frame.minY ? frame.minY - point.y : point.y - frame.maxY
            }
            hit = live.min { distance($0.frame) < distance($1.frame) }
        }
        guard let hit, let line = line(hit.id) else { return nil }
        let id = hit.id, row = hit.frame
        if point.y < row.minY { return GitDiffTextPosition(id, column: 0) }
        if point.y >= row.maxY { return GitDiffTextPosition(id, column: line.text.count) }
        let origin = textOrigin(row, style)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        return GitDiffTextPosition(id, column: column(
            for: line, at: local, width: textWidth(row, style), characterUnder: characterUnder, style))
    }

    /// A thin caret in content space, or nil while its row is not laid out.
    func caretRect(for position: GitDiffTextPosition) -> CGRect? {
        guard let style, let row = frame(for: position.lineID), let line = line(position.lineID) else { return nil }
        let origin = textOrigin(row, style)
        guard !line.text.isEmpty else {
            return CGRect(x: origin.x - 1, y: origin.y, width: 2, height: font(style).lineHeight)
        }
        layOut(line.text, width: textWidth(row, style), style)
        let length = line.text.utf16.count
        let utf16 = min(line.text.prefix(position.column).utf16.count, length)
        let atEnd = utf16 >= length
        // The character at the offset picks the line fragment, so a wrap boundary lands on the next line.
        let probe = atEnd ? length - 1 : utf16
        let glyph = layoutManager.glyphIndexForCharacter(at: probe)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // Insertion points, not glyph edges: inside a right-to-left run the
        // logical position before a character is on its right.
        var positions = [CGFloat](repeating: 0, count: length + 1)
        var indexes = [Int](repeating: 0, count: length + 1)
        let count = layoutManager.getLineFragmentInsertionPoints(
            forCharacterAt: probe, alternatePositions: false, inDisplayOrder: false,
            positions: &positions, characterIndexes: &indexes)
        let x: CGFloat
        if let match = (0..<count).first(where: { indexes[$0] == utf16 }) {
            x = fragment.minX + positions[match]
        } else {
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            x = atEnd ? glyphRect.maxX : glyphRect.minX
        }
        return CGRect(x: origin.x + x - 1, y: origin.y + fragment.minY, width: 2, height: fragment.height)
    }

    /// The scroll view's visible area in content space.
    private var visibleRect: CGRect? {
        guard let anchor = anchorView, let scroll = anchor.enclosingScrollView else { return nil }
        return anchor.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), from: scroll)
    }

    /// A pinned file header covers the top of the visible area.
    private func isUnderHeader(_ point: CGPoint) -> Bool {
        guard let visible = visibleRect else { return false }
        return point.y < visible.minY + headerHeight
    }

    private func isOnHandle(_ point: CGPoint) -> Bool {
        guard showsHandles, let selection else { return false }
        return [selection.start, selection.end].contains { position in
            caretRect(for: position).map { $0.insetBy(dx: -22, dy: -16).contains(point) } ?? false
        }
    }

    func contentPoint(of recognizer: UIGestureRecognizer) -> CGPoint? {
        anchorView.map { recognizer.location(in: $0) }
    }

    func canBeginSelection(at point: CGPoint) -> Bool {
        !isUnderHeader(point) && !isOnHandle(point) && position(at: point, exact: true) != nil
    }

    func canBeginTap(at point: CGPoint) -> Bool {
        !isUnderHeader(point) && !isOnHandle(point) && (hasSelection || position(at: point, exact: true) != nil)
    }

    // MARK: Changing the selection

    private func setSelection(_ new: GitDiffSelection?, handles: Bool) {
        if selection != new { selection = new }
        let handles = handles && new != nil
        if showsHandles != handles { showsHandles = handles }
    }

    func clear() {
        stopDrag()
        setSelection(nil, handles: false)
        anchorView?.dismissMenu()
        if anchorView?.isFirstResponder == true { anchorView?.resignFirstResponder() }
    }

    @discardableResult
    private func selectWord(at point: CGPoint, handles: Bool) -> Bool {
        guard let position = position(at: point, exact: true, characterUnder: true),
              let line = line(position.lineID) else { return false }
        let word = GitDiffSelection.wordRange(in: Array(line.text), at: position.column)
        guard !word.isEmpty else { return false }
        setSelection(GitDiffSelection(anchor: GitDiffTextPosition(position.lineID, column: word.lowerBound),
                                      head: GitDiffTextPosition(position.lineID, column: word.upperBound)),
                     handles: handles)
        return true
    }

    private func selectLine(at point: CGPoint) {
        guard let position = position(at: point, exact: true), let line = line(position.lineID),
              !line.text.isEmpty else { return }
        setSelection(GitDiffSelection(anchor: GitDiffTextPosition(position.lineID, column: 0),
                                      head: GitDiffTextPosition(position.lineID, column: line.text.count)),
                     handles: false)
    }

    func selectAll(handles: Bool) {
        setSelection(GitDiffSelection.all(in: files, isExpanded: isExpanded), handles: handles)
    }

    func copySelection() {
        guard let selection, !selection.isEmpty else { return }
        let text = selection.text(in: files, isExpanded: isExpanded)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    /// A fold that hides either end leaves nothing to point at or copy there.
    func clearIfFolded() {
        guard let selection else { return }
        if !isExpanded(selection.start.lineID.file) || !isExpanded(selection.end.lineID.file) { clear() }
    }

    /// Pointer selections take the keyboard so Copy, Select All and Escape reach the panel.
    private func claimKeyboard() {
        guard let anchorView, !anchorView.isFirstResponder else { return }
        anchorView.becomeFirstResponder()
    }

    // MARK: Drags

    func beginWordDrag(at point: CGPoint, recognizer: UIGestureRecognizer? = nil) {
        anchorView?.dismissMenu()
        guard selectWord(at: point, handles: true), let selection else { return }
        dragMode = .word(selection.start, selection.end)
        beginLoupe(at: point)
        startTracking(recognizer, at: point)
    }

    func beginHandleDrag(_ handle: HandleEnd, at point: CGPoint, recognizer: UIGestureRecognizer? = nil) {
        guard let selection, !selection.isEmpty else { return }
        anchorView?.dismissMenu()
        let moving = handle == .start ? selection.start : selection.end
        let fixed = handle == .start ? selection.end : selection.start
        setSelection(GitDiffSelection(anchor: fixed, head: moving), handles: true)
        let caret = caretRect(for: moving)
        dragMode = .handle(caret.map { CGPoint(x: point.x - $0.midX, y: point.y - $0.midY) } ?? .zero)
        beginLoupe(at: caret.map { CGPoint(x: $0.midX, y: $0.midY) } ?? point)
        startTracking(recognizer, at: point)
    }

    func beginPointerDrag(at point: CGPoint, extending: Bool, recognizer: UIGestureRecognizer) {
        anchorView?.dismissMenu()
        guard let position = position(at: point, exact: false) else { return }
        if extending, let selection {
            setSelection(GitDiffSelection(anchor: selection.anchor, head: position), handles: false)
        } else {
            setSelection(GitDiffSelection(anchor: position, head: position), handles: false)
        }
        dragMode = .pointer
        claimKeyboard()
        startTracking(recognizer, at: point)
    }

    func dragMoved(to point: CGPoint) {
        guard let dragMode, var selection else { return }
        if !dragHasMoved, hypot(point.x - dragStart.x, point.y - dragStart.y) > 8 { dragHasMoved = true }
        switch dragMode {
        case .word(let lower, let upper):
            guard let position = position(at: point, exact: false) else { return }
            if position < lower {
                selection = GitDiffSelection(anchor: upper, head: position)
            } else if position > upper {
                selection = GitDiffSelection(anchor: lower, head: position)
            } else {
                selection = GitDiffSelection(anchor: lower, head: upper)
            }
            setSelection(selection, handles: true)
            moveLoupe(to: point)
        case .handle(let offset):
            let target = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
            guard let position = position(at: target, exact: false) else { return }
            // A handle stops at the other one, so the two never swap ends mid-drag.
            let headIsEnd = selection.head > selection.anchor
            guard headIsEnd ? position > selection.anchor : position < selection.anchor else { return }
            selection.head = position
            setSelection(selection, handles: true)
            moveLoupe(to: target)
        case .pointer:
            guard let position = position(at: point, exact: false) else { return }
            selection.head = position
            setSelection(selection, handles: false)
        }
    }

    func endDrag(presentingMenu: Bool) {
        let wasDragging = dragMode != nil
        stopDrag()
        guard wasDragging else { return }
        if selection?.isEmpty == true {
            clear()
        } else if presentingMenu {
            presentSelectionMenu()
        }
    }

    private func stopDrag() {
        autoscroll?.cancel()
        autoscroll = nil
        dragRecognizer = nil
        dragMode = nil
        dragHasMoved = false
        loupe?.invalidate()
        loupe = nil
    }

    // MARK: Taps

    func handleTap(at point: CGPoint, modifiers: UIKeyModifierFlags) {
        let now = ProcessInfo.processInfo.systemUptime
        var count = 1
        if let lastTap, now - lastTap.time < (lastTapWasPointer ? 0.5 : 0.35),
           hypot(point.x - lastTap.point.x, point.y - lastTap.point.y) < 12 {
            count = lastTap.count + 1
        }
        lastTap = (now, point, count)

        if lastTapWasPointer {
            switch count {
            case 1:
                if modifiers.contains(.shift), let selection, let position = position(at: point, exact: false) {
                    setSelection(GitDiffSelection(anchor: selection.anchor, head: position), handles: false)
                    // Collapsing the range ends it, as an empty drag does.
                    if hasSelection { claimKeyboard() } else { clear() }
                } else {
                    clear()
                }
            case 2:
                if selectWord(at: point, handles: false) { claimKeyboard() }
            default:
                selectLine(at: point)
                if hasSelection { claimKeyboard() }
            }
        } else {
            switch count {
            case 1:
                if let selection, let position = position(at: point, exact: true, characterUnder: true),
                   selection.start <= position, position < selection.end {
                    presentSelectionMenu(fallback: point)
                } else {
                    clear()
                }
            default:
                if selectWord(at: point, handles: true) { presentSelectionMenu() }
            }
        }
    }

    // MARK: Menus

    func presentContextMenu(at point: CGPoint) {
        menuLineID = position(at: point, exact: true)?.lineID
        menuIsPointer = true
        guard hasSelection || menuLineID != nil else { return }
        anchorView?.presentMenu(at: CGRect(x: point.x, y: point.y, width: 1, height: 1))
    }

    /// The Copy menu a finger selection opens. A Mac menu takes the next click
    /// to dismiss, so there it opens only on right-click.
    /// With neither end laid out (Select All in a long diff), the menu points
    /// at `fallback`, else at a selected row on screen.
    private func presentSelectionMenu(fallback: CGPoint? = nil) {
        #if !targetEnvironment(macCatalyst)
        guard let selection, !selection.isEmpty, let anchorView else { return }
        menuLineID = nil
        menuIsPointer = false
        let carets = [selection.start, selection.end].compactMap(caretRect(for:))
        var target: CGRect
        if let first = carets.first {
            target = carets.dropFirst().reduce(first) { $0.union($1) }
        } else if let fallback {
            target = CGRect(x: fallback.x, y: fallback.y, width: 1, height: 1)
        } else if let row = liveRows.filter({
                    selection.start.lineID <= $0.id && $0.id <= selection.end.lineID
                        && (visibleRect?.intersects($0.frame) ?? true)
                  }).map(\.frame).min(by: { $0.minY < $1.minY }) {
            target = row
        } else {
            return
        }
        if let visible = visibleRect {
            let clipped = target.intersection(visible)
            target = clipped.isNull ? CGRect(x: visible.midX, y: visible.midY, width: 1, height: 1) : clipped
        }
        anchorView.presentMenu(at: target)
        #endif
    }

    func menuElements() -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if hasSelection {
            items.append(UIAction(title: String(localized: "Copy", comment: "Git diff selection action"),
                                  image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
            })
        }
        // A right-click copies the row it hit; a touch menu keeps the old
        // one-tap Copy Line for a selection within one row.
        let copyLineID = menuIsPointer
            ? menuLineID
            : selection.flatMap { $0.start.lineID == $0.end.lineID ? $0.start.lineID : nil }
        if let copyLineID, let line = line(copyLineID) {
            let text = line.text
            items.append(UIAction(title: String(localized: "Copy Line", comment: "Git diff line action"),
                                  image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            })
        }
        items.append(UIAction(title: String(localized: "Select All", comment: "Git diff selection action")) {
            [weak self] _ in
            guard let self else { return }
            self.selectAll(handles: !self.menuIsPointer && self.showsHandles)
            if self.menuIsPointer, self.hasSelection { self.claimKeyboard() }
        })
        return items
    }

    // MARK: Loupe

    private func beginLoupe(at point: CGPoint) {
        guard let anchorView else { return }
        loupe?.invalidate()
        loupe = Ghostty.SelectionLoupe.begin(at: point, in: anchorView, fromSelectionWidgetView: nil)
    }

    private func moveLoupe(to point: CGPoint) {
        let caret = selection.flatMap { caretRect(for: $0.head) }
        loupe?.move(to: point, caretRect: caret ?? .null, tracksCaret: caret != nil)
    }

    // MARK: Autoscroll

    /// Scrolls while a drag sits near an edge, extending the selection as content moves under it.
    /// Without a recognizer (visionOS) the selection still follows the drag, but nothing scrolls.
    private func startTracking(_ recognizer: UIGestureRecognizer?, at point: CGPoint) {
        dragRecognizer = recognizer
        dragStart = point
        dragHasMoved = false
        autoscroll?.cancel()
        guard recognizer != nil else { return }
        autoscroll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self else { return }
                self.autoscrollStep()
            }
        }
    }

    private func autoscrollStep() {
        // A press that has not moved yet never scrolls, even when it starts near an edge.
        guard dragHasMoved, let anchor = anchorView, let scroll = anchor.enclosingScrollView,
              let recognizer = dragRecognizer,
              recognizer.state == .began || recognizer.state == .changed else { return }
        let finger = recognizer.location(in: scroll)
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        let band: CGFloat = 32
        func speed(_ depth: CGFloat) -> CGFloat { 3 + 22 * min(1, max(0, depth) / band) }

        var delta = CGPoint.zero
        let top = visible.minY + headerHeight
        if finger.y < top + band {
            delta.y = -speed(top + band - finger.y)
        } else if finger.y > visible.maxY - band {
            delta.y = speed(finger.y - (visible.maxY - band))
        }
        if style?.wrap == false {
            if finger.x < visible.minX + band {
                delta.x = -speed(visible.minX + band - finger.x)
            } else if finger.x > visible.maxX - band {
                delta.x = speed(finger.x - (visible.maxX - band))
            }
        }
        guard delta != .zero else { return }

        let inset = scroll.adjustedContentInset
        let minOffset = CGPoint(x: -inset.left, y: -inset.top)
        let maxOffset = CGPoint(
            x: max(minOffset.x, scroll.contentSize.width + inset.right - scroll.bounds.width),
            y: max(minOffset.y, scroll.contentSize.height + inset.bottom - scroll.bounds.height))
        let current = scroll.contentOffset
        let next = CGPoint(x: min(max(current.x + delta.x, minOffset.x), maxOffset.x),
                           y: min(max(current.y + delta.y, minOffset.y), maxOffset.y))
        guard next != current else { return }
        scroll.setContentOffset(next, animated: false)
        dragMoved(to: anchor.convert(recognizer.location(in: scroll), from: scroll))
    }
}
