package main

import (
	"os"

	"github.com/douglasjarquin/consigliere/cli/client"
)

func main() {
	os.Exit(client.Run(os.Args[1:], os.Stdout, os.Stderr))
}
