//go:build unix

package client

import (
	"errors"
	"syscall"
)

var ErrLockBusy = errors.New("home lock is held")

type LockHandle struct {
	fd int
}

func unixOpen(path string) (int, error) {
	return syscall.Open(path, syscall.O_RDWR, 0)
}

func unixClose(fd int) {
	_ = syscall.Close(fd)
}

func AcquireLock(path string) (*LockHandle, error) {
	fd, err := syscall.Open(path, syscall.O_RDWR|syscall.O_CREAT, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Fchmod(fd, 0o600); err != nil {
		_ = syscall.Close(fd)
		return nil, err
	}

	fl := syscall.Flock_t{Type: syscall.F_WRLCK, Whence: 0, Start: 0, Len: 0}
	if err := syscall.FcntlFlock(uintptr(fd), syscall.F_SETLK, &fl); err != nil {
		_ = syscall.Close(fd)
		if errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrLockBusy
		}
		return nil, err
	}

	return &LockHandle{fd: fd}, nil
}

func (h *LockHandle) Close() error {
	if h == nil || h.fd < 0 {
		return nil
	}
	err := syscall.Close(h.fd)
	h.fd = -1
	return err
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
