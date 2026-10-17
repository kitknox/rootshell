package installer

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestExtensionToolPaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, key := range []string{"PI_CODING_AGENT_DIR", "PI_AGENT_DIR", "OMP_CODING_AGENT_DIR", "OMP_AGENT_DIR", "OMP_PROFILE", "PI_PROFILE", "PI_CONFIG_DIR"} {
		t.Setenv(key, "")
	}
	if !reflect.DeepEqual(Tools, []Tool{ClaudeCode, Codex, Pi, OMP, Hermes}) {
		t.Fatalf("tools: %v", Tools)
	}
	for _, tc := range []struct {
		tool Tool
		name string
		dir  string
	}{
		{Pi, "Pi", ".pi"},
		{OMP, "OMP", ".omp"},
	} {
		t.Run(string(tc.tool), func(t *testing.T) {
			parsed, err := ParseTool(string(tc.tool))
			if err != nil || parsed != tc.tool || parsed.Name() != tc.name {
				t.Fatalf("parse: %v %v, name %q", parsed, err, parsed.Name())
			}
			for _, project := range []bool{false, true} {
				wantDir := filepath.Join(home, tc.dir, "agent")
				if project {
					wantDir = tc.dir
				}
				dir, err := ConfigDir(tc.tool, project)
				if err != nil || dir != wantDir {
					t.Fatalf("config dir = %q, %v; want %q", dir, err, wantDir)
				}
				path, err := Path(tc.tool, project)
				wantPath := filepath.Join(wantDir, "extensions", "rootshell-push.ts")
				if err != nil || path != wantPath {
					t.Fatalf("path = %q, %v; want %q", path, err, wantPath)
				}
			}
		})
	}
	// Unknown tool names must never silently target Claude's configuration.
	if _, err := ConfigDir(Tool("unknown"), false); err == nil {
		t.Fatal("unknown config dir accepted")
	}
	if _, err := Path(Tool("unknown"), false); err == nil {
		t.Fatal("unknown path accepted")
	}
}

func TestExtensionInstallRoundTripAndForeignFiles(t *testing.T) {
	for _, tool := range []Tool{Pi, OMP} {
		t.Run(string(tool), func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			for _, key := range []string{"PI_CODING_AGENT_DIR", "PI_AGENT_DIR", "OMP_CODING_AGENT_DIR", "OMP_AGENT_DIR", "OMP_PROFILE", "PI_PROFILE", "PI_CONFIG_DIR"} {
				t.Setenv(key, "")
			}
			path, err := Path(tool, false)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			foreign := filepath.Join(filepath.Dir(path), "other.ts")
			if err := os.WriteFile(foreign, []byte("export default () => {};"), 0o600); err != nil {
				t.Fatal(err)
			}
			before, err := GetStatus(tool, false)
			if err != nil || before.Exists || before.Installed {
				t.Fatalf("before: %+v %v", before, err)
			}
			res, err := Install(tool, false)
			if err != nil || !res.Changed || res.Path != path {
				t.Fatalf("install: %+v %v", res, err)
			}
			raw, err := os.ReadFile(path)
			if err != nil || len(raw) == 0 {
				t.Fatalf("extension missing: %v", err)
			}
			st, err := GetStatus(tool, false)
			if err != nil || !st.Exists || !st.Installed {
				t.Fatalf("status: %+v %v", st, err)
			}
			res, err = Install(tool, false)
			if err != nil || res.Changed {
				t.Fatalf("idempotent install: %+v %v", res, err)
			}
			res, err = Uninstall(tool, false)
			if err != nil || !res.Changed {
				t.Fatalf("uninstall: %+v %v", res, err)
			}
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatalf("extension not removed: %v", err)
			}
			if _, err := os.Stat(foreign); err != nil {
				t.Fatalf("other extension removed: %v", err)
			}
			res, err = Uninstall(tool, false)
			if err != nil || res.Changed {
				t.Fatalf("idempotent uninstall: %+v %v", res, err)
			}
			// A user-owned file at our intended path is never overwritten or removed.
			if err := os.WriteFile(path, []byte("export default () => {};"), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := Install(tool, false); err == nil {
				t.Fatal("foreign extension overwritten")
			}
			if _, err := Uninstall(tool, false); err == nil {
				t.Fatal("foreign extension removed")
			}
			st, err = GetStatus(tool, false)
			if err != nil || !st.Exists || st.Installed {
				t.Fatalf("foreign status: %+v %v", st, err)
			}
			got, _ := os.ReadFile(path)
			if string(got) != "export default () => {};" {
				t.Fatalf("foreign file changed: %s", got)
			}
		})
	}
}

func TestOfficialAgentDirectoryOverrides(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PI_CODING_AGENT_DIR", "")
	t.Setenv("OMP_PROFILE", "")
	t.Setenv("PI_PROFILE", "")
	t.Setenv("PI_CONFIG_DIR", "")
	// These names are not read by the verified official runtimes.
	t.Setenv("PI_AGENT_DIR", "/not-an-official-pi-override")
	t.Setenv("OMP_AGENT_DIR", "/not-an-official-omp-override")
	t.Setenv("OMP_CODING_AGENT_DIR", "/not-an-official-omp-override")
	for _, tool := range []Tool{Pi, OMP} {
		got, err := ConfigDir(tool, false)
		want := filepath.Join(home, "."+string(tool), "agent")
		if err != nil || got != want {
			t.Fatalf("%s: %q, %v; want %q", tool, got, err, want)
		}
	}
	t.Setenv("PI_CODING_AGENT_DIR", filepath.Join(home, "shared agent"))
	piPath, _ := Path(Pi, false)
	ompPath, _ := Path(OMP, false)
	if piPath != ompPath {
		t.Fatalf("official shared override differs: %s %s", piPath, ompPath)
	}
	if _, err := Install(Pi, false); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(piPath)
	if _, err := Install(OMP, false); err == nil {
		t.Fatal("shared directory overwrote another agent's identity")
	}
	after, _ := os.ReadFile(piPath)
	if !bytes.Equal(before, after) {
		t.Fatal("existing agent overwritten")
	}
	t.Setenv("PI_CODING_AGENT_DIR", "~/custom pi")
	if got, err := ConfigDir(Pi, false); err != nil || got != filepath.Join(home, "custom pi") {
		t.Fatalf("Pi tilde override: %q %v", got, err)
	}
	t.Setenv("PI_CODING_AGENT_DIR", "")
	t.Setenv("PI_CONFIG_DIR", ".omp-custom")
	t.Setenv("OMP_PROFILE", " work ")
	if got, err := ConfigDir(OMP, false); err != nil || got != filepath.Join(home, ".omp-custom", "profiles", "work", "agent") {
		t.Fatalf("OMP profile: %q %v", got, err)
	}
	// A named profile takes priority over the generic agent directory override.
	t.Setenv("PI_CODING_AGENT_DIR", filepath.Join(home, "ignored-by-profile"))
	if got, err := ConfigDir(OMP, false); err != nil || got != filepath.Join(home, ".omp-custom", "profiles", "work", "agent") {
		t.Fatalf("OMP profile override: %q %v", got, err)
	}
	t.Setenv("OMP_PROFILE", "../escape")
	if _, err := ConfigDir(OMP, false); err == nil {
		t.Fatal("invalid OMP profile accepted")
	}
	for _, tool := range []Tool{Pi, OMP} {
		if got, err := ConfigDir(tool, true); err != nil || got != "."+string(tool) {
			t.Fatalf("project override leaked: %q %v", got, err)
		}
	}
}

func TestExtensionUpdatesBackupAndProtectEdits(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PI_CODING_AGENT_DIR", "")
	path, _ := Path(Pi, false)
	os.MkdirAll(filepath.Dir(path), 0o700)
	oldBody := []byte("export default function oldVersion(api) {}\n")
	old := []byte(fmt.Sprintf("// rootshell-notify managed extension v1 pi sha256=%x\n%s", sha256.Sum256(oldBody), oldBody))
	if err := os.WriteFile(path, old, 0o640); err != nil {
		t.Fatal(err)
	}
	if st, err := GetStatus(Pi, false); err != nil || !st.Exists || st.Installed || !st.Outdated {
		t.Fatalf("old status: %+v %v", st, err)
	}
	if res, err := Install(Pi, false); err != nil || !res.Changed {
		t.Fatalf("upgrade: %+v %v", res, err)
	}
	bak, err := os.ReadFile(path + ".bak")
	if err != nil || !bytes.Equal(bak, old) {
		t.Fatalf("upgrade backup: %q %v", bak, err)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o640 {
		t.Fatalf("upgrade changed permissions: %v", st.Mode())
	}
	current, _ := os.ReadFile(path)
	if err := os.WriteFile(path, append(current, []byte("// user edit\n")...), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := Install(Pi, false); err == nil {
		t.Fatal("user edit overwritten")
	}
	if _, err := Uninstall(Pi, false); err == nil {
		t.Fatal("user edit removed")
	}
	if st, _ := GetStatus(Pi, false); st.Installed || st.Outdated {
		t.Fatal("edited extension reported as managed")
	}
	os.WriteFile(path, current, 0o640)
	if _, err := Uninstall(Pi, false); err != nil {
		t.Fatal(err)
	}
	bak, _ = os.ReadFile(path + ".bak")
	if !bytes.Equal(bak, old) {
		t.Fatal("uninstall overwrote first backup")
	}
}

func TestExtensionRefusesSymlink(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PI_CODING_AGENT_DIR", "")
	path, _ := Path(Pi, false)
	os.MkdirAll(filepath.Dir(path), 0o700)
	target := filepath.Join(home, "user.ts")
	os.WriteFile(target, []byte("user-owned"), 0o600)
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	if _, err := Install(Pi, false); err == nil {
		t.Fatal("installed through a symlink")
	}
	if _, err := Uninstall(Pi, false); err == nil {
		t.Fatal("uninstalled a symlink")
	}
	raw, _ := os.ReadFile(target)
	if string(raw) != "user-owned" {
		t.Fatal("symlink target changed")
	}
}
