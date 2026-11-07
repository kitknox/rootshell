package installer

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func setupHome(t *testing.T, tool Tool, fixture string) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	path, _ := Path(tool, false)
	if fixture != "" {
		raw, err := os.ReadFile(filepath.Join("testdata", fixture))
		if err != nil {
			t.Fatal(err)
		}
		os.MkdirAll(filepath.Dir(path), 0o700)
		if err := os.WriteFile(path, raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return path
}

func parse(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return doc
}

func TestInstallUninstallRoundTrip(t *testing.T) {
	for _, tc := range []struct {
		tool    Tool
		fixture string
	}{
		{ClaudeCode, "claude_settings.json"},
		{Codex, "codex_hooks.json"},
		{ClaudeCode, ""},
	} {
		t.Run(string(tc.tool)+"/"+tc.fixture, func(t *testing.T) {
			path := setupHome(t, tc.tool, tc.fixture)
			var before map[string]any
			if tc.fixture != "" {
				before = parse(t, path)
			}
			st, _ := GetStatus(tc.tool, false)
			if st.Installed || st.Exists != (tc.fixture != "") {
				t.Fatalf("pre-status %+v", st)
			}

			res, err := Install(tc.tool, false)
			if err != nil || !res.Changed {
				t.Fatalf("install: %v %+v", err, res)
			}
			if tc.fixture != "" {
				if _, err := os.Stat(path + ".bak"); err != nil {
					t.Fatal("no .bak")
				}
			}
			after := parse(t, path)
			for _, ev := range tc.tool.events() {
				groups := after["hooks"].(map[string]any)[ev].([]any)
				group := groups[len(groups)-1].(map[string]any)
				last := group["hooks"].([]any)[0].(map[string]any)
				wantAsync, wantTimeout := true, float64(10)
				if tc.tool == Codex {
					wantAsync = false
				}
				if last["command"] != tc.tool.command() || last["async"] != wantAsync || last["timeout"] != wantTimeout || last[TagKey] != Tag {
					t.Fatalf("%s: %+v", ev, last)
				}
				if m, _ := group["matcher"].(string); m != matchers[ev] {
					t.Fatalf("%s: matcher %q", ev, m)
				}
			}
			// Foreign entries and unrelated keys survive.
			if before != nil {
				for k, v := range before {
					if k == "hooks" {
						continue
					}
					if !reflect.DeepEqual(after[k], v) {
						t.Fatalf("key %s changed: %v -> %v", k, v, after[k])
					}
				}
				bh := before["hooks"].(map[string]any)
				ah := after["hooks"].(map[string]any)
				for ev, groups := range bh {
					if !reflect.DeepEqual(ah[ev].([]any)[:len(groups.([]any))], groups) {
						t.Fatalf("foreign %s groups changed", ev)
					}
				}
			}
			if st, _ := GetStatus(tc.tool, false); !st.Installed {
				t.Fatal("status not installed")
			}

			res, err = Install(tc.tool, false)
			if err != nil || res.Changed {
				t.Fatalf("second install: %v %+v", err, res)
			}
			if !reflect.DeepEqual(parse(t, path), after) {
				t.Fatal("idempotent install modified file")
			}

			res, err = Uninstall(tc.tool, false)
			if err != nil || !res.Changed {
				t.Fatalf("uninstall: %v %+v", err, res)
			}
			got := parse(t, path)
			if before == nil {
				if len(got) != 0 {
					t.Fatalf("expected empty doc, got %v", got)
				}
			} else if !reflect.DeepEqual(got, before) {
				t.Fatalf("round trip differs:\n%v\n%v", got, before)
			}
			res, _ = Uninstall(tc.tool, false)
			if res.Changed {
				t.Fatal("second uninstall changed file")
			}
		})
	}
}

func TestCodexInstallsOnlyStopHook(t *testing.T) {
	if got, want := Codex.events(), []string{"Stop"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("Codex events = %v, want %v", got, want)
	}
}

func TestCodexRefreshesAsyncHookForOneShotExit(t *testing.T) {
	path := setupHome(t, Codex, "")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	old := `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"rootshell-notify hook --agent codex","async":true,"timeout":10,"_rootshell":"push"},{"type":"command","command":"other","async":true,"timeout":10}]}]}}`
	if err := os.WriteFile(path, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	if st, err := GetStatus(Codex, false); err != nil || st.Installed || !st.Outdated {
		t.Fatalf("async Codex hook status: %+v %v", st, err)
	}
	res, err := Install(Codex, false)
	if err != nil || !res.Changed {
		t.Fatalf("async Codex hook must be refreshed: %+v %v", res, err)
	}
	doc := parse(t, path)
	hooks := doc["hooks"].(map[string]any)["Stop"].([]any)[0].(map[string]any)["hooks"].([]any)
	ours := hooks[0].(map[string]any)
	if ours["async"] != false || ours["timeout"] != float64(10) {
		t.Fatalf("one-shot exit must wait for the sender to hand off: %+v", ours)
	}
	foreign := hooks[1].(map[string]any)
	if foreign["async"] != true || foreign["timeout"] != float64(10) {
		t.Fatalf("unrelated hook changed: %+v", foreign)
	}
	if st, err := GetStatus(Codex, false); err != nil || !st.Installed {
		t.Fatalf("refreshed status: %+v %v", st, err)
	}
	if again, err := Install(Codex, false); err != nil || again.Changed {
		t.Fatalf("second refresh is not idempotent: %+v %v", again, err)
	}
}

func TestUninstallLeavesSharedGroup(t *testing.T) {
	doc := map[string]any{"hooks": map[string]any{
		"Stop": []any{map[string]any{"hooks": []any{
			map[string]any{"type": "command", "command": "other"},
			map[string]any{"type": "command", "command": ClaudeCode.command(), TagKey: Tag},
		}}},
		"Notification": []any{map[string]any{"hooks": []any{map[string]any{"type": "command", "command": ClaudeCode.command(), TagKey: Tag}}}},
		"PreToolUse": []any{
			map[string]any{"matcher": "Bash", "hooks": []any{map[string]any{"type": "command", "command": "./lint.sh"}}},
			ourEntry("PreToolUse", ClaudeCode),
		},
	}}
	if !uninstall(doc) {
		t.Fatal("no change")
	}
	hooks := doc["hooks"].(map[string]any)
	if _, ok := hooks["Notification"]; ok {
		t.Fatal("empty event array not removed")
	}
	if pre := hooks["PreToolUse"].([]any); len(pre) != 1 || pre[0].(map[string]any)["matcher"] != "Bash" {
		t.Fatalf("foreign PreToolUse group damaged: %v", pre)
	}
	inner := hooks["Stop"].([]any)[0].(map[string]any)["hooks"].([]any)
	if len(inner) != 1 || inner[0].(map[string]any)["command"] != "other" {
		t.Fatalf("shared group damaged: %v", inner)
	}
	if uninstall(map[string]any{"hooks": map[string]any{}}) {
		t.Fatal("empty hooks reported change")
	}
}

func untaggedHook() map[string]any {
	return map[string]any{"type": "command", "command": ClaudeCode.command(), "async": true, "timeout": 10}
}

func writeDoc(t *testing.T, path string, doc map[string]any) {
	t.Helper()
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

func oursIn(doc map[string]any, ev string) []map[string]any {
	var ours []map[string]any
	for _, g := range asList(hooksMap(doc)[ev]) {
		for _, h := range asList(g.(map[string]any)["hooks"]) {
			if isOurs(h) {
				ours = append(ours, h.(map[string]any))
			}
		}
	}
	return ours
}

func TestInstallAdoptsUntaggedAndDropsDuplicates(t *testing.T) {
	path := setupHome(t, ClaudeCode, "")
	tagged := ourEntry("Stop", ClaudeCode)
	writeDoc(t, path, map[string]any{"model": "x", "hooks": map[string]any{
		"Stop": []any{
			map[string]any{"hooks": []any{map[string]any{"type": "command", "command": "other"}, untaggedHook()}},
			map[string]any{"hooks": []any{untaggedHook()}},
			tagged,
		},
		"Notification": []any{
			map[string]any{"hooks": []any{untaggedHook()}},
			map[string]any{"hooks": []any{untaggedHook()}},
		},
		"PreToolUse": []any{map[string]any{"matcher": "AskUserQuestion", "hooks": []any{untaggedHook()}}},
	}})
	if st, err := GetStatus(ClaudeCode, false); err != nil || st.Installed || !st.Outdated {
		t.Fatalf("pre-status: %+v %v", st, err)
	}
	if res, err := Install(ClaudeCode, false); err != nil || !res.Changed {
		t.Fatalf("install: %+v %v", res, err)
	}
	doc := parse(t, path)
	for _, ev := range ClaudeCode.events() {
		ours := oursIn(doc, ev)
		if len(ours) != 1 || ours[0][TagKey] != Tag || ours[0]["command"] != ClaudeCode.command() {
			t.Fatalf("%s: want one tagged hook, got %v", ev, ours)
		}
	}
	stop := asList(hooksMap(doc)["Stop"])
	if len(stop) != 1 {
		t.Fatalf("emptied duplicate groups not dropped: %v", stop)
	}
	if inner := asList(stop[0].(map[string]any)["hooks"]); len(inner) != 2 || inner[0].(map[string]any)["command"] != "other" {
		t.Fatalf("shared group damaged: %v", inner)
	}
	if doc["model"] != "x" {
		t.Fatalf("unrelated key changed: %v", doc["model"])
	}
	if st, err := GetStatus(ClaudeCode, false); err != nil || !st.Installed {
		t.Fatalf("status after install: %+v %v", st, err)
	}
	if res, err := Install(ClaudeCode, false); err != nil || res.Changed {
		t.Fatalf("second install: %+v %v", res, err)
	}
}

func TestInstallKeepsCopiesUnderDifferentMatchers(t *testing.T) {
	path := setupHome(t, ClaudeCode, "")
	audit := map[string]any{"type": "command", "command": ClaudeCode.command() + "; ./audit.sh"}
	writeDoc(t, path, map[string]any{"hooks": map[string]any{
		"Notification": []any{
			map[string]any{"matcher": "permission_prompt", "hooks": []any{untaggedHook()}},
			map[string]any{"hooks": []any{untaggedHook(), audit}},
			map[string]any{"matcher": "", "hooks": []any{untaggedHook()}},
		},
	}})
	if res, err := Install(ClaudeCode, false); err != nil || !res.Changed {
		t.Fatalf("install: %+v %v", res, err)
	}
	doc := parse(t, path)
	groups := asList(hooksMap(doc)["Notification"])
	if len(groups) != 2 {
		t.Fatalf("want permission_prompt and catch-all groups, got %v", groups)
	}
	if m := groupMatcher(groups[0].(map[string]any)); m != "permission_prompt" {
		t.Fatalf("restricted group lost: %v", groups)
	}
	inner := asList(groups[1].(map[string]any)["hooks"])
	if len(inner) != 2 || inner[0].(map[string]any)[TagKey] != Tag || !reflect.DeepEqual(inner[1], audit) {
		t.Fatalf("catch-all group: %v", inner)
	}
	if st, err := GetStatus(ClaudeCode, false); err != nil || !st.Installed {
		t.Fatalf("status after install: %+v %v", st, err)
	}
	if res, err := Install(ClaudeCode, false); err != nil || res.Changed {
		t.Fatalf("second install: %+v %v", res, err)
	}
	if res, err := Uninstall(ClaudeCode, false); err != nil || !res.Changed {
		t.Fatalf("uninstall: %+v %v", res, err)
	}
	left := asList(hooksMap(parse(t, path))["Notification"])
	if len(left) != 1 || !reflect.DeepEqual(asList(left[0].(map[string]any)["hooks"]), []any{audit}) {
		t.Fatalf("uninstall must keep the user's suffixed command: %v", left)
	}
}

func TestUninstallRemovesUntaggedHooks(t *testing.T) {
	path := setupHome(t, ClaudeCode, "")
	writeDoc(t, path, map[string]any{"hooks": map[string]any{
		"Stop": []any{
			map[string]any{"hooks": []any{untaggedHook(), map[string]any{"type": "command", "command": "other"}}},
			map[string]any{"hooks": []any{untaggedHook()}},
		},
	}})
	if res, err := Uninstall(ClaudeCode, false); err != nil || !res.Changed {
		t.Fatalf("uninstall: %+v %v", res, err)
	}
	doc := parse(t, path)
	if ours := oursIn(doc, "Stop"); len(ours) != 0 {
		t.Fatalf("untagged hooks left: %v", ours)
	}
	if stop := asList(hooksMap(doc)["Stop"]); len(stop) != 1 {
		t.Fatalf("foreign hook lost: %v", stop)
	}
	if res, _ := Uninstall(ClaudeCode, false); res.Changed {
		t.Fatal("second uninstall changed file")
	}
}

func TestIsOursMatchesOnlyOurCommand(t *testing.T) {
	for cmd, want := range map[string]bool{
		"rootshell-notify hook --agent claude-code":             true,
		"rootshell-notify  hook   --agent codex":                true,
		"rootshell-notify hook":                                 true,
		"rootshell-notify hook --agent claude-code; ./audit.sh": false,
		"rootshell-notify hook --agent claude-code\n./audit.sh": false,
		"rootshell-notify hook --agent claude-code && ./a.sh":   false,
		"rootshell-notify hook --agent pi":                      false,
		"rootshell-notify hook-other":                           false,
		"rootshell-notify status":                               false,
		"echo rootshell-notify hook --agent codex":              false,
		"/usr/bin/rootshell-notify hook --agent claude-code":    false,
	} {
		if got := isOurs(map[string]any{"type": "command", "command": cmd}); got != want {
			t.Errorf("isOurs(%q) = %v, want %v", cmd, got, want)
		}
	}
}

func TestProjectPath(t *testing.T) {
	p, _ := Path(Codex, true)
	if p != filepath.Join(".codex", "hooks.json") {
		t.Fatal(p)
	}
	p, _ = Path(ClaudeCode, true)
	if p != filepath.Join(".claude", "settings.json") {
		t.Fatal(p)
	}
	if _, err := ParseTool("vim"); err == nil {
		t.Fatal("bad tool accepted")
	}
}
