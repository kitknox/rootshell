#if !targetEnvironment(macCatalyst)

import Foundation

/// TUI rendering for mtr using ANSI escape sequences.
/// Supports truecolor (24-bit RGB) derived from the user's terminal theme,
/// with a toggle to fall back to classic 16-color ANSI mode.
@MtrActor
final class MtrDisplay {
    let output: (String) -> Void

    private var cols: UInt16
    private var rows: UInt16
    private var scrollOffset: Int = 0
    private var showHelp: Bool = false
    private var paused: Bool = false

    /// When true (default), uses 24-bit truecolor derived from the user's theme.
    /// When false, renders with basic 16-color ANSI codes (classic mode).
    var useTruecolor: Bool = true

    /// Theme colors captured at init from ThemeManager.
    private let theme: MtrThemeColors

    // MARK: - Theme Color System

    /// Semantic colors derived from the user's terminal theme palette.
    struct MtrThemeColors: Sendable {
        let fg: (UInt8, UInt8, UInt8)
        let dim: (UInt8, UInt8, UInt8)
        let good: (UInt8, UInt8, UInt8)       // palette green
        let warning: (UInt8, UInt8, UInt8)    // palette yellow
        let critical: (UInt8, UInt8, UInt8)   // palette red
        let accent: (UInt8, UInt8, UInt8)     // palette cyan
        let blue: (UInt8, UInt8, UInt8)       // palette blue
        let magenta: (UInt8, UInt8, UInt8)    // palette magenta

        @MainActor static func fromTheme() -> MtrThemeColors {
            let tc = SpinnerAnimator.ThemeColors.fromThemeManager()
            return MtrThemeColors(
                fg: tc.foreground,
                dim: tc.dimmedForeground,
                good: tc.palette[2],
                warning: tc.palette[3],
                critical: tc.palette[1],
                accent: tc.palette[6],
                blue: tc.palette[4],
                magenta: tc.palette[5]
            )
        }
    }

    // MARK: - ANSI Helpers

    private let ESC = "\u{1b}"
    private var CSI: String { "\(ESC)[" }

    /// 24-bit truecolor foreground escape sequence.
    private func fg(_ c: (UInt8, UInt8, UInt8)) -> String {
        "\u{1b}[38;2;\(c.0);\(c.1);\(c.2)m"
    }

    /// Linear interpolation between two RGB colors.
    private func lerp(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8), _ t: Double) -> (UInt8, UInt8, UInt8) {
        let t = max(0, min(1, t))
        return (
            UInt8(clamping: Int(round(Double(a.0) * (1 - t) + Double(b.0) * t))),
            UInt8(clamping: Int(round(Double(a.1) * (1 - t) + Double(b.1) * t))),
            UInt8(clamping: Int(round(Double(a.2) * (1 - t) + Double(b.2) * t)))
        )
    }

    /// Map packet loss percentage to a smooth gradient color (green -> yellow -> red).
    private func lossColor(_ percent: Double) -> (UInt8, UInt8, UInt8) {
        if percent <= 0 { return theme.fg }
        if percent <= 5 { return lerp(theme.good, theme.warning, percent / 5.0) }
        if percent <= 25 { return lerp(theme.warning, theme.critical, (percent - 5) / 20.0) }
        return theme.critical
    }

    /// Map latency ratio (RTT / bestRTT) to a smooth gradient color.
    private func latencyColor(ratio: Double) -> (UInt8, UInt8, UInt8) {
        if ratio <= 1.0 { return theme.good }
        if ratio <= 2.0 { return lerp(theme.good, theme.warning, ratio - 1.0) }
        if ratio <= 5.0 { return lerp(theme.warning, theme.critical, (ratio - 2.0) / 3.0) }
        return theme.critical
    }

    /// Number of header rows consumed before data rows begin.
    private var headerRowCount: Int {
        // title + target + keys + (separator in truecolor) + column header + sub-header/separator
        useTruecolor ? 7 : 6
    }

    /// Stripchart header rows consumed before data rows begin.
    private var stripchartHeaderRowCount: Int {
        // title + target + keys + (separator in truecolor) + column header + (separator in truecolor)
        useTruecolor ? 7 : 5
    }

    init(cols: UInt16, rows: UInt16, theme: MtrThemeColors, output: @escaping (String) -> Void) {
        self.cols = cols
        self.rows = rows
        self.output = output
        self.theme = theme
    }

    // MARK: - Screen Management

    func enterAlternateScreen() {
        output("\(CSI)?1049h")  // Enter alternate screen
        output("\(CSI)?25l")    // Hide cursor
    }

    func exitAlternateScreen() {
        output("\(CSI)?25h")    // Show cursor
        output("\(CSI)?1049l")  // Exit alternate screen
    }

    func resize(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }

    // MARK: - Full Redraw

    func draw(trace: MtrTrace, config: MtrCommandParser.MtrConfig,
              resolver: MtrDNSResolver, targetHost: String, targetIP: String) {
        var buf = ""

        // Begin synchronized output — terminal buffers until end marker
        buf += "\(CSI)?2026h"

        // Clear screen and move to top
        buf += "\(CSI)2J\(CSI)1;1H"

        // Header line 1: title
        let title = "rootshell traceroute"
        let titlePad = max(0, Int(cols) - title.count) / 2
        if useTruecolor {
            buf += "\(CSI)1m\(fg(theme.accent))"
        } else {
            buf += "\(CSI)1m"
        }
        buf += String(repeating: " ", count: titlePad) + title
        buf += "\(CSI)0m\r\n"

        // Header line 2: target info + date
        let dateStr = formatDate()
        let targetStr: String
        if targetHost == targetIP {
            targetStr = targetIP
        } else {
            targetStr = "\(targetHost) (\(targetIP))"
        }
        let targetPad = max(0, Int(cols) - targetStr.count - dateStr.count)
        if useTruecolor {
            buf += targetStr
            buf += String(repeating: " ", count: targetPad)
            buf += "\(fg(theme.dim))\(dateStr)\(CSI)0m"
        } else {
            buf += targetStr + String(repeating: " ", count: targetPad) + dateStr
        }
        buf += "\r\n"

        // Header line 3: keys
        if useTruecolor {
            buf += styledKeysLine()
        } else {
            buf += "Keys: \(CSI)1mH\(CSI)0melp  \(CSI)1mD\(CSI)0misplay mode  \(CSI)1mR\(CSI)0mestart statistics  \(CSI)1mO\(CSI)0mrder of fields  \(CSI)1mT\(CSI)0mruecolor  \(CSI)1mQ\(CSI)0muit"
        }
        buf += "\r\n"

        // Separator line (truecolor mode only)
        if useTruecolor {
            buf += "\(fg(theme.dim))\(String(repeating: "─", count: Int(cols)))\(CSI)0m\r\n"
        }

        if showHelp {
            buf += drawHelpOverlay()
            buf += "\(CSI)?2026l"
            output(buf)
            return
        }

        if paused {
            if useTruecolor {
                buf += "\(fg(theme.warning))-- PAUSED -- press p or Space to resume\(CSI)0m\r\n"
            } else {
                buf += "\(CSI)33m-- PAUSED -- press p or Space to resume\(CSI)0m\r\n"
            }
        }

        // Draw based on display mode
        switch config.displayMode {
        case .statistics:
            buf += drawStatisticsMode(trace: trace, config: config, resolver: resolver)
        case .stripchart:
            buf += drawStripchartMode(trace: trace, config: config, resolver: resolver, showNumbers: false)
        case .stripchartWithNumbers:
            buf += drawStripchartMode(trace: trace, config: config, resolver: resolver, showNumbers: true)
        }

        // End synchronized output — terminal renders frame atomically
        buf += "\(CSI)?2026l"

        output(buf)
    }

    /// Build the styled keys line for truecolor mode.
    private func styledKeysLine() -> String {
        func k(_ key: String, _ desc: String) -> String {
            "\(CSI)1m\(fg(theme.accent))\(key)\(CSI)0m\(fg(theme.dim))\(desc)\(CSI)0m"
        }
        return "\(fg(theme.dim))Keys: \(CSI)0m"
            + k("H", "elp") + "  "
            + k("D", "isplay mode") + "  "
            + k("R", "estart") + "  "
            + k("O", "rder") + "  "
            + k("T", "ruecolor") + "  "
            + k("Q", "uit")
    }

    // MARK: - Statistics Mode (Mode 0)

    private func drawStatisticsMode(trace: MtrTrace, config: MtrCommandParser.MtrConfig,
                                     resolver: MtrDNSResolver) -> String {
        var buf = ""
        let fields = parseFieldOrder(config.fieldOrder)

        // Column header
        let hostWidth = max(20, Int(cols) - fields.count * 7 - 8)

        // Build header line
        if useTruecolor {
            buf += "\(CSI)1m\(fg(theme.blue))"
        } else {
            buf += "\(CSI)1m"
        }
        buf += "     " + padRight("Host", width: hostWidth)
        for field in fields {
            buf += " " + padLeft(field.header, width: 6)
        }
        buf += "\(CSI)0m\r\n"

        // Sub-header grouping ("Packets" / "Pings")
        let subHeader = String(repeating: " ", count: 5 + hostWidth) + "Packets               Pings"
        if useTruecolor {
            buf += "\(fg(theme.dim))\(subHeader)\(CSI)0m\r\n"
        } else {
            buf += subHeader + "\r\n"
        }

        let hopCount = trace.displayableHopCount
        let availableRows = max(1, Int(rows) - headerRowCount)
        let visibleStart = scrollOffset
        let visibleEnd = min(hopCount, visibleStart + availableRows)

        for hopIndex in visibleStart..<visibleEnd {
            let hop = trace.hops[hopIndex]
            let ttl = hopIndex + 1

            // Hop number
            if useTruecolor {
                buf += "\(fg(theme.blue))\(String(format: "%3d.", ttl))\(CSI)0m "
            } else {
                buf += String(format: "%3d. ", ttl)
            }

            // Host name (AS prefix + hostname must fit within hostWidth)
            if hop.addresses.isEmpty {
                if useTruecolor {
                    buf += "\(fg(theme.critical))"
                } else {
                    buf += "\(CSI)31m"
                }
                buf += padRight("???", width: hostWidth)
                buf += "\(CSI)0m"
            } else {
                let ip = hop.primaryAddress ?? "???"
                let hostname = config.numeric ? nil : resolver.cachedHostname(for: ip)
                let hostStr: String
                if let hostname, config.showIPs {
                    hostStr = "\(hostname) (\(ip))"
                } else if let hostname {
                    hostStr = hostname
                } else {
                    hostStr = ip
                }

                // AS number prefix consumes space within hostWidth
                if config.showASN, let asInfo = resolver.cachedASInfo(for: ip) {
                    let asStr = formatASInfo(asInfo, mode: config.ipInfoMode)
                    let prefix = "\(asStr) "
                    let prefixDisplayWidth = displayWidth(prefix)
                    let remaining = hostWidth - prefixDisplayWidth
                    let truncatedHost = String(hostStr.prefix(max(0, remaining)))
                    if useTruecolor {
                        buf += "\(fg(theme.magenta))\(prefix)\(CSI)0m"
                    } else {
                        buf += "\(CSI)36m\(prefix)\(CSI)0m"
                    }
                    buf += padRight(truncatedHost, width: max(0, remaining))
                } else {
                    let truncatedHost = String(hostStr.prefix(hostWidth))
                    buf += padRight(truncatedHost, width: hostWidth)
                }
            }

            // Field values
            for field in fields {
                let value = fieldValue(hop: hop, field: field)
                let colored = colorizeValue(value, field: field, hop: hop)
                buf += " " + colored
            }

            buf += "\r\n"
        }

        // Scroll indicators
        if hopCount > availableRows {
            if scrollOffset > 0 {
                if useTruecolor {
                    buf += "\(fg(theme.dim))  \u{25b2} more above (press -)\(CSI)0m\r\n"
                } else {
                    buf += "\(CSI)33m-- more above (press -) --\(CSI)0m\r\n"
                }
            }
            if visibleEnd < hopCount {
                if useTruecolor {
                    buf += "\(fg(theme.dim))  \u{25bc} more below (press +)\(CSI)0m\r\n"
                } else {
                    buf += "\(CSI)33m-- more below (press +) --\(CSI)0m\r\n"
                }
            }
        }

        return buf
    }

    // MARK: - Stripchart Mode (Mode 1 & 2)

    private func drawStripchartMode(trace: MtrTrace, config: MtrCommandParser.MtrConfig,
                                     resolver: MtrDNSResolver, showNumbers: Bool) -> String {
        var buf = ""
        let hopCount = trace.displayableHopCount
        let hostWidth = 20
        let numberWidth = showNumbers ? 28 : 0  // Space for Last/Avg/Best/Wrst
        let chartWidth = max(10, Int(cols) - hostWidth - numberWidth - 6)

        // Header
        if useTruecolor {
            buf += "\(CSI)1m\(fg(theme.blue))"
        } else {
            buf += "\(CSI)1m"
        }
        buf += "     " + padRight("Host", width: hostWidth)
        if showNumbers {
            buf += "   Last   Avg  Best  Wrst"
        }
        buf += "  Chart"
        buf += "\(CSI)0m\r\n"

        // Separator (truecolor only)
        if useTruecolor {
            buf += "\(fg(theme.dim))\(String(repeating: "─", count: Int(cols)))\(CSI)0m\r\n"
        }

        let availableRows = max(1, Int(rows) - stripchartHeaderRowCount)
        let visibleStart = scrollOffset
        let visibleEnd = min(hopCount, visibleStart + availableRows)

        for hopIndex in visibleStart..<visibleEnd {
            let hop = trace.hops[hopIndex]
            let ttl = hopIndex + 1

            // Hop number
            if useTruecolor {
                buf += "\(fg(theme.blue))\(String(format: "%3d.", ttl))\(CSI)0m "
            } else {
                buf += String(format: "%3d. ", ttl)
            }

            // Host name
            let hostStr: String
            if hop.addresses.isEmpty {
                hostStr = "???"
            } else {
                let ip = hop.primaryAddress ?? "???"
                let hostname = config.numeric ? nil : resolver.cachedHostname(for: ip)
                hostStr = hostname ?? ip
            }

            if hop.addresses.isEmpty {
                if useTruecolor {
                    buf += "\(fg(theme.critical))\(padRight(String(hostStr.prefix(hostWidth)), width: hostWidth))\(CSI)0m"
                } else {
                    buf += "\(CSI)31m\(padRight(String(hostStr.prefix(hostWidth)), width: hostWidth))\(CSI)0m"
                }
            } else {
                buf += padRight(String(hostStr.prefix(hostWidth)), width: hostWidth)
            }

            // Numbers (mode 2 with truecolor gradient)
            if showNumbers && hop.timed > 0 {
                if useTruecolor && hop.bestRTT > 0 {
                    let lastStr = String(format: "%5.1f", hop.lastRTT)
                    let avgStr = String(format: "%5.1f", hop.avgRTT)
                    let bestStr = String(format: "%5.1f", hop.bestRTT)
                    let wrstStr = String(format: "%5.1f", hop.worstRTT)

                    let lastC = latencyColor(ratio: hop.lastRTT / hop.bestRTT)
                    let avgC = latencyColor(ratio: hop.avgRTT / hop.bestRTT)
                    let wrstC = latencyColor(ratio: hop.worstRTT / hop.bestRTT)

                    buf += " \(fg(lastC))\(lastStr)\(CSI)0m"
                    buf += " \(fg(avgC))\(avgStr)\(CSI)0m"
                    buf += " \(fg(theme.good))\(bestStr)\(CSI)0m"
                    buf += " \(fg(wrstC))\(wrstStr)\(CSI)0m"
                } else {
                    buf += String(format: " %5.1f %5.1f %5.1f %5.1f",
                                 hop.lastRTT, hop.avgRTT, hop.bestRTT, hop.worstRTT)
                }
            } else if showNumbers {
                buf += "                          "
            }

            buf += " "

            // Draw chart using ring buffer
            let chartStr = drawStripchartBar(hop: hop, width: chartWidth)
            buf += chartStr
            buf += "\r\n"
        }

        return buf
    }

    private func drawStripchartBar(hop: HopStatistics, width: Int) -> String {
        let blocks = ["\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}"]
        var bar = ""
        guard !hop.samples.isEmpty else { return String(repeating: " ", count: width) }

        let sampleCount = min(width, hop.sampleIndex, hop.samples.count)
        let startIndex = max(0, hop.sampleIndex - sampleCount)

        for i in startIndex..<hop.sampleIndex {
            let sample = hop.samples[i % hop.samples.count]

            switch sample {
            case .empty:
                bar += " "
            case .reply(nil):
                bar += "·"
            case .reply(let rtt?):
                let ratio = hop.bestRTT > 0 ? rtt / hop.bestRTT : 1
                // Scale: 1x=block0, 2x=block2, 5x=block5, 10x+=block7
                let scaled = log2(max(1, ratio)) * 2
                let blockIndex: Int
                if scaled.isFinite, scaled >= 0 {
                    blockIndex = min(blocks.count - 1, Int(scaled))
                } else {
                    blockIndex = 0
                }

                if useTruecolor {
                    let color = latencyColor(ratio: ratio)
                    bar += "\(fg(color))\(blocks[blockIndex])\(CSI)0m"
                } else {
                    // Classic 3-step coloring
                    if ratio <= 2.0 {
                        bar += "\u{1b}[32m\(blocks[blockIndex])\u{1b}[0m"
                    } else if ratio <= 5.0 {
                        bar += "\u{1b}[33m\(blocks[blockIndex])\u{1b}[0m"
                    } else {
                        bar += "\u{1b}[31m\(blocks[blockIndex])\u{1b}[0m"
                    }
                }
            case .timeout:
                if useTruecolor {
                    bar += "\(fg(theme.critical))?\(CSI)0m"
                } else {
                    bar += "\u{1b}[31m?\u{1b}[0m"
                }
            }
        }

        return bar
    }

    // MARK: - Help Overlay

    private func drawHelpOverlay() -> String {
        var buf = "\r\n"

        if useTruecolor {
            buf += "\(CSI)1m\(fg(theme.accent))Keyboard Commands:\(CSI)0m\r\n"

            func helpLine(_ keys: String, _ desc: String) -> String {
                "  \(CSI)1m\(fg(theme.accent))\(keys)\(CSI)0m\(fg(theme.dim))\(desc)\(CSI)0m\r\n"
            }

            buf += helpLine("q        ", " Quit")
            buf += helpLine("h, ?     ", " Show/hide this help")
            buf += helpLine("p, Space ", " Pause/resume probing")
            buf += helpLine("d        ", " Cycle display mode")
            buf += helpLine("n        ", " Toggle DNS resolution")
            buf += helpLine("r        ", " Reset all statistics")
            buf += helpLine("z        ", " Toggle AS number display")
            buf += helpLine("y        ", " Cycle IP info mode (AS/prefix/country/RIR/date/name/continent)")
            buf += helpLine("b        ", " Toggle show both IP and hostname")
            buf += helpLine("j        ", " Toggle latency/jitter columns")
            buf += helpLine("t        ", " Toggle truecolor/classic rendering")
            buf += helpLine("+, -     ", " Scroll up/down")
            buf += helpLine("i        ", " Change probe interval")
            buf += helpLine("f        ", " Change first TTL")
            buf += helpLine("m        ", " Change max TTL")
            buf += helpLine("s        ", " Change packet size")
            buf += helpLine("Ctrl-L   ", " Force redraw")
            buf += "\r\n  \(fg(theme.dim))Press h to close this help\(CSI)0m\r\n"
        } else {
            buf += "\(CSI)1mKeyboard Commands:\(CSI)0m\r\n"
            buf += "  q         Quit\r\n"
            buf += "  h, ?      Show/hide this help\r\n"
            buf += "  p, Space  Pause/resume probing\r\n"
            buf += "  d         Cycle display mode\r\n"
            buf += "  n         Toggle DNS resolution\r\n"
            buf += "  r         Reset all statistics\r\n"
            buf += "  z         Toggle AS number display\r\n"
            buf += "  y         Cycle IP info mode (AS/prefix/country/RIR/date/name/continent)\r\n"
            buf += "  b         Toggle show both IP and hostname\r\n"
            buf += "  j         Toggle latency/jitter columns\r\n"
            buf += "  t         Toggle truecolor/classic rendering\r\n"
            buf += "  +, -      Scroll up/down\r\n"
            buf += "  i         Change probe interval\r\n"
            buf += "  f         Change first TTL\r\n"
            buf += "  m         Change max TTL\r\n"
            buf += "  s         Change packet size\r\n"
            buf += "  Ctrl-L    Force redraw\r\n"
            buf += "\r\n  Press h to close this help\r\n"
        }
        buf += "\r\n  Chart: · reply without RTT, ? timeout\r\n"
        return buf
    }

    // MARK: - Field Configuration

    struct FieldConfig {
        let letter: Character
        let header: String
        let width: Int
    }

    func parseFieldOrder(_ order: String) -> [FieldConfig] {
        var fields: [FieldConfig] = []
        for char in order {
            if char == " " { continue }
            switch char {
            case "L": fields.append(FieldConfig(letter: "L", header: "Loss%", width: 6))
            case "D": fields.append(FieldConfig(letter: "D", header: "Drop", width: 6))
            case "R": fields.append(FieldConfig(letter: "R", header: "Rcv", width: 6))
            case "S": fields.append(FieldConfig(letter: "S", header: "Snt", width: 6))
            case "N": fields.append(FieldConfig(letter: "N", header: "Last", width: 6))
            case "B": fields.append(FieldConfig(letter: "B", header: "Best", width: 6))
            case "A": fields.append(FieldConfig(letter: "A", header: "Avg", width: 6))
            case "W": fields.append(FieldConfig(letter: "W", header: "Wrst", width: 6))
            case "V": fields.append(FieldConfig(letter: "V", header: "StDev", width: 6))
            case "G": fields.append(FieldConfig(letter: "G", header: "Gmean", width: 6))
            case "J": fields.append(FieldConfig(letter: "J", header: "Javg", width: 6))
            case "M": fields.append(FieldConfig(letter: "M", header: "Jmax", width: 6))
            case "X": fields.append(FieldConfig(letter: "X", header: "Jint", width: 6))
            default: break
            }
        }
        return fields
    }

    private func fieldValue(hop: HopStatistics, field: FieldConfig) -> String {
        guard hop.sent > 0 else { return "     -" }

        switch field.letter {
        case "L": return String(format: "%5.1f%%", hop.lossPercent)
        case "D": return String(format: "%6d", hop.dropped)
        case "R": return String(format: "%6d", hop.received)
        case "S": return String(format: "%6d", hop.sent)
        case "N":
            guard hop.timed > 0 else { return "     -" }
            return String(format: "%6.1f", hop.lastRTT)
        case "B":
            guard hop.timed > 0 else { return "     -" }
            return String(format: "%6.1f", hop.bestRTT)
        case "A":
            guard hop.timed > 0 else { return "     -" }
            return String(format: "%6.1f", hop.avgRTT)
        case "W":
            guard hop.timed > 0 else { return "     -" }
            return String(format: "%6.1f", hop.worstRTT)
        case "V":
            guard hop.timed > 1 else { return "     -" }
            return String(format: "%6.1f", hop.stddev)
        case "G":
            guard hop.timed > 0 else { return "     -" }
            return String(format: "%6.1f", hop.geometricMean)
        case "J":
            guard hop.timed > 1 else { return "     -" }
            return String(format: "%6.1f", hop.avgJitter)
        case "M":
            guard hop.timed > 1 else { return "     -" }
            return String(format: "%6.1f", hop.worstJitter)
        case "X":
            guard hop.timed > 1 else { return "     -" }
            return String(format: "%6.1f", hop.interarrivalJitter)
        default: return "     -"
        }
    }

    private func colorizeValue(_ value: String, field: FieldConfig, hop: HopStatistics) -> String {
        guard hop.sent > 0 else { return value }

        if useTruecolor {
            return colorizeValueTruecolor(value, field: field, hop: hop)
        } else {
            return colorizeValueClassic(value, field: field, hop: hop)
        }
    }

    /// Classic 16-color ANSI value coloring (original behavior).
    private func colorizeValueClassic(_ value: String, field: FieldConfig, hop: HopStatistics) -> String {
        if field.letter == "L" && hop.sent > 0 {
            if hop.lossPercent > 50 {
                return "\(CSI)31m\(value)\(CSI)0m"  // Red
            } else if hop.lossPercent > 10 {
                return "\(CSI)33m\(value)\(CSI)0m"  // Yellow
            } else if hop.lossPercent > 0 {
                return "\(CSI)33m\(value)\(CSI)0m"  // Yellow
            }
        }
        return value
    }

    /// Truecolor gradient value coloring using theme palette.
    private func colorizeValueTruecolor(_ value: String, field: FieldConfig, hop: HopStatistics) -> String {
        switch field.letter {
        case "L":
            guard hop.lossPercent > 0 else { return value }
            let color = lossColor(hop.lossPercent)
            return "\(fg(color))\(value)\(CSI)0m"

        case "D":
            guard hop.dropped > 0 else { return value }
            return "\(fg(theme.critical))\(value)\(CSI)0m"

        case "N":
            guard hop.timed > 0, hop.bestRTT > 0 else { return value }
            let ratio = hop.lastRTT / hop.bestRTT
            return "\(fg(latencyColor(ratio: ratio)))\(value)\(CSI)0m"

        case "B":
            guard hop.timed > 0 else { return value }
            return "\(fg(theme.good))\(value)\(CSI)0m"

        case "A":
            guard hop.timed > 0, hop.bestRTT > 0 else { return value }
            let ratio = hop.avgRTT / hop.bestRTT
            return "\(fg(latencyColor(ratio: ratio)))\(value)\(CSI)0m"

        case "W":
            guard hop.timed > 0, hop.bestRTT > 0 else { return value }
            let ratio = hop.worstRTT / hop.bestRTT
            return "\(fg(latencyColor(ratio: ratio)))\(value)\(CSI)0m"

        case "V":
            guard hop.timed > 1, hop.avgRTT > 0 else { return value }
            let relStddev = hop.stddev / hop.avgRTT
            if relStddev > 0.5 { return "\(fg(theme.critical))\(value)\(CSI)0m" }
            if relStddev > 0.2 { return "\(fg(theme.warning))\(value)\(CSI)0m" }
            return value

        default:
            return value
        }
    }

    private func formatASInfo(_ info: GeoInfo, mode: Int) -> String {
        // Fall back to AS number for modes that have no data from this provider
        let value: String
        switch mode {
        case 0: value = info.asNumber
        case 1: value = info.prefix.isEmpty ? info.asNumber : info.prefix
        case 2: value = info.country.isEmpty ? info.asNumber : info.countryWithFlag
        case 3: value = info.rir.isEmpty ? info.asNumber : info.rir
        case 4: value = info.allocationDate.isEmpty ? info.asNumber : info.allocationDate
        case 5: value = info.asName ?? info.asNumber
        case 6:
            if let continent = info.continentCode, !continent.isEmpty {
                value = continent
            } else if !info.country.isEmpty {
                value = info.country
            } else {
                value = info.asNumber
            }
        default: value = info.asNumber
        }
        return "[\(value)]"
    }

    private func formatDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM  d HH:mm:ss yyyy"
        return formatter.string(from: Date())
    }

    // MARK: - Scroll Control

    func scrollUp() {
        if scrollOffset > 0 {
            scrollOffset -= 1
        }
    }

    func scrollDown(maxHops: Int) {
        let availableRows = max(1, Int(rows) - headerRowCount)
        if scrollOffset + availableRows < maxHops {
            scrollOffset += 1
        }
    }

    func resetScroll() {
        scrollOffset = 0
    }

    var isShowingHelp: Bool {
        get { showHelp }
        set { showHelp = newValue }
    }

    var isPaused: Bool {
        get { paused }
        set { paused = newValue }
    }

    // MARK: - String Padding Helpers

    /// Pad a string to `width` characters, right-aligned (left-padded with spaces).
    private func padLeft(_ str: String, width: Int) -> String {
        let len = str.count
        if len >= width { return str }
        return String(repeating: " ", count: width - len) + str
    }

    /// Pad a string to `width` characters, left-aligned (right-padded with spaces).
    private func padRight(_ str: String, width: Int) -> String {
        let len = str.count
        if len >= width { return str }
        return str + String(repeating: " ", count: width - len)
    }

    /// Calculate terminal display width of a string, accounting for wide characters
    /// (emoji flags, CJK, etc.) that occupy 2 columns but count as 1 Swift character.
    private func displayWidth(_ str: String) -> Int {
        var width = 0
        for char in str {
            if char.unicodeScalars.count > 1 {
                // Multi-scalar grapheme clusters (flag emoji, ZWJ sequences, etc.)
                // render as 2 columns in terminals
                width += 2
            } else {
                width += 1
            }
        }
        return width
    }
}

#endif // !targetEnvironment(macCatalyst)
