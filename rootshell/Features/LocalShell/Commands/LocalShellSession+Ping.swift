#if !targetEnvironment(macCatalyst)

import Foundation

extension LocalShellSession {
    /// Handle a ping or ping6 command
    func handlePingCommand(_ command: String) {
        let result = PingCommandParser.parse(command: command)

        switch result {
        case .success(let config):
            let pingCommand = PingCommand(config: config, output: outputSink.emitString)
            pingCommand.onComplete = { [weak self, weak pingCommand] status in
                guard let self, let pingCommand, self.activePingCommand === pingCommand else { return }
                self.activePingCommand = nil
                self.sessionMode = .localShell
                self.lastCommandSucceeded = status == 0
                self.scriptCommandExitCode = status

                // Avoid emitting a prompt/title update while the session is shutting down.
                guard self.isRunning else { return }
                self.onTitleChange?(self.formatPathForTitle(sessionCurrentDirectory))
                self.displayPrompt()
            }

            sessionMode = .pingRunning
            activePingCommand = pingCommand

            // Update tab title
            let target = config.target
            let truncatedTarget = String(target.prefix(30))
            onTitleChange?("ping \(truncatedTarget)")

            pingCommand.start()

        case .help:
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displayPingHelp()

        case .error(let message):
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            onOutput?("ping: \(message)\r\n")
            displayPrompt()
        }
    }

    /// Display ping usage help
    func displayPingHelp() {
        let helpText = """
usage: ping [-DdnQqRrov] [-c count] [-G sweepmaxsize] [-g sweepminsize]
            [-h sweepincrsize] [-i wait] [-k trafficclass] [-l preload]
            [-m TTL] [-p pattern] [-S src_addr] [-s packetsize]
            [-t timeout] [-W waittime] [-b boundif]
            [--apple-connect] [--apple-time] host
       ping6 [-Dnqv] [-c count] [-i wait] [-l preload] [-m hoplimit]
             [-S src_addr] [-s packetsize] host

Options:
  -c count        Stop after sending count packets
  -D              Set Don't Fragment bit (IPv4 only)
  -d              Set SO_DEBUG socket option
  -g size         Sweep minimum packet size
  -G size         Sweep maximum packet size
  -h size         Sweep increment size
  -i wait         Seconds between sending each packet (default: 1)
  -k class        Set traffic class
  -l preload      Send preload packets before entering normal mode
  -m TTL          Set IP Time To Live / IPv6 Hop Limit
  -n              Numeric output only (no DNS lookup for addresses)
  -o              Exit after receiving one reply
  -p pattern      Fill data bytes with hex pattern
  -Q              Quieter output - only show summary
  -q              Quiet output - only show startup and summary
  -R              Record route (IPv4 only)
  -r              Set SO_DONTROUTE socket option
  -S src_addr     Bind to source address
  -s size         Packet data size in bytes (default: 56)
  -t timeout      Overall timeout in seconds
  -v              Verbose output (show ICMP error messages)
  -W waittime     Per-packet timeout in milliseconds (default: 10000)
  -b boundif      Bind to network interface
  --apple-connect Connect socket to target (kernel-level reply filtering)
  --apple-time    Prefix each line with a timestamp (HH:MM:SS.uuuuuu)

"""
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
