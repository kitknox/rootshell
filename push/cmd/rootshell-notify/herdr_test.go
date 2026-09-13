package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/kitknox/rootshell/push/client"
	"github.com/kitknox/rootshell/push/config"
	"github.com/kitknox/rootshell/push/envelope"
)

func TestCommandsSealHerdrRoutes(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "rs-notify-")
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
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			conn.SetDeadline(time.Now().Add(2 * time.Second))
			bufio.NewReader(conn).ReadBytes('\n')
			io.WriteString(conn, `{"id":"rootshell-notify:pane","result":{"type":"pane_info","pane":{"pane_id":"w1:p2","terminal_id":"term_test"}}}`+"\n")
			conn.Close()
		}
	}()
	t.Cleanup(func() { listener.Close(); <-done })
	t.Setenv("HERDR_PANE_ID", "w1:p2")
	t.Setenv("HERDR_SOCKET_PATH", socket)
	t.Setenv("LC_ROOTSHELL_PANE", "00000000-0000-4000-8000-000000000001")
	t.Setenv("TMUX", "")
	t.Setenv(config.EnvPath, filepath.Join(dir, "config.json"))
	sk, err := envelope.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	headers := make(chan *envelope.Header, 4)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var sealed envelope.Envelope
		if err := json.NewDecoder(r.Body).Decode(&sealed); err != nil {
			t.Error(err)
			w.WriteHeader(400)
			return
		}
		header, err := envelope.Open(sk, &sealed)
		if err != nil {
			t.Error(err)
			w.WriteHeader(400)
			return
		}
		headers <- header
		w.WriteHeader(http.StatusAccepted)
		io.WriteString(w, `{"accepted":true}`)
	}))
	defer server.Close()
	old := newClient
	newClient = func() *client.Client { c := client.New("test"); c.HTTP = server.Client(); return c }
	t.Cleanup(func() { newClient = old })
	cfg := config.Config{Devices: []config.Device{{Label: "Test phone", Server: server.URL,
		SenderCred: "rsc1.test", PublicKey: sk.PublicKey().Bytes(), HooksEnabled: true}}}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name  string
		args  []string
		input string
	}{
		{"send", []string{"send", "--title", "Test"}, ""},
		{"test", []string{"test"}, ""},
		{"hook", []string{"hook", "--agent", "codex"}, `{"hook_event_name":"Stop","session_id":"test-session","cwd":"/work/example","last_assistant_message":"Finished."}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var out, errb bytes.Buffer
			if code := run(tc.args, strings.NewReader(tc.input), &out, &errb); code != exitOK {
				t.Fatalf("%d: %s", code, errb.String())
			}
			select {
			case header := <-headers:
				if header.Route == nil || header.Route.HerdrPane != "w1:p2" || header.Route.HerdrTerminal != "term_test" || len(header.Route.HerdrServer) != 64 || header.Route.Pane != os.Getenv("LC_ROOTSHELL_PANE") {
					t.Fatalf("unexpected route: %+v", header.Route)
				}
			default:
				t.Fatal("command sent no notification")
			}
			if tc.name == "hook" && out.Len() != 0 {
				t.Fatal("hook wrote stdout")
			}
		})
	}
}
