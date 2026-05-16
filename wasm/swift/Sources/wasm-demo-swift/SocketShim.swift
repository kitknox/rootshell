// Thin Swift bindings over the `rootshell_socket_*` and `rootshell_terminal_*`
// ABIs exposed by the host. Uses Swift 6.0's `@_extern(wasm, module:, name:)`
// attribute to bind to the correct WASM module namespace; the matching Rust
// shim relies on the host's `env` fallback, but we name the modules
// explicitly to match the Go bindings.
//
// All ints are Int32; pointers are unsafe pointers (linear-memory offsets).
// Sockaddr layout matches BSD `sockaddr_in` / `sockaddr_in6` byte-for-byte.
//
// Note: WASM has no narrow integer types — `port` is widened to UInt32 in
// the import signatures (the host already truncates to 16 bits). Same trick
// the Go binding uses.

let AF_INET: Int32 = 2
let AF_INET6: Int32 = 30
let SOCK_STREAM: Int32 = 1
let SOCK_DGRAM: Int32 = 2

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_socket")
func rootshell_socket_socket(_ domain: Int32, _ type: Int32, _ fdOut: UnsafeMutablePointer<Int32>) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_bind")
func rootshell_socket_bind(_ fd: Int32, _ addr: UnsafePointer<UInt8>, _ addrLen: Int32) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_listen")
func rootshell_socket_listen(_ fd: Int32, _ backlog: Int32) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_accept")
func rootshell_socket_accept(_ fd: Int32, _ fdOut: UnsafeMutablePointer<Int32>) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_connect")
func rootshell_socket_connect(_ fd: Int32, _ addr: UnsafePointer<UInt8>, _ addrLen: Int32) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_send")
func rootshell_socket_send(_ fd: Int32, _ buf: UnsafePointer<UInt8>, _ length: Int32, _ sentOut: UnsafeMutablePointer<UInt32>) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_recv")
func rootshell_socket_recv(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ length: Int32, _ recvOut: UnsafeMutablePointer<UInt32>) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_sendto")
func rootshell_socket_sendto(_ fd: Int32, _ buf: UnsafePointer<UInt8>, _ length: Int32, _ addr: UnsafePointer<UInt8>, _ addrLen: Int32, _ sentOut: UnsafeMutablePointer<UInt32>) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_recvfrom")
func rootshell_socket_recvfrom(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ length: Int32, _ addr: UnsafeMutablePointer<UInt8>, _ addrLenIO: UnsafeMutablePointer<Int32>, _ recvOut: UnsafeMutablePointer<UInt32>) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_shutdown")
func rootshell_socket_shutdown(_ fd: Int32, _ how: Int32) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_close")
func rootshell_socket_close(_ fd: Int32) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_connect_host")
func rootshell_socket_connect_host(_ fd: Int32, _ host: UnsafePointer<UInt8>, _ hostLen: Int32, _ port: UInt32) -> Int32

// TLS-on-TCP: handshake + cert validation happen host-side via
// Network.framework. After this returns 0, regular send/recv work on
// the plaintext stream. No prior connect call is needed - this builds
// the underlying connection from scratch with TLS parameters.
@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_tls_connect_host")
func rootshell_socket_tls_connect_host(_ fd: Int32, _ host: UnsafePointer<UInt8>, _ hostLen: Int32, _ port: UInt32) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_bind_host")
func rootshell_socket_bind_host(_ fd: Int32, _ host: UnsafePointer<UInt8>, _ hostLen: Int32, _ port: UInt32) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_sendto_host")
func rootshell_socket_sendto_host(_ fd: Int32, _ buf: UnsafePointer<UInt8>, _ length: Int32, _ host: UnsafePointer<UInt8>, _ hostLen: Int32, _ port: UInt32, _ sentOut: UnsafeMutablePointer<UInt32>) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_resolve_v4")
func rootshell_socket_resolve_v4(_ host: UnsafePointer<UInt8>, _ hostLen: Int32, _ outBuf: UnsafeMutablePointer<UInt8>, _ outMax: Int32, _ countOut: UnsafeMutablePointer<UInt32>) -> Int32

@_extern(wasm, module: "rootshell_socket", name: "rootshell_socket_resolve_v6")
func rootshell_socket_resolve_v6(_ host: UnsafePointer<UInt8>, _ hostLen: Int32, _ outBuf: UnsafeMutablePointer<UInt8>, _ outMax: Int32, _ countOut: UnsafeMutablePointer<UInt32>) -> Int32

// -------- Terminal (raw / cooked input mode) --------

@_extern(wasm, module: "rootshell_terminal", name: "rootshell_terminal_set_raw")
func rootshell_terminal_set_raw(_ enabled: Int32) -> Int32

@_extern(wasm, module: "rootshell_terminal", name: "rootshell_terminal_is_tty")
func rootshell_terminal_is_tty(_ fd: Int32) -> Int32

/// Build a 16-byte AF_INET sockaddr_in. `host` must be a literal dotted-quad.
func sockaddrIn(_ host: String, port: UInt16) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 16)
    out[0] = UInt8(AF_INET)
    out[1] = 0
    out[2] = UInt8(port >> 8)
    out[3] = UInt8(port & 0xff)
    let parts = host.split(separator: ".")
    for i in 0..<min(4, parts.count) {
        if let v = UInt8(parts[i]) {
            out[4 + i] = v
        }
    }
    return out
}

func errnoName(_ e: Int32) -> String {
    switch e {
    case 0:  return "OK"
    case 2:  return "EACCES"
    case 8:  return "EBADF"
    case 14: return "ECONNREFUSED"
    case 27: return "EINTR"
    case 28: return "EINVAL"
    case 50: return "ENETUNREACH"
    case 73: return "ETIMEDOUT"
    default: return "errno"
    }
}

/// Run a closure with a stable pointer + length for the UTF-8 bytes of a
/// string. The host call must be synchronous (true for every
/// rootshell_socket_* import), so the buffer outliving the call is not a
/// concern.
func withUTF8<R>(_ s: String, _ body: (UnsafePointer<UInt8>, Int32) -> R) -> R {
    var copy = s
    return copy.withUTF8 { buf in
        let ptr = buf.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
        return body(ptr, Int32(buf.count))
    }
}
