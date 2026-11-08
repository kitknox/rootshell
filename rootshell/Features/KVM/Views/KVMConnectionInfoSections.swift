//
//  KVMConnectionInfoSections.swift
//  rootshell
//
//  Connection Info sheet sections for a KVM over IP pane.
//

import SwiftUI

struct KVMConnectionInfoSections: View {
    let info: KVMConnectionInfo

    var body: some View {
        let session = info.session

        Section("Connection") {
            row("Host", info.host)
            row("Port", "\(info.port)")
            row("User", info.username)
            row("Transport", info.transportDescription)
            if let fingerprint = session.certificateFingerprint {
                row("Certificate", String(fingerprint.prefix(23)) + "…")
            }
            HStack {
                Text("Duration")
                    .foregroundStyle(.secondary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ConnectionInfoSheet.formatDuration(from: info.connectedAt, to: context.date))
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                }
            }
            .themedRow()
        }

        Section("Device") {
            if let model = session.deviceInfo.model {
                row("Model", model)
            }
            if let firmware = session.deviceInfo.firmwareVersion {
                row("Firmware", firmware)
            }
            if let kvmd = session.deviceInfo.kvmdVersion {
                row("kvmd", kvmd)
            }
            row("Mouse", session.hid.mouseAbsolute
                ? String(localized: "Absolute")
                : String(localized: "Relative"))
            row("Typing Layout", KVMKeyboardLayouts.displayName(session.config.hostKeyboardLayout))
            if session.atx.enabled {
                row("Power", session.atx.powerOn == true
                    ? String(localized: "On")
                    : String(localized: "Off"))
            }
        }

        Section("Video") {
            if let format = session.videoFormat {
                row("Resolution", "\(format.width) × \(format.height)")
                if let profile = format.profileLevel {
                    row("Codec", "H.264 \(profile)")
                }
            }
            if let bitrate = session.streamer.h264Bitrate {
                row("Encoder Bitrate", bitrate == 0
                    ? String(localized: "Automatic")
                    : "\(bitrate) kbps")
            }
            if let gop = session.streamer.h264Gop {
                row("Keyframe Interval", "\(gop)")
            }
            if let zeroDelay = session.streamer.zeroDelay {
                row("Latency Mode", zeroDelay ? String(localized: "On") : String(localized: "Off"))
            }
        }

        Section("Performance") {
            row("Frame Rate", String(format: "%.0f fps", session.statistics.framesPerSecond))
            row("Throughput", String(format: "%.0f kbps", session.statistics.kilobitsPerSecond))
            if let roundTrip = session.statistics.roundTrip {
                row("Round Trip", String(format: "%.0f ms", roundTrip * 1000))
            }
            row("Keyframe Requests", "\(session.statistics.keyframeRequests)")
            if session.statistics.decodeErrors > 0 {
                row("Decode Errors", "\(session.statistics.decodeErrors)")
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .themedRow()
    }
}
