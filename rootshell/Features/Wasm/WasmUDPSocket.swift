import Foundation
import Darwin

/// BSD UDP socket behind a WASM `SOCK_DGRAM` fd. Unconnected until
/// `connect`, so it sends anywhere and receives from any sender, one
/// datagram at a time with the real source address. All fd work runs on
/// `queue`; the fd closes in the read source's cancel handler.
nonisolated final class WasmUDPSocket: @unchecked Sendable {
    struct Datagram: Sendable {
        let data: Data
        let host: String
        let port: UInt16
    }

    /// Datagrams held for the guest before new ones drop, like a full socket buffer.
    static let queueLimit = 256
    /// Reads per read-source event, so sends and closes on `queue` interleave.
    private static let batchLimit = 32

    let family: Int32
    private let fd: Int32
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private var closed = false
    /// `shutdown` state, kept here because Darwin's SHUT_RD would leave the
    /// read source firing on EOF and SHUT_WR would raise SIGPIPE.
    private var readShut = false
    private var writeShut = false
    /// Datagrams handed to the broker and not yet taken by the guest.
    private var held = 0

    /// Returns the socket, or nil and a WASI errno. `onReceive` gets each
    /// batch and, after it, a WASI errno for a receive error (0 if none).
    static func open(family: Int32, queue: DispatchQueue,
                     onReceive: @escaping @Sendable ([Datagram], Int32) -> Void) -> (WasmUDPSocket?, Int32) {
        let fd = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return (nil, Errno.fromPOSIX(errno)) }
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        // Lets a guest share a port such as 5353 with mDNSResponder.
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, size)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return (WasmUDPSocket(fd: fd, family: family, queue: queue, onReceive: onReceive), 0)
    }

    private init(fd: Int32, family: Int32, queue: DispatchQueue,
                 onReceive: @escaping @Sendable ([Datagram], Int32) -> Void) {
        self.fd = fd
        self.family = family
        self.queue = queue
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let (batch, error) = self?.drain(), !batch.isEmpty || error != 0 else { return }
            onReceive(batch, error)
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    /// The guest took (or the broker dropped) `count` held datagrams.
    func release(_ count: Int) {
        queue.async { [self] in held = max(0, held - count) }
    }

    /// Sends fail with EPIPE after write shutdown; reads after read shutdown are discarded.
    func shutdown(read: Bool, write: Bool) {
        queue.async { [self] in
            if read { readShut = true }
            if write { writeShut = true }
        }
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            source.cancel()
        }
    }

    /// Binds to an IP literal (empty or a name binds the wildcard address).
    /// Completions take a WASI errno, 0 on success; bind also reports the port.
    func bind(host: String, port: UInt16, completion: @escaping @Sendable (Int32, UInt16) -> Void) {
        queue.async { [self] in
            guard !closed else { return completion(Errno.EBADF, 0) }
            let literal = Self.numericAddress(host, port: port, family: family)
            let address = literal ?? Self.wildcard(port: port, family: family)
            let rc = address.withSockaddr { Darwin.bind(fd, $0, $1) }
            completion(rc == 0 ? 0 : Errno.fromPOSIX(errno), boundPort())
        }
    }

    /// Fixes the peer; later receives only come from it.
    func connect(host: String, port: UInt16, completion: @escaping @Sendable (Int32) -> Void) {
        Self.resolve(host, port: port, family: family) { [self] address in
            queue.async { [self] in
                guard !closed else { return completion(Errno.EBADF) }
                guard let address else { return completion(Errno.ENOENT) }
                let rc = address.withSockaddr { Darwin.connect(fd, $0, $1) }
                completion(rc == 0 ? 0 : Errno.fromPOSIX(errno))
            }
        }
    }

    /// Sends to `host` (IP literal or name), or to the connected peer when
    /// nil. Completes with a WASI errno and the bytes sent.
    func send(_ data: Data, host: String?, port: UInt16,
              completion: @escaping @Sendable (Int32, Int) -> Void) {
        guard let host else {
            queue.async { [self] in
                let (e, n) = transmit(data, to: nil)
                completion(e, n)
            }
            return
        }
        Self.resolve(host, port: port, family: family) { [self] address in
            queue.async { [self] in
                guard let address else { return completion(Errno.ENOENT, 0) }
                let (e, n) = transmit(data, to: address)
                completion(e, n)
            }
        }
    }

    private func boundPort() -> UInt16 {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return rc == 0 ? Self.hostPort(storage).port : 0
    }

    private func transmit(_ data: Data, to address: SocketAddress?) -> (Int32, Int) {
        guard !closed else { return (Errno.EBADF, 0) }
        guard !writeShut else { return (Errno.EPIPE, 0) }
        let sent = data.withUnsafeBytes { buf -> Int in
            guard let address else { return Darwin.send(fd, buf.baseAddress, buf.count, 0) }
            return address.withSockaddr { Darwin.sendto(fd, buf.baseAddress, buf.count, 0, $0, $1) }
        }
        return sent < 0 ? (Errno.fromPOSIX(errno), 0) : (0, sent)
    }

    /// The read source is level-triggered, so whatever a batch leaves fires it again.
    private func drain() -> ([Datagram], Int32) {
        guard !closed else { return ([], 0) }
        var batch: [Datagram] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<Self.batchLimit {
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len)
                    }
                }
            }
            guard n >= 0 else {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { break }
                // ICMP errors such as ECONNREFUSED on a connected socket go to the next receive.
                held += batch.count
                return (batch, Errno.fromPOSIX(code))
            }
            // Read even when full, or the source would spin; the datagram drops.
            guard !readShut, held + batch.count < Self.queueLimit else { continue }
            let (host, port) = Self.hostPort(storage)
            batch.append(Datagram(data: Data(buffer[..<n]), host: host, port: port))
        }
        held += batch.count
        return (batch, 0)
    }

    // MARK: - Addresses

    struct SocketAddress: @unchecked Sendable {
        var storage: sockaddr_storage
        var length: socklen_t

        func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
            withUnsafePointer(to: storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
            }
        }
    }

    private static func numericAddress(_ host: String, port: UInt16, family: Int32) -> SocketAddress? {
        guard !host.isEmpty else { return nil }
        return lookup(host, port: port, family: family, flags: AI_NUMERICHOST | AI_NUMERICSERV)
    }

    private static func wildcard(port: UInt16, family: Int32) -> SocketAddress {
        lookup(nil, port: port, family: family, flags: AI_PASSIVE | AI_NUMERICSERV)
            ?? SocketAddress(storage: sockaddr_storage(), length: 0)
    }

    /// Literals resolve inline; names go through the system resolver off the queue.
    private static func resolve(_ host: String, port: UInt16, family: Int32,
                                completion: @escaping @Sendable (SocketAddress?) -> Void) {
        if let literal = numericAddress(host, port: port, family: family) {
            return completion(literal)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            completion(lookup(host, port: port, family: family, flags: AI_NUMERICSERV))
        }
    }

    private static func lookup(_ host: String?, port: UInt16, family: Int32, flags: Int32) -> SocketAddress? {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = flags
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var storage = sockaddr_storage()
        let length = first.pointee.ai_addrlen
        withUnsafeMutableBytes(of: &storage) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: first.pointee.ai_addr, count: Int(length)))
        }
        return SocketAddress(storage: storage, length: length)
    }

    static func hostPort(_ storage: sockaddr_storage) -> (host: String, port: UInt16) {
        var storage = storage
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var serv = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let len = socklen_t(storage.ss_len)
        let rc = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), &serv, socklen_t(serv.count),
                            NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard rc == 0 else { return ("", 0) }
        return (cString(host), UInt16(cString(serv)) ?? 0)
    }

    static func cString(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
