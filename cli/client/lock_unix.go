//go:build unix

package client

import "syscall"

func unixOpen(path string) (int, error) {
	return syscall.Open(path, syscall.O_RDWR, 0)
}

func unixClose(fd int) {
	_ = syscall.Close(fd)
}

func unixGetlk(fd int) (bool, int, error) {
	fl := syscall.Flock_t{Type: syscall.F_WRLCK}
	if err := syscall.FcntlFlock(uintptr(fd), syscall.F_GETLK, &fl); err != nil {
		return false, 0, err
	}
	if fl.Type == syscall.F_UNLCK {
		return false, 0, nil
	}
	return true, int(fl.Pid), nil
}
