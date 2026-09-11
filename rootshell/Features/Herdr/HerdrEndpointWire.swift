// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

/// Vanilla herdr v0.9.0, endpoint generation 1. These tags and field orders
/// come from upstream src/protocol/wire.rs, not the rootshell control fork.
/// The JSON hello negotiates the frozen codecs; their envelope is bincode 2
/// standard configuration inside a four-byte little-endian length prefix.
nonisolated enum HerdrEndpointWire {
    static let limit = 32 * 1024 * 1024

    enum Failure: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return "herdr endpoint: \(message)" }
        }
    }

    struct Framer {
        private var buffer = Data()
        mutating func receive(_ bytes: Data) throws -> [Data] {
            buffer.append(bytes)
            var records: [Data] = []
            var consumed = 0
            while buffer.count - consumed >= 4 {
                let start = buffer.startIndex + consumed
                let length = (0..<4).reduce(0) { $0 | Int(buffer[start + $1]) << ($1 * 8) }
                guard length > 0, length <= limit else { throw Failure.invalid("invalid frame length") }
                guard buffer.count - consumed - 4 >= length else { break }
                records.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
                consumed += length + 4
            }
            if consumed > 0 { buffer.removeFirst(consumed) }
            guard buffer.count <= limit + 4 else { throw Failure.invalid("frame buffer overflow") }
            return records
        }
    }

    struct Writer {
        var data = Data()
        mutating func byte(_ value: UInt8) { data.append(value) }
        mutating func bool(_ value: Bool) { byte(value ? 1 : 0) }
        mutating func uint(_ value: UInt64) {
            if value < 251 { byte(UInt8(value)); return }
            let width: Int
            if value <= UInt16.max { byte(251); width = 2 }
            else if value <= UInt32.max { byte(252); width = 4 }
            else { byte(253); width = 8 }
            for index in 0..<width { byte(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        mutating func bytes(_ value: Data) { uint(UInt64(value.count)); data.append(value) }
        mutating func string(_ value: String) { bytes(Data(value.utf8)) }
        mutating func optionalString(_ value: String?) {
            bool(value != nil)
            if let value { string(value) }
        }
        func framed() -> Data {
            var length = UInt32(data.count).littleEndian
            var result = withUnsafeBytes(of: &length) { Data($0) }
            result.append(data)
            return result
        }
    }

    struct Reader {
        let data: Data
        var offset = 0
        var remaining: Int { data.count - offset }
        mutating func byte() throws -> UInt8 {
            guard remaining > 0 else { throw Failure.invalid("truncated record") }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }
        mutating func bool() throws -> Bool {
            switch try byte() {
            case 0: return false
            case 1: return true
            default: throw Failure.invalid("invalid boolean")
            }
        }
        mutating func uint(max: UInt64 = .max) throws -> UInt64 {
            let first = try byte()
            let value: UInt64
            if first < 251 { value = UInt64(first) }
            else {
                let width: Int
                switch first {
                case 251: width = 2
                case 252: width = 4
                case 253: width = 8
                default: throw Failure.invalid("invalid integer")
                }
                var result: UInt64 = 0
                for index in 0..<width { result |= UInt64(try byte()) << (index * 8) }
                value = result
            }
            guard value <= max else { throw Failure.invalid("integer out of range") }
            return value
        }
        mutating func u16() throws -> Int { Int(try uint(max: UInt64(UInt16.max))) }
        mutating func u32() throws -> UInt32 { UInt32(try uint(max: UInt64(UInt32.max))) }
        mutating func i32() throws -> Int32 {
            let value = try u32()
            return Int32(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
        }
        mutating func bytes() throws -> Data {
            let count = Int(try uint(max: UInt64(remaining)))
            guard count <= remaining else { throw Failure.invalid("truncated bytes") }
            defer { offset += count }
            return Data(data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
        }
        mutating func string() throws -> String {
            guard let string = String(data: try bytes(), encoding: .utf8) else {
                throw Failure.invalid("invalid UTF-8")
            }
            return string
        }
        mutating func optional<T>(_ read: (inout Reader) throws -> T) throws -> T? {
            try bool() ? read(&self) : nil
        }
        mutating func array<T>(_ read: (inout Reader) throws -> T) throws -> [T] {
            let count = Int(try uint(max: UInt64(min(remaining, 1_000_000))))
            var result: [T] = []
            result.reserveCapacity(count)
            for _ in 0..<count { result.append(try read(&self)) }
            return result
        }
    }

    static func control(_ kind: String, _ value: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        var writer = Writer()
        writer.uint(20) // ClientMessage::EndpointControl
        writer.string(kind)
        writer.string(String(decoding: json, as: UTF8.self))
        return writer.framed()
    }

    static func hello(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) throws -> Data {
        try control("endpoint.hello.v1", [
            "generation": 1, "cell_width_px": cellWidth, "cell_height_px": cellHeight,
            "surface_size": ["cols": cols, "rows": rows], "pixel_mouse": true,
            "direct_graphics": false, "endpoint_keybindings": false,
            "mouse_capture": false, "surface_active": true,
            "snapshot_codecs": ["shell.snapshot.v1"], "surface_codecs": ["shell.surface.v1"],
            "input_codecs": ["shell.input.semantic.v1"], "blob_codecs": ["shell.blob.v1"]
        ])
    }

    static func request(boot: String, id: String, method: String, params: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params], options: [.sortedKeys])
        guard json.count <= 1024 * 1024 else { throw Failure.invalid("command exceeds upstream limit") }
        var writer = Writer()
        writer.uint(15) // ClientShellEndpointRequest
        writer.string(boot)
        writer.string(String(decoding: json, as: UTF8.self))
        return writer.framed()
    }

    static func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) -> Data {
        var writer = Writer()
        writer.uint(12)
        writer.uint(UInt64(cellWidth)); writer.uint(UInt64(cellHeight))
        writer.uint(UInt64(cols)); writer.uint(UInt64(rows)); writer.bool(true)
        return writer.framed()
    }

    /// Event payloads use upstream ClientPaneInputEvent's frozen encoding.
    static func input(pane: String, popup: Bool = false, event: Writer, repeatCount: Int = 1) -> Data {
        var writer = Writer()
        writer.uint(popup ? 14 : 13)
        let count = min(96, max(1, repeatCount))
        writer.string(pane); writer.uint(UInt64(count))
        for _ in 0..<count { writer.data.append(event.data) }
        return writer.framed()
    }

    static func text(_ text: String, paste: Bool = false) -> Writer {
        var writer = Writer()
        writer.uint(paste ? 3 : 1); writer.string(text)
        return writer
    }

    static func key(code: UInt64, character: String? = nil, function: UInt8? = nil,
                    modifiers: UInt8, kind: UInt64, text: String?, physical: UInt32?, shifted: UInt32? = nil) -> Writer {
        var writer = Writer()
        writer.uint(0); writer.uint(code)
        if let character { writer.data.append(contentsOf: character.utf8) } // bincode char
        if let function { writer.byte(function) }
        writer.byte(modifiers); writer.uint(kind); writer.uint(1)
        writer.bool(shifted != nil)
        if let shifted { writer.uint(UInt64(shifted)) }
        writer.optionalString(text)
        writer.bool(physical != nil)
        writer.bool(physical != nil)
        if let physical { writer.uint(UInt64(physical)) }
        writer.bool(false) // Windows console record
        return writer
    }

    static func mouse(kind: UInt64, button: UInt64? = nil, column: Int, row: Int,
                      modifiers: UInt8, lines: Int = 1,
                      pixels: (x: UInt32, y: UInt32, cols: Int, rows: Int, width: UInt32, height: UInt32)? = nil) -> Writer {
        var writer = Writer()
        writer.uint(2); writer.uint(kind)
        if let button { writer.uint(button) }
        writer.uint(pixels == nil ? 0 : 1)
        if let pixels { writer.uint(UInt64(pixels.x)); writer.uint(UInt64(pixels.y)) }
        writer.uint(UInt64(min(65535, max(0, column)))); writer.uint(UInt64(min(65535, max(0, row))))
        writer.bool(pixels != nil)
        if let pixels {
            writer.uint(UInt64(pixels.cols)); writer.uint(UInt64(pixels.rows))
            writer.uint(UInt64(pixels.width)); writer.uint(UInt64(pixels.height))
        }
        writer.byte(modifiers); writer.uint(UInt64(min(65535, max(1, lines))))
        return writer
    }
}
