//
//  KVMMediaFrame.swift
//  rootshell
//
//  kvmd-media framing on `/api/media/ws`: server video frames are
//  `[0x01][key 0|1][Annex-B access unit]`, pong is `[0xFF]`.
//

import Foundation

nonisolated enum KVMMediaFrame: Equatable, Sendable {
    case video(isKeyframe: Bool, accessUnit: Data)
    case pong

    static let ping = Data([0x00])
    static let keyframeRequest = Data([0x01])

    static let startH264Message = #"{"event_type":"start","event":{"type":"video","format":"h264"}}"#

    static func parse(_ data: Data) -> KVMMediaFrame? {
        guard let op = data.first else { return nil }
        switch op {
        case 0x01:
            guard data.count >= 2 else { return nil }
            let keyIndex = data.index(after: data.startIndex)
            let payload = data[data.index(after: keyIndex)...]
            return .video(isKeyframe: data[keyIndex] != 0, accessUnit: Data(payload))
        case 0xFF:
            return .pong
        default:
            return nil
        }
    }

    /// The server's opening `media` event lists the formats it can stream.
    static func advertisesH264(_ text: String) -> Bool? {
        guard let object = KVMDJSON.object(from: text),
              object["event_type"] as? String == "media" else { return nil }
        let video = (object["event"] as? [String: Any])?["video"] as? [String: Any]
        return video?["h264"] != nil
    }
}
