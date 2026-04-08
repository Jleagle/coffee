package cmd

import (
	"github.com/spf13/cobra"
)

var RootCmd = &cobra.Command{
	Use:               "coffee",
	Short:             "Order coffee from your terminal",
	CompletionOptions: cobra.CompletionOptions{DisableDefaultCmd: true},
}

func init() {
	RootCmd.SetHelpCommand(&cobra.Command{Hidden: true})
}
