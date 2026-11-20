#if !targetEnvironment(macCatalyst)

import Foundation

/// Non-interactive report output formats for mtr.
/// Used when -r, -w, -C, -j, -x, or -l is specified.
@MtrActor
final class MtrReporter {
    let output: (String) -> Void

    init(output: @escaping (String) -> Void) {
        self.output = output
    }

    // MARK: - Report Mode (-r)

    func printReport(trace: MtrTrace, config: MtrCommandParser.MtrConfig,
                     resolver: MtrDNSResolver, targetHost: String) {
        let hopCount = trace.displayableHopCount
        let hostWidth = 30

        output("Start: \(formatDate())\r\n")
        output("HOST: \(targetHost)")
        output(String(repeating: " ", count: max(1, hostWidth + 2 - targetHost.count)))
        output("  Loss%   Snt   Last    Avg   Best   Wrst  StDev\r\n")

        for i in 0..<hopCount {
            let hop = trace.hops[i]
            let ttl = i + 1

            let hostStr: String
            if hop.addresses.isEmpty {
                hostStr = "???"
            } else {
                let ip = hop.primaryAddress ?? "???"
                let hostname = config.numeric ? nil : resolver.cachedHostname(for: ip)
                hostStr = hostname ?? ip
            }

            let truncatedHost = padRight(String(hostStr.prefix(hostWidth)), width: hostWidth)
            let line = String(format: "%3d.|-- ", ttl) +
                truncatedHost +
                reportColumns(hop)
            output(line)
        }
    }

    // MARK: - Wide Report Mode (-w)

    func printWideReport(trace: MtrTrace, config: MtrCommandParser.MtrConfig,
                         resolver: MtrDNSResolver, targetHost: String) {
        let hopCount = trace.displayableHopCount

        // Pre-compute host strings and find max width
        var hostStrings: [String] = []
        for i in 0..<hopCount {
            let hop = trace.hops[i]
            if hop.addresses.isEmpty {
                hostStrings.append("???")
            } else {
                let ip = hop.primaryAddress ?? "???"
                let hostname = config.numeric ? nil : resolver.cachedHostname(for: ip)
                if let hostname, config.showIPs {
                    hostStrings.append("\(hostname) (\(ip))")
                } else {
                    hostStrings.append(hostname ?? ip)
                }
            }
        }
        let hostWidth = max(20, hostStrings.map(\.count).max() ?? 20)

        output("Start: \(formatDate())\r\n")
        let headerHost = padRight("HOST: \(targetHost)", width: hostWidth + 8)
        output("\(headerHost)  Loss%   Snt   Last    Avg   Best   Wrst  StDev\r\n")

        for i in 0..<hopCount {
            let hop = trace.hops[i]
            let ttl = i + 1

            let paddedHost = padRight(hostStrings[i], width: hostWidth)
            let line = String(format: "%3d.|-- ", ttl) +
                paddedHost +
                reportColumns(hop)
            output(line)
        }
    }

    // MARK: - CSV Mode (-C)

    func printCSV(trace: MtrTrace, config: MtrCommandParser.MtrConfig,
                  resolver: MtrDNSResolver, targetHost: String) {
        output("Mtr_Version;Status;Host;Hop;Ip;Loss%;Snt;Last;Avg;Best;Wrst;StDev\r\n")

        let hopCount = trace.displayableHopCount
        for i in 0..<hopCount {
            let hop = trace.hops[i]
            let ttl = i + 1

            let ip = hop.primaryAddress ?? "???"
            let hostname = config.numeric ? ip : (resolver.cachedHostname(for: ip) ?? ip)
            let status = hop.addresses.isEmpty ? "??" : "OK"

            let times = timingColumns(hop).map { $0.value.map(formatCSVFloat) ?? "" }
            let line = "1.0;\(status);\(targetHost);\(ttl);\(hostname);\(formatCSVFloat(hop.lossPercent));\(hop.sent);\(times.joined(separator: ";"))\r\n"
            output(line)
        }
    }

    // MARK: - JSON Mode (-j)

    func printJSON(trace: MtrTrace, config: MtrCommandParser.MtrConfig,
                   resolver: MtrDNSResolver, targetHost: String, targetIP: String) {
        var json = "{\r\n"
        json += "  \"report\": {\r\n"
        json += "    \"mtr\": {\r\n"
        json += "      \"src\": \"rootshell\",\r\n"
        json += "      \"dst\": \"\(escapeJSON(targetHost))\",\r\n"
        json += "      \"tos\": \(config.tos),\r\n"
        json += "      \"psize\": \"\(config.packetSize)\",\r\n"
        json += "      \"bitpattern\": \"\(config.bitPattern)\",\r\n"
        json += "      \"tests\": \(config.reportCycles ?? 10)\r\n"
        json += "    },\r\n"
        json += "    \"hubs\": [\r\n"

        let hopCount = trace.displayableHopCount
        for i in 0..<hopCount {
            let hop = trace.hops[i]
            let ttl = i + 1
            let ip = hop.primaryAddress ?? "???"
            let hostname = config.numeric ? ip : (resolver.cachedHostname(for: ip) ?? ip)

            json += "      {\r\n"
            json += "        \"count\": \(ttl),\r\n"
            json += "        \"host\": \"\(escapeJSON(hostname))\",\r\n"
            json += "        \"Loss%\": \(formatJSONFloat(hop.lossPercent)),\r\n"
            json += "        \"Snt\": \(hop.sent),\r\n"
            json += timingColumns(hop).map { name, value in
                "        \"\(name)\": \(value.map(formatJSONFloat) ?? "null")"
            }.joined(separator: ",\r\n") + "\r\n"
            json += "      }"
            if i < hopCount - 1 { json += "," }
            json += "\r\n"
        }

        json += "    ]\r\n"
        json += "  }\r\n"
        json += "}\r\n"
        output(json)
    }

    // MARK: - XML Mode (-x)

    func printXML(trace: MtrTrace, config: MtrCommandParser.MtrConfig,
                  resolver: MtrDNSResolver, targetHost: String) {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n"
        xml += "<MTR SRC=\"rootshell\" DST=\"\(escapeXML(targetHost))\" TOS=\"\(config.tos)\" PSIZE=\"\(config.packetSize)\" BITPATTERN=\"\(config.bitPattern)\" TESTS=\"\(config.reportCycles ?? 10)\">\r\n"

        let hopCount = trace.displayableHopCount
        for i in 0..<hopCount {
            let hop = trace.hops[i]
            let ttl = i + 1
            let ip = hop.primaryAddress ?? "???"
            let hostname = config.numeric ? ip : (resolver.cachedHostname(for: ip) ?? ip)

            xml += "  <HUB COUNT=\"\(ttl)\" HOST=\"\(escapeXML(hostname))\""
            xml += " Loss=\"\(formatJSONFloat(hop.lossPercent))\""
            xml += " Snt=\"\(hop.sent)\""
            for (name, value) in timingColumns(hop) {
                if let value { xml += " \(name)=\"\(formatJSONFloat(value))\"" }
            }
            xml += " />\r\n"
        }

        xml += "</MTR>\r\n"
        output(xml)
    }

    // MARK: - Raw Mode (-l)

    /// Emit a single raw line during probing.
    func emitRawHop(ttl: Int, ip: String) {
        output("h \(ttl) \(ip)\r\n")
    }

    func emitRawPing(ttl: Int, rttMicroseconds: Int) {
        output("p \(ttl) \(rttMicroseconds)\r\n")
    }

    func emitRawDNS(ttl: Int, hostname: String) {
        output("d \(ttl) \(hostname)\r\n")
    }

    func emitRawTimeout(ttl: Int) {
        output("x \(ttl)\r\n")
    }

    // MARK: - Helpers

    private func timingColumns(_ hop: HopStatistics) -> [(name: String, value: Double?)] {
        // Keep the existing zero sentinel for unanswered hops. A reply without
        // a kernel timestamp still establishes reachability but supplies no RTT.
        let missing: Double? = hop.received == 0 ? 0 : nil
        return [
            ("Last", hop.timed > 0 ? hop.lastRTT : missing),
            ("Avg", hop.timed > 0 ? hop.avgRTT : missing),
            ("Best", hop.timed > 0 ? hop.bestRTT : missing),
            ("Wrst", hop.timed > 0 ? hop.worstRTT : missing),
            ("StDev", hop.timed > 0 ? hop.stddev : missing)
        ]
    }

    private func reportColumns(_ hop: HopStatistics) -> String {
        let times = timingColumns(hop).map { column in
            column.value.map { String(format: "%5.1f", $0) } ?? "    -"
        }
        return String(format: " %5.1f%%  %4d  ", hop.lossPercent, hop.sent) +
            times.joined(separator: "  ") + "\r\n"
    }

    private func formatDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM  d HH:mm:ss yyyy"
        return formatter.string(from: Date())
    }

    private func formatCSVFloat(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func formatJSONFloat(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func escapeJSON(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func padRight(_ str: String, width: Int) -> String {
        let len = str.count
        if len >= width { return str }
        return str + String(repeating: " ", count: width - len)
    }
}

#endif // !targetEnvironment(macCatalyst)
