#if !targetEnvironment(macCatalyst)

import Foundation

/// Parser for ping/ping6 command-line arguments
/// Follows the SSHCommandParser pattern with tokenization and flag parsing
nonisolated struct PingCommandParser {
    private static let maxPatternHexLength = 1024

    /// Parsed ping configuration
    struct PingConfig: Sendable {
        var target: String
        var addressFamily: AddressFamily = .ipv4
        var count: Int?                    // -c
        var interval: TimeInterval = 1.0   // -i
        var packetSize: Int = 56           // -s
        var timeout: TimeInterval?         // -t (overall)
        var waitTime: TimeInterval = 10.0  // -W (per-packet, in ms on BSD but we use seconds)
        var ttl: Int?                      // -m
        var dontFragment: Bool = false     // -D
        var numeric: Bool = false          // -n
        var quiet: Bool = false            // -q
        var quieter: Bool = false          // -Q
        var verbose: Bool = false          // -v
        var exitOnFirstReply: Bool = false // -o
        var preload: Int = 0              // -l
        var sourceAddress: String?         // -S
        var pattern: [UInt8]?             // -p
        var sweepMin: Int?                // -g
        var sweepMax: Int?                // -G
        var sweepIncr: Int?               // -h
        var boundInterface: String?        // -b
        var trafficClass: Int?            // -k
        var recordRoute: Bool = false     // -R
        var soDebug: Bool = false         // -d
        var soDontRoute: Bool = false     // -r
        var appleConnect: Bool = false    // --apple-connect
        var appleTime: Bool = false       // --apple-time

        enum AddressFamily: Sendable {
            case ipv4
            case ipv6
        }
    }

    /// Result of parsing a ping command
    enum ParseResult {
        case success(PingConfig)
        case help
        case error(String)
    }

    /// Parse a ping or ping6 command string
    /// - Parameter command: Full command string (e.g., "ping -c 3 google.com")
    /// - Returns: ParseResult with success, help, or error
    static func parse(command: String) -> ParseResult {
        let tokens = tokenize(command)

        guard !tokens.isEmpty else {
            return .error("Empty command")
        }

        let commandName = tokens[0].lowercased()
        let isPing6 = commandName == "ping6"

        guard commandName == "ping" || isPing6 else {
            return .error("Not a ping command")
        }

        // Bare command or help flag
        if tokens.count == 1 {
            return .help
        }
        if tokens.count == 2 && (tokens[1] == "-h" || tokens[1] == "--help") {
            return .help
        }

        var config = PingConfig(target: "")
        if isPing6 {
            config.addressFamily = .ipv6
        }

        var i = 1
        var targetFound = false

        while i < tokens.count {
            let token = tokens[i]

            if token.hasPrefix("-") && !token.hasPrefix("--") && token != "-" {
                // Short flags - may be combined (e.g., -nv)
                let flags = token.dropFirst()
                var flagIndex = flags.startIndex

                while flagIndex < flags.endIndex {
                    let flag = flags[flagIndex]

                    switch flag {
                    case "c":
                        i += 1
                        guard i < tokens.count, let n = Int(tokens[i]), n > 0 else {
                            return .error("Invalid count for -c")
                        }
                        config.count = n

                    case "i":
                        i += 1
                        guard i < tokens.count,
                              let val = Double(tokens[i]),
                              val.isFinite,
                              val > 0 else {
                            return .error("Invalid interval for -i")
                        }
                        config.interval = val

                    case "s":
                        i += 1
                        guard i < tokens.count, let val = Int(tokens[i]), val >= 0, val <= 65500 else {
                            return .error("Invalid packet size for -s")
                        }
                        config.packetSize = val

                    case "t":
                        i += 1
                        guard i < tokens.count,
                              let val = Double(tokens[i]),
                              val.isFinite,
                              val > 0 else {
                            return .error("Invalid timeout for -t")
                        }
                        config.timeout = val

                    case "W":
                        i += 1
                        guard i < tokens.count,
                              let val = Double(tokens[i]),
                              val.isFinite,
                              val > 0 else {
                            return .error("Invalid wait time for -W")
                        }
                        // BSD ping uses milliseconds for -W
                        config.waitTime = val / 1000.0

                    case "m":
                        i += 1
                        guard i < tokens.count, let val = Int(tokens[i]), val > 0, val <= 255 else {
                            return .error("Invalid TTL for -m")
                        }
                        config.ttl = val

                    case "l":
                        i += 1
                        guard i < tokens.count, let val = Int(tokens[i]), val >= 0, val <= 128 else {
                            return .error("Invalid preload count for -l (0-128)")
                        }
                        config.preload = val

                    case "S":
                        i += 1
                        guard i < tokens.count else {
                            return .error("Missing source address for -S")
                        }
                        config.sourceAddress = tokens[i]

                    case "p":
                        i += 1
                        guard i < tokens.count else {
                            return .error("Missing pattern for -p")
                        }
                        guard tokens[i].count <= Self.maxPatternHexLength else {
                            return .error("Pattern too long for -p (max \(Self.maxPatternHexLength) hex chars)")
                        }
                        guard let pattern = parseHexPattern(tokens[i]) else {
                            return .error("Invalid hex pattern for -p")
                        }
                        config.pattern = pattern

                    case "g":
                        i += 1
                        guard i < tokens.count, let val = Int(tokens[i]), val >= 0, val <= 65500 else {
                            return .error("Invalid sweep minimum for -g (0-65500)")
                        }
                        config.sweepMin = val

                    case "G":
                        i += 1
                        guard i < tokens.count, let val = Int(tokens[i]), val >= 0, val <= 65500 else {
                            return .error("Invalid sweep maximum for -G (0-65500)")
                        }
                        config.sweepMax = val

                    case "h":
                        // -h can be sweep increment or help
                        // If next token is a positive number, it's sweep increment
                        if i + 1 < tokens.count, let val = Int(tokens[i + 1]), val > 0, val <= 65500 {
                            i += 1
                            config.sweepIncr = val
                        } else if i + 1 < tokens.count, let val = Int(tokens[i + 1]), val > 65500 {
                            return .error("Invalid sweep increment for -h (1-65500)")
                        } else if i + 1 < tokens.count, let val = Int(tokens[i + 1]), val <= 0 {
                            return .error("Invalid sweep increment for -h: must be positive")
                        } else {
                            return .help
                        }

                    case "b", "B":
                        i += 1
                        guard i < tokens.count else {
                            return .error("Missing interface for -\(flag)")
                        }
                        config.boundInterface = tokens[i]

                    case "k":
                        i += 1
                        guard i < tokens.count, let val = Int(tokens[i]) else {
                            return .error("Invalid traffic class for -k")
                        }
                        config.trafficClass = val

                    case "D":
                        config.dontFragment = true
                    case "n":
                        config.numeric = true
                    case "q":
                        config.quiet = true
                    case "Q":
                        config.quieter = true
                    case "v":
                        config.verbose = true
                    case "o":
                        config.exitOnFirstReply = true
                    case "R":
                        config.recordRoute = true
                    case "d":
                        config.soDebug = true
                    case "r":
                        config.soDontRoute = true
                    case "A":
                        // -A (show missed) - not commonly needed, skip
                        break

                    default:
                        return .error("Invalid option: -\(flag)")
                    }

                    flagIndex = flags.index(after: flagIndex)
                }
            } else if token.hasPrefix("--") {
                // Long flags
                switch token {
                case "--help":
                    return .help
                case "--apple-connect":
                    config.appleConnect = true
                case "--apple-time":
                    config.appleTime = true
                default:
                    return .error("Invalid option: \(token)")
                }
            } else {
                // Positional argument = target
                if targetFound {
                    if config.numeric && Int(config.target) != nil {
                        return .error("Too many arguments (hint: use -c \(config.target) to set packet count, -n means numeric output only)")
                    }
                    return .error("Too many arguments")
                }
                config.target = token
                targetFound = true
            }

            i += 1
        }

        guard targetFound else {
            return .error("Missing target host")
        }

        // Validate sweep configuration
        if config.sweepMin != nil || config.sweepMax != nil {
            let sweepMin = config.sweepMin ?? config.packetSize
            let sweepMax = config.sweepMax ?? config.packetSize
            if sweepMin > sweepMax {
                return .error("Sweep minimum must be <= sweep maximum")
            }
            config.sweepMin = sweepMin
            config.sweepMax = sweepMax
            if config.sweepIncr == nil {
                config.sweepIncr = 1
            }
        }

        return .success(config)
    }

    // MARK: - Private Helpers

    /// Tokenize command string, respecting quotes
    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character?

        for char in command {
            if let quote = inQuote {
                if char == quote {
                    inQuote = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                inQuote = char
            } else if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Parse hex pattern string (e.g., "deadbeef") into bytes
    private static func parseHexPattern(_ hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var chars = hex.makeIterator()

        while let hi = chars.next() {
            guard let lo = chars.next(),
                  let hiByte = UInt8(String(hi), radix: 16),
                  let loByte = UInt8(String(lo), radix: 16) else {
                return nil
            }
            bytes.append((hiByte << 4) | loByte)
        }

        return bytes.isEmpty ? nil : bytes
    }
}

#endif // !targetEnvironment(macCatalyst)
