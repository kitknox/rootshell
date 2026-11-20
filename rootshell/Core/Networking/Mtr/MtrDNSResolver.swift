#if !targetEnvironment(macCatalyst)

import Foundation
import Darwin
import OSLog

/// Async reverse DNS resolution with caching and AS number lookup.
/// Non-blocking: display renders IPs immediately, replaces with hostnames when resolved.
@MtrActor
final class MtrDNSResolver {
    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "mtr-dns")

    /// IP → hostname cache
    private var hostnameCache: [String: String] = [:]
    /// IP → AS info cache
    private var asInfoCache: [String: GeoInfo] = [:]
    /// IPs currently being resolved (avoid duplicate lookups)
    private var pendingHostnames: Set<String> = []
    private var pendingASLookups: Set<String> = []

    /// Callback when a hostname is resolved
    var onHostnameResolved: ((String, String) -> Void)?  // (ip, hostname)
    /// Callback when AS info is resolved
    var onASInfoResolved: ((String, GeoInfo) -> Void)?    // (ip, geoInfo)

    // MARK: - Hostname Resolution

    /// Get cached hostname or start async resolution
    func hostname(for ip: String) -> String? {
        if let cached = hostnameCache[ip] {
            return cached == ip ? nil : cached  // Return nil if DNS returned same as IP
        }

        // Start async resolution if not already pending
        if !pendingHostnames.contains(ip) {
            pendingHostnames.insert(ip)
            Task { [weak self] in
                let hostname = await Self.reverseResolve(ip)
                guard let self else { return }
                self.pendingHostnames.remove(ip)
                let resolved = hostname ?? ip
                self.hostnameCache[ip] = resolved
                if resolved != ip {
                    self.onHostnameResolved?(ip, resolved)
                }
            }
        }

        return nil
    }

    /// Synchronously check cache only
    func cachedHostname(for ip: String) -> String? {
        guard let cached = hostnameCache[ip], cached != ip else { return nil }
        return cached
    }

    // MARK: - AS Info Lookup

    /// Get cached AS info or start async lookup
    func asInfo(for ip: String) -> GeoInfo? {
        if let cached = asInfoCache[ip] {
            return cached
        }

        if !pendingASLookups.contains(ip) {
            pendingASLookups.insert(ip)
            Task { [weak self] in
                let info = await GeoResolver.shared.resolve(ip: ip)
                guard let self else { return }
                self.pendingASLookups.remove(ip)
                if let info {
                    self.asInfoCache[ip] = info
                    self.onASInfoResolved?(ip, info)
                }
            }
        }

        return nil
    }

    /// Synchronously check cache only
    func cachedASInfo(for ip: String) -> GeoInfo? {
        asInfoCache[ip]
    }

    // MARK: - Clear

    func clearCache() {
        hostnameCache.removeAll()
        asInfoCache.removeAll()
    }

    // MARK: - Private Resolution

    /// Runs blocking getnameinfo() off the main actor.
    private nonisolated static func reverseResolve(_ ip: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var addr4 = sockaddr_in()
                var addr6 = sockaddr_in6()

                if inet_pton(AF_INET, ip, &addr4.sin_addr) == 1 {
                    addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    addr4.sin_family = sa_family_t(AF_INET)
                    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let rc = withUnsafePointer(to: &addr4) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            getnameinfo(sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                                       &hostBuf, socklen_t(NI_MAXHOST), nil, 0, 0)
                        }
                    }
                    if rc == 0 {
                        continuation.resume(returning: String(cString: hostBuf))
                    } else {
                        continuation.resume(returning: nil)
                    }
                    return
                }

                if inet_pton(AF_INET6, ip, &addr6.sin6_addr) == 1 {
                    addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    addr6.sin6_family = sa_family_t(AF_INET6)
                    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let rc = withUnsafePointer(to: &addr6) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            getnameinfo(sockPtr, socklen_t(MemoryLayout<sockaddr_in6>.size),
                                       &hostBuf, socklen_t(NI_MAXHOST), nil, 0, 0)
                        }
                    }
                    if rc == 0 {
                        continuation.resume(returning: String(cString: hostBuf))
                    } else {
                        continuation.resume(returning: nil)
                    }
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
