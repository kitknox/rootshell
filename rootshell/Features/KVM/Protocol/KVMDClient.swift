//
//  KVMDClient.swift
//  rootshell
//
//  REST calls to a kvmd device (GL.iNet Comet). The token from login rides
//  every request as kvmd's `Token` header; WebSocket requests also carry
//  it as `auth_token` because nginx authorizes some routes by query only.
//

import Foundation
import os

@MainActor
final class KVMDClient {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KVM")

    nonisolated struct Response: Sendable {
        let status: Int
        let body: Data

        var result: [String: Any] {
            KVMDJSON.dict(KVMDJSON.object(from: body)?["result"]) ?? [:]
        }

        var errorMessage: String? {
            result["error_msg"] as? String
        }
    }

    let baseURL: URL
    let session: URLSession
    var token: String?

    init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Auth

    /// With TOTP enabled, kvmd reads the code from the password's last six digits.
    func login(user: String, password: String, oneTimeCode: String?) async throws -> KVMDLoginOutcome {
        let passwd = password + (oneTimeCode ?? "")
        let response = try await send(
            "POST", "/api/auth/login",
            form: ["user": user, "passwd": passwd, "expire": "0"],
            authorized: false)
        let outcome = try KVMDLoginOutcome.parse(status: response.status, body: response.body)
        if case .token(let token) = outcome { self.token = token }
        return outcome
    }

    func completeTwoStep(token twoStepToken: String) async throws -> KVMDLoginOutcome {
        let response = try await send(
            "POST", "/api/auth/two_step_complete",
            form: ["two_step_token": twoStepToken],
            authorized: false)
        if response.status == 403 { throw KVMDError.twoStepExpired }
        let outcome = try KVMDLoginOutcome.parse(status: response.status, body: response.body)
        if case .token(let token) = outcome { self.token = token }
        return outcome
    }

    /// Only a definite answer skips the code prompt: guessing "off" would send
    /// the password alone and count toward the device's lockout.
    func twoFactorEnabled() async throws -> Bool {
        let response = try await send("GET", "/api/2fa/is_enabled", authorized: false)
        switch response.status {
        case 200:
            guard let enabled = KVMDJSON.bool(response.result["enabled"]) else {
                throw KVMDError.protocolError("unreadable two-factor status")
            }
            return enabled
        case 404:
            // kvmd builds without GL.iNet's 2FA API.
            return false
        default:
            throw KVMDError.http(status: response.status, message: response.errorMessage)
        }
    }

    func logout() async {
        guard token != nil else { return }
        _ = try? await send("POST", "/api/auth/logout", timeout: 3)
        token = nil
    }

    // MARK: Calls

    /// The `result` of a successful call. 401/403 mean the token is gone.
    @discardableResult
    func call(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 15
    ) async throws -> [String: Any] {
        let response = try await send(method, path, query: query, body: body, timeout: timeout)
        switch response.status {
        case 200:
            return response.result
        case 401, 403:
            throw KVMDError.unauthorized
        default:
            throw KVMDError.http(status: response.status, message: response.errorMessage)
        }
    }

    /// Types `text` on the remote computer using a kvmd keymap. Returns once
    /// typing finishes; cancelling the calling task stops the typing.
    func printText(_ text: String, keymap: String) async throws {
        try await call(
            "POST", "/api/hid/print",
            query: ["limit": "0", "keymap": keymap],
            body: Data(text.utf8),
            // kvmd types about 200 events per second and replies at the end.
            timeout: 30 + Double(text.count) / 50)
    }

    // MARK: WebSocket

    func webSocketRequest(path: String, query: [String: String] = [:]) -> URLRequest {
        var query = query
        if let token { query["auth_token"] = token }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.path = path
        components.percentEncodedQuery = Self.encode(query)
        var request = URLRequest(url: components.url!)
        if let token { request.setValue(token, forHTTPHeaderField: "Token") }
        request.timeoutInterval = 15
        return request
    }

    // MARK: Transport

    private func send(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        form: [String: String]? = nil,
        body: Data? = nil,
        authorized: Bool = true,
        timeout: TimeInterval = 15
    ) async throws -> Response {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.percentEncodedQuery = query.isEmpty ? nil : Self.encode(query)
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized, let token {
            request.setValue(token, forHTTPHeaderField: "Token")
        }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.encode(form).utf8)
        } else if let body {
            request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                Self.logger.info("KVM \(method, privacy: .public) \(path, privacy: .public) -> \(status)")
            }
            return Response(status: status, body: data)
        } catch let error as URLError where error.code == .timedOut {
            throw KVMDError.timedOut
        }
    }

    /// RFC 3986 unreserved; `alphanumerics` would pass non-ASCII letters raw.
    private nonisolated static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    nonisolated static func encode(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { key in
            let value = fields[key] ?? ""
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }
}
