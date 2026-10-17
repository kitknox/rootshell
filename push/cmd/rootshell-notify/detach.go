package main

import (
	"os"
	"os/exec"
)

// hookChildEnv marks the detached delivery child so it never detaches again.
const hookChildEnv = "ROOTSHELL_NOTIFY_HOOK_CHILD"

// detachHook is a var so tests can deliver in-process.
var detachHook = func(args []string, data []byte) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(exe, append([]string{"hook"}, args...)...)
	cmd.Env = append(os.Environ(), hookChildEnv+"=1")
	// Its own session, so the agent's process-group teardown cannot reach it.
	cmd.SysProcAttr = detachedAttr()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	_, err = stdin.Write(data)
	if closeErr := stdin.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		return err
	}
	return cmd.Process.Release()
}
