package cmd

import (
	"encoding/json"
	"fmt"
	"strings"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/firebase"
	"github.com/spf13/cobra"
)

var (
	drinkDrink string
)

func init() {
	drinkCmd.Flags().StringVarP(&drinkDrink, "drink", "d", "", "Drink ID")
	drinkCmd.MarkFlagRequired("drink")
	RootCmd.AddCommand(drinkCmd)
}

var drinkCmd = &cobra.Command{
	Use:   "drink --drink [id]",
	Short: "Show drink information",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {

		_, client, err := firebase.AuthedClient(cmd.Context(), cmd.Printf)
		if err != nil {
			return err
		}
		defer client.Close()

		drink, err := firebase.LoadRow[*firebase.Drink](cmd.Context(), client, "drinks", drinkDrink)
		if err != nil {
			return fmt.Errorf("reading drink %s: %w", drinkDrink, err)
		}

		b, err := json.MarshalIndent(drink, "", "  ")
		fmt.Println(string(b))

		cmd.Println("Required options: " + strings.Join(drink.RequiredOptions, ", "))
		cmd.Println("Defaults: ")
		for k, v := range drink.DefaultOptions {

			x := v.(*firestore.DocumentRef)

			cmd.Println(k + ": " + x.ID)

		}

		return nil
	},
}
