//
//  main.swift
//  rootshell-helper
//
//  Main entry point for the rootshell-helper service
//

import Foundation

// MARK: - Main

NSLog("rootshell-helper starting...")

// The spawning app passes --app-group so app and helper agree on the socket
// container. A separately launched helper falls back to the compiled-in value.
let arguments = CommandLine.arguments
if let flagIndex = arguments.firstIndex(of: "--app-group"), flagIndex + 1 < arguments.count {
    AppGroupHelper.overrideGroupIdentifier = arguments[flagIndex + 1]
    NSLog("Using app group from argv: \(arguments[flagIndex + 1])")
}

/// Ends the helper after a bounded, non-blocking teardown of its shells.
func shutDown(_ reason: String) {
    NSLog("\(reason), shutting down")
    SessionManager.shared.shutdown { exit(0) }
}

// Teardown locks and allocates, so it runs from dispatch sources on the main
// queue, not in a signal handler. A no-op handler rather than SIG_IGN, which
// shells would inherit across exec.
var lifetimeSources: [DispatchSourceProtocol] = []
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber) { _ in }
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { shutDown("Received signal \(signalNumber)") }
    source.activate()
    lifetimeSources.append(source)
}

// The spawning app passes its pid. A helper that outlives the app's login
// session can't run login: lookups go through that session's dead bootstrap
// namespace (#637).
if let flagIndex = arguments.firstIndex(of: "--parent-pid"), flagIndex + 1 < arguments.count,
   let parentPID = pid_t(arguments[flagIndex + 1]), parentPID > 1 {
    let source = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
    source.setEventHandler { shutDown("Parent \(parentPID) exited") }
    source.activate()
    lifetimeSources.append(source)
    if getppid() != parentPID {
        NSLog("Parent \(parentPID) already gone, exiting")
        exit(0)
    }
}

// Create socket command server
let server = SocketCommandServer()

// Start socket server
do {
    try server.start()
    NSLog("rootshell-helper socket server started successfully")
} catch {
    NSLog("Failed to start socket server: \(error)")
    exit(1)
}

// Run forever
RunLoop.main.run()
