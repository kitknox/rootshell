// rootshell-notify sends encrypted push notifications to paired rootshell devices.
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/kitknox/rootshell/push/client"
	"github.com/kitknox/rootshell/push/config"
	"github.com/kitknox/rootshell/push/envelope"
	"github.com/kitknox/rootshell/push/hook"
	"github.com/kitknox/rootshell/push/installer"
	"github.com/kitknox/rootshell/push/update"
)

var version = "dev"

// newClient is a var so tests can point it at a local relay.
var newClient = func() *client.Client { return client.New(version) }

const (
	exitOK       = 0
	exitError    = 1
	exitUsage    = 2
	exitOutdated = 3

	hookDeadline = 25 * time.Second
	maxHookInput = 1 << 20
)

const usage = `rootshell-notify - encrypted push notifications to rootshell

Usage:
  rootshell-notify <command> [options]

Commands:
  setup --pair <bundle>    Pair and install agent hooks in one step
  pair [bundle]            Pair with a device (bundle from arg, stdin, or prompt)
  devices [action label]   List devices or toggle agent hooks (toggle | on | off)
  unpair <label>           Remove a paired device
  test [label]             Send a test notification to one or all devices
  send --title T [opts]    Send a custom notification
  hook --agent TOOL        Agent hook entry point (reads JSON on stdin)
  install <tool>           Install a hook (claude-code | codex | pi | omp | hermes) [--project]
  uninstall <tool>         Remove the hook [--project] [--purge] [--yes]
  status                   Show hook and pairing status
  upgrade                  Download and install the latest release
  version                  Print version
  help                     Show this help

devices actions:
  devices                  List devices; toggle by number in a terminal
  devices toggle LABEL     Toggle agent hooks for a device
  devices on|off LABEL     Enable or disable agent hooks for a device

setup options:
  --pair BUNDLE            Pairing bundle (or pipe it on stdin)
  --no-pair                Skip pairing; only install or refresh agent hooks
  --hooks SPEC             auto (default) | claude-code,codex,pi,omp,hermes | none
  --project                Install project-local hooks or extensions

upgrade options:
  --check                  Only report; exit 3 if an update is available
  --version X.Y.Z          Install a specific version
  --hooks SPEC             Refresh hooks afterwards: auto (default) | claude-code,codex,pi,omp,hermes | none
  --server URL             Release server (default https://push.rootshell.com/releases)

send options:
  --title T                Notification title (required)
  --body B                 Notification body
  --status S               done | blocked | failed | info (default info)
  --device LABEL           Send to one device only
  --priority P             high | normal

Environment:
  ROOTSHELL_PUSH_CONFIG    Config file path (default ~/.config/rootshell-push/config.json)
  ROOTSHELL_PUSH_DEBUG=1   Also write hook errors to stderr
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "hook":
		return cmdHook(rest, stdin)
	case "setup":
		return cmdSetup(rest, stdin, stdout, stderr)
	case "pair":
		return cmdPair(rest, stdin, stdout, stderr)
	case "devices":
		return cmdDevices(rest, stdin, stdout, stderr, isTerminal(stdin) && isTerminal(stdout))
	case "unpair":
		return cmdUnpair(rest, stdout, stderr)
	case "test":
		return cmdTest(rest, stdout, stderr)
	case "send":
		return cmdSend(rest, stdout, stderr)
	case "install":
		return cmdInstall(rest, stdout, stderr)
	case "uninstall":
		return cmdUninstall(rest, stdin, stdout, stderr)
	case "status":
		return cmdStatus(stdout, stderr)
	case "upgrade":
		return cmdUpgrade(rest, stdout, stderr)
	case "version", "--version", "-v":
		fmt.Fprintln(stdout, "rootshell-notify", version)
		return exitOK
	case "help", "--help", "-h":
		fmt.Fprint(stdout, usage)
		return exitOK
	}
	fmt.Fprintf(stderr, "unknown command %q\n\n%s", cmd, usage)
	return exitUsage
}

// flags is a minimal parser: --k v, --k=v, and bare --k for names in bools.
type flags struct {
	vals  map[string]string
	args  []string
	bools map[string]bool
}

func parseFlags(args []string, bools ...string) (*flags, error) {
	f := &flags{vals: map[string]string{}, bools: map[string]bool{}}
	for _, b := range bools {
		f.bools[b] = true
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "--") || a == "--" {
			f.args = append(f.args, a)
			continue
		}
		name := strings.TrimPrefix(a, "--")
		if k, v, ok := strings.Cut(name, "="); ok {
			f.vals[k] = v
			continue
		}
		if f.bools[name] {
			f.vals[name] = "true"
			continue
		}
		if i+1 >= len(args) {
			return nil, fmt.Errorf("--%s requires a value", name)
		}
		f.vals[name] = args[i+1]
		i++
	}
	return f, nil
}

func (f *flags) has(k string) bool { _, ok := f.vals[k]; return ok }

func fail(stderr io.Writer, err error) int {
	fmt.Fprintln(stderr, "error:", err)
	return exitError
}

func loadConfig(stderr io.Writer) (*config.Config, int) {
	cfg, err := config.Load()
	if err != nil {
		return nil, fail(stderr, err)
	}
	warnSkipped(cfg, stderr)
	return cfg, exitOK
}

func warnSkipped(cfg *config.Config, w io.Writer) {
	if len(cfg.Skipped) > 0 {
		fmt.Fprintf(w, "warning: ignoring old pairing(s) %s; pair again with the current app\n", strings.Join(cfg.Skipped, ", "))
	}
}

// pushErr rewrites relay errors that need user action into instructions.
func pushErr(d *config.Device, err error) error {
	if errors.Is(err, client.ErrDeviceGone) {
		return fmt.Errorf("device %s is no longer registered; run `rootshell-notify unpair %s` and pair again", d.Label, d.Label)
	}
	return err
}

func hostName() string {
	h, _ := os.Hostname()
	h, _, _ = strings.Cut(h, ".")
	if h == "" {
		h = "this computer"
	}
	return h
}

func testHeader() *envelope.Header {
	return &envelope.Header{Kind: "generic", Status: "info", Title: "rootshell push", Body: "Pairing OK from " + hostName(), Route: currentRoute()}
}

// currentRoute identifies the pane this process runs in, so taps can return to it.
func currentRoute() *envelope.Route {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	cwd, _ := os.Getwd()
	return hook.Route(ctx, cwd)
}

func newEID() string {
	return fmt.Sprintf("cli-%d", time.Now().UnixNano())
}

// sendTo seals and pushes one header to each device, reporting per device.
func sendTo(ctx context.Context, c *client.Client, devs []config.Device, eid string, h *envelope.Header, opts client.Options, stdout, stderr io.Writer) int {
	code := exitOK
	for i := range devs {
		d := &devs[i]
		if err := pushOne(ctx, c, d, eid, h, opts); err != nil {
			fmt.Fprintf(stderr, "%s: %v\n", d.Label, pushErr(d, err))
			code = exitError
			continue
		}
		fmt.Fprintf(stdout, "Sent to %s.\n", d.Label)
	}
	return code
}

func pushOne(ctx context.Context, c *client.Client, d *config.Device, eid string, h *envelope.Header, opts client.Options) error {
	pk, err := d.Key()
	if err != nil {
		return err
	}
	hc := *h // Seal mutates V; keep the caller's copy pristine.
	env, err := envelope.Seal(pk, eid, &hc)
	if err != nil {
		return err
	}
	return c.Push(ctx, d, env, opts)
}

func isTerminal(v any) bool {
	f, ok := v.(*os.File)
	if !ok {
		return false
	}
	st, err := f.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}

func cmdPair(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	var bundle string
	switch {
	case len(args) > 0:
		bundle = args[0]
	case !isTerminal(stdin):
		b, _ := io.ReadAll(io.LimitReader(stdin, 64<<10))
		bundle = string(b)
	default:
		fmt.Fprint(stdout, "Paste the pairing bundle from rootshell (Settings > Notifications > Push Notifications > Pair a computer): ")
		line, _ := bufio.NewReader(stdin).ReadString('\n')
		bundle = line
	}
	p, err := envelope.DecodePairing(bundle)
	if err != nil {
		return fail(stderr, err)
	}
	cfg, code := loadConfig(stderr)
	if code != exitOK {
		return code
	}
	c := newClient()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	if err := c.Health(ctx, p.Server); err != nil {
		fmt.Fprintf(stderr, "warning: relay %s not reachable: %v\n", p.Server, err)
	}
	cancel()
	dev := config.DeviceFromPairing(p)
	if cfg.Add(dev) {
		fmt.Fprintf(stdout, "Updated existing pairing for %s.\n", dev.Label)
	}
	if err := cfg.Save(); err != nil {
		return fail(stderr, err)
	}
	fmt.Fprintf(stdout, "Paired with %s. Sending a test notification...\n", dev.Label)
	ctx, cancel = context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return sendTo(ctx, c, []config.Device{dev}, newEID(), testHeader(), client.Options{}, stdout, stderr)
}

func hookState(d config.Device) string {
	if d.HooksEnabled {
		return "on"
	}
	return "off"
}

func printDevices(cfg *config.Config, stdout io.Writer) {
	fmt.Fprintf(stdout, "    %-5s %-24s %-36s %s\n", "Hooks", "Device", "Relay", "Paired")
	for i, d := range cfg.Devices {
		fmt.Fprintf(stdout, "[%d] %-5s %-24s %-36s %s\n", i+1, hookState(d), d.Label, d.Server, d.AddedAt.Local().Format("2006-01-02 15:04"))
	}
}

func saveHookSetting(cfg *config.Config, d config.Device, changed bool, stdout, stderr io.Writer) int {
	if changed {
		if err := cfg.Save(); err != nil {
			return fail(stderr, err)
		}
		fmt.Fprintf(stdout, "%s: agent hooks %s.\n", d.Label, hookState(d))
	} else {
		fmt.Fprintf(stdout, "%s: agent hooks already %s.\n", d.Label, hookState(d))
	}
	return exitOK
}

func pickDevices(cfg *config.Config, stdin io.Reader, stdout, stderr io.Writer) int {
	scanner := bufio.NewScanner(stdin)
	for {
		fmt.Fprint(stdout, "Toggle device number (Enter to finish): ")
		if !scanner.Scan() {
			fmt.Fprintln(stdout)
			return exitOK
		}
		choice := strings.TrimSpace(scanner.Text())
		if choice == "" {
			return exitOK
		}
		n, err := strconv.Atoi(choice)
		if err != nil || n < 1 || n > len(cfg.Devices) {
			fmt.Fprintf(stderr, "Enter a number from 1 to %d.\n", len(cfg.Devices))
			continue
		}
		d := &cfg.Devices[n-1]
		d.HooksEnabled = !d.HooksEnabled
		if err := cfg.Save(); err != nil {
			return fail(stderr, err)
		}
		fmt.Fprintf(stdout, "%s: agent hooks %s.\n", d.Label, hookState(*d))
	}
}

func cmdDevices(args []string, stdin io.Reader, stdout, stderr io.Writer, interactive bool) int {
	if len(args) != 0 && len(args) != 2 {
		fmt.Fprintln(stderr, "usage: rootshell-notify devices [toggle|on|off <label>]")
		return exitUsage
	}
	if len(args) == 2 && args[0] != "toggle" && args[0] != "on" && args[0] != "off" {
		fmt.Fprintln(stderr, "usage: rootshell-notify devices [toggle|on|off <label>]")
		return exitUsage
	}
	cfg, code := loadConfig(stderr)
	if code != exitOK {
		return code
	}
	if len(args) == 2 {
		var d config.Device
		var changed bool
		var err error
		switch args[0] {
		case "toggle":
			d, err = cfg.ToggleHooks(args[1])
			changed = err == nil
		case "on":
			d, changed, err = cfg.SetHooksEnabled(args[1], true)
		case "off":
			d, changed, err = cfg.SetHooksEnabled(args[1], false)
		}
		if errors.Is(err, config.ErrNotFound) {
			return fail(stderr, fmt.Errorf("no device %q", args[1]))
		}
		if err != nil {
			return fail(stderr, err)
		}
		return saveHookSetting(cfg, d, changed, stdout, stderr)
	}
	if len(cfg.Devices) == 0 {
		fmt.Fprintln(stdout, "No paired devices. Run: rootshell-notify pair")
		return exitOK
	}
	printDevices(cfg, stdout)
	if interactive {
		return pickDevices(cfg, stdin, stdout, stderr)
	}
	return exitOK
}

func cmdUnpair(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: rootshell-notify unpair <label>")
		return exitUsage
	}
	cfg, code := loadConfig(stderr)
	if code != exitOK {
		return code
	}
	d, err := cfg.Remove(args[0])
	if err != nil {
		return fail(stderr, err)
	}
	if err := cfg.Save(); err != nil {
		return fail(stderr, err)
	}
	fmt.Fprintf(stdout, "Removed %s.\n", d.Label)
	return exitOK
}

func selectDevices(cfg *config.Config, label string, stderr io.Writer) ([]config.Device, int) {
	if len(cfg.Devices) == 0 {
		fmt.Fprintln(stderr, "No paired devices. Run: rootshell-notify pair")
		return nil, exitError
	}
	if label == "" {
		return cfg.Devices, exitOK
	}
	d, ok := cfg.Find(label)
	if !ok {
		return nil, fail(stderr, fmt.Errorf("no device %q", label))
	}
	return []config.Device{*d}, exitOK
}

func cmdTest(args []string, stdout, stderr io.Writer) int {
	cfg, code := loadConfig(stderr)
	if code != exitOK {
		return code
	}
	label := ""
	if len(args) > 0 {
		label = args[0]
	}
	devs, code := selectDevices(cfg, label, stderr)
	if code != exitOK {
		return code
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return sendTo(ctx, newClient(), devs, newEID(), testHeader(), client.Options{}, stdout, stderr)
}

func cmdSend(args []string, stdout, stderr io.Writer) int {
	f, err := parseFlags(args)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return exitUsage
	}
	title := f.vals["title"]
	if title == "" || len(f.args) > 0 {
		fmt.Fprintln(stderr, "usage: rootshell-notify send --title T [--body B] [--status S] [--device label] [--priority high|normal]")
		return exitUsage
	}
	status := f.vals["status"]
	if status == "" {
		status = "info"
	}
	switch status {
	case "done", "blocked", "failed", "info":
	default:
		fmt.Fprintf(stderr, "bad --status %q\n", status)
		return exitUsage
	}
	priority := f.vals["priority"]
	if priority != "" && priority != "high" && priority != "normal" {
		fmt.Fprintf(stderr, "bad --priority %q\n", priority)
		return exitUsage
	}
	if r := []rune(title); len(r) > envelope.MaxTitleLen {
		title = string(r[:envelope.MaxTitleLen])
	}
	body := f.vals["body"]
	if r := []rune(body); len(r) > envelope.MaxBodyLen {
		body = string(r[:envelope.MaxBodyLen-1]) + "…"
	}

	cfg, code := loadConfig(stderr)
	if code != exitOK {
		return code
	}
	devs, code := selectDevices(cfg, f.vals["device"], stderr)
	if code != exitOK {
		return code
	}
	h := &envelope.Header{Kind: "generic", Status: status, Title: title, Body: body, Route: currentRoute()}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	return sendTo(ctx, newClient(), devs, newEID(), h, client.Options{Priority: priority}, stdout, stderr)
}

func cmdHook(args []string, stdin io.Reader) int {
	// Fail-open: never block the agent, never write to stdout.
	logger := log.New(io.Discard, "", log.LstdFlags)
	if f, err := config.OpenLog(); err == nil {
		defer f.Close()
		var w io.Writer = f
		if os.Getenv("ROOTSHELL_PUSH_DEBUG") == "1" {
			w = io.MultiWriter(f, os.Stderr)
		}
		logger.SetOutput(w)
	} else if os.Getenv("ROOTSHELL_PUSH_DEBUG") == "1" {
		logger.SetOutput(os.Stderr)
	}
	defer func() {
		if r := recover(); r != nil {
			logger.Printf("panic: %v", r)
		}
	}()
	f, err := parseFlags(args)
	if err != nil || len(f.args) != 0 || !f.has("agent") {
		logger.Printf("usage: rootshell-notify hook --agent claude-code|codex|pi|omp|hermes")
		return exitOK
	}
	agent, err := hook.ParseAgent(f.vals["agent"])
	if err != nil {
		logger.Printf("agent: %v", err)
		return exitOK
	}

	cfg, err := config.Load()
	if err != nil {
		logger.Printf("config: %v", err)
		return exitOK
	}
	if len(cfg.Skipped) > 0 {
		logger.Printf("ignoring old pairing(s) %s; pair again with the current app", strings.Join(cfg.Skipped, ", "))
	}
	devices := cfg.HookDevices()
	if len(devices) == 0 {
		return exitOK
	}
	data, err := io.ReadAll(io.LimitReader(stdin, maxHookInput))
	if err != nil {
		logger.Printf("stdin: %v", err)
		return exitOK
	}
	ev, err := hook.Parse(agent, data)
	if errors.Is(err, hook.ErrIgnore) {
		return exitOK
	}
	if err != nil {
		logger.Printf("parse: %v", err)
		return exitOK
	}
	// Codex waits for this hook so one-shot exec keeps its notification;
	// a detached child does the delivery so interactive turns never wait.
	if agent == hook.Codex && os.Getenv(hookChildEnv) == "" {
		err := detachHook(args, data)
		if err == nil {
			return exitOK
		}
		logger.Printf("detach: %v; delivering inline", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), hookDeadline)
	defer cancel()
	h := ev.Header(hook.Route(ctx, ev.Cwd))
	c := newClient()
	for i := range devices {
		d := &devices[i]
		if err := pushOne(ctx, c, d, ev.EID, h, client.Options{}); err != nil {
			logger.Printf("%s %s: push to %s: %v", ev.Agent, ev.Status, d.Label, pushErr(d, err))
		}
	}
	return exitOK
}

func toolArg(args []string, stderr io.Writer, bools ...string) (installer.Tool, *flags, int) {
	f, err := parseFlags(args, append([]string{"project"}, bools...)...)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return "", nil, exitUsage
	}
	if len(f.args) != 1 {
		fmt.Fprintln(stderr, "usage: rootshell-notify install|uninstall claude-code|codex|pi|omp|hermes [--project]")
		return "", nil, exitUsage
	}
	t, err := installer.ParseTool(f.args[0])
	if err != nil {
		fmt.Fprintln(stderr, err)
		return "", nil, exitUsage
	}
	return t, f, exitOK
}

func cmdInstall(args []string, stdout, stderr io.Writer) int {
	t, f, code := toolArg(args, stderr)
	if code != exitOK {
		return code
	}
	if err := installHook(t, f.has("project"), stdout); err != nil {
		return fail(stderr, err)
	}
	warnPath(stdout)
	return exitOK
}

func installHook(t installer.Tool, project bool, stdout io.Writer) error {
	res, err := installer.Install(t, project)
	if err != nil {
		return err
	}
	if !res.Changed {
		fmt.Fprintf(stdout, "%s hook already installed in %s\n", t.Name(), res.Path)
	} else {
		fmt.Fprintf(stdout, "Installed %s hook in %s\n", t.Name(), res.Path)
	}
	if t == installer.Codex {
		fmt.Fprintln(stdout, installer.CodexTrustNote)
	} else if t == installer.Hermes {
		fmt.Fprintln(stdout, installer.HermesEnableNote)
	}
	return nil
}

func projectFlag(project bool) string {
	if project {
		return " --project"
	}
	return ""
}

func warnPath(stdout io.Writer) {
	if _, ok := installer.OnPath(); !ok {
		fmt.Fprintln(stdout, "warning: rootshell-notify is not on PATH; the hook will not run until it is")
	}
}

// hookTools resolves a --hooks spec. Auto picks tools whose user (or, with
// --project, project) config dir exists and skips any it cannot install,
// returning why; an explicit spec fails instead.
func hookTools(spec string, project bool) ([]installer.Tool, []string, error) {
	var candidates []installer.Tool
	auto := spec == "" || spec == "auto"
	switch {
	case spec == "none":
		return nil, nil, nil
	case auto:
		for _, t := range installer.Tools {
			if agentPresent(t, project) {
				candidates = append(candidates, t)
			}
		}
	default:
		for _, s := range strings.Split(spec, ",") {
			t, err := installer.ParseTool(strings.TrimSpace(s))
			if err != nil {
				return nil, nil, err
			}
			candidates = append(candidates, t)
		}
	}
	var tools []installer.Tool
	var skipped []string
	paths := map[string]installer.Tool{}
	for _, t := range candidates {
		path, err := installer.Path(t, project)
		if err == nil {
			path, err = canonicalPath(path)
		}
		if err == nil {
			if previous, ok := paths[path]; ok && previous != t {
				err = fmt.Errorf("%s and %s share extension destination %s; use separate agent directories or select only one agent with --hooks", previous, t, path)
			}
		}
		if err != nil {
			if !auto {
				return nil, nil, err
			}
			skipped = append(skipped, fmt.Sprintf("Skipping %s hook: %v", t.Name(), err))
			continue
		}
		paths[path] = t
		tools = append(tools, t)
	}
	return tools, skipped, nil
}

func agentPresent(t installer.Tool, project bool) bool {
	scopes := []bool{false}
	if project {
		scopes = append(scopes, true)
	}
	for _, scope := range scopes {
		dir, err := installer.ConfigDir(t, scope)
		if err != nil {
			continue
		}
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			return true
		}
	}
	return false
}

// canonicalPath resolves symlinks in the longest existing prefix of path.
func canonicalPath(path string) (string, error) {
	path, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	rest := ""
	for dir := path; ; dir = filepath.Dir(dir) {
		if resolved, err := filepath.EvalSymlinks(dir); err == nil {
			return filepath.Join(resolved, rest), nil
		}
		if filepath.Dir(dir) == dir {
			return path, nil
		}
		rest = filepath.Join(filepath.Base(dir), rest)
	}
}

func cmdSetup(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	f, err := parseFlags(args, "project", "no-pair")
	if err != nil || len(f.args) > 0 {
		if err != nil {
			fmt.Fprintln(stderr, err)
		}
		fmt.Fprintln(stderr, "usage: rootshell-notify setup (--pair <bundle> | --no-pair) [--hooks auto|claude-code,codex,pi,omp,hermes|none] [--project]")
		return exitUsage
	}
	spec := f.vals["hooks"]
	tools, skipped, err := hookTools(spec, f.has("project"))
	if err != nil {
		fmt.Fprintln(stderr, err)
		return exitUsage
	}
	if f.has("no-pair") {
		// Hooks only: refresh hook entries after an upgrade, keeping pairings.
		if cfg, code := loadConfig(stderr); code != exitOK {
			return code
		} else if len(cfg.Devices) == 0 {
			fmt.Fprintln(stdout, "No paired devices yet; pair from rootshell (Settings > Notifications > Push Notifications).")
		}
	} else {
		var pairArgs []string
		if f.has("pair") {
			pairArgs = []string{f.vals["pair"]}
		}
		if code := cmdPair(pairArgs, stdin, stdout, stderr); code != exitOK {
			return code
		}
	}
	if spec == "none" {
		return exitOK
	}
	refreshHooks(tools, skipped, f.has("project"), stdout, stderr)
	return exitOK
}

func refreshHooks(tools []installer.Tool, skipped []string, project bool, stdout, stderr io.Writer) {
	for _, note := range skipped {
		fmt.Fprintln(stdout, note)
	}
	if len(tools) == 0 {
		fmt.Fprintln(stdout, "No agent config found; run `rootshell-notify install <claude-code|codex|pi|omp|hermes>` later.")
		return
	}
	for _, t := range tools {
		if err := installHook(t, project, stdout); err != nil {
			fmt.Fprintf(stderr, "error: install %s hook: %v\n", t, err)
		}
	}
	warnPath(stdout)
}

func cmdUpgrade(args []string, stdout, stderr io.Writer) int {
	f, err := parseFlags(args, "check")
	if err != nil || len(f.args) > 0 {
		if err != nil {
			fmt.Fprintln(stderr, err)
		}
		fmt.Fprintln(stderr, "usage: rootshell-notify upgrade [--check] [--version x.y.z] [--hooks auto|claude-code,codex,pi,omp,hermes|none] [--server URL]")
		return exitUsage
	}
	spec := f.vals["hooks"]
	tools, skipped, err := hookTools(spec, false)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return exitUsage
	}
	base := f.vals["server"]
	if base == "" {
		base = update.DefaultBase
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	target := f.vals["version"]
	if target == "" {
		if target, err = update.Latest(ctx, base); err != nil {
			return fail(stderr, fmt.Errorf("check for updates: %w", err))
		}
	}
	if f.has("check") {
		if target == version {
			fmt.Fprintf(stdout, "rootshell-notify %s is current\n", version)
			return exitOK
		}
		fmt.Fprintf(stdout, "rootshell-notify %s available (installed %s)\n", target, version)
		return exitOutdated
	}
	if target == version {
		fmt.Fprintf(stdout, "rootshell-notify %s is current\n", version)
		return exitOK
	}

	exe, err := os.Executable()
	if err == nil {
		exe, err = filepath.EvalSymlinks(exe)
	}
	if err != nil {
		return fail(stderr, fmt.Errorf("locate binary: %w", err))
	}
	fmt.Fprintf(stdout, "Downloading rootshell-notify %s (%s/%s)...\n", target, runtime.GOOS, runtime.GOARCH)
	data, err := update.Download(ctx, base, target, runtime.GOOS, runtime.GOARCH)
	if err != nil {
		return fail(stderr, err)
	}
	if err := update.Replace(exe, data); err != nil {
		return fail(stderr, err)
	}
	fmt.Fprintf(stdout, "Installed %s\n", exe)

	vctx, vcancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer vcancel()
	out, err := exec.CommandContext(vctx, exe, "version").Output()
	if err != nil {
		return fail(stderr, fmt.Errorf("new binary failed to run: %w", err))
	}
	fmt.Fprintf(stdout, "Verified: %s\n", strings.TrimSpace(string(out)))

	if spec != "none" {
		refreshHooks(tools, skipped, false, stdout, stderr)
	}
	return exitOK
}

func cmdUninstall(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	t, f, code := toolArg(args, stderr, "purge", "yes")
	if code != exitOK {
		return code
	}
	res, err := installer.Uninstall(t, f.has("project"))
	if err != nil {
		return fail(stderr, err)
	}
	if res.Changed {
		fmt.Fprintf(stdout, "Removed %s hook from %s\n", t.Name(), res.Path)
	} else {
		fmt.Fprintf(stdout, "%s hook was not installed in %s\n", t.Name(), res.Path)
	}
	if !f.has("purge") {
		return exitOK
	}
	dir := config.Dir()
	if !f.has("yes") {
		fmt.Fprintf(stdout, "Delete %s (pairings and logs)? [y/N] ", dir)
		line, _ := bufio.NewReader(stdin).ReadString('\n')
		if s := strings.ToLower(strings.TrimSpace(line)); s != "y" && s != "yes" {
			fmt.Fprintln(stdout, "Kept.")
			return exitOK
		}
	}
	if err := os.RemoveAll(dir); err != nil {
		return fail(stderr, err)
	}
	fmt.Fprintf(stdout, "Deleted %s\n", dir)
	return exitOK
}

// updateBase is a var so tests can point status at a local server.
var updateBase = update.DefaultBase

// updateStatus is best-effort: any failure reports unknown.
func updateStatus(base string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	latest, err := update.Latest(ctx, base)
	switch {
	case err != nil:
		return "unknown"
	case latest == version:
		return "current"
	default:
		return latest + " available (run rootshell-notify upgrade)"
	}
}

func cmdStatus(stdout, stderr io.Writer) int {
	fmt.Fprintln(stdout, "rootshell-notify", version)
	if p, ok := installer.OnPath(); ok {
		fmt.Fprintln(stdout, "binary:      on PATH at", p)
	} else {
		fmt.Fprintln(stdout, "binary:      NOT on PATH (hooks will not run)")
	}
	cfg, err := config.Load()
	switch {
	case err != nil:
		fmt.Fprintf(stdout, "config:      %s (error: %v)\n", config.Path(), err)
	case len(cfg.Devices) == 0:
		fmt.Fprintf(stdout, "config:      %s (no paired devices)\n", config.Path())
	default:
		fmt.Fprintf(stdout, "config:      %s (%d device(s))\n", config.Path(), len(cfg.Devices))
		for _, d := range cfg.Devices {
			fmt.Fprintf(stdout, "  - hooks=%-3s %s  %s\n", hookState(d), d.Label, d.Server)
		}
	}
	fmt.Fprintf(stdout, "log:         %s\n", config.LogPath())
	fmt.Fprintf(stdout, "update:      %s\n", updateStatus(updateBase))
	code := exitOK
	for _, t := range installer.Tools {
		for _, project := range []bool{false, true} {
			st, err := installer.GetStatus(t, project)
			scope := "user"
			if project {
				scope = "project"
				if !st.Exists {
					continue
				}
			}
			switch {
			case err != nil:
				fmt.Fprintf(stdout, "%-12s %s hook: error reading %s: %v\n", t.Name()+":", scope, st.Path, err)
				code = exitError
			case st.Installed:
				fmt.Fprintf(stdout, "%-12s %s hook installed (%s)\n", t.Name()+":", scope, st.Path)
			case st.Outdated:
				fmt.Fprintf(stdout, "%-12s %s hook outdated (%s); run `rootshell-notify install %s`%s\n", t.Name()+":", scope, st.Path, t, projectFlag(project))
			default:
				fmt.Fprintf(stdout, "%-12s %s hook not installed (%s)\n", t.Name()+":", scope, st.Path)
			}
		}
	}
	return code
}
