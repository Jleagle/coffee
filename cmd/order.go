package cmd

import (
	"fmt"
	"os"
	"os/signal"
	"time"

	"github.com/Jleagle/coffee/firebase"
	"github.com/spf13/cobra"
)

var (
	orderDrinkID string
	orderTime    string
)

func init() {
	orderCmd.Flags().StringVarP(&orderDrinkID, "drink", "d", "", "Drink document ID (required)")
	orderCmd.Flags().StringVarP(&orderTime, "time", "t", "", "Order time in HH:MM or HH:MM:SS format (default: now)")
	orderCmd.MarkFlagRequired("drink")
	RootCmd.AddCommand(orderCmd)
}

var orderCmd = &cobra.Command{
	Use:   "order --drink [id]",
	Short: "Order a drink",
	RunE: func(cmd *cobra.Command, args []string) error {

		ctx, cancel := signal.NotifyContext(cmd.Context(), os.Interrupt)
		defer cancel()

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

		// Resolve order time
		orderAt := time.Now()
		if orderTime != "" {
			parsed, err := time.Parse("15:04:05", orderTime)
			if err != nil {
				parsed, err = time.Parse("15:04", orderTime)
				if err != nil {
					return fmt.Errorf("invalid time format %q, expected HH:MM or HH:MM:SS: %w", orderTime, err)
				}
			}
			orderAt = time.Date(orderAt.Year(), orderAt.Month(), orderAt.Day(), parsed.Hour(), parsed.Minute(), parsed.Second(), 0, orderAt.Location())

			if wait := time.Until(orderAt); wait > 0 {
				cmd.Printf("Waiting until %s to place order...\n", orderAt.Format("15:04:05"))
				select {
				case <-time.After(wait):
				case <-ctx.Done():
					return ctx.Err()
				}
			}
		}

		// Payload
		order := firebase.Order{
			UserName:       sess.DisplayName,
			UserEmail:      sess.Email,
			UserID:         sess.UID,
			OrderTimestamp: orderAt.UnixMilli(),
			Options:        []firebase.OrderOption{},
			Status:         "queuing",
			DrinkName:      drink.Name,
			DrinkID:        orderDrinkID,
			LastUpdated:    orderAt.UnixMilli(),
		}

		_, _, err = client.Collection("order").Add(ctx, order)
		if err != nil {
			return fmt.Errorf("creating order: %w", err)
		}

		cmd.Println("Order created successfully!")
		return nil
	},
}
