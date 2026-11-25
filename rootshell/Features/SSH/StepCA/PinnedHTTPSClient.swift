import Foundation
import Network
import Security

/// Minimal HTTPS/1.1 client over Network.framework for talking to a step-ca
/// server whose root is pinned by the user. URLSession can't do this for an
/// ATS-protected domain: ATS rejects a private root before a delegate gets a
/// say, and the app only has an ATS exception for ts.net. Network.framework
/// isn't subject to ATS, and its TLS verify block can anchor to the CA root.
nonisolated enum PinnedHTTPSClient {
    struct Response: Sendable {
        let status: Int
        let body: Data
    }

    enum TransportError: LocalizedError {
        case invalidURL
        case untrustedServer
        case timedOut
        case responseTooLarge
        case malformedResponse
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid CA URL"
            case .untrustedServer:
                return "The CA's TLS certificate doesn't chain to the pinned root or doesn't match the CA hostname"
            case .timedOut:
                return "The CA didn't respond in time"
            case .responseTooLarge:
                return "The CA response was too large"
            case .malformedResponse:
                return "The CA sent a malformed HTTP response"
            case .connectionFailed(let detail):
                return "Could not reach the CA: \(detail)"
            }
        }
    }

    private static let maxResponseSize = 4 * 1024 * 1024
    private static let timeout: TimeInterval = 30

    /// Sends `request`. With `anchorDER`, the server chain must lead to that
    /// root and match the hostname; without it any certificate is accepted
    /// (only for the bootstrap root download, which is checked by
    /// fingerprint afterwards). Cancelling the calling task cancels the
    /// connection.
    static func send(_ request: URLRequest, anchorDER: Data?) async throws -> Response {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              let port = UInt16(exactly: url.port ?? 443), port != 0,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TransportError.invalidURL
        }
        let queue = DispatchQueue(label: "com.rootshell.stepca.https")

        let tls = NWProtocolTLS.Options()
        let secOptions = tls.securityProtocolOptions
        sec_protocol_options_add_tls_application_protocol(secOptions, "http/1.1")
        sec_protocol_options_set_verify_block(secOptions, { _, secTrust, complete in
            complete(evaluate(trust: sec_trust_copy_ref(secTrust).takeRetainedValue(), host: host, anchorDER: anchorDER))
        }, queue)

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .https,
            using: NWParameters(tls: tls, tcp: tcp)
        )

        let exchange = Exchange(
            connection: connection,
            queue: queue,
            pinned: anchorDER != nil,
            requestBytes: serialize(request, components: components, host: host, port: port)
        )
        let raw = try await withTaskCancellationHandler {
            try await exchange.run()
        } onCancel: {
            exchange.cancel()
        }
        return try parse(raw)
    }

    // MARK: - Trust

    private static func evaluate(trust: SecTrust, host: String, anchorDER: Data?) -> Bool {
        guard let anchorDER else { return true }
        guard let anchor = SecCertificateCreateWithData(nil, anchorDER as CFData) else { return false }
        // Fail closed if the pin can't be applied.
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            return false
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    // MARK: - Connection

    /// One request/response over a connection: write the request, read until
    /// the server closes (`Connection: close`). All state lives on `queue`.
    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let requestBytes: Data
        private let pinned: Bool
        private var timeout: DispatchWorkItem?
        private var continuation: CheckedContinuation<Data, Error>?
        private var finished = false
        private var received = Data()

        init(connection: NWConnection, queue: DispatchQueue, pinned: Bool, requestBytes: Data) {
            self.connection = connection
            self.queue = queue
            self.pinned = pinned
            self.requestBytes = requestBytes
        }

        func run() async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        }

        func cancel() {
            queue.async { self.finish(.failure(CancellationError())) }
        }

        private func start(_ continuation: CheckedContinuation<Data, Error>) {
            guard !finished else {
                // Cancelled before the connection started.
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connection.send(content: requestBytes, completion: .contentProcessed { [self] error in
                        if let error {
                            finish(.failure(TransportError.connectionFailed(error.localizedDescription)))
                        } else {
                            receive()
                        }
                    })
                case .failed(let error):
                    finish(.failure(transportError(for: error)))
                case .waiting(let error):
                    // Keep waiting (Local Network prompt, VPN coming up) unless
                    // the handshake itself was rejected; the timeout bounds it.
                    if case .tls = error {
                        finish(.failure(transportError(for: error)))
                    }
                default:
                    break
                }
            }
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(.failure(TransportError.timedOut))
            }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + PinnedHTTPSClient.timeout, execute: timeout)
            connection.start(queue: queue)
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
                if let data {
                    received.append(data)
                    if received.count > PinnedHTTPSClient.maxResponseSize {
                        finish(.failure(TransportError.responseTooLarge))
                        return
                    }
                }
                // An abrupt close can arrive as isComplete plus an error; the
                // data is then truncated, so the error wins.
                if let error {
                    finish(.failure(transportError(for: error)))
                } else if isComplete {
                    finish(.success(received))
                } else {
                    receive()
                }
            }
        }

        private func transportError(for error: NWError) -> TransportError {
            if case .tls = error, pinned {
                return .untrustedServer
            }
            return .connectionFailed(error.localizedDescription)
        }

        private func finish(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            timeout = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    // MARK: - HTTP/1.1

    private static func serialize(_ request: URLRequest, components: URLComponents, host: String, port: UInt16) -> Data {
        // The percent-encoded form: a decoded path could contain spaces.
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            target += "?" + query
        }
        let body = request.httpBody ?? Data()
        // IPv6 literals need their brackets back (URL.host strips them).
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let hostHeader = port == 443 ? bracketed : "\(bracketed):\(port)"
        var head = "\(request.httpMethod ?? "GET") \(target) HTTP/1.1\r\n"
        head += "Host: \(hostHeader)\r\n"
        head += "Accept: application/json\r\n"
        head += "User-Agent: rootshell\r\n"
        head += "Connection: close\r\n"
        if let contentType = request.value(forHTTPHeaderField: "Content-Type") {
            head += "Content-Type: \(contentType)\r\n"
        }
        if !body.isEmpty || request.httpMethod == "POST" {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func parse(_ raw: Data) throws -> Response {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = raw.range(of: separator),
              let head = String(data: raw[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw TransportError.malformedResponse
        }
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw TransportError.malformedResponse
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let body = Data(raw[headerEnd.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return Response(status: status, body: try dechunk(body))
        }
        if let lengthHeader = headers["content-length"] {
            // UInt rejects a sign; the comparison rejects lengths past the data.
            guard let length = UInt(lengthHeader), length <= UInt(body.count) else {
                throw TransportError.malformedResponse
            }
            return Response(status: status, body: body.prefix(Int(length)))
        }
        return Response(status: status, body: body)
    }

    private static func dechunk(_ data: Data) throws -> Data {
        var result = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex),
                  let sizeLine = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii) else {
                throw TransportError.malformedResponse
            }
            let sizeField = sizeLine.split(separator: ";", omittingEmptySubsequences: false).first ?? ""
            // UInt rejects a sign; sizes are compared before any arithmetic.
            guard let size = UInt(sizeField.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw TransportError.malformedResponse
            }
            index = lineEnd.upperBound
            if size == 0 { return result }
            let remaining = UInt(data.distance(from: index, to: data.endIndex))
            guard size <= remaining, remaining - size >= 2 else {
                throw TransportError.malformedResponse
            }
            let chunkEnd = data.index(index, offsetBy: Int(size))
            result.append(data[index..<chunkEnd])
            guard data[chunkEnd..<data.index(chunkEnd, offsetBy: 2)] == crlf else {
                throw TransportError.malformedResponse
            }
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}
