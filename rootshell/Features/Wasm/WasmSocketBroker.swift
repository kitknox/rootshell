import Foundation
import Network
import Security

/// Bridges the `rootshell_socket_*` ABI used by WASM modules to Apple's
/// `Network.framework`. Operates on virtual fds allocated by `WasmProcess`
/// (sockets start at 100 to avoid clashing with WASI file descriptors).
///
/// Every call from JS is replied to exactly once via
/// `runtime.replyToJS(callID:payload:)`. Blocking operations (connect, recv,
/// accept) hold the reply until data is available; the JS Worker is parked
/// on `Atomics.wait` in the meantime so this looks synchronous to WASM.
@MainActor
final class WasmSocketBroker {
    private let queue = DispatchQueue(label: "com.rootshell.wasm.socket")

    /// Recv requests parked while waiting for bytes to land on a TCP/UDP fd.
    private struct PendingRecv {
        let callID: String
        let fd: Int32
        let maxLen: Int
    }
    private var pendingRecvs: [Int32: [PendingRecv]] = [:]

    /// Accept requests parked while waiting for an inbound connection.
    private struct PendingAccept {
        let callID: String
        let fd: Int32
    }
    private var pendingAccepts: [Int32: [PendingAccept]] = [:]

    /// Connect callIDs in-flight per fd (so we resolve exactly once).
    private var pendingConnects: [Int32: String] = [:]

    /// Connects held open while the Local Network prompt may be up.
    private var localNetworkWaits: Set<ObjectIdentifier> = []
    private static let localNetworkGrace: Duration = .seconds(30)
    private static var localNetworkGraceExpired = false

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

        switch op {
        case "socket":     opSocket(dict, proc: proc, callID: callID, runtime: runtime)
        case "bind":       opBind(dict, proc: proc, callID: callID, runtime: runtime)
        case "listen":     opListen(dict, proc: proc, callID: callID, runtime: runtime)
        case "accept":     opAccept(dict, proc: proc, callID: callID, runtime: runtime)
        case "connect":    opConnect(dict, proc: proc, callID: callID, runtime: runtime)
        case "tls_connect": opTlsConnect(dict, proc: proc, callID: callID, runtime: runtime)
        case "send":       opSend(dict, proc: proc, callID: callID, runtime: runtime)
        case "recv":       opRecv(dict, proc: proc, callID: callID, runtime: runtime)
        case "sendto":     opSendto(dict, proc: proc, callID: callID, runtime: runtime)
        case "recvfrom":   opRecvfrom(dict, proc: proc, callID: callID, runtime: runtime)
        case "shutdown":   opShutdown(dict, proc: proc, callID: callID, runtime: runtime)
        case "close":      opClose(dict, proc: proc, callID: callID, runtime: runtime)
        case "getsockname": opGetsockname(dict, proc: proc, callID: callID, runtime: runtime)
        case "getpeername": opGetpeername(dict, proc: proc, callID: callID, runtime: runtime)
        case "resolve":    opResolve(dict, callID: callID, runtime: runtime)
        case "set_recv_timeout": opSetRecvTimeout(dict, proc: proc, callID: callID, runtime: runtime)
        case "bonjour_lookup": opBonjourLookup(dict, proc: proc, callID: callID, runtime: runtime)
        default:
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.ENOSYS])
        }
    }

    // MARK: - Ops

    private func opSocket(_ dict: [String: Any],
                          proc: WasmProcess,
                          callID: String,
                          runtime: WasmRuntime) {
        guard let domain = (dict["domain"] as? NSNumber)?.int32Value,
              let type = (dict["type"] as? NSNumber)?.int32Value else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        guard domain == 2 || domain == 30 else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let kind: WasmProcess.SocketHandle.Kind
        switch type {
        case 1: kind = .tcpClient
        case 2: kind = .udp
        default:
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let h = WasmProcess.SocketHandle(kind: kind)
        let fd = proc.nextSocketFd
        if kind == .udp {
            let (udp, err) = WasmUDPSocket.open(
                family: domain == 30 ? AF_INET6 : AF_INET, queue: queue
            ) { [weak self, weak proc] batch, error in
                guard let self, let proc else { return }
                Task { @MainActor in
                    self.enqueueDatagrams(batch, error: error, fd: fd, proc: proc, runtime: runtime)
                }
            }
            guard let udp else {
                runtime.replyToJS(callID: callID, payload: ["errno": err])
                return
            }
            h.primitive = udp
        }
        proc.nextSocketFd += 1
        proc.socketHandles[fd] = h
        runtime.replyToJS(callID: callID, payload: ["errno": 0, "fd": fd])
    }

    private func opBind(_ dict: [String: Any],
                        proc: WasmProcess,
                        callID: String,
                        runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd],
              let port = (dict["port"] as? NSNumber)?.uint16Value else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        if let udp = handle.primitive as? WasmUDPSocket {
            udp.bind(host: dict["host"] as? String ?? "", port: port) { err, bound in
                Task { @MainActor in
                    if err == 0 { handle.localPort = bound }
                    Self.reply(proc, callID: callID, payload: ["errno": err], runtime: runtime)
                }
            }
            return
        }
        // TCP only needs the port, for `listen`; Network.framework picks the interface.
        handle.localPort = port
        runtime.replyToJS(callID: callID, payload: ["errno": 0])
    }

    private func opListen(_ dict: [String: Any],
                          proc: WasmProcess,
                          callID: String,
                          runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        guard handle.kind == .tcpClient else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        // Convert this fd into a TCP listener.
        let portValue = handle.localPort == 0 ? UInt16(0) : handle.localPort
        guard let nwPort = NWEndpoint.Port(rawValue: portValue == 0 ? 0 : portValue) else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }

        let listener: NWListener
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: nwPort == 0 ? .any : nwPort)
        } catch {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EADDRINUSE])
            return
        }

        handle.primitive = ListenerBox(listener: listener)
        // Upgrade kind in place — the same `SocketHandle` instance must stay
        // in the fd table, otherwise `newConnectionHandler` (below) ends up
        // appending to a dead reference while `opAccept` reads from the
        // replacement, and clients hang forever.
        handle.kind = .tcpListener

        listener.newConnectionHandler = { [weak self, weak proc, weak runtime, weak handle] conn in
            guard let self = self, let proc = proc, let runtime = runtime,
                  let handle = handle else { return }
            Task { @MainActor in
                conn.start(queue: self.queue)
                let peer = WasmSocketBroker.endpointHostPort(conn.endpoint)
                handle.pendingAccepts.append((ConnectionBox(connection: conn), peer.0, peer.1))
                self.flushPendingAccept(fd: fd, proc: proc, handle: handle, runtime: runtime)
            }
        }
        // Resolve actual port if 0 was requested.
        listener.stateUpdateHandler = { [weak handle] state in
            if case .ready = state, let p = listener.port?.rawValue {
                Task { @MainActor [weak handle] in
                    handle?.localPort = p
                }
            }
        }
        listener.start(queue: queue)

        runtime.replyToJS(callID: callID, payload: ["errno": 0])
    }

    private func opAccept(_ dict: [String: Any],
                          proc: WasmProcess,
                          callID: String,
                          runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd], handle.kind == .tcpListener else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }

        if !handle.pendingAccepts.isEmpty {
            let pending = handle.pendingAccepts.removeFirst()
            let newFd = installAcceptedConnection(pending: pending, proc: proc, runtime: runtime)
            runtime.replyToJS(callID: callID, payload: [
                "errno": 0, "fd": newFd,
                "peerHost": pending.1, "peerPort": pending.2
            ])
        } else {
            pendingAccepts[fd, default: []].append(PendingAccept(callID: callID, fd: fd))
        }
    }

    private func flushPendingAccept(fd: Int32,
                                    proc: WasmProcess,
                                    handle: WasmProcess.SocketHandle,
                                    runtime: WasmRuntime) {
        // Re-fetch the (possibly upgraded) listener handle.
        guard let listenerHandle = proc.socketHandles[fd] else { return }
        guard !listenerHandle.pendingAccepts.isEmpty else { return }
        guard var waiters = pendingAccepts[fd], !waiters.isEmpty else { return }

        let pending = listenerHandle.pendingAccepts.removeFirst()
        let waiter = waiters.removeFirst()
        pendingAccepts[fd] = waiters
        let newFd = installAcceptedConnection(pending: pending, proc: proc, runtime: runtime)
        runtime.replyToJS(callID: waiter.callID, payload: [
            "errno": 0, "fd": newFd,
            "peerHost": pending.1, "peerPort": pending.2
        ])
        _ = handle
    }

    private func installAcceptedConnection(pending: (AnyObject, String, UInt16),
                                           proc: WasmProcess,
                                           runtime: WasmRuntime) -> Int32 {
        let h = WasmProcess.SocketHandle(kind: .tcpClient)
        h.primitive = pending.0
        h.peerHost = pending.1
        h.peerPort = pending.2
        let fd = proc.nextSocketFd
        proc.nextSocketFd += 1
        proc.socketHandles[fd] = h
        if let box = pending.0 as? ConnectionBox {
            receiveLoop(connection: box.connection, fd: fd, proc: proc, runtime: runtime)
        }
        return fd
    }

    private func opConnect(_ dict: [String: Any],
                           proc: WasmProcess,
                           callID: String,
                           runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        guard let host = dict["host"] as? String,
              let port = (dict["port"] as? NSNumber)?.uint16Value,
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }

        if let udp = handle.primitive as? WasmUDPSocket {
            udp.connect(host: host, port: port) { err in
                Task { @MainActor in
                    if err == 0 {
                        handle.peerHost = host
                        handle.peerPort = port
                    }
                    Self.reply(proc, callID: callID, payload: ["errno": err], runtime: runtime)
                }
            }
            return
        }
        guard handle.kind == .tcpClient else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let params = NWParameters.tcp

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        handle.primitive = ConnectionBox(connection: conn)
        handle.peerHost = host
        handle.peerPort = port
        pendingConnects[fd] = callID

        conn.stateUpdateHandler = { [weak self, weak proc] state in
            guard let self = self, let proc = proc else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    if let cid = self.pendingConnects.removeValue(forKey: fd) {
                        runtime.replyToJS(callID: cid, payload: ["errno": 0])
                        self.receiveLoop(connection: conn, fd: fd, proc: proc, runtime: runtime)
                    }
                case .waiting(let err):
                    self.endWaitingConnect(err, conn: conn, fd: fd, proc: proc, runtime: runtime)
                case .failed(let err):
                    if let cid = self.pendingConnects.removeValue(forKey: fd) {
                        runtime.replyToJS(callID: cid, payload: ["errno": Self.connectErrno(err)])
                    }
                    self.failPendingRecvs(fd: fd, errno: Errno.EIO, runtime: runtime)
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    /// TLS variant of `opConnect`. Builds the `NWConnection` directly with
    /// `NWParameters(tls:tcp:)` so `Network.framework` does the handshake,
    /// cert validation, and SNI on the host side. WASM guests then do
    /// plaintext `send` / `recv` on the same fd. Crucially, this saves
    /// guests from bundling rustls/openssl into a WASI binary (neither
    /// compiles cleanly to `wasm32-wasip1`).
    private func opTlsConnect(_ dict: [String: Any],
                              proc: WasmProcess,
                              callID: String,
                              runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        guard handle.kind == .tcpClient else {
            // TLS only makes sense over TCP client sockets.
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        guard let host = dict["host"] as? String,
              let port = (dict["port"] as? NSNumber)?.uint16Value,
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }

        // If this fd already had a connection (e.g. a previous opConnect),
        // tear it down before building the TLS one. Buffers reset too —
        // any pending recvs from the old socket are no longer meaningful.
        if let prior = handle.primitive as? ConnectionBox {
            prior.connection.cancel()
        }
        handle.pendingReads.removeAll()
        handle.eofReceived = false

        let tlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(
            tlsOpts.securityProtocolOptions, host)
        let params = NWParameters(tls: tlsOpts, tcp: .init())

        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: nwPort,
                                using: params)
        handle.primitive = ConnectionBox(connection: conn)
        handle.peerHost = host
        handle.peerPort = port
        pendingConnects[fd] = callID

        conn.stateUpdateHandler = { [weak self, weak proc] state in
            guard let self = self, let proc = proc else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    if let cid = self.pendingConnects.removeValue(forKey: fd) {
                        runtime.replyToJS(callID: cid, payload: ["errno": 0])
                        self.receiveLoop(connection: conn, fd: fd, proc: proc, runtime: runtime)
                    }
                case .waiting(let err):
                    self.endWaitingConnect(err, conn: conn, fd: fd, proc: proc, runtime: runtime)
                case .failed(let err):
                    if let cid = self.pendingConnects.removeValue(forKey: fd) {
                        runtime.replyToJS(callID: cid, payload: ["errno": Self.connectErrno(err)])
                    }
                    self.failPendingRecvs(fd: fd, errno: Errno.EIO, runtime: runtime)
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    /// Network.framework retries a refused or unreachable connect indefinitely;
    /// POSIX connect fails, so the guest can retry. The Local Network prompt
    /// also parks a connect, and Allow resumes it, so that case gets a grace.
    private func endWaitingConnect(_ err: NWError, conn: NWConnection, fd: Int32,
                                   proc: WasmProcess, runtime: WasmRuntime) {
        // fds and call IDs repeat across invocations; a connect left behind
        // by an ended process must not answer the current one.
        guard Self.owns(conn, fd: fd, proc: proc, runtime: runtime) else {
            conn.cancel()
            return
        }
        // A later state update (Allow resuming it) answers the connect instead.
        guard case .waiting = conn.state, let cid = pendingConnects[fd] else { return }
        if Self.localNetworkBlocked(conn), !Self.localNetworkGraceExpired {
            guard localNetworkWaits.insert(ObjectIdentifier(conn)).inserted else { return }
            Task { @MainActor [weak self, weak proc] in
                try? await Task.sleep(for: Self.localNetworkGrace)
                guard let self else { return }
                self.localNetworkWaits.remove(ObjectIdentifier(conn))
                guard let proc, Self.owns(conn, fd: fd, proc: proc, runtime: runtime) else {
                    conn.cancel()
                    return
                }
                // Allow resumed the connect; its own state updates answer it.
                guard self.pendingConnects[fd] == cid, Self.localNetworkBlocked(conn) else { return }
                // Unanswered or denied: later connects fail without the wait.
                Self.localNetworkGraceExpired = true
                self.pendingConnects.removeValue(forKey: fd)
                conn.cancel()
                runtime.replyToJS(callID: cid, payload: ["errno": Errno.EACCES])
            }
            return
        }
        let e = Self.localNetworkBlocked(conn) ? Errno.EACCES : Self.connectErrno(err)
        pendingConnects.removeValue(forKey: fd)
        conn.cancel()
        runtime.replyToJS(callID: cid, payload: ["errno": e])
    }

    private static func owns(_ conn: NWConnection, fd: Int32, proc: WasmProcess,
                             runtime: WasmRuntime) -> Bool {
        runtime.current === proc
            && (proc.socketHandles[fd]?.primitive as? ConnectionBox)?.connection === conn
    }

    private static func localNetworkBlocked(_ conn: NWConnection) -> Bool {
        guard case .waiting = conn.state else { return false }
        return conn.currentPath?.unsatisfiedReason == .localNetworkDenied
    }

    /// Handshake and cert failures (`.tls`) report as ECONNREFUSED so guests
    /// bail out the same way they do on a TCP refusal.
    private static func connectErrno(_ err: NWError) -> Int32 {
        switch err {
        case .tls:                  return Errno.ECONNREFUSED
        case .posix(.ECONNREFUSED): return Errno.ECONNREFUSED
        case .posix(.ETIMEDOUT):    return Errno.ETIMEDOUT
        case .posix(.ENETUNREACH), .posix(.ENETDOWN), .posix(.EHOSTUNREACH):
            return Errno.ENETUNREACH
        default:                    return Errno.EIO
        }
    }

    /// TCP only; UDP fds read through `WasmUDPSocket`.
    private func receiveLoop(connection: NWConnection,
                             fd: Int32,
                             proc: WasmProcess,
                             runtime: WasmRuntime) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak proc] (data, _, isComplete, error) in
            guard let self = self, let proc = proc else { return }
            Task { @MainActor in
                self.handleIncoming(data: data, error: error, isComplete: isComplete,
                                    fd: fd, proc: proc, runtime: runtime)
                // Only reschedule if there's more to read. On EOF
                // (`isComplete`) handleIncoming has already marked the
                // socket and drained any parked recvs.
                if proc.socketHandles[fd]?.isClosed != true && !isComplete {
                    self.receiveLoop(connection: connection, fd: fd, proc: proc, runtime: runtime)
                }
            }
        }
    }

    private func enqueueDatagrams(_ batch: [WasmUDPSocket.Datagram],
                                  error: Int32,
                                  fd: Int32,
                                  proc: WasmProcess,
                                  runtime: WasmRuntime) {
        guard let handle = proc.socketHandles[fd],
              let udp = handle.primitive as? WasmUDPSocket else { return }
        // Read side shut down while this batch was in flight.
        if handle.eofReceived {
            udp.release(batch.count)
            return
        }
        handle.datagrams.append(contentsOf: batch.map { ($0.data, $0.host, $0.port) })
        flushPendingRecvs(fd: fd, proc: proc, runtime: runtime)
        guard error != 0 else { return }
        // Like BSD so_error: the next receive reports it, after earlier datagrams.
        if handle.datagrams.isEmpty, var waiters = pendingRecvs[fd], !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            pendingRecvs[fd] = waiters
            runtime.replyToJS(callID: waiter.callID, payload: ["errno": error])
        } else {
            handle.pendingError = error
        }
    }

    private func handleIncoming(data: Data?,
                                error: NWError?,
                                isComplete: Bool,
                                fd: Int32,
                                proc: WasmProcess,
                                runtime: WasmRuntime) {
        if let err = error {
            _ = err
            failPendingRecvs(fd: fd, errno: Errno.EIO, runtime: runtime)
            return
        }
        guard let handle = proc.socketHandles[fd] else { return }

        if let data = data, !data.isEmpty {
            handle.pendingReads.append(data)
        }
        if isComplete {
            // Peer half-closed (HTTP/1.0, connection: close, etc.).
            handle.eofReceived = true
        }
        flushPendingRecvs(fd: fd, proc: proc, runtime: runtime)
    }

    private func flushPendingRecvs(fd: Int32, proc: WasmProcess, runtime: WasmRuntime) {
        guard var waiters = pendingRecvs[fd], !waiters.isEmpty,
              let handle = proc.socketHandles[fd] else { return }
        if handle.kind == .udp {
            while !waiters.isEmpty, !handle.datagrams.isEmpty {
                let waiter = waiters.removeFirst()
                runtime.replyToJS(callID: waiter.callID,
                                  payload: Self.takeDatagram(handle, maxLen: waiter.maxLen))
            }
            if handle.eofReceived {
                for waiter in waiters {
                    runtime.replyToJS(callID: waiter.callID, payload: ["errno": 0, "data": ""])
                }
                waiters.removeAll()
            }
            pendingRecvs[fd] = waiters
            return
        }
        // Serve buffered bytes first.
        while !waiters.isEmpty, !handle.pendingReads.isEmpty {
            let waiter = waiters.removeFirst()
            let take = min(waiter.maxLen, handle.pendingReads.count)
            let slice = handle.pendingReads.prefix(take)
            handle.pendingReads.removeFirst(take)
            runtime.replyToJS(callID: waiter.callID, payload: [
                "errno": 0,
                "data": Data(slice).base64EncodedString()
            ])
        }
        // Once the buffer is empty and EOF has arrived, return 0 bytes to
        // every remaining waiter so they break out of their read loops —
        // standard BSD `recv == 0` means peer closed.
        if handle.eofReceived && handle.pendingReads.isEmpty {
            for waiter in waiters {
                runtime.replyToJS(callID: waiter.callID, payload: [
                    "errno": 0,
                    "data": ""
                ])
            }
            waiters.removeAll()
        }
        pendingRecvs[fd] = waiters
    }

    private func failPendingRecvs(fd: Int32, errno: Int32, runtime: WasmRuntime) {
        guard let waiters = pendingRecvs.removeValue(forKey: fd) else { return }
        for w in waiters {
            runtime.replyToJS(callID: w.callID, payload: ["errno": errno])
        }
    }

    private func opSend(_ dict: [String: Any],
                        proc: WasmProcess,
                        callID: String,
                        runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd],
              let b64 = dict["data"] as? String,
              let data = Data(base64Encoded: b64) else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        if let udp = handle.primitive as? WasmUDPSocket {
            udp.send(data, host: nil, port: 0) { err, sent in
                Task { @MainActor in
                    Self.reply(proc, callID: callID, payload: ["errno": err, "sent": sent], runtime: runtime)
                }
            }
            return
        }
        guard let box = handle.primitive as? ConnectionBox else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        box.connection.send(content: data, completion: .contentProcessed { err in
            Task { @MainActor in
                if let err = err {
                    _ = err
                    runtime.replyToJS(callID: callID, payload: ["errno": Errno.EIO])
                } else {
                    runtime.replyToJS(callID: callID, payload: ["errno": 0, "sent": data.count])
                }
            }
        })
    }

    private func opRecv(_ dict: [String: Any],
                        proc: WasmProcess,
                        callID: String,
                        runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd],
              let maxLen = (dict["maxLen"] as? NSNumber)?.intValue else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }

        if handle.kind == .udp, !handle.datagrams.isEmpty {
            runtime.replyToJS(callID: callID, payload: Self.takeDatagram(handle, maxLen: maxLen))
            return
        }
        if handle.pendingError != 0 {
            let error = handle.pendingError
            handle.pendingError = 0
            runtime.replyToJS(callID: callID, payload: ["errno": error])
            return
        }
        if !handle.pendingReads.isEmpty {
            let take = min(maxLen, handle.pendingReads.count)
            let slice = handle.pendingReads.prefix(take)
            handle.pendingReads.removeFirst(take)
            runtime.replyToJS(callID: callID, payload: [
                "errno": 0,
                "data": Data(slice).base64EncodedString()
            ])
            return
        }
        // Buffer empty but peer already closed → EOF immediately.
        if handle.eofReceived {
            runtime.replyToJS(callID: callID, payload: ["errno": 0, "data": ""])
            return
        }
        let waiter = PendingRecv(callID: callID, fd: fd, maxLen: maxLen)
        pendingRecvs[fd, default: []].append(waiter)
        guard let timeout = handle.recvTimeout else { return }
        Task { @MainActor [weak self, weak proc] in
            try? await Task.sleep(for: timeout)
            // Call IDs restart with each process, so match the process too.
            guard let self, let proc, runtime.current === proc,
                  var waiters = self.pendingRecvs[fd],
                  let index = waiters.firstIndex(where: { $0.callID == callID }) else { return }
            waiters.remove(at: index)
            self.pendingRecvs[fd] = waiters
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EAGAIN])
        }
    }

    /// One whole datagram per receive; bytes past `maxLen` are discarded.
    private static func takeDatagram(_ handle: WasmProcess.SocketHandle, maxLen: Int) -> [String: Any] {
        let d = handle.datagrams.removeFirst()
        (handle.primitive as? WasmUDPSocket)?.release(1)
        return [
            "errno": 0,
            "data": d.data.prefix(maxLen).base64EncodedString(),
            "peerHost": d.host,
            "peerPort": Int(d.port)
        ]
    }

    private func opSetRecvTimeout(_ dict: [String: Any],
                                  proc: WasmProcess,
                                  callID: String,
                                  runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        let ms = (dict["timeoutMs"] as? NSNumber)?.int64Value ?? 0
        guard ms >= 0 else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        handle.recvTimeout = ms == 0 ? nil : .milliseconds(ms)
        runtime.replyToJS(callID: callID, payload: ["errno": 0])
    }

    private func opBonjourLookup(_ dict: [String: Any],
                                 proc: WasmProcess,
                                 callID: String,
                                 runtime: WasmRuntime) {
        guard let type = dict["type"] as? String, !type.isEmpty,
              let ms = (dict["timeoutMs"] as? NSNumber)?.int64Value, ms > 0 else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let timeout = TimeInterval(min(ms, 60_000)) / 1000
        WasmBonjourLookup.start(type: type, timeout: timeout) { err, instances in
            let text = WasmBonjourLookup.format(instances)
            Task { @MainActor in
                Self.reply(proc, callID: callID, payload: ["errno": err, "text": text], runtime: runtime)
            }
        }
    }

    private func opSendto(_ dict: [String: Any],
                          proc: WasmProcess,
                          callID: String,
                          runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        guard handle.kind == .udp,
              let host = dict["host"] as? String,
              let port = (dict["port"] as? NSNumber)?.uint16Value,
              let b64 = dict["data"] as? String,
              let data = Data(base64Encoded: b64) else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }

        guard let udp = handle.primitive as? WasmUDPSocket else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        // Unconnected: replies from any sender reach recvfrom with their own address.
        udp.send(data, host: host, port: port) { err, sent in
            Task { @MainActor in
                Self.reply(proc, callID: callID, payload: ["errno": err, "sent": sent], runtime: runtime)
            }
        }
    }

    private func opRecvfrom(_ dict: [String: Any],
                            proc: WasmProcess,
                            callID: String,
                            runtime: WasmRuntime) {
        // Same path as `opRecv`: UDP replies always carry the datagram's
        // sender, which the JS recvfrom shim turns into a sockaddr.
        opRecv(dict, proc: proc, callID: callID, runtime: runtime)
    }

    private func opShutdown(_ dict: [String: Any],
                            proc: WasmProcess,
                            callID: String,
                            runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        if let udp = handle.primitive as? WasmUDPSocket {
            let how = (dict["how"] as? NSNumber)?.intValue ?? -1
            guard (0...2).contains(how) else {
                runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
                return
            }
            let read = how != 1, write = how != 0
            udp.shutdown(read: read, write: write)
            if read {
                // Queued datagrams are discarded and receives see EOF, as on BSD.
                udp.release(handle.datagrams.count)
                handle.datagrams.removeAll()
                handle.pendingError = 0
                handle.eofReceived = true
                flushPendingRecvs(fd: fd, proc: proc, runtime: runtime)
            }
            runtime.replyToJS(callID: callID, payload: ["errno": 0])
            return
        }
        guard let box = handle.primitive as? ConnectionBox else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        box.connection.cancel()
        runtime.replyToJS(callID: callID, payload: ["errno": 0])
    }

    private func opClose(_ dict: [String: Any],
                         proc: WasmProcess,
                         callID: String,
                         runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        Self.release(handle)
        proc.socketHandles.removeValue(forKey: fd)
        failPendingRecvs(fd: fd, errno: Errno.EBADF, runtime: runtime)
        runtime.replyToJS(callID: callID, payload: ["errno": 0])
    }

    /// Closes every socket a finished process left open and drops its parked calls.
    func closeAll(for proc: WasmProcess) {
        for handle in proc.socketHandles.values { Self.release(handle) }
        proc.socketHandles.removeAll()
        pendingRecvs.removeAll()
        pendingAccepts.removeAll()
        pendingConnects.removeAll()
    }

    /// For replies that land after a hop: call IDs restart with each process,
    /// so one meant for a finished process must not answer the next.
    private static func reply(_ proc: WasmProcess, callID: String, payload: [String: Any],
                              runtime: WasmRuntime) {
        guard runtime.current === proc else { return }
        runtime.replyToJS(callID: callID, payload: payload)
    }

    private static func release(_ handle: WasmProcess.SocketHandle) {
        (handle.primitive as? ConnectionBox)?.connection.cancel()
        (handle.primitive as? ListenerBox)?.listener.cancel()
        (handle.primitive as? WasmUDPSocket)?.close()
        handle.isClosed = true
    }

    private func opGetsockname(_ dict: [String: Any],
                               proc: WasmProcess,
                               callID: String,
                               runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        runtime.replyToJS(callID: callID, payload: [
            "errno": 0,
            "host": "0.0.0.0",
            "port": Int(handle.localPort)
        ])
    }

    /// `resolve` is the porting-friendly DNS entry point. We let
    /// Network.framework do the lookup since it integrates with iOS's
    /// system resolver, VPN routing, and IPv6 happy-eyeballs. Returns one
    /// or more IPv4 addresses (4 bytes each) packed into the reply buffer.
    /// The JS shim exposes this to WASM as
    /// `rootshell_socket_resolve_v4(host_ptr, host_len, out_buf, out_max,
    /// count_out) -> errno`.
    private func opResolve(_ dict: [String: Any],
                           callID: String,
                           runtime: WasmRuntime) {
        guard let host = dict["host"] as? String else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EINVAL])
            return
        }
        let maxResults = (dict["maxResults"] as? NSNumber)?.intValue ?? 8
        let family = (dict["family"] as? String) ?? "v4"

        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: family == "v6" ? AF_INET6 : AF_INET,
                ai_socktype: SOCK_STREAM,
                ai_protocol: 0,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, nil, &hints, &result)
            if rc != 0 {
                Task { @MainActor in
                    runtime.replyToJS(callID: callID, payload: [
                        "errno": rc == EAI_NONAME ? Errno.ENOENT : Errno.EIO,
                        "gai_error": String(cString: gai_strerror(rc))
                    ])
                }
                return
            }
            defer { if let result = result { freeaddrinfo(result) } }

            var addrs: [[UInt8]] = []
            var node = result
            while let n = node, addrs.count < maxResults {
                if family == "v4", n.pointee.ai_family == AF_INET {
                    n.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        var ip = sin.pointee.sin_addr.s_addr.bigEndian
                        var bytes: [UInt8] = []
                        for _ in 0..<4 {
                            bytes.append(UInt8(ip & 0xff))
                            ip >>= 8
                        }
                        addrs.append(bytes.reversed())
                    }
                } else if family == "v6", n.pointee.ai_family == AF_INET6 {
                    n.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin in
                        let raw = sin.pointee.sin6_addr
                        let bytes: [UInt8] = withUnsafeBytes(of: raw) { Array($0) }
                        addrs.append(bytes)
                    }
                }
                node = n.pointee.ai_next
            }

            let resolved = addrs
            Task { @MainActor in
                if resolved.isEmpty {
                    runtime.replyToJS(callID: callID, payload: ["errno": Errno.ENOENT])
                } else {
                    runtime.replyToJS(callID: callID, payload: [
                        "errno": 0,
                        "addrs": resolved.map { Data($0).base64EncodedString() }
                    ])
                }
            }
        }
    }

    private func opGetpeername(_ dict: [String: Any],
                               proc: WasmProcess,
                               callID: String,
                               runtime: WasmRuntime) {
        guard let fd = (dict["fd"] as? NSNumber)?.int32Value,
              let handle = proc.socketHandles[fd] else {
            runtime.replyToJS(callID: callID, payload: ["errno": Errno.EBADF])
            return
        }
        runtime.replyToJS(callID: callID, payload: [
            "errno": 0,
            "host": handle.peerHost,
            "port": Int(handle.peerPort)
        ])
    }

    // MARK: - Helpers

    private static func endpointHostPort(_ endpoint: NWEndpoint) -> (String, UInt16) {
        switch endpoint {
        case .hostPort(let host, let port):
            return (host.debugDescription, port.rawValue)
        default:
            return ("", 0)
        }
    }
}

// MARK: - Boxes (so we can stuff non-Sendable Network types into AnyObject)

final class ConnectionBox: NSObject, @unchecked Sendable {
    let connection: NWConnection
    init(connection: NWConnection) {
        self.connection = connection
    }
}

final class ListenerBox: NSObject, @unchecked Sendable {
    let listener: NWListener
    init(listener: NWListener) {
        self.listener = listener
    }
}

