//
//  AgentUsageOMPReport.swift
//  rootshell
//
//  Parses `omp usage --json` into the same snapshot model the three native
//  lanes produce.
//
//  oh-my-pi signs into many providers at once, so one pane is 1:N rather than
//  1:1 and there is no single account to attribute it to. Rather than read
//  its credential store and re-implement a dozen provider APIs, the probe
//  asks oh-my-pi for the answer it already has: `omp usage --json` reports
//  every authenticated account in one normalized payload and caches each
//  provider's result for five minutes internally.
//
//  The upside is that no token ever leaves the host and a provider added
//  upstream needs no change here. The cost is that we are parsing someone
//  else's schema, so every field is treated as optional and a lane that does
//  not parse is dropped rather than guessed at.
//

import Foundation

nonisolated enum AgentUsageOMPReport {

    /// What a probe payload turned out to be.
    ///
    /// The distinction matters because `omp usage --json` writes a VALID
    /// payload and returns before its no-credentials exit-1 path, so an
    /// install with nothing signed in emits `{"reports": [], ...}` and exits
    /// 0. Collapsing that with malformed output made logging out of every
    /// account leave its quota rows on screen forever, and put the host into
    /// probe-health backoff instead of recording a stable absence.
    enum Outcome: Equatable {
        /// Not JSON, or no `reports` array: retry, keep what we had.
        case malformed
        /// A valid report. An EMPTY array is a real answer -- this install
        /// has no usage accounts -- not a failure.
        case accounts([AgentUsageSnapshot])
    }

    /// One account's usage, as omp reports it. A single payload normally
    /// yields several: one per (provider, account).
    static func parse(_ json: String, now: Date = Date()) -> Outcome {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reports = root["reports"] as? [[String: Any]]
        else { return .malformed }

        // Keyed by (brand, account) because omp reports one entry per
        // provider but a provider may hold several accounts, each carrying
        // its own limits — load-balancing across two Anthropic logins is a
        // documented oh-my-pi feature, so collapsing them would show one
        // account's numbers under both names.
        var byAccount: [String: AgentUsageSnapshot] = [:]
        var order: [String] = []

        for report in reports {
            guard let providerID = report["provider"] as? String else { continue }
            let brand = AgentUsageBrand.fromOMPProvider(providerID)
            // Bounded, not merely finite. Rejecting NaN and infinity here was
            // not enough: "1e24" is finite, and the Date it produces overflows
            // the Int conversion in the "updated N minutes ago" arithmetic,
            // which traps. An unusable stamp is no stamp -- the payload
            // arrived now regardless of what it claims about itself.
            let fetchedAt = number(report["fetchedAt"])
                .flatMap { AgentUsageEpoch.date(milliseconds: $0) } ?? now
            let limits = report["limits"] as? [[String: Any]] ?? []

            // Which lane fronts the compact row can only be decided once
            // every lane of the same cadence has been seen, so the shortest
            // id per cadence is measured first and the classification below
            // ranks against it.
            var shortestSegmentsByCadence: [CadenceGroup: Int] = [:]
            for limit in limits {
                let windowInfo = limit["window"] as? [String: Any]
                let ms = number(windowInfo?["durationMs"])
                let c = cadence(limit: limit, window: windowInfo, durationMs: ms)
                let key = group(limit: limit, window: windowInfo, durationMs: ms, cadence: c)
                let segments = segmentCount(limit)
                if let existing = shortestSegmentsByCadence[key] {
                    shortestSegmentsByCadence[key] = min(existing, segments)
                } else {
                    shortestSegmentsByCadence[key] = segments
                }
            }

            // Account identity is REPORT-level. `UsageScope` has no email
            // field at all, and the Anthropic module puts accountId, email
            // and orgId in `report.metadata` -- so keying off the limit scope
            // alone collapsed every Anthropic account onto "claude|-" and
            // merged their windows into one mixed row, defeating the
            // load-balancing across several logins that oh-my-pi documents.
            // Scope is the fallback for providers that do populate it.
            let metadata = report["metadata"] as? [String: Any]
            let reportAccount = accountLabel(metadata: metadata)
            let reportIdentity = accountIdentity(metadata: metadata)

            for limit in limits {
                guard let window = window(
                    from: limit,
                    shortestSegmentsByCadence: shortestSegmentsByCadence)
                else { continue }
                let scope = limit["scope"] as? [String: Any]
                let account = reportAccount ?? accountLabel(scope: scope)
                // Identity and display are DIFFERENT values. Keying on the
                // display string meant the same subscription changed key
                // whenever metadata completeness changed -- one host
                // reporting email and accountId keyed by email while another
                // reporting only accountId keyed by that, so `ompAccounts`
                // could not collapse them and one subscription rendered as
                // several accounts. Case differences in an email did it too.
                let identity = reportIdentity
                    ?? accountIdentity(scope: scope)
                    ?? account?.lowercased()
                let key = "\(brand.dedupeID)|\(identity ?? "-")"

                if var existing = byAccount[key] {
                    existing.windows.append(window)
                    // Keep the freshest stamp across a provider's lanes.
                    if fetchedAt > existing.fetchedAt { existing.fetchedAt = fetchedAt }
                    byAccount[key] = existing
                } else {
                    byAccount[key] = AgentUsageSnapshot(
                        provider: .omp,
                        brand: brand,
                        // Prefixed so an omp-sourced account can never collide
                        // with a native lane's host-derived key; merging the
                        // two is a deliberate step in the center, not an
                        // accident of key collision.
                        accountKey: "omp:\(key)",
                        accountLabel: account,
                        planLabel: planLabel(report: report, limit: limit),
                        windows: [window],
                        creditsBalance: creditsBalance(report),
                        fetchedAt: fetchedAt)
                    order.append(key)
                }
            }
        }

        let snapshots = order.compactMap { byAccount[$0] }
            .filter { !$0.windows.isEmpty }
            .map(promotingHeadline)

        // A NON-empty reports array that yielded nothing usable is a schema
        // we failed to read, not an install with no accounts: retry rather
        // than wiping the rows. An empty array is the genuine absence.
        if snapshots.isEmpty, !reports.isEmpty { return .malformed }
        return .accounts(snapshots)
    }

    /// Convenience for call sites that only care about the accounts.
    static func snapshots(_ json: String, now: Date = Date()) -> [AgentUsageSnapshot] {
        if case .accounts(let accounts) = parse(json, now: now) { return accounts }
        return []
    }

    /// Guarantees at least one unscoped window per account.
    ///
    /// Scoped lanes are popover-only: `compactLine` filters them and the
    /// mini-bars only match session/weekly/monthly. An account whose lanes
    /// are ALL scoped therefore rendered a mark and then nothing at all --
    /// not even "Unlimited", since that is reserved for genuinely empty
    /// window lists. Gemini reports exactly that shape today: tier scopes,
    /// no durationMs, and window ids like "quota" or "reset-<timestamp>"
    /// that no cadence rule recognises.
    ///
    /// Promotes the most constrained lane, which is the one the compact row
    /// would have led with anyway, and keeps its own label so the row still
    /// says what it is measuring.
    private static func promotingHeadline(_ snapshot: AgentUsageSnapshot) -> AgentUsageSnapshot {
        guard !snapshot.windows.isEmpty,
              snapshot.windows.allSatisfy({ $0.kind.isScoped }),
              let leadIndex = snapshot.windows.indices.max(by: {
                  snapshot.windows[$0].usedPercent < snapshot.windows[$1].usedPercent
              })
        else { return snapshot }

        var promoted = snapshot
        let lead = promoted.windows[leadIndex]

        // Re-derive the period from the DURATION, not from the scoped kind.
        // `.weeklyModel` is what BOTH a subordinate session lane and a
        // subordinate weekly lane collapse to, so the kind no longer knows
        // which it was: mapping it straight to `.weekly` promoted an
        // account whose only quota is a model-scoped five-hour limit and
        // displayed it as "7d". The window still carries its real length,
        // which is the one thing that never lost the answer.
        let label: String
        switch lead.kind {
        case .weeklyModel(let text), .sessionModel(let text), .monthlyScoped(let text): label = text
        case .session, .weekly, .monthly, .labelled: return snapshot
        }
        let promotedKind: AgentUsageWindow.Kind
        switch lead.windowLength.map({ $0 / 3600 }).flatMap(standardCadence) {
        case .session: promotedKind = .session
        case .weekly: promotedKind = .weekly
        case .monthly: promotedKind = .monthly(label)
        // No length, or a length matching no standard window: show the
        // lane's own name and claim no period.
        case .other, .unknown, .none: promotedKind = .labelled(label)
        }
        promoted.windows[leadIndex] = AgentUsageWindow(
            kind: promotedKind,
            usedPercent: lead.usedPercent,
            resetsAt: lead.resetsAt,
            windowLength: lead.windowLength,
            remainingCount: lead.remainingCount,
            entitlement: lead.entitlement)
        return promoted
    }

    // MARK: - Windows

    /// Maps one oh-my-pi `UsageLimit` onto our window model.
    ///
    /// Everything normalizes to USED percent, the convention the rest of the
    /// model follows, and a lane whose numbers cannot be read at all returns
    /// nil rather than a zero — a false "0% used" reads as plenty of headroom
    /// and is the worst possible failure for this feature.
    private static func window(
        from limit: [String: Any],
        shortestSegmentsByCadence: [CadenceGroup: Int]
    ) -> AgentUsageWindow? {
        let amount = limit["amount"] as? [String: Any] ?? [:]
        let unit = amount["unit"] as? String
        let used = number(amount["used"])
        let entitlement = number(amount["limit"])
        let remaining = number(amount["remaining"])
        let usedFraction = number(amount["usedFraction"])
        let remainingFraction = number(amount["remainingFraction"])

        let usedPercent: Double
        if let usedFraction {
            usedPercent = usedFraction * 100
        } else if let remainingFraction {
            usedPercent = (1 - remainingFraction) * 100
        } else if unit == "percent", let used {
            // Already a percentage; the ratio branches below would only
            // reproduce it, and they need a limit this shape often omits.
            usedPercent = used
        } else if let used, let entitlement, entitlement > 0 {
            usedPercent = (used / entitlement) * 100
        } else if let remaining, let entitlement, entitlement > 0 {
            usedPercent = ((entitlement - remaining) / entitlement) * 100
        } else {
            return nil
        }

        // A husk lane: no entitlement and nothing left is not "100% used", it
        // is a meter the provider stopped keeping. Copilot's
        // premium_interactions taught this the hard way, as a live false
        // alarm that read 100% while credits remained.
        if entitlement == 0, (remaining ?? 0) == 0 { return nil }

        let windowInfo = limit["window"] as? [String: Any]
        let durationMs = number(windowInfo?["durationMs"])
        let resetsAt = number(windowInfo?["resetsAt"])
            .flatMap { AgentUsageEpoch.date(milliseconds: $0) }

        let laneCadence = cadence(limit: limit, window: windowInfo, durationMs: durationMs)
        let laneGroup = group(
            limit: limit, window: windowInfo,
            durationMs: durationMs, cadence: laneCadence)
        let subordinate = isSubordinate(
            limit: limit,
            group: laneGroup,
            shortestSegmentsByCadence: shortestSegmentsByCadence)

        return AgentUsageWindow(
            kind: kind(
                limit: limit, window: windowInfo,
                cadence: laneCadence, subordinate: subordinate),
            usedPercent: max(0, min(100, usedPercent)),
            resetsAt: resetsAt,
            // Bounded for the same reason the stamps are: a duration a
            // hundred million years long is not a window, and the pace tick
            // would place itself against it as though it were. An unusable
            // duration already becomes no duration; finite-but-absurd is
            // just as unusable.
            windowLength: durationMs.flatMap { AgentUsageEpoch.interval(seconds: $0 / 1000) },
            remainingCount: remaining,
            entitlement: entitlement)
    }

    /// How a limit is metered, before deciding whether it fronts the compact
    /// row or stays popover detail.
    ///
    /// `other` is a real, stated duration that matches none of the standard
    /// windows. It is deliberately distinct from `unknown`: both render with
    /// the lane's own label, but only `other` has a duration to show a pace
    /// tick from.
    private enum Cadence { case session, weekly, monthly, other, unknown }

    /// Key for deciding which lanes compete to front the compact row.
    ///
    /// `Cadence` is the right granularity for RENDERING but far too coarse
    /// for hierarchy: `.other` covers every declared non-standard duration
    /// and `.unknown` every undeclared one, so an hourly quota and a daily
    /// quota were ranked against each other and the daily one was demoted
    /// purely for having a longer id. Siblings must share an actual period.
    private enum CadenceGroup: Hashable {
        case standard(String)
        /// Distinct durations are distinct periods, never siblings.
        case duration(Int)
        /// No duration to compare, so the window's own id is the only stable
        /// thing that says whether two lanes measure the same thing.
        case identified(String)
    }

    private static func group(
        limit: [String: Any],
        window: [String: Any]?,
        durationMs: Double?,
        cadence: Cadence
    ) -> CadenceGroup {
        switch cadence {
        case .session: return .standard("session")
        case .weekly: return .standard("weekly")
        case .monthly: return .standard("monthly")
        case .other:
            // A duration that will not convert cannot identify a period, so
            // it groups by the window id instead of trapping.
            guard let ms = durationMs.map({ $0.rounded() }).flatMap(safeInt) else {
                let id = ((window?["id"] as? String) ?? (limit["id"] as? String) ?? "").lowercased()
                return .identified(id)
            }
            return .duration(ms)
        case .unknown:
            // Same fallback `cadence` uses. `window` is optional in the
            // schema, and keying on it alone gave EVERY windowless limit the
            // group "", so unrelated windowless quotas ranked against each
            // other and the longer-id one vanished from the compact row.
            let id = ((window?["id"] as? String) ?? (limit["id"] as? String) ?? "").lowercased()
            return .identified(id)
        }
    }

    /// Rounding tolerance around the standard windows -- NOT a range of
    /// "roughly similar" periods.
    ///
    /// `.session` and `.weekly` render as the literal strings "5h" and "7d",
    /// so a duration may only claim them if it IS five hours or seven days.
    /// `durationMs` is a nominal window length, so the only slack needed is
    /// for a provider reporting 4.999h or 6.99d; anything else keeps its own
    /// label. Successive widenings of these bands showed a one-hour quota as
    /// "5h", a daily quota as "7d", and then an exact three-hour or eight-
    /// hour limit as "5h".
    ///
    /// Monthly is genuinely wider because a calendar month IS 28 to 31 days,
    /// and providers compute it from an observed billing period rather than
    /// a fixed constant.
    /// Canonical whole-token spellings for the standard windows. Anything
    /// outside these keeps its own label.
    private static let sessionTokens: Set<String> = ["5h", "5hour", "5hours", "session"]
    private static let weeklyTokens: Set<String> = ["7d", "7day", "7days", "1w", "week", "weekly"]
    private static let monthlyTokens: Set<String> = ["1mo", "mo", "month", "monthly"]

    private static func standardCadence(hours: Double) -> Cadence? {
        if (4.9...5.1).contains(hours) { return .session }
        if (24 * 6.9...24 * 7.1).contains(hours) { return .weekly }
        if (24 * 27.0...24 * 32.0).contains(hours) { return .monthly }
        return nil
    }

    /// Classify by DECLARED duration first, never by a nominal 5h/7d
    /// assumption — the Codex tracker learned that a "primary window" can be
    /// a week, and putting a window start in the future makes the pace marker
    /// vanish. The window id is only a fallback for reports with no duration.
    private static func cadence(
        limit: [String: Any],
        window: [String: Any]?,
        durationMs: Double?
    ) -> Cadence {
        if let durationMs {
            return standardCadence(hours: durationMs / 3_600_000) ?? .other
        }
        // Whole tokens, never substrings. `durationMs` is optional in
        // oh-my-pi's schema so this path is ordinary, not exceptional, and
        // substring matching mislabelled real ids: "hourly" and "24hour" both
        // contain "hour" and became a five-hour session, "biweekly" contains
        // "week" and became seven days, and "model-quota" contains "mo" and
        // became monthly. An id we do not recognise keeps its own label
        // rather than borrowing a cadence.
        let id = ((window?["id"] as? String) ?? (limit["id"] as? String) ?? "").lowercased()
        let tokens = Set(
            id.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if !tokens.isDisjoint(with: Self.sessionTokens) { return .session }
        if !tokens.isDisjoint(with: Self.weeklyTokens) { return .weekly }
        if !tokens.isDisjoint(with: Self.monthlyTokens) { return .monthly }
        return .unknown
    }

    /// Whether a limit is subordinate to another lane of the same cadence.
    ///
    /// Scoped lanes are popover-only (`Kind.isScoped`), so getting this wrong
    /// in the pessimistic direction empties the compact row entirely.
    ///
    /// NOT a segment count. That was the first attempt, taken from
    /// Anthropic's "anthropic:7d" headline vs "anthropic:7d:opus" per-model
    /// pair, and it silently broke every provider that names a category in
    /// the middle of its id: xAI's headline lane is "xai-oauth:credits:1w"
    /// (three segments), so the whole account rendered a blank row.
    ///
    /// Two signals, both provider-agnostic:
    ///  - an explicit model/tier scope that is not marked shared, which is
    ///    how Anthropic tags its per-model lanes;
    ///  - being a longer id than the shortest lane of the same cadence for
    ///    this account, which is how a category lane ("…:product:grok:1w")
    ///    ranks under its own overall lane ("…:credits:1w").
    private static func isSubordinate(
        limit: [String: Any],
        group: CadenceGroup,
        shortestSegmentsByCadence: [CadenceGroup: Int]
    ) -> Bool {
        let scope = limit["scope"] as? [String: Any]
        let isShared = (scope?["shared"] as? Bool) == true
        if !isShared, scope?["modelId"] != nil || scope?["tier"] != nil { return true }
        let segments = segmentCount(limit)
        if let shortest = shortestSegmentsByCadence[group], segments > shortest { return true }
        return false
    }

    private static func segmentCount(_ limit: [String: Any]) -> Int {
        (limit["id"] as? String)?.split(separator: ":").count ?? 0
    }

    private static func kind(
        limit: [String: Any],
        window: [String: Any]?,
        cadence: Cadence,
        subordinate: Bool
    ) -> AgentUsageWindow.Kind {
        let label = (limit["label"] as? String) ?? (window?["label"] as? String) ?? "Usage"
        switch cadence {
        case .session: return subordinate ? .weeklyModel(label) : .session
        case .weekly: return subordinate ? .weeklyModel(label) : .weekly
        case .monthly: return subordinate ? .monthlyScoped(label) : .monthly(label)
        // A stated but non-standard period, and an unstated one, both show
        // the lane's own name rather than borrowing another provider's
        // window text. Subordinate lanes stay scoped so they appear in the
        // popover without claiming a compact slot.
        case .other, .unknown: return subordinate ? .monthlyScoped(label) : .labelled(label)
        }
    }

    // MARK: - Identity and labels

    /// Prefer something a human recognizes. omp redacts nothing by default,
    /// so an email is normally present; the ids are the fallback.
    private static func accountLabel(scope: [String: Any]?) -> String? {
        guard let scope else { return nil }
        // No `email` here by design: UsageScope does not define one. Kept in
        // the list anyway so a provider that adds it is picked up.
        for key in ["email", "accountId", "orgName", "orgId", "projectId"] {
            if let value = scope[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// STABLE identity for the account key, as distinct from the label a
    /// person reads. Provider-assigned ids first, because they do not change
    /// when an optional profile lookup fails; a normalized email only as the
    /// last resort, since that is the field most likely to be missing on one
    /// host and present on another.
    private static func accountIdentity(metadata: [String: Any]?) -> String? {
        guard let metadata else { return nil }
        for key in ["accountId", "account_id", "orgId", "projectId"] {
            if let value = metadata[key] as? String, !value.isEmpty {
                return value.lowercased()
            }
        }
        if let email = metadata["email"] as? String, !email.isEmpty {
            return email.lowercased()
        }
        return nil
    }

    private static func accountIdentity(scope: [String: Any]?) -> String? {
        guard let scope else { return nil }
        for key in ["accountId", "orgId", "projectId"] {
            if let value = scope[key] as? String, !value.isEmpty {
                return value.lowercased()
            }
        }
        return nil
    }

    /// Report-level identity, which is where every provider that knows who
    /// it is actually puts it.
    private static func accountLabel(metadata: [String: Any]?) -> String? {
        guard let metadata else { return nil }
        for key in ["email", "accountId", "account_id", "orgName", "orgId", "projectId"] {
            if let value = metadata[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func planLabel(report: [String: Any], limit: [String: Any]) -> String? {
        if let tier = (limit["scope"] as? [String: Any])?["tier"] as? String, !tier.isEmpty {
            return tier.prefix(1).uppercased() + tier.dropFirst()
        }
        if let metadata = report["metadata"] as? [String: Any] {
            for key in ["plan", "planType", "tier", "sku"] {
                if let value = metadata[key] as? String, !value.isEmpty {
                    return value.prefix(1).uppercased() + value.dropFirst()
                }
            }
        }
        return nil
    }

    private static func creditsBalance(_ report: [String: Any]) -> Double? {
        guard let metadata = report["metadata"] as? [String: Any] else { return nil }
        // omp carries this as a string on some providers, matching the
        // upstream payloads it mirrors.
        return number(metadata["creditsBalance"]) ?? number(metadata["credits"])
    }

    /// JSON numbers arrive as NSNumber, but several providers hand oh-my-pi a
    /// numeric STRING and it passes them through unchanged.
    ///
    /// Non-finite values are rejected outright rather than propagated.
    /// `Double("nan")` and `Double("1e400")` both parse, and either one
    /// reaching the model is unsafe in two different ways: converting it to
    /// Int traps and takes the app down, and the used-percent clamp turns
    /// NaN into a silent 100%, which reads as an exhausted subscription. A
    /// lane whose numbers cannot be trusted is dropped, which is what every
    /// other unreadable field here already does.
    ///
    /// Finite is NOT the same as usable, so this is only the first gate.
    /// `"1e24"` passes here and still overflows Int once a caller divides an
    /// interval by 60; callers that build a Date go through
    /// `AgentUsageEpoch`, and callers that need an Int go through `safeInt`.
    private static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        if let d = value as? Double { parsed = d }
        else if let i = value as? Int { parsed = Double(i) }
        else if let s = value as? String { parsed = Double(s) }
        else { parsed = nil }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    /// Safe Double-to-Int for values that reached us from a remote payload.
    /// Defence in depth behind `number`: any future caller that skips it
    /// still cannot trap here.
    ///
    /// The upper bound is STRICT. `Double(Int.max)` rounds up to exactly
    /// 2^63, one past the range, so `value <= Double(Int.max)` admitted a
    /// value that `Int(_:)` then trapped on. `Double(Int.min)` is exactly
    /// representable, so the lower bound is correct inclusive.
    private static func safeInt(_ value: Double) -> Int? {
        guard value.isFinite,
              value >= Double(Int.min), value < Double(Int.max)
        else { return nil }
        return Int(value)
    }
}
