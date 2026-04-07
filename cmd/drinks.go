package cmd

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/firebase"
	"github.com/rodaine/table"
	"github.com/samber/lo"
	"github.com/spf13/cobra"
	"google.golang.org/api/iterator"
)

func init() {
	RootCmd.AddCommand(drinksCmd)
}

var drinksCmd = &cobra.Command{
	Use:   "drinks",
	Short: "List available drinks",
	RunE: func(cmd *cobra.Command, args []string) error {

		ctx := context.Background()
		_, client, err := firebase.AuthedClient(ctx, cmd.Printf)
		if err != nil {
			return err
		}
		defer client.Close()

		// Load all categories by ID
		categories, err := firebase.LoadRows(ctx, client, &firebase.DrinkCategory{})
		if err != nil {
			return fmt.Errorf("loading categories: %w", err)
		}

		// Load all drinks with their category
		iter := client.Collection("drinks").OrderBy("name", firestore.Asc).Limit(100).Documents(ctx)
		defer iter.Stop()

		var drinks []firebase.Drink
		for {
			doc, err := iter.Next()
			if errors.Is(err, iterator.Done) {
				break
			}
			if err != nil {
				return fmt.Errorf("listing drinks: %w", err)
			}
			var drink firebase.Drink

			if err := doc.DataTo(&drink); err != nil {
				return fmt.Errorf("decoding drink %s: %w", doc.Ref.ID, err)
			}
			drink.ID = doc.Ref.ID

			for _, v := range drink.Categories {
				drink.Categories = []*firestore.DocumentRef{v}
				drinks = append(drinks, drink)
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
