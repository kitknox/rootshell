import Foundation
import OSLog

/// Resolves WASI Preview 1 filesystem operations against a per-process
/// sandbox. Receives one message at a time from the JS host (the Worker is
/// blocked on Atomics.wait while it waits) and replies via
/// `runtime.replyToJS(callID:payload:)`.
@MainActor
final class WasmFilesystemBroker {
    nonisolated static let fsLogger = Logger(subsystem: "com.rootshell", category: "WasmFs")
    func handle(_ dict: [String: Any], process: WasmProcess?, runtime: WasmRuntime) {
        guard let callID = dict["callID"] as? String else { return }
        guard let op = dict["op"] as? String else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        guard let proc = process else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }

        let sandbox = WasmPathSandbox(root: proc.sandboxRoot, cwd: proc.cwd)

        switch op {
        case "path_open":
            pathOpen(dict, proc: proc, sandbox: sandbox, callID: callID, runtime: runtime)
        case "fd_read":
            fdRead(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_write":
            fdWrite(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_close":
            fdClose(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_seek":
            fdSeek(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_filestat_get":
            fdFilestatGet(dict, proc: proc, callID: callID, runtime: runtime)
        case "path_filestat_get":
            pathFilestatGet(dict, proc: proc, sandbox: sandbox, callID: callID, runtime: runtime)
        case "path_create_directory":
            pathCreateDirectory(dict, proc: proc, sandbox: sandbox, callID: callID, runtime: runtime)
        case "path_remove_directory":
            pathRemoveDirectory(dict, proc: proc, sandbox: sandbox, callID: callID, runtime: runtime)
        case "path_unlink_file":
            pathUnlinkFile(dict, proc: proc, sandbox: sandbox, callID: callID, runtime: runtime)
        case "path_rename":
            pathRename(dict, proc: proc, sandbox: sandbox, callID: callID, runtime: runtime)
        case "fd_readdir":
            fdReaddir(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_prestat_get":
            fdPrestatGet(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_prestat_dir_name":
            fdPrestatDirName(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_pread":
            fdPread(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_pwrite":
            fdPwrite(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_filestat_set_size":
            fdFilestatSetSize(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_filestat_set_times":
            fdFilestatSetTimes(dict, proc: proc, callID: callID, runtime: runtime)
        case "fd_sync":
            fdSync(dict, proc: proc, callID: callID, runtime: runtime)
        case "path_filestat_set_times":
            pathFilestatSetTimes(dict, proc: proc, sandbox: sandbox, callID: callID, runtime: runtime)
        default:
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.ENOSYS])
        }
    }

    // MARK: - Path resolution

    /// WASI path_* operations are openat-style: `path` is relative to the
    /// directory referred to by `dirfd`. Most WASI client libraries (Rust
    /// std, wasi-libc, etc.) discover the preopens at startup and ALWAYS
    /// pass paths relative to a preopen — never with a leading slash. We
    /// also accept absolute paths and `~`/`~/...` defensively so that
    /// ported apps which assume shell-style expansion still work without
    /// the shell having pre-expanded the path.
    ///
    /// Path semantics:
    /// - `~`        → sandbox root (= HOME = Documents)
    /// - `~/foo`    → sandbox root + `/foo`
    /// - `/foo`     → sandbox root + `/foo` (virtual-absolute; never the
    ///               device's `/foo`)
    /// - `foo`      → dirfd's URL + `/foo`
    private func resolvePath(_ raw: String,
                             dirfd: Int32,
                             proc: WasmProcess,
                             sandbox: WasmPathSandbox) -> WasmPathSandbox.Resolution {
        if raw.contains("\0") {
            return .denied(reason: "null byte in path")
        }
        // ~ expansion. `~` only expands at the start before a `/` (POSIX).
        if raw == "~" {
            return .allowed(sandbox.root)
        }
        if raw.hasPrefix("~/") {
            return sandbox.resolve("/" + raw.dropFirst(2))
        }
        if raw.hasPrefix("/") {
            return sandbox.resolve(raw)
        }
        guard let dirEntry = proc.fsHandles[dirfd], dirEntry.isDirectory else {
            return .denied(reason: "invalid dirfd \(dirfd)")
        }
        // Use the same canonicalisation as the sandbox root, so both sides
        // of the prefix check agree on whether to use the `/private/` form
        // for app-container paths.
        let combined = dirEntry.url.appendingPathComponent(raw)
        let standardised = WasmPathSandbox.canonical(combined)
        let rootPath = sandbox.root.path
        let candidatePath = standardised.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return .denied(reason: "path escapes sandbox: \(candidatePath)")
        }
        return .allowed(standardised)
    }

    // MARK: - Ops

    private func pathOpen(_ dict: [String: Any],
                          proc: WasmProcess,
                          sandbox: WasmPathSandbox,
                          callID: String,
                          runtime: WasmRuntime) {
        guard let path = dict["path"] as? String,
              let oflagsRaw = (dict["oflags"] as? NSNumber)?.int32Value,
              let fdflagsRaw = (dict["fdflags"] as? NSNumber)?.int32Value
        else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let dirfd = (dict["dirfd"] as? NSNumber)?.int32Value ?? -1

        let oflags = OFlags(rawValue: oflagsRaw)
        let fdflags = FdFlags(rawValue: fdflagsRaw)

        Self.fsLogger.debug("path_open dirfd=\(dirfd, privacy: .public) path=\(path, privacy: .public) oflags=\(oflagsRaw, privacy: .public) fdflags=\(fdflagsRaw, privacy: .public)")

        switch resolvePath(path, dirfd: dirfd, proc: proc, sandbox: sandbox) {
        case .denied(let reason):
            Self.fsLogger.error("path_open denied: \(reason, privacy: .public)")
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EACCES])
        case .allowed(let url):
            Self.fsLogger.debug("path_open resolved -> \(url.path, privacy: .public)")
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)

            if !exists && !oflags.contains(.creat) {
                Self.fsLogger.error("path_open ENOENT: \(url.path, privacy: .public) (oflags=\(oflagsRaw, privacy: .public))")
                runtime.replyToJS(callID: callID, payload: ["errno": Errno.ENOENT])
                return
            }
            if exists && oflags.contains(.excl) && oflags.contains(.creat) {
                runtime.replyToJS(callID: callID, payload: ["errno": Errno.EEXIST])
                return
            }
            if isDir.boolValue {
                let fd = proc.nextFileFd
                proc.nextFileFd += 1
                proc.fsHandles[fd] = WasmProcess.FsHandle(
                    url: url, handle: nil, isDirectory: true
                )
                runtime.replyToJS(callID: callID, payload: ["errno": 0, "fd": fd])
                return
            }

            // Create if requested.
            if !exists && oflags.contains(.creat) {
                fm.createFile(atPath: url.path, contents: nil, attributes: nil)
            }

            // Truncate if requested.
            if oflags.contains(.trunc) {
                try? Data().write(to: url)
            }

            // Determine read/write mode. Default to read-write if neither
            // flag is explicit (matches POSIX-style open semantics that WASI
            // toolchains expect after their layering).
            let handle: FileHandle?
            do {
                if fdflags.contains(.append) || oflags.contains(.creat) || oflags.contains(.trunc) {
                    handle = try FileHandle(forUpdating: url)
                    if fdflags.contains(.append) {
                        try handle?.seekToEnd()
                    }
                } else {
                    handle = try FileHandle(forUpdating: url)
                }
            } catch {
                runtime.replyToJS(callID: callID, payload: ["errno": Errno.EIO])
                return
            }

            let fd = proc.nextFileFd
            proc.nextFileFd += 1
            proc.fsHandles[fd] = WasmProcess.FsHandle(
                url: url, handle: handle, isDirectory: false
            )
            runtime.replyToJS(callID: callID, payload: ["errno": 0, "fd": fd])
        }
    }

    private func fdRead(_ dict: [String: Any],
                        proc: WasmProcess,
                        callID: String,
                        runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let length = (dict["length"] as? NSNumber)?.intValue
        else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        // fd 0 (stdin) is handled by the host JS pulling from the queue; the
        // broker only sees non-std fds here.
        guard let entry = proc.fsHandles[fd], let handle = entry.handle else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        // FileHandle.read is a synchronous syscall — push to the runtime's
        // marshal queue so a WASM tool reading a large file doesn't stall
        // the main actor for the duration of every read chunk.
        runtime.marshalQueue.async {
            let result: (Int32, Data?)
            do {
                let data = try handle.read(upToCount: length) ?? Data()
                result = (0, data)
            } catch {
                result = (Errno.EIO, nil)
            }
            Task { @MainActor in
                if result.0 != 0 {
                    runtime.replyToJS(callID: callID, payload: ["errno": result.0])
                } else {
                    runtime.replyToJS(callID: callID, payload: [
                        "errno": 0,
                        "data": (result.1 ?? Data()).base64EncodedString()
                    ])
                }
            }
        }
    }

    private func fdWrite(_ dict: [String: Any],
                         proc: WasmProcess,
                         callID: String,
                         runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let b64 = dict["data"] as? String
        else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        guard let entry = proc.fsHandles[fd], let handle = entry.handle else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        runtime.marshalQueue.async {
            // Decoding + write on the background queue. Decoding alone for
            // a large write is a real cost on main.
            guard let data = Data(base64Encoded: b64) else {
                Task { @MainActor in
                    runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
                }
                return
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                Task { @MainActor in
                    runtime.replyToJS(callID: callID, payload: ["errno": Errno.EIO])
                }
                return
            }
            Task { @MainActor in
                runtime.replyToJS(callID: callID, payload: ["errno": 0, "written": data.count])
            }
        }
    }

    private func fdClose(_ dict: [String: Any],
                         proc: WasmProcess,
                         callID: String,
                         runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        if fd <= 4 {
            // Preopens / std fds cannot be closed.
            runtime.replyToJS(callID: callID, payload: ["errno": 0])
            return
        }
        if let entry = proc.fsHandles.removeValue(forKey: fd) {
            try? entry.handle?.close()
        }
        runtime.replyToJS(callID: callID, payload: ["errno": 0])
    }

    private func fdSeek(_ dict: [String: Any],
                        proc: WasmProcess,
                        callID: String,
                        runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let offset = (dict["offset"] as? NSNumber)?.int64Value,
              let whence = (dict["whence"] as? NSNumber)?.int32Value
        else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        guard let entry = proc.fsHandles[fd], let handle = entry.handle else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        do {
            let new: UInt64
            switch whence {
            case 0: // SET
                try handle.seek(toOffset: UInt64(max(0, offset)))
                new = UInt64(max(0, offset))
            case 1: // CUR
                let cur = try handle.offset()
                let target = Int64(cur) + offset
                let safe = UInt64(max(0, target))
                try handle.seek(toOffset: safe)
                new = safe
            case 2: // END
                try handle.seekToEnd()
                let end = try handle.offset()
                let target = Int64(end) + offset
                let safe = UInt64(max(0, target))
                try handle.seek(toOffset: safe)
                new = safe
            default:
                runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
                return
            }
            runtime.replyToJS(callID: callID, payload: ["errno": 0, "offset": NSNumber(value: new)])
        } catch {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EIO])
        }
    }

    private func fdFilestatGet(_ dict: [String: Any],
                               proc: WasmProcess,
                               callID: String,
                               runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let entry = proc.fsHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        replyStat(url: entry.url, isDirectoryHint: entry.isDirectory, callID: callID, runtime: runtime)
    }

    private func pathFilestatGet(_ dict: [String: Any],
                                 proc: WasmProcess,
                                 sandbox: WasmPathSandbox,
                                 callID: String,
                                 runtime: WasmRuntime) {
        guard let path = dict["path"] as? String else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let dirfd = (dict["dirfd"] as? NSNumber)?.int32Value ?? -1
        switch resolvePath(path, dirfd: dirfd, proc: proc, sandbox: sandbox) {
        case .denied:
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EACCES])
        case .allowed(let url):
            replyStat(url: url, isDirectoryHint: nil, callID: callID, runtime: runtime)
        }
    }

    private func pathCreateDirectory(_ dict: [String: Any],
                                     proc: WasmProcess,
                                     sandbox: WasmPathSandbox,
                                     callID: String,
                                     runtime: WasmRuntime) {
        guard let path = dict["path"] as? String else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let dirfd = (dict["dirfd"] as? NSNumber)?.int32Value ?? -1
        switch resolvePath(path, dirfd: dirfd, proc: proc, sandbox: sandbox) {
        case .denied:
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EACCES])
        case .allowed(let url):
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                runtime.replyToJS(callID: callID, payload: ["errno": 0])
            } catch {
                Self.fsLogger.error("createDirectory failed: \(error.localizedDescription, privacy: .public)")
                runtime.replyToJS(callID: callID, payload: ["errno": Errno.EIO])
            }
        }
    }

    private func pathRemoveDirectory(_ dict: [String: Any],
                                     proc: WasmProcess,
                                     sandbox: WasmPathSandbox,
                                     callID: String,
                                     runtime: WasmRuntime) {
        guard let path = dict["path"] as? String else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let dirfd = (dict["dirfd"] as? NSNumber)?.int32Value ?? -1
        switch resolvePath(path, dirfd: dirfd, proc: proc, sandbox: sandbox) {
        case .denied:
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EACCES])
        case .allowed(let url):
            do {
                try FileManager.default.removeItem(at: url)
                runtime.replyToJS(callID: callID, payload: ["errno": 0])
            } catch {
                runtime.replyToJS(callID: callID, payload: ["errno": Errno.EIO])
            }
        }
    }

    private func pathUnlinkFile(_ dict: [String: Any],
                                proc: WasmProcess,
                                sandbox: WasmPathSandbox,
                                callID: String,
                                runtime: WasmRuntime) {
        guard let path = dict["path"] as? String else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let dirfd = (dict["dirfd"] as? NSNumber)?.int32Value ?? -1
        switch resolvePath(path, dirfd: dirfd, proc: proc, sandbox: sandbox) {
        case .denied:
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EACCES])
        case .allowed(let url):
            do {
                try FileManager.default.removeItem(at: url)
                runtime.replyToJS(callID: callID, payload: ["errno": 0])
            } catch {
                runtime.replyToJS(callID: callID, payload: ["errno": Errno.EIO])
            }
        }
    }

    private func pathRename(_ dict: [String: Any],
                            proc: WasmProcess,
                            sandbox: WasmPathSandbox,
                            callID: String,
                            runtime: WasmRuntime) {
        guard let oldPath = dict["oldPath"] as? String,
              let newPath = dict["newPath"] as? String else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let oldDirfd = (dict["oldDirfd"] as? NSNumber)?.int32Value ?? -1
        let newDirfd = (dict["newDirfd"] as? NSNumber)?.int32Value ?? oldDirfd
        guard case .allowed(let from) = resolvePath(oldPath, dirfd: oldDirfd, proc: proc, sandbox: sandbox),
              case .allowed(let to) = resolvePath(newPath, dirfd: newDirfd, proc: proc, sandbox: sandbox) else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EACCES])
            return
        }
        do {
            try FileManager.default.moveItem(at: from, to: to)
            runtime.replyToJS(callID: callID, payload: ["errno": 0])
        } catch {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EIO])
        }
    }

    private func fdReaddir(_ dict: [String: Any],
                           proc: WasmProcess,
                           callID: String,
                           runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let entry = proc.fsHandles[fd], entry.isDirectory else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.ENOTDIR])
            return
        }
        let cookie = max(0, (dict["cookie"] as? NSNumber)?.intValue ?? 0)
        let bufLen = max(0, (dict["bufLen"] as? NSNumber)?.intValue ?? 0)
        if cookie == 0 || entry.dirEntries == nil {
            let contents = (try? FileManager.default.contentsOfDirectory(at: entry.url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            entry.dirEntries = contents.map { url in
                (url.lastPathComponent, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            }
        }
        let all = entry.dirEntries ?? []
        // Pages of 24-byte dirent header + name keep the JSON reply inside
        // the 64 KB reply buffer; the worker pages until its buffer is full.
        let budget = min(bufLen, 8 * 1024)
        var page: [[String: Any]] = []
        var used = 0
        var i = cookie
        while i < all.count, used < budget || page.isEmpty {
            page.append(["name": all[i].name, "isDir": all[i].isDir])
            used += 24 + all[i].name.utf8.count
            i += 1
        }
        runtime.replyToJS(callID: callID, payload: ["errno": 0, "entries": page])
    }

    private func fdPrestatGet(_ dict: [String: Any],
                              proc: WasmProcess,
                              callID: String,
                              runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        guard let entry = proc.fsHandles[fd], entry.isPreopen,
              let name = entry.preopenName else {
            Self.fsLogger.debug("fd_prestat_get(\(fd, privacy: .public)) -> EBADF (no preopen)")
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        Self.fsLogger.debug("fd_prestat_get(\(fd, privacy: .public)) -> name=\(name, privacy: .public) len=\(name.utf8.count, privacy: .public)")
        runtime.replyToJS(callID: callID, payload: [
            "errno": 0,
            "type": 0, // dir
            "nameLen": name.utf8.count
        ])
    }

    private func fdPrestatDirName(_ dict: [String: Any],
                                  proc: WasmProcess,
                                  callID: String,
                                  runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let entry = proc.fsHandles[fd], entry.isPreopen,
              let name = entry.preopenName else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        Self.fsLogger.debug("fd_prestat_dir_name(\(fd, privacy: .public)) -> \(name, privacy: .public)")
        runtime.replyToJS(callID: callID, payload: [
            "errno": 0,
            "name": name
        ])
    }

    private func replyStat(url: URL, isDirectoryHint: Bool?, callID: String, runtime: WasmRuntime) {
        var attrs: [FileAttributeKey: Any]?
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.ENOENT])
            return
        }
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let isDir: Bool = {
            if let hint = isDirectoryHint { return hint }
            return (attrs?[.type] as? FileAttributeType) == .typeDirectory
        }()
        runtime.replyToJS(callID: callID, payload: [
            "errno": 0,
            "size": NSNumber(value: size),
            "mtime": NSNumber(value: UInt64(mtime * 1_000_000_000)),
            "type": isDir ? 3 : 4   // WASI: 3 = dir, 4 = regular file
        ])
    }

    // MARK: - Positioned I/O (POSIX pread/pwrite semantics)

    /// pread leaves the fd's seek position untouched. Foundation's FileHandle
    /// has no positional read API, so we save the offset, seek + read, then
    /// restore. Marshal queue keeps multi-MB chunks off the main actor.
    private func fdPread(_ dict: [String: Any],
                         proc: WasmProcess,
                         callID: String,
                         runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let offset = (dict["offset"] as? NSNumber)?.uint64Value,
              let length = (dict["length"] as? NSNumber)?.intValue
        else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        guard let entry = proc.fsHandles[fd], let handle = entry.handle else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        runtime.marshalQueue.async {
            let result: (Int32, Data?)
            do {
                let saved = try handle.offset()
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: length) ?? Data()
                try handle.seek(toOffset: saved)
                result = (0, data)
            } catch {
                result = (Errno.EIO, nil)
            }
            Task { @MainActor in
                if result.0 != 0 {
                    runtime.replyToJS(callID: callID, payload: ["errno": result.0])
                } else {
                    runtime.replyToJS(callID: callID, payload: [
                        "errno": 0,
                        "data": (result.1 ?? Data()).base64EncodedString()
                    ])
                }
            }
        }
    }

    private func fdPwrite(_ dict: [String: Any],
                          proc: WasmProcess,
                          callID: String,
                          runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let offset = (dict["offset"] as? NSNumber)?.uint64Value,
              let b64 = dict["data"] as? String
        else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        guard let entry = proc.fsHandles[fd], let handle = entry.handle else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        runtime.marshalQueue.async {
            guard let data = Data(base64Encoded: b64) else {
                Task { @MainActor in
                    runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
                }
                return
            }
            let result: Int32
            do {
                let saved = try handle.offset()
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: data)
                try handle.seek(toOffset: saved)
                result = 0
            } catch {
                result = Errno.EIO
            }
            Task { @MainActor in
                if result != 0 {
                    runtime.replyToJS(callID: callID, payload: ["errno": result])
                } else {
                    runtime.replyToJS(callID: callID, payload: ["errno": 0, "written": data.count])
                }
            }
        }
    }

    // MARK: - Truncate, sync, mtime preservation

    private func fdFilestatSetSize(_ dict: [String: Any],
                                   proc: WasmProcess,
                                   callID: String,
                                   runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let size = (dict["size"] as? NSNumber)?.uint64Value
        else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        guard let entry = proc.fsHandles[fd], let handle = entry.handle else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        do {
            try handle.truncate(atOffset: size)
            runtime.replyToJS(callID: callID, payload: ["errno": 0])
        } catch {
            Self.fsLogger.error("truncate failed: \(error.localizedDescription, privacy: .public)")
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EIO])
        }
    }

    private func fdFilestatSetTimes(_ dict: [String: Any],
                                    proc: WasmProcess,
                                    callID: String,
                                    runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let flags = (dict["flags"] as? NSNumber)?.uint32Value
        else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        guard let entry = proc.fsHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        let atim = (dict["atim"] as? NSNumber)?.uint64Value ?? 0
        let mtim = (dict["mtim"] as? NSNumber)?.uint64Value ?? 0
        applyTimes(url: entry.url, atimNs: atim, mtimNs: mtim, flags: flags,
                   callID: callID, runtime: runtime)
    }

    private func pathFilestatSetTimes(_ dict: [String: Any],
                                      proc: WasmProcess,
                                      sandbox: WasmPathSandbox,
                                      callID: String,
                                      runtime: WasmRuntime) {
        guard let path = dict["path"] as? String,
              let flags = (dict["flags"] as? NSNumber)?.uint32Value
        else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let dirfd = (dict["dirfd"] as? NSNumber)?.int32Value ?? -1
        let atim = (dict["atim"] as? NSNumber)?.uint64Value ?? 0
        let mtim = (dict["mtim"] as? NSNumber)?.uint64Value ?? 0
        switch resolvePath(path, dirfd: dirfd, proc: proc, sandbox: sandbox) {
        case .denied:
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EACCES])
        case .allowed(let url):
            applyTimes(url: url, atimNs: atim, mtimNs: mtim, flags: flags,
                       callID: callID, runtime: runtime)
        }
    }

    /// WASI fst_flags: bit 0 = ATIM, 1 = ATIM_NOW, 2 = MTIM, 3 = MTIM_NOW.
    /// FileManager exposes modificationDate / creationDate but not atime, so
    /// we set mtime when requested and silently drop atime — rclone only
    /// cares about mtime for sync decisions.
    private func applyTimes(url: URL,
                            atimNs: UInt64,
                            mtimNs: UInt64,
                            flags: UInt32,
                            callID: String,
                            runtime: WasmRuntime) {
        var attrs: [FileAttributeKey: Any] = [:]
        if flags & 0x04 != 0 {
            attrs[.modificationDate] = Date(timeIntervalSince1970: Double(mtimNs) / 1_000_000_000)
        } else if flags & 0x08 != 0 {
            attrs[.modificationDate] = Date()
        }
        if attrs.isEmpty {
            runtime.replyToJS(callID: callID, payload: ["errno": 0])
            return
        }
        do {
            try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
            runtime.replyToJS(callID: callID, payload: ["errno": 0])
        } catch {
            Self.fsLogger.error("setAttributes failed: \(error.localizedDescription, privacy: .public)")
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EIO])
        }
    }

    /// fsync(2) via the raw descriptor. FileHandle.synchronize() is deprecated;
    /// using Darwin.fsync keeps the call path on supported API. Stdio fds
    /// short-circuit in the JS shim before reaching here.
    private func fdSync(_ dict: [String: Any],
                        proc: WasmProcess,
                        callID: String,
                        runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        guard let entry = proc.fsHandles[fd], let handle = entry.handle else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        let rc = Darwin.fsync(handle.fileDescriptor)
        runtime.replyToJS(callID: callID, payload: ["errno": rc == 0 ? 0 : Errno.EIO])
    }
}

// MARK: - WASI flags + errno

nonisolated enum Errno {
    static let EPERM:  Int32 = 63
    static let ENOENT: Int32 = 44
    static let EIO:    Int32 = 29
    static let EBADF:  Int32 = 8
    static let EACCES: Int32 = 2
    static let EEXIST: Int32 = 20
    static let ENOTDIR: Int32 = 54
    static let EINVAL: Int32 = 28
    static let ENOSYS: Int32 = 52
    static let EAGAIN: Int32 = 6
    static let EADDRINUSE: Int32 = 1
    static let ECONNREFUSED: Int32 = 14
    static let ENETUNREACH: Int32 = 50
    static let ETIMEDOUT: Int32 = 73
    static let EINTR:  Int32 = 27
    static let EFAULT: Int32 = 21
    static let ENOMEM: Int32 = 48
    static let EISCONN: Int32 = 30
    static let EMSGSIZE: Int32 = 35
    static let ENOBUFS: Int32 = 42
    static let EPIPE: Int32 = 64

    /// Maps a Darwin errno from a socket call onto its WASI number.
    static func fromPOSIX(_ code: Int32) -> Int32 {
        switch code {
        case Darwin.EACCES, Darwin.EPERM:            return EACCES
        case Darwin.EADDRINUSE, Darwin.EADDRNOTAVAIL: return EADDRINUSE
        case Darwin.ECONNREFUSED:                    return ECONNREFUSED
        case Darwin.EHOSTUNREACH, Darwin.ENETUNREACH, Darwin.ENETDOWN, Darwin.EHOSTDOWN:
            return ENETUNREACH
        case Darwin.EMSGSIZE:                        return EMSGSIZE
        case Darwin.ENOBUFS:                         return ENOBUFS
        case Darwin.EAGAIN:                          return EAGAIN
        case Darwin.EISCONN:                         return EISCONN
        case Darwin.EPIPE:                           return EPIPE
        case Darwin.EINVAL, Darwin.EAFNOSUPPORT:     return EINVAL
        case Darwin.EMFILE, Darwin.ENFILE:           return ENOMEM
        default:                                     return EIO
        }
    }
}

struct OFlags: OptionSet {
    let rawValue: Int32
    static let creat = OFlags(rawValue: 1 << 0)
    static let directory = OFlags(rawValue: 1 << 1)
    static let excl = OFlags(rawValue: 1 << 2)
    static let trunc = OFlags(rawValue: 1 << 3)
}

struct FdFlags: OptionSet {
    let rawValue: Int32
    static let append = FdFlags(rawValue: 1 << 0)
    static let dsync = FdFlags(rawValue: 1 << 1)
    static let nonblock = FdFlags(rawValue: 1 << 2)
    static let rsync = FdFlags(rawValue: 1 << 3)
    static let sync = FdFlags(rawValue: 1 << 4)
}
