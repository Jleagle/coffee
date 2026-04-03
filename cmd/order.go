package cmd

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/helpers"
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
		sess, client, err := helpers.AuthedClient(ctx, cmd.Printf)
		if err != nil {
			return err
		}
		defer client.Close()

		// Read the drink
		drinkDoc, err := client.Collection("drinks").Doc(orderDrinkID).Get(ctx)
		if err != nil {
			return fmt.Errorf("reading drink %s: %w", orderDrinkID, err)
		}

		drink := drinkDoc.Data()
		drinkName, _ := drink["name"].(string)
		cmd.Printf("\nDrink: %s\n", drinkName)

		// Resolve default options
		options, err := resolveOptions(ctx, drink)
		if err != nil {
			return fmt.Errorf("resolving options: %w", err)
		}
		if len(options) > 0 {
			cmd.Println("\nOptions:")
			for _, opt := range options {
				count := ""
				if opt.Count > 0 {
					count = fmt.Sprintf(" x%d", opt.Count)
				}
				cmd.Printf("  - %s: %s%s\n", opt.Collection, opt.OptionName, count)
			}
		}

		// Resolve order time
		now := time.Now()
		if orderTime != "" {
			parsed, err := time.Parse("15:04", orderTime)
			if err != nil {
				return fmt.Errorf("invalid time format %q, expected HH:MM: %w", orderTime, err)
			}
			now = time.Date(now.Year(), now.Month(), now.Day(), parsed.Hour(), parsed.Minute(), 0, 0, now.Location())
		}
		order := map[string]any{
			"userName":             sess.DisplayName,
			"userId":               sess.UID,
			"userEmail":            sess.Email,
			"drinkName":            drinkName,
			"drinkId":              orderDrinkID,
			"options":              options,
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

type orderOption struct {
	Collection string                 `firestore:"collection" json:"collection"`
	OptionName string                 `firestore:"optionName" json:"optionName"`
	OptionRef  *firestore.DocumentRef `firestore:"optionRef" json:"optionRef"`
	OptionID   string                 `firestore:"optionId" json:"optionId"`
	Count      int                    `firestore:"count,omitempty" json:"count,omitempty"`
}

func resolveOptions(ctx context.Context, drink map[string]any) ([]orderOption, error) {
	optionGroups, ok := drink["optionGroups"].(map[string]any)
	if !ok {
		return nil, nil
	}

	var options []orderOption
	for groupName, refs := range optionGroups {
		var refList []*firestore.DocumentRef
		switch v := refs.(type) {
		case []*firestore.DocumentRef:
			refList = v
		case *firestore.DocumentRef:
			refList = []*firestore.DocumentRef{v}
		case []any:
			for _, item := range v {
				if ref, ok := item.(*firestore.DocumentRef); ok {
					refList = append(refList, ref)
				}
			}
		default:
			continue
		}

		if len(refList) == 0 {
			continue
		}

		ref := refList[0]
		doc, err := ref.Get(ctx)
		if err != nil {
			return nil, fmt.Errorf("reading option %s/%s: %w", groupName, ref.ID, err)
		}
		optData := doc.Data()
		name, _ := optData["name"].(string)

		opt := orderOption{
			Collection: groupName,
			OptionName: name,
			OptionRef:  ref,
			OptionID:   ref.ID,
		}

		if groupName == "beans" {
			opt.Count = 1
		}

		options = append(options, opt)
	}

	return options, nil
}
