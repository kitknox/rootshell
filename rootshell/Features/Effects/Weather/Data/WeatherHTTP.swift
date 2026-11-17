// WeatherHTTP.swift
// rootshell

#if !CHINA_BUILD
import Foundation

nonisolated enum WeatherFetchError: Error, Equatable {
    case notCovered                 // NWS 404 for a point outside its grids
    case unauthorized               // 401 or 403: a missing or rejected key
    case rateLimited(Double?)       // Retry-After seconds
    case http(Int)
    case network(Int)               // URLError code, without the URL and any key in it
    case decoding
    case unusable                   // a response without the fields we need
}

/// Conditional-request state for one URL.
nonisolated struct WeatherHTTPValidator: Codable, Equatable, Sendable {
    var lastModified: String?
    var etag: String?
    var expires: Date?
}

nonisolated enum WeatherHTTP {
    enum Response {
        case body(Data, WeatherHTTPValidator, HTTPURLResponse)
        case notModified(WeatherHTTPValidator)
    }

    /// The free services ask for an identifying User-Agent with a way to reach us.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "rootshell/\(version) (+https://rootshell.com)"
    }()

    /// A person's own User-Agent: printable ASCII only, so a pasted value
    /// can't break the header. Nil when nothing usable is left.
    static func sanitizedUserAgent(_ text: String?) -> String? {
        guard let text else { return nil }
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }))
        let trimmed = printable.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(256))
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// `userAgent` replaces ours, for a provider the person configured; "" sends an empty header.
    static func get(_ url: URL, accept: String, validator: WeatherHTTPValidator? = nil,
                    userAgent: String? = nil) async throws -> Response {
        var request = URLRequest(url: url)
        request.setValue(userAgent ?? Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let lastModified = validator?.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        if let etag = validator?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // A URLError's description carries the URL, and some keys travel in the query.
            throw error.code == .cancelled ? CancellationError() : WeatherFetchError.network(error.code.rawValue)
        }
        guard let http = response as? HTTPURLResponse else { throw WeatherFetchError.http(0) }
        let next = WeatherHTTPValidator(lastModified: http.value(forHTTPHeaderField: "Last-Modified") ?? validator?.lastModified,
                                        etag: http.value(forHTTPHeaderField: "ETag") ?? validator?.etag,
                                        expires: http.value(forHTTPHeaderField: "Expires").flatMap(httpDate))
        switch http.statusCode {
        case 200...299: return .body(data, next, http)
        case 304: return .notModified(next)
        case 401, 403: throw WeatherFetchError.unauthorized
        case 404: throw WeatherFetchError.notCovered
        case 429: throw WeatherFetchError.rateLimited(http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        default: throw WeatherFetchError.http(http.statusCode)
        }
    }

    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
#endif
