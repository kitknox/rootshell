package hook

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/kitknox/rootshell/push/envelope"
)

func TestHeaderShowsSendingHost(t *testing.T) {
	e, err := Parse(Codex, fixture(t, "codex_stop.json"))
	if err != nil {
		t.Fatal(err)
	}
	route := &envelope.Route{Host: "kit@build-mac", Cwd: e.Cwd, Pane: "pane-1"}
	h := e.Header(route)
	if h.Title != "[build-mac] Codex · app" || h.Route != route || h.Kind != "agent" {
		t.Fatalf("header: %+v", h)
	}
	if e.Title != "Codex · app" || h.Body != e.Body || h.Agent != e.Agent {
		t.Fatalf("header mutated the parsed event: %+v %+v", e, h)
	}
	for _, r := range []*envelope.Route{nil, {Host: ""}} {
		if got := e.Header(r).Title; got != "Codex · app" {
			t.Fatalf("missing host: %q", got)
		}
	}
	if got := e.Header(&envelope.Route{Host: "build-linux"}).Title; got != "[build-linux] Codex · app" {
		t.Fatalf("host without username: %q", got)
	}
	e.Title = "Pi · " + strings.Repeat("界", 150)
	h = e.Header(route)
	if utf8.RuneCountInString(h.Title) > envelope.MaxTitleLen || !utf8.ValidString(h.Title) ||
		!strings.HasPrefix(h.Title, "[build-mac] Pi · ") {
		t.Fatalf("long title: %q", h.Title)
	}
}

func TestHostPrefixFitsExistingEnvelopeBudget(t *testing.T) {
	e := &Event{Agent: "pi", AgentName: "Pi", Status: "done", Title: "Pi · app", Body: strings.Repeat("界", MaxBody), Thread: "session-thread"}
	route := &envelope.Route{Host: "kit@build-linux-01", Pane: "pane-1", TmuxPane: "%12", TmuxSession: "work", Cwd: "/"}
	previous := &envelope.Header{V: envelope.Version, Kind: "agent", Agent: "pi", Status: "done", Title: "Pi · app", Body: e.Body, Thread: e.Thread, Route: route}
	raw, err := json.Marshal(previous)
	if err != nil {
		t.Fatal(err)
	}
	route.Cwd += strings.Repeat("x", envelope.MaxHeaderBytes-10-len(raw))
	raw, _ = json.Marshal(previous)
	if len(raw) != envelope.MaxHeaderBytes-10 {
		t.Fatalf("fixture must fit before adding host: %d bytes", len(raw))
	}
	h := e.Header(route)
	sk, err := envelope.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := envelope.Seal(sk.PublicKey(), "host-budget-test", h); err != nil {
		t.Fatalf("host prefix made a deliverable header unsendable: %v", err)
	}
	if h.Title != "[build-linux-01] Pi · app" || h.Route != route || h.Body == e.Body || !utf8.ValidString(h.Body) {
		t.Fatalf("must preserve host and route, shorten only the body: %+v", h)
	}
}

func TestExtensionAgentEvents(t *testing.T) {
	for _, agent := range []string{"pi", "omp", "hermes"} {
		t.Run(agent, func(t *testing.T) {
			a, err := ParseAgent(agent)
			if err != nil {
				t.Fatal(err)
			}
			name := "Pi"
			if agent == "omp" {
				name = "OMP"
			} else if agent == "hermes" {
				name = "Hermes"
			}
			for _, tc := range []struct {
				event, stop, message, wantStatus, wantBody string
				continuing, ignore                         bool
			}{
				{event: "agent_end", stop: "stop", message: "Done. api_key=secret", wantStatus: "done", wantBody: "Done. api_key=[redacted]"},
				{event: "agent_end", stop: "error", message: "Request failed.", wantStatus: "failed", wantBody: "Request failed."},
				{event: "agent_end", stop: "aborted", ignore: true},
				{event: "agent_end", stop: "toolUse", ignore: true},
				{event: "agent_end", stop: "unknown-future-reason", ignore: true},
				{event: "agent_end", continuing: true, ignore: true},
				{event: "input_required", message: "Approval required for bash", wantStatus: "blocked", wantBody: "Approval required for bash"},
				{event: "tool_execution_end", ignore: true},
			} {
				in := map[string]any{
					"hook_event_name": tc.event, "session_id": "s-1", "event_id": "run-1",
					"cwd": "/srv/app", "stop_reason": tc.stop, "will_continue": tc.continuing,
					"last_assistant_message": tc.message, "message": tc.message,
				}
				data, _ := json.Marshal(in)
				e, err := Parse(a, data)
				if tc.ignore {
					if !errors.Is(err, ErrIgnore) {
						t.Fatalf("%s: want ignored, got %+v %v", tc.event, e, err)
					}
					continue
				}
				if err != nil {
					t.Fatal(err)
				}
				h := e.Header(&envelope.Route{Host: "kit@build-mac"})
				if h.Kind != "agent" || h.Agent != agent || h.Status != tc.wantStatus ||
					h.Title != "[build-mac] "+name+" · app" || h.Body != tc.wantBody {
					t.Fatalf("header: %+v", h)
				}
			}
		})
	}
}

func TestExtensionEventIdentity(t *testing.T) {
	payload := `{"session_id":"s-1","event_id":"run-1","hook_event_name":"agent_end","last_assistant_message":"Done."}`
	a, err := Parse(Agent("pi"), []byte(payload))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := Parse(Agent("pi"), []byte(payload))
	c, _ := Parse(Agent("pi"), []byte(strings.Replace(payload, "run-1", "run-2", 1)))
	d, _ := Parse(Agent("omp"), []byte(payload))
	if a.EID != b.EID || a.EID == c.EID || a.Thread != c.Thread || a.Thread == d.Thread || a.EID == d.EID {
		t.Fatalf("identity: %+v %+v %+v %+v", a, b, c, d)
	}
	for _, input := range []string{
		`{"hook_event_name":"agent_end","event_id":"run-1"}`,
		`{"hook_event_name":"agent_end","session_id":"s-1"}`,
	} {
		if _, err := Parse(Agent("pi"), []byte(input)); err == nil || errors.Is(err, ErrIgnore) {
			t.Fatalf("missing identity accepted: %s", input)
		}
	}
}
