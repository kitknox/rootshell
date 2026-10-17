package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/kitknox/rootshell/push/client"
	"github.com/kitknox/rootshell/push/config"
	"github.com/kitknox/rootshell/push/envelope"
	"github.com/kitknox/rootshell/push/installer"
)

func TestMain(m *testing.M) {
	// Deliver Codex hooks in-process; a detached child would rerun the test binary.
	os.Setenv(hookChildEnv, "1")
	os.Exit(m.Run())
}

func TestCodexHookHandsDeliveryToDetachedChild(t *testing.T) {
	t.Setenv(config.EnvPath, filepath.Join(t.TempDir(), "config.json"))
	t.Setenv(hookChildEnv, "")
	var mu sync.Mutex
	delivered := 0
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		delivered++
		mu.Unlock()
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()
	old := newClient
	newClient = func() *client.Client {
		c := client.New("test")
		c.HTTP = srv.Client()
		return c
	}
	t.Cleanup(func() { newClient = old })
	cfg := &config.Config{Devices: []config.Device{testDevice(t, "phone", "rsc1.phone", srv.URL, true)}}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	var gotArgs []string
	var gotData []byte
	detachErr := error(nil)
	oldDetach := detachHook
	detachHook = func(args []string, data []byte) error {
		gotArgs, gotData = args, data
		return detachErr
	}
	t.Cleanup(func() { detachHook = oldDetach })

	payload := `{"session_id":"s","cwd":"/srv/app","turn_id":"t","hook_event_name":"Stop","last_assistant_message":"Done."}`
	var out, errb bytes.Buffer
	if code := run([]string{"hook", "--agent", "codex"}, strings.NewReader(payload), &out, &errb); code != exitOK {
		t.Fatal(code)
	}
	mu.Lock()
	if delivered != 0 || strings.Join(gotArgs, " ") != "--agent codex" || string(gotData) != payload {
		t.Fatalf("detached hand-off: delivered %d, args %v, data %q", delivered, gotArgs, gotData)
	}
	mu.Unlock()

	detachErr = os.ErrPermission
	if code := run([]string{"hook", "--agent", "codex"}, strings.NewReader(payload), &out, &errb); code != exitOK {
		t.Fatal(code)
	}
	mu.Lock()
	defer mu.Unlock()
	if delivered != 1 || out.Len() != 0 {
		t.Fatalf("failed detach must deliver inline: %d %q", delivered, out.String())
	}
}

func TestHookIsSilentWithoutDevices(t *testing.T) {
	t.Setenv(config.EnvPath, filepath.Join(t.TempDir(), "config.json"))
	var out, errb bytes.Buffer
	for _, in := range []string{"", "garbage", `{"transcript_path":"x","hook_event_name":"Stop"}`} {
		if code := run([]string{"hook", "--agent", "claude-code"}, strings.NewReader(in), &out, &errb); code != 0 {
			t.Fatalf("hook exit %d", code)
		}
	}
	if out.Len() != 0 || errb.Len() != 0 {
		t.Fatalf("hook wrote output: %q %q", out.String(), errb.String())
	}
}

func TestUsageExitCodes(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run(nil, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	if code := run([]string{"bogus"}, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	if code := run([]string{"send"}, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	if code := run([]string{"install", "vim"}, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	out.Reset()
	if code := run([]string{"help"}, strings.NewReader(""), &out, &errb); code != 0 || !strings.Contains(out.String(), "Usage:") {
		t.Fatal(code)
	}
}

func TestParseFlags(t *testing.T) {
	f, err := parseFlags([]string{"claude-code", "--project", "--title=Hi there", "--body", "b", "--yes"}, "project", "yes")
	if err != nil {
		t.Fatal(err)
	}
	if len(f.args) != 1 || f.args[0] != "claude-code" || !f.has("project") || f.vals["title"] != "Hi there" || f.vals["body"] != "b" || !f.has("yes") {
		t.Fatalf("%+v", f)
	}
	if _, err := parseFlags([]string{"--title"}); err == nil {
		t.Fatal("missing value accepted")
	}
}

func testDevice(t *testing.T, label, cred, server string, hooksEnabled bool) config.Device {
	t.Helper()
	sk, err := envelope.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	return config.Device{
		Label:        label,
		Server:       server,
		SenderCred:   cred,
		PublicKey:    sk.PublicKey().Bytes(),
		HooksEnabled: hooksEnabled,
	}
}

func TestDevicesCommandsAndPicker(t *testing.T) {
	t.Setenv(config.EnvPath, filepath.Join(t.TempDir(), "config.json"))
	cfg := &config.Config{Devices: []config.Device{
		testDevice(t, "phone", "rsc1.phone", "https://push.example", true),
		testDevice(t, "tablet", "rsc1.tablet", "https://push.example", false),
	}}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}

	var out, errb bytes.Buffer
	if code := run([]string{"devices"}, strings.NewReader(""), &out, &errb); code != exitOK {
		t.Fatal(code, errb.String())
	}
	if got := out.String(); !strings.Contains(got, "[1] on") || !strings.Contains(got, "phone") || !strings.Contains(got, "[2] off") || !strings.Contains(got, "tablet") {
		t.Fatal(got)
	}

	out.Reset()
	if code := run([]string{"devices", "off", "phone"}, strings.NewReader(""), &out, &errb); code != exitOK || !strings.Contains(out.String(), "phone: agent hooks off") {
		t.Fatalf("off: %d %q %q", code, out.String(), errb.String())
	}
	out.Reset()
	if code := run([]string{"devices", "off", "phone"}, strings.NewReader(""), &out, &errb); code != exitOK || !strings.Contains(out.String(), "already off") {
		t.Fatalf("idempotent off: %d %q %q", code, out.String(), errb.String())
	}
	out.Reset()
	if code := run([]string{"devices", "toggle", "tablet"}, strings.NewReader(""), &out, &errb); code != exitOK || !strings.Contains(out.String(), "tablet: agent hooks on") {
		t.Fatalf("toggle: %d %q %q", code, out.String(), errb.String())
	}

	out.Reset()
	errb.Reset()
	if code := cmdDevices(nil, strings.NewReader("nope\n3\n1\n2\n\n"), &out, &errb, true); code != exitOK {
		t.Fatalf("picker: %d %q", code, errb.String())
	}
	if strings.Count(errb.String(), "Enter a number from 1 to 2") != 2 || !strings.Contains(out.String(), "phone: agent hooks on") || !strings.Contains(out.String(), "tablet: agent hooks off") {
		t.Fatalf("picker output: %q %q", out.String(), errb.String())
	}
	cfg, err := config.Load()
	if err != nil || !cfg.Devices[0].HooksEnabled || cfg.Devices[1].HooksEnabled {
		t.Fatalf("picker state: %v %+v", err, cfg)
	}
	out.Reset()
	errb.Reset()
	if code := run([]string{"devices", "on", "tablet"}, strings.NewReader(""), &out, &errb); code != exitOK || !strings.Contains(out.String(), "tablet: agent hooks on") {
		t.Fatalf("on: %d %q %q", code, out.String(), errb.String())
	}
	out.Reset()
	if code := cmdDevices(nil, strings.NewReader(""), &out, &errb, true); code != exitOK {
		t.Fatalf("picker EOF: %d %q", code, errb.String())
	}

	for _, args := range [][]string{{"devices", "bad", "phone"}, {"devices", "on"}, {"devices", "on", "missing"}} {
		out.Reset()
		errb.Reset()
		code := run(args, strings.NewReader(""), &out, &errb)
		if code == exitOK {
			t.Fatalf("accepted %v: %q", args, out.String())
		}
	}
}

func TestHookDeviceSelectionDoesNotLimitManualDelivery(t *testing.T) {
	t.Setenv(config.EnvPath, filepath.Join(t.TempDir(), "config.json"))
	var mu sync.Mutex
	var credentials []string
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/push" {
			http.NotFound(w, r)
			return
		}
		mu.Lock()
		credentials = append(credentials, r.Header.Get("Authorization"))
		mu.Unlock()
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()
	old := newClient
	newClient = func() *client.Client {
		c := client.New("test")
		c.HTTP = srv.Client()
		return c
	}
	t.Cleanup(func() { newClient = old })

	cfg := &config.Config{Devices: []config.Device{
		testDevice(t, "phone", "rsc1.phone", srv.URL, true),
		testDevice(t, "tablet", "rsc1.tablet", srv.URL, false),
	}}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	reset := func() {
		mu.Lock()
		credentials = nil
		mu.Unlock()
	}
	gotCredentials := func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), credentials...)
	}
	runOK := func(args []string, input string) {
		t.Helper()
		var out, errb bytes.Buffer
		if code := run(args, strings.NewReader(input), &out, &errb); code != exitOK {
			t.Fatalf("%v: exit %d: %s %s", args, code, out.String(), errb.String())
		}
	}

	payload := `{"session_id":"sess-9","cwd":"/srv/app","turn_id":"turn-42","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done."}`
	runOK([]string{"hook", "--agent", "codex"}, payload)
	if got := gotCredentials(); len(got) != 1 || got[0] != "Bearer rsc1.phone" {
		t.Fatalf("hook recipients: %v", got)
	}

	reset()
	runOK([]string{"test", "tablet"}, "")
	if got := gotCredentials(); len(got) != 1 || got[0] != "Bearer rsc1.tablet" {
		t.Fatalf("explicit test recipients: %v", got)
	}

	reset()
	runOK([]string{"send", "--title", "Manual"}, "")
	if got := gotCredentials(); len(got) != 2 {
		t.Fatalf("broadcast recipients: %v", got)
	}

	reset()
	runOK([]string{"send", "--title", "Manual", "--device", "tablet"}, "")
	if got := gotCredentials(); len(got) != 1 || got[0] != "Bearer rsc1.tablet" {
		t.Fatalf("explicit send recipients: %v", got)
	}

	cfg.Devices[0].HooksEnabled = false
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	reset()
	runOK([]string{"hook", "--agent", "codex"}, "not even parsed")
	if got := gotCredentials(); len(got) != 0 {
		t.Fatalf("all-disabled hook recipients: %v", got)
	}
}

func TestExtensionHooksDeliverNativeAgentNotifications(t *testing.T) {
	t.Setenv(config.EnvPath, filepath.Join(t.TempDir(), "config.json"))
	t.Setenv("HERDR_PANE_ID", "")
	t.Setenv("TMUX", "")
	t.Setenv("LC_ROOTSHELL_PANE", "pane-1")
	sk, err := envelope.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	type delivery struct {
		header *envelope.Header
		eid    string
	}
	var mu sync.Mutex
	var received []delivery
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/push" || r.Header.Get("Authorization") != "Bearer rsc1.phone" {
			t.Errorf("unexpected recipient: %s %s", r.URL.Path, r.Header.Get("Authorization"))
		}
		var env envelope.Envelope
		if err := json.NewDecoder(r.Body).Decode(&env); err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		h, err := envelope.Open(sk, &env)
		if err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		mu.Lock()
		received = append(received, delivery{h, env.EID})
		mu.Unlock()
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()
	old := newClient
	newClient = func() *client.Client {
		c := client.New("test")
		c.HTTP = srv.Client()
		return c
	}
	t.Cleanup(func() { newClient = old })
	cfg := &config.Config{Devices: []config.Device{
		{Label: "phone", Server: srv.URL, SenderCred: "rsc1.phone", PublicKey: sk.PublicKey().Bytes(), HooksEnabled: true},
		testDevice(t, "disabled", "rsc1.disabled", srv.URL, false),
	}}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	for _, agent := range []string{"pi", "omp", "hermes"} {
		for _, eventID := range []string{"run-1", "run-1", "run-2"} {
			in := `{"hook_event_name":"agent_end","session_id":"s-1","event_id":"` + eventID +
				`","cwd":"/srv/app","last_assistant_message":"Done. password=hunter2","stop_reason":"stop"}`
			var out, errb bytes.Buffer
			if code := run([]string{"hook", "--agent", agent}, strings.NewReader(in), &out, &errb); code != exitOK ||
				out.Len() != 0 || errb.Len() != 0 {
				t.Fatalf("hook: %d %q %q", code, out.String(), errb.String())
			}
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(received) != 9 {
		t.Fatalf("want nine encrypted deliveries, got %d", len(received))
	}
	for i, d := range received {
		agent, name := "pi", "Pi"
		if i >= 6 {
			agent, name = "hermes", "Hermes"
		} else if i >= 3 {
			agent, name = "omp", "OMP"
		}
		h := d.header
		if h.Kind != "agent" || h.Agent != agent || h.Status != "done" ||
			h.Title != "["+hostName()+"] "+name+" · app" || h.Body != "Done. password=[redacted]" ||
			h.Route == nil || h.Route.Pane != "pane-1" || h.Route.Cwd != "/srv/app" {
			t.Fatalf("decrypted header: %+v", h)
		}
	}
	for _, start := range []int{0, 3, 6} {
		a, b, c := received[start], received[start+1], received[start+2]
		if a.eid != b.eid || a.eid == c.eid || a.header.Thread != c.header.Thread {
			t.Fatalf("deduplication/grouping: %+v %+v %+v", a, b, c)
		}
	}
}

func TestHookToolsAutoDetectsExtensions(t *testing.T) {
	clearAgentOverrides(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, dir := range []string{".pi/agent", ".omp/agent"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	tools, skipped, err := hookTools("auto", false)
	if err != nil || len(skipped) != 0 || len(tools) != 2 || string(tools[0]) != "pi" || string(tools[1]) != "omp" {
		t.Fatalf("auto-detected tools: %v %q %v", tools, skipped, err)
	}
}

func TestHookToolsSharedAgentDirectory(t *testing.T) {
	clearAgentOverrides(t)
	t.Setenv("HOME", t.TempDir())
	shared := t.TempDir()
	t.Setenv("PI_CODING_AGENT_DIR", shared)
	if _, _, err := hookTools("pi,omp", false); err == nil || !strings.Contains(err.Error(), "share") {
		t.Fatalf("explicit shared directory must fail before partial installation: %v", err)
	}
	expectAutoSkipsOMP(t)
	for _, spec := range []string{"pi", "omp"} {
		if tools, _, err := hookTools(spec, false); err != nil || len(tools) != 1 {
			t.Fatalf("explicit single-agent setup: %s: %v %v", spec, tools, err)
		}
	}
	t.Setenv("PI_CODING_AGENT_DIR", "")
	for _, dir := range []string{".pi/agent", ".omp/agent"} {
		path := filepath.Join(os.Getenv("HOME"), dir)
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(shared, filepath.Join(path, "extensions")); err != nil {
			t.Fatal(err)
		}
	}
	expectAutoSkipsOMP(t)
}

// A shared Pi/OMP destination must not block pairing or upgrades in auto mode.
func expectAutoSkipsOMP(t *testing.T) {
	t.Helper()
	tools, skipped, err := hookTools("auto", false)
	if err != nil || len(tools) != 1 || tools[0] != installer.Pi || len(skipped) != 1 ||
		!strings.Contains(skipped[0], "Skipping OMP hook") || !strings.Contains(skipped[0], "share") {
		t.Fatalf("auto with shared destination: %v %q %v", tools, skipped, err)
	}
}

func TestHookToolsAutoSkipsInvalidOMPProfile(t *testing.T) {
	clearAgentOverrides(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.MkdirAll(filepath.Join(home, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OMP_PROFILE", "Work")
	tools, skipped, err := hookTools("auto", false)
	if err != nil || len(tools) != 1 || tools[0] != installer.ClaudeCode || len(skipped) != 0 {
		t.Fatalf("invalid OMP profile must not block auto: %v %q %v", tools, skipped, err)
	}
	if _, _, err := hookTools("omp", false); err == nil || !strings.Contains(err.Error(), "invalid OMP profile") {
		t.Fatalf("explicit OMP with invalid profile: %v", err)
	}
}

func TestSetupProjectAutoUsesUserAgentsInFreshRepo(t *testing.T) {
	clearAgentOverrides(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv(config.EnvPath, filepath.Join(home, "config.json"))
	if err := os.MkdirAll(filepath.Join(home, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Chdir(t.TempDir())
	var out, errb bytes.Buffer
	code := run([]string{"setup", "--no-pair", "--project"}, strings.NewReader(""), &out, &errb)
	if code != exitOK || !strings.Contains(out.String(), "Installed Claude Code hook in .claude") || errb.Len() != 0 {
		t.Fatalf("project auto in fresh repo: %d %q %q", code, out.String(), errb.String())
	}
	if _, err := os.Stat(filepath.Join(".claude", "settings.json")); err != nil {
		t.Fatal(err)
	}
}

func TestSetupAutoFindsProjectExtensions(t *testing.T) {
	clearAgentOverrides(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv(config.EnvPath, filepath.Join(home, "config.json"))
	t.Setenv("PI_CODING_AGENT_DIR", filepath.Join(home, "unused-agent-dir"))
	t.Chdir(t.TempDir())
	for _, dir := range []string{".pi", ".omp"} {
		if err := os.Mkdir(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	var out, errb bytes.Buffer
	code := run([]string{"setup", "--no-pair", "--project"}, strings.NewReader(""), &out, &errb)
	if code != exitOK || !strings.Contains(out.String(), "Installed Pi hook") ||
		!strings.Contains(out.String(), "Installed OMP hook") || errb.Len() != 0 {
		t.Fatalf("project auto: %d %q %q", code, out.String(), errb.String())
	}
}

func clearAgentOverrides(t *testing.T) {
	t.Helper()
	for _, key := range []string{"PI_CODING_AGENT_DIR", "PI_CONFIG_DIR", "OMP_PROFILE", "PI_PROFILE"} {
		t.Setenv(key, "")
	}
}

func TestStatusIncludesInstalledExtensionAgents(t *testing.T) {
	clearAgentOverrides(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv(config.EnvPath, filepath.Join(home, "config.json"))
	t.Chdir(t.TempDir())
	for _, tool := range []installer.Tool{installer.Pi, installer.OMP} {
		if _, err := installer.Install(tool, false); err != nil {
			t.Fatal(err)
		}
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/LATEST" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(version + "\n"))
	}))
	defer srv.Close()
	old := updateBase
	updateBase = srv.URL
	t.Cleanup(func() { updateBase = old })
	var out, errb bytes.Buffer
	if code := run([]string{"status"}, strings.NewReader(""), &out, &errb); code != exitOK || errb.Len() != 0 {
		t.Fatalf("status: %d %q %q", code, out.String(), errb.String())
	}
	for _, name := range []string{"Pi:", "OMP:"} {
		found := false
		for _, line := range strings.Split(out.String(), "\n") {
			if strings.HasPrefix(line, name) && strings.Contains(line, "user hook installed") {
				found = true
			}
		}
		if !found {
			t.Fatalf("missing installed %s status: %s", name, out.String())
		}
	}
}

// setupEnv points HOME and the config at temp dirs and stands up a TLS relay.
func setupEnv(t *testing.T) (home, bundle string) {
	t.Helper()
	clearAgentOverrides(t)
	home = t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv(config.EnvPath, filepath.Join(home, "config.json"))
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/push" {
			w.WriteHeader(http.StatusAccepted)
		}
	}))
	t.Cleanup(srv.Close)
	old := newClient
	newClient = func() *client.Client {
		c := client.New("test")
		c.HTTP = srv.Client()
		return c
	}
	t.Cleanup(func() { newClient = old })
	sk, _ := envelope.GeneratePrivateKey()
	p := &envelope.Pairing{Server: srv.URL, DeviceLabel: "phone", SenderCred: "rsc1.tok", PublicKey: sk.PublicKey().Bytes()}
	bundle, err := p.Encode()
	if err != nil {
		t.Fatal(err)
	}
	return home, bundle
}

func TestSetupNoHooks(t *testing.T) {
	home, bundle := setupEnv(t)
	var out, errb bytes.Buffer
	if code := run([]string{"setup", "--pair", bundle, "--hooks", "none"}, strings.NewReader(""), &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s %s", code, out.String(), errb.String())
	}
	if !strings.Contains(out.String(), "Paired with phone") || !strings.Contains(out.String(), "Sent to phone") {
		t.Fatal(out.String())
	}
	cfg, err := config.Load()
	if err != nil || len(cfg.Devices) != 1 || !cfg.Devices[0].HooksEnabled {
		t.Fatalf("%v %+v", err, cfg)
	}
	if _, err := os.Stat(filepath.Join(home, ".claude", "settings.json")); err == nil {
		t.Fatal("hook installed with --hooks none")
	}
	if strings.Contains(out.String(), "No agent config found") {
		t.Fatal("hint printed for --hooks none")
	}
}

func TestSetupClaudeCode(t *testing.T) {
	home, bundle := setupEnv(t)
	var out, errb bytes.Buffer
	// Bundle from stdin.
	if code := run([]string{"setup", "--hooks", "claude-code"}, strings.NewReader(bundle+"\n"), &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s %s", code, out.String(), errb.String())
	}
	if !strings.Contains(out.String(), "Installed Claude Code hook") {
		t.Fatal(out.String())
	}
	st, err := installer.GetStatus(installer.ClaudeCode, false)
	if err != nil || !st.Installed || st.Path != filepath.Join(home, ".claude", "settings.json") {
		t.Fatalf("%v %+v", err, st)
	}
	out.Reset()
	if code := run([]string{"setup", "--pair", bundle, "--hooks", "claude-code"}, strings.NewReader(""), &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	if !strings.Contains(out.String(), "Claude Code hook already installed") {
		t.Fatal(out.String())
	}
}

func TestSetupAuto(t *testing.T) {
	home, bundle := setupEnv(t)
	var out, errb bytes.Buffer
	if code := run([]string{"setup", "--pair", bundle}, strings.NewReader(""), &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	if !strings.Contains(out.String(), "No agent config found") {
		t.Fatal(out.String())
	}
	os.MkdirAll(filepath.Join(home, ".codex"), 0o700)
	out.Reset()
	if code := run([]string{"setup", "--pair", bundle}, strings.NewReader(""), &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	if !strings.Contains(out.String(), "Installed Codex hook") || !strings.Contains(out.String(), installer.CodexTrustNote) {
		t.Fatal(out.String())
	}
	if st, _ := installer.GetStatus(installer.ClaudeCode, false); st.Exists {
		t.Fatal("claude hook installed without ~/.claude")
	}
	if code := run([]string{"setup", "--pair", bundle, "--hooks", "vim"}, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	if code := run([]string{"setup", "--pair", "junk"}, strings.NewReader(""), &out, &errb); code != exitError {
		t.Fatal(code)
	}
}

func TestUpgradeCheck(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/LATEST" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte("9.9.9\n"))
	}))
	defer srv.Close()
	var out, errb bytes.Buffer
	if code := run([]string{"upgrade", "--check", "--server", srv.URL}, strings.NewReader(""), &out, &errb); code != exitOutdated {
		t.Fatal(code, errb.String())
	}
	if !strings.Contains(out.String(), "9.9.9 available") {
		t.Fatal(out.String())
	}
	out.Reset()
	if code := run([]string{"upgrade", "--check", "--server", srv.URL, "--version", version}, strings.NewReader(""), &out, &errb); code != exitOK {
		t.Fatal(code, errb.String())
	}
	if !strings.Contains(out.String(), "is current") {
		t.Fatal(out.String())
	}
	if code := run([]string{"upgrade", "extra"}, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	if s := updateStatus(srv.URL); !strings.Contains(s, "9.9.9 available") {
		t.Fatal(s)
	}
	if s := updateStatus("http://127.0.0.1:1"); s != "unknown" {
		t.Fatal(s)
	}
}
