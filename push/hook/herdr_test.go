package hook

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const herdrResponse = `{"id":"rootshell-notify:pane","result":{"type":"pane_info","pane":{"pane_id":"w2:p7","terminal_id":"term_live"}}}` + "\n"

func herdrSocket(t *testing.T, reply func(net.Conn)) string {
	t.Helper()
	// Darwin Unix socket paths cannot exceed 104 bytes.
	dir, err := os.MkdirTemp("/tmp", "rs-herdr-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "api.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		reply(conn)
	}()
	t.Cleanup(func() { listener.Close(); <-done })
	t.Setenv("HERDR_PANE_ID", "w1:p2")
	t.Setenv("HERDR_SOCKET_PATH", socket)
	return socket
}

func TestHerdrRouteResolvesMovedPane(t *testing.T) {
	socket := herdrSocket(t, func(conn net.Conn) {
		var request struct {
			Method string
			Params map[string]string
		}
		if err := json.NewDecoder(conn).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		if request.Method != "pane.get" || request.Params["pane_id"] != "w1:p2" {
			t.Errorf("wrong request: %+v", request)
		}
		io.WriteString(conn, herdrResponse)
	})
	t.Setenv("HERDR_TAB_ID", "w1:t2")
	t.Setenv("HERDR_WORKSPACE_ID", "w1")
	t.Setenv("HERDR_BIN_PATH", "/nonexistent/herdr")
	t.Setenv("LC_ROOTSHELL_PANE", "gateway")
	t.Setenv("TMUX", "inherited")
	t.Setenv("PATH", "")
	route := Route(t.Context(), "/work")
	host, _ := os.Hostname()
	if route.HerdrPane != "w2:p7" || route.HerdrTerminal != "term_live" ||
		route.HerdrServer != herdrServerIdentity(host, strconv.Itoa(os.Geteuid()), socket) ||
		route.Pane != "gateway" || route.Cwd != "/work" || route.TmuxServer != "" {
		t.Fatalf("unexpected route: %+v", route)
	}
}

func TestHerdrRouteFailuresKeepHint(t *testing.T) {
	for name, response := range map[string]string{
		"malformed":      "no json\n",
		"truncated":      strings.TrimSuffix(herdrResponse, "\n"),
		"oversized":      strings.Repeat(" ", herdrMaxResponseBytes) + herdrResponse,
		"wrong id":       strings.Replace(herdrResponse, "rootshell-notify:pane", "other", 1),
		"wrong result":   strings.Replace(herdrResponse, "pane_info", "ok", 1),
		"empty terminal": strings.Replace(herdrResponse, "term_live", "", 1),
		"empty pane":     strings.Replace(herdrResponse, "w2:p7", "", 1),
		"remote error":   `{"id":"rootshell-notify:pane","error":{"code":"not_found"}}` + "\n",
	} {
		t.Run(name, func(t *testing.T) {
			herdrSocket(t, func(conn net.Conn) {
				bufio.NewReader(conn).ReadBytes('\n')
				io.WriteString(conn, response)
			})
			route := Route(t.Context(), "/work")
			if route.HerdrPane != "w1:p2" || route.HerdrTerminal != "" || route.HerdrServer != "" {
				t.Fatalf("unsafe route: %+v", route)
			}
		})
	}
}

func TestHerdrRouteMissingEnvironment(t *testing.T) {
	for _, pane := range []string{"", "w1:p2"} {
		for _, socket := range []string{"", "/nonexistent/rootshell-herdr.sock"} {
			t.Setenv("HERDR_PANE_ID", pane)
			t.Setenv("HERDR_SOCKET_PATH", socket)
			t.Setenv("TMUX", "")
			route := Route(t.Context(), "/work")
			if route.HerdrPane != pane || route.HerdrServer != "" || route.HerdrTerminal != "" {
				t.Fatalf("unexpected route: %+v", route)
			}
		}
	}
}

func TestHerdrRouteCancellationAndTimeout(t *testing.T) {
	for _, earlyCancel := range []bool{false, true} {
		t.Run(strconv.FormatBool(earlyCancel), func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			herdrSocket(t, func(conn net.Conn) {
				bufio.NewReader(conn).ReadBytes('\n')
				if earlyCancel {
					cancel()
				}
				io.Copy(io.Discard, conn) // returns when the client closes on cancellation/deadline
			})
			start := time.Now()
			route := Route(ctx, "/work")
			limit := 2 * time.Second
			if earlyCancel {
				limit = 500 * time.Millisecond
			}
			if time.Since(start) > limit || route.HerdrTerminal != "" || route.HerdrPane != "w1:p2" {
				t.Fatalf("lookup did not fail promptly: %+v (%v)", route, time.Since(start))
			}
		})
	}
}

func TestHerdrServerIdentity(t *testing.T) {
	const want = "821bba138301c53b6e41e66f65a569561dab6a53b013d7ae5683404ce04dc41f"
	if got := herdrServerIdentity("dev.example", "1000", "/home/user/.config/herdr/herdr.sock"); got != want {
		t.Fatal(got)
	}
	if herdrServerIdentity("", "1000", "/socket") != "" {
		t.Fatal("accepted missing host")
	}
	if herdrServerIdentity("dev", "1000", "/socket") == herdrServerIdentity("dev", "1000", "/named/socket") {
		t.Fatal("different namespaces collided")
	}
}
