package cmd

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/firebase"
	"github.com/samber/lo"
	"github.com/spf13/cobra"
)

const (
	optionMediumRoast = "vyZITIjN1jTOUYkVikfN"
)

var (
	orderDrinkID string
	orderTime    string
	orderDouble  bool
	orderTriple  bool
	orderOptions []string
)

func init() {
	orderCmd.Flags().StringVarP(&orderDrinkID, "drink", "d", "", "Drink document ID (required)")
	orderCmd.Flags().StringVarP(&orderTime, "time", "t", "", "Order time in HH:MM or HH:MM:SS format (default: now)")
	orderCmd.Flags().BoolVar(&orderDouble, "double", false, "Double shot")
	orderCmd.Flags().BoolVar(&orderTriple, "triple", false, "Triple shot")
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
		orderAt, err := parseOrderTime(orderTime)
		if err != nil {
			return err
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
		waited, err := firebase.WaitForShopOpen(ctx, client, cmd)
		if err != nil {
			return err
		}
		if waited {
			orderAt = time.Now()
		}

		// Resolve options
		finalOptions, err := resolveOptions(ctx, client, orderOptions, orderDouble, orderTriple)
		if err != nil {
			return err
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

		//fmt.Println(order)
		_, _, err = client.Collection("order").Add(ctx, order)
		if err != nil {
			return fmt.Errorf("creating order: %w", err)
		}

		// Calculate queue position
		pos, err := getQueuePosition(ctx, client, orderAt)
		if err != nil {
			return err
		}

		cmd.Printf("Order created successfully! Queue position: %d\n", pos)
		return nil
	},
}

func parseOrderTime(input string) (time.Time, error) {
	now := time.Now()
	if input == "" {
		return now, nil
	}
	parsed, err := time.Parse("15:04:05", input)
	if err != nil {
		parsed, err = time.Parse("15:04", input)
		if err != nil {
			return now, fmt.Errorf("invalid time format %q, expected HH:MM or HH:MM:SS: %w", input, err)
		}
	}
	return time.Date(now.Year(), now.Month(), now.Day(), parsed.Hour(), parsed.Minute(), parsed.Second(), 0, now.Location()), nil
}

func resolveOptions(ctx context.Context, client *firestore.Client, selectedIDs []string, double, triple bool) ([]firebase.OrderOption, error) {

	var refs []*firestore.DocumentRef
	for coll := range firebase.OptionCollections {
		for _, optID := range selectedIDs {
			refs = append(refs, client.Collection(coll).Doc(optID))
		}
	}

	snaps, err := client.GetAll(ctx, refs)
	if err != nil {
		return nil, fmt.Errorf("getting options: %w", err)
	}

	optionsByCollection := make(map[string]firebase.OrderOption)
	for _, snap := range snaps {
		if !snap.Exists() {
			continue
		}

		var item firebase.Option
		if err := snap.DataTo(&item); err != nil {
			return nil, fmt.Errorf("decoding option %s: %w", snap.Ref.ID, err)
		}

		coll := snap.Ref.Parent.ID
		optionsByCollection[coll] = firebase.OrderOption{
			Collection: coll,
			OptionName: item.Name,
			OptionID:   snap.Ref.ID,
			OptionRef:  snap.Ref,
			Count: func() int {
				if coll == firebase.CollBeans {
					if triple {
						return 3
					}
					if double {
						return 2
					}
				}
				return 1
			}(),
		}
	}

	var finalOptions []firebase.OrderOption
	for _, opt := range optionsByCollection {
		finalOptions = append(finalOptions, opt)
	}

	return finalOptions, nil
}

func getQueuePosition(ctx context.Context, client *firestore.Client, orderAt time.Time) (int, error) {

	ordersIter := client.Collection("order").
		Where("orderTimestamp", ">", orderAt.Truncate(24*time.Hour).UnixMilli()).
		Where("orderTimestamp", "<", orderAt.UnixMilli()).
		Documents(ctx)
	defer ordersIter.Stop()

	orders, err := firebase.LoadRows[*firebase.Order](ordersIter)
	if err != nil {
		return 0, fmt.Errorf("getting queue position: %w", err)
	}

	queuingCount := lo.PickBy(orders, func(key string, o *firebase.Order) bool {
		return o.Status == "queuing" || o.Status == "being-prepared"
	})

	return len(queuingCount) + 1, nil
}
