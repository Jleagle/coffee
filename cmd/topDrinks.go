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
		orders, err := loadOrders(ctx, client)
		if err != nil {
			return fmt.Errorf("loading orders: %w", err)
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

			//fmt.Println(doc.Data())

			if err := doc.DataTo(&drink); err != nil {
				return fmt.Errorf("decoding drink %s: %w", doc.Ref.ID, err)
			}
			drink.ID = doc.Ref.ID

			drinks = append(drinks, drink)
		}

		slices.SortFunc(drinks, func(i, j firebase.Drink) int {
			return cmp.Or(
				cmp.Compare(*orders[j.ID], *orders[i.ID]),
			)
		})

		tbl := table.New("ID", "Orders", "Drink").WithWriter(cmd.OutOrStdout())
		for _, d := range drinks {
			tbl.AddRow(d.ID, *orders[d.ID], d.Name)
		}
		tbl.Print()

		return nil
	},
}

func loadOrders(ctx context.Context, client *firestore.Client) (orders map[string]*int, err error) {

	iter := client.Collection("order").
		Where("status", "!=", "cancelled").
		Documents(ctx)

	defer iter.Stop()

	orders = map[string]*int{}

	for {
		doc, err := iter.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("listing orders: %w", err)
		}

		order := firebase.Order{}
		if err := doc.DataTo(&order); err != nil {
			return nil, fmt.Errorf("decoding order %s: %w", doc.Ref.ID, err)
		}
		order.ID = doc.Ref.ID

		if t, ok := orders[order.DrinkID]; ok {
			*t++
		} else {
			x := 1
			orders[order.DrinkID] = &x
		}
	}

	return orders, nil
}
