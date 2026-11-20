#if !targetEnvironment(macCatalyst)

import Foundation

/// Parser for mtr/mtr6 command-line arguments.
/// Follows the PingCommandParser pattern with tokenization and flag parsing.
nonisolated struct MtrCommandParser {

    /// Parsed mtr configuration
    struct MtrConfig: Sendable {
        var target: String
        var addressFamily: AddressFamily = .unspecified
        var reportCycles: Int?               // -c (nil = unlimited interactive)
        var interval: TimeInterval = 1.0     // -i
        var packetSize: Int = 64             // -s (data bytes, excludes 8-byte ICMP header)
        var firstTTL: Int = 1                // -f
        var maxTTL: Int = 30                 // -m
        var probeTimeout: TimeInterval = 3.0 // per-probe timeout
        var bitPattern: Int = 0              // -B (0-255, >255 = random)
        var tos: Int = 0                     // -Q (Type of Service)
        var graceTime: TimeInterval = 5.0    // -G
        var numeric: Bool = false            // -n
        var showIPs: Bool = false            // -b (show IP + hostname)
        var displayMode: DisplayMode = .statistics
        var reportMode: ReportMode?          // nil = interactive TUI
        var fieldOrder: String = "LS NABWV"  // -o
        var showASN: Bool = false            // -z
        var ipInfoMode: Int = 0              // -y (0=AS, 1=prefix, 2=country, 3=RIR, 4=date, 5=name, 6=continent)
        var maxUnknown: Int = 5              // max consecutive ??? before stopping

        enum AddressFamily: Sendable { case unspecified, ipv4, ipv6 }
        enum DisplayMode: Int, Sendable { case statistics = 0, stripchart = 1, stripchartWithNumbers = 2 }
        enum ReportMode: Sendable { case report, reportWide, csv, json, xml, raw }
    }

    /// Result of parsing an mtr command
    enum ParseResult {
        case success(MtrConfig)
        case help
        case error(String)
    }

    /// Parse an mtr or mtr6 command string
    static func parse(command: String) -> ParseResult {
        let tokens = tokenize(command)
        guard !tokens.isEmpty else { return .error("Empty command") }

        let commandName = tokens[0].lowercased()
        var config = MtrConfig(target: "")

        // mtr6 implies IPv6
        if commandName == "mtr6" {
            config.addressFamily = .ipv6
        }

        // No args = help
        if tokens.count == 1 {
            return .help
        }

        var i = 1
        while i < tokens.count {
            let token = tokens[i]

            if token == "-h" || token == "--help" {
                return .help
            }

            // Long flags
            if token.hasPrefix("--") {
                let result = parseLongFlag(token, tokens: tokens, index: &i, config: &config)
                if let err = result { return .error(err) }
                i += 1
                continue
            }

            // Short flags
            if token.hasPrefix("-") && token.count > 1 {
                let flags = token.dropFirst()
                var flagIndex = flags.startIndex

                while flagIndex < flags.endIndex {
                    let flag = flags[flagIndex]

                    switch flag {
                    case "4":
                        config.addressFamily = .ipv4
                    case "6":
                        config.addressFamily = .ipv6
                    case "r":
                        config.reportMode = .report
                        if config.reportCycles == nil { config.reportCycles = 10 }
                    case "w":
                        config.reportMode = .reportWide
                        if config.reportCycles == nil { config.reportCycles = 10 }
                    case "C":
                        config.reportMode = .csv
                        if config.reportCycles == nil { config.reportCycles = 10 }
                    case "j":
                        config.reportMode = .json
                        if config.reportCycles == nil { config.reportCycles = 10 }
                    case "x":
                        config.reportMode = .xml
                        if config.reportCycles == nil { config.reportCycles = 10 }
                    case "l":
                        config.reportMode = .raw
                        if config.reportCycles == nil { config.reportCycles = 10 }
                    case "n":
                        config.numeric = true
                    case "b":
                        config.showIPs = true
                    case "z":
                        config.showASN = true
                    case "c":
                        guard let val = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- c")
                        }
                        guard let cycles = Int(val), cycles > 0 else {
                            return .error("invalid count: \(val)")
                        }
                        config.reportCycles = cycles
                    case "i":
                        guard let val = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- i")
                        }
                        guard let interval = Double(val), interval.isFinite, interval > 0 else {
                            return .error("invalid interval: \(val)")
                        }
                        config.interval = interval
                    case "s":
                        guard let val = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- s")
                        }
                        guard let size = Int(val), size >= 0, size <= 65500 else {
                            return .error("invalid packet size: \(val)")
                        }
                        config.packetSize = size
                    case "f":
                        guard let val = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- f")
                        }
                        guard let ttl = Int(val), ttl >= 1, ttl <= 255 else {
                            return .error("invalid first TTL: \(val)")
                        }
                        config.firstTTL = ttl
                    case "m":
                        guard let val = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- m")
                        }
                        guard let ttl = Int(val), ttl >= 1, ttl <= 255 else {
                            return .error("invalid max TTL: \(val)")
                        }
                        config.maxTTL = ttl
                    case "B":
                        guard let val = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- B")
                        }
                        guard let pat = Int(val), pat >= 0 else {
                            return .error("invalid bit pattern: \(val)")
                        }
                        config.bitPattern = pat
                    case "Q":
                        guard let val = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- Q")
                        }
                        guard let tos = Int(val), tos >= 0, tos <= 255 else {
                            return .error("invalid TOS value: \(val)")
                        }
                        config.tos = tos
                    case "G":
                        guard let val = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- G")
                        }
                        guard let grace = Double(val), grace.isFinite, grace >= 0 else {
                            return .error("invalid grace time: \(val)")
                        }
                        config.graceTime = grace
                    case "o":
                        guard let val = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- o")
                        }
                        config.fieldOrder = val
                    case "y":
                        guard let val = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- y")
                        }
                        guard let mode = Int(val), mode >= 0, mode <= 6 else {
                            return .error("invalid IP info mode: \(val) (must be 0-6)")
                        }
                        config.ipInfoMode = mode
                    case "P":
                        // Port flag - accepted but only used for display
                        guard let _ = consumeArgValue(flags: flags, flagIndex: &flagIndex, tokens: tokens, tokenIndex: &i) else {
                            return .error("option requires an argument -- P")
                        }
                    case "u":
                        return .error("UDP mode is not supported on iOS (only ICMP probes are available)")
                    case "T":
                        return .error("TCP mode is not supported on iOS (only ICMP probes are available)")
                    default:
                        return .error("unknown option: -\(flag)")
                    }

                    flagIndex = flags.index(after: flagIndex)
                }
            } else {
                // Positional argument = target
                if !config.target.isEmpty {
                    return .error("unexpected argument: \(token)")
                }
                config.target = token
            }

            i += 1
        }

        // Validate
        if config.target.isEmpty {
            return .help
        }

        if config.firstTTL > config.maxTTL {
            return .error("first TTL (\(config.firstTTL)) must be <= max TTL (\(config.maxTTL))")
        }

        return .success(config)
    }

    // MARK: - Long Flag Parsing

    private static func parseLongFlag(_ token: String, tokens: [String], index: inout Int, config: inout MtrConfig) -> String? {
        let flag = String(token.dropFirst(2))

        switch flag {
        case "udp":
            return "UDP mode is not supported on iOS (only ICMP probes are available)"
        case "tcp":
            return "TCP mode is not supported on iOS (only ICMP probes are available)"
        case "sctp":
            return "SCTP mode is not supported on iOS (only ICMP probes are available)"
        case "mpls":
            return "MPLS label detection is not supported on iOS (ICMP extensions stripped by kernel)"
        case "interface":
            return "--interface is not supported on iOS"
        case "mark":
            return "--mark is not supported on iOS"
        case "report":
            config.reportMode = .report
            if config.reportCycles == nil { config.reportCycles = 10 }
        case "report-wide":
            config.reportMode = .reportWide
            if config.reportCycles == nil { config.reportCycles = 10 }
        case "csv":
            config.reportMode = .csv
            if config.reportCycles == nil { config.reportCycles = 10 }
        case "json":
            config.reportMode = .json
            if config.reportCycles == nil { config.reportCycles = 10 }
        case "xml":
            config.reportMode = .xml
            if config.reportCycles == nil { config.reportCycles = 10 }
        case "raw":
            config.reportMode = .raw
            if config.reportCycles == nil { config.reportCycles = 10 }
        case "no-dns":
            config.numeric = true
        case "show-ips":
            config.showIPs = true
        case "aslookup":
            config.showASN = true
        case "displaymode":
            guard index + 1 < tokens.count else {
                return "--displaymode requires an argument"
            }
            index += 1
            guard let mode = Int(tokens[index]), mode >= 0, mode <= 2 else {
                return "invalid display mode: \(tokens[index]) (must be 0-2)"
            }
            config.displayMode = MtrConfig.DisplayMode(rawValue: mode) ?? .statistics
        default:
            // Handle --flag=value patterns
            if flag.contains("=") {
                let parts = flag.split(separator: "=", maxSplits: 1)
                let name = String(parts[0])
                let value = parts.count > 1 ? String(parts[1]) : ""
                switch name {
                case "interval":
                    guard let interval = Double(value), interval.isFinite, interval > 0 else {
                        return "invalid interval: \(value)"
                    }
                    config.interval = interval
                case "max-ttl":
                    guard let ttl = Int(value), ttl >= 1, ttl <= 255 else {
                        return "invalid max TTL: \(value)"
                    }
                    config.maxTTL = ttl
                case "first-ttl":
                    guard let ttl = Int(value), ttl >= 1, ttl <= 255 else {
                        return "invalid first TTL: \(value)"
                    }
                    config.firstTTL = ttl
                case "psize":
                    guard let size = Int(value), size >= 0, size <= 65500 else {
                        return "invalid packet size: \(value)"
                    }
                    config.packetSize = size
                default:
                    return "unknown option: --\(name)"
                }
            } else {
                return "unknown option: --\(flag)"
            }
        }

        return nil
    }

    // MARK: - Tokenization

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for char in command {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }

            if char == "\\" && !inSingleQuote {
                escaped = true
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if char == " " && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Consume the argument value for a short flag that requires a parameter.
    /// If there are remaining characters in the current flag group, use them.
    /// Otherwise, consume the next token.
    private static func consumeArgValue(
        flags: String.SubSequence,
        flagIndex: inout String.Index,
        tokens: [String],
        tokenIndex: inout Int
    ) -> String? {
        let nextIndex = flags.index(after: flagIndex)
        if nextIndex < flags.endIndex {
            // Remaining characters in this flag group are the value
            let value = String(flags[nextIndex...])
            flagIndex = flags.index(before: flags.endIndex) // Will be incremented past end
            return value
        }
        // Consume next token
        if tokenIndex + 1 < tokens.count {
            tokenIndex += 1
            return tokens[tokenIndex]
        }
        return nil
    }
}

#endif // !targetEnvironment(macCatalyst)
