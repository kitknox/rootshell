//
//  PipedProcessRegistry.swift
//  rootshell-helper
//
//  Tracks non-PTY children spawned for the app (herdr control streams) so
//  they can be ended by pid and are reaped when the app goes away.
//

import Foundation

final class PipedProcessRegistry {
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]

    func add(_ process: Process) {
        lock.lock()
        processes[process.processIdentifier] = process
        lock.unlock()
    }

    func remove(pid: Int32) {
        lock.lock()
        processes.removeValue(forKey: pid)
        lock.unlock()
    }

    func kill(pid: Int32) {
        lock.lock()
        let process = processes.removeValue(forKey: pid)
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    func killAll() {
        lock.lock()
        let all = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for process in all where process.isRunning {
            process.terminate()
        }
    }
}
