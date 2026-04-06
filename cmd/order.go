package cmd

import (
	"context"
	"fmt"
	"time"

	"github.com/Jleagle/coffee/firebase"
	"github.com/spf13/cobra"
)

var (
	orderDrinkID string
	orderTime    string
)

func init() {
	orderCmd.Flags().StringVarP(&orderDrinkID, "drink", "d", "tVZmk6rGTqBN7JgAEKhG", "Drink document ID (required)")
	orderCmd.Flags().StringVarP(&orderTime, "time", "t", "", "Order time in HH:MM format (default: now)")
	//orderCmd.MarkFlagRequired("drink")
	RootCmd.AddCommand(orderCmd)
}

var orderCmd = &cobra.Command{
	Use:   "order",
	Short: "Order a drink by its ID",
	RunE: func(cmd *cobra.Command, args []string) error {

		ctx := context.Background()
		sess, client, err := firebase.AuthedClient(ctx, cmd.Printf)
		if err != nil {
			return err
		}
		defer client.Close()

		// Read the drink
		doc, err := client.Collection("drinks").Doc(orderDrinkID).Get(ctx)
		if err != nil {
			return fmt.Errorf("reading drink %s: %w", orderDrinkID, err)
		}

		var drink firebase.Drink
		if err := doc.DataTo(&drink); err != nil {
			return fmt.Errorf("decoding drink %s: %w", orderDrinkID, err)
		}
		drink.ID = doc.Ref.ID

		cmd.Printf("\nDrink: %s\n", drink.Name)

		// Resolve order time
		now := time.Now()
		if orderTime != "" {
			parsed, err := time.Parse("15:04", orderTime)
			if err != nil {
				return fmt.Errorf("invalid time format %q, expected HH:MM: %w", orderTime, err)
			}
			now = time.Date(now.Year(), now.Month(), now.Day(), parsed.Hour(), parsed.Minute(), 0, 0, now.Location())
		}

		// Payload
		order := map[string]any{
			"userName":             sess.DisplayName,
			"userId":               sess.UID,
			"userEmail":            sess.Email,
			"drinkName":            drink.Name,
			"drinkId":              orderDrinkID,
			"options":              nil, // array of option documents
			"orderTimestamp":       now.UnixMilli(),
			"lastUpdatedTimestamp": now.UnixMilli(),
			"status":               "queuing",
		}

		_, _, err = client.Collection("order").Add(ctx, order)
		if err != nil {
			return fmt.Errorf("creating order: %w", err)
		}

		cmd.Printf("\nOrder created successfully!\n")
		return nil
	},
}
