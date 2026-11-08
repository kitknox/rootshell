//
//  AnnexB.swift
//  rootshell
//
//  H.264 Annex-B access units to the length-prefixed (AVCC) layout
//  VideoToolbox decodes.
//

import Foundation

nonisolated enum AnnexB {
    enum NALType: UInt8 {
        case slice = 1
        case idr = 5
        case sei = 6
        case sps = 7
        case pps = 8
        case accessUnitDelimiter = 9
    }

    /// NAL units without start codes. Bytes before the first start code
    /// are ignored; a trailing zero before a 4-byte start code is dropped.
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(start: Int, prefix: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index + 3, 3))
                index += 3
            } else {
                index += 1
            }
        }
        var units: [Data] = []
        for (offset, entry) in starts.enumerated() {
            var end = offset + 1 < starts.count ? starts[offset + 1].start - 3 : bytes.count
            while end > entry.start, bytes[end - 1] == 0, offset + 1 < starts.count {
                end -= 1
            }
            if end > entry.start {
                units.append(Data(bytes[entry.start..<end]))
            }
        }
        return units
    }

    static func type(of nal: Data) -> UInt8 {
        (nal.first ?? 0) & 0x1F
    }

    /// Concatenates NAL units, each with a 4-byte big-endian length.
    static func lengthPrefixed(_ nals: [Data]) -> Data {
        var output = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let length = UInt32(nal.count)
            output.append(UInt8(length >> 24))
            output.append(UInt8((length >> 16) & 0xFF))
            output.append(UInt8((length >> 8) & 0xFF))
            output.append(UInt8(length & 0xFF))
            output.append(nal)
        }
        return output
    }

    /// "High@5.0"-style label from an SPS NAL unit.
    static func profileLevel(fromSPS sps: Data) -> String? {
        let bytes = [UInt8](sps)
        guard bytes.count >= 4 else { return nil }
        let profile: String
        switch bytes[1] {
        case 66: profile = (bytes[2] & 0x40) != 0 ? "Constrained Baseline" : "Baseline"
        case 77: profile = "Main"
        case 88: profile = "Extended"
        case 100: profile = "High"
        case 110: profile = "High 10"
        case 122: profile = "High 4:2:2"
        case 244: profile = "High 4:4:4"
        default: profile = "Profile \(bytes[1])"
        }
        let level = Int(bytes[3])
        return "\(profile)@\(level / 10).\(level % 10)"
    }
}
