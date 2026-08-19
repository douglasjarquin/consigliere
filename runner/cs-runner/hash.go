package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
)

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open %s for hashing: %w", path, err)
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("hash %s: %w", path, err)
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}
