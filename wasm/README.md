# rootshell WASM demos

End-to-end demos and reference bindings for the **rootshell WASM runtime**:
the on-device sandbox that lets you compile CLI tools in any language that
targets WASI Preview 1 (C/C++ via clang/wasi-sdk, Rust, Go, TinyGo, Zig,
AssemblyScript, and so on) and run them on iPhone, iPad, and Vision Pro by
dropping the resulting `.wasm` into the rootshell directory.

Three reference implementations, same surface area:

| Demo                | Language | Path                 | Builds with |
|---------------------|----------|----------------------|-------------|
| `wasm-demo`         | Rust     | [`rust/`](rust/)     | `rustup target add wasm32-wasip1` |
| `wasm-demo-go`      | Go       | [`go/`](go/)         | Go 1.21+ (`GOOS=wasip1 GOARCH=wasm`) or TinyGo 0.31+ |
| `wasm-demo-swift`   | Swift    | [`swift/`](swift/)   | Swift 6.3+ with the swift.org `wasm` SDK (`wasm32-unknown-wasip1`) |

All three exercise the same subcommands (`hello`, `fs-write`, `fs-read`,
`fs-escape`, `tcp-client`, `tls-client`, `dns-query`, `tcp-listen`, `all`)
and link against the same host-provided `rootshell_socket_*` and
`rootshell_terminal_*` ABIs. Use them as starting points for your own
ports.

A note on Swift binary size: the demo here deliberately avoids
`import Foundation`. Foundation works on WASI (URLs, FileHandle,
ProcessInfo, Data all behave), but it drags in roughly **50 MB** of
extra wasm (ICU, the full NS object graph, the Swift concurrency
runtime). At that size, even `hello` takes several seconds to
instantiate on an iPhone or Vision Pro because the runtime has to
parse and validate every byte of the module before main runs. Sticking
to `WASILibc` for file I/O / stdio / environ / exit keeps the demo
around **3 MB** with no measurable startup delay. Foundation is fine if
you genuinely need it (JSON, URL parsing, NSCalendar, etc.), but go in
knowing the cost.

## Quick start

```bash
# Rust
cd rust && ./build.sh
# -> dist/wasm-demo.wasm

# Go (standard)
cd go && ./build.sh
# -> dist/wasm-demo-go.wasm

# Go (TinyGo, smaller binary)
cd go && ./build.sh tinygo
# -> dist/wasm-demo-go-tinygo.wasm

# Swift (needs the SwiftWasm wasm32-unknown-wasi SDK, see swift/build.sh)
cd swift && ./build.sh
# -> dist/wasm-demo-swift.wasm
```

Get the resulting `.wasm` onto the device by either:

- **Files app**: drop it into the rootshell directory.
- **scp / sftp from the iOS local shell**: the fastest iteration path.
  Open a local shell tab on the device and pull straight from your
  build machine. rootshell's `scp` and interactive `sftp` clients are
  built in and land files in the same sandbox the WASM runtime reads
  from.

  ```sh
  $ scp you@build-host:wasm-demo/dist/wasm-demo.wasm .
  $ ./wasm-demo.wasm hello
  ```

  Or interactively:

  ```sh
  $ sftp you@build-host
  sftp> get wasm-demo/dist/wasm-demo.wasm
  sftp> bye
  ```

Either way the file lands in the rootshell directory, which is the
WASM sandbox root (see [Filesystem sandbox](#filesystem-sandbox)).
From a local shell tab:

```sh
$ ./wasm-demo.wasm hello
hello from wasm-demo
argv = ["./wasm-demo.wasm", "hello"]
HOME = /
PWD = /

$ ./wasm-demo.wasm all          # full battery against real internet hosts
```

The WASM runtime is **iOS / visionOS only**. macOS uses a real native
shell with full fork/exec, so `.wasm` files there are just data; run the
underlying tool directly instead.

---

## Why this exists

rootshell ships with a curated set of native tools (vim, ripgrep, curl,
bat, and so on), but the long tail is endless. The WASM runtime is the
escape hatch: pick any language that has a WASI Preview 1 target, build a
static `.wasm`, drop it on the device, run it. No jailbreak, no developer
account, no recompiling rootshell.

What you get on top of vanilla WASI:

- A **filesystem preopen** rooted at the rootshell document directory,
  with `..`-traversal blocked. No access to system paths.
- A **host-provided socket ABI** (`rootshell_socket_*`) that lets WASM
  programs do real BSD-style networking (TCP, UDP, **TLS-on-TCP with
  host-side cert validation**, DNS) through Apple's Network.framework.
  WASI Preview 2 sockets are not used.
- A **terminal raw/cooked switch** (`rootshell_terminal_set_raw`) so
  full-screen TUIs (vim/htop-style) work alongside line-oriented programs
  (rclone-style configurators) inside the same shell session.
- WASI **argv, environ, stdin/stdout/stderr, exit** wired through to the
  shell tab. Same UX as any other built-in command.

---

## Filesystem sandbox

The runtime exposes WASI Preview 1 file ops (`path_open`, `fd_read`,
`fd_write`, `fd_close`, `path_create_directory`, `path_remove_directory`,
`path_unlink_file`, `path_rename`, `path_filestat_get`,
`path_filestat_set_times`, `fd_seek`, `fd_sync`, and so on) over a single
**preopened directory** equal to the rootshell document directory (what
shows up in Files.app as the "rootshell" folder).

Path semantics inside the WASM process:

| Input              | Resolves to |
|--------------------|-------------|
| `foo`              | `dirfd` + `/foo` (normal WASI openat) |
| `/foo`             | sandbox root + `/foo` (virtual-absolute) |
| `~`                | sandbox root (= `HOME`) |
| `~/foo`            | sandbox root + `/foo` |
| `../../etc/passwd` | **denied**. Path is canonicalised, then prefix-checked against the sandbox root. |

The host rejects paths containing a NUL byte, paths that resolve outside
the sandbox root, and any attempt to open a `dirfd` that wasn't itself
opened inside the sandbox. The `fs-escape` subcommand in both demos is
the negative test for this: it tries to open `../../outside.txt` and
expects an `EACCES`.

Environment-wise the runtime sets `HOME=/`, `PWD=/`, and `USER=mobile`
inside the sandbox (so `~` expansion in app-level shells matches the
WASM view). `argv[0]` is the path the user typed.

---

## Host ABI: `rootshell_socket_*`

Sockets bypass WASI Preview 1 entirely. WASI 1 has no socket support, and
WASI Preview 2's sockets are not yet broadly available across toolchains,
so rootshell exposes its own thin ABI that maps 1:1 onto BSD calls, and
the host implements them with Network.framework.

All calls follow the same shape:

- Return `i32` errno (0 = success, non-zero from the WASI errno set:
  `EBADF=8`, `EACCES=2`, `EINVAL=28`, `ECONNREFUSED=14`, `ETIMEDOUT=73`,
  `ENETUNREACH=50`, `EINTR=27`, `EADDRINUSE=1`, `ENOSYS=52`, `EIO=29`,
  `ENOENT=44`).
- Take `i32` socket fds. Note: this is a separate fd space from WASI fs.
  Fds returned by `rootshell_socket_socket` must not be passed to
  `fd_close`, and vice versa.
- Buffers are linear-memory offsets (`*const u8` / `*mut u8` in Rust,
  `unsafe.Pointer` in Go).
- `sockaddr` layout matches BSD `sockaddr_in` (`family=2`, port BE, then
  4 bytes IP) and `sockaddr_in6` (`family=30`, port BE, flowinfo,
  16 bytes IP, scope) byte-for-byte. `family` lives in the **first
  byte** (not `sa_len/sa_family`); the demos and host agree on a
  no-`sa_len` layout.
- Every call is **synchronous from the WASM program's perspective**.
  Internally the host parks the Worker thread on `Atomics.wait` until
  Network.framework delivers a result, but the WASM program just sees a
  blocking syscall return.

Constants:

```c
#define AF_INET     2
#define AF_INET6    30
#define SOCK_STREAM 1
#define SOCK_DGRAM  2
```

### Connection-oriented (TCP)

| Symbol                                       | Maps to        | Notes |
|----------------------------------------------|----------------|-------|
| `rootshell_socket_socket(domain, type, fd_out) -> errno`             | `socket(2)`    | `domain` in {`AF_INET`, `AF_INET6`}, `type` in {`SOCK_STREAM`, `SOCK_DGRAM`}. |
| `rootshell_socket_bind(fd, addr, addrlen) -> errno`                  | `bind(2)`      | `addr` is a `sockaddr_in` / `sockaddr_in6` blob. |
| `rootshell_socket_listen(fd, backlog) -> errno`                      | `listen(2)`    | Backing `NWListener` is started inside the broker. |
| `rootshell_socket_accept(fd, fd_out) -> errno`                       | `accept(2)`    | Blocks until an inbound connection arrives. Returns a new connected fd. |
| `rootshell_socket_connect(fd, addr, addrlen) -> errno`               | `connect(2)`   | IP literal in the sockaddr; the host does **not** resolve DNS here. |
| `rootshell_socket_send(fd, buf, len, sent_out) -> errno`             | `send(2)`      | Short writes possible; check `sent_out`. |
| `rootshell_socket_recv(fd, buf, len, recv_out) -> errno`             | `recv(2)`      | Returns `0` in `recv_out` at EOF. |
| `rootshell_socket_shutdown(fd, how) -> errno`                        | `shutdown(2)`  | `how` in {`SHUT_RD=0`, `SHUT_WR=1`, `SHUT_RDWR=2`}. |
| `rootshell_socket_close(fd) -> errno`                                | `close(2)`     | Releases the underlying `NWConnection` / `NWListener`. |
| `rootshell_socket_getsockname(fd, addr_out, addrlen_io) -> errno`    | `getsockname(2)` | Local endpoint after bind/connect. |
| `rootshell_socket_getpeername(fd, addr_out, addrlen_io) -> errno`    | `getpeername(2)` | Remote endpoint of a connected socket. |

### Datagram (UDP)

UDP uses the same `socket` / `bind` / `close` calls (with `type =
SOCK_DGRAM`) plus:

| Symbol                                                                                                                   | Maps to        |
|--------------------------------------------------------------------------------------------------------------------------|----------------|
| `rootshell_socket_sendto(fd, buf, len, addr, addrlen, sent_out) -> errno`                                                | `sendto(2)`    |
| `rootshell_socket_recvfrom(fd, buf, len, addr_out, addrlen_io, recv_out) -> errno`                                       | `recvfrom(2)`  |

`addr_out` is filled with the peer's sockaddr; the `addrlen_io`
in/out parameter tells the host how much space is available and gets
overwritten with the actual length. This is what makes the
`dns-query` demo work: it proves the host is wiring through the
resolver's source address, not zeroing the buffer.

### Hostname-friendly variants

These avoid the round-trip through a sockaddr by handing the host the
hostname directly. Network.framework does DNS, happy-eyeballs,
VPN-aware routing, and (for TLS) handshake + cert validation. Use
these in preference to `connect` / `sendto` when you have a name rather
than an IP. They Just Work behind the iOS VPN and Tailscale stacks.

| Symbol                                                                                                                                                 | Behaviour |
|--------------------------------------------------------------------------------------------------------------------------------------------------------|-----------|
| `rootshell_socket_connect_host(fd, host, host_len, port) -> errno`                                                                                     | TCP connect. `host` is a UTF-8 hostname **or** IP literal. |
| `rootshell_socket_tls_connect_host(fd, host, host_len, port) -> errno`                                                                                 | TLS-on-TCP. Sets up the TLS connection from scratch (no prior `connect_host`). After it returns 0, `send` / `recv` operate on the plaintext stream. SNI = `host`. Cert validation uses Apple's trust store. |
| `rootshell_socket_bind_host(fd, host, host_len, port) -> errno`                                                                                        | `bind` by interface name / IP literal. |
| `rootshell_socket_sendto_host(fd, buf, len, host, host_len, port, sent_out) -> errno`                                                                  | UDP `sendto` by hostname. |
| `rootshell_socket_resolve_v4(host, host_len, out_buf, out_max, count_out) -> errno`                                                                    | Explicit A-record resolution. `out_buf` receives `count_out * 4` bytes packed back-to-back. |
| `rootshell_socket_resolve_v6(host, host_len, out_buf, out_max, count_out) -> errno`                                                                    | Explicit AAAA-record resolution. 16 bytes per entry. |

For most uses you do **not** need to call `resolve_*`: pass the
hostname straight to `connect_host` / `tls_connect_host` and let
Network.framework's resolver handle it. The explicit resolvers exist
for tools that need to inspect or pick from the result set (DNS
diagnostics, multi-homed clients, custom happy-eyeballs).

### What's intentionally *not* exposed

- Raw sockets / ICMP. Entitlement-gated on iOS.
- `setsockopt` / `getsockopt`. Knobs like `SO_REUSEADDR`, `TCP_NODELAY`,
  `IP_MULTICAST_*` are mostly N/A under Network.framework. Reasonable
  defaults are baked in. Open a request issue if you need a specific
  knob.
- `select` / `poll` / `epoll` / `kqueue`. The broker is synchronous and
  one-fd-at-a-time inside a single call. If you need multiplexing,
  build it from threads (Go goroutines work; TinyGo's scheduler also
  works) or non-blocking loops over short `recv` calls.

---

## Host ABI: `rootshell_terminal_*` (raw vs cooked mode)

Local shell input has two modes when a WASM program is running. The
shell chooses based on a single bit owned by the WASM process,
flippable at runtime:

```c
i32 rootshell_terminal_set_raw(i32 enabled);   // 0 = cooked, 1 = raw
i32 rootshell_terminal_is_tty(i32 fd);         // 1 if fd 0/1/2 is on the terminal
```

`set_raw` returns `errno` (0 on success). The flip is process-scoped:
when your WASM exits, the shell goes back to cooked behaviour
automatically.

### Cooked mode (default)

The shell emulates POSIX termios `ICANON | ECHO | ICRNL | ERASE`:

| Behaviour | Detail |
|---|---|
| `ICANON` | stdin is **line-buffered**. Bytes accumulate in the shell until the user presses Enter, then the whole line + `\n` is delivered to the WASM in a single `fd_read`. |
| `ECHO` | Each typed printable byte is echoed back to the display. The WASM does not need to print what the user typed. |
| `ICRNL` | The terminal sends `\r` on Enter; cooked mode translates that to `\n` before delivery, so `bufio.NewReader.ReadString('\n')`, `read_line`, fgets, and friends all work as you'd expect on Linux. |
| `ERASE` | Backspace / DEL erases the previous byte from the buffer **and the display**. Bytes are not delivered to the WASM until Enter. |
| `Ctrl-C` | Cancels the WASM process (delivered as SIGINT-equivalent; the host fires `cancel` on the runtime). |
| `Ctrl-D` | On an empty line, delivers `EOF` (zero-byte read) to the WASM. On a non-empty line, ignored (matches Linux VEOF). |

Cooked mode is the right default for: line-oriented configurators
(rclone interactive setup), question/answer prompts, anything that
calls `read_line` / `ReadString('\n')` / `fgets`.

### Raw mode (`rootshell_terminal_set_raw(1)`)

Every byte is forwarded to the WASM **immediately, verbatim, without
echo and without CR->LF translation**. No line buffering, no `Ctrl-C`
handling at the shell level; the program owns the keystroke stream.

Raw mode is the right choice for: full-screen TUIs (vim/less/htop
style), keystroke-by-keystroke games, programs that draw their own
prompts and need to see arrow keys / function keys / mouse escape
sequences as they arrive.

If you flip into raw mode, **you are responsible for handling
Ctrl-C yourself** (it arrives as a `0x03` byte). Most TUI libraries
do this automatically.

You can flip back to cooked with `rootshell_terminal_set_raw(0)`,
for example to drop into cooked for an interactive prompt and then
back to raw to redraw the screen.

### `rootshell_terminal_is_tty(fd)`

Returns 1 if the given WASI fd (0, 1, 2 == stdin/stdout/stderr) is
attached to the terminal. Always 1 today, since the shell is the only
delivery mechanism, but useful for code that wants to fall back to
non-TTY behaviour when redirected. (`./wasm-demo.wasm hello >
file.txt` is **not** currently supported by the shell driver; the
demo binary still returns 1 here because the host has no other way
to deliver stdout.)

---

## What the demos prove

Each subcommand exists to exercise one slice of the runtime:

| Command                                         | Surface tested |
|-------------------------------------------------|----------------|
| `hello`                                         | argv, environ, stdout, exit code |
| `fs-write <path>`                               | `path_open` + `fd_write` + `fd_close` inside the sandbox |
| `fs-read <path>`                                | `path_open` read + `fd_read` + EOF |
| `fs-escape ../../outside.txt`                   | sandbox **rejects** with `EACCES` (negative test) |
| `tcp-client <host> <port>`                      | `socket` / `connect_host` / `send` / `recv` / `close` against an HTTP server |
| `tls-client <host> <port>`                      | `tls_connect_host` + cert validation against an HTTPS server |
| `dns-query <name> [resolver]`                   | hand-built DNS/A query over UDP via `sendto_host` + `recvfrom` (also proves peer address is delivered) |
| `tcp-listen <port>`                             | `bind` / `listen` / `accept` + one-shot echo |
| `all`                                           | runs every self-contained subcommand plus `dns-query`, `tcp-client`, `tls-client` against real internet hosts |

`tcp-listen` needs a peer to be useful; it's driven by the in-app
`wasm test` self-test runner (which spins up a loopback client),
not by `all`.

The full source for all three bindings is the canonical reference for
the ABI. For Rust see [`rust/src/socket_shim.rs`](rust/src/socket_shim.rs);
for Go see [`go/socket.go`](go/socket.go); for Swift see
[`swift/Sources/wasm-demo-swift/SocketShim.swift`](swift/Sources/wasm-demo-swift/SocketShim.swift).

---

## Building your own WASM tools

Anything that targets **WASI Preview 1** will run. Known-good
toolchains:

- **Rust**: `rustup target add wasm32-wasip1`, then
  `cargo build --target wasm32-wasip1 --release`.
- **Go**: `GOOS=wasip1 GOARCH=wasm go build` (Go 1.21+).
- **TinyGo**: `tinygo build -target=wasip1 -opt=z` (much smaller
  binaries, occasional stdlib gaps).
- **Swift**: install the official swift.org `wasm` SDK with
  `swift sdk install <artifactbundle url>` (the 6.3.2 bundle targets
  `wasm32-unknown-wasip1`), then `swift build --swift-sdk
  swift-6.3.2-RELEASE_wasm -c release`. Needs Swift 6.0+ for the
  `@_extern(wasm, module:, name:)` attribute used to import host
  functions, plus a matching host toolchain (use
  [swiftly](https://www.swift.org/install/macos/) to keep them in
  sync). Skip `import Foundation` unless you need it — see the size
  note above.
- **C / C++**: wasi-sdk (`clang --target=wasm32-wasi`).
- **Zig**: `zig build-exe -target wasm32-wasi`.
- **AssemblyScript**, **Grain**, etc.: anything that emits a
  Preview 1 binary.

To use the rootshell socket / terminal ABIs from a new language, just
declare the imports under the right module name:

- Module `rootshell_socket`: all `rootshell_socket_*` functions.
- Module `rootshell_terminal`: `rootshell_terminal_set_raw`,
  `rootshell_terminal_is_tty`.

In Rust the imports default to module `env` and the host accepts that
as a fallback; in Go the `//go:wasmimport` directive requires an
explicit module name (see [`go/socket.go`](go/socket.go)); in Swift
6.0+ the `@_extern(wasm, module:, name:)` attribute names the module
explicitly (see [`swift/Sources/wasm-demo-swift/SocketShim.swift`](swift/Sources/wasm-demo-swift/SocketShim.swift)).

Drop the resulting `.wasm` into the rootshell document directory (the
Files app "rootshell" folder, or `scp` / `sftp` it in directly from a
local shell tab) and invoke it by name. Working directory inside the
WASM matches the shell's `pwd` at launch.
