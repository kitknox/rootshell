#if !targetEnvironment(macCatalyst)

import Foundation

/// Per-hop statistics tracking with ring buffer for stripchart display.
nonisolated struct HopStatistics {
    /// All IPs seen at this TTL (ECMP load balancing)
    var addresses: [String] = []
    /// Resolved hostnames keyed by IP
    var hostnames: [String: String] = [:]
    /// AS info keyed by IP
    var asInfo: [String: GeoInfo] = [:]

    var sent: Int = 0
    var received: Int = 0
    private(set) var dropped = 0
    private(set) var timed = 0
    var lastRTT: Double = 0             // milliseconds
    var bestRTT: Double = .infinity
    var worstRTT: Double = 0
    var sumRTT: Double = 0
    var sumRTTSquared: Double = 0       // for stdev: sqrt(sumSq/n - (sum/n)^2)
    var previousRTT: Double?            // for jitter calculation
    var lastJitter: Double = 0          // |current - previous|
    var sumJitter: Double = 0
    var worstJitter: Double = 0
    var interarrivalJitter: Double = 0  // RFC 1889 running estimate

    enum Sample {
        case empty
        case reply(rtt: Double?)
        case timeout
    }

    /// Ring buffer in arrival order, including replies without kernel timing.
    var samples: [Sample]
    var sampleIndex: Int = 0

    /// Number of log(rtt) samples accumulated for geometric mean
    private var logRTTSum: Double = 0

    init(maxSamples: Int) {
        let safeMaxSamples = max(1, maxSamples)
        self.samples = [Sample](repeating: .empty, count: safeMaxSamples)
    }

    // MARK: - Computed Properties

    var lossPercent: Double {
        let settled = received + dropped
        guard settled > 0 else { return 0 }
        return Double(dropped) / Double(settled) * 100.0
    }

    var avgRTT: Double {
        guard timed > 0 else { return 0 }
        return sumRTT / Double(timed)
    }

    var stddev: Double {
        guard timed > 1 else { return 0 }
        let avg = avgRTT
        let variance = sumRTTSquared / Double(timed) - avg * avg
        return variance > 0 ? sqrt(variance) : 0
    }

    var avgJitter: Double {
        let jitterSamples = timed > 1 ? timed - 1 : 0
        guard jitterSamples > 0 else { return 0 }
        return sumJitter / Double(jitterSamples)
    }

    var geometricMean: Double {
        guard timed > 0, bestRTT > 0 else { return 0 }
        return exp(logRTTSum / Double(timed))
    }

    /// Primary display address (first seen)
    var primaryAddress: String? {
        addresses.first
    }

    /// Primary hostname for display
    var displayName: String? {
        guard let ip = primaryAddress else { return nil }
        return hostnames[ip]
    }

    // MARK: - Mutations

    mutating func recordProbe(rtt: Double?, fromAddress: String) {
        received += 1
        if !addresses.contains(fromAddress) { addresses.append(fromAddress) }
        samples[sampleIndex % samples.count] = .reply(rtt: rtt)
        sampleIndex += 1
        guard let rtt else { return }
        timed += 1
        lastRTT = rtt
        bestRTT = min(bestRTT, rtt)
        worstRTT = max(worstRTT, rtt)
        sumRTT += rtt
        sumRTTSquared += rtt * rtt

        // Log for geometric mean (guard against log(0))
        if rtt > 0 {
            logRTTSum += log(rtt)
        }

        // Jitter
        if let prev = previousRTT {
            let jitter = abs(rtt - prev)
            lastJitter = jitter
            sumJitter += jitter
            worstJitter = max(worstJitter, jitter)
            // RFC 1889 interarrival jitter: J(i) = J(i-1) + (|D(i-1,i)| - J(i-1))/16
            interarrivalJitter += (jitter - interarrivalJitter) / 16.0
        }
        previousRTT = rtt
    }

    mutating func recordTimeout() {
        dropped += 1
        // Note: sent is already incremented by recordSent() when the probe is dispatched.
        // Do NOT increment sent here — that would double-count.
        if !samples.isEmpty {
            samples[sampleIndex % samples.count] = .timeout
            sampleIndex += 1
        }
    }

    mutating func recordSent() {
        sent += 1
    }

    mutating func reset() {
        sent = 0
        received = 0
        dropped = 0
        timed = 0
        lastRTT = 0
        bestRTT = .infinity
        worstRTT = 0
        sumRTT = 0
        sumRTTSquared = 0
        previousRTT = nil
        lastJitter = 0
        sumJitter = 0
        worstJitter = 0
        interarrivalJitter = 0
        logRTTSum = 0
        sampleIndex = 0
        for i in samples.indices {
            samples[i] = .empty
        }
        // Keep addresses and hostnames
    }
}

/// Complete trace state containing all hops
@MtrActor
final class MtrTrace {
    static let maxSamples = 400

    var hops: [HopStatistics]
    var destinationReached: Bool = false
    var destinationTTL: Int?
    /// Highest TTL that received any response
    var effectiveMaxTTL: Int
    /// Configured max TTL
    let configMaxTTL: Int

    init(maxTTL: Int) {
        let safeMaxTTL = max(1, maxTTL)
        self.configMaxTTL = safeMaxTTL
        self.effectiveMaxTTL = safeMaxTTL
        self.hops = (0..<safeMaxTTL).map { _ in HopStatistics(maxSamples: Self.maxSamples) }
    }

    /// Number of displayable hops (up to destination or highest responding hop)
    var displayableHopCount: Int {
        if let destTTL = destinationTTL {
            return destTTL
        }
        // Find highest hop that actually received a response.
        // We can't use `sent > 0` because probes are sent for all TTLs each round,
        // which would always show maxTTL hops.
        // Show up to the highest responding hop + maxUnknown consecutive non-responding hops.
        var highestResponding = 0
        for i in 0..<hops.count {
            if hops[i].received > 0 {
                highestResponding = i + 1
            }
        }
        // If nothing responded yet, show up to the first few hops that have been probed
        if highestResponding == 0 {
            for i in 0..<hops.count {
                if hops[i].sent > 0 {
                    highestResponding = i + 1
                } else {
                    break
                }
            }
        }
        return highestResponding
    }

    func reset(keepAddresses: Bool) {
        for i in hops.indices {
            if keepAddresses {
                hops[i].reset()
            } else {
                hops[i] = HopStatistics(maxSamples: Self.maxSamples)
            }
        }
        destinationReached = false
        destinationTTL = nil
    }
}

#endif // !targetEnvironment(macCatalyst)
