package cmd

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/Jleagle/coffee/firebase"
	"github.com/rodaine/table"
	"github.com/spf13/cobra"
	"google.golang.org/api/iterator"
)

func init() {
	RootCmd.AddCommand(topDrinksCmd)
}

var topDrinksCmd = &cobra.Command{
	Use:   "top-drinks",
	Short: "List drinks by popularity",
	RunE: func(cmd *cobra.Command, args []string) error {

		ctx := context.Background()
		_, client, err := firebase.AuthedClient(ctx, cmd.Printf)
		if err != nil {
			return err
		}
		defer client.Close()

		// Load all categories by ID
		orders, err := firebase.LoadRows(ctx, client, &firebase.Order{})
		if err != nil {
			return fmt.Errorf("loading orders: %w", err)
		}

		var ordersCount = map[string]*int{}

		for _, v := range orders {
			if v.Status != "completed" {
				continue
			}
			if t, ok := ordersCount[v.DrinkID]; ok {
				*t++
			} else {
				x := 1
				ordersCount[v.DrinkID] = &x
			}
		}

		// Load drinks
		iter := client.Collection("drinks").Documents(ctx)
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

			drinks = append(drinks, drink)
		}

		slices.SortFunc(drinks, func(i, j firebase.Drink) int {
			return cmp.Or(
				cmp.Compare(*ordersCount[j.ID], *ordersCount[i.ID]),
			)
		})

		tbl := table.New("ID", "Orders", "Drink").WithWriter(cmd.OutOrStdout())
		for _, d := range drinks {
			tbl.AddRow(d.ID, *ordersCount[d.ID], d.Name)
		}
		tbl.Print()

		return nil
	},
}
