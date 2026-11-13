/* eslint-disable */
/*
 * wasm-worker.js — runs WASM in a Web Worker. Every WASI / rootshell_socket
 * import is wired to a postMessage round-trip that blocks the Worker on
 * Atomics.wait so the call presents as synchronous to the WASM module.
 *
 * Layout of the reply SAB (Int32 view):
 *   view[0] = ready flag (Atomics.wait target)
 *   view[1] = JSON byte length
 *   bytes[8..8+len] = UTF-8 JSON reply payload
 */

let processID = null;
let sab = null;
let view = null;
let memory = null;
let exitCode = 0;
let cancelled = false;
let argv = [];
let env = {};
let cwdPath = "/";
let rootPath = "/";

let nextCallID = 1;

// Dedicated SAB for sleep waits. Always zero — Atomics.wait will block until
// the timeout expires since nobody ever writes to it. Keeps poll_oneoff
// (and therefore std::thread::sleep) cleanly isolated from the reply SAB.
const sleepSab = new SharedArrayBuffer(4);
const sleepView = new Int32Array(sleepSab);

self.onmessage = (ev) => {
    const msg = ev.data;
    if (msg.kind === "cancel") {
        cancelled = true;
        return;
    }
    if (msg.kind !== "start") return;

    processID = msg.processID;
    sab = msg.sab;
    view = new Int32Array(sab);
    argv = msg.argv;
    env = msg.env;
    cwdPath = msg.cwd;
    rootPath = msg.sandboxRoot;

    try {
        const bytes = b64ToBytes(msg.wasm);
        const mod = new WebAssembly.Module(bytes);
        const imports = buildImports();
        // Auto-stub any `env` imports we don't explicitly provide. Without this
        // a single missing libc shim aborts module instantiation before we get
        // any visibility into what's wrong. Stubs return 0 and log their first
        // call so unported syscalls surface as a stderr line at runtime rather
        // than a cryptic LinkError at startup.
        stubMissingEnvImports(mod, imports);
        const inst = new WebAssembly.Instance(mod, imports);
        memory = inst.exports.memory;
        if (typeof inst.exports._start === "function") {
            try {
                inst.exports._start();
                self.postMessage({ kind: "exit", code: exitCode });
            } catch (e) {
                if (e && e.wasiExit !== undefined) {
                    self.postMessage({ kind: "exit", code: e.wasiExit });
                } else {
                    self.postMessage({ kind: "error", message: "wasm trap: " + (e && e.message || e) });
                }
            }
        } else if (typeof inst.exports.main === "function") {
            const ret = inst.exports.main(0, 0) | 0;
            self.postMessage({ kind: "exit", code: ret });
        } else {
            self.postMessage({ kind: "error", message: "no _start or main export in wasm module" });
        }
    } catch (e) {
        self.postMessage({ kind: "error", message: String(e && e.message || e) });
    }
};

/* ---------- imports / WASI ---------- */

function buildImports() {
    const wasi = wasiPreview1Imports();
    const sock = rootshellSocketImports();
    const term = rootshellTerminalImports();
    const posix = posixStubImports();
    return {
        wasi_snapshot_preview1: wasi,
        wasi_unstable: wasi,
        rootshell_socket: sock,
        rootshell_terminal: term,
        // `env` fallback for modules that import under the default namespace
        // (e.g. minimal C ports without explicit `__import_module__`).
        env: { ...sock, ...term, ...posix },
    };
}

function stubMissingEnvImports(mod, imports) {
    const env = imports.env || (imports.env = {});
    const warned = new Set();
    for (const imp of WebAssembly.Module.imports(mod)) {
        if (imp.module !== "env" || imp.kind !== "function") continue;
        if (env[imp.name] !== undefined) continue;
        const name = imp.name;
        env[name] = (...args) => {
            if (!warned.has(name)) {
                warned.add(name);
                const note = `[wasm] unhandled env.${name}(${args.length} args) — returning 0\n`;
                self.postMessage({ kind: "stderr", data: bytesToB64(new TextEncoder().encode(note)) });
            }
            return 0;
        };
    }
}

/* ---------- POSIX stubs for modules built against full libc ----------
 *
 * Some WASM ports (notably neovim, which is compiled with a POSIX shim
 * layer rather than pure wasi-libc) declare imports under `env` for libc
 * functions that have no WASI Preview 1 equivalent. Provide best-effort
 * stubs so they link. Semantics chosen to be safe inside a single-threaded
 * sandbox where there's only one process: locks always succeed, signal/
 * process ops are no-ops, identity calls return plausible constants.
 *
 * If you see a runtime error like "import function env:<name>", add a stub
 * here. Returning 0 is "success" for most POSIX ints; -1 + errno would be
 * "fail" but most callers handle success more gracefully.
 */
function posixStubImports() {
    return {
        // File locking — meaningless in a single-process sandbox.
        // flock(int fd, int operation) -> 0 on success.
        flock(_fd, _operation) { return 0; },
        lockf(_fd, _cmd, _len) { return 0; },
        fcntl(_fd, _cmd, _arg) { return 0; },

        // Signal / process — no other processes or signal handlers to talk to.
        kill(_pid, _sig) { return 0; },
        killpg(_pgrp, _sig) { return 0; },
        getpid() { return 1; },
        getppid() { return 0; },
        getpgrp() { return 1; },
        getpgid(_pid) { return 1; },
        setpgid(_pid, _pgid) { return 0; },
        setsid() { return 1; },
        getsid(_pid) { return 1; },
        tcgetpgrp(_fd) { return 1; },
        tcsetpgrp(_fd, _pgrp) { return 0; },

        // User / group identity. Static "uid=501, gid=20" mirrors a typical
        // macOS first user; the sandbox doesn't enforce any of this.
        getuid() { return 501; },
        geteuid() { return 501; },
        getgid() { return 20; },
        getegid() { return 20; },

        // umask is a per-process mode mask. Stash the last value so callers
        // that round-trip umask() see consistent results.
        umask(_mask) { return 0o022; },
    };
}

function checkCancelled() { return cancelled ? 27 /* EINTR */ : 0; }

/* Block until Swift writes the next reply into `sab`. Returns the parsed
 * payload. The callID we get back must match `expectedCallID`. */
function awaitReply(expectedCallID) {
    while (true) {
        Atomics.wait(view, 0, 0);
        const len = Atomics.load(view, 1);
        const bytes = new Uint8Array(sab, 8, len);
        const json = new TextDecoder().decode(bytes);
        Atomics.store(view, 0, 0);
        Atomics.store(view, 1, 0);
        let payload;
        try { payload = JSON.parse(json); } catch (_) { return { errno: 28 }; }
        if (!expectedCallID || payload.callID === expectedCallID) return payload;
        // Out-of-order reply — keep waiting. Shouldn't happen with our
        // strict single-in-flight protocol, but be defensive.
    }
}

function callFs(op, params) {
    if (cancelled) return { errno: 27 };
    const callID = "fs-" + (nextCallID++);
    self.postMessage({
        kind: "fs",
        callID,
        payload: { op, ...params },
    });
    return awaitReply(callID);
}

function callSocket(op, params) {
    if (cancelled) return { errno: 27 };
    const callID = "sk-" + (nextCallID++);
    self.postMessage({
        kind: "socket",
        callID,
        payload: { op, ...params },
    });
    return awaitReply(callID);
}

/* ---------- Terminal (raw / cooked input mode) ---------- */

function rootshellTerminalImports() {
    return {
        // Flip the host's stdin handling. Returns 0 always — the host
        // tracks the flag asynchronously, but ordering is preserved
        // because Atomics.wait round-trips the control message via the
        // standard reply channel.
        rootshell_terminal_set_raw(enabled) {
            if (cancelled) return 27;
            const callID = "tm-" + (nextCallID++);
            self.postMessage({
                kind: "terminal",
                callID,
                payload: { op: "set_raw", enabled: enabled | 0 },
            });
            return awaitReply(callID).errno || 0;
        },
        // Returns 1 for fds 0/1/2 (always TTYs from the WASM's POV) and 0
        // otherwise. Apps use this to detect interactive vs piped use.
        rootshell_terminal_is_tty(fd) {
            return (fd === 0 || fd === 1 || fd === 2) ? 1 : 0;
        },
    };
}

/* ---------- WASI Preview 1 ---------- */

function wasiPreview1Imports() {
    return {
        // ---- proc ----
        proc_exit(code) {
            exitCode = code | 0;
            const e = new Error("wasi exit");
            e.wasiExit = exitCode;
            throw e;
        },
        proc_raise(_sig) { return 0; },

        // ---- args / env ----
        args_sizes_get(numPtr, sizePtr) {
            const enc = new TextEncoder();
            let bufSize = 0;
            for (const a of argv) bufSize += enc.encode(a).length + 1;
            const dv = new DataView(memory.buffer);
            dv.setUint32(numPtr, argv.length, true);
            dv.setUint32(sizePtr, bufSize, true);
            return 0;
        },
        args_get(argvPtr, bufPtr) {
            const enc = new TextEncoder();
            const dv = new DataView(memory.buffer);
            const buf = new Uint8Array(memory.buffer);
            let off = bufPtr;
            for (let i = 0; i < argv.length; i++) {
                dv.setUint32(argvPtr + i * 4, off, true);
                const b = enc.encode(argv[i]);
                buf.set(b, off);
                buf[off + b.length] = 0;
                off += b.length + 1;
            }
            return 0;
        },
        environ_sizes_get(numPtr, sizePtr) {
            const enc = new TextEncoder();
            const entries = Object.entries(env);
            let bufSize = 0;
            for (const [k, v] of entries) bufSize += enc.encode(`${k}=${v}`).length + 1;
            const dv = new DataView(memory.buffer);
            dv.setUint32(numPtr, entries.length, true);
            dv.setUint32(sizePtr, bufSize, true);
            return 0;
        },
        environ_get(envPtr, bufPtr) {
            const enc = new TextEncoder();
            const dv = new DataView(memory.buffer);
            const buf = new Uint8Array(memory.buffer);
            let off = bufPtr;
            const entries = Object.entries(env);
            for (let i = 0; i < entries.length; i++) {
                dv.setUint32(envPtr + i * 4, off, true);
                const b = enc.encode(`${entries[i][0]}=${entries[i][1]}`);
                buf.set(b, off);
                buf[off + b.length] = 0;
                off += b.length + 1;
            }
            return 0;
        },

        // ---- clock ----
        clock_time_get(_id, _prec, ptr) {
            const ns = BigInt(Date.now()) * 1000000n;
            new DataView(memory.buffer).setBigUint64(ptr, ns, true);
            return 0;
        },
        clock_res_get(_id, ptr) {
            new DataView(memory.buffer).setBigUint64(ptr, 1000000n, true);
            return 0;
        },

        // ---- random ----
        random_get(ptr, len) {
            const out = new Uint8Array(memory.buffer, ptr, len);
            crypto.getRandomValues(out);
            return 0;
        },

        // ---- fd: stdio + files ----
        fd_write(fd, iovsPtr, iovsLen, writtenPtr) {
            const c = checkCancelled(); if (c) return c;
            const data = gatherIovs(iovsPtr, iovsLen);
            if (fd === 1 || fd === 2) {
                self.postMessage({
                    kind: fd === 1 ? "stdout" : "stderr",
                    data: bytesToB64(data),
                });
                new DataView(memory.buffer).setUint32(writtenPtr, data.length, true);
                return 0;
            }
            const r = callFs("fd_write", { fd, data: bytesToB64(data) });
            if (r.errno !== 0) return r.errno;
            new DataView(memory.buffer).setUint32(writtenPtr, r.written, true);
            return 0;
        },
        fd_read(fd, iovsPtr, iovsLen, readPtr) {
            const c = checkCancelled(); if (c) return c;
            const wantTotal = iovTotalLen(iovsPtr, iovsLen);
            let bytes;
            if (fd === 0) {
                const callID = "stdin-" + (nextCallID++);
                self.postMessage({ kind: "stdinRead", callID, maxLen: wantTotal });
                const reply = awaitReply(callID);
                if (reply.errno !== 0) return reply.errno;
                bytes = b64ToBytes(reply.data || "");
            } else {
                const r = callFs("fd_read", { fd, length: wantTotal });
                if (r.errno !== 0) return r.errno;
                bytes = b64ToBytes(r.data || "");
            }
            scatterIntoIovs(iovsPtr, iovsLen, bytes);
            new DataView(memory.buffer).setUint32(readPtr, bytes.length, true);
            return 0;
        },
        fd_close(fd) {
            if (fd <= 2) return 0;
            return callFs("fd_close", { fd }).errno || 0;
        },
        fd_seek(fd, offset, whence, newOffsetPtr) {
            const offNum = Number(offset);
            const r = callFs("fd_seek", { fd, offset: offNum, whence });
            if (r.errno !== 0) return r.errno;
            new DataView(memory.buffer).setBigUint64(newOffsetPtr, BigInt(r.offset), true);
            return 0;
        },
        fd_tell(fd, ptr) {
            const r = callFs("fd_seek", { fd, offset: 0, whence: 1 });
            if (r.errno !== 0) return r.errno;
            new DataView(memory.buffer).setBigUint64(ptr, BigInt(r.offset), true);
            return 0;
        },
        fd_filestat_get(fd, ptr) {
            const r = callFs("fd_filestat_get", { fd });
            if (r.errno !== 0) return r.errno;
            writeFilestat(ptr, r);
            return 0;
        },
        fd_fdstat_get(fd, ptr) {
            // type=4 regular, type=3 dir, rights=all bits set
            const dv = new DataView(memory.buffer);
            dv.setUint8(ptr, fd <= 2 ? 2 /* char dev */ : 4 /* regular */);
            dv.setUint16(ptr + 2, 0, true);   // flags
            dv.setBigUint64(ptr + 8, 0xFFFFFFFFFFFFFFFFn, true);
            dv.setBigUint64(ptr + 16, 0xFFFFFFFFFFFFFFFFn, true);
            return 0;
        },
        fd_fdstat_set_flags(_fd, _flags) { return 0; },

        // ---- fd: positioned I/O + sync + truncate ----
        //
        // Required for Go's wasip1 stdlib (os.File.ReadAt/WriteAt/Truncate),
        // and for rclone multipart uploads which read/write chunks at offsets
        // without disturbing the fd's seek position.
        //
        // Offsets travel as Number, not BigInt: WASI's filesize is u64 but
        // 53 bits of JS mantissa covers 8 PB which is far past anything that
        // can fit in the iOS Documents sandbox.
        fd_pread(fd, iovsPtr, iovsLen, offset, nreadPtr) {
            const c = checkCancelled(); if (c) return c;
            if (fd <= 2) return 8 /* EBADF — stdio is not seekable */;
            const wantTotal = iovTotalLen(iovsPtr, iovsLen);
            const r = callFs("fd_pread", {
                fd, offset: Number(offset), length: wantTotal,
            });
            if (r.errno !== 0) return r.errno;
            const bytes = b64ToBytes(r.data || "");
            scatterIntoIovs(iovsPtr, iovsLen, bytes);
            new DataView(memory.buffer).setUint32(nreadPtr, bytes.length, true);
            return 0;
        },
        fd_pwrite(fd, iovsPtr, iovsLen, offset, nwrittenPtr) {
            const c = checkCancelled(); if (c) return c;
            if (fd <= 2) return 8;
            const data = gatherIovs(iovsPtr, iovsLen);
            const r = callFs("fd_pwrite", {
                fd, offset: Number(offset), data: bytesToB64(data),
            });
            if (r.errno !== 0) return r.errno;
            new DataView(memory.buffer).setUint32(nwrittenPtr, r.written, true);
            return 0;
        },
        fd_filestat_set_size(fd, size) {
            if (fd <= 2) return 8;
            return callFs("fd_filestat_set_size", {
                fd, size: Number(size),
            }).errno || 0;
        },
        // fst_flags layout: bit 0=ATIM, 1=ATIM_NOW, 2=MTIM, 3=MTIM_NOW.
        // Broker checks MTIM / MTIM_NOW and ignores atime (FileManager has
        // no portable way to set it).
        fd_filestat_set_times(fd, atim, mtim, fstFlags) {
            if (fd <= 2) return 0;
            return callFs("fd_filestat_set_times", {
                fd,
                atim: Number(atim), mtim: Number(mtim),
                flags: fstFlags | 0,
            }).errno || 0;
        },
        fd_sync(fd) {
            if (fd <= 2) return 0;
            return callFs("fd_sync", { fd }).errno || 0;
        },
        fd_datasync(fd) {
            // Foundation has no fdatasync(2) distinction — alias to fd_sync.
            if (fd <= 2) return 0;
            return callFs("fd_sync", { fd }).errno || 0;
        },

        // ---- fd: harmless no-ops / non-applicable ----
        fd_advise(_fd, _offset, _len, _advice) { return 0; },
        fd_allocate(_fd, _offset, _len) { return 52 /* ENOSYS */; },
        fd_fdstat_set_rights(_fd, _base, _inh) { return 0; },
        fd_renumber(_from, _to) { return 52 /* single-handle model */; },

        fd_prestat_get(fd, ptr) {
            const r = callFs("fd_prestat_get", { fd });
            if (r.errno !== 0) return r.errno;
            const dv = new DataView(memory.buffer);
            dv.setUint8(ptr, r.type);
            dv.setUint32(ptr + 4, r.nameLen, true);
            return 0;
        },
        fd_prestat_dir_name(fd, ptr, _len) {
            const r = callFs("fd_prestat_dir_name", { fd });
            if (r.errno !== 0) return r.errno;
            const enc = new TextEncoder().encode(r.name);
            new Uint8Array(memory.buffer).set(enc, ptr);
            return 0;
        },
        fd_readdir(fd, bufPtr, bufLen, cookie, retPtr) {
            // WASI dirent: 8B d_next (the cookie), 8B d_ino, 4B namlen,
            // 1B type, 3B pad, name. A full buffer with the last entry cut
            // short tells wasi-libc to call again from that entry's cookie;
            // a short buffer means the end, so keep paging until full.
            const enc = new TextEncoder();
            const end = bufPtr + bufLen;
            let off = bufPtr;
            let index = Number(cookie);
            do {
                const r = callFs("fd_readdir", { fd, cookie: index, bufLen: end - off });
                if (r.errno !== 0) return r.errno;
                if (r.entries.length === 0) break;
                const buf = new Uint8Array(memory.buffer);
                for (let i = 0; i < r.entries.length && off < end; i++, index++) {
                    const name = enc.encode(r.entries[i].name);
                    const ent = new Uint8Array(24 + name.length);
                    const dv = new DataView(ent.buffer);
                    dv.setBigUint64(0, BigInt(index + 1), true);
                    dv.setBigUint64(8, BigInt(index + 1), true);
                    dv.setUint32(16, name.length, true);
                    dv.setUint8(20, r.entries[i].isDir ? 3 : 4);
                    ent.set(name, 24);
                    const n = Math.min(ent.length, end - off);
                    buf.set(ent.subarray(0, n), off);
                    off += n;
                }
            } while (off < end);
            new DataView(memory.buffer).setUint32(retPtr, off - bufPtr, true);
            return 0;
        },
        path_open(dirfd, _dirflags, pathPtr, pathLen,
                  oflags, _rightsBase, _rightsInh, fdflags, fdOutPtr) {
            const c = checkCancelled(); if (c) return c;
            const path = readString(pathPtr, pathLen);
            const r = callFs("path_open", {
                dirfd, path, oflags: oflags | 0, fdflags: fdflags | 0,
            });
            if (r.errno !== 0) return r.errno;
            new DataView(memory.buffer).setUint32(fdOutPtr, r.fd, true);
            return 0;
        },
        path_filestat_get(dirfd, _flags, pathPtr, pathLen, ptr) {
            const path = readString(pathPtr, pathLen);
            const r = callFs("path_filestat_get", { dirfd, path });
            if (r.errno !== 0) return r.errno;
            writeFilestat(ptr, r);
            return 0;
        },
        path_create_directory(dirfd, pathPtr, pathLen) {
            const path = readString(pathPtr, pathLen);
            return callFs("path_create_directory", { dirfd, path }).errno || 0;
        },
        path_remove_directory(dirfd, pathPtr, pathLen) {
            const path = readString(pathPtr, pathLen);
            return callFs("path_remove_directory", { dirfd, path }).errno || 0;
        },
        path_unlink_file(dirfd, pathPtr, pathLen) {
            const path = readString(pathPtr, pathLen);
            return callFs("path_unlink_file", { dirfd, path }).errno || 0;
        },
        path_rename(oldDirfd, oldPathPtr, oldPathLen, newDirfd, newPathPtr, newPathLen) {
            const oldPath = readString(oldPathPtr, oldPathLen);
            const newPath = readString(newPathPtr, newPathLen);
            return callFs("path_rename", { oldDirfd, oldPath, newDirfd, newPath }).errno || 0;
        },

        // mtime preservation — without this, rclone sync re-uploads every
        // file every run because timestamps don't survive the round-trip.
        path_filestat_set_times(dirfd, _lookupflags, pathPtr, pathLen, atim, mtim, fstFlags) {
            const path = readString(pathPtr, pathLen);
            return callFs("path_filestat_set_times", {
                dirfd, path,
                atim: Number(atim), mtim: Number(mtim),
                flags: fstFlags | 0,
            }).errno || 0;
        },
        // No symlinks in the iOS sandbox: tell callers "not a link" so the
        // walker code paths gracefully fall back to treating entries as
        // regular files. EINVAL is the POSIX errno for readlink-on-non-link.
        path_readlink(_dirfd, _pathPtr, _pathLen, _bufPtr, _bufLen, bufUsedPtr) {
            new DataView(memory.buffer).setUint32(bufUsedPtr, 0, true);
            return 28 /* EINVAL */;
        },
        path_symlink(_oldPathPtr, _oldPathLen, _newDirfd, _newPathPtr, _newPathLen) {
            return 52 /* ENOSYS */;
        },
        path_link(_oldDirfd, _oldFlags, _oldPathPtr, _oldPathLen, _newDirfd, _newPathPtr, _newPathLen) {
            return 52 /* ENOSYS */;
        },

        // Go's runtime emits WASI sock_* imports even when the program uses
        // a custom socket ABI (rootshell_socket_*), because the imports are
        // declared in the runtime regardless. Return ENOSYS so any direct
        // use bails cleanly; rclone routes everything via rootshell_socket_*.
        sock_accept(_fd, _flags, _fdOutPtr) { return 52; },
        sock_shutdown(_fd, _how) { return 52; },
        sock_recv(_fd, _riDataPtr, _riDataLen, _riFlags, _roDataLenPtr, _roFlagsPtr) { return 52; },
        sock_send(_fd, _siDataPtr, _siDataLen, _siFlags, _soDataLenPtr) { return 52; },

        // Minimal poll_oneoff: handles EVENTTYPE_CLOCK (so std::thread::sleep,
        // tokio::time, etc. work) by blocking the Worker on Atomics.wait
        // against a dedicated SAB. Other subscription types return ENOSYS.
        //
        // Subscription layout (48 bytes each):
        //   +0  userdata u64
        //   +8  type u8   (0=clock, 1=fd_read, 2=fd_write)
        //   +16 clockid u32                    (clock subs only)
        //   +24 timeout u64 nanoseconds        (clock subs only)
        //   +32 precision u64 nanoseconds      (clock subs only)
        //   +40 flags u16                      (clock subs only — bit 0: ABSTIME)
        //
        // Event_t layout (32 bytes): userdata, error u16, type u8, padding.
        poll_oneoff(inPtr, outPtr, nsubs, nevPtr) {
            const c = checkCancelled(); if (c) return c;
            const dv = new DataView(memory.buffer);

            let userdata = 0n;
            let timeoutNs = 0n;
            let flagsAbstime = false;
            let foundClock = false;

            for (let i = 0; i < nsubs; i++) {
                const base = inPtr + i * 48;
                const type = dv.getUint8(base + 8);
                if (type === 0) {
                    userdata = dv.getBigUint64(base + 0, true);
                    timeoutNs = dv.getBigUint64(base + 24, true);
                    const flags = dv.getUint16(base + 40, true);
                    flagsAbstime = (flags & 1) !== 0;
                    foundClock = true;
                    break;
                }
            }

            if (!foundClock) return 52; /* ENOSYS for non-clock subs */

            let timeoutMs;
            if (flagsAbstime) {
                const nowNs = BigInt(Date.now()) * 1000000n;
                const diff = timeoutNs > nowNs ? timeoutNs - nowNs : 0n;
                timeoutMs = Number(diff / 1000000n);
            } else {
                timeoutMs = Number(timeoutNs / 1000000n);
            }

            if (timeoutMs > 0) {
                // Spurious wakeups from Atomics.wait are theoretically possible;
                // re-check the deadline and re-wait until we've actually slept
                // the full duration. Also bail early on cancellation.
                const deadline = Date.now() + timeoutMs;
                let remaining = timeoutMs;
                while (remaining > 0) {
                    Atomics.wait(sleepView, 0, 0, Math.max(1, remaining));
                    if (cancelled) return 27 /* EINTR */;
                    remaining = deadline - Date.now();
                }
            }

            dv.setUint32(nevPtr, 1, true);
            dv.setBigUint64(outPtr + 0, userdata, true);
            dv.setUint16(outPtr + 8, 0, true);
            dv.setUint8(outPtr + 10, 0); /* type = CLOCK */
            return 0;
        },
        sched_yield() { return 0; },
    };
}

/* ---------- rootshell_socket_* shim ---------- */

function rootshellSocketImports() {
    return {
        rootshell_socket_socket(domain, type, fdOutPtr) {
            const r = callSocket("socket", { domain, type });
            if (r.errno !== 0) return r.errno;
            new DataView(memory.buffer).setInt32(fdOutPtr, r.fd, true);
            return 0;
        },
        rootshell_socket_bind(fd, addrPtr, addrLen) {
            const sa = parseSockaddr(addrPtr, addrLen);
            if (!sa) return 28;
            return callSocket("bind", { fd, host: sa.host, port: sa.port }).errno || 0;
        },
        rootshell_socket_listen(fd, backlog) {
            return callSocket("listen", { fd, backlog }).errno || 0;
        },
        rootshell_socket_accept(fd, fdOutPtr) {
            const r = callSocket("accept", { fd });
            if (r.errno !== 0) return r.errno;
            new DataView(memory.buffer).setInt32(fdOutPtr, r.fd, true);
            return 0;
        },
        rootshell_socket_connect(fd, addrPtr, addrLen) {
            const sa = parseSockaddr(addrPtr, addrLen);
            if (!sa) return 28;
            return callSocket("connect", { fd, host: sa.host, port: sa.port }).errno || 0;
        },
        rootshell_socket_send(fd, bufPtr, bufLen, sentOutPtr) {
            const data = new Uint8Array(memory.buffer, bufPtr, bufLen);
            const r = callSocket("send", { fd, data: bytesToB64(data) });
            if (r.errno !== 0) return r.errno;
            new DataView(memory.buffer).setUint32(sentOutPtr, r.sent, true);
            return 0;
        },
        rootshell_socket_recv(fd, bufPtr, bufLen, recvOutPtr) {
            const r = callSocket("recv", { fd, maxLen: bufLen });
            if (r.errno !== 0) return r.errno;
            const bytes = b64ToBytes(r.data || "");
            new Uint8Array(memory.buffer).set(bytes, bufPtr);
            new DataView(memory.buffer).setUint32(recvOutPtr, bytes.length, true);
            return 0;
        },
        rootshell_socket_sendto(fd, bufPtr, bufLen, addrPtr, addrLen, sentOutPtr) {
            const data = new Uint8Array(memory.buffer, bufPtr, bufLen);
            const sa = parseSockaddr(addrPtr, addrLen);
            if (!sa) return 28;
            const r = callSocket("sendto", { fd, data: bytesToB64(data), host: sa.host, port: sa.port });
            if (r.errno !== 0) return r.errno;
            new DataView(memory.buffer).setUint32(sentOutPtr, r.sent, true);
            return 0;
        },
        rootshell_socket_recvfrom(fd, bufPtr, bufLen, addrPtr, addrLenIO, recvOutPtr) {
            const r = callSocket("recvfrom", { fd, maxLen: bufLen });
            if (r.errno !== 0) return r.errno;
            const bytes = b64ToBytes(r.data || "");
            new Uint8Array(memory.buffer).set(bytes, bufPtr);
            new DataView(memory.buffer).setUint32(recvOutPtr, bytes.length, true);
            // Materialize the datagram's sender the BSD way. addrLenIO is
            // in/out: read capacity, write the actual sockaddr length back.
            // If the caller passed null buffers or the broker couldn't tell
            // us who sent the datagram, leave addrLenIO at 0 so apps see
            // "unknown source" cleanly instead of stale stack data.
            if (addrPtr && addrLenIO) {
                const dv = new DataView(memory.buffer);
                const cap = dv.getInt32(addrLenIO, true);
                const written = r.peerHost
                    ? writeSockaddr(addrPtr, cap, r.peerHost, (r.peerPort | 0) & 0xffff)
                    : 0;
                dv.setInt32(addrLenIO, written, true);
            }
            return 0;
        },
        rootshell_socket_shutdown(fd, how) {
            return callSocket("shutdown", { fd, how }).errno || 0;
        },
        // SO_RCVTIMEO: recv/recvfrom give up with EAGAIN after timeoutMs; 0 waits forever.
        rootshell_socket_set_recv_timeout(fd, timeoutMs) {
            return callSocket("set_recv_timeout", { fd, timeoutMs: timeoutMs >>> 0 }).errno || 0;
        },
        // Browses for a Bonjour service type such as "_ssh._tcp" for up to
        // timeoutMs. Writes one "name\thost\tport\taddr,addr\n" line per
        // instance, whole lines only; ENOBUFS when not even one fits.
        rootshell_socket_bonjour_lookup(typePtr, typeLen, timeoutMs, outBufPtr, outMax, outLenPtr) {
            const type = readString(typePtr, typeLen);
            const r = callSocket("bonjour_lookup", { type, timeoutMs: timeoutMs >>> 0 });
            if (r.errno !== 0) return r.errno;
            const enc = new TextEncoder();
            const buf = new Uint8Array(memory.buffer);
            let written = 0;
            for (const line of (r.text || "").split("\n")) {
                if (!line) continue;
                const bytes = enc.encode(line + "\n");
                if (written + bytes.length > outMax) break;
                buf.set(bytes, outBufPtr + written);
                written += bytes.length;
            }
            new DataView(memory.buffer).setUint32(outLenPtr, written, true);
            return written === 0 ? 42 /* ENOBUFS */ : 0;
        },
        rootshell_socket_close(fd) {
            return callSocket("close", { fd }).errno || 0;
        },

        // -------- Porting-friendly DNS + hostname variants --------
        //
        // Apps written against BSD sockets typically need a getaddrinfo
        // call before connect. These imports let porters skip the
        // sockaddr round-trip entirely:
        //   * connect_host / sendto_host take a hostname string and port
        //     directly; Network.framework handles DNS internally.
        //   * resolve_v4 / resolve_v6 do explicit name -> address lookup
        //     for code paths that still want a sockaddr.

        rootshell_socket_connect_host(fd, hostPtr, hostLen, port) {
            const host = readString(hostPtr, hostLen);
            return callSocket("connect", { fd, host, port }).errno || 0;
        },
        // TLS variant: NWConnection is built with NWParameters(tls:tcp:) on
        // the Swift side, so the handshake + cert validation happen host-side
        // and the WASM guest just does plaintext send/recv on the same fd.
        rootshell_socket_tls_connect_host(fd, hostPtr, hostLen, port) {
            const host = readString(hostPtr, hostLen);
            return callSocket("tls_connect", { fd, host, port }).errno || 0;
        },
        rootshell_socket_bind_host(fd, hostPtr, hostLen, port) {
            const host = readString(hostPtr, hostLen);
            return callSocket("bind", { fd, host, port }).errno || 0;
        },
        rootshell_socket_sendto_host(fd, bufPtr, bufLen, hostPtr, hostLen, port, sentOutPtr) {
            const data = new Uint8Array(memory.buffer, bufPtr, bufLen);
            const host = readString(hostPtr, hostLen);
            const r = callSocket("sendto", { fd, data: bytesToB64(data), host, port });
            if (r.errno !== 0) return r.errno;
            new DataView(memory.buffer).setUint32(sentOutPtr, r.sent, true);
            return 0;
        },
        rootshell_socket_resolve_v4(hostPtr, hostLen, outBufPtr, outMax, countOutPtr) {
            const host = readString(hostPtr, hostLen);
            const r = callSocket("resolve", { host, family: "v4", maxResults: outMax });
            if (r.errno !== 0) return r.errno;
            const buf = new Uint8Array(memory.buffer);
            let written = 0;
            for (const b64 of (r.addrs || [])) {
                const bytes = b64ToBytes(b64);
                if (written + bytes.length > outMax * 4) break;
                buf.set(bytes, outBufPtr + written);
                written += bytes.length;
            }
            new DataView(memory.buffer).setUint32(countOutPtr, written / 4, true);
            return 0;
        },
        rootshell_socket_resolve_v6(hostPtr, hostLen, outBufPtr, outMax, countOutPtr) {
            const host = readString(hostPtr, hostLen);
            const r = callSocket("resolve", { host, family: "v6", maxResults: outMax });
            if (r.errno !== 0) return r.errno;
            const buf = new Uint8Array(memory.buffer);
            let written = 0;
            for (const b64 of (r.addrs || [])) {
                const bytes = b64ToBytes(b64);
                if (written + bytes.length > outMax * 16) break;
                buf.set(bytes, outBufPtr + written);
                written += bytes.length;
            }
            new DataView(memory.buffer).setUint32(countOutPtr, written / 16, true);
            return 0;
        },
    };
}

/* ---------- helpers ---------- */

function readString(ptr, len) {
    const bytes = new Uint8Array(memory.buffer, ptr, len);
    return new TextDecoder().decode(bytes);
}

function gatherIovs(iovsPtr, iovsLen) {
    const dv = new DataView(memory.buffer);
    let total = 0;
    const ranges = [];
    for (let i = 0; i < iovsLen; i++) {
        const p = dv.getUint32(iovsPtr + i * 8, true);
        const l = dv.getUint32(iovsPtr + i * 8 + 4, true);
        ranges.push([p, l]);
        total += l;
    }
    const out = new Uint8Array(total);
    let off = 0;
    for (const [p, l] of ranges) {
        out.set(new Uint8Array(memory.buffer, p, l), off);
        off += l;
    }
    return out;
}

function iovTotalLen(iovsPtr, iovsLen) {
    const dv = new DataView(memory.buffer);
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
        total += dv.getUint32(iovsPtr + i * 8 + 4, true);
    }
    return total;
}

function scatterIntoIovs(iovsPtr, iovsLen, bytes) {
    const dv = new DataView(memory.buffer);
    const buf = new Uint8Array(memory.buffer);
    let off = 0;
    for (let i = 0; i < iovsLen && off < bytes.length; i++) {
        const p = dv.getUint32(iovsPtr + i * 8, true);
        const l = dv.getUint32(iovsPtr + i * 8 + 4, true);
        const take = Math.min(l, bytes.length - off);
        buf.set(bytes.subarray(off, off + take), p);
        off += take;
    }
}

function writeFilestat(ptr, r) {
    const dv = new DataView(memory.buffer);
    dv.setBigUint64(ptr + 0, 1n, true);                  // dev
    dv.setBigUint64(ptr + 8, 1n, true);                  // ino
    dv.setUint8(ptr + 16, r.type | 0);                    // filetype
    dv.setBigUint64(ptr + 24, 1n, true);                  // nlink
    dv.setBigUint64(ptr + 32, BigInt(r.size || 0), true); // size
    dv.setBigUint64(ptr + 40, BigInt(r.mtime || 0), true);// atim
    dv.setBigUint64(ptr + 48, BigInt(r.mtime || 0), true);// mtim
    dv.setBigUint64(ptr + 56, BigInt(r.mtime || 0), true);// ctim
}

/* Sockaddr layout (BSD-compatible, little-endian):
 *   AF_INET   (sa_family=2):  [0]=family byte LE, [2..4]=port BE, [4..8]=ipv4 bytes
 *   AF_INET6  (sa_family=30): [0]=family, [2..4]=port BE, [4..8]=flowinfo, [8..24]=ipv6 bytes
 */
function parseSockaddr(ptr, len) {
    if (len < 8) return null;
    const dv = new DataView(memory.buffer);
    const family = dv.getUint8(ptr);
    const port = dv.getUint16(ptr + 2, false);
    if (family === 2) {
        const o0 = dv.getUint8(ptr + 4);
        const o1 = dv.getUint8(ptr + 5);
        const o2 = dv.getUint8(ptr + 6);
        const o3 = dv.getUint8(ptr + 7);
        return { host: `${o0}.${o1}.${o2}.${o3}`, port };
    }
    if (family === 30) {
        if (len < 24) return null;
        const parts = [];
        for (let i = 0; i < 8; i++) {
            parts.push(dv.getUint16(ptr + 8 + i * 2, false).toString(16));
        }
        return { host: parts.join(":"), port };
    }
    return null;
}

/* Writes a BSD-compatible sockaddr to `ptr`. Returns the number of bytes
 * written, or 0 if the caller's capacity is too small or `host` can't be
 * parsed as a literal IP. Matches `parseSockaddr` above byte-for-byte so
 * round-tripping through bind/connect/recvfrom stays consistent.
 */
function writeSockaddr(ptr, cap, host, port) {
    const dv = new DataView(memory.buffer);
    const u8 = new Uint8Array(memory.buffer);
    if (host.includes(":")) {
        // IPv6 — 24 bytes: family(1)+rsv(1)+port(2BE)+flowinfo(4)+addr(16).
        if (cap < 24) return 0;
        const parts = parseIPv6Literal(host);
        if (!parts) return 0;
        dv.setUint8(ptr, 30);
        dv.setUint8(ptr + 1, 0);
        dv.setUint16(ptr + 2, port, false);
        dv.setUint32(ptr + 4, 0, false);
        for (let i = 0; i < 8; i++) {
            dv.setUint16(ptr + 8 + i * 2, parts[i], false);
        }
        return 24;
    }
    // IPv4 — 16 bytes: family(1)+rsv(1)+port(2BE)+addr(4)+pad(8).
    if (cap < 16) return 0;
    const octets = host.split(".").map(s => parseInt(s, 10));
    if (octets.length !== 4 || octets.some(o => isNaN(o) || o < 0 || o > 255)) return 0;
    dv.setUint8(ptr, 2);
    dv.setUint8(ptr + 1, 0);
    dv.setUint16(ptr + 2, port, false);
    for (let i = 0; i < 4; i++) dv.setUint8(ptr + 4 + i, octets[i]);
    for (let i = 8; i < 16; i++) u8[ptr + i] = 0;
    return 16;
}

/* Parses an IPv6 literal into an 8-element array of u16 words. Accepts
 * "::" zero compression, zone suffixes ("fe80::1%en0"), and a dotted IPv4
 * tail ("::ffff:192.0.2.1"), which a v6 socket reports for IPv4 senders.
 */
function parseIPv6Literal(s) {
    s = s.split("%")[0]; // strip zone suffix
    const lastColon = s.lastIndexOf(":");
    const v4 = s.slice(lastColon + 1);
    if (lastColon >= 0 && v4.includes(".")) {
        const o = v4.split(".").map(p => /^\d{1,3}$/.test(p) ? parseInt(p, 10) : NaN);
        if (o.length !== 4 || o.some(v => isNaN(v) || v > 255)) return null;
        const hi = ((o[0] << 8) | o[1]).toString(16);
        const lo = ((o[2] << 8) | o[3]).toString(16);
        s = s.slice(0, lastColon + 1) + hi + ":" + lo;
    }
    const halves = s.split("::");
    if (halves.length > 2) return null;
    const head = halves[0] && halves[0].length ? halves[0].split(":") : [];
    const tail = halves.length === 2 && halves[1].length ? halves[1].split(":") : [];
    if (halves.length === 1 && head.length !== 8) return null;
    const fill = 8 - head.length - tail.length;
    if (fill < 0) return null;
    const full = [...head, ...Array(fill).fill("0"), ...tail];
    if (full.length !== 8) return null;
    const out = new Array(8);
    for (let i = 0; i < 8; i++) {
        const v = parseInt(full[i], 16);
        if (isNaN(v) || v < 0 || v > 0xffff) return null;
        out[i] = v;
    }
    return out;
}

function b64ToBytes(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
}
function bytesToB64(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return btoa(s);
}
