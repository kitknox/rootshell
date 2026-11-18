//
//  AgentUsageAntigravityReport.swift
//  rootshell
//
//  Parses the Antigravity probe payload into a usage snapshot. The payload
//  is the raw answers the host got, split by `::AGPART:<name>::` lines:
//  the running language server's (`ls-summary`, `ls-status`, `ls-configs`)
//  or Google Cloud Code's (`summary`, `models`, `plan`).
//
//  The quota summary states shared pools by bucket id; older answers state
//  one quota per model. Every field is optional and a bucket without a
//  usable fraction is dropped rather than read as 0%.
//

import Foundation

nonisolated enum AgentUsageAntigravityReport {

    enum Outcome: Equatable {
        /// No part parsed into a quota: keep the last snapshot and retry.
        case malformed
        /// The desktop app answered but nothing in it parsed: ask Google instead.
        case localUnusable
        case snapshot(AgentUsageSnapshot)
    }

    static func parse(_ payload: String, hostKey: String, now: Date = Date()) -> Outcome {
        let parts = split(payload)
        func object(_ name: String) -> [String: Any]? {
            guard let text = parts[name], let data = text.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        let local = parts.keys.contains { $0.hasPrefix("ls-") }
        let summary = local ? object("ls-summary") : object("summary")
        let models = local ? nil : object("models")
        let status = (object("ls-status")?["userStatus"] as? [String: Any])

        var windows: [AgentUsageWindow] = []
        var stated: Set<String> = []
        if let summary {
            (windows, stated) = summaryWindows(summary)
        }

        // Google's summary leaves the Gemini pool to the model list for some
        // accounts: every Gemini model shares one 5-hour pool, Argon its own.
        if let list = models?["models"] as? [String: Any] {
            if !stated.contains("gemini-5h"),
               let quota = poolQuota(list, isGemini) {
                windows.append(window(.session, quota, AgentUsageWindowLength.session))
            }
            if let quota = poolQuota(list, isArgon) {
                windows.append(window(.sessionModel("Argon"), quota, AgentUsageWindowLength.session))
            }
            // Every other model shares the Claude pool. Without this, a list
            // with no usable summary showed Gemini alone, however low Claude ran.
            if !stated.contains("3p-5h"), !stated.contains("3p-weekly"),
               let quota = poolQuota(list, { !isGemini($0, $1) && !isArgon($0, $1) }) {
                windows.append(window(.sessionModel("Claude"), quota, AgentUsageWindowLength.session))
            }
        }

        // Older builds: one quota per model, each the 5-hour window.
        if windows.isEmpty {
            windows = perModelWindows(
                status: status,
                configs: object("ls-configs"),
                models: models?["models"] as? [String: Any])
        }
        guard !windows.isEmpty else { return local ? .localUnusable : .malformed }

        let email = (status?["email"] as? String).flatMap(nonEmpty)
        let plan = planName(status: status, cloudPlan: object("plan"))
        return .snapshot(AgentUsageSnapshot(
            provider: .antigravity,
            brand: .antigravity,
            accountKey: email.map { "agy:\($0.lowercased())" } ?? "agy@\(hostKey)",
            accountLabel: email,
            planLabel: plan,
            windows: promotingHeadline(windows),
            fetchedAt: now))
    }

    // MARK: - Payload

    private static func split(_ payload: String) -> [String: String] {
        let prefix = AgentUsageProbeCommand.antigravityPartPrefix
        var parts: [String: String] = [:]
        var name: String?
        var lines: [Substring] = []
        func flush() {
            if let name, parts[name] == nil { parts[name] = lines.joined(separator: "\n") }
            lines = []
        }
        for line in payload.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix), trimmed.hasSuffix("::") {
                flush()
                name = String(trimmed.dropFirst(prefix.count).dropLast(2))
            } else if name != nil {
                lines.append(line)
            }
        }
        flush()
        return parts
    }

    // MARK: - Quota summary

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

    /// `{"groups": [{"buckets": [...]}]}`, bare from Google or inside
    /// `response` from the language server.
    private static func summaryWindows(
        _ root: [String: Any]
    ) -> (windows: [AgentUsageWindow], stated: Set<String>) {
        let groups = ((root["response"] as? [String: Any])?["groups"] ?? root["groups"])
            as? [[String: Any]] ?? []
        var byID: [String: [String: Any]] = [:]
        var argon: [String: Any]?
        for group in groups {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = (bucket["bucketId"] ?? bucket["id"]) as? String else { continue }
                if byID[id] == nil { byID[id] = bucket }
                if argon == nil, id.contains("argon") { argon = bucket }
            }
        }
        if byID["gemini-argon-wtu-weekly"] == nil, let argon {
            byID["gemini-argon-wtu-weekly"] = argon
        }

        var windows: [AgentUsageWindow] = []
        var stated: Set<String> = []
        for (id, spec) in buckets {
            guard let bucket = byID[id],
                  let fraction = number(bucket["remainingFraction"] ?? bucket["remaining_fraction"])
            else { continue }
            windows.append(AgentUsageWindow(
                kind: spec.kind,
                usedPercent: usedPercent(remainingFraction: fraction),
                resetsAt: date(bucket["resetTime"] ?? bucket["reset_time"]),
                windowLength: spec.length))
            stated.insert(id)
        }
        return (windows, stated)
    }

    // MARK: - Per-model quotas

    private struct ModelQuota {
        var fraction: Double
        var resetsAt: Date?
    }

    /// The most constrained model in one pool. Models in a pool share it, so
    /// they should agree; the lowest is the safe reading when they do not.
    /// The model list is a legacy answer, so its rule applies: a quota with no
    /// remaining fraction is used up, not unknown.
    private static func poolQuota(
        _ models: [String: Any],
        _ belongs: (_ id: String, _ name: String) -> Bool
    ) -> ModelQuota? {
        var lowest: ModelQuota?
        for key in models.keys.sorted() {
            guard let model = models[key] as? [String: Any],
                  model["isInternal"] as? Bool != true,
                  let info = model["quotaInfo"] as? [String: Any] else { continue }
            let name = ((model["displayName"] as? String) ?? key).lowercased()
            guard belongs(key.lowercased(), name) else { continue }
            let fraction = number(info["remainingFraction"]) ?? 0
            if let current = lowest, current.fraction <= fraction { continue }
            lowest = ModelQuota(fraction: fraction, resetsAt: date(info["resetTime"]))
        }
        return lowest
    }

    private static func isGemini(_ id: String, _ name: String) -> Bool {
        (id.contains("gemini") || name.contains("gemini")) && !isArgon(id, name)
    }

    private static func isArgon(_ id: String, _ name: String) -> Bool {
        id.contains("argon") || name.contains("argon")
    }

    private static func window(
        _ kind: AgentUsageWindow.Kind,
        _ quota: ModelQuota,
        _ length: TimeInterval
    ) -> AgentUsageWindow {
        AgentUsageWindow(
            kind: kind,
            usedPercent: usedPercent(remainingFraction: quota.fraction),
            resetsAt: quota.resetsAt,
            windowLength: length)
    }

    /// Legacy answers. A missing fraction here means the quota is used up,
    /// the opposite of the summary's rule (matches the app's own reading).
    private static func perModelWindows(
        status: [String: Any]?,
        configs: [String: Any]?,
        models: [String: Any]?
    ) -> [AgentUsageWindow] {
        var entries: [(label: String, info: [String: Any])] = []
        let modelConfigs = ((status?["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"]
            ?? configs?["clientModelConfigs"]) as? [[String: Any]]
        if let modelConfigs {
            for config in modelConfigs {
                guard let label = (config["label"] as? String).flatMap(nonEmpty),
                      let info = config["quotaInfo"] as? [String: Any] else { continue }
                entries.append((label, info))
            }
        } else if let models {
            for key in models.keys.sorted() {
                guard let model = models[key] as? [String: Any],
                      model["isInternal"] as? Bool != true,
                      let info = model["quotaInfo"] as? [String: Any] else { continue }
                let label = [model["displayName"], model["label"]]
                    .compactMap { ($0 as? String).flatMap(nonEmpty) }.first ?? key
                entries.append((label, info))
            }
        }
        return entries.map { entry in
            AgentUsageWindow(
                kind: .sessionModel(entry.label),
                usedPercent: usedPercent(remainingFraction: number(entry.info["remainingFraction"]) ?? 0),
                resetsAt: date(entry.info["resetTime"]),
                windowLength: AgentUsageWindowLength.session)
        }
    }

    /// An all-scoped report (per-model answers, or a summary stating only the
    /// Claude or Argon pools) would leave the compact row blank; the most
    /// constrained window fronts it under its own name.
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

    private static func planName(status: [String: Any]?, cloudPlan: [String: Any]?) -> String? {
        let planInfo = (status?["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        if let name = (planInfo?["planName"] as? String).flatMap(nonEmpty) { return name }
        for key in ["paidTier", "currentTier"] {
            if let name = ((cloudPlan?[key] as? [String: Any])?["name"] as? String).flatMap(nonEmpty) {
                return name
            }
        }
        return nil
    }

    private static func usedPercent(remainingFraction: Double) -> Double {
        max(0, 100 - remainingFraction * 100)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? Double, number.isFinite else { return nil }
        return number
    }

    /// ISO8601 with or without fractional seconds, or epoch seconds as a
    /// string. Bounded, since it feeds the reset countdown.
    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
            return AgentUsageEpoch.sanitized(date)
        }
        return Double(string).flatMap { AgentUsageEpoch.date(seconds: $0) }
    }

    private static func nonEmpty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
