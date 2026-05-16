// Thin Go bindings over the `rootshell_socket_*` and `rootshell_terminal_*`
// ABIs exposed by the host. Imports use `//go:wasmimport <module> <name>`
// so they bind to the right namespace; the matching Rust shim relies on
// the host's `env` fallback, but we name the modules explicitly.
//
// All ints are i32; pointers are `unsafe.Pointer` (linear-memory offsets).
// Sockaddr layout matches BSD `sockaddr_in` / `sockaddr_in6` byte-for-byte.

package main

import (
	"strconv"
	"strings"
	"unsafe"
)

const (
	AF_INET     int32 = 2
	AF_INET6    int32 = 30
	SOCK_STREAM int32 = 1
	SOCK_DGRAM  int32 = 2
)

//go:wasmimport rootshell_socket rootshell_socket_socket
//go:noescape
func socketSocket(domain int32, typ int32, fdOut unsafe.Pointer) int32

//go:wasmimport rootshell_socket rootshell_socket_bind
//go:noescape
func socketBind(fd int32, addr unsafe.Pointer, addrLen int32) int32

//go:wasmimport rootshell_socket rootshell_socket_listen
func socketListen(fd int32, backlog int32) int32

//go:wasmimport rootshell_socket rootshell_socket_accept
//go:noescape
func socketAccept(fd int32, fdOut unsafe.Pointer) int32

//go:wasmimport rootshell_socket rootshell_socket_connect
//go:noescape
func socketConnect(fd int32, addr unsafe.Pointer, addrLen int32) int32

//go:wasmimport rootshell_socket rootshell_socket_send
//go:noescape
func socketSend(fd int32, buf unsafe.Pointer, length int32, sentOut unsafe.Pointer) int32

//go:wasmimport rootshell_socket rootshell_socket_recv
//go:noescape
func socketRecv(fd int32, buf unsafe.Pointer, length int32, recvOut unsafe.Pointer) int32

//go:wasmimport rootshell_socket rootshell_socket_sendto
//go:noescape
func socketSendto(fd int32, buf unsafe.Pointer, length int32, addr unsafe.Pointer, addrLen int32, sentOut unsafe.Pointer) int32

//go:wasmimport rootshell_socket rootshell_socket_recvfrom
//go:noescape
func socketRecvfrom(fd int32, buf unsafe.Pointer, length int32, addr unsafe.Pointer, addrLenIO unsafe.Pointer, recvOut unsafe.Pointer) int32

//go:wasmimport rootshell_socket rootshell_socket_shutdown
func socketShutdown(fd int32, how int32) int32

//go:wasmimport rootshell_socket rootshell_socket_close
func socketClose(fd int32) int32

//go:wasmimport rootshell_socket rootshell_socket_connect_host
//go:noescape
func socketConnectHost(fd int32, host unsafe.Pointer, hostLen int32, port uint32) int32

// TLS-on-TCP: handshake + cert validation happen host-side via
// Network.framework. After this returns 0, regular send/recv work on
// the plaintext stream. No prior connect call is needed — this builds
// the underlying connection from scratch with TLS parameters.
//
//go:wasmimport rootshell_socket rootshell_socket_tls_connect_host
//go:noescape
func socketTLSConnectHost(fd int32, host unsafe.Pointer, hostLen int32, port uint32) int32

//go:wasmimport rootshell_socket rootshell_socket_bind_host
//go:noescape
func socketBindHost(fd int32, host unsafe.Pointer, hostLen int32, port uint32) int32

//go:wasmimport rootshell_socket rootshell_socket_sendto_host
//go:noescape
func socketSendtoHost(fd int32, buf unsafe.Pointer, length int32, host unsafe.Pointer, hostLen int32, port uint32, sentOut unsafe.Pointer) int32

//go:wasmimport rootshell_socket rootshell_socket_resolve_v4
//go:noescape
func socketResolveV4(host unsafe.Pointer, hostLen int32, outBuf unsafe.Pointer, outMax int32, countOut unsafe.Pointer) int32

//go:wasmimport rootshell_socket rootshell_socket_resolve_v6
//go:noescape
func socketResolveV6(host unsafe.Pointer, hostLen int32, outBuf unsafe.Pointer, outMax int32, countOut unsafe.Pointer) int32

//go:wasmimport rootshell_terminal rootshell_terminal_set_raw
func terminalSetRaw(enabled int32) int32

//go:wasmimport rootshell_terminal rootshell_terminal_is_tty
func terminalIsTTY(fd int32) int32

// Note: `port` is uint32 in the wasmimport signature because Go's
// wasmimport rejects narrow integer types like uint16. The host JS
// already truncates to 16 bits.

// Build a 16-byte AF_INET sockaddr_in. `host` must be a literal
// dotted-quad — anything else returns an addr with 0.0.0.0.
func sockaddrIn(host string, port uint16) [16]byte {
	var out [16]byte
	out[0] = byte(AF_INET)
	out[1] = 0
	out[2] = byte(port >> 8)
	out[3] = byte(port & 0xff)
	parts := strings.Split(host, ".")
	for i := 0; i < 4 && i < len(parts); i++ {
		v, err := strconv.ParseUint(parts[i], 10, 8)
		if err != nil {
			out[4+i] = 0
			continue
		}
		out[4+i] = byte(v)
	}
	return out
}

func errnoName(e int32) string {
	switch e {
	case 0:
		return "OK"
	case 2:
		return "EACCES"
	case 8:
		return "EBADF"
	case 14:
		return "ECONNREFUSED"
	case 27:
		return "EINTR"
	case 28:
		return "EINVAL"
	case 50:
		return "ENETUNREACH"
	case 73:
		return "ETIMEDOUT"
	default:
		return "errno"
	}
}

// stringPtr returns a stable pointer to the bytes of s for the duration
// of one host call. The host copies the bytes synchronously before
// returning (Atomics.wait round-trip), so this is safe.
func stringPtr(s string) unsafe.Pointer {
	if len(s) == 0 {
		return nil
	}
	b := unsafe.StringData(s)
	return unsafe.Pointer(b)
}

// bytesPtr returns a pointer to the first byte of b. The host call must
// be synchronous (true for every rootshell_socket_* import).
func bytesPtr(b []byte) unsafe.Pointer {
	if len(b) == 0 {
		return nil
	}
	return unsafe.Pointer(&b[0])
}
