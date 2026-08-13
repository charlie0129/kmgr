// kmgr-engine is the out-of-process Kubernetes authority for Kmgr.app.
package main

import (
	"flag"
	"fmt"
	"os"
)

var version = "dev"

func main() {
	showVersion := flag.Bool("version", false, "print the engine version")
	flag.Parse()

	if *showVersion {
		fmt.Printf("kmgr-engine %s\n", version)
		return
	}

	fmt.Fprintln(os.Stderr, "kmgr-engine: no endpoint configured")
	os.Exit(2)
}
