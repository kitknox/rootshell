//
//  AgentUsageAPIClient.swift
//  rootshell
//
//  Stateless HTTP for the usage endpoints. All fetch POLICY — floors,
//  Retry-After handling, backoff — lives in AgentUsageCenter and
//  AgentUsageAccountState; this file only makes one request and types the
//  outcome.
//
//  Nothing here logs. Tokens ride the Authorization header and nowhere
//  else; callers log provider + status class only.
//

import Foundation

nonisolated enum AgentUsageAPIError: Error {
    /// 401/403: the token went stale — re-probe the host, never refresh.
    case unauthorized
    /// 429. Seconds may be 0 or absent; the policy layer rejects those.
    case rateLimited(retryAfterSeconds: Double?)
    /// 2xx with a body that did not parse, or an unexpected status.
    case badResponse
    case transport(Error)
}

nonisolated enum AgentUsageAPIClient {

    /// Ephemeral on purpose: no cookies, no URL cache, nothing about these
    /// requests persisted anywhere.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    static func fetchClaudeUsage(accessToken: String) async throws -> [AgentUsageWindow] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The beta header is what admits an OAuth bearer token at all.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await perform(request)
        try checkStatus(response)
        guard let windows = ClaudeUsageResponse.parse(data) else {
            throw AgentUsageAPIError.badResponse
        }
        return windows
    }

    static func fetchCodexUsage(
        accessToken: String,
        accountID: String?
    ) async throws -> CodexUsageResponse.Parsed {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await perform(request)
        try checkStatus(response)
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        guard let parsed = CodexUsageResponse.parse(data, headers: headers) else {
            throw AgentUsageAPIError.badResponse
        }
        return parsed
    }

    static func fetchCopilotUsage(token: String) async throws -> CopilotUsageResponse.Parsed {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.httpMethod = "GET"
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The editor headers VS Code sends; the internal endpoint has been
        // seen filtering bare user agents.
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("vscode/1.99.0", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")

        let (data, response) = try await perform(request)
        // GitHub quirks ahead of the shared classifier: the endpoint 404s
        // for token types with no Copilot visibility (treat as unauthorized
        // so the digest blacklist retires the token instead of retrying it
        // every floor), and 403 doubles as "rate limited" when the
        // x-ratelimit budget is spent.
        if response.statusCode == 404 {
            throw AgentUsageAPIError.unauthorized
        }
        if response.statusCode == 403 {
            // Primary limit spends the x-ratelimit budget; secondary
            // (abuse) limits can 403 with budget REMAINING and only a
            // Retry-After. Both are throttling, not a dead token — falling
            // through to `.unauthorized` would blacklist a valid one.
            let retryAfter = retryAfterSeconds(response)
            let budgetSpent =
                response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            if budgetSpent || retryAfter != nil {
                let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset")
                    .flatMap(Double.init)
                    .map { max(0, $0 - Date().timeIntervalSince1970) }
                throw AgentUsageAPIError.rateLimited(
                    retryAfterSeconds: retryAfter ?? reset)
            }
        }
        try checkStatus(response)
        guard let parsed = CopilotUsageResponse.parse(data) else {
            throw AgentUsageAPIError.badResponse
        }
        return parsed
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AgentUsageAPIError.badResponse
            }
            return (data, http)
        } catch let error as AgentUsageAPIError {
            throw error
        } catch {
            throw AgentUsageAPIError.transport(error)
        }
    }

    private static func checkStatus(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw AgentUsageAPIError.unauthorized
        case 429:
            throw AgentUsageAPIError.rateLimited(
                retryAfterSeconds: retryAfterSeconds(response))
        default:
            throw AgentUsageAPIError.badResponse
        }
    }

    /// RFC 7231 Retry-After: integer seconds or an HTTP-date. Returns the
    /// raw value — including 0 — and lets the policy layer decide; it knows
    /// this endpoint sends `Retry-After: 0` while still throttling.
    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> Double? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = Double(raw) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return date.timeIntervalSinceNow
        }
        return nil
    }
}
