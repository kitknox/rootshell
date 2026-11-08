//
//  KVMDModels.swift
//  rootshell
//
//  kvmd REST/WebSocket payloads. kvmd state events are partial and
//  loosely typed, so the session keeps merged JSON dictionaries and these
//  types read typed views out of them.
//

import Foundation

nonisolated enum KVMDJSON {
    static func object(from text: String) -> [String: Any]? {
        object(from: Data(text.utf8))
    }

    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Nested dictionaries merge key by key; any other value replaces.
    static func merge(_ base: [String: Any], _ update: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in update {
            if let nested = value as? [String: Any], let existing = result[key] as? [String: Any] {
                result[key] = merge(existing, nested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// `{"event_type": …, "event": {…}}`; a null event becomes empty.
    static func event(from text: String) -> (type: String, event: [String: Any])? {
        guard let object = object(from: text),
              let type = object["event_type"] as? String else { return nil }
        return (type, object["event"] as? [String: Any] ?? [:])
    }

    static func eventMessage(_ type: String, _ event: [String: Any] = [:]) -> String {
        let object: [String: Any] = ["event_type": type, "event": event]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"event_type":"\#(type)","event":{}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber where !(number === kCFBooleanTrue || number === kCFBooleanFalse):
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return ["1", "true", "yes", "on"].contains(string.lowercased())
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    static func dict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }
}

// MARK: - Errors

nonisolated enum KVMDError: LocalizedError, Equatable, Sendable {
    case invalidCredentials
    case rateLimited(seconds: Int)
    case twoStepExpired
    case unauthorized
    case http(status: Int, message: String?)
    case directVideoUnavailable
    case kickedOut(reason: String)
    case protocolError(String)
    case timedOut

    /// Errors a reconnect cannot fix; retrying them repeats the same failure
    /// or, for credentials, extends the device's lockout.
    var isTerminal: Bool {
        switch self {
        case .invalidCredentials, .rateLimited, .twoStepExpired, .directVideoUnavailable, .kickedOut:
            return true
        case .unauthorized, .http, .protocolError, .timedOut:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return String(localized: "The KVM rejected the user name, password, or verification code.")
        case .rateLimited(let seconds):
            let minutes = max(1, (seconds + 59) / 60)
            return String(localized: "Too many failed sign-ins. The KVM accepts new attempts in about \(minutes) min.")
        case .twoStepExpired:
            return String(localized: "The sign-in wasn't approved on the KVM's screen in time.")
        case .unauthorized:
            return String(localized: "The KVM session expired.")
        case .http(let status, let message):
            if let message, !message.isEmpty {
                return String(localized: "The KVM returned an error (\(status)): \(message)")
            }
            return String(localized: "The KVM returned an error (\(status)).")
        case .directVideoUnavailable:
            return String(localized: "This KVM doesn't offer Direct H.264 video. Update its firmware to 1.4 or later.")
        case .kickedOut(let reason):
            if reason == "deleted_by_admin" {
                return String(localized: "An administrator ended this KVM session.")
            }
            return String(localized: "The KVM ended this session (\(reason)).")
        case .protocolError(let detail):
            return String(localized: "Unexpected response from the KVM: \(detail)")
        case .timedOut:
            return String(localized: "The KVM didn't respond in time.")
        }
    }
}

// MARK: - Auth

nonisolated enum KVMDLoginOutcome: Equatable, Sendable {
    case token(String)
    case twoStepRequired(token: String, expiresIn: Int)
    case twoStepPending
    /// Authentication is disabled on the device.
    case open

    /// Maps a login or two-step reply. Throws the reply's terminal error.
    static func parse(status: Int, body: Data) throws -> KVMDLoginOutcome {
        let result = KVMDJSON.dict(KVMDJSON.object(from: body)?["result"]) ?? [:]
        switch status {
        case 200:
            if let token = result["token"] as? String, !token.isEmpty {
                return .token(token)
            }
            if KVMDJSON.bool(result["two_step_required"]) == true,
               let token = result["two_step_token"] as? String {
                return .twoStepRequired(token: token, expiresIn: KVMDJSON.int(result["expires_in"]) ?? 60)
            }
            if result["status"] as? String == "pending" {
                return .twoStepPending
            }
            return .open
        case 401, 403:
            throw KVMDError.invalidCredentials
        case 429:
            throw KVMDError.rateLimited(seconds: KVMDJSON.int(result["remaining_time"]) ?? 600)
        default:
            throw KVMDError.http(status: status, message: result["error_msg"] as? String)
        }
    }
}

// MARK: - Device state

nonisolated struct KVMDeviceInfo: Equatable, Sendable {
    var kvmdVersion: String?
    var model: String?
    var firmwareVersion: String?
    var hostname: String?

    static func parse(info: [String: Any]) -> KVMDeviceInfo {
        let system = KVMDJSON.dict(info["system"])
        let kvmd = KVMDJSON.dict(system?["kvmd"])
        let server = KVMDJSON.dict(KVMDJSON.dict(info["meta"])?["server"])
        return KVMDeviceInfo(
            kvmdVersion: kvmd?["version"] as? String,
            model: nil,
            firmwareVersion: nil,
            hostname: server?["host"] as? String)
    }

    /// GL.iNet's `/api/upgrade/version`; field names vary by firmware.
    mutating func apply(upgradeVersion result: [String: Any]) {
        model = (result["model"] as? String) ?? (result["board"] as? String) ?? model
        firmwareVersion = (result["version"] as? String)
            ?? (result["firmware_version"] as? String)
            ?? (result["current_version"] as? String)
            ?? firmwareVersion
    }
}

nonisolated struct KVMStreamerState: Equatable, Sendable {
    var isRunning = false
    var sourceOnline: Bool?
    var sourceWidth: Int?
    var sourceHeight: Int?
    var desiredFPS: Int?
    var videoFormat: Int?
    var h264Bitrate: Int?
    var h264Gop: Int?
    var zeroDelay: Bool?
    var bitrateRange: ClosedRange<Int>?
    var supportsH264 = true

    init() {}

    init(merged state: [String: Any]) {
        let params = KVMDJSON.dict(state["params"]) ?? [:]
        let limits = KVMDJSON.dict(state["limits"]) ?? [:]
        let features = KVMDJSON.dict(state["features"]) ?? [:]
        desiredFPS = KVMDJSON.int(params["desired_fps"])
        videoFormat = KVMDJSON.int(params["video_format"])
        h264Bitrate = KVMDJSON.int(params["h264_bitrate"])
        h264Gop = KVMDJSON.int(params["h264_gop"])
        zeroDelay = KVMDJSON.bool(params["zero_delay"])
        if let range = KVMDJSON.dict(limits["h264_bitrate"]),
           let lower = KVMDJSON.int(range["min"]), let upper = KVMDJSON.int(range["max"]), lower <= upper {
            bitrateRange = lower...upper
        }
        supportsH264 = KVMDJSON.bool(features["h264"]) ?? true

        if let streamer = KVMDJSON.dict(state["streamer"]) {
            isRunning = true
            let source = KVMDJSON.dict(streamer["source"])
            sourceOnline = KVMDJSON.bool(source?["online"])
            let resolution = KVMDJSON.dict(source?["resolution"])
            sourceWidth = KVMDJSON.int(resolution?["width"])
            sourceHeight = KVMDJSON.int(resolution?["height"])
        }
    }

    var currentPreset: KVMQualityPreset? {
        guard let h264Bitrate else { return nil }
        return KVMQualityPreset.allCases.first { preset in
            preset.bitrate == h264Bitrate && (preset.gop == nil || preset.gop == h264Gop)
        }
    }
}

nonisolated struct KVMHIDState: Equatable, Sendable {
    var online = true
    var mouseAbsolute = true
    var keyboardOnline = true
    var mouseOnline = true

    init() {}

    init(merged state: [String: Any]) {
        online = KVMDJSON.bool(state["online"]) ?? true
        let keyboard = KVMDJSON.dict(state["keyboard"])
        let mouse = KVMDJSON.dict(state["mouse"])
        keyboardOnline = KVMDJSON.bool(keyboard?["online"]) ?? online
        mouseOnline = KVMDJSON.bool(mouse?["online"]) ?? online
        mouseAbsolute = KVMDJSON.bool(mouse?["absolute"]) ?? true
    }
}

nonisolated struct KVMATXState: Equatable, Sendable {
    var enabled = false
    var busy = false
    var powerOn: Bool?
    var hddActive: Bool?

    init() {}

    init(merged state: [String: Any]) {
        enabled = KVMDJSON.bool(state["enabled"]) ?? false
        busy = KVMDJSON.bool(state["busy"]) ?? false
        let leds = KVMDJSON.dict(state["leds"])
        powerOn = KVMDJSON.bool(leds?["power"])
        hddActive = KVMDJSON.bool(leds?["hdd"])
    }
}

nonisolated enum KVMATXAction: String, CaseIterable, Sendable {
    case on
    case off
    case offHard = "off_hard"
    case resetHard = "reset_hard"

    var isDestructive: Bool { self == .offHard || self == .resetHard }
}

/// GL.iNet's own stream presets. Only a bitrate change applies live; any
/// GOP change restarts the device's encoder for every viewer.
nonisolated enum KVMQualityPreset: String, CaseIterable, Sendable {
    case auto, low, medium, high, ultra, lossless

    var bitrate: Int {
        switch self {
        case .auto: 0
        case .low: 500
        case .medium: 2000
        case .high: 5000
        case .ultra: 8000
        case .lossless: 20000
        }
    }

    var gop: Int? {
        switch self {
        case .auto: nil
        case .low, .medium: 30
        case .high, .ultra, .lossless: 60
        }
    }

    /// Streamer parameters that move the device to this preset.
    func parameters(from state: KVMStreamerState) -> [String: String] {
        var params = ["h264_bitrate": String(bitrate)]
        if let gop, gop != state.h264Gop {
            params["h264_gop"] = String(gop)
        }
        return params
    }
}
