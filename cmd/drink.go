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

		doc, err := client.Collection("drinks").Doc(drinkDrink).Get(cmd.Context())
		if err != nil {
			return fmt.Errorf("reading drink %s: %w", drinkDrink, err)
		}

		var d firebase.Drink
		if err := doc.DataTo(&d); err != nil {
			return fmt.Errorf("decoding drink %s: %w", drinkDrink, err)
		}
		d.ID = doc.Ref.ID

		b, err := json.MarshalIndent(d, "", "  ")
		fmt.Println(string(b))

		cmd.Println("Required options: " + strings.Join(d.RequiredOptions, ", "))
		cmd.Println("Defaults: ")
		for k, v := range d.DefaultOptions {

			x := v.(*firestore.DocumentRef)

			cmd.Println(k + ": " + x.ID)

		}

		return nil
	},
}
