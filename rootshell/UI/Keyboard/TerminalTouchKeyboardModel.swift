import Foundation
import CoreGraphics

/// One partition for the system toolbar and the touch keyboard. Runtime buttons
/// reserve main-row slots without changing the user's saved configuration.
nonisolated enum KeyboardToolbarOverflow {
    static func layout<Slot: Equatable>(main: [Slot], drawers: [[Slot]], capacity: Int,
                                       reservedSlots: Int = 0, drawerToggle: Slot,
                                       keepsDrawerToggleVisible: Bool) -> (main: [Slot], drawers: [[Slot]]) {
        let available = max(1, capacity - max(0, reservedSlots))
        var visible = Array(main.prefix(available))
        var overflow = Array(main.dropFirst(available))
        var rows = drawers.isEmpty ? [[]] : drawers
        let hasContent = (overflow + rows.flatMap { $0 }).contains { $0 != drawerToggle }
        if hasContent, keepsDrawerToggleVisible, !visible.contains(drawerToggle) {
            if visible.count == available { overflow.insert(visible.removeLast(), at: 0) }
            visible.append(drawerToggle)
        }
        rows[0] = overflow + rows[0]
        rows = rows.map { $0.filter { $0 != drawerToggle } }
        return (visible, rows)
    }
}

/// A page contains only complete key cells. The last page keeps the same width
/// as every other page, so the scroll view can land on an exact page boundary.
nonisolated struct ToolbarPageLayout {
    let viewportWidth: CGFloat
    let capacity: Int
    let itemCount: Int

    init(viewportWidth: CGFloat, buttonWidth: CGFloat, spacing: CGFloat, itemCount: Int) {
        self.viewportWidth = max(1, viewportWidth)
        capacity = max(1, Int((max(1, viewportWidth) + spacing) / max(1, buttonWidth + spacing)))
        self.itemCount = max(0, itemCount)
    }

    var cellWidth: CGFloat { viewportWidth / CGFloat(capacity) }
    var pageCount: Int { max(1, (itemCount + capacity - 1) / capacity) }
    var contentWidth: CGFloat { CGFloat(pageCount) * viewportWidth }

    func offset(containing item: Int) -> CGFloat {
        CGFloat(min(pageCount - 1, max(0, item) / capacity)) * viewportWidth
    }
}

/// Platform-independent behavior shared by the touch surface and its tests.
nonisolated enum TerminalTouchKeyboardModel {
    /// Stable persisted identifiers; rendering implementations live in the style files.
    enum Style: String, CaseIterable, Sendable {
        case flat, sculpted, steampunk, phosphor
        case beigeBox = "beige-box"
        case neonGrid = "neon-grid"
        case circuitBoard = "circuit-board"

        var displayName: String {
            switch self {
            case .flat: String(localized: "Flat")
            case .sculpted: String(localized: "Sculpted")
            case .steampunk: String(localized: "Steampunk")
            case .phosphor: String(localized: "Phosphor")
            case .beigeBox: String(localized: "Beige Box")
            case .neonGrid: String(localized: "Neon Grid")
            case .circuitBoard: String(localized: "Circuit Board")
            }
        }
    }

    enum PhosphorColor: String, CaseIterable, Sendable {
        case green, amber, white, theme

        var displayName: String {
            switch self {
            case .green: String(localized: "Green")
            case .amber: String(localized: "Amber")
            case .white: String(localized: "White")
            case .theme: String(localized: "Terminal Theme")
            }
        }
    }

    enum BackgroundEffectPlacement: String, CaseIterable, Sendable {
        case off
        case toolbar
        case entireKeyboard = "entire-keyboard"

        var displayName: String {
            switch self {
            case .off: String(localized: "Off")
            case .toolbar: String(localized: "Toolbar Only")
            case .entireKeyboard: String(localized: "Entire Keyboard")
            }
        }
    }

    /// Docked keyboard height, tallest first. Every size but `extraLarge` extends
    /// into the bottom safe area. Raw values are the persisted pre-rename names.
    enum Height: String, CaseIterable, Sendable {
        case extraLarge = "full"
        case large = "compact"
        case medium = "shorter"
        case small = "shortest"
        case extraSmall

        var displayName: String {
            switch self {
            case .extraLarge: String(localized: "Extra Large", comment: "Terminal keyboard height")
            case .large: String(localized: "Large", comment: "Terminal keyboard height")
            case .medium: String(localized: "Medium", comment: "Terminal keyboard height")
            case .small: String(localized: "Small", comment: "Terminal keyboard height")
            case .extraSmall: String(localized: "Extra Small", comment: "Terminal keyboard height")
            }
        }

        var usesBottomSafeArea: Bool { self != .extraLarge }

        /// The front display keeps its own height once set; until then it follows the inner one.
        static func resolved(inner: Self, front: Self?, isFrontDisplay: Bool) -> Self {
            isFrontDisplay ? front ?? inner : inner
        }

        /// Positive steps shrink the keyboard. Clamps at both ends.
        func stepped(by offset: Int) -> Self {
            let all = Self.allCases
            let index = min(max(all.firstIndex(of: self)! + offset, 0), all.count - 1)
            return all[index]
        }

        func rowHeight(verticallyCompact: Bool, pad: Bool) -> CGFloat {
            switch self {
            case .extraLarge, .large: verticallyCompact ? 40 : (pad ? 60 : 54)
            case .medium: verticallyCompact ? 36 : (pad ? 52 : 47)
            case .small: verticallyCompact ? 32 : (pad ? 46 : 41)
            case .extraSmall: verticallyCompact ? 29 : (pad ? 40 : 36)
            }
        }

        /// Main toolbar row, before any drawer rows.
        var toolbarRowHeight: CGFloat {
            switch self {
            case .extraLarge, .large: 48
            case .medium: 42
            case .small: 38
            case .extraSmall: 34
            }
        }

        var toolbarDrawerRowHeight: CGFloat {
            switch self {
            case .extraLarge, .large: 44
            case .medium: 40
            case .small: 36
            case .extraSmall: 33
            }
        }
    }

    enum FloatingGlassStyle: String, CaseIterable, Sendable {
        case regular, clear, solid

        var displayName: String {
            switch self {
            case .regular: String(localized: "Regular")
            case .clear: String(localized: "Clear")
            case .solid: String(localized: "Solid")
            }
        }
    }

    /// Config files can supply values outside the slider's range.
    static func floatingGlassTintOpacity(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.25
    }

    enum Modifier: Int, CaseIterable, Sendable {
        // Matches KeyModifiers without importing UIKit into the model.
        case control = 1, alt = 2, command = 4, shift = 8
    }

    struct Modifiers: Sendable {
        private(set) var oneShot: Set<Modifier> = []
        private(set) var locked: Set<Modifier> = []
        private var held: Set<Modifier> = []
        private var used: Set<Modifier> = []
        private var lastTap: [Modifier: TimeInterval] = [:]

        var rawValue: Int { oneShot.union(locked).union(held).reduce(0) { $0 | $1.rawValue } }
        func isActive(_ modifier: Modifier) -> Bool { rawValue & modifier.rawValue != 0 }

        mutating func begin(_ modifier: Modifier) {
            held.insert(modifier)
            used.remove(modifier)
        }

        mutating func end(_ modifier: Modifier, at time: TimeInterval, cancelled: Bool = false) {
            held.remove(modifier)
            defer { used.remove(modifier) }
            guard !cancelled, !used.contains(modifier) else { return }
            if locked.remove(modifier) != nil {
                lastTap[modifier] = nil
            } else if oneShot.contains(modifier), time - (lastTap[modifier] ?? -.infinity) < 0.5 {
                oneShot.remove(modifier)
                locked.insert(modifier)
                lastTap[modifier] = nil
            } else if oneShot.remove(modifier) == nil {
                oneShot.insert(modifier)
                lastTap[modifier] = time
            } else {
                lastTap[modifier] = nil
            }
        }

        mutating func consume(_ rawValue: Int? = nil) {
            let consumed = rawValue.map { value in Set(Modifier.allCases.filter { value & $0.rawValue != 0 }) }
                ?? oneShot.union(held)
            used.formUnion(held.intersection(consumed))
            oneShot.subtract(consumed)
            for modifier in consumed { lastTap[modifier] = nil }
        }

        mutating func cancelHeld() { held.removeAll(); used.removeAll() }
        mutating func reset() { self = Self() }
    }

    /// One store per window. Reference values let placement and keyboard-choice
    /// changes stay current without copying input-host state between terminals.
    struct StateStore<State> {
        private var shared: State?
        private var tabs: [UUID: State] = [:]
        private var lastState: State?
        private var perTab = false

        mutating func activate(tabID: UUID?, perTab: Bool, make: () -> State,
                               copyChoices: (State, State) -> Void) -> State {
            let selected = state(tabID: tabID, perTab: perTab, make: make)
            // A settings sheet may resign the terminal before changing scope.
            // Seed the new scope from the last displayed state on next focus.
            if self.perTab != perTab, let lastState { copyChoices(lastState, selected) }
            self.perTab = perTab
            lastState = selected
            return selected
        }

        mutating func state(tabID: UUID?, perTab: Bool, make: () -> State) -> State {
            guard perTab, let tabID else {
                if let shared { return shared }
                let state = make()
                shared = state
                return state
            }
            if let state = tabs[tabID] { return state }
            let state = make()
            tabs[tabID] = state
            return state
        }
    }

    /// Durable presentation choices. Touches, repeats, suggestions and prediction
    /// context belong to the input host and must never travel to another terminal.
    struct PresentationState {
        var modifiers = Modifiers()
        var page = Page.letters
        var preset = Preset.shell
        var toolPage = ToolPage.typing
        var toolbarDrawer = ToolbarDrawerState.closed
        var drawerOffset = CGPoint.zero
        var toolbarOffsets: [Int: CGPoint] = [:]

        func suspendingInput() -> Self {
            var result = self
            result.modifiers.cancelHeld()
            return result
        }
    }

    enum Page: CaseIterable { case letters, numbers, symbols }
    enum Action: Hashable {
        case text(String), key(String), modifier(Modifier)
        case page, switchKeyboard, drawer, dismiss, joystick, compose, paste, tabs
        case toolbar(String), custom(UUID)
    }

    struct Key: Hashable {
        let title: String
        let action: Action
        var symbol: String? = nil
        var weight: Double = 1
        var accessibility: String? = nil

        var isText: Bool { if case .text = action { return true }; return false }
        var letter: String? {
            guard case .text(let text) = action, text.count == 1,
                  text.first?.isASCII == true, text.first?.isLetter == true else { return nil }
            return text.lowercased()
        }
    }

    struct HitTarget {
        let key: Key
        let frame: CGRect
    }

    struct TypingGeometry {
        let targets: [HitTarget]
        let bounds: CGRect
        /// An ordinary one-unit key (LatinIME's "most common key"), so size-relative
        /// rules don't loosen on wide keys like Space.
        let typicalKeySize: CGSize

        init(targets: [HitTarget], bounds: CGRect) {
            self.targets = targets
            self.bounds = bounds
            let sizes = targets.filter { $0.key.isText && $0.key.weight == 1 }.map(\.frame.size)
            func median(_ values: [CGFloat]) -> CGFloat { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
            typicalKeySize = CGSize(width: median(sizes.map(\.width)), height: median(sizes.map(\.height)))
        }

        private func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - point.x, 0, point.x - rect.maxX),
                  max(rect.minY - point.y, 0, point.y - rect.maxY))
        }

        func hit(at point: CGPoint) -> Int? {
            guard point.x.isFinite, point.y.isFinite, bounds.contains(point) else { return nil }
            if let contained = targets.firstIndex(where: { $0.frame.contains(point) }) { return contained }
            // Recover unclaimed margins without enlarging action keys.
            return targets.indices.filter { targets[$0].key.isText && distance(point, to: targets[$0].frame) <= 17 }
                .min { distance(point, to: targets[$0].frame) < distance(point, to: targets[$1].frame) }
        }

        /// Fast drift onto another key is two merged taps; drift within one
        /// wide key such as Space is still a single press.
        func splitsMergedDrift(from origin: CGPoint, to point: CGPoint, elapsed: TimeInterval, selected: Int?) -> Bool {
            guard let destination = hit(at: point), destination != selected else { return false }
            return TerminalTouchKeyboardModel.isMergedDrift(from: origin, to: point, elapsed: elapsed, keySize: typicalKeySize)
        }

        func textHit(at point: CGPoint) -> Int? {
            guard let index = hit(at: point), targets[index].key.isText else { return nil }
            return index
        }

        func predictedHit(at point: CGPoint, prior: LetterPrior?) -> Int? {
            guard let geometric = hit(at: point), let prior, !prior.isEmpty,
                  let letter = targets[geometric].key.letter else { return hit(at: point) }
            let base = targets[geometric].frame
            guard base.contains(point) else { return geometric }
            // Anchored core: the prior never overrides a tap in the middle half of a key.
            guard !base.insetBy(dx: base.width * 0.25, dy: base.height * 0.25).contains(point) else { return geometric }
            let boundaryDistance = min(point.x - base.minX, base.maxX - point.x,
                                       point.y - base.minY, base.maxY - point.y)
            func spatial(_ rect: CGRect) -> Double {
                // Gaussian finger spread of about a third of a key, so a weak
                // prior only wins near the edge and a strong one reaches further.
                let x = (point.x - rect.midX) / max(1, rect.width * 0.35)
                let y = (point.y - rect.midY) / max(1, rect.height * 0.35)
                return Double(-0.5 * (x * x + y * y))
            }
            let baseScore = spatial(base)
            var best = geometric, bestScore = baseScore + 0.15
            for index in targets.indices where index != geometric {
                let candidate = targets[index]
                let isSpace = candidate.key.action == .text(" ")
                let next = isSpace ? " " : candidate.key.letter
                guard let next, base.insetBy(dx: -0.01, dy: -0.01).intersects(candidate.frame) else { continue }
                if isSpace {
                    // Space's width flattens its spatial cost; it still needs a near miss.
                    let allowance = min(10, base.height * 0.25)
                    guard boundaryDistance <= allowance, distance(point, to: candidate.frame) <= allowance else { continue }
                }
                let ratio = min(4, max(0.25, prior.weight(for: next) / prior.weight(for: letter)))
                guard ratio > 1 else { continue }
                let score = spatial(candidate.frame) + log(ratio)
                if score > bestScore { best = index; bestScore = score }
            }
            return best
        }
    }

    /// A contact keeps its selection until movement indicates a deliberate slide.
    struct TouchSelection {
        let initialPoint: CGPoint
        let modifiers: Int
        let prior: LetterPrior?
        private(set) var anchor: CGPoint
        private(set) var latestPoint: CGPoint
        private(set) var selected: Int?
        private(set) var dragged = false
        private(set) var consumed = false

        init(point: CGPoint, selected: Int, modifiers: Int, prior: LetterPrior? = nil) {
            initialPoint = point; anchor = point; latestPoint = point
            self.selected = selected; self.modifiers = modifiers
            self.prior = prior
        }

        @discardableResult
        mutating func move(to point: CGPoint, in geometry: TypingGeometry, dockedPad: Bool) -> Bool {
            guard !consumed else { return false }
            latestPoint = point
            let threshold: CGFloat = dockedPad ? (dragged ? 34 : 42) : (dragged ? 12 : 18)
            let displacement = max(abs(point.x - anchor.x), abs(point.y - anchor.y))
            // Fractional cell origins must not move an exact boundary below its threshold.
            guard displacement + 0.0001 >= threshold else { return false }
            // Leaving the typing area keeps the last key, as the system keyboard does,
            // but still counts as a slide so holds (accents, cursor) disarm.
            guard geometry.bounds.contains(point) else {
                anchor = point
                dragged = true
                return true
            }
            let next = geometry.textHit(at: point) == nil ? nil : geometry.predictedHit(at: point, prior: prior)
            if let next, next != selected, let selected {
                let old = geometry.targets[selected].frame
                // Finger roll drifts across rows more than columns, so a row
                // change needs the finger well past the old key's edge.
                guard !old.insetBy(dx: -0.1 * old.width, dy: -0.35 * old.height).contains(point) else { return false }
                let frame = geometry.targets[next].frame
                let interior = frame.insetBy(dx: min(10, frame.width * 0.25), dy: min(10, frame.height * 0.25))
                // Finger roll can travel far while barely entering another
                // cell. A slide must reach its interior before changing keys.
                guard interior.contains(point) else { return false }
            }
            anchor = point
            dragged = true
            selected = next
            return true
        }

        mutating func takeSelection() -> Int? {
            guard !consumed else { return nil }
            consumed = true
            return selected
        }

        mutating func finish(at point: CGPoint, in geometry: TypingGeometry, dockedPad: Bool,
                             cancelled: Bool = false) -> Int? {
            guard !cancelled else { cancel(); return nil }
            if geometry.bounds.contains(point) {
                // Releasing on an action key still cancels the letter.
                guard geometry.textHit(at: point) != nil else { cancel(); return nil }
                move(to: point, in: geometry, dockedPad: dockedPad)
            }
            return takeSelection()
        }

        mutating func cancel() { consumed = true; selected = nil }
    }

    struct PredictionSnapshot: Equatable {
        let prefix: String
        let revision: UInt64
    }

    /// Read-only typing context, with no authority to replace terminal text.
    struct PredictionContext {
        private(set) var text = ""
        private(set) var revision: UInt64 = 0

        var snapshot: PredictionSnapshot? {
            let token = String(text.reversed().prefix { !$0.isWhitespace }.reversed())
            guard (1...32).contains(token.count), token.allSatisfy({ $0.isASCII && $0.isLetter }),
                  token.dropFirst().allSatisfy({ $0.isLowercase }) else { return nil }
            return PredictionSnapshot(prefix: token.lowercased(), revision: revision)
        }

        mutating func append(_ value: String) {
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { reset(); return }
            text = String((text + value).suffix(128))
            revision &+= 1
        }

        mutating func backspace() {
            if !text.isEmpty { text.removeLast() }
            revision &+= 1
        }

        mutating func reset() { text = ""; revision &+= 1 }

        mutating func apply(_ mutation: TerminalCorrectionContext.Mutation, attributed: Bool) {
            switch mutation {
            case .text(let text, _) where attributed: append(text)
            case .backspace where attributed: backspace()
            default: reset()
            }
        }
    }

    struct LetterPrior {
        private var weights: [String: Double] = [:]
        var isEmpty: Bool { weights.isEmpty }

        init(prefix: String, completions: [String], isCompleteWord: Bool = false) {
            if isCompleteWord { weights[" "] = 1 }
            var seen = Set<String>()
            let matching = completions.map { $0.lowercased() }.filter {
                $0.hasPrefix(prefix) && $0.count > prefix.count && $0.allSatisfy { $0.isASCII && $0.isLetter }
                    && seen.insert($0).inserted
            }.prefix(32)
            for (rank, word) in matching.enumerated() {
                let letter = String(word[word.index(word.startIndex, offsetBy: prefix.count)])
                weights[letter, default: 0] += 1 / Double(rank + 1)
            }
        }

        func weight(for letter: String) -> Double { 0.1 + (weights[letter] ?? 0) }
    }

    struct PredictionCache {
        private var values: [String: LetterPrior] = [:]
        private var order: [String] = []

        subscript(prefix: String) -> LetterPrior? { values[prefix] }

        mutating func prior(for prefix: String, load: () -> LetterPrior) -> LetterPrior {
            if let cached = values[prefix] { return cached }
            let prior = load()
            values[prefix] = prior
            order.append(prefix)
            if order.count > 128 { values.removeValue(forKey: order.removeFirst()) }
            return prior
        }

        mutating func removeAll() { values.removeAll(); order.removeAll() }
    }

    enum ToolPage: Int, CaseIterable {
        case typing, dictation, symbols, navigation, shortcuts

        var title: String {
            switch self {
            case .typing: return String(localized: "Keyboard")
            case .dictation: return String(localized: "Dictation")
            case .symbols: return String(localized: "Symbols")
            case .navigation: return String(localized: "Navigation")
            case .shortcuts: return String(localized: "Shortcuts")
            }
        }

        /// Pages in swipe order; Dictation only when the feature is available and on.
        static func pages(dictation: Bool) -> [Self] {
            dictation ? allCases : allCases.filter { $0 != .dictation }
        }

        func moved(by offset: Int, in pages: [Self] = Self.allCases) -> Self {
            guard let index = pages.firstIndex(of: self) else { return .typing }
            let count = pages.count
            return pages[(index + offset % count + count) % count]
        }
    }

    /// A deliberate horizontal stroke changes pages; ordinary key correction
    /// and vertical scrolling do not. The view excludes contacts owned by holds.
    static func pageSwipe(translation: CGPoint, duration: TimeInterval) -> Int? {
        guard abs(translation.x) >= 70, abs(translation.x) > abs(translation.y) * 2,
              abs(translation.x) >= 300 * max(0, duration) else { return nil }
        return translation.x < 0 ? 1 : -1
    }

    /// The vertical counterpart of `pageSwipe`: down shrinks (+1), up grows (-1).
    static func heightSwipe(translation: CGPoint, duration: TimeInterval) -> Int? {
        pageSwipe(translation: CGPoint(x: translation.y, y: translation.x), duration: duration).map { -$0 }
    }

    /// The arrow a joystick drag points at; nil inside the dead zone.
    static func joystickArrow(dx: Double, dy: Double) -> String? {
        guard hypot(dx, dy) >= 18 else { return nil }
        return abs(dx) > abs(dy) ? (dx > 0 ? "\u{1b}[C" : "\u{1b}[D") : (dy > 0 ? "\u{1b}[B" : "\u{1b}[A")
    }

    /// A letter this recent means the user is mid-word (LatinIME's 350ms).
    /// Merged-touch splitting and page swipes both use it, so no touch can be both.
    static let typingBurst: TimeInterval = 0.35
    /// How long a fast-typing touch can still turn out to be two merged taps.
    static let mergeWindow: TimeInterval = 0.08

    /// A finger bouncing on release lands again almost at once, in the same place.
    static func isTouchBounce(down: CGPoint, at time: TimeInterval, lastUp: CGPoint, at upTime: TimeInterval) -> Bool {
        time - upTime < 0.04 && hypot(down.x - lastUp.x, down.y - lastUp.y) < 12.6
    }

    /// Mid-word, a toolbar key only fires on a deliberate hit away from its edges.
    static func isClearlyInside(_ point: CGPoint, _ frame: CGRect) -> Bool {
        frame.insetBy(dx: frame.width * 0.15, dy: frame.height * 0.15).contains(point)
    }

    /// Two taps can also merge over a few samples instead of one jump. A fast,
    /// mostly horizontal travel of half a key diagonal is not a finger roll.
    static func isMergedDrift(from origin: CGPoint, to point: CGPoint, elapsed: TimeInterval, keySize: CGSize) -> Bool {
        let dx = abs(point.x - origin.x), dy = abs(point.y - origin.y)
        let diagonal = hypot(keySize.width, keySize.height)
        return diagonal > 0 && elapsed <= mergeWindow && dx >= dy && hypot(dx, dy) >= 0.53 * diagonal
    }

    /// Taps land below key centres on the letter rows, so the boundaries under
    /// the first two rows move down by these fractions of a row (LatinIME
    /// touch-position-correction). Logged taps hit Space high, so its edge stays.
    static let rowBoundaryOffsets: [CGFloat] = [0.038, 0.088]

    static func touchCorrectedFrames(_ rows: [[CGRect]]) -> [[CGRect]] {
        func shift(below row: Int) -> CGFloat { rowBoundaryOffsets.indices.contains(row) ? rowBoundaryOffsets[row] : 0 }
        return rows.enumerated().map { index, row in
            row.map { frame in
                let top = shift(below: index - 1) * frame.height
                let bottom = shift(below: index) * frame.height
                return CGRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: frame.height - top + bottom)
            }
        }
    }

    /// Hit geometry for laid-out rows. `overhang` extends the top row upward.
    /// The row correction is phone data; LatinIME ships none for tablets.
    static func typingGeometry(keys: [[Key]], frames: [[CGRect]], minX: CGFloat, width: CGFloat,
                               overhang: CGFloat, touchCorrection: Bool) -> TypingGeometry {
        let top = frames.first?.first?.minY ?? 0
        let bottom = frames.last?.first?.maxY ?? top
        let hitFrames = touchCorrection ? touchCorrectedFrames(frames) : frames
        let targets = zip(keys.flatMap { $0 }, hitFrames.flatMap { $0 })
            .map { HitTarget(key: $0, frame: $1) }
        return TypingGeometry(targets: targets, bounds: CGRect(x: minX, y: top - overhang, width: width,
                                                              height: bottom - top + overhang))
    }

    /// One thumb lifting as another lands can arrive as a single touch that
    /// jumps. No finger covers this distance between two digitizer samples.
    static func isTouchJump(from previous: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - previous.x, point.y - previous.y) > 60
    }

    /// The top row also claims the bottom strip of the row above it:
    /// a stray letter costs less than a stray Esc or Ctrl.
    static let topRowOverhang: CGFloat = 6

    enum ToolbarDrawerState: Equatable {
        case closed, stacked(Int), cycling(Int)

        func toggled(rowCount: Int, cycle: Bool) -> Self {
            guard rowCount > 0 else { return .closed }
            switch self {
            case .closed: return cycle ? .cycling(0) : .stacked(1)
            case .stacked(let count): return !cycle && count < rowCount ? .stacked(count + 1) : .closed
            case .cycling(let index): return cycle && index + 1 < rowCount ? .cycling(index + 1) : .closed
            }
        }

        func clamped(rowCount: Int) -> Self {
            guard rowCount > 0 else { return .closed }
            switch self {
            case .closed: return .closed
            case .stacked(let count): return .stacked(min(count, rowCount))
            case .cycling(let index): return .cycling(min(index, rowCount - 1))
            }
        }

        func visibleRows(rowCount: Int) -> [Int] {
            guard rowCount > 0 else { return [] }
            switch self {
            case .closed: return []
            case .stacked(let count): return Array((0..<min(count, rowCount)).reversed())
            case .cycling(let index): return [min(index, rowCount - 1)]
            }
        }
    }

    /// Keep configured rows intact. Main-row overflow joins the first drawer,
    /// including a button displaced to keep the drawer toggle reachable.
    static func toolbarKeys(main: [Key], drawers: [[Key]], width: CGFloat,
                            drawerToggle: Key? = nil) -> (main: [Key], drawers: [[Key]]) {
        KeyboardToolbarOverflow.layout(main: main, drawers: drawers,
            capacity: max(1, Int(max(0, width - 10) / 40)),
            drawerToggle: drawerToggle ?? Key(title: "…", action: .drawer),
            keepsDrawerToggleVisible: drawerToggle != nil)
    }

    /// Contrast is computed in linear light, after decoding the sRGB channels.
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 1, green: 1, blue: 1)

        var luminance: Double {
            func linear(_ component: Double) -> Double {
                let value = min(1, max(0, component))
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrast(against other: RGB) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }

        func readableInk(preferred: RGB) -> RGB {
            if preferred.contrast(against: self) >= 4.5 { return preferred }
            return Self.white.contrast(against: self) > Self.black.contrast(against: self) ? .white : .black
        }
    }

    /// Paired neutral colors remain legible through keyboard-window trait changes.
    /// Both cap and ink must resolve from the same appearance, including Shift.
    static func keyColors(dark: Bool, character: Bool, pressed: Bool, selected: Bool) -> (background: Double, ink: Double) {
        if selected { return dark ? (0.96, 0.08) : (0.12, 1.0) }
        // Native dark keyboards use the same muted fill for letters and utilities.
        if dark { return (pressed ? 0.36 : 0.27, 1.0) }
        return (pressed ? 0.75 : (character ? 1.0 : 0.79), 0.08)
    }

    /// A detached card moves the Apple Keyboard key to its footer, as Apple's
    /// floating keyboard does with its globe, so the row matches Apple's widths.
    static func rows(page: Page, floating: Bool = false) -> [[Key]] {
        func text(_ string: String) -> [Key] { string.map { Key(title: String($0), action: .text(String($0))) } }
        let shift = Key(title: "Shift", action: .modifier(.shift), symbol: "shift", weight: 1.5)
        let delete = Key(title: "Delete", action: .key("\u{7f}"), symbol: "delete.left", weight: 1.5)
        let first: [Key]
        let second: [Key]
        let third: [Key]
        switch page {
        case .letters:
            first = text("qwertyuiop")
            second = text("asdfghjkl")
            third = [shift] + text("zxcvbnm") + [delete]
        case .numbers:
            first = text("1234567890")
            second = text("-/:;()$&@\"")
            third = [Key(title: "#+=", action: .page, weight: 1.5)] + text(".,?!'[]") + [delete]
        case .symbols:
            first = text("[]{}#%^*+=")
            second = text("_\\|~<>€£¥•")
            third = [Key(title: "123", action: .page, weight: 1.5)] + text(".,?!'`;") + [delete]
        }
        return [first, second, third, [
            Key(title: page == .letters ? "123" : "ABC", action: .page, weight: floating ? 2.5 : 1.25),
            Key(title: "Apple Keyboard", action: .switchKeyboard, symbol: "keyboard", weight: floating ? 0 : 1.15),
            Key(title: "space", action: .text(" "), weight: floating ? 5 : 5.8, accessibility: "Space. Hold and drag to move the terminal cursor."),
            Key(title: "return", action: .key("\r"), symbol: "return", weight: floating ? 2.5 : 1.8)
        ]]
    }

    /// Full cells are hit targets; the visual caps are inset inside them.
    static func frames(keys: [Key], width: Double, y: Double, height: Double, inset: Double = 0) -> [CGRect] {
        let unit = max(0, width - inset * 2) / max(1, keys.reduce(0) { $0 + $1.weight })
        var x = inset
        return keys.map { key in
            defer { x += unit * key.weight }
            return CGRect(x: x, y: y, width: unit * key.weight, height: height)
        }
    }

    /// UIKit can fix a docked keyboard's height (iPhone Duo's laptop pose).
    /// Rows grow to fill it up to a comfortable size; the remainder goes above
    /// the toolbar so the keys stay on the bottom edge.
    static func fixedHeightLayout(height: Double, chrome: Double, rowCount: Int) -> (rowHeight: Double, top: Double) {
        guard rowCount > 0 else { return (0, max(0, height - chrome)) }
        let rowHeight = min(80, max(30, (height - chrome) / Double(rowCount)))
        return (rowHeight, max(0, height - chrome - rowHeight * Double(rowCount)))
    }

    /// One typing row divided around the half-open Duo's vertical fold.
    struct SplitRow: Equatable {
        var left: [Key]
        var right: [Key]
    }

    struct SplitMetrics: Equatable {
        let unit: Double
        let halfWidth: Double
        let leftMinX: Double
        let rightMinX: Double
    }

    private static func weight(_ keys: [Key]) -> Double { keys.reduce(0) { $0 + $1.weight } }

    /// Mirrors the system's split keyboard: an odd run of text keys repeats its
    /// middle key in both halves (G, V), and Space appears in each half, widened
    /// to match the widest row.
    static func splitRows(_ rows: [[Key]]) -> [SplitRow] {
        let space = Action.text(" ")
        let split = rows.map { row -> SplitRow in
            if let index = row.firstIndex(where: { $0.action == space }) {
                return SplitRow(left: Array(row[...index]), right: Array(row[index...]))
            }
            let leading = Array(row.prefix { !$0.isText })
            let rest = row.dropFirst(leading.count)
            let trailing = Array(rest.reversed().prefix { !$0.isText }.reversed())
            let text = Array(rest.dropLast(trailing.count))
            let half = text.count / 2
            let left = text.count.isMultiple(of: 2) ? text[..<half] : text[...half]
            return SplitRow(left: leading + left, right: Array(text[half...]) + trailing)
        }
        let widest = split.filter { !$0.left.contains { $0.action == space } }
            .flatMap { [weight($0.left), weight($0.right)] }.max() ?? 0
        func widened(_ keys: [Key]) -> [Key] {
            guard let index = keys.firstIndex(where: { $0.action == space }) else { return keys }
            var keys = keys
            keys[index].weight = max(2, widest - (weight(keys) - keys[index].weight))
            return keys
        }
        return split.map { SplitRow(left: widened($0.left), right: widened($0.right)) }
    }

    static let splitEdgeInset = 2.0
    static let splitFoldClearance = 12.0

    /// As the system keyboard does, each half is centered in its side of the
    /// fold, with one key unit capped near the system's size. nil when either
    /// side is too narrow for usable keys.
    static func splitMetrics(_ rows: [SplitRow], width: Double, fold: ClosedRange<Double>) -> SplitMetrics? {
        let widest = rows.flatMap { [weight($0.left), weight($0.right)] }.max() ?? 0
        let leftMax = fold.lowerBound - splitFoldClearance
        let rightMin = fold.upperBound + splitFoldClearance
        let side = min(leftMax - splitEdgeInset, width - splitEdgeInset - rightMin)
        guard widest > 0, side / widest >= 30 else { return nil }
        let unit = min(56, side / widest)
        let half = unit * widest
        return SplitMetrics(unit: unit, halfWidth: half, leftMinX: (splitEdgeInset + leftMax - half) / 2,
                            rightMinX: (rightMin + width - splitEdgeInset - half) / 2)
    }

    /// A row narrower than its half sits against the outer edge, or with
    /// `towardFold` against the fold, giving the system's half-key stagger.
    /// `outerInset` keeps the bottom row clear of the rounded screen corners.
    static func splitFrames(_ row: SplitRow, metrics: SplitMetrics, width: Double, y: Double,
                            height: Double, towardFold: Bool = false, outerInset: Double = 0) -> [CGRect] {
        let edge = splitEdgeInset + outerInset
        let leftMinX = max(metrics.leftMinX, edge)
        let rightMaxX = min(metrics.rightMinX + metrics.halfWidth, width - edge)
        func place(_ keys: [Key], minX: Double, maxX: Double, outerIsMin: Bool) -> [CGRect] {
            let span = max(0, maxX - minX)
            let used = min(span, metrics.unit * weight(keys))
            let start = outerIsMin != towardFold ? minX : maxX - used
            return frames(keys: keys, width: used, y: y, height: height).map { $0.offsetBy(dx: start, dy: 0) }
        }
        return place(row.left, minX: leftMinX, maxX: metrics.leftMinX + metrics.halfWidth, outerIsMin: true)
            + place(row.right, minX: metrics.rightMinX, maxX: rightMaxX, outerIsMin: false)
    }

    /// Equal columns on both sides of the fold, each block hugging its outer edge.
    struct SplitColumns: Equatable {
        let unit: Double
        let leftCount: Int
        let rightStart: Double

        var leftEnd: Double { Double(leftCount) * unit }

        func x(column: Int) -> Double {
            column < leftCount ? Double(column) * unit : rightStart + Double(column - leftCount) * unit
        }

        /// Sequential origins; anything that would reach the fold moves to the right-hand block.
        func positions(widths: [Double]) -> [Double] {
            var x = 0.0
            return widths.map { width in
                if x < rightStart, x + width > leftEnd + 0.001 { x = rightStart }
                defer { x += width }
                return x
            }
        }
    }

    /// Columns for `count` slots across `width`, shared out in proportion to
    /// the room on each side of `fold` (same coordinates as `width`).
    static func splitColumns(count: Int, width: Double, fold: ClosedRange<Double>) -> SplitColumns? {
        let left = fold.lowerBound - splitFoldClearance
        let right = width - fold.upperBound - splitFoldClearance
        guard count > 0, left > 0, right > 0 else { return nil }
        let leftCount = count == 1 ? 1 : min(count - 1, max(1, Int((Double(count) * left / (left + right)).rounded())))
        let rightCount = count - leftCount
        let unit = rightCount == 0 ? left / Double(leftCount) : min(left / Double(leftCount), right / Double(rightCount))
        return SplitColumns(unit: unit, leftCount: leftCount, rightStart: width - Double(rightCount) * unit)
    }

    /// The width a split row loses to the fold and its clearance.
    static func splitFoldBlock(_ fold: ClosedRange<Double>) -> Double {
        fold.upperBound - fold.lowerBound + splitFoldClearance * 2
    }

    enum Placement: Equatable { case docked, floating }

    static func placementAfterPinch(_ scale: CGFloat, from placement: Placement) -> Placement {
        guard scale.isFinite else { return placement }
        switch placement {
        case .docked: return scale < 0.78 ? .floating : .docked
        case .floating: return scale > 1.22 ? .docked : .floating
        }
    }

    /// The anchor describes the available travel, not the screen coordinates,
    /// so a floating keyboard remains reachable after rotation/window resizing.
    static func floatingFrame(in available: CGRect, height: CGFloat, anchor: CGPoint) -> CGRect {
        let size = CGSize(width: min(320, max(0, available.width)), height: min(max(0, height), max(0, available.height)))
        let x = min(1, max(0, anchor.x.isFinite ? anchor.x : 1))
        let y = min(1, max(0, anchor.y.isFinite ? anchor.y : 1))
        return CGRect(x: available.minX + (available.width - size.width) * x,
                      y: available.minY + (available.height - size.height) * y, width: size.width, height: size.height)
    }

    /// Moves a floating card off the Duo's fold, to the side holding most of it
    /// when the card fits there. All rects share coordinates.
    static func floatingFrame(_ frame: CGRect, avoiding fold: CGRect?, in available: CGRect) -> CGRect {
        guard let fold, frame.intersects(fold) else { return frame }
        var moved = frame
        if fold.height > fold.width {
            let fitsBefore = fold.minX - available.minX >= frame.width, fitsAfter = available.maxX - fold.maxX >= frame.width
            if fitsBefore && (frame.midX < fold.midX || !fitsAfter) { moved.origin.x = fold.minX - frame.width }
            else if fitsAfter { moved.origin.x = fold.maxX }
        } else {
            let fitsBefore = fold.minY - available.minY >= frame.height, fitsAfter = available.maxY - fold.maxY >= frame.height
            if fitsBefore && (frame.midY < fold.midY || !fitsAfter) { moved.origin.y = fold.minY - frame.height }
            else if fitsAfter { moved.origin.y = fold.maxY }
        }
        return moved
    }

    static func floatingAnchor(for frame: CGRect, in available: CGRect) -> CGPoint {
        let travelX = available.width - frame.width, travelY = available.height - frame.height
        return CGPoint(x: travelX > 0 ? min(1, max(0, (frame.minX - available.minX) / travelX)) : 0.5,
                       y: travelY > 0 ? min(1, max(0, (frame.minY - available.minY) / travelY)) : 0.5)
    }

    /// Detect an existing native floating input region.
    static func isFloatingInput(width: CGFloat, hostWidth: CGFloat, isPad: Bool) -> Bool {
        isPad && width > 0 && width <= 400 && width < hostWidth - 1
    }

    struct Shortcut {
        let title: String
        let key: String
        var modifiers: Int = 0
        var chord: String {
            (modifiers & 1 != 0 ? "⌃" : "") + (modifiers & 2 != 0 ? "⌥" : "")
                + (modifiers & 8 != 0 ? "⇧" : "")
                + (["\u{1b}": "Esc", "\t": "Tab", "\r": "Return"][key] ?? key)
        }
    }

    enum Preset: String, CaseIterable {
        case shell = "Shell", vim = "Vim", emacs = "Emacs", nano = "Nano", agent = "Agent"

        /// Insert literal text so commands can take arguments before Return.
        /// Availability depends on the coding agent running in the terminal.
        var slashCommands: [String] {
            guard self == .agent else { return [] }
            return ["/model", "/copy", "/help", "/clear", "/compact", "/resume",
                    "/status", "/diff", "/review", "/plan", "/init", "/exit"]
        }

        var shortcuts: [Shortcut] {
            func ctrl(_ title: String, _ key: String) -> Shortcut { Shortcut(title: title, key: key, modifiers: 1) }
            switch self {
            case .shell:
                return [ctrl("Interrupt", "c"), ctrl("EOF", "d"), ctrl("Clear", "l"), ctrl("History", "r"),
                        ctrl("Line start", "a"), ctrl("Line end", "e"), ctrl("Delete word", "w")]
            case .vim:
                return [Shortcut(title: "Normal mode", key: "\u{1b}"), Shortcut(title: "Command", key: ":"),
                        Shortcut(title: "Search", key: "/"), Shortcut(title: "Next match", key: "n"),
                        Shortcut(title: "Previous match", key: "N"), Shortcut(title: "Undo", key: "u"),
                        ctrl("Redo", "r"), ctrl("Half page down", "d"), ctrl("Half page up", "u")]
            case .emacs:
                return [ctrl("Cancel", "g"), ctrl("Prefix", "x"), Shortcut(title: "Command", key: "x", modifiers: 2),
                        ctrl("Search", "s"), ctrl("Line start", "a"), ctrl("Line end", "e"), ctrl("Kill line", "k"), ctrl("Yank", "y")]
            case .nano:
                return [ctrl("Write out", "o"), ctrl("Exit", "x"), ctrl("Search", "w"),
                        ctrl("Cut", "k"), ctrl("Uncut", "u"), ctrl("Help", "g")]
            case .agent:
                return [Shortcut(title: "Escape", key: "\u{1b}"), ctrl("Interrupt", "c"),
                        Shortcut(title: "Tab", key: "\t"), Shortcut(title: "Backtab", key: "\t", modifiers: 8),
                        Shortcut(title: "Shift-Return", key: "\r", modifiers: 8)]
            }
        }
    }

    static let accents: [String: String] = [
        "a": "àáâäæãåā", "e": "èéêëēėę", "i": "ìíîïīį", "o": "òóôöõøœō",
        "u": "ùúûüū", "c": "çćč", "n": "ñń", "s": "ßśš", "y": "ÿý", "z": "žźż"
    ]

    struct SuggestionContext: Equatable, Sendable {
        let document: String
        let generation: UInt64
        let documentGeneration: UInt64
        let range: NSRange
        var word: String { (document as NSString).substring(with: range) }

        init?(document: String, eligibleCount: Int, generation: UInt64, documentGeneration: UInt64) {
            let suffix = document.reversed().prefix { $0.isASCII && $0.isLetter }.reversed()
            let word = String(suffix)
            guard word.count >= 2, word.count <= 32, word.utf16.count <= eligibleCount else { return nil }
            let prefix = document.dropLast(word.count)
            // Never guess inside a path, identifier, flag, or shell expansion.
            guard prefix.isEmpty || prefix.last?.isWhitespace == true else { return nil }
            self.document = document
            self.generation = generation
            self.documentGeneration = documentGeneration
            self.range = NSRange(location: document.utf16.count - word.utf16.count, length: word.utf16.count)
        }
    }
}
