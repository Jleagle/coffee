package cmd

import (
	"context"
	"errors"
	"fmt"

	"github.com/Jleagle/coffee/firebase"
	"github.com/fatih/color"
	"github.com/rodaine/table"
	"github.com/spf13/cobra"
	"google.golang.org/api/iterator"
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

			tbl.AddRow("", "")
			tbl.AddRow("", color.HiGreenString(title))

			for {
				doc, err := iter.Next()
				if errors.Is(err, iterator.Done) {
					break
				}
				if err != nil {
					return fmt.Errorf("listing %s: %w", coll, err)
				}

				//fmt.Println(doc.Data())

				option := firebase.Option{}
				if err := doc.DataTo(&option); err != nil {
					return fmt.Errorf("decoding %s %s: %w", coll, doc.Ref.ID, err)
				}
				option.ID = doc.Ref.ID

				tbl.AddRow(doc.Ref.ID, option.Name)
			}
			iter.Stop()
		}

		tbl.Print()

		return nil
	},
}
