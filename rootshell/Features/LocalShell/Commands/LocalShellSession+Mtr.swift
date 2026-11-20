#if !targetEnvironment(macCatalyst)

import Foundation

extension LocalShellSession {
    /// Handle an mtr, mtr6, traceroute, or traceroute6 command
    func handleMtrCommand(_ command: String) {
        let result = MtrCommandParser.parse(command: command)

        switch result {
        case .success(let config):
            let sink = self.outputSink
            let mtrCommand = MtrCommand(
                config: config,
                cols: pty.windowSize.cols,
                rows: pty.windowSize.rows,
                output: { text in sink.emitString(text) }
            )

            mtrCommand.onComplete = { [weak self, weak mtrCommand] in
                guard let self, let mtrCommand, self.activeMtrCommand === mtrCommand else { return }
                self.activeMtrCommand = nil
                self.sessionMode = .localShell
                self.lastCommandSucceeded = !mtrCommand.didFail
                self.scriptCommandExitCode = mtrCommand.didFail ? 1 : 0

                guard self.isRunning else { return }
                self.onTitleChange?(self.formatPathForTitle(sessionCurrentDirectory))
                self.displayPrompt()
            }

            sessionMode = .mtrRunning
            activeMtrCommand = mtrCommand

            let target = config.target
            let truncatedTarget = String(target.prefix(30))
            onTitleChange?("mtr \(truncatedTarget)")

            mtrCommand.start()

        case .help:
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displayMtrHelp()

        case .error(let message):
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            onOutput?("mtr: \(message)\r\n")
            displayPrompt()
        }
    }

    /// Display mtr usage help
    func displayMtrHelp() {
        let helpText = """
usage: mtr [-46rwnbz] [-c count] [-i interval] [-s packetsize]
           [-f first_ttl] [-m max_ttl] [-B bitpattern] [-Q tos]
           [-G graceperiod] [-o fields] [-y ipinfo] host
       mtr6 [options] host                  (force IPv6)
       traceroute [options] host            (alias: mtr -r -c 3)
       traceroute6 [options] host           (alias: mtr6 -r -c 3)

rootshell traceroute - network path analysis tool (ICMP)

Options:
  -4              Force IPv4
  -6              Force IPv6
  -c count        Number of probe cycles (default: unlimited interactive, 10 report)
  -i interval     Seconds between rounds (default: 1)
  -s size         Packet data size in bytes (default: 64)
  -f ttl          First TTL (default: 1)
  -m ttl          Max TTL (default: 30)
  -B pattern      Bit pattern for payload (0-255, >255 = random)
  -Q tos          Type of Service / traffic class (0-255)
  -G seconds      Grace time after destination found (default: 5)
  -n              No DNS - numeric output only
  -b              Show both IP and hostname
  -z              Show AS number
  -y mode         IP info mode (0=AS, 1=prefix, 2=country, 3=RIR, 4=date, 5=name, 6=continent)
  -o fields       Field order (default: "LS NABWV")
  --displaymode N Display mode (0=stats, 1=stripchart, 2=strip+numbers)

Report modes (non-interactive):
  -r, --report       Standard report
  -w, --report-wide  Wide report (no hostname truncation)
  -C, --csv          CSV output (semicolon-separated)
  -j, --json         JSON output
  -x, --xml          XML output
  -l, --raw          Raw line-by-line output during probing

Interactive keys:
  q         Quit
  h, ?      Help
  d         Cycle display mode
  n         Toggle DNS
  r         Reset statistics
  z         Toggle AS numbers
  y         Cycle IP info mode
  b         Toggle show IPs
  j         Toggle jitter columns
  p, Space  Pause/resume
  +, -      Scroll
  i/f/m/s   Change interval/first-ttl/max-ttl/packet-size

Field letters for -o: L(Loss%) D(Drop) R(Rcv) S(Snt) N(Last) B(Best)
                      A(Avg) W(Wrst) V(StDev) G(Gmean) J(Javg) M(Jmax) X(Jint)

Note: iOS only supports ICMP probes. UDP (-u), TCP (-T), and SCTP are not available.

"""
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
