package hook

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/kitknox/rootshell/push/envelope"
)

const herdrMaxResponseBytes = 64 * 1024

// The namespace scopes Herdr's terminal IDs across hosts and named sessions.
// Keep this byte encoding identical to PushHerdrRoute.serverIdentity in Swift.
func herdrServerIdentity(host, uid, socket string) string {
	if host == "" || uid == "" || socket == "" {
		return ""
	}
	return hashOf(host + "\x00" + uid + "\x00" + socket)
}

func populateHerdrRoute(ctx context.Context, route *envelope.Route) {
	socket := os.Getenv("HERDR_SOCKET_PATH")
	if socket == "" {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", socket)
	if err != nil {
		return
	}
	defer conn.Close()
	// A deadline bounds reads/writes; closing also handles early cancellation.
	deadline, _ := ctx.Deadline()
	if err := conn.SetDeadline(deadline); err != nil {
		return
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	const requestID = "rootshell-notify:pane"
	request := struct {
		ID     string            `json:"id"`
		Method string            `json:"method"`
		Params map[string]string `json:"params"`
	}{requestID, "pane.get", map[string]string{"pane_id": route.HerdrPane}}
	if err := json.NewEncoder(conn).Encode(request); err != nil {
		return
	}
	line, err := bufio.NewReader(io.LimitReader(conn, herdrMaxResponseBytes+1)).ReadBytes('\n')
	if err != nil || len(line) > herdrMaxResponseBytes {
		return
	}
	var response struct {
		ID     string          `json:"id"`
		Error  json.RawMessage `json:"error"`
		Result struct {
			Type string `json:"type"`
			Pane struct {
				PaneID     string `json:"pane_id"`
				TerminalID string `json:"terminal_id"`
			} `json:"pane"`
		} `json:"result"`
	}
	if json.Unmarshal(line, &response) != nil || response.ID != requestID || len(response.Error) != 0 ||
		response.Result.Type != "pane_info" || strings.TrimSpace(response.Result.Pane.PaneID) == "" ||
		strings.TrimSpace(response.Result.Pane.TerminalID) == "" || ctx.Err() != nil {
		return
	}
	host, err := os.Hostname()
	if err != nil {
		return
	}
	route.HerdrServer = herdrServerIdentity(host, strconv.Itoa(os.Geteuid()), socket)
	route.HerdrTerminal = response.Result.Pane.TerminalID
	route.HerdrPane = response.Result.Pane.PaneID
}
