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

//go:embed adapter.ts
var adapterTemplate string

func isExtension(t Tool) bool { return t == Pi || t == OMP }

// ConfigDir returns the tool's configuration directory, not its hook file.
// Project paths are relative to cwd and ignore user-level directory overrides.
func ConfigDir(t Tool, project bool) (string, error) {
	var dotDir string
	switch t {
	case ClaudeCode:
		dotDir = ".claude"
	case Codex:
		dotDir = ".codex"
	case Pi:
		dotDir = ".pi"
	case OMP:
		dotDir = ".omp"
	case Hermes:
		dotDir = ".hermes"
	default:
		return "", fmt.Errorf("unknown tool %q", t)
	}
	if project {
		return dotDir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if t == Hermes {
		if value := os.Getenv("HERMES_HOME"); value != "" {
			return expandHermesHome(value, home)
		}
		dotDir += os.Getenv("HERMES_DATA_DIR_SUFFIX")
	}
	if isExtension(t) {
		if t == OMP {
			if value := os.Getenv("PI_CONFIG_DIR"); value != "" {
				dotDir = value
			}
			root := filepath.Join(home, dotDir)
			profile, err := ompProfile()
			if err != nil {
				return "", err
			}
			if profile != "" {
				return filepath.Join(root, "profiles", profile, "agent"), nil
			}
			value := os.Getenv("PI_CODING_AGENT_DIR")
			// OMP's explicit default profile must not inherit a directory
			// propagated by a legacy PI_PROFILE in a parent process.
			legacy, _ := normalizeOMPProfile(os.Getenv("PI_PROFILE"))
			if value != "" && (legacy == "" || value != filepath.Join(root, "profiles", legacy, "agent")) {
				return filepath.Abs(value)
			}
			return filepath.Join(root, "agent"), nil
		}
		if value := os.Getenv("PI_CODING_AGENT_DIR"); value != "" {
			return expandAgentDir(value, home)
		}
		return filepath.Join(home, dotDir, "agent"), nil
	}
	return filepath.Join(home, dotDir), nil
}

var ompProfilePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
var ompReservedProfile = regexp.MustCompile(`(?i)^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$`)

func normalizeOMPProfile(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" || value == "default" {
		return "", nil
	}
	if !ompProfilePattern.MatchString(value) || strings.HasSuffix(value, ".") || ompReservedProfile.MatchString(value) {
		return "", fmt.Errorf("invalid OMP profile %q", value)
	}
	return value, nil
}

func ompProfile() (string, error) {
	value, exists := os.LookupEnv("OMP_PROFILE")
	if !exists {
		value = os.Getenv("PI_PROFILE")
	}
	return normalizeOMPProfile(value)
}

func expandAgentDir(value, home string) (string, error) {
	if value == "~" {
		value = home
	} else if strings.HasPrefix(value, "~/") {
		value = filepath.Join(home, value[2:])
	}
	return filepath.Abs(value)
}

func extensionSource(t Tool) []byte {
	body := strings.ReplaceAll(adapterTemplate, "__ROOTSHELL_AGENT__", string(t))
	return []byte(fmt.Sprintf("// rootshell-notify managed extension v1 %s sha256=%x\n%s", t, sha256.Sum256([]byte(body)), body))
}

// A marker alone is insufficient: do not overwrite a user's edits to an
// installed extension. Older intact generated versions can still be upgraded.
func ownedExtension(raw []byte, t Tool) bool {
	header, body, ok := bytes.Cut(raw, []byte("\n"))
	return ok && string(header) == fmt.Sprintf("// rootshell-notify managed extension v1 %s sha256=%x", t, sha256.Sum256(body))
}

func readExtension(path string) ([]byte, bool, error) {
	st, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if !st.Mode().IsRegular() {
		return nil, true, fmt.Errorf("%s: extension must be a regular file (symlinks are not followed)", path)
	}
	raw, err := os.ReadFile(path)
	return raw, true, err
}

func applyExtension(t Tool, project, remove bool) (Result, error) {
	path, err := Path(t, project)
	res := Result{Path: path}
	if err != nil {
		return res, err
	}
	raw, exists, err := readExtension(path)
	if err != nil {
		return res, err
	}
	if exists && !ownedExtension(raw, t) {
		return res, fmt.Errorf("%s: refusing to modify an unowned or edited extension", path)
	}
	if remove && !exists || !remove && exists && bytes.Equal(raw, extensionSource(t)) {
		return res, nil
	}
	if exists {
		// Never overwrite the first backup, or follow a backup symlink.
		if err := writeExclusive(path+".bak", raw, 0o600); err != nil && !errors.Is(err, os.ErrExist) {
			return res, err
		}
	}
	if remove {
		err = os.Remove(path)
	} else if !exists {
		err = writeExclusive(path, extensionSource(t), 0o600)
	} else {
		st, statErr := os.Stat(path)
		if statErr != nil {
			return res, statErr
		}
		err = config.WriteFileAtomic(path, extensionSource(t), st.Mode().Perm())
	}
	res.Changed = err == nil
	return res, err
}

func writeExclusive(path string, raw []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	_, err = file.Write(raw)
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		os.Remove(path)
		return err
	}
	return closeErr
}
