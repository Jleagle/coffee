package cmd

import (
	"context"
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
	Short: "List available drink options (beans, milks, syrups, etc.)",
	RunE: func(cmd *cobra.Command, args []string) error {

		ctx := context.Background()
		_, client, err := firebase.AuthedClient(ctx, cmd.Printf)
		if err != nil {
			return err
		}

		defer client.Close()

		var optionCollections = map[string]string{
			"beans":           "Beans",
			"milks":           "Milks",
			"cup_choices":     "Cups",
			"syrups":          "Syrups",
			"sugars":          "Sugars",
			"toppings":        "Toppings",
			"extras":          "Extras",
			"drinkCategories": "Categories",
		}

		tbl := table.New("Collection", "ID", "Name").WithWriter(cmd.OutOrStdout())

		for coll, title := range optionCollections {

			iter := client.Collection(coll).Documents(ctx)

			options, err := firebase.LoadRows(iter, &firebase.Option{})
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
