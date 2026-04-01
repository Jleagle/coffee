package main

import (
	"fmt"
	"os"
	_ "time/tzdata"

	"github.com/Jleagle/coffee/cmd"
)

var requiredEnvVars = []string{
	"COFFEE_API_KEY",
	"COFFEE_AUTH_DOMAIN",
	"COFFEE_APP_ID",
	"COFFEE_PROJECT_ID",
}

func main() {

	os.Setenv("TZ", "Europe/London")

	for _, key := range requiredEnvVars {
		if os.Getenv(key) == "" {
			fmt.Fprintf(os.Stderr, "Error: required environment variable %s is not set\n", key)
			os.Exit(1)
		}
	}

	if err := cmd.RootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
