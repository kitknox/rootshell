package installer

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/kitknox/rootshell/push/config"
)

//go:embed hermes.py
var hermesTemplate string

const HermesEnableNote = "Enable the plugin with `hermes plugins enable rootshell-push`, then restart Hermes. Project plugins also require HERMES_ENABLE_PROJECT_PLUGINS=1."

type hermesFile struct {
	path   string
	source []byte
}

var hermesEnvPattern = regexp.MustCompile(`\$(?:\{[^}]*\}|[A-Za-z0-9_]+)`)

func expandHermesHome(value, home string) (string, error) {
	value = hermesEnvPattern.ReplaceAllStringFunc(value, func(match string) string {
		key := strings.TrimPrefix(match, "$")
		if strings.HasPrefix(key, "{") {
			key = key[1 : len(key)-1]
		}
		if expanded, ok := os.LookupEnv(key); ok {
			return expanded
		}
		return match
	})
	return expandAgentDir(value, home)
}

func checkHermesPath(path string) error {
	dir := filepath.Dir(path)
	if st, err := os.Lstat(dir); err == nil && !st.IsDir() {
		return fmt.Errorf("%s: plugin directory must be a directory (symlinks are not followed)", dir)
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for _, name := range []string{"plugin.json", "plugin.yml"} {
		foreignPath := filepath.Join(dir, name)
		if _, err := os.Lstat(foreignPath); err == nil {
			return fmt.Errorf("%s: refusing to modify a plugin with an unowned manifest", foreignPath)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func hermesFiles(path string) []hermesFile {
	source := []byte(fmt.Sprintf("# rootshell-notify managed plugin v1 hermes sha256=%x\n%s", sha256.Sum256([]byte(hermesTemplate)), hermesTemplate))
	// Lists what current Hermes registers; older hosts get the approval-hook fallback.
	body := []byte("name: rootshell-push\nversion: \"0.1.0\"\ndescription: Encrypted rootshell notifications for interactive Hermes turns\nprovides_hooks:\n  - pre_llm_call\n  - post_llm_call\n  - on_session_end\n  - on_human_input_request\n  - on_human_input_resolved\n")
	manifest := append([]byte(fmt.Sprintf("# rootshell-notify managed manifest v1 hermes sha256=%x\n", sha256.Sum256(body))), body...)
	return []hermesFile{{path, source}, {filepath.Join(filepath.Dir(path), "plugin.yaml"), manifest}}
}

func ownedHermesFile(file hermesFile, raw []byte) bool {
	kind := "manifest"
	if filepath.Ext(file.path) == ".py" {
		kind = "plugin"
	}
	header, body, ok := bytes.Cut(raw, []byte("\n"))
	return ok && string(header) == fmt.Sprintf("# rootshell-notify managed %s v1 hermes sha256=%x", kind, sha256.Sum256(body))
}

func applyHermes(project, remove bool) (Result, error) {
	path, err := Path(Hermes, project)
	res := Result{Path: path}
	if err != nil {
		return res, err
	}
	files := hermesFiles(path)
	originals := make([][]byte, len(files))
	exists := make([]bool, len(files))
	// Validate every source and manifest before making changes.
	if err := checkHermesPath(path); err != nil {
		return res, err
	}
	for i, file := range files {
		raw, found, err := readExtension(file.path)
		if err != nil {
			return res, err
		}
		if found && !ownedHermesFile(file, raw) {
			return res, fmt.Errorf("%s: refusing to modify an unowned or edited plugin", file.path)
		}
		originals[i], exists[i] = raw, found
	}
	for i, file := range files {
		if remove && !exists[i] || !remove && exists[i] && bytes.Equal(originals[i], file.source) {
			continue
		}
		if exists[i] {
			if err := writeExclusive(file.path+".bak", originals[i], 0o600); err != nil && !errors.Is(err, os.ErrExist) {
				return res, err
			}
		}
		if remove {
			err = os.Remove(file.path)
		} else if !exists[i] {
			err = writeExclusive(file.path, file.source, 0o600)
		} else {
			st, statErr := os.Stat(file.path)
			if statErr != nil {
				return res, statErr
			}
			err = config.WriteFileAtomic(file.path, file.source, st.Mode().Perm())
		}
		if err != nil {
			return res, err
		}
		res.Changed = true
	}
	return res, nil
}
