package installer

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestHermesInstallLifecycle(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("HERMES_HOME", "")
	tool, err := ParseTool("hermes")
	if err != nil {
		t.Fatal(err)
	}
	if tool.Name() != "Hermes" {
		t.Fatalf("name: %s", tool.Name())
	}
	path, err := Path(tool, false)
	if err != nil || path != filepath.Join(home, ".hermes", "plugins", "rootshell-push", "__init__.py") {
		t.Fatalf("path: %s %v", path, err)
	}
	manifest := filepath.Join(filepath.Dir(path), "plugin.yaml")
	res, err := Install(tool, false)
	if err != nil || !res.Changed {
		t.Fatalf("install: %+v %v", res, err)
	}
	raw, err := os.ReadFile(manifest)
	if err != nil || !bytes.Contains(raw, []byte("name: rootshell-push\n")) {
		t.Fatalf("manifest: %s %v", raw, err)
	}
	st, err := GetStatus(tool, false)
	if err != nil || !st.Installed {
		t.Fatalf("status: %+v %v", st, err)
	}
	res, err = Install(tool, false)
	if err != nil || res.Changed {
		t.Fatalf("idempotent install: %+v %v", res, err)
	}
	source, _ := os.ReadFile(path)
	if err := os.WriteFile(path, append(source, []byte("\n# user edit\n")...), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Install(tool, false); err == nil {
		t.Fatal("overwrote edited plugin")
	}
	if _, err := Uninstall(tool, false); err == nil {
		t.Fatal("removed edited plugin")
	}
	os.WriteFile(path, source, 0o600)
	foreign := filepath.Join(filepath.Dir(path), "user.txt")
	os.WriteFile(foreign, []byte("keep"), 0o600)
	res, err = Uninstall(tool, false)
	if err != nil || !res.Changed {
		t.Fatalf("uninstall: %+v %v", res, err)
	}
	for _, p := range []string{path, manifest} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("file not removed: %s %v", p, err)
		}
	}
	if raw, _ := os.ReadFile(foreign); !bytes.Equal(raw, []byte("keep")) {
		t.Fatal("foreign file changed")
	}
	res, err = Uninstall(tool, false)
	if err != nil || res.Changed {
		t.Fatalf("idempotent uninstall: %+v %v", res, err)
	}
}

func TestHermesHomeAndProjectPaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("HERMES_HOME", "~/custom-hermes")
	dir, err := ConfigDir(Tool("hermes"), false)
	if err != nil || dir != filepath.Join(home, "custom-hermes") {
		t.Fatalf("override: %s %v", dir, err)
	}
	path, err := Path(Tool("hermes"), true)
	if err != nil || path != filepath.Join(".hermes", "plugins", "rootshell-push", "__init__.py") {
		t.Fatalf("project: %s %v", path, err)
	}
	t.Setenv("HERMES_CUSTOM_ROOT", filepath.Join(home, "profiles"))
	for _, tc := range []struct{ value, want string }{
		{"$HOME/custom", filepath.Join(home, "custom")},
		{"${HERMES_CUSTOM_ROOT}/work", filepath.Join(home, "profiles", "work")},
		{"relative-hermes", "relative-hermes"},
		{"$HERMES_UNKNOWN_ROOT/work", "$HERMES_UNKNOWN_ROOT/work"},
	} {
		t.Setenv("HERMES_HOME", tc.value)
		want, _ := filepath.Abs(tc.want)
		dir, err := ConfigDir(Tool("hermes"), false)
		if err != nil || dir != want {
			t.Fatalf("%s: %s %v; want %s", tc.value, dir, err, want)
		}
	}
}

func TestHermesRefusesConflictingManifestsAndSymlinks(t *testing.T) {
	for _, name := range []string{"plugin.json", "plugin.yml", "plugin.yaml", "__init__.py"} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			t.Setenv("HERMES_HOME", "")
			path, _ := Path(Tool("hermes"), false)
			target := filepath.Join(filepath.Dir(path), name)
			os.MkdirAll(filepath.Dir(path), 0o700)
			foreign := []byte("name: foreign\n")
			os.WriteFile(target, foreign, 0o600)
			if _, err := Install(Tool("hermes"), false); err == nil {
				t.Fatal("foreign manifest or source overwritten")
			}
			if _, err := Uninstall(Tool("hermes"), false); err == nil {
				t.Fatal("foreign manifest or source removed")
			}
			raw, _ := os.ReadFile(target)
			if !bytes.Equal(raw, foreign) {
				t.Fatal("foreign file changed")
			}
			os.Remove(target)
			os.Symlink(filepath.Join(t.TempDir(), "absent"), target)
			if _, err := Install(Tool("hermes"), false); err == nil {
				t.Fatal("symlink accepted")
			}
		})
	}
}
