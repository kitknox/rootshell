import Foundation
import WebKit
import OSLog

/// Hosts a hidden WKWebView whose page bootstraps a Web Worker that runs WASM
/// against a from-scratch WASI Preview 1 implementation plus our custom
/// `rootshell_socket_*` ABI. One runtime per shell session — at any moment
/// there is at most one active `WasmProcess`, which mirrors the single-active-
/// command shape the rest of `LocalShellSession` already uses (ssh/ping/mtr/…).
///
/// The cross-origin-isolation needed for `SharedArrayBuffer` + `Atomics.wait`
/// is achieved by serving the host page through a custom `WKURLSchemeHandler`
/// that returns `Cross-Origin-Opener-Policy: same-origin` and
/// `Cross-Origin-Embedder-Policy: require-corp`. `loadFileURL` is not enough
/// because file:// URLs don't get isolation headers.
@MainActor
final class WasmRuntime: NSObject {
    nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "WasmRuntime")

    private var webView: WKWebView?
    private var localServer: WasmLocalServer?
    private(set) var current: WasmProcess?

    /// Most recent error from JS-side bootstrap, surfaced when `run` fails.
    private var lastBootstrapError: String?

    private let fsBroker = WasmFilesystemBroker()
    private let socketBroker = WasmSocketBroker()

    /// Dedicated serial queue for the CPU-bound parts of message marshaling
    /// (base64 + JSONSerialization). Keeping this off the main actor matters
    /// because a tight WASM syscall loop fires one reply per iteration —
    /// even small per-reply work adds up to perceptible UI hitching.
    /// `evaluateJavaScript` is the only step that genuinely needs the main
    /// thread (WebKit requirement), so we hop back just for that.
    nonisolated let marshalQueue = DispatchQueue(
        label: "com.rootshell.wasm.marshal",
        qos: .userInitiated
    )

    /// Whether the host page has signalled `["ready"]`. Set by the control
    /// handler, awaited by `run` so we don't post `run` messages into a
    /// not-yet-loaded WKWebView.
    private var readyContinuation: CheckedContinuation<Bool, Never>?
    private var hostReady: Bool = false

    /// Used by control messages from JS to mark a process complete.
    func processExit(processID: UUID, code: Int32) {
        guard let proc = current, proc.id == processID else { return }
        current = nil
        socketBroker.closeAll(for: proc)
        proc.onExit?(code)
    }

    // MARK: - Public API

    /// Run a `.wasm` file end-to-end. Returns once the WASM process has
    /// exited (or has been cancelled). `onStdout` / `onStderr` are called on
    /// the main actor for each chunk produced by the WASM module.
    func run(wasmURL: URL,
             argv: [String],
             env: [String: String],
             cwd: URL,
             sandboxRoot: URL,
             onStdout: @escaping (Data) -> Void,
             onStderr: @escaping (Data) -> Void) async -> Int32 {
        if current != nil {
            onStderr(Data("wasm: another WASM process is already running\n".utf8))
            return 1
        }

        let proc = WasmProcess(
            wasmURL: wasmURL,
            argv: argv,
            env: env,
            cwd: cwd,
            sandboxRoot: sandboxRoot
        )
        proc.onStdout = onStdout
        proc.onStderr = onStderr
        current = proc

        let ready = await ensureWebViewReady()
        if !ready {
            current = nil
            let detail = lastBootstrapError ?? "WKWebView host did not signal ready within 5s"
            onStderr(Data("wasm: runtime bootstrap failed: \(detail)\n".utf8))
            return 1
        }

        // Read the WASM file off the main actor — for a multi-MB binary
        // this is the difference between a perceptible UI hitch and none.
        let bytes: Data
        do {
            bytes = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: wasmURL)
            }.value
        } catch {
            current = nil
            onStderr(Data("wasm: cannot read \(wasmURL.lastPathComponent): \(error.localizedDescription)\n".utf8))
            return 1
        }

        // Seed the single root preopen. fd 3 = sandbox root mounted as "/".
        //
        // Rationale for one preopen instead of two: when both "/" and "."
        // are exposed, wasi-libc's preopen matcher is order-/length-
        // sensitive and can pick "." (the cwd) for an absolute path like
        // "/test.sh", routing the lookup against the cwd URL instead of
        // the sandbox root. With only "/" available, both wasi-libc and
        // Go's wasip1 path resolution route everything through the root —
        // absolute paths match "/" directly, relative paths are first
        // joined with $PWD (which we set to a virtual sandbox path) and
        // then matched against "/". The path sandbox enforces the
        // boundary on every subsequent path_open.
        proc.fsHandles[3] = WasmProcess.FsHandle(
            url: sandboxRoot, handle: nil, isDirectory: true,
            isPreopen: true, preopenName: "/"
        )

        // Provision conventional directories so that ported apps which
        // assume `/tmp` exists "just work". `createDirectory` does
        // filesystem IO — push to a background queue so we don't block the
        // main actor for every `wasm` invocation.
        let tmpURL = sandboxRoot.appendingPathComponent("tmp", isDirectory: true)
        marshalQueue.async {
            try? FileManager.default.createDirectory(
                at: tmpURL, withIntermediateDirectories: true
            )
        }

        // Wait for exit. The Worker → JS host → Swift control handler will
        // call `processExit(...)` which fulfils this continuation.
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            proc.onExit = { code in
                cont.resume(returning: code)
            }
            postRunMessage(proc: proc, wasmBytes: bytes)
        }
    }

    /// Forward bytes (e.g. keystrokes) to the running WASM process's stdin.
    /// Base64 encoding runs off-main so a large paste doesn't hitch the UI.
    func write(stdin data: Data, processID: UUID) {
        guard let proc = current, proc.id == processID else { return }
        _ = proc
        let pid = processID.uuidString
        marshalQueue.async { [weak self] in
            guard let self else { return }
            let base64 = data.base64EncodedString()
            let js = "rootshellWasm.feedStdin(\(Self.jsStringLiteral(pid)), \(Self.jsStringLiteral(base64)));"
            Task { @MainActor in
                self.evalOnMain(js)
            }
        }
    }

    /// Mark the current process cancelled. WASM imports return EINTR on the
    /// next call; the Worker then unwinds and posts `exit`.
    func cancel(processID: UUID) {
        guard let proc = current, proc.id == processID else { return }
        proc.markCancelled()
        eval("rootshellWasm.cancel(\(jsString(processID.uuidString)));")
    }

    /// Inform the WASM process of the current terminal size by setting
    /// `COLUMNS` / `LINES` env vars (the only portable WASI affordance).
    /// Only meaningful at launch; we still expose this hook so a future
    /// `SIGWINCH`-style signal can be plumbed without changing callers.
    func resize(cols: UInt16, rows: UInt16, processID: UUID) {
        guard let proc = current, proc.id == processID else { return }
        _ = proc
        // No-op for now; left as an extension point.
    }

    // MARK: - WKWebView bootstrap

    /// Waits up to `timeout` seconds for the WKWebView's host page to load
    /// and signal `["ready"]`. Returns true on success, false on timeout.
    /// A timeout means the JS bootstrap silently failed — most likely the
    /// scheme handler couldn't find the bundled HTML/JS or
    /// `crossOriginIsolated` is false.
    private func ensureWebViewReady(timeout: TimeInterval = 5.0) async -> Bool {
        if hostReady { return true }
        if webView == nil {
            await buildWebView()
            if webView == nil {
                // buildWebView already recorded a bootstrap error.
                return false
            }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if hostReady {
                cont.resume(returning: true)
                return
            }
            readyContinuation = cont
            // Timeout safety net so the caller never hangs.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                if !self.hostReady, let pending = self.readyContinuation {
                    self.readyContinuation = nil
                    pending.resume(returning: false)
                }
            }
        }
    }

    private func buildWebView() async {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc

        // Each message handler corresponds to one logical subsystem. Splitting
        // them keeps the JS side's switch statements simple and gives us
        // per-channel logging.
        ucc.add(MessageProxy(runtime: self, channel: .stdio), name: "wasmStdio")
        ucc.add(MessageProxy(runtime: self, channel: .fs), name: "wasmFs")
        ucc.add(MessageProxy(runtime: self, channel: .socket), name: "wasmSocket")
        ucc.add(MessageProxy(runtime: self, channel: .control), name: "wasmControl")

        cfg.suppressesIncrementalRendering = true

        let view = WKWebView(frame: .zero, configuration: cfg)
        view.isHidden = true
        self.webView = view

        // We *must* serve the host page over `http(s)://` for the page to
        // be a secure context and have `crossOriginIsolated === true`
        // (which gates SharedArrayBuffer). Custom URL schemes never get a
        // secure context. So we run a tiny loopback HTTP server bound to
        // 127.0.0.1 only, with COOP/COEP/CORP headers attached.
        let server = WasmLocalServer()
        do {
            let port = try await server.start()
            self.localServer = server
            let url = URL(string: "http://127.0.0.1:\(port)/wasm-host.html")!
            view.load(URLRequest(url: url))
        } catch {
            lastBootstrapError = "loopback server failed: \(error.localizedDescription)"
            Self.logger.error("loopback bind failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - JS bridge

    private func postRunMessage(proc: WasmProcess, wasmBytes: Data) {
        // Snapshot the process metadata under the main actor, then push the
        // marshaling work (base64 + JSON + JS-string-escape — all CPU-bound
        // and proportional to the WASM binary size) onto the background
        // queue. `evaluateJavaScript` is the only step that requires the
        // main thread.
        let pid = proc.id.uuidString
        let argv = proc.argv
        let env = proc.env
        let cwd = proc.cwd.path
        let sandboxRoot = proc.sandboxRoot.path

        marshalQueue.async { [weak self] in
            guard let self else { return }
            let wasmB64 = wasmBytes.base64EncodedString()
            let payload: [String: Any] = [
                "processID": pid,
                "wasm": wasmB64,
                "argv": argv,
                "env": env,
                "cwd": cwd,
                "sandboxRoot": sandboxRoot,
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let jsonString = String(data: json, encoding: .utf8) else {
                Task { @MainActor in
                    proc.onStderr?(Data("wasm: failed to encode launch payload\n".utf8))
                    self.current = nil
                    proc.onExit?(1)
                }
                return
            }
            let js = "rootshellWasm.run(JSON.parse(\(Self.jsStringLiteral(jsonString))));"
            Task { @MainActor in
                self.evalOnMain(js)
            }
        }
    }

    private func evalOnMain(_ js: String) {
        webView?.evaluateJavaScript(js) { _, err in
            if let err = err {
                Self.logger.error("evaluateJavaScript failed: \(String(describing: err))")
            }
        }
    }

    /// Convenience wrapper. Most call sites build the JS string off-main
    /// and only need this for the actual eval.
    private func eval(_ js: String) {
        evalOnMain(js)
    }

    /// Encodes a string as a JS string literal — safe for arbitrary content
    /// including newlines, quotes, and non-ASCII. `nonisolated` so the
    /// marshal queue can call it without hopping back to main.
    nonisolated static func jsStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }

    private func jsString(_ s: String) -> String { Self.jsStringLiteral(s) }

    // MARK: - Message routing

    fileprivate enum Channel {
        case stdio, fs, socket, control
    }

    fileprivate func handleMessage(_ body: Any, channel: Channel) {
        guard let dict = body as? [String: Any] else { return }

        switch channel {
        case .control:
            handleControl(dict)
        case .stdio:
            handleStdio(dict)
        case .fs:
            fsBroker.handle(dict, process: current, runtime: self)
        case .socket:
            socketBroker.handle(dict, process: current, runtime: self)
        }
    }

    private func handleControl(_ dict: [String: Any]) {
        guard let kind = dict["kind"] as? String else { return }
        switch kind {
        case "ready":
            hostReady = true
            readyContinuation?.resume(returning: true)
            readyContinuation = nil
        case "exit":
            let pidStr = dict["processID"] as? String ?? ""
            let code = (dict["code"] as? NSNumber)?.int32Value ?? 0
            if let uuid = UUID(uuidString: pidStr) {
                processExit(processID: uuid, code: code)
            }
        case "log":
            if let msg = dict["message"] as? String {
                Self.logger.debug("wasm js: \(msg, privacy: .public)")
            }

        case "terminal":
            // Set/clear raw mode on the current process and ack via the
            // standard reply channel so the Worker un-parks.
            guard let callID = dict["callID"] as? String else { return }
            if let proc = current,
               let pidStr = dict["processID"] as? String,
               UUID(uuidString: pidStr) == proc.id,
               let op = dict["op"] as? String, op == "set_raw" {
                let enabled = (dict["enabled"] as? NSNumber)?.intValue ?? 0
                proc.isRawMode = enabled != 0
                Self.logger.info("wasm raw mode = \(enabled != 0 ? "on" : "off", privacy: .public)")
                replyToJS(callID: callID, payload: ["errno": 0])
            } else {
                replyToJS(callID: callID, payload: ["errno": 28]) // EINVAL
            }
        case "error":
            let msg = dict["message"] as? String ?? "unknown error"
            Self.logger.error("wasm js error: \(msg, privacy: .public)")
            if let proc = current {
                proc.onStderr?(Data("wasm: \(msg)\n".utf8))
                current = nil
                socketBroker.closeAll(for: proc)
                proc.onExit?(1)
            } else {
                lastBootstrapError = msg
            }
        default:
            break
        }
    }

    private func handleStdio(_ dict: [String: Any]) {
        guard let proc = current,
              let pidStr = dict["processID"] as? String,
              UUID(uuidString: pidStr) == proc.id else { return }

        let stream = dict["stream"] as? String ?? "stdout"
        guard let b64 = dict["data"] as? String,
              let data = Data(base64Encoded: b64) else { return }

        if stream == "stderr" {
            proc.onStderr?(data)
        } else {
            proc.onStdout?(data)
        }
    }

    /// Reply to a JS-side syscall by writing into the reply queue. JSON
    /// encoding + JS string escaping run on the background marshal queue —
    /// only the actual `evaluateJavaScript` call (which WebKit requires on
    /// main) hops back. Critical for not stalling the main actor when WASM
    /// is in a tight syscall loop.
    func replyToJS(callID: String, payload: [String: Any]) {
        var full = payload
        full["callID"] = callID
        let captured = full
        marshalQueue.async { [weak self] in
            guard let self else { return }
            guard let json = try? JSONSerialization.data(withJSONObject: captured, options: []),
                  let s = String(data: json, encoding: .utf8) else { return }
            let js = "rootshellWasm.deliver(JSON.parse(\(Self.jsStringLiteral(s))));"
            Task { @MainActor in
                self.evalOnMain(js)
            }
        }
    }
}

// MARK: - WKScriptMessageHandler proxy

/// Holds a weak reference to `WasmRuntime` and tags incoming messages with
/// their channel so the runtime can route them. Kept separate from the
/// runtime class so `WasmRuntime` doesn't have to conform to
/// `WKScriptMessageHandler` (which would conflict with our MainActor
/// isolation in places).
@MainActor
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var runtime: WasmRuntime?
    let channel: WasmRuntime.Channel

    init(runtime: WasmRuntime, channel: WasmRuntime.Channel) {
        self.runtime = runtime
        self.channel = channel
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        let body = message.body
        runtime?.handleMessage(body, channel: channel)
    }
}

// The earlier `WasmHostSchemeHandler` is gone: custom WKWebView URL
// schemes never qualify as secure contexts, so `crossOriginIsolated` was
// always false and SharedArrayBuffer unavailable. See `WasmLocalServer`
// for the loopback HTTP path that replaces it.
