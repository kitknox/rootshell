//
//  TerminalView+TextInput.swift
//  rootshell
//
//  UITextInput conformance for dictation and CJK IME composition support.
//  The terminal is a byte stream with no editable document, but iOS dictation
//  requires accurate cursor position tracking to function correctly.
//  The pure correction context owns the committed document and tracks
//  what iOS thinks the text field contains, so position/range queries return
//  correct values and `replace(_:withText:)` can compute proper diffs.
//

import UIKit

// MARK: - Text Position / Range helpers

class TerminalTextPosition: UITextPosition {
    let offset: Int
    let generation: UInt64?
    let assistanceGeneration: UInt64?
    init(_ offset: Int, generation: UInt64? = nil, assistanceGeneration: UInt64? = nil) {
        self.offset = offset
        self.generation = generation
        self.assistanceGeneration = assistanceGeneration
    }
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

    init(location: Int, length: Int, generation: UInt64? = nil, assistanceGeneration: UInt64? = nil) {
        _start = TerminalTextPosition(location, generation: generation, assistanceGeneration: assistanceGeneration)
        let (end, overflow) = location.addingReportingOverflow(length)
        _end = TerminalTextPosition(overflow ? -1 : end, generation: generation, assistanceGeneration: assistanceGeneration)
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
            sendUserInput(payload, documentMutation: .legacyDocument(bufferPrefix + incomingToken + delimiter))
        }

        return true
    }

    func handleThirdPartyKeyboardDelete() -> Bool {
        return false
    }

    var hasExplicitDictationSource: Bool {
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
        return false
    }

    var isLikelySystemDictationActive: Bool {
        if hasExplicitDictationSource { return true }
        guard let lastDictationActivityAt else { return false }
        return Date().timeIntervalSince(lastDictationActivityAt) < 2.0
    }

    // MARK: Preedit (inline composition display)

    /// Sends current composition text to GhosttyKit for inline preedit rendering.
    /// Pass nil or empty string to clear the preedit display.
    func syncIMEPreedit(_ text: String?) {
        guard let surface = self.surface else { return }
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
        invalidateWritingAssistance()
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
        refreshWritingAssistanceTraits()
    }

    func unmarkText() {
        defer { refreshWritingAssistanceTraits() }
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
            if let data = text.data(using: .utf8) {
                sendUserInput(data, documentMutation: .text(text, eligible: false))
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
        let start = usesIsolatedKoreanTextInputDocument ? 0 : documentBuffer.utf16.count
        return inputDocumentRange(location: start, length: text.utf16.count)
    }

    // MARK: Selected text

    var selectedTextRange: UITextRange? {
        get {
            if let selection = writingAssistanceSelection { return selection }
            // Cursor is always at the end of committed + marked text
            let committedCount = usesIsolatedKoreanTextInputDocument ? 0 : documentBuffer.utf16.count
            let pos = committedCount
                + (markedTextString?.utf16.count ?? 0)
                + (koreanPreeditTextForTextInput?.utf16.count ?? 0)
            return inputDocumentRange(location: pos, length: 0)
        }
        set {
            // QuickType can use selection + insertText instead of replace.
            // Remember the range with its original safety generation, without
            // moving the remote cursor or granting any new rewrite authority.
            guard let newValue else {
                writingAssistanceSelection = nil
                return
            }
            guard let range = newValue as? TerminalTextRange,
                  let start = range.start as? TerminalTextPosition,
                  let end = range.end as? TerminalTextPosition,
                  start.generation == correctionContext.documentGeneration,
                  end.generation == start.generation,
                  start.offset >= 0, end.offset >= start.offset,
                  end.offset <= fullDocument.utf16.count,
                  TerminalCorrectionContext.range(NSRange(location: start.offset, length: end.offset - start.offset), in: fullDocument) != nil else {
                invalidateWritingAssistance()
                return
            }
            if writingAssistanceMode != .off, eligibleWritingAssistanceSource != nil,
               markedTextString == nil, !usesIsolatedKoreanTextInputDocument,
               start.offset < end.offset, end.offset <= documentBuffer.utf16.count {
                writingAssistanceSelection = range
            } else {
                writingAssistanceSelection = nil
            }
        }
    }

    // MARK: Text reading / writing

    /// A selection is only a correction request while its document positions
    /// still describe this document. Stale positions must not eat plain typing.
    func consumeWritingAssistanceSelection(with text: String) -> Bool {
        guard let selection = writingAssistanceSelection else { return false }
        writingAssistanceSelection = nil
        guard let start = selection.start as? TerminalTextPosition,
              let end = selection.end as? TerminalTextPosition,
              start.generation == correctionContext.documentGeneration,
              end.generation == correctionContext.documentGeneration,
              start.offset >= 0, end.offset > start.offset,
              end.offset <= documentBuffer.utf16.count,
              TerminalCorrectionContext.range(NSRange(location: start.offset, length: end.offset - start.offset),
                                               in: documentBuffer) != nil else { return false }
        // Invalidation clears pending selections before ordinary insertion.
        // Explicit replacements still validate their original authority; a
        // rejected correction must not be retried as appended text.
        replace(selection, withText: text)
        return true
    }

    private func isRecentBulkDictationReplacement(_ range: NSRange) -> Bool {
        guard let lastBulkTextInputAt, let bulkDictationRange,
              bulkDictationDocumentGeneration == correctionContext.documentGeneration,
              range.length > 0,
              range.location >= bulkDictationRange.location,
              NSMaxRange(range) <= NSMaxRange(bulkDictationRange) else { return false }
        let age = Date().timeIntervalSince(lastBulkTextInputAt)
        return age >= 0 && age < 2
    }

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
        guard start.offset >= 0, end.offset <= doc.utf16.count, start.offset <= end.offset,
              start.generation == correctionContext.documentGeneration,
              end.generation == correctionContext.documentGeneration,
              let indices = TerminalCorrectionContext.range(NSRange(location: start.offset, length: end.offset - start.offset), in: doc) else {
            return nil
        }
        return String(doc[indices])
    }

    func replace(_ range: UITextRange, withText text: String) {
        writingAssistanceSelection = nil
        _ = refreshWritingAssistanceTraits()
        let text = text.precomposedStringWithCanonicalMapping
        guard let range = range as? TerminalTextRange,
              let rangeStart = range.start as? TerminalTextPosition,
              let rangeEnd = range.end as? TerminalTextPosition,
              rangeStart.offset >= 0, rangeEnd.offset >= rangeStart.offset,
              rangeEnd.offset <= fullDocument.utf16.count,
              rangeStart.generation == correctionContext.documentGeneration,
              rangeEnd.generation == correctionContext.documentGeneration,
              TerminalCorrectionContext.range(NSRange(location: rangeStart.offset, length: rangeEnd.offset - rangeStart.offset), in: fullDocument) != nil else {
            rejectWritingAssistanceReplacement()
            return
        }

        let usesIsolatedKoreanDocument = usesIsolatedKoreanTextInputDocument
        let bufCount = usesIsolatedKoreanDocument ? 0 : documentBuffer.utf16.count

        // If replacing beyond the committed buffer, this is either real UIKit
        // marked text or our synthetic Korean preedit. Do not treat insertions at
        // the caret after Korean preedit as marked-text replacement; that would
        // drop the active syllable.
        if rangeStart.offset >= bufCount {
            if markedTextString == nil,
               let koreanPreedit = koreanPreeditTextForTextInput,
               !koreanPreedit.isEmpty {
                let preeditEnd = bufCount + koreanPreedit.utf16.count
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

            if markedTextString == nil {
                insertText(text)
                return
            }

            clearKoreanCompositionIfNeeded(external: false)
            markedTextString = nil
            markedTextSelectedRange = NSRange(location: NSNotFound, length: 0)
            syncIMEPreedit(nil)
            if !text.isEmpty {
                if let data = text.data(using: .utf8) {
                    sendUserInput(data, documentMutation: .text(text, eligible: false))
                }
            }
            return
        }

        guard rangeEnd.offset <= bufCount else {
            rejectWritingAssistanceReplacement()
            return
        }
        let committedRange = NSRange(location: rangeStart.offset, length: rangeEnd.offset - rangeStart.offset)
        if isLikelySystemDictationActive || isRecentBulkDictationReplacement(committedRange) {
            guard let replacement = correctionContext.replacement(in: committedRange, with: text,
                                                                 generation: correctionContext.generation,
                                                                 dictation: true) else {
                rejectWritingAssistanceReplacement()
                return
            }
            sendUserInput(replacement.payload, documentMutation: .correction(replacement))
        } else {
            guard let generation = rangeStart.assistanceGeneration,
                  generation == rangeEnd.assistanceGeneration else {
                rejectWritingAssistanceReplacement()
                return
            }
            applyWritingAssistanceReplacement(committedRange, text: text, generation: generation)
        }
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
              let to = toPosition as? TerminalTextPosition,
              from.generation == correctionContext.documentGeneration, to.generation == from.generation,
              from.offset >= 0, to.offset >= from.offset, to.offset <= fullDocument.utf16.count else { return nil }
        return TerminalTextRange(start: from, end: to)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let pos = position as? TerminalTextPosition else { return nil }
        let (newOffset, overflow) = pos.offset.addingReportingOverflow(offset)
        guard !overflow, pos.generation == correctionContext.documentGeneration,
              newOffset >= 0, newOffset <= fullDocument.utf16.count else { return nil }
        return TerminalTextPosition(newOffset, generation: pos.generation, assistanceGeneration: pos.assistanceGeneration)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard offset != Int.min else { return nil }
        return self.position(from: position, offset: (direction == .left || direction == .up) ? -offset : offset)
    }

    private func inputDocumentRange(location: Int, length: Int) -> TerminalTextRange {
        TerminalTextRange(location: location, length: length, generation: correctionContext.documentGeneration,
                          assistanceGeneration: correctionContext.generation)
    }

    var beginningOfDocument: UITextPosition { inputDocumentRange(location: 0, length: 0).start }
    var endOfDocument: UITextPosition { inputDocumentRange(location: fullDocument.utf16.count, length: 0).end }

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
        let (distance, overflow) = b.offset.subtractingReportingOverflow(a.offset)
        return overflow ? 0 : distance
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let r = range as? TerminalTextRange else { return nil }
        return (direction == .left || direction == .up) ? r.start : r.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let document = fullDocument
        guard let position = position as? TerminalTextPosition,
              position.generation == correctionContext.documentGeneration,
              let point = TerminalCorrectionContext.range(NSRange(location: position.offset, length: 0), in: document) else { return nil }
        let lower: String.Index
        let upper: String.Index
        if direction == .left || direction == .up {
            guard point.lowerBound > document.startIndex else { return nil }
            upper = point.lowerBound
            lower = document.index(before: upper)
        } else {
            guard point.lowerBound < document.endIndex else { return nil }
            lower = point.lowerBound
            upper = document.index(after: lower)
        }
        let range = NSRange(lower..<upper, in: document)
        return inputDocumentRange(location: range.location, length: range.length)
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
        return endOfDocument
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        return endOfDocument
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        return inputDocumentRange(location: fullDocument.utf16.count, length: 0)
    }

    // MARK: Floating cursor (long-press spacebar trackpad)

    // iOS calls these when the on-screen keyboard's spacebar enters
    // long-press trackpad mode. Drag offsets arrive in our coordinate space;
    // we bucket them into whole-cell steps and emit arrow keys for each cell
    // crossed. Going through `sendKeyViaGhostty` (instead of writing escape
    // sequences) means DECCKM application-mode is respected, so vi/less/fzf
    // and DECCKM-aware TUIs all see the right encoding.

    func beginFloatingCursor(at point: CGPoint) {
        invalidateWritingAssistance()
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
