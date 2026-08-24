//
//  TerminalView+TextInput.swift
//  rootshell
//
//  UITextInput conformance for dictation and CJK IME composition support.
//  The terminal is a byte stream with no editable document, but iOS dictation
//  requires accurate cursor position tracking to function correctly.
//  We maintain a lightweight `documentBuffer` (in TerminalView) that tracks
//  what iOS thinks the text field contains, so position/range queries return
//  correct values and `replace(_:withText:)` can compute proper diffs.
//

import UIKit

// MARK: - Text Position / Range helpers

class TerminalTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

class TerminalTextRange: UITextRange {
    private let _start: TerminalTextPosition
    private let _end: TerminalTextPosition

    override var start: UITextPosition { _start }
    override var end: UITextPosition { _end }
    override var isEmpty: Bool { _start.offset == _end.offset }

    init(start: TerminalTextPosition, end: TerminalTextPosition) {
        _start = start
        _end = end
    }

    init(location: Int, length: Int) {
        _start = TerminalTextPosition(location)
        _end = TerminalTextPosition(location + length)
    }
}

// MARK: - UITextInput

extension Ghostty.TerminalView {

    var isLikelyThirdPartyKeyboard: Bool {
        guard let inputMode = textInputMode else { return false }
        let className = NSStringFromClass(type(of: inputMode))
        return className.localizedCaseInsensitiveContains("extension")
    }

    private func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
    }

    private func trailingTokenRange(in text: String) -> Range<String.Index> {
        if let lastWhitespace = text.lastIndex(where: \.isWhitespace) {
            return text.index(after: lastWhitespace)..<text.endIndex
        }
        return text.startIndex..<text.endIndex
    }

    private func splitTrailingDelimiter(in text: String) -> (token: String, delimiter: String) {
        guard let lastWordScalar = text.unicodeScalars.lastIndex(where: CharacterSet.alphanumerics.contains) else {
            return ("", text)
        }
        let tokenEnd = text.index(after: lastWordScalar)
        return (String(text[..<tokenEnd]), String(text[tokenEnd...]))
    }

    private func boundedDocumentBuffer(_ text: String) -> String {
        if text.count > 4096 {
            return String(text.suffix(2048))
        }
        return text
    }

    func handleThirdPartyKeyboardInsert(_ incomingText: String) -> Bool {
        guard isLikelyThirdPartyKeyboard,
              markedTextString == nil,
              incomingText.count > 1 else {
            return false
        }

        let tokenRange = trailingTokenRange(in: documentBuffer)
        let bufferPrefix = String(documentBuffer[..<tokenRange.lowerBound])
        let currentToken = String(documentBuffer[tokenRange])

        let (incomingToken, delimiter) = splitTrailingDelimiter(in: incomingText)
        if incomingToken.contains(where: \.isWhitespace) {
            return false
        }

        let prefixLength = commonPrefixLength(currentToken, incomingToken)
        let deleteCount = currentToken.count - prefixLength
        let replacementSuffix = String(incomingToken.dropFirst(prefixLength))
        let emittedText = replacementSuffix + delimiter

        guard deleteCount > 0 || !emittedText.isEmpty else { return false }

        var payload = Data(repeating: 0x7F, count: deleteCount)
        if let emittedData = emittedText.replacingOccurrences(of: "\n", with: "\r").data(using: .utf8) {
            payload.append(emittedData)
        }

        NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
        if !payload.isEmpty {
            sendUserInput(payload)
        }

        let updatedBuffer = bufferPrefix + incomingToken + delimiter
        documentBuffer = boundedDocumentBuffer(updatedBuffer)
        return true
    }

    func handleThirdPartyKeyboardDelete() -> Bool {
        return false
    }

    private var isLikelySystemDictationActive: Bool {
        if isHandlingDictationResult || !pendingDictationPlaceholderTokens.isEmpty {
            return true
        }
        if textInputMode?.primaryLanguage == "dictation" {
            return true
        }
        if #available(iOS 16.4, visionOS 1.0, *) {
            if let context = UITextInputContext.current(),
               context.isDictationInputExpected {
                return true
            }
        }
        if let lastBulkTextInputAt,
           Date().timeIntervalSince(lastBulkTextInputAt) < 2.0 {
            return true
        }
        guard let lastDictationActivityAt else { return false }
        return Date().timeIntervalSince(lastDictationActivityAt) < 2.0
    }

    private var allowsCommittedTextReplacement: Bool {
        isLikelySystemDictationActive || !isLikelyThirdPartyKeyboard
    }

    // MARK: Preedit (inline composition display)

    /// Sends current composition text to GhosttyKit for inline preedit rendering.
    /// Pass nil or empty string to clear the preedit display.
    ///
    /// While forwarding, the preedit renders under the EXTERNAL cursor; the
    /// UITextInput document bookkeeping stays local with first responder.
    func syncIMEPreedit(_ text: String?) {
        #if targetEnvironment(macCatalyst)
        renderPreedit(text, on: self)
        #else
        let target = externalInputRedirectTarget ?? self
        // Focus moved since the last render: clear the stale preedit there.
        if let previous = lastExternalPreeditTarget, previous !== target {
            renderPreedit(nil, on: previous)
        }
        lastExternalPreeditTarget = target === self ? nil : target
        renderPreedit(text, on: target)
        #endif
    }

    private func renderPreedit(_ text: String?, on view: Ghostty.TerminalView) {
        guard let surface = view.surface else { return }
        if let text, !text.isEmpty {
            let normalized = text.precomposedStringWithCanonicalMapping
            normalized.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(normalized.utf8.count))
            }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
        ghostty_surface_refresh(surface)
    }

    // MARK: Marked text (composition / dictation)

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        #if targetEnvironment(macCatalyst)
        if koreanCompositionModel.hasActiveComposition,
           markedText?.isEmpty != false {
            markedTextString = nil
            markedTextSelectedRange = NSRange(location: NSNotFound, length: 0)
            return
        }
        #endif

        clearKoreanCompositionIfNeeded(external: false)
        let normalized = markedText?.precomposedStringWithCanonicalMapping
        markedTextString = normalized
        markedTextSelectedRange = selectedRange
        syncIMEPreedit(normalized)
    }

    func unmarkText() {
        #if targetEnvironment(macCatalyst)
        // Match macOS Ghostty: marked text is preedit only. Committed text
        // must arrive through insertText; unmarkText just clears preedit.
        if markedTextString != nil {
            markedTextString = nil
            markedTextSelectedRange = NSRange(location: NSNotFound, length: 0)
            if !koreanCompositionModel.hasActiveComposition {
                syncIMEPreedit(nil)
            }
        }
        #else

        // Korean on iOS hardware keyboards can call unmarkText() after every unmarked insertText()
        // even though composition is still ongoing. Treat an empty unmark as a
        // no-op for our local Korean preedit; real commits happen when the next
        // independent text/key path forces the preedit to flush.
        guard markedTextString != nil else {
            return
        }

        // Some CJK IMEs commit by setting markedText to the final candidate
        // then calling unmarkText(). Flush the composed text to the terminal
        // before clearing, otherwise the candidate is silently dropped.
        if let text = markedTextString, !text.isEmpty {
            documentBuffer.append(text)
            if documentBuffer.count > 4096 {
                documentBuffer = String(documentBuffer.suffix(2048))
            }
            if let data = text.data(using: .utf8) {
                sendUserInput(data)
            }
        }
        markedTextString = nil
        markedTextSelectedRange = NSRange(location: NSNotFound, length: 0)
        syncIMEPreedit(nil)
        #endif
    }

    var markedTextRange: UITextRange? {
        let activeMarkedText = markedTextString ?? koreanPreeditTextForTextInput
        guard let text = activeMarkedText, !text.isEmpty else { return nil }
        let start = usesIsolatedKoreanTextInputDocument ? 0 : documentBuffer.count
        return TerminalTextRange(location: start, length: text.count)
    }

    // MARK: Selected text

    var selectedTextRange: UITextRange? {
        get {
            // Cursor is always at the end of committed + marked text
            let committedCount = usesIsolatedKoreanTextInputDocument ? 0 : documentBuffer.count
            let pos = committedCount
                + (markedTextString?.count ?? 0)
                + (koreanPreeditTextForTextInput?.count ?? 0)
            return TerminalTextRange(location: pos, length: 0)
        }
        set { /* ignored — terminal cursor is always at end */ }
    }

    // MARK: Text reading / writing

    /// The full "document" iOS sees: committed buffer + any marked/composition text.
    private var fullDocument: String {
        if usesIsolatedKoreanTextInputDocument {
            return markedTextString ?? koreanPreeditTextForTextInput ?? ""
        }

        return documentBuffer + (markedTextString ?? "") + (koreanPreeditTextForTextInput ?? "")
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? TerminalTextRange,
              let start = range.start as? TerminalTextPosition,
              let end = range.end as? TerminalTextPosition else { return nil }
        let doc = fullDocument
        guard start.offset >= 0, end.offset <= doc.count, start.offset <= end.offset else {
            return nil
        }
        let startIdx = doc.index(doc.startIndex, offsetBy: start.offset)
        let endIdx = doc.index(doc.startIndex, offsetBy: end.offset)
        return String(doc[startIdx..<endIdx])
    }

    func replace(_ range: UITextRange, withText text: String) {
        let text = text.precomposedStringWithCanonicalMapping
        guard let range = range as? TerminalTextRange,
              let rangeStart = range.start as? TerminalTextPosition,
              let rangeEnd = range.end as? TerminalTextPosition else {
            insertText(text)
            return
        }

        let usesIsolatedKoreanDocument = usesIsolatedKoreanTextInputDocument
        let bufCount = usesIsolatedKoreanDocument ? 0 : documentBuffer.count

        // If replacing beyond the committed buffer, this is either real UIKit
        // marked text or our synthetic Korean preedit. Do not treat insertions at
        // the caret after Korean preedit as marked-text replacement; that would
        // drop the active syllable.
        if rangeStart.offset >= bufCount {
            if markedTextString == nil,
               let koreanPreedit = koreanPreeditTextForTextInput,
               !koreanPreedit.isEmpty {
                let preeditEnd = bufCount + koreanPreedit.count
                let replacesKoreanPreedit = rangeStart.offset == bufCount
                    && rangeEnd.offset <= preeditEnd
                if replacesKoreanPreedit {
                    commitKoreanReplacementText(text, external: false)
                    return
                }

                commitKoreanCompositionIfNeeded(external: false)
                if !text.isEmpty {
                    insertText(text)
                }
                return
            }

            if usesIsolatedKoreanDocument && markedTextString == nil {
                clearKoreanCompositionIfNeeded(external: false)
                if !text.isEmpty {
                    if handleKoreanCompositionInsertIfNeeded(text) {
                        return
                    }
                    insertText(text)
                }
                return
            }

            clearKoreanCompositionIfNeeded(external: false)
            markedTextString = nil
            markedTextSelectedRange = NSRange(location: NSNotFound, length: 0)
            syncIMEPreedit(nil)
            if !text.isEmpty {
                documentBuffer.append(text)
                if documentBuffer.count > 4096 {
                    documentBuffer = String(documentBuffer.suffix(2048))
                }
                if let data = text.data(using: .utf8) {
                    sendUserInput(data)
                }
            }
            return
        }

        // Replacing committed text: send backspaces to erase from cursor back
        // to the start of the replaced range, then re-type the replacement +
        // any text that was after the replaced range.
        guard allowsCommittedTextReplacement else {
            return
        }

        let replaceEnd = min(rangeEnd.offset, bufCount)
        let startIdx = documentBuffer.index(documentBuffer.startIndex, offsetBy: rangeStart.offset)
        let endIdx = documentBuffer.index(documentBuffer.startIndex, offsetBy: replaceEnd)
        let afterText = String(documentBuffer[endIdx...])

        let backspaceCount = bufCount - rangeStart.offset

        // Rebuild buffer
        documentBuffer = String(documentBuffer[..<startIdx]) + text + afterText

        // Send backspaces + replacement as a single payload for atomicity.
        // This ensures the TUI receives the complete correction in one read,
        // avoiding partial states where the input is empty before replacement arrives.
        var payload = Data(repeating: 0x7F, count: backspaceCount)
        let newContent = (text + afterText).replacingOccurrences(of: "\n", with: "\r")
        if let textData = newContent.data(using: .utf8) {
            payload.append(textData)
        }
        sendUserInput(payload)
    }

    func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        let text = dictationResult.map(\.text).joined()
        guard !text.isEmpty else { return }
        lastDictationActivityAt = Date()
        isHandlingDictationResult = true
        defer { isHandlingDictationResult = false }
        insertText(text)
    }

    func insertText(_ text: String, alternatives: [String], style: UITextAlternativeStyle) {
        // The flag has to stay set across insertText, so the defer belongs to
        // the function scope, not the `if` (where it fired immediately).
        let isDictation = !alternatives.isEmpty || style != .none
        if isDictation {
            lastDictationActivityAt = Date()
            isHandlingDictationResult = true
        }
        defer { if isDictation { isHandlingDictationResult = false } }
        insertText(text)
    }

    var insertDictationResultPlaceholder: Any {
        let token = UUID().uuidString
        lastDictationActivityAt = Date()
        pendingDictationPlaceholderTokens.insert(token)
        return token as NSString
    }

    func frameForDictationResultPlaceholder(_ placeholder: Any) -> CGRect {
        caretRect(for: endOfDocument)
    }

    func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {
        lastDictationActivityAt = Date()
        if let token = placeholder as? String {
            pendingDictationPlaceholderTokens.remove(token)
        } else if let token = placeholder as? NSString {
            pendingDictationPlaceholderTokens.remove(token as String)
        } else {
            pendingDictationPlaceholderTokens.removeAll()
        }
    }

    func dictationRecordingDidEnd() {
        lastDictationActivityAt = Date()
    }

    func dictationRecognitionFailed() {
        lastDictationActivityAt = nil
        pendingDictationPlaceholderTokens.removeAll()
    }

    // MARK: Position / range arithmetic

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalTextPosition,
              let to = toPosition as? TerminalTextPosition else { return nil }
        return TerminalTextRange(start: from, end: to)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let pos = position as? TerminalTextPosition else { return nil }
        let newOffset = pos.offset + offset
        guard newOffset >= 0, newOffset <= fullDocument.count else { return nil }
        return TerminalTextPosition(newOffset)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        return self.position(from: position, offset: (direction == .left || direction == .up) ? -offset : offset)
    }

    var beginningOfDocument: UITextPosition { TerminalTextPosition(0) }
    var endOfDocument: UITextPosition { TerminalTextPosition(fullDocument.count) }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? TerminalTextPosition,
              let b = other as? TerminalTextPosition else { return .orderedSame }
        if a.offset < b.offset { return .orderedAscending }
        if a.offset > b.offset { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = from as? TerminalTextPosition,
              let b = toPosition as? TerminalTextPosition else { return 0 }
        return b.offset - a.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let r = range as? TerminalTextRange else { return nil }
        return (direction == .left || direction == .up) ? r.start : r.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        return TerminalTextRange(location: 0, length: 0)
    }

    // MARK: Writing direction

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        return .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        // Terminal is always LTR
    }

    // MARK: Geometry

    /// View-local geometry of the IME preedit / caret cell.
    ///
    /// `ghostty_surface_ime_point` reports, in logical points (already divided
    /// by content scale), the *midpoint x* and *bottom y* of the caret cell plus
    /// the cell height. The preedit `width`, however, comes back in device
    /// pixels (Ghostty intentionally skips the content-scale divide there), so we
    /// downscale it here. We undo the half-cell x offset to recover the cell's
    /// left edge. Because the Ghostty surface is sized to the view bounds, these
    /// values are already in this view's coordinate space — UIKit converts them
    /// to screen space when positioning the IME candidate bar.
    private struct IMECellGeometry {
        var cellLeft: CGFloat
        var cellTop: CGFloat
        var cellHeight: CGFloat
        var preeditWidth: CGFloat
    }

    private struct IMECandidatePlacement {
        var shouldLift: Bool
        var clearanceHeight: CGFloat
        var visibleBounds: CGRect
    }

    private func imeCellGeometry() -> IMECellGeometry? {
        guard let surface = self.surface else { return nil }
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)

        let scale = contentScaleFactor > 0 ? contentScaleFactor : 1
        let cellHeight = max(CGFloat(h), cellSize.height)
        // x is the cell midpoint; recover the left edge.
        let cellLeft = CGFloat(x) - cellSize.width / 2
        // y is the bottom of the cell; the top is one cell up.
        let cellTop = CGFloat(y) - CGFloat(h)
        // Preedit width arrives in device pixels — convert to points.
        let preeditWidth = CGFloat(w) / scale

        return IMECellGeometry(
            cellLeft: cellLeft,
            cellTop: cellTop,
            cellHeight: cellHeight,
            preeditWidth: preeditWidth
        )
    }

    private func imeVisibleBounds() -> CGRect {
        #if !targetEnvironment(macCatalyst)
        // External content has no device safe areas or keyboard toolbar.
        if isExternalDisplayTerminal { return bounds }
        #endif
        let bottomInset = max(safeAreaInsets.bottom, reservedKeyboardToolbarHeightAtBottom)
        let insets = UIEdgeInsets(top: safeAreaInsets.top, left: 0, bottom: bottomInset, right: 0)
        let visibleBounds = bounds.inset(by: insets)
        guard !visibleBounds.isNull, !visibleBounds.isEmpty else { return bounds }
        return visibleBounds
    }

    private func imeKeyboardObstructionTop(in window: UIWindow) -> CGFloat? {
        let keyboardFrame = KeyboardTracker.shared.keyboardFrame
        guard !keyboardFrame.isNull, !keyboardFrame.isEmpty else { return nil }

#if os(visionOS)
        // visionOS has no UIScreen; there is no docked hardware-keyboard
        // candidate strip to clear, so the keyboard frame (already in window
        // space) needs no screen→window conversion.
        let frameInWindow = keyboardFrame
#else
        let frameInWindow = window.screen.coordinateSpace.convert(
            keyboardFrame,
            to: window.coordinateSpace
        )
#endif
        let intersection = window.bounds.intersection(frameInWindow)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }

        // Only treat bottom-docked frames as an obstruction. Floating/split
        // keyboard frames and candidate popovers should not shrink the terminal
        // placement space.
        let touchesBottom = abs(intersection.maxY - window.bounds.maxY) <= 2
        guard touchesBottom else { return nil }
        return intersection.minY
    }

    private func estimatedIMECandidateHeight(cellHeight: CGFloat) -> CGFloat {
        // The hardware-keyboard candidate strip is system UI; it should not
        // scale with terminal font size. Keep this close to observed iPadOS
        // strip heights so the forced-above anchor clears the text without
        // jumping far away from the active row.
        min(88, max(72, ceil(cellHeight * 2.5)))
    }

    private func imeFlipThreshold(visibleHeight: CGFloat, candidateHeight: CGFloat) -> CGFloat {
        // UIKit starts clamping the candidate strip before it literally runs
        // out of room below the caret, and that clamp threshold varies across
        // device/window/font combinations. Use a viewport-relative risk band,
        // capped so large iPads do not flip at mid-screen.
        let viewportBand = visibleHeight * 0.42
        let minimumBand = candidateHeight + 160
        return min(420, max(minimumBand, viewportBand))
    }

    private func imeCandidatePlacement(for rect: CGRect) -> IMECandidatePlacement? {
        guard markedTextString != nil else { return nil }

        // Software-keyboard composition is already constrained by the keyboard
        // frame. The problematic floating candidate bar is the hardware-keyboard
        // path, where UIKit may clamp the bar back onto the terminal row.
        guard !KeyboardTracker.shared.isSoftwareKeyboardVisible else { return nil }

        let visibleBounds = imeVisibleBounds()
        guard visibleBounds.width > 0, visibleBounds.height > 0 else { return nil }

        let candidateHeight = estimatedIMECandidateHeight(cellHeight: rect.height)
        let verticalGap: CGFloat = 4
        let clearanceHeight = candidateHeight + verticalGap

        var roomAbove = max(0, rect.minY - visibleBounds.minY)
        var roomBelow = max(0, visibleBounds.maxY - rect.maxY)

        if let window {
            let rectInWindow = convert(rect, to: window)
            let safeWindowBounds = window.bounds.inset(by: window.safeAreaInsets)
            roomAbove = min(roomAbove, max(0, rectInWindow.minY - safeWindowBounds.minY))

            let bottomLimit = min(
                safeWindowBounds.maxY,
                imeKeyboardObstructionTop(in: window) ?? safeWindowBounds.maxY
            )
            roomBelow = min(roomBelow, max(0, bottomLimit - rectInWindow.maxY))
        }

        let fitsAbove = roomAbove >= clearanceHeight
        let fitsBelow = roomBelow >= clearanceHeight
        let shouldAvoidBelow = roomBelow < imeFlipThreshold(
            visibleHeight: visibleBounds.height,
            candidateHeight: candidateHeight
        )

        let shouldLift: Bool
        switch (fitsAbove, fitsBelow) {
        case (true, false):
            shouldLift = true
        case (false, true):
            shouldLift = false
        case (true, true):
            // Flip only inside the measured bottom risk band. Choosing purely
            // by "which side has more room" flips too early and makes the strip
            // jump high while there is still plenty of usable space below.
            shouldLift = shouldAvoidBelow
        case (false, false):
            // Tiny split panes may not fit the full strip on either side; choose
            // the side with more space and let UIKit do the final clipping.
            shouldLift = roomAbove > roomBelow
        }

        return IMECandidatePlacement(
            shouldLift: shouldLift,
            clearanceHeight: clearanceHeight,
            visibleBounds: visibleBounds
        )
    }

    private func imeCandidateAnchorRect(for rect: CGRect) -> CGRect {
        guard let placement = imeCandidatePlacement(for: rect),
              placement.shouldLift else {
            return rect
        }

        let candidateTop = rect.minY - placement.clearanceHeight
        let minY = placement.visibleBounds.minY
        let y = max(minY, candidateTop - rect.height)
        return CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
    }

    private func clampIMEPreeditRectToBounds(_ rect: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return rect }
        let clamped = rect.intersection(bounds)
        if !clamped.isNull { return clamped }
        return rect
    }

    /// Bounding box of the inline preedit in view-local points: anchored at the
    /// caret cell's left edge, spanning the preedit width (falling back to one
    /// cell when there is no marked text), one row tall. iOS positions the
    /// candidate bar against this box.
    private func imePreeditRect() -> CGRect? {
        guard let geo = imeCellGeometry() else { return nil }
        let width = max(geo.preeditWidth, cellSize.width, 1)
        return CGRect(x: geo.cellLeft, y: geo.cellTop, width: width, height: geo.cellHeight)
    }

    func firstRect(for range: UITextRange) -> CGRect {
        guard let rect = imePreeditRect() else {
            return CGRect(x: 0, y: 0, width: 1, height: 20)
        }
        // Keep this tied to the real inline preedit. Some IMEs use firstRect as
        // document geometry rather than as a candidate anchor; lifting both
        // firstRect and caretRect can push the candidate UI far above the row.
        return clampIMEPreeditRectToBounds(rect)
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        guard let geo = imeCellGeometry() else {
            return CGRect(x: 0, y: 0, width: 2, height: 20)
        }
        let trueRect = CGRect(x: geo.cellLeft, y: geo.cellTop, width: 2, height: geo.cellHeight)
        return imeCandidateAnchorRect(for: trueRect)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        return []
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        return TerminalTextPosition(fullDocument.count)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        return TerminalTextPosition(fullDocument.count)
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        let pos = fullDocument.count
        return TerminalTextRange(location: pos, length: 0)
    }

    // MARK: Floating cursor (long-press spacebar trackpad)

    // iOS calls these when the on-screen keyboard's spacebar enters
    // long-press trackpad mode. Drag offsets arrive in our coordinate space;
    // we bucket them into whole-cell steps and emit arrow keys for each cell
    // crossed. Going through `sendKeyViaGhostty` (instead of writing escape
    // sequences) means DECCKM application-mode is respected, so vi/less/fzf
    // and DECCKM-aware TUIs all see the right encoding.

    func beginFloatingCursor(at point: CGPoint) {
        floatingCursorStartPoint = point
        floatingCursorCumulativeCol = 0
        floatingCursorCumulativeRow = 0
    }

    func updateFloatingCursor(at point: CGPoint) {
        guard let start = floatingCursorStartPoint else { return }
        guard cellSize.width > 0, cellSize.height > 0 else { return }

        let dx = point.x - start.x
        let dy = point.y - start.y
        let targetCol = Int((dx / cellSize.width).rounded(.towardZero))
        let targetRow = Int((dy / cellSize.height).rounded(.towardZero))

        let stepCol = targetCol - floatingCursorCumulativeCol
        let stepRow = targetRow - floatingCursorCumulativeRow

        if stepCol != 0 {
            let key: UIKeyboardHIDUsage = stepCol > 0 ? .keyboardRightArrow : .keyboardLeftArrow
            for _ in 0..<abs(stepCol) {
                sendKeyViaGhostty(keyCode: key, action: .press, mods: .none)
            }
            floatingCursorCumulativeCol = targetCol
        }

        if stepRow != 0 {
            let key: UIKeyboardHIDUsage = stepRow > 0 ? .keyboardDownArrow : .keyboardUpArrow
            for _ in 0..<abs(stepRow) {
                sendKeyViaGhostty(keyCode: key, action: .press, mods: .none)
            }
            floatingCursorCumulativeRow = targetRow
        }
    }

    func endFloatingCursor() {
        floatingCursorStartPoint = nil
        floatingCursorCumulativeCol = 0
        floatingCursorCumulativeRow = 0
    }
}
