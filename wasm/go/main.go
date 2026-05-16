// Demo WASM binary for the rootshell iOS local shell WASM runtime, Go edition.
// Built with `GOOS=wasip1 GOARCH=wasm go build` (or TinyGo — see
// build.sh). Each subcommand mirrors the Rust wasm-demo and exercises
// one slice of the runtime + sandbox surface:
//
//	hello                       — args, env, stdout, exit
//	fs-write <path>             — sandboxed write
//	fs-read  <path>             — sandboxed read
//	fs-escape <path>            — should be rejected by the sandbox (negative)
//	tcp-client <h> <p>          — connect, send HTTP/1.0 GET, dump response
//	tls-client <h> <p>          — TLS variant of tcp-client, hits HTTPS hosts
//	dns-query <name> [resolver] — hand-rolled DNS/A query over UDP
//	tcp-listen <port>           — bind/listen/accept, echo one line, exit
//	all                         — runs every self-contained subcommand,
//	                              plus dns-query / tcp-client / tls-client
//	                              against real internet hosts. tcp-listen
//	                              needs a peer, so it's driven by the in-app
//	                              `wasm test` runner (which spins up loopback
//	                              servers), not by this battery.

package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"unsafe"
)

func main() {
	args := os.Args
	sub := "hello"
	if len(args) > 1 {
		sub = args[1]
	}

	var code int
	switch sub {
	case "hello":
		code = cmdHello(args)
	// Relative paths land in the cwd the .wasm was launched from, so
	// the user can see the artifact appear next to the binary in Files.
	case "fs-write":
		code = cmdFsWrite(argOr(args, 2, "wasm-demo.txt"))
	case "fs-read":
		code = cmdFsRead(argOr(args, 2, "wasm-demo.txt"))
	// The sandbox clamps `..` traversal — this is a negative test that
	// we expect to fail with EACCES.
	case "fs-escape":
		code = cmdFsEscape(argOr(args, 2, "../../outside.txt"))
	case "tcp-client":
		code = cmdTCPClient(argOr(args, 2, "127.0.0.1"), parsePort(argOr(args, 3, "80")))
	case "tls-client":
		code = cmdTLSClient(argOr(args, 2, "google.com"), parsePort(argOr(args, 3, "443")))
	case "dns-query":
		code = cmdDNSQuery(argOr(args, 2, "google.com"), argOr(args, 3, "1.1.1.1"))
	case "tcp-listen":
		code = cmdTCPListen(parsePort(argOr(args, 2, "0")))
	case "all":
		code = cmdAll()
	default:
		fmt.Printf("wasm-demo: unknown subcommand %s\n", sub)
		code = 1
	}
	os.Exit(code)
}

func argOr(args []string, i int, def string) string {
	if i < len(args) {
		return args[i]
	}
	return def
}

func parsePort(s string) uint16 {
	v, err := strconv.ParseUint(s, 10, 16)
	if err != nil {
		return 0
	}
	return uint16(v)
}

func cmdHello(args []string) int {
	fmt.Println("hello from wasm-demo (go)")
	fmt.Printf("argv = %q\n", args)
	if h := os.Getenv("HOME"); h != "" {
		fmt.Println("HOME =", h)
	}
	if p := os.Getenv("PWD"); p != "" {
		fmt.Println("PWD =", p)
	}
	return 0
}

func cmdFsWrite(path string) int {
	content := []byte("hello, wasm fs (go)\n")
	if err := os.WriteFile(path, content, 0644); err != nil {
		fmt.Fprintln(os.Stderr, "fs-write:", err)
		return 1
	}
	fmt.Printf("wrote %d bytes to %s\n", len(content), path)
	return 0
}

func cmdFsRead(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fs-read:", err)
		return 1
	}
	os.Stdout.Write(data)
	if len(data) == 0 || data[len(data)-1] != '\n' {
		fmt.Println()
	}
	return 0
}

func cmdFsEscape(path string) int {
	// We *expect* this to fail with EACCES from the sandbox.
	if _, err := os.Open(path); err != nil {
		fmt.Println("fs-escape: open failed (as expected):", err)
		return 0
	}
	fmt.Fprintf(os.Stderr, "fs-escape: BUG: opened %s (sandbox not enforcing!)\n", path)
	return 1
}

func cmdTCPClient(host string, port uint16) int {
	var fd int32 = -1
	if e := socketSocket(AF_INET, SOCK_STREAM, unsafe.Pointer(&fd)); e != 0 {
		fmt.Fprintln(os.Stderr, "socket:", errnoName(e))
		return 1
	}
	defer socketClose(fd)

	// Hostname or IP, both fine — connect_host hands the string straight
	// to Network.framework which does DNS internally.
	if e := socketConnectHost(fd, stringPtr(host), int32(len(host)), uint32(port)); e != 0 {
		fmt.Fprintf(os.Stderr, "connect %s:%d: %s\n", host, port, errnoName(e))
		return 1
	}

	req := fmt.Sprintf("GET / HTTP/1.0\r\nHost: %s\r\n\r\n", host)
	var sent uint32
	if e := socketSend(fd, stringPtr(req), int32(len(req)), unsafe.Pointer(&sent)); e != 0 {
		fmt.Fprintln(os.Stderr, "send:", errnoName(e))
		return 1
	}
	fmt.Printf("tcp-client: sent %d bytes\n", sent)

	const maxPrint = 2048
	total := 0
	printed := 0
	buf := make([]byte, 4096)
	for i := 0; i < 32; i++ {
		var got uint32
		if e := socketRecv(fd, bytesPtr(buf), int32(len(buf)), unsafe.Pointer(&got)); e != 0 {
			fmt.Fprintln(os.Stderr, "recv:", errnoName(e))
			return 1
		}
		if got == 0 {
			break
		}
		// Print up to maxPrint bytes total, even if a chunk straddles the
		// cap. Cap keeps output terminal-friendly when responses are huge.
		if printed < maxPrint {
			want := int(got)
			if printed+want > maxPrint {
				want = maxPrint - printed
			}
			os.Stdout.Write(buf[:want])
			printed += want
		}
		total += int(got)
	}
	fmt.Printf("\ntcp-client: read %d bytes total\n", total)
	return 0
}

func cmdTLSClient(host string, port uint16) int {
	var fd int32 = -1
	if e := socketSocket(AF_INET, SOCK_STREAM, unsafe.Pointer(&fd)); e != 0 {
		fmt.Fprintln(os.Stderr, "socket:", errnoName(e))
		return 1
	}
	defer socketClose(fd)

	// Build the TLS connection directly — no prior plain-TCP connect.
	// Network.framework handles SNI, DNS, and cert validation host-side.
	if e := socketTLSConnectHost(fd, stringPtr(host), int32(len(host)), uint32(port)); e != 0 {
		fmt.Fprintf(os.Stderr, "tls_connect %s:%d: %s\n", host, port, errnoName(e))
		return 1
	}

	req := fmt.Sprintf("GET / HTTP/1.0\r\nHost: %s\r\n\r\n", host)
	var sent uint32
	if e := socketSend(fd, stringPtr(req), int32(len(req)), unsafe.Pointer(&sent)); e != 0 {
		fmt.Fprintln(os.Stderr, "send:", errnoName(e))
		return 1
	}
	fmt.Printf("tls-client: sent %d bytes\n", sent)

	const maxPrint = 2048
	total := 0
	printed := 0
	buf := make([]byte, 4096)
	for i := 0; i < 64; i++ {
		var got uint32
		if e := socketRecv(fd, bytesPtr(buf), int32(len(buf)), unsafe.Pointer(&got)); e != 0 {
			fmt.Fprintln(os.Stderr, "recv:", errnoName(e))
			return 1
		}
		if got == 0 {
			break
		}
		if printed < maxPrint {
			want := int(got)
			if printed+want > maxPrint {
				want = maxPrint - printed
			}
			os.Stdout.Write(buf[:want])
			printed += want
		}
		total += int(got)
	}
	fmt.Printf("\ntls-client: read %d bytes total\n", total)
	return 0
}

// Build a minimal DNS query packet, ship it over UDP to a public resolver,
// and parse the A-record reply. This exercises the full UDP path:
// sendto_host (which routes through Network.framework's DNS), then
// recvfrom which must return the resolver's reply with its source addr.
// Doing real DNS in the packet payload means we also verify that the host
// is sending exactly the bytes we asked it to (not just acking and dropping).
func cmdDNSQuery(name string, resolver string) int {
	var fd int32 = -1
	if e := socketSocket(AF_INET, SOCK_DGRAM, unsafe.Pointer(&fd)); e != 0 {
		fmt.Fprintln(os.Stderr, "socket:", errnoName(e))
		return 1
	}
	defer socketClose(fd)

	// ---- Build the query ----
	// Header: id=0x1234, flags=0x0100 (standard query, RD), 1 question.
	pkt := make([]byte, 0, 64)
	pkt = append(pkt, 0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0)
	// QNAME: length-prefixed labels, terminated by a zero byte.
	for _, label := range strings.Split(name, ".") {
		if len(label) == 0 || len(label) > 63 {
			fmt.Fprintf(os.Stderr, "dns-query: invalid label in %s\n", name)
			return 1
		}
		pkt = append(pkt, byte(len(label)))
		pkt = append(pkt, []byte(label)...)
	}
	pkt = append(pkt, 0)
	// QTYPE=A (1), QCLASS=IN (1).
	pkt = append(pkt, 0, 1, 0, 1)

	var sent uint32
	if e := socketSendtoHost(fd, bytesPtr(pkt), int32(len(pkt)),
		stringPtr(resolver), int32(len(resolver)), 53,
		unsafe.Pointer(&sent)); e != 0 {
		fmt.Fprintf(os.Stderr, "sendto %s:53: %s\n", resolver, errnoName(e))
		return 1
	}
	fmt.Printf("dns-query: sent %d bytes to %s:53 for %s\n", sent, resolver, name)

	// ---- Receive the reply ----
	buf := make([]byte, 1500)
	addrBuf := make([]byte, 16)
	alen := int32(len(addrBuf))
	var got uint32
	if e := socketRecvfrom(fd, bytesPtr(buf), int32(len(buf)),
		bytesPtr(addrBuf), unsafe.Pointer(&alen),
		unsafe.Pointer(&got)); e != 0 {
		fmt.Fprintln(os.Stderr, "recvfrom:", errnoName(e))
		return 1
	}

	reply := buf[:got]
	if len(reply) < 12 {
		fmt.Fprintf(os.Stderr, "dns-query: short reply (%d bytes)\n", len(reply))
		return 1
	}
	// Confirm the resolver returned the source address we expect — proves
	// recvfrom is delivering peer info, not just zeroing the sockaddr.
	if alen >= 8 && addrBuf[0] == byte(AF_INET) {
		port := (uint16(addrBuf[2]) << 8) | uint16(addrBuf[3])
		fmt.Printf("dns-query: reply from %d.%d.%d.%d:%d (%d bytes)\n",
			addrBuf[4], addrBuf[5], addrBuf[6], addrBuf[7], port, got)
	} else {
		fmt.Printf("dns-query: reply (%d bytes, source addr unavailable)\n", got)
	}

	// ---- Parse the header ----
	if reply[0] != 0x12 || reply[1] != 0x34 {
		fmt.Fprintf(os.Stderr, "dns-query: transaction id mismatch (%02x%02x)\n",
			reply[0], reply[1])
		return 1
	}
	if reply[2]&0x80 == 0 {
		fmt.Fprintln(os.Stderr, "dns-query: QR bit not set (not a response)")
		return 1
	}
	rcode := reply[3] & 0x0f
	if rcode != 0 {
		fmt.Fprintf(os.Stderr, "dns-query: RCODE=%d (non-zero)\n", rcode)
		return 1
	}
	qd := int(reply[4])<<8 | int(reply[5])
	an := int(reply[6])<<8 | int(reply[7])
	fmt.Printf("dns-query: QDCOUNT=%d ANCOUNT=%d\n", qd, an)
	if an == 0 {
		fmt.Fprintln(os.Stderr, "dns-query: no answers")
		return 1
	}

	// Walk past the questions to land on the answer section.
	off := 12
	for i := 0; i < qd; i++ {
		next, ok := skipName(reply, off)
		if !ok {
			fmt.Fprintln(os.Stderr, "dns-query: malformed question name")
			return 1
		}
		off = next
		if off+4 > len(reply) {
			fmt.Fprintln(os.Stderr, "dns-query: truncated question")
			return 1
		}
		off += 4 // QTYPE + QCLASS
	}

	// Pull the first A record out of the answer section. Names here are
	// usually compressed pointers (0xC0xx), so skipName handles both.
	foundA := false
	for i := 0; i < an; i++ {
		next, ok := skipName(reply, off)
		if !ok {
			fmt.Fprintln(os.Stderr, "dns-query: malformed answer name")
			return 1
		}
		off = next
		if off+10 > len(reply) {
			fmt.Fprintln(os.Stderr, "dns-query: truncated RR")
			return 1
		}
		rtype := uint16(reply[off])<<8 | uint16(reply[off+1])
		rclass := uint16(reply[off+2])<<8 | uint16(reply[off+3])
		ttl := uint32(reply[off+4])<<24 | uint32(reply[off+5])<<16 |
			uint32(reply[off+6])<<8 | uint32(reply[off+7])
		rdlen := int(reply[off+8])<<8 | int(reply[off+9])
		off += 10
		if off+rdlen > len(reply) {
			fmt.Fprintln(os.Stderr, "dns-query: truncated RDATA")
			return 1
		}
		if rtype == 1 && rclass == 1 && rdlen == 4 {
			fmt.Printf("dns-query: %s A %d.%d.%d.%d (ttl %d)\n",
				name, reply[off], reply[off+1], reply[off+2], reply[off+3], ttl)
			foundA = true
		}
		off += rdlen
	}
	if !foundA {
		fmt.Fprintln(os.Stderr, "dns-query: no A record in answers")
		return 1
	}
	return 0
}

// skipName walks a DNS-encoded name and returns the offset of the first
// byte after it. Handles both label sequences (length-prefix + label,
// terminated by 0) and compression pointers (0b11xxxxxx). Pointers are
// not followed — they count as 2 bytes, which is all we need to advance
// past the name.
func skipName(buf []byte, off int) (int, bool) {
	for {
		if off >= len(buf) {
			return 0, false
		}
		length := buf[off]
		if length == 0 {
			return off + 1, true
		}
		if length&0xc0 == 0xc0 {
			if off+2 > len(buf) {
				return 0, false
			}
			return off + 2, true
		}
		if length&0xc0 != 0 {
			return 0, false // reserved bits set, malformed
		}
		off += 1 + int(length)
	}
}

func cmdTCPListen(port uint16) int {
	var fd int32 = -1
	if e := socketSocket(AF_INET, SOCK_STREAM, unsafe.Pointer(&fd)); e != 0 {
		fmt.Fprintln(os.Stderr, "socket:", errnoName(e))
		return 1
	}
	defer socketClose(fd)

	sa := sockaddrIn("0.0.0.0", port)
	if e := socketBind(fd, unsafe.Pointer(&sa[0]), int32(len(sa))); e != 0 {
		fmt.Fprintln(os.Stderr, "bind:", errnoName(e))
		return 1
	}
	if e := socketListen(fd, 16); e != 0 {
		fmt.Fprintln(os.Stderr, "listen:", errnoName(e))
		return 1
	}
	fmt.Printf("tcp-listen: listening on port %d\n", port)

	var conn int32 = -1
	if e := socketAccept(fd, unsafe.Pointer(&conn)); e != 0 {
		fmt.Fprintln(os.Stderr, "accept:", errnoName(e))
		return 1
	}

	buf := make([]byte, 1024)
	var got uint32
	if e := socketRecv(conn, bytesPtr(buf), int32(len(buf)), unsafe.Pointer(&got)); e != 0 {
		fmt.Fprintln(os.Stderr, "recv:", errnoName(e))
		socketClose(conn)
		return 1
	}
	reply := fmt.Sprintf("pong: echoed %d bytes\n", got)
	var sent uint32
	socketSend(conn, stringPtr(reply), int32(len(reply)), unsafe.Pointer(&sent))
	socketClose(conn)
	fmt.Println("tcp-listen: served one client, exiting")
	return 0
}

func cmdAll() int {
	acc := 0
	fmt.Println("=== hello ===")
	acc |= cmdHello([]string{"wasm-demo", "all"})
	fmt.Println("=== fs-write ===")
	acc |= cmdFsWrite("wasm-demo-all.txt")
	fmt.Println("=== fs-read ===")
	acc |= cmdFsRead("wasm-demo-all.txt")
	fmt.Println("=== fs-escape ===")
	acc |= cmdFsEscape("../../outside.txt")
	// The networking checks hit real internet hosts — running `all` is
	// also a quick way to confirm the device has working egress.
	// google.com on port 80 returns a 301 redirect to https, which is
	// still a valid HTTP response and exercises the plain-TCP path end
	// to end.
	fmt.Println("=== dns-query ===")
	acc |= cmdDNSQuery("google.com", "1.1.1.1")
	fmt.Println("=== tcp-client ===")
	acc |= cmdTCPClient("www.google.com", 80)
	fmt.Println("=== tls-client ===")
	acc |= cmdTLSClient("google.com", 443)
	if acc == 0 {
		fmt.Println("all: PASS")
	} else {
		fmt.Printf("all: FAIL (composite=%d)\n", acc)
	}
	return acc
}
