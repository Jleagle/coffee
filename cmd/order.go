package cmd

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/spf13/cobra"
)

var orderCmd = &cobra.Command{
	Use:   "order [drink-id]",
	Short: "Order a drink by its ID",
	Args:  cobra.ExactArgs(1),
	RunE:  runOrder,
}

func init() {
	RootCmd.AddCommand(orderCmd)
	orderCmd.SetHelpCommand(&cobra.Command{Hidden: true})
}

func runOrder(cmd *cobra.Command, args []string) error {
	drinkID := args[0]

	ctx := context.Background()
	sess, client, err := authedClient(ctx)
	if err != nil {
		return err
	}
	defer client.Close()

	// Read the drink
	drinkDoc, err := client.Collection("drinks").Doc(drinkID).Get(ctx)
	if err != nil {
		return fmt.Errorf("reading drink %s: %w", drinkID, err)
	}
	drink := drinkDoc.Data()
	drinkName, _ := drink["name"].(string)
	cmd.Printf("\nDrink: %s\n", drinkName)

	// Resolve default options
	options, err := resolveOptions(ctx, client, drink)
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

	// Create the order
	now := time.Now()
	order := map[string]any{
		"userName":             sess.DisplayName,
		"userId":               sess.UID,
		"userEmail":            sess.Email,
		"drinkName":            drinkName,
		"drinkId":              drinkID,
		"options":              options,
		"orderTimestamp":       now.UnixMilli(),
		"lastUpdatedTimestamp": now.UnixMilli(),
		"status":               "queuing",
	}

	cmd.Println("\nCreating order:")
	if err := prettyPrint(cmd, order); err != nil {
		return fmt.Errorf("printing order: %w", err)
	}

	docRef, _, err := client.Collection("order").Add(ctx, order)
	if err != nil {
		return fmt.Errorf("creating order: %w", err)
	}
	cmd.Printf("\nOrder created successfully! Document ID: %s\n", docRef.ID)
	return nil
}

type orderOption struct {
	Collection string                 `firestore:"collection" json:"collection"`
	OptionName string                 `firestore:"optionName" json:"optionName"`
	OptionRef  *firestore.DocumentRef `firestore:"optionRef" json:"optionRef"`
	OptionID   string                 `firestore:"optionId" json:"optionId"`
	Count      int                    `firestore:"count,omitempty" json:"count,omitempty"`
}

func resolveOptions(ctx context.Context, client *firestore.Client, drink map[string]any) ([]orderOption, error) {
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
