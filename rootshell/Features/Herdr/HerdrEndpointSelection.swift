// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

/// Inclusive buffer coordinates, matching vanilla pane.selection.read.
/// Scrolling changes the projection, never the fixed anchor.
nonisolated struct HerdrEndpointSelection: Equatable {
    struct Point: Equatable, Comparable {
        var row: UInt64
        var column: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
        }
        var json: [String: Any] { ["row": row, "col": column] }
    }
    var anchor: Point
    var cursor: Point
    var dragging = true
    var visible = false
    var ordered: (Point, Point) { anchor <= cursor ? (anchor, cursor) : (cursor, anchor) }

    mutating func move(to point: Point) {
        if point != anchor { visible = true }
        cursor = point
    }

    func contains(row: UInt64, column: Int) -> Bool {
        guard visible else { return false }
        let point = Point(row: row, column: column)
        let (start, end) = ordered
        return point >= start && point <= end
    }

    static func point(row: Int, column: Int, pane: HerdrEndpointSurface.Pane) -> Point {
        let top = pane.scroll?.top ?? 0
        return Point(row: min(UInt64(UInt32.max), top + UInt64(max(0, min(row, pane.inner.height - 1)))),
                     column: max(0, min(column, pane.inner.width - 1)))
    }

    /// A width change reflows absolute rows; a screen transition changes the
    /// buffer entirely. Ordinary output revisions do neither.
    static func survives(from old: HerdrEndpointSurface.Pane, to new: HerdrEndpointSurface.Pane) -> Bool {
        old.id == new.id && old.inner.width == new.inner.width && old.inner.height == new.inner.height
            && old.alternateScreen == new.alternateScreen
            && (new.scroll?.max_offset_from_bottom ?? 0) >= (old.scroll?.max_offset_from_bottom ?? 0)
    }
}

/// Retains the last painted cells so selection changes and sparse remote
/// patches only redraw affected rows. Ghostty renders these cells; its local
/// alternate-screen selection and scrollback are deliberately not the model.
nonisolated struct HerdrEndpointPainter {
    typealias Surface = HerdrEndpointSurface
    private var previous: [Surface.Cell] = []
    private var links: [String] = []
    private var width = 0
    private var height = 0
    private var cursor: Surface.Cursor?
    private var mouse = false
    private var initialized = false
    /// Ghostty redrew its own screen for a new surface size, so the retained
    /// cells no longer describe what is on screen.
    private var stale = false
    private var placements: [Surface.Placement] = []
    private var imageIDs: [Surface.AssetKey: UInt32] = [:]
    private var nextImageID: UInt32 = 1

    mutating func reset() { self = Self() }

    mutating func noteSurfaceGridChanged() { stale = true }

    mutating func render(frame: Surface.Frame, pane: Surface.Pane, selection: HerdrEndpointSelection?,
                         selectionColors: (foreground: UInt32, background: UInt32)?) -> Data? {
        let rect = pane.inner
        let popupX = max(0, (frame.grid.width - (frame.popup?.grid.width ?? 0)) / 2)
        let popupY = max(0, (frame.grid.height - (frame.popup?.grid.height ?? 0)) / 2)
        let hyperlinks = frame.grid.hyperlinks + (frame.popup?.grid.hyperlinks ?? [])
        var cells: [Surface.Cell] = []
        cells.reserveCapacity(rect.width * rect.height)
        for row in 0..<rect.height {
            let index = (rect.y + row) * frame.grid.width + rect.x
            for column in 0..<rect.width {
                var cell = frame.grid.cells[index + column]
                if let popup = frame.popup {
                    let x = rect.x + column - popupX, y = rect.y + row - popupY
                    if x >= 0, x < popup.grid.width, y >= 0, y < popup.grid.height {
                        cell = popup.grid.cells[y * popup.grid.width + x]
                        if let link = cell.hyperlink { cell.hyperlink = link + UInt32(frame.grid.hyperlinks.count) }
                    }
                }
                if selection?.contains(row: (pane.scroll?.top ?? 0) + UInt64(row), column: column) == true {
                    if let colors = selectionColors {
                        cell.foreground = colors.foreground; cell.background = colors.background
                        cell.modifiers &= ~64
                    } else { cell.modifiers ^= 64 }
                }
                cells.append(cell)
            }
        }
        var nextCursor = frame.grid.cursor
        if let popup = frame.popup {
            nextCursor = popup.grid.cursor
            nextCursor?.x += popupX; nextCursor?.y += popupY
        }
        if let value = nextCursor {
            if value.x >= rect.x, value.x < rect.x + rect.width, value.y >= rect.y, value.y < rect.y + rect.height {
                nextCursor?.x -= rect.x; nextCursor?.y -= rect.y
            } else { nextCursor = nil }
        }
        let nextPlacements = frame.scene.placements.compactMap { placement -> Surface.Placement? in
            if selection?.visible == true { return nil }
            if !placement.asset.popup { return placement.asset.pane == pane.id ? placement : nil }
            guard frame.popup?.id == placement.asset.pane else { return nil }
            var translated = placement
            translated.x += popupX; translated.y += popupY
            return translated.x >= rect.x && translated.x < rect.x + rect.width
                && translated.y >= rect.y && translated.y < rect.y + rect.height ? translated : nil
        }
        let capturesMouse = frame.popup?.mouseReporting ?? pane.mouseReporting
        let full = !initialized || stale || width != rect.width || height != rect.height
            || cells.count != previous.count || links != hyperlinks
        let changed = full || previous != cells || cursor != nextCursor || mouse != capturesMouse || placements != nextPlacements
        guard changed else { return nil }
        var out = (initialized ? "" : "\u{18}") + "\u{1b}[?2026h\u{1b}[?25l"
        if !initialized {
            out += "\u{1b}[?1049h\u{1b}[?6l\u{1b}[r\u{1b}[?7l\u{1b}[4l\u{1b}(B\u{0f}\u{1b}_Ga=d,d=A,q=2\u{1b}\\"
        }
        if full { out += "\u{1b}[0m\u{1b}[2J" }
        if !initialized || mouse != capturesMouse {
            out += capturesMouse ? "\u{1b}[?1002h\u{1b}[?1006h" : "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l"
        }
        var pen: Surface.Cell?
        var link: UInt32?
        for row in 0..<rect.height {
            let range = (row * rect.width)..<((row + 1) * rect.width)
            if !full, previous[range].elementsEqual(cells[range]) { continue }
            var nextColumn: Int?
            for column in 0..<rect.width {
                let index = row * rect.width + column
                let cell = cells[index]
                if cell.skip { continue }
                if !full, cell == previous[index] { continue }
                if nextColumn != column { out += "\u{1b}[\(row + 1);\(column + 1)H" }
                if pen?.foreground != cell.foreground || pen?.background != cell.background || pen?.modifiers != cell.modifiers {
                    out += Self.style(cell)
                    pen = cell
                }
                if cell.hyperlink != link {
                    link = cell.hyperlink
                    let target = link.flatMap { Int($0) < hyperlinks.count ? hyperlinks[Int($0)] : nil } ?? ""
                    out += "\u{1b}]8;;\(Self.safeText(target))\u{1b}\\"
                }
                let symbol = Self.safeText(cell.symbol)
                out += symbol.isEmpty ? " " : symbol
                // Consecutive ASCII cells advance the cursor predictably.
                // Position explicitly after Unicode instead of guessing its
                // display width (wide cells, combining marks, and emoji).
                nextColumn = symbol.isEmpty || Self.isPrintableASCII(symbol) ? column + 1 : nil
            }
        }
        out += "\u{1b}]8;;\u{1b}\\\u{1b}[0m"
        if full || placements != nextPlacements {
            // Every desired scene is complete. Delete old placements, retain
            // image data, then place the current clipped scene in pane space.
            out += "\u{1b}_Ga=d,d=a,q=2\u{1b}\\"
            for placement in nextPlacements {
                if imageIDs[placement.asset] == nil, let data = frame.scene.assets[placement.asset] {
                    let id = nextImageID; nextImageID &+= 1
                    imageIDs[placement.asset] = id
                    let encoded = data.base64EncodedString()
                    let format = [24, 32, 100][Int(placement.asset.format)]
                    var index = encoded.startIndex
                    var first = true
                    while index < encoded.endIndex {
                        let end = encoded.index(index, offsetBy: 4096, limitedBy: encoded.endIndex) ?? encoded.endIndex
                        let more = end < encoded.endIndex ? 1 : 0
                        let header = first ? "a=t,t=d,f=\(format),s=\(placement.asset.width),v=\(placement.asset.height),i=\(id),q=2,m=\(more)" : "m=\(more)"
                        out += "\u{1b}_G\(header);\(encoded[index..<end])\u{1b}\\"
                        first = false; index = end
                    }
                }
                guard let id = imageIDs[placement.asset] else { continue }
                let x = placement.x - rect.x, y = placement.y - rect.y
                guard x >= 0, y >= 0, x < rect.width, y < rect.height else { continue }
                out += "\u{1b}[\(y + 1);\(x + 1)H"
                out += "\u{1b}_Ga=p,i=\(id),p=\(placement.id),q=2,C=1,c=\(placement.cols),r=\(placement.rows),x=\(placement.sourceX),y=\(placement.sourceY),w=\(placement.sourceWidth),h=\(placement.sourceHeight),X=\(placement.offsetX),Y=\(placement.offsetY),z=\(placement.z)\u{1b}\\"
            }
            let live = Set(nextPlacements.map(\.asset))
            for (key, id) in imageIDs where !live.contains(key) {
                out += "\u{1b}_Ga=d,d=I,i=\(id),q=2\u{1b}\\"
                imageIDs.removeValue(forKey: key)
            }
        }
        if let nextCursor, nextCursor.visible {
            out += "\u{1b}[\(nextCursor.y + 1);\(nextCursor.x + 1)H\u{1b}[\(min(nextCursor.shape, 6)) q\u{1b}[?25h"
        }
        out += "\u{1b}[?2026l"
        previous = cells; width = rect.width; height = rect.height; links = hyperlinks; stale = false
        cursor = nextCursor; mouse = capturesMouse; placements = nextPlacements; initialized = true
        return Data(out.utf8)
    }

    private static func safeText(_ text: String) -> String {
        if isPrintableASCII(text) { return text }
        // Preserve Unicode format scalars such as emoji's zero-width joiner.
        // Only C0/C1 can introduce terminal control sequences here.
        return String(text.unicodeScalars.filter { $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value) })
    }

    private static func isPrintableASCII(_ text: String) -> Bool {
        text.utf8.count == 1 && text.utf8.first.map { (0x20...0x7e).contains($0) } == true
    }

    private static func color(_ value: UInt32, background: Bool) -> String {
        let base = background ? 48 : 38
        switch value >> 24 {
        case 1: return "\(base);5;\(value & 255)"
        case 2: return "\(base);2;\((value >> 16) & 255);\((value >> 8) & 255);\(value & 255)"
        default:
            let name = Int(value & 255)
            if name == 0 || name > 16 { return background ? "49" : "39" }
            return String((background ? 40 : 30) + (name - 1) % 8 + (name > 8 ? 60 : 0))
        }
    }

    private static func style(_ cell: Surface.Cell) -> String {
        var codes = ["0", color(cell.foreground, background: false), color(cell.background, background: true)]
        for (mask, code) in [(1,"1"),(2,"2"),(4,"3"),(16,"5"),(32,"6"),(64,"7"),(128,"8"),(256,"9")] {
            if cell.modifiers & mask != 0 { codes.append(code) }
        }
        let underline = (cell.modifiers >> 12) & 15
        if underline > 0 { codes.append("4:\(min(underline, 5))") }
        else if cell.modifiers & 8 != 0 { codes.append("4") }
        return "\u{1b}[\(codes.joined(separator: ";"))m"
    }
}
