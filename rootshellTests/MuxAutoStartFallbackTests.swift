import Foundation
import XCTest

final class MuxAutoStartFallbackTests: XCTestCase {

    func testExecLinesFallBackWithMarkerInsteadOfBareShell() {
        let tmux = SSHConfig.tmuxExecCommandLine(sessionName: "main", controlMode: false)
        let herdr = SSHConfig.herdrExecCommandLine(sessionName: "dev")
        let zmx = SSHConfig.zmxExecCommandLine(sessionName: "main")
        for (line, name) in [(tmux, "tmux"), (herdr, "herdr"), (zmx, "zmx")] {
            XCTAssertTrue(line.contains("command -v \(name)"))
            XCTAssertTrue(line.contains("rootshell: mux-fallback \(name)"))
            XCTAssertTrue(line.contains("exec \"${SHELL:-/bin/sh}\""))
            XCTAssertFalse(line.contains("|| exec $SHELL"))
            XCTAssertFalse(
                SSHConfig.muxAutoStartFallbackShellFragment(wanted: name).contains("'"),
                "fallback fragment must stay inside the single-quoted sh -c"
            )
        }
        XCTAssertTrue(tmux.contains("new-session -A -s main"))
        XCTAssertTrue(SSHConfig.tmuxExecCommandLine(sessionName: "main", controlMode: true).contains("-CC "))
    }

    func testMissingBinaryBranchPrintsMarkerThenReplacesTheProcess() throws {
        let fragment = SSHConfig.muxAutoStartFallbackShellFragment(wanted: "zmx")
        let script = "command -v rootshell-no-such-mux >/dev/null && exec rootshell-no-such-mux || \(fragment)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["SHELL"] = "/usr/bin/true"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(text.contains("rootshell: mux-fallback zmx"))
    }

    func testScannerFindsNameSplitAcrossReadsAndFiresOnce() {
        var scanner = MuxAutoStartFallbackScanner()
        let marker = Data(SSHConfig.muxAutoStartFallbackMarkerPrefix.utf8)
        let split = marker.count - 4
        XCTAssertNil(scanner.consume(Data(marker.prefix(split))))
        XCTAssertEqual(
            scanner.consume(Data(marker.dropFirst(split)) + Data("tmux\r\n".utf8)),
            "tmux"
        )
        XCTAssertNil(scanner.consume(Data("rootshell: mux-fallback herdr\n".utf8)))
    }

    func testScannerIgnoresOrdinaryOutput() {
        var scanner = MuxAutoStartFallbackScanner()
        XCTAssertNil(scanner.consume(Data("tmux: command not found\r\n$ ".utf8)))
        XCTAssertNil(scanner.consume(Data("rootshell: mux-fallback tmux".utf8)))
        XCTAssertEqual(scanner.consume(Data("\n".utf8)), "tmux")
    }
}
