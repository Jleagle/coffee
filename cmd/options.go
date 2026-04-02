package cmd

import (
	"context"
	"errors"
	"fmt"

	"github.com/Jleagle/coffee/helpers"
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
		_, client, err := helpers.AuthedClient(ctx, cmd.Printf)
		if err != nil {
			return err
		}

		defer client.Close()

		var optionCollections = []string{
			"beans",
			"milks",
			"cup_choices",
			"syrups",
			"sugars",
			"toppings",
			"extras",
		}

		for _, coll := range optionCollections {
			iter := client.Collection(coll).Documents(ctx)

			var found bool
			for {
				doc, err := iter.Next()
				if errors.Is(err, iterator.Done) {
					break
				}
				if err != nil {
					iter.Stop()
					return fmt.Errorf("listing %s: %w", coll, err)
				}
				if !found {
					cmd.Printf("\n%s\n", coll)
					found = true
				}
				data := doc.Data()
				name, _ := data["name"].(string)
				cmd.Printf("  %s: %s\n", doc.Ref.ID, name)
			}
			iter.Stop()
		}
		cmd.Println()
		return nil
	},
}
