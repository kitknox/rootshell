//
//  AgentUsageCredentials.swift
//  rootshell
//
//  Typed views over the credential JSON a usage probe reads off a host,
//  plus the account key that scopes the usage cache. Tokens parsed here
//  live in AgentUsageCenter memory only: never persisted, never logged.
//

import Foundation

/// Claude Code's stored OAuth grant, from `.credentials.json`, the macOS
/// Keychain item, or a synthesized env-token payload.
nonisolated struct ClaudeCredentials: Equatable, Sendable {
    var accessToken: String
    /// Absent for setup-tokens, which carry no expiry.
    var expiresAt: Date?
    /// "max", "pro", "api", ... (older CLIs: "claude_max"), the CLI's own label.
    var subscriptionType: String?
    /// "default_claude_max_20x", ...; the only field that tells Ultra from Max.
    var rateLimitTier: String?

    /// Expired tokens are not worth an API call; the running CLI refreshes
    /// its own credentials, so a re-probe is the fix, not a refresh.
    func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    var planLabel: String? {
        switch subscriptionType?.lowercased() {
        case "claude_ultra", "ultra": return "Ultra"
        // Ultra is the renamed Max 20x; its grants can still say "max".
        case "claude_max", "max":
            return rateLimitTier?.lowercased().contains("20x") == true ? "Ultra" : "Max"
        case "claude_pro", "pro": return "Pro"
        case "api": return "API"
        default: return subscriptionType
        }
    }

    static func parse(json: String) -> ClaudeCredentials? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }

        var credentials = ClaudeCredentials(accessToken: token)
        // Milliseconds since epoch, per the CLI's own writer.
        if let ms = oauth["expiresAt"] as? Double {
            credentials.expiresAt = Date(timeIntervalSince1970: ms / 1000)
        }
        credentials.subscriptionType = oauth["subscriptionType"] as? String
        credentials.rateLimitTier = oauth["rateLimitTier"] as? String
        return credentials
    }
}

/// Codex's stored OAuth grant, from `auth.json`.
nonisolated struct CodexCredentials: Equatable, Sendable {
    var accessToken: String
    /// The ChatGPT account the token belongs to; sent as a request header.
    var accountID: String?
    /// "plus", "pro", "free" — from the id_token claims.
    var planType: String?

    var planLabel: String? {
        guard let planType, !planType.isEmpty else { return nil }
        return planType.prefix(1).uppercased() + planType.dropFirst()
    }

    static func parse(json: String) -> CodexCredentials? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty
        else { return nil }

        var credentials = CodexCredentials(accessToken: token)
        // The id_token claims are the authoritative account identity; the
        // top-level account_id is the fallback when the JWT does not decode.
        if let idToken = tokens["id_token"] as? String,
           let claims = AgentUsageJWT.claims(of: idToken),
           let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            credentials.accountID = auth["chatgpt_account_id"] as? String
            credentials.planType = auth["chatgpt_plan_type"] as? String
        }
        if credentials.accountID == nil {
            credentials.accountID = tokens["account_id"] as? String
        }
        return credentials
    }
}

/// A GitHub token with Copilot access, from an editor's `apps.json` /
/// `hosts.json`, Copilot CLI's plaintext config, the macOS Keychain item,
/// `gh auth token`, or an exported env token (the latter three synthesized
/// or raw — see the probe script).
nonisolated struct CopilotCredentials: Equatable, Sendable {
    var token: String
    /// GitHub login, when the source carries one (apps.json / hosts.json).
    var login: String?

    /// A copilot payload carries EVERY credential source the host offered,
    /// `::CPSRC::`-separated in priority order. Splits, parses each chunk,
    /// and dedupes by token (the same account signed into an editor and gh
    /// yields the same token twice; the first copy keeps its login).
    static func parseAll(json: String) -> [CopilotCredentials] {
        var chunks: [String] = []
        var current: [String] = []
        var sawSeparator = false
        for line in json.split(whereSeparator: \.isNewline) {
            if line.trimmingCharacters(in: .whitespaces)
                == AgentUsageProbeCommand.copilotSourceSeparator {
                sawSeparator = true
                if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(String(line))
            }
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        // Separator-less payloads (a hand-fed token, older captures) are
        // one chunk.
        if !sawSeparator { chunks = [json] }

        var indexByToken: [String: Int] = [:]
        var candidates: [CopilotCredentials] = []
        for chunk in chunks {
            // Every structured entry is a candidate — apps.json can carry
            // several app-scoped sign-ins, and returning only the first
            // stranded the rest behind one rejected token.
            var parsed = structuredCandidates(json: chunk)
            if parsed.isEmpty, let token = firstTokenMatch(in: chunk) {
                parsed = [CopilotCredentials(token: token, login: nil)]
            }
            for candidate in parsed {
                if let existing = indexByToken[candidate.token] {
                    // Bare sources (env, keychain, gh) rank ahead of the
                    // editor files but carry no login; when a later copy of
                    // the SAME token names the account, enrich the kept
                    // candidate in place — dropping the login demoted the
                    // account key to host-based, splitting one account
                    // across hosts into separately-polled rows.
                    if candidates[existing].login == nil, let login = candidate.login {
                        candidates[existing].login = login
                    }
                } else {
                    indexByToken[candidate.token] = candidates.count
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    /// The candidate to fetch with: the first whose token has not already
    /// been refused by the provider. Rejections accumulate across probes —
    /// checking only the LATEST rejection made selection ping-pong between
    /// two dead candidates without ever reaching a live third. When every
    /// candidate has been refused, the first is returned anyway — the
    /// caller's digest check marks the slot unusable, which is the honest
    /// state.
    static func select(
        from candidates: [CopilotCredentials],
        rejectedDigests: Set<String>
    ) -> CopilotCredentials? {
        guard !rejectedDigests.isEmpty else { return candidates.first }
        return candidates.first { !rejectedDigests.contains(AgentUsageTokenDigest.of($0.token)) }
            ?? candidates.first
    }

    /// Two strategies, one entry point. The structured pass covers
    /// apps.json (`"github.com:Iv1.xxx"` keys), hosts.json (`"github.com"`
    /// keys), and the probe's synthesized shape. The pattern pass covers
    /// Copilot CLI's config blob and raw keychain content, whose token key
    /// is undocumented — GitHub token prefixes are distinctive enough to
    /// extract by shape.
    static func parse(json: String) -> CopilotCredentials? {
        if let first = structuredCandidates(json: json).first {
            return first
        }
        if let token = firstTokenMatch(in: json) {
            return CopilotCredentials(token: token, login: nil)
        }
        return nil
    }

    /// Every github.com entry of a structured credential file, plain host
    /// key ranked ahead of app-scoped ones, ties broken by key so the
    /// order is stable across probes. GHE hosts are deliberately skipped:
    /// the usage endpoint lives on api.github.com.
    private static func structuredCandidates(json: String) -> [CopilotCredentials] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var candidates: [CopilotCredentials] = []
        let keys = root.keys.sorted { ($0.count, $0) < ($1.count, $1) }
        for key in keys where key == "github.com" || key.hasPrefix("github.com:") {
            guard let entry = root[key] as? [String: Any],
                  let token = entry["oauth_token"] as? String,
                  !token.isEmpty else { continue }
            let user = entry["user"] as? String
            candidates.append(CopilotCredentials(
                token: token,
                login: (user?.isEmpty == false) ? user : nil))
        }
        return candidates
    }

    private static func firstTokenMatch(in text: String) -> String? {
        let pattern = "gh[a-z]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{20,}"
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }
}

/// Non-reversible fingerprint of a token, used only to answer "did the same
/// token come back?" — never logged, never persisted, never sent anywhere.
/// A rejected token that reappears must not be retried against the provider,
/// or a stale credential file turns into a 401 every retry interval.
nonisolated enum AgentUsageTokenDigest {
    static func of(_ token: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in token.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Unverified JWT payload decoding. Nothing here is TRUSTED — the claims
/// only provide a stable identity string and a plan label, and the token is
/// sent to its own issuer either way.
nonisolated enum AgentUsageJWT {
    static func claims(of token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return claims
    }
}

/// Identity of the SUBSCRIPTION a credential belongs to. The usage cache is
/// keyed by this so the same account signed in on two hosts polls the
/// rate-limited endpoint once, not twice.
nonisolated enum AgentUsageAccountKey {

    static func claude(_ credentials: ClaudeCredentials, hostKey: String) -> String {
        // Some Claude access tokens are JWTs whose `sub` names the account,
        // which dedupes one account across hosts. Live `sk-ant-oat01-…`
        // tokens are NOT JWTs, so most of the time the host fallback runs.
        if let claims = AgentUsageJWT.claims(of: credentials.accessToken),
           let sub = claims["sub"] as? String, !sub.isEmpty {
            return "claude:\(sub)"
        }
        return "claude@\(hostKey)"
    }

    static func codex(_ credentials: CodexCredentials, hostKey: String) -> String {
        if let accountID = credentials.accountID, !accountID.isEmpty {
            return "codex:\(accountID)"
        }
        return "codex@\(hostKey)"
    }

    static func copilot(_ credentials: CopilotCredentials, hostKey: String) -> String {
        // GitHub tokens are opaque, never JWTs; only the editor credential
        // files name the account. Elsewhere the host fallback applies.
        if let login = credentials.login, !login.isEmpty {
            return "copilot:\(login)"
        }
        return "copilot@\(hostKey)"
    }

    // The fallback keys on the HOST rather than on a hash of the token.
    //
    // A token hash looked more precise and was strictly worse: the CLI
    // rotates its access token roughly hourly, so the key changed every
    // rotation — orphaning the persisted snapshot, resetting the fetch
    // clock, and churning the cache with one dead entry per refresh. It
    // never bought the cross-host dedupe it was there for either, since two
    // hosts signed into one account still hold DIFFERENT token strings and
    // therefore different hashes. Keying on the host is stable across
    // refreshes and dedupes exactly as well.
}
