import Foundation

/// One in-flight `.wasm` invocation. Held by `WasmRuntime` and exposed to
/// `LocalShellSession` so it can route stdin / interrupts to the right
/// running process.
@MainActor
final class WasmProcess {
    let id: UUID
    let wasmURL: URL
    let argv: [String]
    let env: [String: String]
    let cwd: URL
    let sandboxRoot: URL

    /// Forwarded to the terminal as bytes. We use a `Data` sink rather than
    /// String so binary stdout (e.g. image piping) survives intact.
    var onStdout: ((Data) -> Void)?
    var onStderr: ((Data) -> Void)?

    /// Fired exactly once when the process exits or fails. Exit code follows
    /// POSIX conventions (0 = success, >0 = error).
    var onExit: ((Int32) -> Void)?

    /// Set by the runtime when the user cancels or the WKWebView is torn
    /// down. The Worker is told to abort; any pending FS/socket calls return
    /// `EINTR`.
    private(set) var cancelled: Bool = false

    /// Whether the WASM process has opted into raw terminal input. In raw
    /// mode, Ctrl-C is delivered as a `0x03` byte on stdin and the app
    /// decides what to do with it (e.g. vim, less). In cooked mode (the
    /// default), Ctrl-C cancels the process. The WASM side flips this via
    /// the `rootshell_terminal_set_raw(...)` import.
    var isRawMode: Bool = false

    /// Per-process state held by brokers. Indexed by virtual fd. Kept here
    /// rather than on the brokers themselves so that closing the process
    /// reliably reaps everything in one place.
    var fsHandles: [Int32: FsHandle] = [:]
    var socketHandles: [Int32: SocketHandle] = [:]

    /// Next free virtual fd for non-std files. WASI requires 0/1/2 to be
    /// stdin/stdout/stderr, the demo expects /home and /cwd preopens at 3/4,
    /// so we start regular files at 5 and sockets at 100.
    var nextFileFd: Int32 = 5
    var nextSocketFd: Int32 = 100

    init(id: UUID = UUID(),
         wasmURL: URL,
         argv: [String],
         env: [String: String],
         cwd: URL,
         sandboxRoot: URL) {
        self.id = id
        self.wasmURL = wasmURL
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.sandboxRoot = sandboxRoot
    }

    func markCancelled() {
        cancelled = true
    }

    /// Holds a `FileHandle` + the resolved URL + the open flags. The handle
    /// is closed by the broker on `fd_close` or process teardown.
    final class FsHandle {
        let url: URL
        let handle: FileHandle?
        let isDirectory: Bool
        let isPreopen: Bool
        let preopenName: String?
        /// Snapshot taken at cookie 0 so fd_readdir pages stay stable while
        /// the program deletes entries mid-listing.
        var dirEntries: [(name: String, isDir: Bool)]?

        init(url: URL,
             handle: FileHandle?,
             isDirectory: Bool,
             isPreopen: Bool = false,
             preopenName: String? = nil) {
            self.url = url
            self.handle = handle
            self.isDirectory = isDirectory
            self.isPreopen = isPreopen
            self.preopenName = preopenName
        }
    }

    /// Holds the native socket primitive plus a coalesced read buffer that
    /// the broker drains synchronously when WASM calls recv.
    final class SocketHandle {
        enum Kind {
            case tcpClient
            case udp
            case tcpListener
        }
        /// Mutable so a socket can be upgraded in place from `.tcpClient` to
        /// `.tcpListener` by `listen(2)` — swapping the handle in the fd
        /// table would orphan any closure (e.g. `newConnectionHandler`) that
        /// already captured the original instance.
        var kind: Kind
        /// Type-erased to keep this header dependency-free. The broker casts
        /// back to `NWConnection` / `NWListener` / `WasmUDPSocket`.
        var primitive: AnyObject?
        var pendingReads: Data = Data()
        /// UDP only: whole datagrams with their real sender, oldest first.
        var datagrams: [(data: Data, host: String, port: UInt16)] = []
        /// UDP only: a receive error (WASI errno) held for the next recv.
        var pendingError: Int32 = 0
        /// `SO_RCVTIMEO` equivalent; nil waits forever.
        var recvTimeout: Duration?
        var pendingAccepts: [(AnyObject, String, UInt16)] = []
        var lastError: Int32 = 0
        var localPort: UInt16 = 0
        var peerHost: String = ""
        var peerPort: UInt16 = 0
        var isClosed: Bool = false
        /// Set when the peer half-closes (HTTP/1.0 servers do this after
        /// the response). Subsequent recvs drain `pendingReads` first then
        /// return 0 — standard BSD `recv` EOF semantics.
        var eofReceived: Bool = false

        init(kind: Kind) {
            self.kind = kind
        }
    }
}
