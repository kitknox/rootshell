// Demo WASM binary for the rootshell iOS local shell WASM runtime. Built with
// `cargo build --target wasm32-wasip1 --release` (see build.sh). Each
// subcommand exercises one slice of the runtime + sandbox surface:
//
//   hello                 — args, env, stdout, exit
//   fs-write <path>       — sandboxed write
//   fs-read  <path>       — sandboxed read
//   fs-escape <path>      — should be rejected by the sandbox (negative)
//   tcp-client <h> <p>    — connect, send HTTP/1.0 GET, dump response
//   tls-client <h> <p>    — TLS variant of tcp-client, hits HTTPS hosts
//   dns-query <name> [resolver] — hand-rolled DNS/A query over UDP
//   tcp-listen <port>     — bind/listen/accept, echo one line, exit
//   all                   — runs every self-contained subcommand, plus
//                           dns-query and tls-client against real internet
//                           hosts. tcp-client/tcp-listen need a peer to be
//                           useful, so they're driven by the in-app
//                           `wasm test` runner (which spins up loopback
//                           servers), not by this battery.

mod socket_shim;
use socket_shim::*;

use std::env;
use std::fs;
use std::io::{Read, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let sub = args.get(1).map(String::as_str).unwrap_or("hello");

    let code = match sub {
        "hello" => cmd_hello(&args),
        // Relative paths land in the cwd the .wasm was launched from, so
        // the user can see the artifact appear next to the binary in Files.
        "fs-write" => cmd_fs_write(args.get(2).map(String::as_str).unwrap_or("wasm-demo.txt")),
        "fs-read" => cmd_fs_read(args.get(2).map(String::as_str).unwrap_or("wasm-demo.txt")),
        // The sandbox clamps `..` traversal — this is a negative test that
        // we expect to fail with EACCES.
        "fs-escape" => cmd_fs_escape(args.get(2).map(String::as_str).unwrap_or("../../outside.txt")),
        "tcp-client" => cmd_tcp_client(
            args.get(2).map(String::as_str).unwrap_or("127.0.0.1"),
            args.get(3).and_then(|s| s.parse().ok()).unwrap_or(80),
        ),
        "tls-client" => cmd_tls_client(
            args.get(2).map(String::as_str).unwrap_or("google.com"),
            args.get(3).and_then(|s| s.parse().ok()).unwrap_or(443),
        ),
        "dns-query" => cmd_dns_query(
            args.get(2).map(String::as_str).unwrap_or("google.com"),
            args.get(3).map(String::as_str).unwrap_or("1.1.1.1"),
        ),
        "tcp-listen" => cmd_tcp_listen(args.get(2).and_then(|s| s.parse().ok()).unwrap_or(0)),
        "all" => cmd_all(),
        other => {
            println!("wasm-demo: unknown subcommand {}", other);
            1
        }
    };

    if code == 0 { ExitCode::SUCCESS } else { ExitCode::from(code as u8) }
}

fn cmd_hello(args: &[String]) -> i32 {
    println!("hello from wasm-demo");
    println!("argv = {:?}", args);
    if let Ok(h) = env::var("HOME") {
        println!("HOME = {}", h);
    }
    if let Ok(p) = env::var("PWD") {
        println!("PWD = {}", p);
    }
    0
}

fn cmd_fs_write(path: &str) -> i32 {
    let content = b"hello, wasm fs\n";
    match fs::File::create(path) {
        Ok(mut f) => match f.write_all(content) {
            Ok(_) => {
                println!("wrote {} bytes to {}", content.len(), path);
                0
            }
            Err(e) => {
                eprintln!("fs-write: {}", e);
                1
            }
        },
        Err(e) => {
            eprintln!("fs-write: open: {}", e);
            1
        }
    }
}

fn cmd_fs_read(path: &str) -> i32 {
    match fs::File::open(path) {
        Ok(mut f) => {
            let mut s = String::new();
            match f.read_to_string(&mut s) {
                Ok(_) => {
                    print!("{}", s);
                    if !s.ends_with('\n') {
                        println!();
                    }
                    0
                }
                Err(e) => {
                    eprintln!("fs-read: read: {}", e);
                    1
                }
            }
        }
        Err(e) => {
            eprintln!("fs-read: open: {}", e);
            1
        }
    }
}

fn cmd_fs_escape(path: &str) -> i32 {
    // We *expect* this to fail with EACCES from the sandbox.
    match fs::File::open(path) {
        Ok(_) => {
            eprintln!("fs-escape: BUG: opened {} (sandbox not enforcing!)", path);
            1
        }
        Err(e) => {
            println!("fs-escape: open failed (as expected): {}", e);
            0
        }
    }
}

fn cmd_tcp_client(host: &str, port: u16) -> i32 {
    unsafe {
        let mut fd: i32 = -1;
        let e = rootshell_socket_socket(AF_INET, SOCK_STREAM, &mut fd);
        if e != 0 {
            eprintln!("socket: {}", errno_name(e));
            return 1;
        }

        // Hostname or IP, both fine — connect_host hands the string straight
        // to Network.framework which does DNS internally.
        let e = rootshell_socket_connect_host(fd, host.as_ptr(), host.len() as i32, port);
        if e != 0 {
            eprintln!("connect {}:{}: {}", host, port, errno_name(e));
            return 1;
        }

        let req = format!("GET / HTTP/1.0\r\nHost: {}\r\n\r\n", host);
        let mut sent: u32 = 0;
        let e = rootshell_socket_send(fd, req.as_ptr(), req.len() as i32, &mut sent);
        if e != 0 {
            eprintln!("send: {}", errno_name(e));
            return 1;
        }
        println!("tcp-client: sent {} bytes", sent);

        const MAX_PRINT: usize = 2048;
        let mut total = 0usize;
        let mut printed = 0usize;
        let mut buf = [0u8; 4096];
        for _ in 0..32 {
            let mut got: u32 = 0;
            let e = rootshell_socket_recv(fd, buf.as_mut_ptr(), buf.len() as i32, &mut got);
            if e != 0 {
                eprintln!("recv: {}", errno_name(e));
                rootshell_socket_close(fd);
                return 1;
            }
            if got == 0 {
                break;
            }
            // Print up to MAX_PRINT bytes total, even if a single chunk
            // straddles the cap. Cap keeps output terminal-friendly when
            // the response runs to many KB.
            if printed < MAX_PRINT {
                let want = std::cmp::min(got as usize, MAX_PRINT - printed);
                if let Ok(s) = std::str::from_utf8(&buf[..want]) {
                    print!("{}", s);
                    printed += want;
                }
            }
            total += got as usize;
        }
        println!("\ntcp-client: read {} bytes total", total);
        rootshell_socket_close(fd);
        0
    }
}

fn cmd_tls_client(host: &str, port: u16) -> i32 {
    unsafe {
        let mut fd: i32 = -1;
        let e = rootshell_socket_socket(AF_INET, SOCK_STREAM, &mut fd);
        if e != 0 {
            eprintln!("socket: {}", errno_name(e));
            return 1;
        }

        // Build the TLS connection directly — no prior plain-TCP connect.
        // Network.framework handles SNI, DNS, and cert validation host-side.
        let e =
            rootshell_socket_tls_connect_host(fd, host.as_ptr(), host.len() as i32, port);
        if e != 0 {
            eprintln!("tls_connect {}:{}: {}", host, port, errno_name(e));
            rootshell_socket_close(fd);
            return 1;
        }

        let req = format!("GET / HTTP/1.0\r\nHost: {}\r\n\r\n", host);
        let mut sent: u32 = 0;
        let e = rootshell_socket_send(fd, req.as_ptr(), req.len() as i32, &mut sent);
        if e != 0 {
            eprintln!("send: {}", errno_name(e));
            rootshell_socket_close(fd);
            return 1;
        }
        println!("tls-client: sent {} bytes", sent);

        const MAX_PRINT: usize = 2048;
        let mut total = 0usize;
        let mut printed = 0usize;
        let mut buf = [0u8; 4096];
        for _ in 0..64 {
            let mut got: u32 = 0;
            let e = rootshell_socket_recv(fd, buf.as_mut_ptr(), buf.len() as i32, &mut got);
            if e != 0 {
                eprintln!("recv: {}", errno_name(e));
                rootshell_socket_close(fd);
                return 1;
            }
            if got == 0 {
                break;
            }
            if printed < MAX_PRINT {
                let want = std::cmp::min(got as usize, MAX_PRINT - printed);
                if let Ok(s) = std::str::from_utf8(&buf[..want]) {
                    print!("{}", s);
                    printed += want;
                }
            }
            total += got as usize;
        }
        println!("\ntls-client: read {} bytes total", total);
        rootshell_socket_close(fd);
        0
    }
}

// Build a minimal DNS query packet, ship it over UDP to a public resolver,
// and parse the A-record reply. This exercises the full UDP path:
// sendto_host (which routes through Network.framework's DNS), then
// recvfrom which must return the resolver's reply with its source addr.
// Doing real DNS in the packet payload means we also verify that the host
// is sending exactly the bytes we asked it to (not just acking and dropping).
fn cmd_dns_query(name: &str, resolver: &str) -> i32 {
    unsafe {
        let mut fd: i32 = -1;
        let e = rootshell_socket_socket(AF_INET, SOCK_DGRAM, &mut fd);
        if e != 0 {
            eprintln!("socket: {}", errno_name(e));
            return 1;
        }

        // ---- Build the query ----
        // Header: id=0x1234, flags=0x0100 (standard query, RD), 1 question.
        let mut pkt: Vec<u8> = Vec::with_capacity(64);
        pkt.extend_from_slice(&[0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
        // QNAME: length-prefixed labels, terminated by a zero byte.
        for label in name.split('.') {
            if label.is_empty() || label.len() > 63 {
                eprintln!("dns-query: invalid label in {}", name);
                rootshell_socket_close(fd);
                return 1;
            }
            pkt.push(label.len() as u8);
            pkt.extend_from_slice(label.as_bytes());
        }
        pkt.push(0);
        // QTYPE=A (1), QCLASS=IN (1).
        pkt.extend_from_slice(&[0, 1, 0, 1]);

        let mut sent: u32 = 0;
        let e = rootshell_socket_sendto_host(
            fd,
            pkt.as_ptr(), pkt.len() as i32,
            resolver.as_ptr(), resolver.len() as i32, 53,
            &mut sent,
        );
        if e != 0 {
            eprintln!("sendto {}:53: {}", resolver, errno_name(e));
            rootshell_socket_close(fd);
            return 1;
        }
        println!("dns-query: sent {} bytes to {}:53 for {}", sent, resolver, name);

        // ---- Receive the reply ----
        let mut buf = [0u8; 1500];
        let mut got: u32 = 0;
        let mut addr_buf = [0u8; 16];
        let mut alen: i32 = addr_buf.len() as i32;
        let e = rootshell_socket_recvfrom(
            fd, buf.as_mut_ptr(), buf.len() as i32,
            addr_buf.as_mut_ptr(), &mut alen, &mut got,
        );
        if e != 0 {
            eprintln!("recvfrom: {}", errno_name(e));
            rootshell_socket_close(fd);
            return 1;
        }
        rootshell_socket_close(fd);

        let reply = &buf[..got as usize];
        if reply.len() < 12 {
            eprintln!("dns-query: short reply ({} bytes)", reply.len());
            return 1;
        }
        // Confirm the resolver returned the source-address we expect — proves
        // recvfrom is delivering peer info, not just zeroing the sockaddr.
        if alen >= 8 && addr_buf[0] == AF_INET as u8 {
            let port = ((addr_buf[2] as u16) << 8) | addr_buf[3] as u16;
            println!(
                "dns-query: reply from {}.{}.{}.{}:{} ({} bytes)",
                addr_buf[4], addr_buf[5], addr_buf[6], addr_buf[7], port, got,
            );
        } else {
            println!("dns-query: reply ({} bytes, source addr unavailable)", got);
        }

        // ---- Parse the header ----
        if reply[0] != 0x12 || reply[1] != 0x34 {
            eprintln!("dns-query: transaction id mismatch ({:02x}{:02x})", reply[0], reply[1]);
            return 1;
        }
        if reply[2] & 0x80 == 0 {
            eprintln!("dns-query: QR bit not set (not a response)");
            return 1;
        }
        let rcode = reply[3] & 0x0f;
        if rcode != 0 {
            eprintln!("dns-query: RCODE={} (non-zero)", rcode);
            return 1;
        }
        let qd = u16::from_be_bytes([reply[4], reply[5]]) as usize;
        let an = u16::from_be_bytes([reply[6], reply[7]]) as usize;
        println!("dns-query: QDCOUNT={} ANCOUNT={}", qd, an);
        if an == 0 {
            eprintln!("dns-query: no answers");
            return 1;
        }

        // Walk past the questions to land on the answer section.
        let mut off = 12usize;
        for _ in 0..qd {
            off = match skip_name(reply, off) {
                Some(v) => v,
                None => {
                    eprintln!("dns-query: malformed question name");
                    return 1;
                }
            };
            if off + 4 > reply.len() { eprintln!("dns-query: truncated question"); return 1; }
            off += 4; // QTYPE + QCLASS
        }

        // Pull the first A record out of the answer section. Names here are
        // usually compressed pointers (0xC0xx), so skip_name handles both.
        let mut found_a = false;
        for _ in 0..an {
            off = match skip_name(reply, off) {
                Some(v) => v,
                None => {
                    eprintln!("dns-query: malformed answer name");
                    return 1;
                }
            };
            if off + 10 > reply.len() { eprintln!("dns-query: truncated RR"); return 1; }
            let rtype = u16::from_be_bytes([reply[off], reply[off + 1]]);
            let rclass = u16::from_be_bytes([reply[off + 2], reply[off + 3]]);
            let ttl = u32::from_be_bytes([
                reply[off + 4], reply[off + 5], reply[off + 6], reply[off + 7],
            ]);
            let rdlen = u16::from_be_bytes([reply[off + 8], reply[off + 9]]) as usize;
            off += 10;
            if off + rdlen > reply.len() { eprintln!("dns-query: truncated RDATA"); return 1; }
            if rtype == 1 && rclass == 1 && rdlen == 4 {
                println!(
                    "dns-query: {} A {}.{}.{}.{} (ttl {})",
                    name,
                    reply[off], reply[off + 1], reply[off + 2], reply[off + 3], ttl,
                );
                found_a = true;
            }
            off += rdlen;
        }
        if !found_a {
            eprintln!("dns-query: no A record in answers");
            return 1;
        }
        0
    }
}

// Walk a DNS-encoded name and return the offset of the first byte after it.
// Handles both label sequences (length-prefix + label, terminated by 0) and
// compression pointers (0b11xxxxxx). Pointers are not followed — they count
// as 2 bytes, which is all we need to advance past the name.
fn skip_name(buf: &[u8], mut off: usize) -> Option<usize> {
    loop {
        if off >= buf.len() { return None; }
        let len = buf[off];
        if len == 0 {
            return Some(off + 1);
        }
        if len & 0xc0 == 0xc0 {
            // Two-byte compression pointer.
            if off + 2 > buf.len() { return None; }
            return Some(off + 2);
        }
        if len & 0xc0 != 0 { return None; } // reserved bits set, malformed
        off += 1 + len as usize;
    }
}

fn cmd_tcp_listen(port: u16) -> i32 {
    unsafe {
        let mut fd: i32 = -1;
        let e = rootshell_socket_socket(AF_INET, SOCK_STREAM, &mut fd);
        if e != 0 {
            eprintln!("socket: {}", errno_name(e));
            return 1;
        }
        let sa = sockaddr_in("0.0.0.0", port);
        let e = rootshell_socket_bind(fd, sa.as_ptr(), sa.len() as i32);
        if e != 0 {
            eprintln!("bind: {}", errno_name(e));
            return 1;
        }
        let e = rootshell_socket_listen(fd, 16);
        if e != 0 {
            eprintln!("listen: {}", errno_name(e));
            return 1;
        }
        println!("tcp-listen: listening on port {}", port);

        let mut conn: i32 = -1;
        let e = rootshell_socket_accept(fd, &mut conn);
        if e != 0 {
            eprintln!("accept: {}", errno_name(e));
            return 1;
        }

        let mut buf = [0u8; 1024];
        let mut got: u32 = 0;
        let e = rootshell_socket_recv(conn, buf.as_mut_ptr(), buf.len() as i32, &mut got);
        if e != 0 {
            eprintln!("recv: {}", errno_name(e));
            return 1;
        }
        let reply = format!("pong: echoed {} bytes\n", got);
        let mut sent: u32 = 0;
        rootshell_socket_send(conn, reply.as_ptr(), reply.len() as i32, &mut sent);
        rootshell_socket_close(conn);
        rootshell_socket_close(fd);
        println!("tcp-listen: served one client, exiting");
        0
    }
}

fn cmd_all() -> i32 {
    let mut acc = 0;
    println!("=== hello ===");
    acc |= cmd_hello(&vec!["wasm-demo".to_string(), "all".to_string()]);
    println!("=== fs-write ===");
    acc |= cmd_fs_write("wasm-demo-all.txt");
    println!("=== fs-read ===");
    acc |= cmd_fs_read("wasm-demo-all.txt");
    println!("=== fs-escape ===");
    acc |= cmd_fs_escape("../../outside.txt");
    // The networking checks hit real internet hosts — running `all` is
    // also a quick way to confirm the device has working egress. google.com
    // on port 80 returns a 301 redirect to https, which is still a valid
    // HTTP response and exercises the plain-TCP path end to end.
    println!("=== dns-query ===");
    acc |= cmd_dns_query("google.com", "1.1.1.1");
    println!("=== tcp-client ===");
    acc |= cmd_tcp_client("www.google.com", 80);
    println!("=== tls-client ===");
    acc |= cmd_tls_client("google.com", 443);
    if acc == 0 {
        println!("all: PASS");
    } else {
        println!("all: FAIL (composite={})", acc);
    }
    acc
}
