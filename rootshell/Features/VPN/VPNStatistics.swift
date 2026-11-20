//
//  VPNStatistics.swift
//  rootshell
//
//  Statistics tracking for VPN tunnel
//

import Foundation
import os.log

/// Traffic statistics for the VPN tunnel
struct VPNStatistics: Codable, Sendable, Equatable {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VPNStatistics")

    var bytesIn: Int64
    var bytesOut: Int64
    var activeConnections: Int
    var activeTCPConnections: Int
    var activeUDPConnections: Int
    var totalConnections: Int64
    var tcpCapacityDrops: Int64
    var udpCapacityDrops: Int64
    var transportType: String
    var extensionPhysFootprintBytes: Int64
    var extensionMemoryBudgetBytes: Int64
    var extensionMemoryUsagePercent: Double
    var goHeapAllocBytes: Int64
    var goHeapInuseBytes: Int64
    var goStackInuseBytes: Int64
    var goSysBytes: Int64
    var goNumGC: Int64
    var goGoroutines: Int
    var goLiveObjects: Int64
    var connectedSince: Date?
    var tsshPort: Int?
    var tsshMode: String?
    var tsshMTU: Int?
    var tunMTU: Int?

    init(
        bytesIn: Int64 = 0,
        bytesOut: Int64 = 0,
        activeConnections: Int = 0,
        activeTCPConnections: Int = 0,
        activeUDPConnections: Int = 0,
        totalConnections: Int64 = 0,
        tcpCapacityDrops: Int64 = 0,
        udpCapacityDrops: Int64 = 0,
        transportType: String = "",
        extensionPhysFootprintBytes: Int64 = 0,
        extensionMemoryBudgetBytes: Int64 = 0,
        extensionMemoryUsagePercent: Double = 0,
        goHeapAllocBytes: Int64 = 0,
        goHeapInuseBytes: Int64 = 0,
        goStackInuseBytes: Int64 = 0,
        goSysBytes: Int64 = 0,
        goNumGC: Int64 = 0,
        goGoroutines: Int = 0,
        goLiveObjects: Int64 = 0,
        connectedSince: Date? = nil,
        tsshPort: Int? = nil,
        tsshMode: String? = nil,
        tsshMTU: Int? = nil,
        tunMTU: Int? = nil
    ) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.activeConnections = activeConnections
        self.activeTCPConnections = activeTCPConnections
        self.activeUDPConnections = activeUDPConnections
        self.totalConnections = totalConnections
        self.tcpCapacityDrops = tcpCapacityDrops
        self.udpCapacityDrops = udpCapacityDrops
        self.transportType = transportType
        self.extensionPhysFootprintBytes = extensionPhysFootprintBytes
        self.extensionMemoryBudgetBytes = extensionMemoryBudgetBytes
        self.extensionMemoryUsagePercent = extensionMemoryUsagePercent
        self.goHeapAllocBytes = goHeapAllocBytes
        self.goHeapInuseBytes = goHeapInuseBytes
        self.goStackInuseBytes = goStackInuseBytes
        self.goSysBytes = goSysBytes
        self.goNumGC = goNumGC
        self.goGoroutines = goGoroutines
        self.goLiveObjects = goLiveObjects
        self.connectedSince = connectedSince
        self.tsshPort = tsshPort
        self.tsshMode = tsshMode
        self.tsshMTU = tsshMTU
        self.tunMTU = tunMTU
    }

    /// Parse from Go GetStatus() JSON response
    static func fromGoStatus(_ json: String) -> VPNStatistics? {
        guard let data = json.data(using: .utf8) else { return nil }

        struct GoStatus: Decodable {
            let connected: Bool?
            let bytesIn: Int64?
            let bytesOut: Int64?
            let activeConns: Int?
            let activeConnections: Int?
            let activeTCPConns: Int?
            let activeUDPConns: Int?
            let totalConns: Int64?
            let totalConnections: Int64?
            let tcpCapacityDrops: Int64?
            let udpCapacityDrops: Int64?
            let transportType: String?
            let extensionPhysFootprintBytes: Int64?
            let extensionMemoryBudgetBytes: Int64?
            let extensionMemoryUsagePercent: Double?
            let goHeapAllocBytes: Int64?
            let goHeapInuseBytes: Int64?
            let goStackInuseBytes: Int64?
            let goSysBytes: Int64?
            let goNumGC: Int64?
            let goGoroutines: Int?
            let goLiveObjects: Int64?
            let connectedSinceUnix: Double?
            let tsshPort: Int?
            let tsshMode: String?
            let tsshMTU: Int?
            let tunMTU: Int?
        }

        if let status = try? JSONDecoder().decode(GoStatus.self, from: data) {
            let active = status.activeConns ?? status.activeConnections ?? 0
            let activeTCP = status.activeTCPConns ?? 0
            let activeUDP = status.activeUDPConns ?? 0
            let total = status.totalConns ?? status.totalConnections ?? 0
            let connectedSince = status.connectedSinceUnix.map { Date(timeIntervalSince1970: $0) }
            return VPNStatistics(
                bytesIn: status.bytesIn ?? 0,
                bytesOut: status.bytesOut ?? 0,
                activeConnections: active,
                activeTCPConnections: activeTCP,
                activeUDPConnections: activeUDP,
                totalConnections: total,
                tcpCapacityDrops: status.tcpCapacityDrops ?? 0,
                udpCapacityDrops: status.udpCapacityDrops ?? 0,
                transportType: status.transportType ?? "",
                extensionPhysFootprintBytes: status.extensionPhysFootprintBytes ?? 0,
                extensionMemoryBudgetBytes: status.extensionMemoryBudgetBytes ?? 0,
                extensionMemoryUsagePercent: status.extensionMemoryUsagePercent ?? 0,
                goHeapAllocBytes: status.goHeapAllocBytes ?? 0,
                goHeapInuseBytes: status.goHeapInuseBytes ?? 0,
                goStackInuseBytes: status.goStackInuseBytes ?? 0,
                goSysBytes: status.goSysBytes ?? 0,
                goNumGC: status.goNumGC ?? 0,
                goGoroutines: status.goGoroutines ?? 0,
                goLiveObjects: status.goLiveObjects ?? 0,
                connectedSince: connectedSince,
                tsshPort: status.tsshPort,
                tsshMode: status.tsshMode,
                tsshMTU: status.tsshMTU,
                tunMTU: status.tunMTU
            )
        }

        // Fallback parsing for schema drift (e.g. renamed fields or number types).
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func asInt64(_ value: Any?) -> Int64 {
            if let v = value as? Int64 { return v }
            if let v = value as? Int { return Int64(v) }
            if let v = value as? Double { return Int64(v) }
            if let v = value as? String, let n = Int64(v) { return n }
            return 0
        }
        func asInt(_ value: Any?) -> Int {
            if let v = value as? Int { return v }
            if let v = value as? Int64 { return Int(v) }
            if let v = value as? Double { return Int(v) }
            if let v = value as? String, let n = Int(v) { return n }
            return 0
        }
        func asDouble(_ value: Any?) -> Double {
            if let v = value as? Double { return v }
            if let v = value as? Int { return Double(v) }
            if let v = value as? Int64 { return Double(v) }
            if let v = value as? String, let n = Double(v) { return n }
            return 0
        }
        let connectedSinceUnix = asDouble(raw["connectedSinceUnix"])
        let connectedSince = connectedSinceUnix > 0 ? Date(timeIntervalSince1970: connectedSinceUnix) : nil
        return VPNStatistics(
            bytesIn: asInt64(raw["bytesIn"]),
            bytesOut: asInt64(raw["bytesOut"]),
            activeConnections: asInt(raw["activeConns"] ?? raw["activeConnections"]),
            activeTCPConnections: asInt(raw["activeTCPConns"]),
            activeUDPConnections: asInt(raw["activeUDPConns"]),
            totalConnections: asInt64(raw["totalConns"] ?? raw["totalConnections"]),
            tcpCapacityDrops: asInt64(raw["tcpCapacityDrops"]),
            udpCapacityDrops: asInt64(raw["udpCapacityDrops"]),
            transportType: raw["transportType"] as? String ?? "",
            extensionPhysFootprintBytes: asInt64(raw["extensionPhysFootprintBytes"]),
            extensionMemoryBudgetBytes: asInt64(raw["extensionMemoryBudgetBytes"]),
            extensionMemoryUsagePercent: asDouble(raw["extensionMemoryUsagePercent"]),
            goHeapAllocBytes: asInt64(raw["goHeapAllocBytes"]),
            goHeapInuseBytes: asInt64(raw["goHeapInuseBytes"]),
            goStackInuseBytes: asInt64(raw["goStackInuseBytes"]),
            goSysBytes: asInt64(raw["goSysBytes"]),
            goNumGC: asInt64(raw["goNumGC"]),
            goGoroutines: asInt(raw["goGoroutines"]),
            goLiveObjects: asInt64(raw["goLiveObjects"]),
            connectedSince: connectedSince,
            tsshPort: asInt(raw["tsshPort"]) > 0 ? asInt(raw["tsshPort"]) : nil,
            tsshMode: raw["tsshMode"] as? String,
            tsshMTU: asInt(raw["tsshMTU"]) > 0 ? asInt(raw["tsshMTU"]) : nil,
            tunMTU: asInt(raw["tunMTU"]) > 0 ? asInt(raw["tunMTU"]) : nil
        )
    }

    var formattedBytesIn: String {
        ByteCountFormatter.string(fromByteCount: bytesIn, countStyle: .binary)
    }

    var formattedBytesOut: String {
        ByteCountFormatter.string(fromByteCount: bytesOut, countStyle: .binary)
    }

    var formattedExtensionMemory: String {
        ByteCountFormatter.string(fromByteCount: extensionPhysFootprintBytes, countStyle: .binary)
    }

    var formattedMemoryBudget: String {
        ByteCountFormatter.string(fromByteCount: extensionMemoryBudgetBytes, countStyle: .binary)
    }

    var formattedGoHeapAlloc: String {
        ByteCountFormatter.string(fromByteCount: goHeapAllocBytes, countStyle: .binary)
    }

    /// Human-readable transport label combining runtime mode and transport type.
    var displayTransportLabel: String? {
        if let mode = tsshMode, !mode.isEmpty {
            return "TSSH (\(mode))"
        }
        switch transportType.lowercased() {
        case "ssh": return "SSH"
        case "tssh": return "TSSH"
        case "tailscale": return "Tailscale"
        case "direct": return "Direct"
        case "": return nil
        default: return transportType.uppercased()
        }
    }

    var formattedMemoryBudgetUsage: String {
        guard extensionMemoryBudgetBytes > 0 else { return "0%" }
        let percent = effectiveMemoryUsagePercent
        return String(format: "%.1f%%", percent)
    }

    var effectiveMemoryUsagePercent: Double {
        if extensionMemoryUsagePercent > 0 {
            return extensionMemoryUsagePercent
        }
        guard extensionMemoryBudgetBytes > 0 else { return 0 }
        return (Double(extensionPhysFootprintBytes) * 100.0) / Double(extensionMemoryBudgetBytes)
    }
}

// MARK: - Traffic Time Series

/// A single traffic snapshot from the extension's rolling recorder.
/// Kept separate from VPNStatistics to avoid polluting its Equatable conformance.
struct VPNTrafficSnapshot: Sendable, Equatable {
    let timestamp: Date
    let bytesIn: Int64
    let bytesOut: Int64
}

extension VPNTrafficSnapshot {
    /// Parse the compact `[[unixTimestamp, bytesIn, bytesOut], ...]` format from extension IPC.
    static func fromJSONArray(_ raw: [[Any]]) -> [VPNTrafficSnapshot] {
        raw.compactMap { entry in
            guard entry.count >= 3,
                  let t = entry[0] as? Double,
                  let bIn = (entry[1] as? NSNumber)?.int64Value,
                  let bOut = (entry[2] as? NSNumber)?.int64Value
            else { return nil }
            return VPNTrafficSnapshot(
                timestamp: Date(timeIntervalSince1970: t),
                bytesIn: bIn,
                bytesOut: bOut
            )
        }
    }
}
