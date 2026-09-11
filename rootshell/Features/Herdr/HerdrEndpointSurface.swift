// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

nonisolated enum HerdrEndpointSurface {
    typealias Reader = HerdrEndpointWire.Reader
    typealias Failure = HerdrEndpointWire.Failure

    struct Rect: Equatable, Sendable {
        var x: Int, y: Int, width: Int, height: Int
        init(_ reader: inout Reader) throws {
            x = try reader.u16(); y = try reader.u16()
            width = try reader.u16(); height = try reader.u16()
        }
        init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        func fits(width: Int, height: Int) -> Bool {
            x >= 0 && y >= 0 && self.width > 0 && self.height > 0
                && x + self.width <= width && y + self.height <= height
        }
    }

    struct Scroll: Equatable, Decodable, Sendable {
        var offset_from_bottom: UInt64
        var max_offset_from_bottom: UInt64
        var viewport_rows: UInt64
        var top: UInt64 { max_offset_from_bottom - min(offset_from_bottom, max_offset_from_bottom) }
        var total: UInt64? {
            let (value, overflow) = max_offset_from_bottom.addingReportingOverflow(viewport_rows)
            return overflow ? nil : value
        }
        static func read(_ reader: inout Reader) throws -> Self {
            let result = try Self(offset_from_bottom: reader.uint(), max_offset_from_bottom: reader.uint(), viewport_rows: reader.uint())
            guard result.total != nil, result.offset_from_bottom <= result.max_offset_from_bottom else {
                throw Failure.invalid("invalid scroll metrics")
            }
            return result
        }
    }

    struct Cell: Equatable, Sendable {
        var symbol: String
        var foreground: UInt32, background: UInt32
        var modifiers: Int
        var skip: Bool
        var hyperlink: UInt32?
        static func read(_ r: inout Reader) throws -> Self {
            try Self(symbol: r.string(), foreground: r.u32(), background: r.u32(),
                     modifiers: r.u16(), skip: r.bool(), hyperlink: r.optional { try $0.u32() })
        }
    }

    struct Cursor: Equatable, Sendable {
        var x: Int, y: Int
        var visible: Bool
        var shape: UInt8
        static func read(_ r: inout Reader) throws -> Self {
            try Self(x: r.u16(), y: r.u16(), visible: r.bool(), shape: r.byte())
        }
    }

    struct Grid: Sendable {
        var cells: [Cell]
        var width: Int, height: Int
        var cursor: Cursor?
        var hyperlinks: [String]
        var graphics: Data
        static func read(_ r: inout Reader) throws -> Self {
            let cells = try r.array(Cell.read)
            let width = try r.u16(), height = try r.u16()
            guard width > 0, height > 0, width * height == cells.count else {
                throw Failure.invalid("invalid surface grid")
            }
            return try Self(cells: cells, width: width, height: height,
                            cursor: r.optional(Cursor.read), hyperlinks: r.array { try $0.string() }, graphics: r.bytes())
        }
    }

    struct Pane: Equatable, Sendable {
        var id: String
        var contentRevision: UInt64
        var rect: Rect, inner: Rect
        var scrollbar: Rect?
        var scroll: Scroll?
        var focused: Bool, mouseReporting: Bool, pixelMouse: Bool, alternateScreen: Bool
        var pixelWidth: UInt32, pixelHeight: UInt32
        static func read(_ r: inout Reader) throws -> Self {
            try Self(id: r.string(), contentRevision: r.uint(), rect: Rect(&r), inner: Rect(&r),
                     scrollbar: r.optional { try Rect(&$0) }, scroll: r.optional(Scroll.read),
                     focused: r.bool(), mouseReporting: r.bool(), pixelMouse: r.bool(), alternateScreen: r.bool(),
                     pixelWidth: r.u32(), pixelHeight: r.u32())
        }
    }

    struct Split: Sendable {
        var direction: Int, position: Int
        var area: Rect, hit: Rect
        var path: [Bool]
        static func read(_ r: inout Reader) throws -> Self {
            try Self(direction: Int(r.uint(max: 1)), position: r.u16(), area: Rect(&r), hit: Rect(&r), path: r.array { try $0.bool() })
        }
    }

    struct Popup: Sendable {
        var id: String, title: String
        var grid: Grid
        var mouseReporting: Bool, pixelMouse: Bool
        var pixelWidth: UInt32, pixelHeight: UInt32
        static func read(_ r: inout Reader) throws -> Self {
            let id = try r.string(), title = try r.string()
            for _ in 0..<2 {
                _ = try r.optional { reader in
                    _ = try reader.uint(max: 1)
                    return try reader.u16()
                }
            }
            return try Self(id: id, title: title, grid: Grid.read(&r), mouseReporting: r.bool(),
                            pixelMouse: r.bool(), pixelWidth: r.u32(), pixelHeight: r.u32())
        }
    }

    struct AssetKey: Hashable, Sendable {
        var pane: String, popup: Bool
        var image: UInt32?, layer: String?
        var width: UInt32, height: UInt32, format: UInt64, length: UInt64, fingerprint: UInt64
        static func read(_ r: inout Reader) throws -> Self {
            let source = try r.uint(max: 1)
            let target = source == 0 ? try r.uint(max: 1) : 0
            let pane = try r.string()
            let image = source == 0 ? try r.u32() : nil
            let layer = source == 1 ? try r.string() : nil
            return try Self(pane: pane, popup: target == 1, image: image, layer: layer,
                            width: r.u32(), height: r.u32(), format: r.uint(max: 2), length: r.uint(), fingerprint: r.uint())
        }
    }

    struct Placement: Equatable, Sendable {
        var asset: AssetKey
        var id: UInt32
        var x: Int, y: Int
        var cols: UInt32, rows: UInt32
        var sourceX: UInt32, sourceY: UInt32, sourceWidth: UInt32, sourceHeight: UInt32
        var offsetX: UInt32, offsetY: UInt32
        var z: Int32
        var scrollbackOffset: UInt32
        static func read(_ r: inout Reader) throws -> Self {
            try Self(asset: AssetKey.read(&r), id: r.u32(), x: r.u16(), y: r.u16(), cols: r.u32(), rows: r.u32(),
                     sourceX: r.u32(), sourceY: r.u32(), sourceWidth: r.u32(), sourceHeight: r.u32(),
                     offsetX: r.u32(), offsetY: r.u32(), z: r.i32(), scrollbackOffset: r.u32())
        }
    }

    struct Scene: Sendable {
        var assets: [AssetKey: Data]
        var placements: [Placement]
        var retained: [AssetKey]
        static func read(_ r: inout Reader) throws -> Self {
            let assets = try r.array { reader -> (AssetKey, Data) in
                let key = try AssetKey.read(&reader), bytes = try reader.bytes()
                guard key.length == bytes.count else { throw Failure.invalid("invalid image length") }
                return (key, bytes)
            }
            return try Self(assets: Dictionary(assets, uniquingKeysWith: { _, new in new }),
                            placements: r.array(Placement.read), retained: r.array(AssetKey.read))
        }
    }

    struct Frame: Sendable {
        var boot: String
        var projection: UInt64, revision: UInt64
        var grid: Grid
        var panes: [Pane]
        var splits: [Split]
        var popup: Popup?
        var scene: Scene
        static func read(_ r: inout Reader) throws -> Self {
            let frame = try Self(boot: r.string(), projection: r.uint(), revision: r.uint(),
                                 grid: Grid.read(&r), panes: r.array(Pane.read), splits: r.array(Split.read),
                                 popup: r.optional(Popup.read), scene: Scene.read(&r))
            try frame.validate()
            return frame
        }
        func validate() throws {
            guard Set(panes.map(\.id)).count == panes.count,
                  panes.allSatisfy({ $0.inner.fits(width: grid.width, height: grid.height) }) else {
                throw Failure.invalid("invalid pane rectangles")
            }
        }
        mutating func apply(_ patch: Patch) throws {
            guard boot == patch.boot, projection == patch.projection,
                  revision == patch.base, patch.revision > revision else {
                throw Failure.invalid("surface patch lost its base")
            }
            for row in patch.rows {
                guard row.y >= 0, row.y < grid.height, row.x >= 0, row.x <= grid.width, row.cells.count <= grid.width - row.x else {
                    throw Failure.invalid("patch outside surface")
                }
            }
            for pane in patch.panes {
                guard let old = panes.first(where: { $0.id == pane.id }), old.inner == pane.inner else {
                    throw Failure.invalid("patch changed pane geometry")
                }
            }
            for row in patch.rows {
                let start = row.y * grid.width + row.x
                grid.cells.replaceSubrange(start..<(start + row.cells.count), with: row.cells)
            }
            for pane in patch.panes {
                if let index = panes.firstIndex(where: { $0.id == pane.id }) { panes[index] = pane }
            }
            grid.cursor = patch.cursor
            revision = patch.revision
        }
    }

    struct Patch: Sendable {
        struct Row: Sendable { var x: Int, y: Int; var cells: [Cell] }
        var boot: String
        var projection: UInt64, base: UInt64, revision: UInt64
        var rows: [Row]
        var panes: [Pane]
        var cursor: Cursor?
        static func read(_ r: inout Reader) throws -> Self {
            try Self(boot: r.string(), projection: r.uint(), base: r.uint(), revision: r.uint(),
                     rows: r.array { try Row(x: $0.u16(), y: $0.u16(), cells: $0.array(Cell.read)) },
                     panes: r.array(Pane.read), cursor: r.optional(Cursor.read))
        }
    }

    enum Message: Sendable {
        case control(String, String)
        case frame(Frame)
        case patch(Patch)
        case response(boot: String, id: String, final: Bool, data: Data)
        case clipboard(String)
        case bell(Int)
        case error(String)
        case shutdown(String?)
        case ignored
    }

    static func decode(_ bytes: Data) throws -> Message {
        var r = Reader(data: bytes)
        let result: Message
        switch try r.uint() {
        case 3: result = .shutdown(try r.optional { try $0.string() })
        case 5: result = .clipboard(try r.string())
        case 9: result = .bell(try r.u16())
        case 13: result = .frame(try Frame.read(&r))
        case 15: result = .error(try r.string())
        case 18: result = try .response(boot: r.string(), id: r.string(), final: r.bool(), data: r.bytes())
        case 19: result = .patch(try Patch.read(&r))
        case 20: result = try .control(r.string(), r.string())
        default: return .ignored // Optional effects have their own bounded envelope.
        }
        guard r.remaining == 0 else { throw Failure.invalid("trailing bytes in record") }
        return result
    }
}
