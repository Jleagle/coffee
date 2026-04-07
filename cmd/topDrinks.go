package cmd

import (
	"cmp"
	"context"
	"fmt"
	"slices"

	"github.com/Jleagle/coffee/firebase"
	"github.com/rodaine/table"
	"github.com/spf13/cobra"
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

		// Load orders
		iter := client.Collection("order").Where("status", "==", "completed").Documents(ctx)
		defer iter.Stop()

		orders, err := firebase.LoadRows(iter, &firebase.Order{})
		if err != nil {
			return fmt.Errorf("loading orders: %w", err)
		}

		var ordersCount = map[string]*int{}
		for _, v := range orders {
			if t, ok := ordersCount[v.DrinkID]; ok {
				*t++
			} else {
				x := 1
				ordersCount[v.DrinkID] = &x
			}
		}

		// Load drinks
		iter = client.Collection("drinks").Documents(ctx)
		defer iter.Stop()

		drinksM, err := firebase.LoadRows(iter, &firebase.Drink{})
		if err != nil {
			return fmt.Errorf("loading orders: %w", err)
		}

		var drinks []firebase.Drink
		for _, v := range drinksM {
			drinks = append(drinks, *v)
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
