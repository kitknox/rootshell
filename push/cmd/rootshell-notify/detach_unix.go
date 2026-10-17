//go:build unix

package main

import "syscall"

func detachedAttr() *syscall.SysProcAttr { return &syscall.SysProcAttr{Setsid: true} }
