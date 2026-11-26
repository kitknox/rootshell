//
//  AgentUsageAntigravityReport.swift
//  rootshell
//
//  Parses `agy -p /usage --output-format json` into a usage snapshot. The
//  report states shared pools as buckets under `command.data.groups`, each
//  with a stable id, a remaining fraction and a reset time. A bucket without
//  a usable fraction is dropped rather than read as 0%.
//

import Foundation

nonisolated enum AgentUsageAntigravityReport {

    /// nil when the report did not parse into any window: keep the last
    /// snapshot and retry.
    static func parse(_ payload: String, hostKey: String, now: Date = Date()) -> AgentUsageSnapshot? {
        // Anything agy prints around the JSON (an update notice) is skipped.
        guard let start = payload.firstIndex(of: "{"),
              let end = payload.lastIndex(of: "}"), start < end,
              let root = (try? JSONSerialization.jsonObject(
                  with: Data(payload[start...end].utf8))) as? [String: Any],
              root["status"] as? String == "SUCCESS"
        else { return nil }

        let data = (root["command"] as? [String: Any])?["data"] as? [String: Any]
        let groups = data?["groups"] as? [[String: Any]] ?? []
        let windows = bucketWindows(groups)
        guard !windows.isEmpty else { return nil }

        // `/usage` names no account, so the host stands in for one.
        return AgentUsageSnapshot(
            provider: .antigravity,
            brand: .antigravity,
            accountKey: "agy@\(hostKey)",
            accountLabel: nil,
            planLabel: nil,
            windows: promotingHeadline(windows),
            fetchedAt: now)
    }

    // MARK: - Buckets

    private struct Bucket {
        var kind: AgentUsageWindow.Kind
        var length: TimeInterval
    }

    private static let buckets: [(id: String, bucket: Bucket)] = [
        ("gemini-5h", Bucket(kind: .session, length: AgentUsageWindowLength.session)),
        ("gemini-weekly", Bucket(kind: .weekly, length: AgentUsageWindowLength.weekly)),
        ("3p-5h", Bucket(kind: .sessionModel("Claude"), length: AgentUsageWindowLength.session)),
        ("3p-weekly", Bucket(kind: .weeklyModel("Claude"), length: AgentUsageWindowLength.weekly)),
        ("gemini-argon-wtu-weekly",
         Bucket(kind: .weeklyModel("Argon"), length: AgentUsageWindowLength.weekly)),
    ]

    private static func bucketWindows(_ groups: [[String: Any]]) -> [AgentUsageWindow] {
        var byID: [String: [String: Any]] = [:]
        var argon: [String: Any]?
        for group in groups {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = bucket["id"] as? String else { continue }
                if byID[id] == nil { byID[id] = bucket }
                if argon == nil, id.contains("argon") { argon = bucket }
            }
        }
        if byID["gemini-argon-wtu-weekly"] == nil, let argon {
            byID["gemini-argon-wtu-weekly"] = argon
        }

        return buckets.compactMap { id, spec in
            guard let bucket = byID[id],
                  let fraction = number(bucket["remaining_fraction"]) else { return nil }
            return AgentUsageWindow(
                kind: spec.kind,
                usedPercent: max(0, 100 - fraction * 100),
                resetsAt: date(bucket["reset_time"]),
                windowLength: spec.length)
        }
    }

    /// An all-scoped report (one stating only the Claude or Argon pools)
    /// would leave the compact row blank; the most constrained window fronts
    /// it under its own name.
    private static func promotingHeadline(_ windows: [AgentUsageWindow]) -> [AgentUsageWindow] {
        guard windows.allSatisfy({ $0.kind.isScoped }),
              let lead = windows.indices.max(by: {
                  windows[$0].usedPercent < windows[$1].usedPercent
              }),
              let label = periodLabel(windows[lead].kind)
        else { return windows }
        var promoted = windows
        promoted[lead].kind = .labelled(label)
        return promoted
    }

    /// The window's name with its period, since `.labelled` claims none:
    /// "Claude 5h", "Argon 7d". A weekly-only report needs a headline too.
    private static func periodLabel(_ kind: AgentUsageWindow.Kind) -> String? {
        switch kind {
        case .sessionModel(let label):
            return String(
                localized: "\(label) 5h",
                comment: "Agent usage compact label: a model's five-hour window")
        case .weeklyModel(let label):
            return String(
                localized: "\(label) 7d",
                comment: "Agent usage compact label: a model's seven-day window")
        default:
            return nil
        }
    }

    // MARK: - Fields

    /// JSON numbers arrive as NSNumber, so an integral `1` reads as Double too.
    private static func number(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return nil }
        return number
    }

    /// ISO8601 with or without fractional seconds. An untouched pool reports
    /// the epoch itself, which means no reset is pending.
    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string),
              date.timeIntervalSince1970 > 0
        else { return nil }
        return AgentUsageEpoch.sanitized(date)
    }
}
