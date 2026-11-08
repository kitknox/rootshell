import XCTest

@MainActor
final class KVMProtocolTests: XCTestCase {

    // MARK: - HID frames

    func testKeyFrameCarriesStateAndCodeName() {
        XCTAssertEqual(KVMHIDFrame.key("KeyA", down: true), Data([0x01, 0x01]) + Data("KeyA".utf8))
        XCTAssertEqual(KVMHIDFrame.key("ShiftLeft", down: false), Data([0x01, 0x00]) + Data("ShiftLeft".utf8))
    }

    func testButtonFrameUsesKvmdButtonNames() {
        XCTAssertEqual(KVMHIDFrame.button(.right, down: true), Data([0x02, 0x01]) + Data("right".utf8))
        XCTAssertEqual(KVMHIDFrame.button(.back, down: false), Data([0x02, 0x00]) + Data("up".utf8))
    }

    func testAbsoluteMoveIsBigEndianSigned() {
        XCTAssertEqual(KVMHIDFrame.absoluteMove(x: -32768, y: 32767), Data([0x03, 0x80, 0x00, 0x7F, 0xFF]))
        XCTAssertEqual(KVMHIDFrame.absoluteMove(x: 1, y: -1), Data([0x03, 0x00, 0x01, 0xFF, 0xFF]))
    }

    func testAbsoluteCoordinateSpansTheFrame() {
        XCTAssertEqual(KVMHIDFrame.absoluteCoordinate(0, extent: 1920), -32768)
        XCTAssertEqual(KVMHIDFrame.absoluteCoordinate(1919, extent: 1920), 32767)
        XCTAssertEqual(KVMHIDFrame.absoluteCoordinate(5000, extent: 1920), 32767)
        XCTAssertEqual(KVMHIDFrame.absoluteCoordinate(-4, extent: 1920), -32768)
        XCTAssertEqual(KVMHIDFrame.absoluteCoordinate(10, extent: 0), 0)
        let middle = KVMHIDFrame.absoluteCoordinate(960, extent: 1921)
        XCTAssertTrue(abs(Int(middle)) <= 1)
    }

    func testRelativeAndWheelFrames() {
        XCTAssertEqual(KVMHIDFrame.relativeMove([(5, -3), (-127, 127)]), Data([0x04, 0x00, 0x05, 0xFD, 0x81, 0x7F]))
        XCTAssertEqual(KVMHIDFrame.wheel(dx: 0, dy: -1), Data([0x05, 0x00, 0x00, 0xFF]))
    }

    func testSplitDeltaStaysWithinInt8AndSumsBack() {
        let steps = KVMHIDFrame.splitDelta(dx: 300, dy: -200)
        XCTAssertTrue(steps.allSatisfy { abs(Int($0.dx)) <= 127 && abs(Int($0.dy)) <= 127 })
        XCTAssertEqual(steps.reduce(0) { $0 + Int($1.dx) }, 300)
        XCTAssertEqual(steps.reduce(0) { $0 + Int($1.dy) }, -200)
        XCTAssertTrue(KVMHIDFrame.splitDelta(dx: 0, dy: 0).isEmpty)
    }

    // MARK: - Key names

    func testKeysymsMapToUSPositions() {
        XCTAssertEqual(KVMKeyMap.key(forKeysym: 0x61), .init(code: "KeyA", shifted: false))
        XCTAssertEqual(KVMKeyMap.key(forKeysym: 0x5A), .init(code: "KeyZ", shifted: true))
        XCTAssertEqual(KVMKeyMap.key(forKeysym: 0x30), .init(code: "Digit0", shifted: false))
        XCTAssertEqual(KVMKeyMap.key(forKeysym: 0x21), .init(code: "Digit1", shifted: true))
        XCTAssertEqual(KVMKeyMap.key(forKeysym: 0x7C), .init(code: "Backslash", shifted: true))
        XCTAssertEqual(KVMKeyMap.key(forKeysym: 0xFF0D)?.code, "Enter")
        XCTAssertEqual(KVMKeyMap.key(forKeysym: 0xFFC9)?.code, "F12")
        XCTAssertEqual(KVMKeyMap.key(forKeysym: 0xFFB5)?.code, "Numpad5")
        XCTAssertEqual(KVMKeyMap.key(forKeysym: 0xFFEB)?.code, "MetaLeft")
        XCTAssertEqual(KVMKeyMap.key(forKeysym: 0xFFE9)?.code, "AltLeft")
        XCTAssertNil(KVMKeyMap.key(forKeysym: 0x0100_00E9))
    }

    func testHIDUsagesMapToPhysicalKeys() {
        XCTAssertEqual(KVMKeyMap.code(forHIDUsage: 0x04), "KeyA")
        XCTAssertEqual(KVMKeyMap.code(forHIDUsage: 0x1D), "KeyZ")
        XCTAssertEqual(KVMKeyMap.code(forHIDUsage: 0x1E), "Digit1")
        XCTAssertEqual(KVMKeyMap.code(forHIDUsage: 0x27), "Digit0")
        XCTAssertEqual(KVMKeyMap.code(forHIDUsage: 0x3A), "F1")
        XCTAssertEqual(KVMKeyMap.code(forHIDUsage: 0x45), "F12")
        XCTAssertEqual(KVMKeyMap.code(forHIDUsage: 0x59), "Numpad1")
        XCTAssertEqual(KVMKeyMap.code(forHIDUsage: 0x62), "Numpad0")
        XCTAssertEqual(KVMKeyMap.code(forHIDUsage: 0x64), "IntlBackslash")
        XCTAssertEqual(KVMKeyMap.code(forHIDUsage: 0xE3), "MetaLeft")
        XCTAssertNil(KVMKeyMap.code(forHIDUsage: 0x68))
    }

    /// Every name the maps produce must be one kvmd accepts.
    func testMappedNamesAreKnownToKvmd() {
        let kvmdNames: Set<String> = [
            "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL",
            "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX",
            "KeyY", "KeyZ", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8",
            "Digit9", "Digit0", "Enter", "Escape", "Backspace", "Tab", "Space", "Minus", "Equal",
            "BracketLeft", "BracketRight", "Backslash", "Semicolon", "Quote", "Backquote", "Comma", "Period",
            "Slash", "CapsLock", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
            "PrintScreen", "Insert", "Home", "PageUp", "Delete", "End", "PageDown", "ArrowRight", "ArrowLeft",
            "ArrowDown", "ArrowUp", "ControlLeft", "ShiftLeft", "AltLeft", "MetaLeft", "ControlRight",
            "ShiftRight", "AltRight", "MetaRight", "Pause", "ScrollLock", "NumLock", "ContextMenu",
            "NumpadDivide", "NumpadMultiply", "NumpadSubtract", "NumpadAdd", "NumpadEnter", "Numpad1",
            "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9",
            "Numpad0", "NumpadDecimal", "Power", "IntlBackslash", "IntlYen", "IntlRo", "KanaMode", "Convert",
            "NonConvert", "AudioVolumeMute", "AudioVolumeUp", "AudioVolumeDown", "F20",
        ]
        for usage in UInt32(0)...0xFF {
            if let code = KVMKeyMap.code(forHIDUsage: usage) {
                XCTAssertTrue(kvmdNames.contains(code), "usage \(usage) -> \(code)")
            }
        }
        let keysyms = Array(UInt32(0x20)...0xFF) + Array(UInt32(0xFE00)...0xFFFF) + [0x1008FF11, 0x1008FF12, 0x1008FF13, 0x1008FF2A]
        for keysym in keysyms {
            if let key = KVMKeyMap.key(forKeysym: keysym) {
                XCTAssertTrue(kvmdNames.contains(key.code), "keysym \(keysym) -> \(key.code)")
            }
        }
    }

    // MARK: - Media frames

    func testMediaFrameParsing() {
        XCTAssertEqual(KVMMediaFrame.parse(Data([0x01, 0x01, 0x00, 0x00, 0x01, 0x65])),
                       .video(isKeyframe: true, accessUnit: Data([0x00, 0x00, 0x01, 0x65])))
        XCTAssertEqual(KVMMediaFrame.parse(Data([0x01, 0x00])), .video(isKeyframe: false, accessUnit: Data()))
        XCTAssertEqual(KVMMediaFrame.parse(Data([0xFF])), .pong)
        XCTAssertNil(KVMMediaFrame.parse(Data([0x01])))
        XCTAssertNil(KVMMediaFrame.parse(Data()))
        // A slice of a larger buffer must index from its own start.
        let buffer = Data([0x09, 0x01, 0x00, 0xAA])
        XCTAssertEqual(KVMMediaFrame.parse(buffer.dropFirst()), .video(isKeyframe: false, accessUnit: Data([0xAA])))
    }

    func testMediaAnnouncement() {
        let announcement = #"{"event_type":"media","event":{"video":{"h264":{"profile_level_id":"42E01F"}}}}"#
        XCTAssertEqual(KVMMediaFrame.advertisesH264(announcement), true)
        XCTAssertEqual(KVMMediaFrame.advertisesH264(#"{"event_type":"media","event":{"video":{}}}"#), false)
        XCTAssertNil(KVMMediaFrame.advertisesH264(#"{"event_type":"loop","event":{}}"#))
    }

    // MARK: - Annex B

    func testAnnexBSplitsThreeAndFourByteStartCodes() {
        let au = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x32,
                       0x00, 0x00, 0x01, 0x68, 0xEE,
                       0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x00])
        let nals = AnnexB.nalUnits(in: au)
        XCTAssertEqual(nals, [Data([0x67, 0x64, 0x00, 0x32]), Data([0x68, 0xEE]), Data([0x65, 0x88, 0x00])])
        XCTAssertEqual(nals.map(AnnexB.type(of:)), [7, 8, 5])
    }

    func testAnnexBLengthPrefixing() {
        let avcc = AnnexB.lengthPrefixed([Data([0x65, 0x01]), Data([0x41])])
        XCTAssertEqual(avcc, Data([0, 0, 0, 2, 0x65, 0x01, 0, 0, 0, 1, 0x41]))
    }

    func testProfileLevelFromSPS() {
        XCTAssertEqual(AnnexB.profileLevel(fromSPS: Data([0x67, 100, 0x00, 50])), "High@5.0")
        XCTAssertEqual(AnnexB.profileLevel(fromSPS: Data([0x67, 66, 0xE0, 31])), "Constrained Baseline@3.1")
        XCTAssertNil(AnnexB.profileLevel(fromSPS: Data([0x67])))
    }

    // MARK: - kvmd models

    func testLoginOutcomes() throws {
        let token = Data(#"{"ok":true,"result":{"token":"abc","failed_since_last_success":0}}"#.utf8)
        XCTAssertEqual(try KVMDLoginOutcome.parse(status: 200, body: token), .token("abc"))

        let twoStep = Data(#"{"ok":true,"result":{"two_step_required":true,"two_step_token":"2s_x","expires_in":60}}"#.utf8)
        XCTAssertEqual(try KVMDLoginOutcome.parse(status: 200, body: twoStep), .twoStepRequired(token: "2s_x", expiresIn: 60))

        let pending = Data(#"{"ok":true,"result":{"status":"pending"}}"#.utf8)
        XCTAssertEqual(try KVMDLoginOutcome.parse(status: 200, body: pending), .twoStepPending)

        XCTAssertEqual(try KVMDLoginOutcome.parse(status: 200, body: Data(#"{"ok":true,"result":{}}"#.utf8)), .open)

        XCTAssertThrowsError(try KVMDLoginOutcome.parse(status: 403, body: Data())) { error in
            XCTAssertEqual(error as? KVMDError, .invalidCredentials)
        }
        let limited = Data(#"{"ok":false,"result":{"error":"RateLimitError","remaining_time":420}}"#.utf8)
        XCTAssertThrowsError(try KVMDLoginOutcome.parse(status: 429, body: limited)) { error in
            XCTAssertEqual(error as? KVMDError, .rateLimited(seconds: 420))
        }
    }

    func testTerminalErrorsNeverRetry() {
        XCTAssertTrue(KVMDError.invalidCredentials.isTerminal)
        XCTAssertTrue(KVMDError.rateLimited(seconds: 1).isTerminal)
        XCTAssertFalse(KVMDError.timedOut.isTerminal)
        XCTAssertFalse(KVMDError.unauthorized.isTerminal)
    }

    func testStreamerStateMergesPartialEvents() throws {
        let full = try XCTUnwrap(KVMDJSON.event(from: """
            {"event_type":"streamer","event":{
              "features":{"h264":true,"zero_delay":true},
              "limits":{"h264_bitrate":{"min":0,"max":20000}},
              "params":{"video_format":1,"h264_bitrate":5000,"h264_gop":60,"zero_delay":false,"desired_fps":60},
              "streamer":{"source":{"online":true,"resolution":{"width":1920,"height":1080}}}}}
            """))
        XCTAssertEqual(full.type, "streamer")
        var merged = full.event
        var state = KVMStreamerState(merged: merged)
        XCTAssertEqual(state.videoFormat, 1)
        XCTAssertEqual(state.currentPreset, .high)
        XCTAssertEqual(state.bitrateRange, 0...20000)
        XCTAssertEqual(state.sourceOnline, true)
        XCTAssertEqual(state.sourceWidth, 1920)

        let partial = try XCTUnwrap(KVMDJSON.event(from:
            #"{"event_type":"streamer","event":{"streamer":{"source":{"online":false}}}}"#))
        merged = KVMDJSON.merge(merged, partial.event)
        state = KVMStreamerState(merged: merged)
        XCTAssertEqual(state.sourceOnline, false)
        XCTAssertEqual(state.sourceWidth, 1920, "untouched nested keys survive a partial update")
        XCTAssertEqual(state.h264Bitrate, 5000)

        let stopped = try XCTUnwrap(KVMDJSON.event(from: #"{"event_type":"streamer","event":{"streamer":null}}"#))
        state = KVMStreamerState(merged: KVMDJSON.merge(merged, stopped.event))
        XCTAssertFalse(state.isRunning)
    }

    func testQualityPresetSendsGOPOnlyWhenItChanges() {
        var state = KVMStreamerState()
        state.h264Gop = 60
        XCTAssertEqual(KVMQualityPreset.high.parameters(from: state), ["h264_bitrate": "5000"])
        XCTAssertEqual(KVMQualityPreset.low.parameters(from: state), ["h264_bitrate": "500", "h264_gop": "30"])
        XCTAssertEqual(KVMQualityPreset.auto.parameters(from: state), ["h264_bitrate": "0"])
    }

    func testHIDAndATXState() {
        let hid = KVMHIDState(merged: ["online": true, "mouse": ["absolute": false, "online": true]])
        XCTAssertFalse(hid.mouseAbsolute)
        let atx = KVMATXState(merged: ["enabled": true, "busy": false, "leds": ["power": true, "hdd": false]])
        XCTAssertTrue(atx.enabled)
        XCTAssertEqual(atx.powerOn, true)
    }

    func testEventMessageEncoding() throws {
        let ping = try XCTUnwrap(KVMDJSON.event(from: KVMDJSON.eventMessage("ping")))
        XCTAssertEqual(ping.type, "ping")
        XCTAssertTrue(ping.event.isEmpty)
    }
}
