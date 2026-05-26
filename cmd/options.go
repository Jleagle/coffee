package cmd

import (
	"fmt"

	"github.com/Jleagle/coffee/firebase"
	"github.com/fatih/color"
	"github.com/rodaine/table"
	"github.com/spf13/cobra"
)

func init() {
	RootCmd.AddCommand(optionsCmd)
}

var optionsCmd = &cobra.Command{
	Use:   "options",
	Short: "List beans, milks, cups, syrups, sugars, toppings & extras",
	RunE: func(cmd *cobra.Command, args []string) error {

		_, client, err := firebase.AuthedClient(cmd.Context(), cmd.Printf)
		if err != nil {
			return err
		}

		defer client.Close()

		tbl := table.New("Collection", "ID", "Name").WithWriter(cmd.OutOrStdout())

		for coll, title := range firebase.OptionCollections {

			iter := client.Collection(coll).Documents(cmd.Context())

			options, err := firebase.LoadRows[*firebase.Option](iter)
			if err != nil {
				return fmt.Errorf("loading %s: %w", coll, err)
			}

			tbl.AddRow("", "")
			tbl.AddRow("", color.HiGreenString(title))

			for id, option := range options {
				tbl.AddRow(id, option.Name)
			}
		}

		tbl.Print()

		return nil
	},
}
