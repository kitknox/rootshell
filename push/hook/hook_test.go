package hook

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestParse(t *testing.T) {
	cases := []struct {
		file      string
		agent     Agent
		wantAgent string
		status    string
		title     string
		body      string
		ignore    bool
	}{
		{"claude_stop.json", ClaudeCode, "claude-code", "done", "Claude Code · rootshell", "I refactored the parser and all tests pass. See the PR for details. Next I would suggest reviewing parser.go.", false},
		{"claude_stop_active.json", ClaudeCode, "", "", "", "", true},
		{"claude_permission.json", ClaudeCode, "claude-code", "blocked", "Claude Code · rootshell", "Claude needs your permission to use Bash", false},
		{"claude_idle.json", ClaudeCode, "claude-code", "done", "Claude Code · rootshell", "Claude is waiting for your input", false},
		{"claude_notification_other.json", ClaudeCode, "", "", "", "", true},
		{"claude_subagent_stop.json", ClaudeCode, "", "", "", "", true},
		{"claude_ask.json", ClaudeCode, "claude-code", "blocked", "Claude Code · rootshell", "Which framework should I use?", false},
		{"claude_ask_empty.json", ClaudeCode, "claude-code", "blocked", "Claude Code · rootshell", "Claude Code is asking you a question", false},
		{"claude_pretooluse_other.json", ClaudeCode, "", "", "", "", true},
		{"codex_permission_command.json", Codex, "", "", "", "", true},
		{"codex_permission_tool.json", Codex, "", "", "", "", true},
		{"codex_permission_bare.json", Codex, "", "", "", "", true},
		{"codex_other_event.json", Codex, "", "", "", "", true},
		{"codex_stop.json", Codex, "codex", "done", "Codex · app", "Deployed the fix. Token=[redacted] was rotated.", false},
		{"codex_legacy.json", Codex, "codex", "done", "Codex · app", "完成了所有的修改。请检查结果！然后继续。", false},
		{"codex_nocwd.json", Codex, "codex", "done", "Codex", "", false},
	}
	for _, tc := range cases {
		e, err := Parse(tc.agent, fixture(t, tc.file))
		if tc.ignore {
			if !errors.Is(err, ErrIgnore) {
				t.Errorf("%s: want ErrIgnore, got %v %+v", tc.file, err, e)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", tc.file, err)
			continue
		}
		if e.Agent != tc.wantAgent || e.Status != tc.status || e.Title != tc.title || e.Body != tc.body {
			t.Errorf("%s: got %+v", tc.file, e)
		}
		if len(e.Thread) != 16 || len(e.EID) != 24 {
			t.Errorf("%s: ids %q %q", tc.file, e.Thread, e.EID)
		}
	}
	if _, err := Parse(Agent("unknown"), []byte(`{"foo":1}`)); err == nil || errors.Is(err, ErrIgnore) {
		t.Errorf("unknown agent: %v", err)
	}
	if _, err := Parse(ClaudeCode, []byte(`nope`)); err == nil {
		t.Error("bad json accepted")
	}
}

func TestIDsStableAndDistinct(t *testing.T) {
	a, _ := Parse(ClaudeCode, fixture(t, "claude_stop.json"))
	b, _ := Parse(ClaudeCode, fixture(t, "claude_stop.json"))
	c, _ := Parse(ClaudeCode, fixture(t, "claude_permission.json"))
	if a.EID != b.EID || a.Thread != b.Thread {
		t.Fatal("not deterministic")
	}
	if a.Thread != c.Thread {
		t.Fatal("same session must share thread")
	}
	if a.EID == c.EID {
		t.Fatal("different events must differ")
	}
	d, _ := Parse(Codex, fixture(t, "codex_stop.json"))
	if d.Thread == a.Thread {
		t.Fatal("agents must not collide")
	}
	// Question ids follow the tool_input, not just the session.
	q1, _ := Parse(ClaudeCode, fixture(t, "claude_ask.json"))
	q2, _ := Parse(ClaudeCode, []byte(strings.Replace(string(fixture(t, "claude_ask.json")), "Which framework", "Which database", 1)))
	if q1.EID == q2.EID || q1.Thread != q2.Thread || q1.EID == c.EID {
		t.Fatalf("question ids %q %q", q1.EID, q2.EID)
	}
}

func TestTranscriptMtimeSalt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "t.jsonl")
	os.WriteFile(path, []byte("x"), 0o600)
	payload := strings.Replace(string(fixture(t, "claude_stop.json")), "/nonexistent/transcript.jsonl", path, 1)
	a, err := Parse(ClaudeCode, []byte(payload))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := Parse(ClaudeCode, fixture(t, "claude_stop.json"))
	if a.EID == b.EID {
		t.Fatal("mtime salt not used")
	}
}

func TestSummarize(t *testing.T) {
	long := strings.Repeat("word ", 60)
	cases := []struct{ in, want string }{
		{"Hello **world**.", "Hello world."},
		{"See [docs](https://x.y/z) and https://example.com/path now", "See docs and now"},
		{"Run `go test` first.\n\n```sh\nsecret\n```\nThen done.", "Run go test first. Then done."},
		{"# Title\n- item one\n- item two", "Title item one item two"},
		{"Unterminated ```code block goes on forever", "Unterminated"},
		{"First sentence is here. " + long, "First sentence is here."},
		{"Erste Aussage! " + long, "Erste Aussage!"},
		{"日本語の文です。" + strings.Repeat("あ", 300), "日本語の文です。"},
		{long, strings.TrimSpace(strings.Repeat("word ", 40)) + "…"},
		{strings.Repeat("x", 250), strings.Repeat("x", 199) + "…"},
		{"émoji 🚀 ünïcode", "émoji 🚀 ünïcode"},
		{"", ""},
	}
	for _, tc := range cases {
		got := Summarize(tc.in, MaxBody)
		if got != tc.want {
			t.Errorf("Summarize(%.30q...) = %q, want %q", tc.in, got, tc.want)
		}
		if utf8.RuneCountInString(got) > MaxBody {
			t.Errorf("too long: %d", utf8.RuneCountInString(got))
		}
	}
}

func TestRedact(t *testing.T) {
	cases := []struct{ in, want string }{
		{"api_key=abc123 done", "api_key=[redacted] done"},
		{"API-Key: xyz", "API-Key=[redacted]"},
		{"password = hunter2", "password=[redacted]"},
		{"Authorization: Bearer eyJhbGciOi", "Authorization=[redacted]"},
		{"use Bearer abc.def.ghi here", "use Bearer [redacted] here"},
		{"key AKIAIOSFODNN7EXAMPLE used", "key [redacted] used"},
		{"gh: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123", "gh: [redacted]"},
		{"openai sk-abcdefghijklmnopqrstuvwxyz1234", "openai [redacted]"},
		{"anthropic sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "anthropic [redacted]"},
		{"slack xoxb-1234567890-abcdefghij", "slack [redacted]"},
		{"sha 0123456789abcdef0123456789abcdef01234567 ok", "sha [redacted] ok"},
		{"blob QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5 end", "blob [redacted] end"},
		{"-----BEGIN RSA PRIVATE KEY----- MIIE -----END RSA PRIVATE KEY----- after", "[redacted] after"},
		{"-----BEGIN PRIVATE KEY----- MIIE truncated", "[redacted]"},
		{"/Users/kit/Development/rootshell/push/hook/testdata/claude_stop.json", "/Users/kit/Development/rootshell/push/hook/testdata/claude_stop.json"},
		{"feature/integrated-tab-osc-progress-with-a-very-long-name", "feature/integrated-tab-osc-progress-with-a-very-long-name"},
		{"The token was rotated and the secret is safe.", "The token was rotated and the secret is safe."},
	}
	for _, tc := range cases {
		if got := Redact(tc.in); got != tc.want {
			t.Errorf("Redact(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestRoute(t *testing.T) {
	t.Setenv("HERDR_PANE_ID", "")
	t.Setenv("LC_ROOTSHELL_PANE", "pane-1")
	t.Setenv("TMUX_PANE", "%3")
	t.Setenv("TMUX", "")
	t.Setenv("USER", "kit")
	r := Route(t.Context(), "/x")
	if r.Pane != "pane-1" || r.TmuxPane != "%3" || r.Cwd != "/x" || !strings.HasPrefix(r.Host, "kit@") || strings.Contains(r.Host, ".") {
		t.Fatalf("%+v", r)
	}
}

func TestRouteUsesCanonicalTmuxServerIdentity(t *testing.T) {
	t.Setenv("HERDR_PANE_ID", "")
	dir := t.TempDir()
	tmux := filepath.Join(dir, "tmux")
	script := `#!/bin/sh
case "$*" in
  *socket_path*) printf 'dev:/tmp/tmux-1000/default,42410,1788022920\n' ;;
  *'#S'*) printf 'work\n' ;;
  *) exit 1 ;;
esac
`
	if err := os.WriteFile(tmux, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("LC_ROOTSHELL_PANE", "")
	t.Setenv("TMUX", "/tmp/tmux-1000/default,42410,0")
	t.Setenv("TMUX_PANE", "%14")
	t.Setenv("USER", "kit")

	r := Route(t.Context(), "/work")
	if r.Pane != "" || r.TmuxPane != "%14" ||
		r.TmuxServer != "dev:/tmp/tmux-1000/default,42410,1788022920" ||
		r.TmuxSession != "work" {
		t.Fatalf("%+v", r)
	}
}
