package main

import (
	"os"

	"github.com/douglasjarquin/consigliere/cli/service"
)

func main() {
	os.Exit(service.Run(os.Args[1:], os.Stdout, os.Stderr))
}
