#if !targetEnvironment(macCatalyst)

import Foundation

// MARK: - ios_system entry points

/// Entry point for `mtr` when invoked via ios_system.
/// ios_system calls this as `int mtr_main(int argc, char* argv[])` on a background thread
/// with `ios_get_thread_stdout()` already redirected to the appropriate pipe.
@_cdecl("mtr_main")
func mtr_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return mtrIOSSystemEntry(argc: argc, argv: argv, forceIPv6: false, isTraceroute: false)
}

/// Entry point for `mtr6` (IPv6-forced mtr).
@_cdecl("mtr6_main")
func mtr6_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return mtrIOSSystemEntry(argc: argc, argv: argv, forceIPv6: true, isTraceroute: false)
}

/// Entry point for `traceroute` (always report mode).
/// Rewrites to `mtr -r -c 3 <remaining args>`.
@_cdecl("traceroute_main")
func traceroute_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return mtrIOSSystemEntry(argc: argc, argv: argv, forceIPv6: false, isTraceroute: true)
}

/// Entry point for `traceroute6` (always report mode, IPv6).
/// Rewrites to `mtr6 -r -c 3 <remaining args>`.
@_cdecl("traceroute6_main")
func traceroute6_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return mtrIOSSystemEntry(argc: argc, argv: argv, forceIPv6: true, isTraceroute: true)
}

// MARK: - Common implementation

/// Common entry point for all mtr/traceroute commands invoked via ios_system.
/// MtrCommand is @MainActor + async, so its output is bridged back to the
/// ios_system thread through `IOSSystemBridge.pump`.
private func mtrIOSSystemEntry(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    forceIPv6: Bool,
    isTraceroute: Bool
) -> Int32 {
    var parts = [forceIPv6 ? "mtr6" : "mtr"]
    if isTraceroute {
        parts += ["-r", "-c", "3"]
    }
    parts += IOSSystemBridge.arguments(argc: argc, argv: argv)

    switch MtrCommandParser.parse(command: parts.joined(separator: " ")) {
    case .error(let message):
        IOSSystemBridge.write("mtr: \(message)\n")
        return 1

    case .help:
        IOSSystemBridge.write("mtr: use --help for usage information\n")
        return 1

    case .success(let config):
        // Interactive mode never routes through ios_system, but guard against it.
        if config.reportMode == nil {
            IOSSystemBridge.write("mtr: interactive mode not supported via ios_system\n")
            return 1
        }

        return IOSSystemBridge.pump(name: "mtr") { writer in
            Task { @MainActor in
                let command = MtrCommand(
                    config: config,
                    cols: 80,
                    rows: 24,
                    output: { text in
                        // Pipe transport uses Unix line endings; the terminal side restores \r.
                        writer.write(text.replacingOccurrences(of: "\r\n", with: "\n"))
                    }
                )
                command.onComplete = {
                    writer.finish(exitStatus: command.didFail ? 1 : 0)
                }
                command.start()
            }
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
