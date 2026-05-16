// Demo WASM binary for the rootshell iOS local shell WASM runtime, Swift edition.
// Built with the Swift WASI SDK (see build.sh). Each subcommand mirrors the
// Rust and Go wasm-demos and exercises one slice of the runtime + sandbox
// surface:
//
//   hello                       - args, env, stdout, exit
//   fs-write <path>             - sandboxed write
//   fs-read  <path>             - sandboxed read
//   fs-escape <path>            - should be rejected by the sandbox (negative)
//   tcp-client <h> <p>          - connect, send HTTP/1.0 GET, dump response
//   tls-client <h> <p>          - TLS variant of tcp-client, hits HTTPS hosts
//   dns-query <name> [resolver] - hand-rolled DNS/A query over UDP
//   tcp-listen <port>           - bind/listen/accept, echo one line, exit
//   all                         - runs every self-contained subcommand,
//                                 plus dns-query / tcp-client / tls-client
//                                 against real internet hosts. tcp-listen
//                                 needs a peer, so it's driven by the in-app
//                                 `wasm test` runner (which spins up loopback
//                                 servers), not by this battery.
//
// Foundation is intentionally NOT imported - it would balloon the .wasm by
// ~50 MB (ICU, full NS object graph, etc). All I/O goes through WASILibc
// (fopen/fread/fwrite/fputs/getenv/exit), which is what wasi-libc exposes
// under WASI Preview 1.

import WASILibc

// MARK: - I/O helpers (no Foundation)

func eprint(_ s: String) {
    var copy = s
    copy.withUTF8 { buf in
        if let p = buf.baseAddress, buf.count > 0 {
            _ = fwrite(p, 1, buf.count, stderr)
        }
    }
    _ = fputs("\n", stderr)
}

func writeStdout(_ bytes: UnsafePointer<UInt8>, _ count: Int) {
    _ = fwrite(bytes, 1, count, stdout)
}

func strerrorString(_ e: Int32) -> String {
    guard let p = strerror(e) else { return "errno=\(e)" }
    return String(cString: p)
}

func hex2(_ b: UInt8) -> String {
    let s = String(b, radix: 16, uppercase: false)
    return s.count < 2 ? "0\(s)" : s
}

func getenvString(_ name: String) -> String? {
    guard let p = getenv(name) else { return nil }
    return String(cString: p)
}

// MARK: - Entry point

func arg(_ args: [String], _ i: Int, _ def: String) -> String {
    return i < args.count ? args[i] : def
}

func parsePort(_ s: String) -> UInt16 {
    return UInt16(s) ?? 0
}

let args = CommandLine.arguments
let sub = args.count > 1 ? args[1] : "hello"

let code: Int32
switch sub {
case "hello":
    code = cmdHello(args)
// Relative paths land in the cwd the .wasm was launched from, so the user
// can see the artifact appear next to the binary in Files.
case "fs-write":
    code = cmdFsWrite(arg(args, 2, "wasm-demo.txt"))
case "fs-read":
    code = cmdFsRead(arg(args, 2, "wasm-demo.txt"))
// The sandbox clamps `..` traversal - this is a negative test that we
// expect to fail with EACCES.
case "fs-escape":
    code = cmdFsEscape(arg(args, 2, "../../outside.txt"))
case "tcp-client":
    code = cmdTCPClient(arg(args, 2, "127.0.0.1"), parsePort(arg(args, 3, "80")))
case "tls-client":
    code = cmdTLSClient(arg(args, 2, "google.com"), parsePort(arg(args, 3, "443")))
case "dns-query":
    code = cmdDNSQuery(arg(args, 2, "google.com"), arg(args, 3, "1.1.1.1"))
case "tcp-listen":
    code = cmdTCPListen(parsePort(arg(args, 2, "0")))
case "all":
    code = cmdAll()
default:
    print("wasm-demo: unknown subcommand \(sub)")
    code = 1
}

exit(code)

// MARK: - Subcommands

func cmdHello(_ args: [String]) -> Int32 {
    print("hello from wasm-demo (swift)")
    print("argv = \(args)")
    if let h = getenvString("HOME") {
        print("HOME = \(h)")
    }
    if let p = getenvString("PWD") {
        print("PWD = \(p)")
    }
    return 0
}

func cmdFsWrite(_ path: String) -> Int32 {
    let content = "hello, wasm fs (swift)\n"
    guard let f = fopen(path, "w") else {
        eprint("fs-write: \(strerrorString(errno))")
        return 1
    }
    defer { fclose(f) }
    var written = 0
    var copy = content
    copy.withUTF8 { buf in
        if let p = buf.baseAddress {
            written = fwrite(p, 1, buf.count, f)
        }
    }
    print("wrote \(written) bytes to \(path)")
    return 0
}

func cmdFsRead(_ path: String) -> Int32 {
    guard let f = fopen(path, "r") else {
        eprint("fs-read: \(strerrorString(errno))")
        return 1
    }
    defer { fclose(f) }
    var buf = [UInt8](repeating: 0, count: 4096)
    var lastByte: UInt8 = 0
    var totalRead = 0
    while true {
        let n = buf.withUnsafeMutableBufferPointer { p -> Int in
            fread(p.baseAddress!, 1, p.count, f)
        }
        if n == 0 { break }
        buf.withUnsafeBufferPointer { p in
            writeStdout(p.baseAddress!, n)
        }
        lastByte = buf[n - 1]
        totalRead += n
    }
    if totalRead == 0 || lastByte != UInt8(ascii: "\n") {
        _ = fputs("\n", stdout)
    }
    return 0
}

func cmdFsEscape(_ path: String) -> Int32 {
    // We *expect* this to fail with EACCES from the sandbox.
    if let f = fopen(path, "r") {
        fclose(f)
        eprint("fs-escape: BUG: opened \(path) (sandbox not enforcing!)")
        return 1
    }
    print("fs-escape: open failed (as expected): \(strerrorString(errno))")
    return 0
}

func cmdTCPClient(_ host: String, _ port: UInt16) -> Int32 {
    var fd: Int32 = -1
    var e = rootshell_socket_socket(AF_INET, SOCK_STREAM, &fd)
    if e != 0 {
        eprint("socket: \(errnoName(e))")
        return 1
    }
    defer { _ = rootshell_socket_close(fd) }

    // Hostname or IP, both fine - connect_host hands the string straight
    // to Network.framework which does DNS internally.
    e = withUTF8(host) { ptr, len in
        rootshell_socket_connect_host(fd, ptr, len, UInt32(port))
    }
    if e != 0 {
        eprint("connect \(host):\(port): \(errnoName(e))")
        return 1
    }

    let req = "GET / HTTP/1.0\r\nHost: \(host)\r\n\r\n"
    var sent: UInt32 = 0
    e = withUTF8(req) { ptr, len in
        rootshell_socket_send(fd, ptr, len, &sent)
    }
    if e != 0 {
        eprint("send: \(errnoName(e))")
        return 1
    }
    print("tcp-client: sent \(sent) bytes")

    let maxPrint = 2048
    var total = 0
    var printed = 0
    var buf = [UInt8](repeating: 0, count: 4096)
    for _ in 0..<32 {
        var got: UInt32 = 0
        let r = buf.withUnsafeMutableBufferPointer { p in
            rootshell_socket_recv(fd, p.baseAddress!, Int32(p.count), &got)
        }
        if r != 0 {
            eprint("recv: \(errnoName(r))")
            return 1
        }
        if got == 0 {
            break
        }
        // Print up to maxPrint bytes total, even if a chunk straddles the
        // cap. Cap keeps output terminal-friendly when responses are huge.
        if printed < maxPrint {
            var want = Int(got)
            if printed + want > maxPrint {
                want = maxPrint - printed
            }
            buf.withUnsafeBufferPointer { p in
                writeStdout(p.baseAddress!, want)
            }
            printed += want
        }
        total += Int(got)
    }
    print("\ntcp-client: read \(total) bytes total")
    return 0
}

func cmdTLSClient(_ host: String, _ port: UInt16) -> Int32 {
    var fd: Int32 = -1
    var e = rootshell_socket_socket(AF_INET, SOCK_STREAM, &fd)
    if e != 0 {
        eprint("socket: \(errnoName(e))")
        return 1
    }
    defer { _ = rootshell_socket_close(fd) }

    // Build the TLS connection directly - no prior plain-TCP connect.
    // Network.framework handles SNI, DNS, and cert validation host-side.
    e = withUTF8(host) { ptr, len in
        rootshell_socket_tls_connect_host(fd, ptr, len, UInt32(port))
    }
    if e != 0 {
        eprint("tls_connect \(host):\(port): \(errnoName(e))")
        return 1
    }

    let req = "GET / HTTP/1.0\r\nHost: \(host)\r\n\r\n"
    var sent: UInt32 = 0
    e = withUTF8(req) { ptr, len in
        rootshell_socket_send(fd, ptr, len, &sent)
    }
    if e != 0 {
        eprint("send: \(errnoName(e))")
        return 1
    }
    print("tls-client: sent \(sent) bytes")

    let maxPrint = 2048
    var total = 0
    var printed = 0
    var buf = [UInt8](repeating: 0, count: 4096)
    for _ in 0..<64 {
        var got: UInt32 = 0
        let r = buf.withUnsafeMutableBufferPointer { p in
            rootshell_socket_recv(fd, p.baseAddress!, Int32(p.count), &got)
        }
        if r != 0 {
            eprint("recv: \(errnoName(r))")
            return 1
        }
        if got == 0 {
            break
        }
        if printed < maxPrint {
            var want = Int(got)
            if printed + want > maxPrint {
                want = maxPrint - printed
            }
            buf.withUnsafeBufferPointer { p in
                writeStdout(p.baseAddress!, want)
            }
            printed += want
        }
        total += Int(got)
    }
    print("\ntls-client: read \(total) bytes total")
    return 0
}

// Build a minimal DNS query packet, ship it over UDP to a public resolver,
// and parse the A-record reply. This exercises the full UDP path:
// sendto_host (which routes through Network.framework's DNS), then
// recvfrom which must return the resolver's reply with its source addr.
// Doing real DNS in the packet payload means we also verify that the host
// is sending exactly the bytes we asked it to (not just acking and dropping).
func cmdDNSQuery(_ name: String, _ resolver: String) -> Int32 {
    var fd: Int32 = -1
    var e = rootshell_socket_socket(AF_INET, SOCK_DGRAM, &fd)
    if e != 0 {
        eprint("socket: \(errnoName(e))")
        return 1
    }
    defer { _ = rootshell_socket_close(fd) }

    // ---- Build the query ----
    // Header: id=0x1234, flags=0x0100 (standard query, RD), 1 question.
    var pkt: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
    // QNAME: length-prefixed labels, terminated by a zero byte.
    for label in name.split(separator: ".", omittingEmptySubsequences: false) {
        let bytes = Array(label.utf8)
        if bytes.isEmpty || bytes.count > 63 {
            eprint("dns-query: invalid label in \(name)")
            return 1
        }
        pkt.append(UInt8(bytes.count))
        pkt.append(contentsOf: bytes)
    }
    pkt.append(0)
    // QTYPE=A (1), QCLASS=IN (1).
    pkt.append(contentsOf: [0, 1, 0, 1])

    var sent: UInt32 = 0
    e = pkt.withUnsafeBufferPointer { pktBuf in
        withUTF8(resolver) { rPtr, rLen in
            rootshell_socket_sendto_host(
                fd, pktBuf.baseAddress!, Int32(pktBuf.count),
                rPtr, rLen, 53, &sent
            )
        }
    }
    if e != 0 {
        eprint("sendto \(resolver):53: \(errnoName(e))")
        return 1
    }
    print("dns-query: sent \(sent) bytes to \(resolver):53 for \(name)")

    // ---- Receive the reply ----
    var buf = [UInt8](repeating: 0, count: 1500)
    var addrBuf = [UInt8](repeating: 0, count: 16)
    var alen: Int32 = Int32(addrBuf.count)
    var got: UInt32 = 0
    let r = buf.withUnsafeMutableBufferPointer { bufPtr in
        addrBuf.withUnsafeMutableBufferPointer { addrPtr in
            rootshell_socket_recvfrom(
                fd, bufPtr.baseAddress!, Int32(bufPtr.count),
                addrPtr.baseAddress!, &alen, &got
            )
        }
    }
    if r != 0 {
        eprint("recvfrom: \(errnoName(r))")
        return 1
    }

    let reply = Array(buf[0..<Int(got)])
    if reply.count < 12 {
        eprint("dns-query: short reply (\(reply.count) bytes)")
        return 1
    }
    // Confirm the resolver returned the source address we expect - proves
    // recvfrom is delivering peer info, not just zeroing the sockaddr.
    if alen >= 8 && addrBuf[0] == UInt8(AF_INET) {
        let port = (UInt16(addrBuf[2]) << 8) | UInt16(addrBuf[3])
        print("dns-query: reply from \(addrBuf[4]).\(addrBuf[5]).\(addrBuf[6]).\(addrBuf[7]):\(port) (\(got) bytes)")
    } else {
        print("dns-query: reply (\(got) bytes, source addr unavailable)")
    }

    // ---- Parse the header ----
    if reply[0] != 0x12 || reply[1] != 0x34 {
        eprint("dns-query: transaction id mismatch (\(hex2(reply[0]))\(hex2(reply[1])))")
        return 1
    }
    if reply[2] & 0x80 == 0 {
        eprint("dns-query: QR bit not set (not a response)")
        return 1
    }
    let rcode = reply[3] & 0x0f
    if rcode != 0 {
        eprint("dns-query: RCODE=\(rcode) (non-zero)")
        return 1
    }
    let qd = Int(reply[4]) << 8 | Int(reply[5])
    let an = Int(reply[6]) << 8 | Int(reply[7])
    print("dns-query: QDCOUNT=\(qd) ANCOUNT=\(an)")
    if an == 0 {
        eprint("dns-query: no answers")
        return 1
    }

    // Walk past the questions to land on the answer section.
    var off = 12
    for _ in 0..<qd {
        guard let next = skipName(reply, off) else {
            eprint("dns-query: malformed question name")
            return 1
        }
        off = next
        if off + 4 > reply.count {
            eprint("dns-query: truncated question")
            return 1
        }
        off += 4 // QTYPE + QCLASS
    }

    // Pull the first A record out of the answer section. Names here are
    // usually compressed pointers (0xC0xx), so skipName handles both.
    var foundA = false
    for _ in 0..<an {
        guard let next = skipName(reply, off) else {
            eprint("dns-query: malformed answer name")
            return 1
        }
        off = next
        if off + 10 > reply.count {
            eprint("dns-query: truncated RR")
            return 1
        }
        let rtype = UInt16(reply[off]) << 8 | UInt16(reply[off + 1])
        let rclass = UInt16(reply[off + 2]) << 8 | UInt16(reply[off + 3])
        let ttl = UInt32(reply[off + 4]) << 24 | UInt32(reply[off + 5]) << 16 |
                  UInt32(reply[off + 6]) << 8  | UInt32(reply[off + 7])
        let rdlen = Int(reply[off + 8]) << 8 | Int(reply[off + 9])
        off += 10
        if off + rdlen > reply.count {
            eprint("dns-query: truncated RDATA")
            return 1
        }
        if rtype == 1 && rclass == 1 && rdlen == 4 {
            print("dns-query: \(name) A \(reply[off]).\(reply[off+1]).\(reply[off+2]).\(reply[off+3]) (ttl \(ttl))")
            foundA = true
        }
        off += rdlen
    }
    if !foundA {
        eprint("dns-query: no A record in answers")
        return 1
    }
    return 0
}

// Walk a DNS-encoded name and return the offset of the first byte after it.
// Handles both label sequences (length-prefix + label, terminated by 0) and
// compression pointers (0b11xxxxxx). Pointers are not followed - they count
// as 2 bytes, which is all we need to advance past the name.
func skipName(_ buf: [UInt8], _ off: Int) -> Int? {
    var off = off
    while true {
        if off >= buf.count { return nil }
        let len = buf[off]
        if len == 0 {
            return off + 1
        }
        if len & 0xc0 == 0xc0 {
            if off + 2 > buf.count { return nil }
            return off + 2
        }
        if len & 0xc0 != 0 {
            return nil // reserved bits set, malformed
        }
        off += 1 + Int(len)
    }
}

func cmdTCPListen(_ port: UInt16) -> Int32 {
    var fd: Int32 = -1
    var e = rootshell_socket_socket(AF_INET, SOCK_STREAM, &fd)
    if e != 0 {
        eprint("socket: \(errnoName(e))")
        return 1
    }
    defer { _ = rootshell_socket_close(fd) }

    let sa = sockaddrIn("0.0.0.0", port: port)
    e = sa.withUnsafeBufferPointer { p in
        rootshell_socket_bind(fd, p.baseAddress!, Int32(p.count))
    }
    if e != 0 {
        eprint("bind: \(errnoName(e))")
        return 1
    }
    e = rootshell_socket_listen(fd, 16)
    if e != 0 {
        eprint("listen: \(errnoName(e))")
        return 1
    }
    print("tcp-listen: listening on port \(port)")

    var conn: Int32 = -1
    e = rootshell_socket_accept(fd, &conn)
    if e != 0 {
        eprint("accept: \(errnoName(e))")
        return 1
    }

    var buf = [UInt8](repeating: 0, count: 1024)
    var got: UInt32 = 0
    let r = buf.withUnsafeMutableBufferPointer { p in
        rootshell_socket_recv(conn, p.baseAddress!, Int32(p.count), &got)
    }
    if r != 0 {
        eprint("recv: \(errnoName(r))")
        _ = rootshell_socket_close(conn)
        return 1
    }
    let reply = "pong: echoed \(got) bytes\n"
    var sent: UInt32 = 0
    _ = withUTF8(reply) { ptr, len in
        rootshell_socket_send(conn, ptr, len, &sent)
    }
    _ = rootshell_socket_close(conn)
    print("tcp-listen: served one client, exiting")
    return 0
}

func cmdAll() -> Int32 {
    var acc: Int32 = 0
    print("=== hello ===")
    acc |= cmdHello(["wasm-demo", "all"])
    print("=== fs-write ===")
    acc |= cmdFsWrite("wasm-demo-all.txt")
    print("=== fs-read ===")
    acc |= cmdFsRead("wasm-demo-all.txt")
    print("=== fs-escape ===")
    acc |= cmdFsEscape("../../outside.txt")
    // The networking checks hit real internet hosts - running `all` is
    // also a quick way to confirm the device has working egress.
    // google.com on port 80 returns a 301 redirect to https, which is
    // still a valid HTTP response and exercises the plain-TCP path end
    // to end.
    print("=== dns-query ===")
    acc |= cmdDNSQuery("google.com", "1.1.1.1")
    print("=== tcp-client ===")
    acc |= cmdTCPClient("www.google.com", 80)
    print("=== tls-client ===")
    acc |= cmdTLSClient("google.com", 443)
    if acc == 0 {
        print("all: PASS")
    } else {
        print("all: FAIL (composite=\(acc))")
    }
    return acc
}
