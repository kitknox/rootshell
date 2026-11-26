//
//  AgentUsageModel.swift
//  rootshell
//
//  Normalized subscription-usage model shared by both providers, plus the
//  parsers for their usage responses and the small pure math the overlay
//  renders from (status band, pace tick, countdowns).
//
//  Everything normalizes to USED percent: Claude reports `utilization`
//  (used), Codex reports `used_percent` (used), and some CLI surfaces report
//  remaining — one convention here keeps polarity bugs out of the views.
//

import Foundation

/// Bounds for Dates built from a raw epoch value in a probe payload.
///
/// Rejecting NaN and infinity is not enough: a finite Double is not
/// necessarily a plausible date. `"fetchedAt": "1e24"` survives every
/// non-finite check and lands the Date some 3e13 years out, and the interval
/// to it overflows Int in the "updated N ago" and "resets in N" arithmetic,
/// which traps and takes the app down. Anything outside a calendar range a
/// real host could report is treated as no value at all.
nonisolated enum AgentUsageEpoch {
    /// Two centuries either side of 1970 -- wider than any clock a host could
    /// plausibly report, narrow enough that intervals stay far inside Int.
    static let bound: TimeInterval = 200 * 365 * 24 * 60 * 60

    /// A Date from an epoch in seconds, or nil when it is out of range.
    static func date(seconds: Double) -> Date? {
        guard seconds.isFinite, abs(seconds) <= bound else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// A Date from an epoch in milliseconds, or nil when it is out of range.
    /// Infinity and NaN survive the division, so the seconds form catches them.
    static func date(milliseconds: Double) -> Date? {
        date(seconds: milliseconds / 1000)
    }

    /// A Date that already exists -- decoded from storage, or built by a build
    /// that predates these bounds -- pulled back to nil when it is unusable.
    static func sanitized(_ date: Date) -> Date? {
        self.date(seconds: date.timeIntervalSince1970)
    }

    /// An interval bounded to the same range, for the `resets in N seconds`
    /// form where the payload gives an offset rather than a stamp.
    static func interval(seconds: Double) -> TimeInterval? {
        guard seconds.isFinite, abs(seconds) <= bound else { return nil }
        return seconds
    }
}

/// One rate-limit window of one account.
nonisolated struct AgentUsageWindow: Equatable, Sendable, Codable {
    enum Kind: Equatable, Sendable, Codable {
        /// Claude 5-hour session window / Codex primary window.
        case session
        /// Claude 7-day all-models window / Codex secondary window.
        case weekly
        /// Claude per-model weekly window, labelled by model display name.
        case weeklyModel(String)
        /// A per-model five-hour window (Antigravity's Claude pool), labelled
        /// by model family.
        case sessionModel(String)
        /// Copilot's headline calendar-month quota. The label names the
        /// unit, which GitHub has changed once already: "Premium requests"
        /// through May 2026, "Credits" since the June 2026 billing change.
        case monthly(String)
        /// Copilot's secondary monthly meters ("Chat", "Completions" on
        /// the Free plan, or premium requests riding alongside credits).
        case monthlyScoped(String)
        /// A headline lane whose cadence the provider did not state. Carries
        /// the lane's own name and claims NO period: coercing these to
        /// `.monthly` rendered a Gemini quota of unknown cadence as "mo 42%"
        /// and "Pro quota (month)", which is a period we never established.
        case labelled(String)

        /// Scoped lanes stay out of the compact footer line; the popover
        /// lists every window either way.
        var isScoped: Bool {
            switch self {
            case .session, .weekly, .monthly, .labelled: return false
            case .weeklyModel, .sessionModel, .monthlyScoped: return true
            }
        }
    }

    var kind: Kind
    var usedPercent: Double
    var resetsAt: Date?
    /// Nominal window length, for the pace tick. nil = no pace shown.
    var windowLength: TimeInterval?
    /// Request counts, where the provider meters in requests rather than
    /// percent (Copilot). Both present -> "N of M left" in the popover.
    var remainingCount: Double? = nil
    var entitlement: Double? = nil

    var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// `usedPercent` as a whole number for display.
    ///
    /// Only the oh-my-pi parser clamps this field; the native lanes pass the
    /// provider's number through as-is, and over-quota values above 100 are
    /// legitimate. So the guard is against the pathological rather than the
    /// merely large: a non-finite percent traps the Int conversion, and a
    /// plain `min(100,)` clamp would read NaN as a fully exhausted plan.
    var displayPercent: Int {
        guard usedPercent.isFinite else { return 0 }
        return AgentUsageFormat.saturatingInt(usedPercent.rounded())
    }

    /// How much of the bar to fill, 0...1. Separate from `displayPercent`
    /// because the bar does saturate at full: a 120% lane draws a full bar
    /// and reads "120%". `min`/`max` alone would pass NaN straight through
    /// to a view frame, so the finite check comes first here too.
    var barFraction: Double {
        guard usedPercent.isFinite else { return 0 }
        return min(max(usedPercent, 0), 100) / 100
    }

    var shortLabel: String {
        switch kind {
        case .session:
            return String(localized: "5h", comment: "Compact agent usage window: five hours")
        case .weekly:
            return String(localized: "7d", comment: "Compact agent usage window: seven days")
        case .weeklyModel(let model): return model
        case .sessionModel(let model): return model
        case .monthly:
            return String(localized: "mo", comment: "Compact agent usage window: month")
        case .monthlyScoped(let label): return label
        case .labelled(let label): return label
        }
    }
}

/// Which product's quota a snapshot describes, as distinct from the probe
/// lane that fetched it.
///
/// The two are the same thing for the three native lanes, but not for
/// oh-my-pi: one `omp` probe returns quotas for every provider that install
/// is signed into, so `provider` stays `.omp` (bookkeeping, backoff, cadence)
/// while `brand` says whose numbers these are (label, logo, dedupe).
nonisolated enum AgentUsageBrand: Equatable, Hashable, Sendable, Codable {
    case claude
    case codex
    case copilot
    /// A provider with no native lane of ours (Z.AI, Kimi, Cursor, Devin,
    /// Antigravity, OpenRouter, …). `id` is oh-my-pi's provider id, kept so
    /// dedupe is stable; `label` is what the row shows.
    case other(id: String, label: String)

    /// Manifest agent id for `AgentBrandMark`, or nil to fall back to the
    /// oh-my-pi mark. Deliberately not exhaustive: an unknown brand must
    /// degrade to a generic mark, never to a missing-asset box.
    var agentID: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .copilot: return "copilot"
        case .other: return nil
        }
    }

    /// Asset-catalog name for this brand's own mark.
    ///
    /// A usage row is identified by its mark alone (the compact footer row
    /// draws no text), so every provider oh-my-pi can report needs a distinct
    /// one. Falling back to the oh-my-pi mark for all of them made an xAI
    /// row, a Z.AI row and a Kimi row visually identical.
    ///
    /// Keyed on oh-my-pi's provider id. nil means genuinely unrecognized, and
    /// the view degrades to the oh-my-pi mark plus a text label rather than a
    /// missing-asset box.
    var assetName: String? {
        switch self {
        case .claude: return "ClaudeLogo"
        case .codex: return "CodexLogo"
        case .copilot: return "CopilotLogo"
        case .other(let id, _): return Self.assetNamesByProviderID[id]
        }
    }

    /// oh-my-pi provider id to asset. Providers whose mark this app already
    /// shipped reuse it; the rest were drawn for this feature as simplified
    /// geometric marks, not official artwork, so a real vendor SVG can be
    /// dropped into the same imageset later without touching this table.
    private static let assetNamesByProviderID: [String: String] = [
        "cursor": "CursorAgentLogo",
        "cursor-agent": "CursorAgentLogo",
        "google-antigravity": "AntigravityLogo",
        "openrouter": "OpenRouterLogo",
        // The id oh-my-pi actually reports is the AUTH provider id, which
        // for Google OAuth is google-gemini-cli and for Moonshot is
        // kimi-code. The bare "gemini"/"kimi" spellings are the module
        // names, not wire values, and matching only those sent both rows to
        // the generic fallback despite having a mark for each.
        "google-gemini-cli": "GoogleLogo",
        "gemini": "GoogleLogo",
        "google": "GoogleLogo",
        "opencode-go": "OpenCodeLogo",
        "opencode": "OpenCodeLogo",
        "gitlab-duo": "GitLabLogo",
        "xai-oauth": "XAILogo",
        "xai": "XAILogo",
        "zai": "ZAILogo",
        "kimi-code": "KimiLogo",
        "kimi": "KimiLogo",
        "minimax-code": "MiniMaxLogo",
        "minimax-token-plan": "MiniMaxLogo",
        "minimax": "MiniMaxLogo",
        "alibaba-token-plan": "QwenLogo",
        "alibaba": "QwenLogo",
        "qwen": "QwenLogo",
        "ollama": "OllamaLogo",
        "ollama-cloud": "OllamaLogo",
        "synthetic": "SyntheticLogo",
        "umans": "UmansLogo",
        "umans-coder": "UmansLogo",
        "devin": "DevinLogo",
        "devin-agent": "DevinLogo",
    ]

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        case .other(_, let label): return label
        }
    }

    /// Stable key for merging the same account seen through two lanes.
    var dedupeID: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .copilot: return "copilot"
        case .other(let id, _): return id
        }
    }

    /// The native Antigravity lane's brand. Shares oh-my-pi's provider id so
    /// an omp-reported Antigravity account dedupes against it.
    static let antigravity = AgentUsageBrand.other(id: "google-antigravity", label: "Antigravity")

    /// oh-my-pi provider id -> brand. Its ids come from
    /// `packages/ai/src/usage/*`; anything unrecognized keeps its id so a
    /// provider added upstream still renders rather than disappearing.
    static func fromOMPProvider(_ id: String) -> AgentUsageBrand {
        switch id.lowercased() {
        case "anthropic", "claude": return .claude
        case "openai-codex", "codex": return .codex
        case "github-copilot", "copilot": return .copilot
        default: return .other(id: id.lowercased(), label: ompLabel(for: id))
        }
    }

    /// Title-cases an unknown provider id for display ("zai" -> "Zai",
    /// "opencode-go" -> "Opencode Go"). A handful of ids read badly that way
    /// and get a spelling.
    private static func ompLabel(for id: String) -> String {
        switch id.lowercased() {
        case "zai", "zai-coding-plan": return "Z.AI"
        case "kimi-code", "kimi": return "Kimi"
        case "google-gemini-cli": return "Gemini"
        case "cursor-agent": return "Cursor"
        case "devin-agent": return "Devin"
        case "opencode-go": return "OpenCode Go"
        case "xai-oauth", "xai": return "xAI"
        case "google-antigravity": return "Antigravity"
        case "minimax-code": return "MiniMax"
        case "alibaba-token-plan": return "Alibaba"
        case "openrouter": return "OpenRouter"
        case "ollama": return "Ollama"
        default:
            return id.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

/// Everything one usage fetch learned about one account.
nonisolated struct AgentUsageSnapshot: Equatable, Sendable, Codable {
    var provider: AgentUsageProvider
    /// Defaults from `provider` when absent, so snapshots persisted before
    /// oh-my-pi existed still decode.
    var brand: AgentUsageBrand
    var accountKey: String
    /// Account email or id, when the source knows one. oh-my-pi reports it;
    /// the native Claude lane cannot (its key is host-derived on macOS).
    /// Used to decide whether two lanes are describing the same account.
    var accountLabel: String?
    var planLabel: String?
    var windows: [AgentUsageWindow]
    /// Codex only: pay-as-you-go credits alongside the windows.
    var creditsBalance: Double?
    var fetchedAt: Date

    /// `brand` and `accountLabel` are defaulted so the three native lanes
    /// construct exactly as they did before oh-my-pi existed.
    init(
        provider: AgentUsageProvider,
        brand: AgentUsageBrand? = nil,
        accountKey: String,
        accountLabel: String? = nil,
        planLabel: String? = nil,
        windows: [AgentUsageWindow],
        creditsBalance: Double? = nil,
        fetchedAt: Date
    ) {
        self.provider = provider
        self.brand = brand ?? AgentUsageSnapshot.defaultBrand(for: provider)
        self.accountKey = accountKey
        self.accountLabel = accountLabel
        self.planLabel = planLabel
        self.windows = windows
        self.creditsBalance = creditsBalance
        self.fetchedAt = fetchedAt
    }

    static func defaultBrand(for provider: AgentUsageProvider) -> AgentUsageBrand {
        switch provider {
        case .claude: return .claude
        case .codex: return .codex
        case .copilot: return .copilot
        // Only reached by a decode of a malformed snapshot: every omp
        // snapshot is built with an explicit brand, since the whole point of
        // that lane is that one probe yields several.
        case .omp: return .other(id: "omp", label: "oh-my-pi")
        case .antigravity: return .antigravity
        }
    }

    /// Hand-written so a snapshot persisted before `brand` existed still
    /// decodes: UserDefaults holds the previous release's JSON across an
    /// update, and a throwing decode would silently drop every stored
    /// account and reset the fetch clocks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try c.decode(AgentUsageProvider.self, forKey: .provider)
        self.provider = provider
        self.brand = try c.decodeIfPresent(AgentUsageBrand.self, forKey: .brand)
            ?? AgentUsageSnapshot.defaultBrand(for: provider)
        self.accountKey = try c.decode(String.self, forKey: .accountKey)
        self.accountLabel = try c.decodeIfPresent(String.self, forKey: .accountLabel)
        self.planLabel = try c.decodeIfPresent(String.self, forKey: .planLabel)
        self.windows = try c.decode([AgentUsageWindow].self, forKey: .windows)
        self.creditsBalance = try c.decodeIfPresent(Double.self, forKey: .creditsBalance)
        // Sanitized on the way in, not just on the way out. A build that
        // predates the epoch bounds could persist a stamp far enough out that
        // the countdown arithmetic traps, and it would keep crashing every
        // launch after the parser was fixed. It also permanently wins the
        // freshness comparison in `adoptConservativeClock`, pinning staleness
        // off for that account.
        let storedFetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        self.fetchedAt = AgentUsageEpoch.sanitized(storedFetchedAt) ?? Date()
    }

    var session: AgentUsageWindow? { windows.first { $0.kind == .session } }
    var weekly: AgentUsageWindow? { windows.first { $0.kind == .weekly } }
    var monthly: AgentUsageWindow? {
        windows.first { if case .monthly = $0.kind { return true }; return false }
    }
    var modelWindows: [AgentUsageWindow] {
        windows.filter { if case .weeklyModel = $0.kind { return true }; return false }
    }

    /// The window closest to its limit — what the compact row leads with
    /// when it must pick one.
    var mostConstrained: AgentUsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }
}

/// Why a provider that IS running has no numbers to show. Rendered as a
/// muted footer row: silence with no explanation reads as a broken feature,
/// and the remedy is not guessable (a Mac reached over SSH or tssh refuses
/// to release Claude's keychain item to a detached session).
nonisolated enum AgentUsageUnavailableReason: Equatable, Sendable {
    case keychainLocked
    case credentialsUnreadable
    case signInExpired

    var shortLabel: String {
        switch self {
        case .keychainLocked:
            return String(
                localized: "Keychain locked",
                comment: "Agent usage unavailable reason")
        case .credentialsUnreadable:
            return String(
                localized: "Sign-in unreadable",
                comment: "Agent usage unavailable reason")
        case .signInExpired:
            return String(
                localized: "Sign-in expired",
                comment: "Agent usage unavailable reason")
        }
    }

    func detail(for provider: AgentUsageProvider) -> String {
        switch self {
        case .keychainLocked:
            if provider == .antigravity {
                return String(
                    localized: """
                        macOS will not release Antigravity's saved sign-in to a \
                        shell it did not start, so this connection cannot read \
                        it. Start tmux on that Mac once from its own desktop \
                        session and usage is read through the tmux server.
                        """,
                    comment: "Agent usage help when a remote Mac will not release Antigravity credentials")
            }
            if provider == .copilot {
                return String(
                    localized: """
                        macOS will not release Copilot's saved sign-in to a shell \
                        it did not start, so this connection cannot read it. \
                        Simplest fix: start tmux on that Mac once from its own \
                        desktop session, and usage is read through the tmux \
                        server. Signing in to Copilot in VS Code or JetBrains on \
                        that machine also works — those editors keep a readable \
                        sign-in file. Otherwise export GH_TOKEN on that host in \
                        ~/.profile, which is the file this check reads.
                        """,
                    comment: "Agent usage help when a remote Mac will not release Copilot credentials")
            }
            return String(
                localized: """
                    macOS will not release the agent's saved sign-in to a shell it \
                    did not start, so this connection cannot read it. Simplest \
                    fix: start tmux on that Mac once from its own desktop session, \
                    and usage is read through the tmux server. Otherwise export \
                    CLAUDE_CODE_OAUTH_TOKEN on that host in ~/.profile, which is \
                    the file this check reads (~/.zshrc is not read).
                    """,
                comment: "Agent usage help when a remote Mac will not release agent credentials")
        case .credentialsUnreadable:
            return String(
                localized: "The agent's saved sign-in could not be read on that host.",
                comment: "Agent usage unavailable detail")
        case .signInExpired:
            if provider == .copilot {
                return String(
                    localized: """
                        GitHub rejected the saved sign-in, and GitHub tokens do \
                        not refresh on their own. Run `gh auth login` or sign in \
                        to Copilot again on that host, then Refresh.
                        """,
                    comment: "Agent usage help when a Copilot sign-in has expired")
            }
            return String(
                localized: """
                    The saved sign-in has expired. It refreshes by itself the next \
                    time the agent runs, and usage reappears then.
                    """,
                comment: "Agent usage help when an agent sign-in has expired")
        }
    }
}

nonisolated enum AgentUsageWindowLength {
    static let session: TimeInterval = 5 * 60 * 60
    static let weekly: TimeInterval = 7 * 24 * 60 * 60
}

/// Parser for `GET api.anthropic.com/api/oauth/usage`.
nonisolated enum ClaudeUsageResponse {

    /// Builds windows from the legacy top-level objects, then folds in the
    /// per-model entries from `limits[]`. Newer responses null the legacy
    /// fields, so `limits[]` also backfills session/weekly. Tolerant of
    /// unknown kinds by design; nil only when NOTHING parsed, so a shape
    /// drift reads as a failed fetch rather than "0% used".
    static func parse(_ data: Data) -> [AgentUsageWindow]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var windows: [AgentUsageWindow] = []

        func legacyWindow(_ key: String, kind: AgentUsageWindow.Kind, length: TimeInterval) {
            guard let object = root[key] as? [String: Any],
                  let used = object["utilization"] as? Double else { return }
            windows.append(AgentUsageWindow(
                kind: kind,
                usedPercent: used,
                resetsAt: isoDate(object["resets_at"]),
                windowLength: length))
        }
        legacyWindow("five_hour", kind: .session, length: AgentUsageWindowLength.session)
        legacyWindow("seven_day", kind: .weekly, length: AgentUsageWindowLength.weekly)
        legacyWindow("seven_day_opus", kind: .weeklyModel("Opus"),
                     length: AgentUsageWindowLength.weekly)
        legacyWindow("seven_day_sonnet", kind: .weeklyModel("Sonnet"),
                     length: AgentUsageWindowLength.weekly)

        for entry in root["limits"] as? [[String: Any]] ?? [] {
            guard let kindName = entry["kind"] as? String,
                  let percent = entry["percent"] as? Double else { continue }
            let resetsAt = isoDate(entry["resets_at"])

            let kind: AgentUsageWindow.Kind
            let length: TimeInterval
            switch kindName {
            case "session":
                kind = .session; length = AgentUsageWindowLength.session
            case "weekly_all":
                kind = .weekly; length = AgentUsageWindowLength.weekly
            case "weekly_scoped":
                let scope = entry["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = model?["display_name"] as? String ?? "Model"
                // The card label wants the family, not the full marketing
                // name: "Fable 5" -> "Fable", matching the CLI's own list.
                kind = .weeklyModel(String(name.split(separator: " ").first ?? "Model"))
                length = AgentUsageWindowLength.weekly
            default:
                continue
            }
            // Legacy fields win when both carry the same window.
            guard !windows.contains(where: { $0.kind == kind }) else { continue }
            windows.append(AgentUsageWindow(
                kind: kind, usedPercent: percent, resetsAt: resetsAt, windowLength: length))
        }

        return windows.isEmpty ? nil : windows
    }

    /// `resets_at` is ISO8601, with or without fractional seconds.
    private static func isoDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

/// Parser for `GET chatgpt.com/backend-api/wham/usage`.
nonisolated enum CodexUsageResponse {

    struct Parsed: Equatable, Sendable {
        var windows: [AgentUsageWindow]
        var creditsBalance: Double?
        var planType: String?
    }

    /// Body first; the `x-codex-*` response headers back-fill when the body
    /// shape drifts. Header names arrive lowercased by the caller.
    static func parse(_ data: Data, headers: [String: String]) -> Parsed? {
        var windows: [AgentUsageWindow] = []
        var credits: Double?
        var plan: String?

        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Two body shapes are in the wild: the dashboard's `rate_limit`
            // with `primary_window`/`secondary_window`, and the CLI-styled
            // `rate_limits` with `primary`/`secondary`.
            let rateLimit = (root["rate_limit"] ?? root["rate_limits"]) as? [String: Any]

            func firstObject(_ container: [String: Any]?, _ keys: [String]) -> [String: Any]? {
                keys.lazy.compactMap { container?[$0] as? [String: Any] }.first
            }

            if let primary = firstObject(rateLimit, ["primary_window", "primary"]),
               let parsed = parseWindow(primary, positionalKind: .session) {
                windows.append(parsed)
            }
            if let secondary = firstObject(rateLimit, ["secondary_window", "secondary"]),
               let parsed = parseWindow(secondary, positionalKind: .weekly),
               !windows.contains(where: { $0.kind == parsed.kind }) {
                windows.append(parsed)
            }

            // Model-scoped lanes (e.g. "GPT-5.3-Codex-Spark") ride along
            // like Claude's weekly_scoped limits.
            for entry in root["additional_rate_limits"] as? [[String: Any]] ?? [] {
                guard let name = entry["limit_name"] as? String,
                      let entryLimit = entry["rate_limit"] as? [String: Any],
                      let object = firstObject(entryLimit, ["primary_window", "primary"]),
                      var parsed = parseWindow(object, positionalKind: .weekly)
                else { continue }
                // "GPT-5.3-Codex-Spark" -> "Spark".
                parsed.kind = .weeklyModel(String(name.split(separator: "-").last ?? "Model"))
                guard !windows.contains(where: { $0.kind == parsed.kind }) else { continue }
                windows.append(parsed)
            }

            credits = creditsBalance(root["credits"])
            plan = root["plan_type"] as? String
        }

        func headerWindow(_ name: String, kind: AgentUsageWindow.Kind, length: TimeInterval) {
            guard !windows.contains(where: { $0.kind == kind }),
                  let raw = headers[name], let used = Double(raw) else { return }
            windows.append(AgentUsageWindow(
                kind: kind, usedPercent: used, resetsAt: nil, windowLength: length))
        }
        headerWindow("x-codex-primary-used-percent", kind: .session,
                     length: AgentUsageWindowLength.session)
        headerWindow("x-codex-secondary-used-percent", kind: .weekly,
                     length: AgentUsageWindowLength.weekly)
        if credits == nil, let raw = headers["x-codex-credits-balance"] {
            credits = Double(raw)
        }

        guard !windows.isEmpty else { return nil }
        return Parsed(windows: windows, creditsBalance: credits, planType: plan)
    }

    /// Anything longer than a few hours is a long-horizon lane rather than
    /// a rolling session window.
    private static let sessionLengthCeiling: TimeInterval = 8 * 60 * 60

    /// One window object, from either body shape.
    ///
    /// `limit_window_seconds` is authoritative for BOTH the length and the
    /// classification: Codex lanes vary by plan, and a Pro account's
    /// `primary_window` is a 7-DAY window, not a 5-hour one. Position alone
    /// is a bad label, and assuming a nominal 5h length against a reset
    /// date six days out put the window's start in the future — which the
    /// pace math correctly rejected, hiding the marker entirely.
    private static func parseWindow(
        _ object: [String: Any],
        positionalKind: AgentUsageWindow.Kind
    ) -> AgentUsageWindow? {
        guard let used = object["used_percent"] as? Double else { return nil }

        let length = (object["limit_window_seconds"] as? Double)
            ?? (object["window_minutes"] as? Double).map { $0 * 60 }

        // Both forms are raw numbers straight off the wire, so both are
        // bounded before becoming a Date: an out-of-range stamp reaches the
        // reset countdown, whose `Int(interval / 60)` traps on it.
        var resetsAt: Date?
        if let epoch = (object["reset_at"] ?? object["resets_at"]) as? Double {
            resetsAt = AgentUsageEpoch.date(seconds: epoch)
        } else if let after = (object["reset_after_seconds"]
                               ?? object["resets_in_seconds"]) as? Double {
            resetsAt = AgentUsageEpoch.interval(seconds: after)
                .map { Date().addingTimeInterval($0) }
        }

        let kind: AgentUsageWindow.Kind = length.map {
            $0 <= sessionLengthCeiling ? .session : .weekly
        } ?? positionalKind
        let nominal = kind == .session
            ? AgentUsageWindowLength.session
            : AgentUsageWindowLength.weekly

        return AgentUsageWindow(
            kind: kind,
            usedPercent: used,
            resetsAt: resetsAt,
            windowLength: length ?? nominal)
    }

    /// `balance` is a JSON STRING ("0") on live accounts and a number in
    /// older payloads.
    private static func creditsBalance(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any] else { return nil }
        if let number = object["balance"] as? Double { return number }
        if let string = object["balance"] as? String { return Double(string) }
        return nil
    }
}

/// Parser for `GET api.github.com/copilot_internal/user`.
nonisolated enum CopilotUsageResponse {

    struct Parsed: Equatable, Sendable {
        var windows: [AgentUsageWindow]
        var planLabel: String?
    }

    /// Copilot meters by calendar month: `quota_snapshots` carries the
    /// metered lanes and `quota_reset_date` names the day they refill.
    /// Lanes are iterated GENERICALLY because GitHub has re-denominated
    /// once already (premium requests -> AI Credits, June 2026) and the
    /// internal endpoint's key for the credits lane is undocumented: any
    /// metered lane renders, a credits-named lane wins the headline over
    /// `premium_interactions`, and unknown keys ride along scoped. nil only
    /// when `quota_snapshots` is missing entirely, so a shape drift reads
    /// as a failed fetch rather than "0% used". An account whose lanes are
    /// all `unlimited` parses to an EMPTY window list — that is a valid
    /// answer (nothing to meter, rendered "Unlimited"), not a failure to
    /// loop backoff on. Empty is only ever produced by an EXPLICIT
    /// `unlimited: true` lane: an empty `quota_snapshots`, all-husk lanes,
    /// or lanes whose fields did not parse yield nil instead — presenting
    /// an unrecognized shape as "Unlimited" would hide real limits.
    static func parse(_ data: Data) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = root["quota_snapshots"] as? [String: Any] else {
            return nil
        }

        // The _utc variant is exact; the bare one is date-only.
        let resetsAt = isoResetDate(root["quota_reset_date_utc"])
            ?? resetDate(root["quota_reset_date"])
        // True calendar length, not a nominal 30d: a nominal length against
        // the real reset date puts the window's start in the future for part
        // of a 31-day month, and the pace math would (correctly) hide the
        // tick. Same lesson the Codex parser already learned.
        var windowLength: TimeInterval?
        if let resetsAt {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            if let start = calendar.date(byAdding: .month, value: -1, to: resetsAt) {
                windowLength = resetsAt.timeIntervalSince(start)
            }
        }

        // June 2026 credits billing: flagged per lane and at the root.
        // Under it the "chat" lane IS the AI-credits pool (chat, agents
        // and review all draw from it; verified against a live Free
        // account), so it takes the credits label and the headline.
        let rootTokenBilling = root["token_based_billing"] as? Bool ?? false

        struct Lane {
            var key: String
            var label: String
            var isCredits: Bool
            var used: Double
            var remaining: Double?
            var entitlement: Double?
        }
        var lanes: [Lane] = []
        var sawUnlimited = false
        var sawUnparseable = false
        for (key, value) in snapshots {
            guard let object = value as? [String: Any] else {
                sawUnparseable = true
                continue
            }
            if object["unlimited"] as? Bool == true {
                sawUnlimited = true
                continue
            }
            // Credits-era responses keep the legacy premium_interactions
            // lane as an all-zeros husk with `has_quota: false`. Reading
            // its 0% remaining as "100% used" is exactly the false alarm
            // to avoid, so a lane that says it has no quota — or has
            // literally nothing to meter — renders nothing.
            if object["has_quota"] as? Bool == false { continue }

            let entitlement = object["entitlement"] as? Double
            let remaining = (object["quota_remaining"] ?? object["remaining"]) as? Double
            if entitlement == 0, (remaining ?? 0) == 0 { continue }

            let used: Double
            if let percentRemaining = object["percent_remaining"] as? Double {
                used = 100 - percentRemaining
            } else if let entitlement, entitlement > 0, let remaining {
                used = 100 * (1 - remaining / entitlement)
            } else {
                // A metered, non-husk lane whose numbers did not parse is
                // a real limit this shape hides, not an absent one.
                sawUnparseable = true
                continue
            }

            let tokenBilling = object["token_based_billing"] as? Bool ?? rootTokenBilling
            let isCredits = key.contains("credit") || (key == "chat" && tokenBilling)
            let label = isCredits
                ? String(localized: "Credits", comment: "Copilot usage quota label")
                : laneLabel(key)
            // Overage pushes past 100 and should read as depleted; below
            // zero is only ever noise.
            lanes.append(Lane(
                key: key,
                label: label,
                isCredits: isCredits,
                used: max(0, used),
                remaining: remaining,
                entitlement: entitlement))
        }

        // Empty windows may claim "Unlimited" only when EVERY meaningful
        // lane said so explicitly: nothing declared unlimited is an
        // unrecognized shape, and one unlimited lane must not vouch for a
        // metered lane whose fields failed to parse.
        if lanes.isEmpty, !sawUnlimited || sawUnparseable { return nil }

        // The headline: credits when present, else premium requests, else
        // the single metered lane a future shape might carry. Everything
        // else rides along scoped, known lanes ahead of unknown ones.
        let headlineIndex = lanes.firstIndex { $0.isCredits }
            ?? lanes.firstIndex { $0.key == "premium_interactions" }
            ?? (lanes.count == 1 ? 0 : nil)

        let laneOrder = ["premium_interactions", "chat", "completions"]
        let sorted = lanes.enumerated().sorted { lhs, rhs in
            func rank(_ entry: (offset: Int, element: Lane)) -> (Int, Int, String) {
                let known = laneOrder.firstIndex(of: entry.element.key)
                return (entry.offset == headlineIndex ? 0 : 1,
                        known ?? laneOrder.count,
                        entry.element.key)
            }
            return rank(lhs) < rank(rhs)
        }

        let windows = sorted.map { entry in
            AgentUsageWindow(
                kind: entry.offset == headlineIndex
                    ? .monthly(entry.element.label)
                    : .monthlyScoped(entry.element.label),
                usedPercent: entry.element.used,
                resetsAt: resetsAt,
                windowLength: windowLength,
                remainingCount: entry.element.remaining,
                entitlement: entry.element.entitlement)
        }

        return Parsed(
            windows: windows,
            planLabel: planLabel(
                sku: root["access_type_sku"] as? String,
                plan: root["copilot_plan"] as? String))
    }

    /// "premium_interactions" -> "Premium requests", "ai_credits_snapshot"
    /// -> "Credits", unknown keys prettified from snake_case.
    private static func laneLabel(_ key: String) -> String {
        if key.contains("credit") {
            return String(localized: "Credits", comment: "Copilot usage quota label")
        }
        switch key {
        case "premium_interactions":
            return String(localized: "Premium requests", comment: "Copilot usage quota label")
        case "chat":
            return String(localized: "Chat", comment: "Copilot usage quota label")
        case "completions":
            return String(localized: "Completions", comment: "Copilot usage quota label")
        default:
            // Future provider-defined lane names cannot be extracted into
            // the catalog because they are not known at compile time.
            let words = key.split(separator: "_").joined(separator: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// `quota_reset_date_utc` is full ISO8601 with fractional seconds.
    private static func isoResetDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    /// `quota_reset_date` is a bare "yyyy-MM-dd" on the provider's clock;
    /// UTC midnight keeps the countdown identical on every device looking
    /// at the same account.
    private static func resetDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    /// "copilot_pro" / "individual" -> "Pro", etc. The SKU is the more
    /// specific of the two fields, so it wins when both are present. Max
    /// and Student arrived with the June 2026 plan lineup.
    private static func planLabel(sku: String?, plan: String?) -> String? {
        for raw in [sku, plan] {
            guard let value = raw?.lowercased(), !value.isEmpty else { continue }
            if value.contains("pro_plus") || value.contains("pro+") { return "Pro+" }
            if value.contains("enterprise") { return "Enterprise" }
            if value.contains("business") { return "Business" }
            if value.contains("student") { return "Student" }
            if value.contains("free") { return "Free" }
            if value.contains("max") { return "Max" }
            if value.contains("pro") || value.contains("individual") { return "Pro" }
        }
        guard let plan, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }
}

/// Visual status banding, on percent REMAINING (ClaudeBar thresholds).
nonisolated enum AgentUsageBand: Equatable, Sendable {
    case healthy
    case warning
    case critical
    case depleted

    static func band(usedPercent: Double) -> AgentUsageBand {
        let remaining = 100 - usedPercent
        switch remaining {
        case ...0: return .depleted
        case ..<20: return .critical
        case ..<50: return .warning
        default: return .healthy
        }
    }
}

nonisolated enum AgentUsagePace {
    /// Where usage would sit right now at perfectly even burn across the
    /// window: the pace tick's position, as a 0...1 fraction of the bar.
    /// nil when the window has no reset date or nominal length.
    static func expectedUsedFraction(window: AgentUsageWindow, now: Date) -> Double? {
        guard let resetsAt = window.resetsAt, let length = window.windowLength,
              length > 0 else { return nil }
        let windowStart = resetsAt.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed >= 0, elapsed <= length else { return nil }
        return elapsed / length
    }
}

nonisolated enum AgentUsageFormat {

    /// A count derived from remote-sourced arithmetic, saturated into Int
    /// rather than trapping.
    ///
    /// Parsing bounds these values where they enter, but that only covers
    /// what this build parsed. This keeps the formatters safe whatever
    /// reaches them -- a snapshot an older build persisted, or a field a
    /// future parser forgets to bound.
    static func saturatingInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        // Well inside Int64 with room for the callers' own division.
        let ceiling = 1e15
        return Int(max(-ceiling, min(ceiling, value)))
    }

    /// "5h 12% · 7d 34%" — the footer row's trailing text.
    static func compactLine(windows: [AgentUsageWindow]) -> String {
        windows
            .filter { !$0.kind.isScoped }
            .map {
                // Both halves are already localized on their own (the label
                // through String(localized:), the percent through the format
                // style), so the pair needs no catalog key of its own.
                "\($0.shortLabel) \($0.displayPercent.formatted(.percent))"
            }
            .joined(separator: " · ")
    }

    /// "Resets in 2d 5h" / "Resets in 3h 12m" / "Resets in 45m".
    static func resetCountdown(until resetsAt: Date, now: Date) -> String {
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else {
            return String(localized: "Resets soon", comment: "Agent usage reset time")
        }
        let minutes = saturatingInt(interval / 60)
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let mins = minutes % 60
        if days > 0 {
            return String(
                localized: "Resets in \(days)d \(hours)h",
                comment: "Agent usage reset time in days and hours")
        }
        if hours > 0 {
            return String(
                localized: "Resets in \(hours)h \(mins)m",
                comment: "Agent usage reset time in hours and minutes")
        }
        if mins > 0 {
            return String(
                localized: "Resets in \(mins)m",
                comment: "Agent usage reset time in minutes")
        }
        return String(localized: "Resets soon", comment: "Agent usage reset time")
    }

    /// "retry in 12m" / "retry in 1h 5m" — why Refresh is unavailable.
    static func retryCountdown(until: Date, now: Date) -> String {
        let seconds = max(0, until.timeIntervalSince(now))
        let minutes = saturatingInt(ceil(seconds / 60))
        if minutes < 1 {
            return String(localized: "retry shortly", comment: "Agent usage rate-limit retry time")
        }
        if minutes < 60 {
            return String(
                localized: "retry in \(minutes)m",
                comment: "Agent usage rate-limit retry time in minutes")
        }
        return String(
            localized: "retry in \(minutes / 60)h \(minutes % 60)m",
            comment: "Agent usage rate-limit retry time in hours and minutes")
    }

    /// "Updated just now" / "Updated 23m ago" / "Updated 2h ago".
    static func updatedAgo(fetchedAt: Date, now: Date) -> String {
        let minutes = saturatingInt(now.timeIntervalSince(fetchedAt) / 60)
        if minutes < 1 {
            return String(localized: "Updated just now", comment: "Agent usage last-updated time")
        }
        if minutes < 60 {
            return String(
                localized: "Updated \(minutes)m ago",
                comment: "Agent usage last-updated time in minutes")
        }
        let hours = minutes / 60
        if hours < 24 {
            return String(
                localized: "Updated \(hours)h ago",
                comment: "Agent usage last-updated time in hours")
        }
        return String(
            localized: "Updated \(hours / 24)d ago",
            comment: "Agent usage last-updated time in days")
    }
}
