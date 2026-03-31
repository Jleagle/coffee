package cmd

import (
	"context"
	"errors"
	"fmt"

	"github.com/spf13/cobra"
	"google.golang.org/api/iterator"
)

var optionsCmd = &cobra.Command{
	Use:   "options",
	Short: "List available drink options (beans, milks, syrups, etc.)",
	RunE:  runOptions,
}

func init() {
	RootCmd.AddCommand(optionsCmd)
	optionsCmd.SetHelpCommand(&cobra.Command{Hidden: true})
}

var optionCollections = []string{
	"beans",
	"milks",
	"cup_choices",
	"syrups",
	"sugars",
	"toppings",
	"extras",
}

func runOptions(cmd *cobra.Command, args []string) error {
	ctx := context.Background()
	_, client, err := authedClient(ctx)
	if err != nil {
		return err
	}
	defer client.Close()

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
}
