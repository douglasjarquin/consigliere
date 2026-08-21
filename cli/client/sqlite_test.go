package client

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSourcesNeverImportSQLite(t *testing.T) {
	root := filepath.Join("..")
	banned := []string{
		"database/sql",
		"modernc.org/sqlite",
		"github.com/mattn/go-sqlite3",
		"github.com/mattn/go-sqlite",
	}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		body := string(b)
		for _, needle := range banned {
			if strings.Contains(body, needle) {
				t.Errorf("%s imports or mentions %s", path, needle)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestDoctorDoesNotCreateDatabase(t *testing.T) {
	dir := shortDir(t)
	t.Setenv("CS_HOME", dir)
	var out, errb strings.Builder
	_ = Run([]string{"doctor"}, &out, &errb)
	if _, err := os.Stat(filepath.Join(dir, "consigliere.db")); !os.IsNotExist(err) {
		t.Fatal("cs doctor must not create SQLite")
	}
}
