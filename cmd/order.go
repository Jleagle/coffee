package cmd

import (
	"fmt"
	"os"
	"os/signal"
	"sync"
	"time"

	"github.com/Jleagle/coffee/firebase"
	"github.com/spf13/cobra"
	"golang.org/x/sync/errgroup"
)

const (
	optionMediumRoast = "vyZITIjN1jTOUYkVikfN"
)

var (
	orderDrinkID string
	orderTime    string
	orderDouble  bool
	orderOptions []string
)

func init() {
	orderCmd.Flags().StringVarP(&orderDrinkID, "drink", "d", "", "Drink document ID (required)")
	orderCmd.Flags().StringVarP(&orderTime, "time", "t", "", "Order time in HH:MM or HH:MM:SS format (default: now)")
	orderCmd.Flags().BoolVar(&orderDouble, "double", false, "Double shot")
	orderCmd.Flags().StringSliceVarP(&orderOptions, "option", "o", []string{optionMediumRoast}, "Option IDs")
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
		drink, err := firebase.LoadRow[*firebase.Drink](ctx, client, "drinks", orderDrinkID)
		if err != nil {
			return fmt.Errorf("reading drink %s: %w", orderDrinkID, err)
		}

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
		}

		// Don't order before 08:30
		openingTime := time.Date(orderAt.Year(), orderAt.Month(), orderAt.Day(), 8, 30, 0, 0, orderAt.Location())
		if orderAt.Before(openingTime) {
			orderAt = openingTime
		}

		// Wait for order time
		if wait := time.Until(orderAt); wait > 0 {
			cmd.Printf("Waiting until %s to place order...\n", orderAt.Format("15:04:05"))
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				return ctx.Err()
			}
		}

		// Wait for shop to open
		if err := firebase.WaitForShopOpen(ctx, client, cmd.Printf); err != nil {
			return err
		}

		// Resolve options
		var mu sync.Mutex
		var wg errgroup.Group
		var collections = []string{firebase.CollBeans, firebase.CollMilks, firebase.CollCupChoices, firebase.CollSyrups, firebase.CollSugars, firebase.CollToppings, firebase.CollExtras}

		var allOptions = make(map[string]firebase.OrderOption)
		for _, coll := range collections {
			wg.Go(func() error {
				iter := client.Collection(coll).Documents(ctx)
				items, err := firebase.LoadRows[*firebase.Option](iter)
				if err != nil {
					return fmt.Errorf("loading %s: %w", coll, err)
				}
				mu.Lock()
				defer mu.Unlock()
				for id, item := range items {
					option := firebase.OrderOption{
						Collection: coll,
						OptionName: item.Name,
						OptionID:   id,
						OptionRef:  client.Collection(coll).Doc(id),
						Count: func() int {
							if coll == firebase.CollBeans && orderDouble {
								return 2
							}
							return 1
						}(),
					}
					allOptions[id] = option
					allOptions[item.Name] = option
				}
				return nil
			})
		}

		if err := wg.Wait(); err != nil {
			return err
		}

		// Payload
		optionsByCollection := make(map[string]firebase.OrderOption)
		for _, optID := range orderOptions {
			if opt, ok := allOptions[optID]; ok {
				optionsByCollection[opt.Collection] = opt
			}
		}

		var finalOptions []firebase.OrderOption
		for _, opt := range optionsByCollection {
			finalOptions = append(finalOptions, opt)
		}

		order := firebase.Order{
			UserName:       sess.DisplayName,
			UserEmail:      sess.Email,
			UserID:         sess.UID,
			OrderTimestamp: orderAt.UnixMilli(),
			Options:        finalOptions,
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
