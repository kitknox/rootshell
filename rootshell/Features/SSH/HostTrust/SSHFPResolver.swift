//
//  SSHFPResolver.swift
//  rootshell
//
//  SSHFP lookups. A validating DoH resolver answers first, because common
//  resolvers (home routers, MagicDNS) strip DNSSEC and mDNSResponder then never
//  reports a status; the system resolver through dnssd covers split-horizon names.
//

import Foundation
import dnssd

/// Validating DoH resolvers for SSHFP lookups; each sets AD and SERVFAILs bogus zones.
nonisolated enum SSHFPDoHProvider: String, CaseIterable, Sendable {
    case cloudflare
    case quad9
    case google
    case mullvad
    case secureDNS360 = "360"

    static var buildDefault: SSHFPDoHProvider {
        #if CHINA_BUILD
        .secureDNS360
        #else
        .cloudflare
        #endif
    }

    var endpoint: URL {
        switch self {
        case .cloudflare: URL(string: "https://cloudflare-dns.com/dns-query")!
        case .quad9: URL(string: "https://dns.quad9.net/dns-query")!
        case .google: URL(string: "https://dns.google/dns-query")!
        case .mullvad: URL(string: "https://dns.mullvad.net/dns-query")!
        case .secureDNS360: URL(string: "https://doh.360.cn/dns-query")!
        }
    }

    var displayName: String {
        switch self {
        case .cloudflare: "Cloudflare"
        case .quad9: "Quad9"
        case .google: "Google"
        case .mullvad: "Mullvad"
        case .secureDNS360: String(localized: "360 Secure DNS", comment: "DNS-over-HTTPS provider name")
        }
    }
}

nonisolated enum SSHFPResolver {
    static let queue = DispatchQueue(label: "com.rootshell.sshfp")

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept": "application/dns-message"]
        return URLSession(configuration: configuration)
    }()

    /// Nil when the mode is off, the name is skipped, or every lookup failed.
    static func lookup(
        hostname: String, mode: HostKeyDNSVerification, provider: SSHFPDoHProvider
    ) async -> SSHFPLookupResult? {
        guard mode != .off, SSHFPRecord.shouldLookUp(hostname: hostname) else { return nil }

        return await withTaskGroup(of: (fromDoH: Bool, result: SSHFPLookupResult?).self) { group in
            group.addTask { (true, await dohLookup(hostname, provider: provider)) }
            group.addTask { (false, await systemLookup(hostname)) }
            var dohResult: SSHFPLookupResult?
            var systemResult: SSHFPLookupResult?
            for await (fromDoH, result) in group {
                guard fromDoH else {
                    systemResult = result
                    continue
                }
                // DoH records win the merge below, so skip the system query's validation grace.
                if let result, !result.records.isEmpty {
                    group.cancelAll()
                    return result
                }
                dohResult = result
            }
            // Split-horizon names only have records on the local resolver.
            if let dohResult, !dohResult.records.isEmpty { return dohResult }
            if let systemResult, !systemResult.records.isEmpty { return systemResult }
            return dohResult ?? systemResult
        }
    }

    private static func dohLookup(_ hostname: String, provider: SSHFPDoHProvider) async -> SSHFPLookupResult? {
        guard let query = SSHFPDNSMessage.query(name: hostname),
              var components = URLComponents(url: provider.endpoint, resolvingAgainstBaseURL: false)
        else { return nil }
        let encoded = query.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        components.queryItems = [URLQueryItem(name: "dns", value: encoded)]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return SSHFPDNSMessage.parse(response: data)
    }

    private static func systemLookup(_ hostname: String) async -> SSHFPLookupResult? {
        let query = SSHFPSystemQuery()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { query.start(hostname, continuation: continuation) }
            }
        } onCancel: {
            queue.async { query.cancel() }
        }
    }
}

/// One dnssd SSHFP query; all state is confined to `SSHFPResolver.queue`.
nonisolated private final class SSHFPSystemQuery: @unchecked Sendable {
    private static let timeout: TimeInterval = 3
    /// dns_sd.h lets the DNSSEC status follow the records, but ValidateOptional
    /// sends none when the resolver strips DNSSEC, so only hold the answer briefly.
    private static let validationGrace: TimeInterval = 1

    private var continuation: CheckedContinuation<SSHFPLookupResult?, Never>?
    private var ref: DNSServiceRef?
    private var records: [SSHFPRecord] = []
    private var status: SSHFPDNSSECStatus?
    private var graceScheduled = false
    private var cancelled = false

    private var currentResult: SSHFPLookupResult? {
        records.isEmpty ? nil : SSHFPLookupResult(records: records, dnssec: status ?? .insecure)
    }

    func cancel() {
        cancelled = true
        finish(currentResult)
    }

    func start(_ hostname: String, continuation: CheckedContinuation<SSHFPLookupResult?, Never>) {
        self.continuation = continuation
        guard !cancelled else {
            finish(nil)
            return
        }
        // ValidateOptional still answers when the resolver strips DNSSEC; plain
        // Validate never calls back at all in that case.
        let flags = DNSServiceFlags(
            kDNSServiceFlagsValidateOptional | kDNSServiceFlagsReturnIntermediates | kDNSServiceFlagsTimeout)
        let context = Unmanaged.passRetained(self).toOpaque()
        var ref: DNSServiceRef?
        let error = DNSServiceQueryRecord(
            &ref, flags, 0, hostname, UInt16(kDNSServiceType_SSHFP), UInt16(kDNSServiceClass_IN),
            { _, flags, _, error, _, rrtype, _, rdlen, rdata, _, context in
                guard let context else { return }
                let query = Unmanaged<SSHFPSystemQuery>.fromOpaque(context).takeUnretainedValue()
                let data = rdata.map { Data(bytes: $0, count: Int(rdlen)) } ?? Data()
                query.handle(flags: flags, error: error, rrtype: rrtype, rdata: data)
            },
            context)
        guard error == kDNSServiceErr_NoError, let ref else {
            Unmanaged<SSHFPSystemQuery>.fromOpaque(context).release()
            finish(nil)
            return
        }
        self.ref = ref
        DNSServiceSetDispatchQueue(ref, SSHFPResolver.queue)
        SSHFPResolver.queue.asyncAfter(deadline: .now() + Self.timeout) { [self] in
            finish(currentResult)
        }
    }

    private func handle(flags: DNSServiceFlags, error: DNSServiceErrorType, rrtype: UInt16, rdata: Data) {
        guard continuation != nil else { return }
        switch Int(error) {
        case kDNSServiceErr_NoError:
            break
        case kDNSServiceErr_NoSuchRecord, kDNSServiceErr_NoSuchName:
            finish(SSHFPLookupResult(records: [], dnssec: .insecure))
            return
        default:
            finish(currentResult)
            return
        }

        let record = rrtype == UInt16(kDNSServiceType_SSHFP) ? SSHFPRecord(rdata: rdata) : nil
        guard flags & kDNSServiceFlagsAdd != 0 else {
            // A removal invalidates the RRset's DNSSEC status too.
            status = nil
            if let record { records.removeAll { $0 == record } }
            return
        }
        if let record { records.append(record) }
        if flags & kDNSServiceFlagsValidate == kDNSServiceFlagsValidate {
            // Status bits overlap registration flags, so only read them alongside Validate.
            let statusBits = flags & ~kDNSServiceFlagsValidate
            if statusBits & 0x40 != 0 {
                status = .bogus
            } else if statusBits & 0x10 != 0 {
                status = .secure
            } else if statusBits & (0x20 | 0x80) != 0 {
                status = .insecure
            }
        }

        guard flags & kDNSServiceFlagsMoreComing == 0, !records.isEmpty else { return }
        if status != nil {
            finish(currentResult)
        } else if !graceScheduled {
            graceScheduled = true
            SSHFPResolver.queue.asyncAfter(deadline: .now() + Self.validationGrace) { [self] in
                finish(currentResult)
            }
        }
    }

    private func finish(_ result: SSHFPLookupResult?) {
        guard let continuation else { return }
        self.continuation = nil
        if let ref {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
            Unmanaged.passUnretained(self).release()
        }
        continuation.resume(returning: result)
    }
}
