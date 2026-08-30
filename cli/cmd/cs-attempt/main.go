package main

import (
	"os"

	"github.com/douglasjarquin/consigliere/cli/client"
)

func main() {
	os.Exit(client.RunAttempt(os.Args[1:], os.Stdout, os.Stderr))
}
