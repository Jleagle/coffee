package cmd

import (
	"cmp"
	"fmt"
	"slices"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/firebase"
	"github.com/rodaine/table"
	"github.com/samber/lo"
	"github.com/spf13/cobra"
)

func init() {
	RootCmd.AddCommand(drinksCmd)
}

var drinksCmd = &cobra.Command{
	Use:   "drinks",
	Short: "List available drinks",
	RunE: func(cmd *cobra.Command, args []string) error {

		_, client, err := firebase.AuthedClient(cmd.Context(), cmd.Printf)
		if err != nil {
			return err
		}
		defer client.Close()

		// Load categories
		iter := client.Collection("drinkCategories").Documents(cmd.Context())
		defer iter.Stop()

		categories, err := firebase.LoadRows[*firebase.DrinkCategory](iter)
		if err != nil {
			return fmt.Errorf("loading categories: %w", err)
		}

		// Load drinks
		iter = client.Collection("drinks").OrderBy("name", firestore.Asc).Limit(100).Documents(cmd.Context())
		defer iter.Stop()

		rows, err := firebase.LoadRows[*firebase.Drink](iter)
		if err != nil {
			return fmt.Errorf("loading categories: %w", err)
		}

		var drinks []firebase.Drink
		for _, drink := range rows {
			for _, v := range drink.Categories {
				drink.Categories = []*firestore.DocumentRef{v}
				drinks = append(drinks, *drink)
			}
		}

		slices.SortFunc(drinks, func(i, j firebase.Drink) int {
			return cmp.Or(
				cmp.Compare(categories[i.Categories[0].ID].Order, categories[j.Categories[0].ID].Order),
				cmp.Compare(categories[i.Categories[0].ID].Name, categories[j.Categories[0].ID].Name),
				cmp.Compare(i.Name, j.Name),
			)
		})

		tbl := table.New("ID", "Category", "Drink").WithWriter(cmd.OutOrStdout())
		for _, d := range drinks {
			tbl.AddRow(d.ID, lo.Capitalize(categories[d.Categories[0].ID].Name), d.Name)
		}
		tbl.Print()

		return nil
	},
}
