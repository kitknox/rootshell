// Thin Rust bindings over the `rootshell_socket_*` ABI exposed by the host.
// Every function maps 1:1 to a BSD-style call. All ints are i32, all pointers
// are u32 in WASM linear memory. Sockaddr layout is identical to BSD
// `sockaddr_in` / `sockaddr_in6`.

#![allow(dead_code)]

pub const AF_INET: i32 = 2;
pub const AF_INET6: i32 = 30;
pub const SOCK_STREAM: i32 = 1;
pub const SOCK_DGRAM: i32 = 2;

unsafe extern "C" {
    pub unsafe fn rootshell_socket_socket(domain: i32, type_: i32, fd_out: *mut i32) -> i32;
    pub unsafe fn rootshell_socket_bind(fd: i32, addr: *const u8, addrlen: i32) -> i32;
    pub unsafe fn rootshell_socket_listen(fd: i32, backlog: i32) -> i32;
    pub unsafe fn rootshell_socket_accept(fd: i32, fd_out: *mut i32) -> i32;
    pub unsafe fn rootshell_socket_connect(fd: i32, addr: *const u8, addrlen: i32) -> i32;
    pub unsafe fn rootshell_socket_send(fd: i32, buf: *const u8, len: i32, sent_out: *mut u32) -> i32;
    pub unsafe fn rootshell_socket_recv(fd: i32, buf: *mut u8, len: i32, recv_out: *mut u32) -> i32;
    pub unsafe fn rootshell_socket_sendto(
        fd: i32,
        buf: *const u8,
        len: i32,
        addr: *const u8,
        addrlen: i32,
        sent_out: *mut u32,
    ) -> i32;
    pub unsafe fn rootshell_socket_recvfrom(
        fd: i32,
        buf: *mut u8,
        len: i32,
        addr: *mut u8,
        addrlen_io: *mut i32,
        recv_out: *mut u32,
    ) -> i32;
    pub unsafe fn rootshell_socket_shutdown(fd: i32, how: i32) -> i32;
    pub unsafe fn rootshell_socket_close(fd: i32) -> i32;

    // -------- Hostname-friendly variants (no sockaddr round-trip) --------
    pub unsafe fn rootshell_socket_connect_host(
        fd: i32, host: *const u8, host_len: i32, port: u16,
    ) -> i32;
    // TLS-on-TCP: handshake + cert validation happen host-side via
    // Network.framework. After this returns 0, regular send/recv work on
    // the plaintext stream. No prior connect call is needed — this builds
    // the underlying connection from scratch with TLS parameters.
    pub unsafe fn rootshell_socket_tls_connect_host(
        fd: i32, host: *const u8, host_len: i32, port: u16,
    ) -> i32;
    pub unsafe fn rootshell_socket_bind_host(
        fd: i32, host: *const u8, host_len: i32, port: u16,
    ) -> i32;
    pub unsafe fn rootshell_socket_sendto_host(
        fd: i32,
        buf: *const u8, len: i32,
        host: *const u8, host_len: i32, port: u16,
        sent_out: *mut u32,
    ) -> i32;
    pub unsafe fn rootshell_socket_resolve_v4(
        host: *const u8, host_len: i32,
        out_buf: *mut u8, out_max: i32,
        count_out: *mut u32,
    ) -> i32;
    pub unsafe fn rootshell_socket_resolve_v6(
        host: *const u8, host_len: i32,
        out_buf: *mut u8, out_max: i32,
        count_out: *mut u32,
    ) -> i32;
}

// -------- Terminal (raw / cooked input mode) --------
unsafe extern "C" {
    pub unsafe fn rootshell_terminal_set_raw(enabled: i32) -> i32;
    pub unsafe fn rootshell_terminal_is_tty(fd: i32) -> i32;
}

/// Build a 16-byte AF_INET sockaddr_in. `host` must be a literal dotted-quad.
pub fn sockaddr_in(host: &str, port: u16) -> [u8; 16] {
    let mut out = [0u8; 16];
    out[0] = AF_INET as u8;
    out[1] = 0;
    out[2] = (port >> 8) as u8;
    out[3] = (port & 0xff) as u8;
    let mut parts = host.split('.');
    for i in 4..8 {
        out[i] = parts.next().and_then(|s| s.parse::<u8>().ok()).unwrap_or(0);
    }
    out
}

pub fn errno_name(e: i32) -> &'static str {
    match e {
        0 => "OK",
        2 => "EACCES",
        14 => "ECONNREFUSED",
        50 => "ENETUNREACH",
        73 => "ETIMEDOUT",
        27 => "EINTR",
        28 => "EINVAL",
        8 => "EBADF",
        _ => "errno",
    }
}
