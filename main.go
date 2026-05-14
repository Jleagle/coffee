package main

import (
	"context"
	"os"
	_ "time/tzdata"

	"github.com/Jleagle/coffee/cmd"
)

func main() {

	os.Setenv("TZ", "Europe/London")

	ctx := context.Background()

	if err := cmd.RootCmd.ExecuteContext(ctx); err != nil {
		os.Exit(1)
	}
}
