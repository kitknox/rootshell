// Package installer installs rootshell-notify hooks and agent extensions,
// preserving configuration and extensions belonging to the user.
package installer

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/kitknox/rootshell/push/config"
)

const (
	Tag         = "push"
	TagKey      = "_rootshell"
	Command     = "rootshell-notify hook"
	HookTimeout = 10

	CodexTrustNote = "Codex requires you to trust new hooks: run `codex` then `/hooks`, review the rootshell entry and mark it trusted."
)

type Tool string

const (
	ClaudeCode Tool = "claude-code"
	Codex      Tool = "codex"
	Pi         Tool = "pi"
	OMP        Tool = "omp"
	Hermes     Tool = "hermes"
)

var Tools = []Tool{ClaudeCode, Codex, Pi, OMP, Hermes}

func ParseTool(s string) (Tool, error) {
	switch Tool(s) {
	case ClaudeCode, Codex, Pi, OMP, Hermes:
		return Tool(s), nil
	}
	return "", fmt.Errorf("unknown tool %q (want claude-code, codex, pi, omp or hermes)", s)
}

func (t Tool) Name() string {
	switch t {
	case Codex:
		return "Codex"
	case Pi:
		return "Pi"
	case OMP:
		return "OMP"
	case Hermes:
		return "Hermes"
	}
	return "Claude Code"
}

func (t Tool) events() []string {
	if t == Codex {
		return []string{"Stop"}
	}
	return []string{"Stop", "Notification", "PreToolUse"}
}

func (t Tool) command() string {
	return Command + " --agent " + string(t)
}

func (t Tool) hookAsync() bool {
	// Codex exec tears down async hooks on exit. The synchronous sender only
	// hands the payload to a detached child, so Codex barely waits.
	return t != Codex
}

// matchers restricts an event to specific tools; PreToolUse only fires for questions.
var matchers = map[string]string{"PreToolUse": "AskUserQuestion"}

// Path returns the hook file for the tool, project-local when project is set.
func Path(t Tool, project bool) (string, error) {
	dir, err := ConfigDir(t, project)
	if err != nil {
		return "", err
	}
	switch t {
	case Hermes:
		return filepath.Join(dir, "plugins", "rootshell-push", "__init__.py"), nil
	case Pi, OMP:
		return filepath.Join(dir, "extensions", "rootshell-push.ts"), nil
	case Codex:
		return filepath.Join(dir, "hooks.json"), nil
	default:
		return filepath.Join(dir, "settings.json"), nil
	}
}

type Result struct {
	Path    string
	Changed bool
}

type Status struct {
	Tool      Tool
	Path      string
	Exists    bool
	Installed bool
	// Outdated means a managed hook is present but differs from this version's.
	Outdated bool
}

func Install(t Tool, project bool) (Result, error) {
	if t == Hermes {
		return applyHermes(project, false)
	}
	if isExtension(t) {
		return applyExtension(t, project, false)
	}
	return apply(t, project, func(doc map[string]any) bool { return install(doc, t) })
}

func Uninstall(t Tool, project bool) (Result, error) {
	if t == Hermes {
		return applyHermes(project, true)
	}
	if isExtension(t) {
		return applyExtension(t, project, true)
	}
	return apply(t, project, uninstall)
}

func GetStatus(t Tool, project bool) (Status, error) {
	path, err := Path(t, project)
	if err != nil {
		return Status{}, err
	}
	st := Status{Tool: t, Path: path}
	if t == Hermes {
		if err := checkHermesPath(path); err != nil {
			st.Exists = true
			return st, err
		}
		current, owned := true, true
		for _, file := range hermesFiles(path) {
			raw, exists, err := readExtension(file.path)
			if err != nil {
				return st, err
			}
			st.Exists = st.Exists || exists
			if !exists || !bytes.Equal(raw, file.source) {
				current = false
			}
			if exists && !ownedHermesFile(file, raw) {
				owned = false
			}
		}
		st.Installed = current
		st.Outdated = !current && st.Exists && owned
		return st, nil
	}
	if isExtension(t) {
		raw, exists, err := readExtension(path)
		st.Exists = exists
		st.Installed = exists && bytes.Equal(raw, extensionSource(t))
		st.Outdated = exists && !st.Installed && ownedExtension(raw, t)
		return st, err
	}
	doc, exists, err := load(path)
	if err != nil {
		return st, err
	}
	st.Exists = exists
	st.Installed = installed(doc, t)
	st.Outdated = !st.Installed && hasOurs(doc)
	return st, nil
}

// OnPath reports whether rootshell-notify resolves on $PATH.
func OnPath() (string, bool) {
	p, err := exec.LookPath("rootshell-notify")
	return p, err == nil
}

func apply(t Tool, project bool, mutate func(map[string]any) bool) (Result, error) {
	path, err := Path(t, project)
	if err != nil {
		return Result{}, err
	}
	doc, exists, err := load(path)
	if err != nil {
		return Result{Path: path}, err
	}
	original, _ := os.ReadFile(path)
	if !mutate(doc) {
		return Result{Path: path}, nil
	}
	if exists {
		if _, err := os.Stat(path + ".bak"); errors.Is(err, os.ErrNotExist) {
			if err := config.WriteFileAtomic(path+".bak", original, 0o600); err != nil {
				return Result{Path: path}, err
			}
		}
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return Result{Path: path}, err
	}
	perm := os.FileMode(0o600)
	if st, err := os.Stat(path); err == nil {
		perm = st.Mode().Perm()
	}
	if err := config.WriteFileAtomic(path, buf.Bytes(), perm); err != nil {
		return Result{Path: path}, err
	}
	return Result{Path: path, Changed: true}, nil
}

func load(path string) (map[string]any, bool, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{}, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	doc := map[string]any{}
	if len(bytes.TrimSpace(raw)) == 0 {
		return doc, true, nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&doc); err != nil {
		return nil, true, fmt.Errorf("%s: %w", path, err)
	}
	return doc, true, nil
}

func ourEntry(event string, t Tool) map[string]any {
	g := map[string]any{
		"hooks": []any{map[string]any{
			"type": "command", "command": t.command(), "async": t.hookAsync(), "timeout": HookTimeout, TagKey: Tag,
		}},
	}
	if m := matchers[event]; m != "" {
		g["matcher"] = m
	}
	return g
}

func isOurs(h any) bool {
	m, ok := h.(map[string]any)
	return ok && m[TagKey] == Tag
}

func groupHasOurs(g any) bool {
	m, ok := g.(map[string]any)
	if !ok {
		return false
	}
	inner, _ := m["hooks"].([]any)
	for _, h := range inner {
		if isOurs(h) {
			return true
		}
	}
	return false
}

func hookIsCurrent(h any, t Tool) bool {
	m, ok := h.(map[string]any)
	return ok && isOurs(m) && m["type"] == "command" && m["command"] == t.command() && m["async"] == t.hookAsync() && timeoutIsCurrent(m["timeout"], HookTimeout)
}

func timeoutIsCurrent(v any, want int) bool {
	switch n := v.(type) {
	case int:
		return n == want
	case float64:
		return n == float64(want)
	case json.Number:
		i, err := n.Int64()
		return err == nil && i == int64(want)
	default:
		return false
	}
}

func groupHasCurrent(g any, t Tool) bool {
	m, ok := g.(map[string]any)
	if !ok {
		return false
	}
	for _, h := range asList(m["hooks"]) {
		if hookIsCurrent(h, t) {
			return true
		}
	}
	return false
}

func hooksMap(doc map[string]any) map[string]any {
	m, _ := doc["hooks"].(map[string]any)
	return m
}

func installed(doc map[string]any, t Tool) bool {
	hooks := hooksMap(doc)
	if hooks == nil {
		return false
	}
	for _, ev := range t.events() {
		found := false
		for _, g := range asList(hooks[ev]) {
			if groupHasCurrent(g, t) {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}

func hasOurs(doc map[string]any) bool {
	for _, v := range hooksMap(doc) {
		for _, g := range asList(v) {
			if groupHasOurs(g) {
				return true
			}
		}
	}
	return false
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

func install(doc map[string]any, t Tool) bool {
	hooks := hooksMap(doc)
	if hooks == nil {
		hooks = map[string]any{}
	}
	changed := false
	for _, ev := range t.events() {
		groups := asList(hooks[ev])
		has := false
		for _, g := range groups {
			m, ok := g.(map[string]any)
			if !ok {
				continue
			}
			for _, h := range asList(m["hooks"]) {
				hm, ok := h.(map[string]any)
				if !ok || !isOurs(hm) {
					continue
				}
				has = true
				if !hookIsCurrent(hm, t) {
					hm["type"] = "command"
					hm["command"] = t.command()
					hm["async"] = t.hookAsync()
					hm["timeout"] = HookTimeout
					changed = true
				}
			}
		}
		if has {
			continue
		}
		hooks[ev] = append(groups, ourEntry(ev, t))
		changed = true
	}
	if changed {
		doc["hooks"] = hooks
	}
	return changed
}

func uninstall(doc map[string]any) bool {
	hooks := hooksMap(doc)
	if hooks == nil {
		return false
	}
	changed := false
	for ev, v := range hooks {
		groups, ok := v.([]any)
		if !ok {
			continue
		}
		var kept []any
		touched := false
		for _, g := range groups {
			m, ok := g.(map[string]any)
			if !ok || !groupHasOurs(g) {
				kept = append(kept, g)
				continue
			}
			changed, touched = true, true
			var inner []any
			for _, h := range asList(m["hooks"]) {
				if !isOurs(h) {
					inner = append(inner, h)
				}
			}
			if len(inner) > 0 {
				m["hooks"] = inner
				kept = append(kept, m)
			}
		}
		if !touched {
			continue
		}
		if len(kept) == 0 {
			delete(hooks, ev)
		} else {
			hooks[ev] = kept
		}
	}
	if changed && len(hooks) == 0 {
		delete(doc, "hooks")
	}
	return changed
}
