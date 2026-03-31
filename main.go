package main

import (
	"os"

	"github.com/Jleagle/coffee/cmd"
)

func main() {
	if err := cmd.RootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
