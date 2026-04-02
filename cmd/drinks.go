package cmd

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/helpers"
	"github.com/rodaine/table"
	"github.com/spf13/cobra"
	"google.golang.org/api/iterator"
)

func init() {
	RootCmd.AddCommand(drinksCmd)
}

var drinksCmd = &cobra.Command{
	Use:   "drinks",
	Short: "List available drinks",
	RunE: func(cmd *cobra.Command, args []string) error {

		ctx := context.Background()
		_, client, err := helpers.AuthedClient(ctx, cmd.Printf)
		if err != nil {
			return err
		}
		defer client.Close()

		// Load all categories by ID
		categories, err := loadCategories(ctx, client)
		if err != nil {
			return fmt.Errorf("loading categories: %w", err)
		}

		// Load all drinks with their category
		iter := client.Collection("drinks").OrderBy("name", firestore.Asc).Limit(100).Documents(ctx)
		defer iter.Stop()

		type drinkWithOrder struct {
			drinkEntry
			catOrder int
		}
		var drinks []drinkWithOrder

		for {
			doc, err := iter.Next()
			if errors.Is(err, iterator.Done) {
				break
			}
			if err != nil {
				return fmt.Errorf("listing drinks: %w", err)
			}
			data := doc.Data()
			name, _ := data["name"].(string)

			catName := "Uncategorized"
			catOrder := 9999
			if refs := extractCategoryRefs(data["category"]); len(refs) > 0 {
				if cat, ok := categories[refs[0].ID]; ok {
					catName = cat.Name
					catOrder = cat.Order
				}
			}

			drinks = append(drinks, drinkWithOrder{
				drinkEntry: drinkEntry{ID: doc.Ref.ID, Category: catName, Name: name},
				catOrder:   catOrder,
			})
		}

		sort.Slice(drinks, func(i, j int) bool {
			if drinks[i].catOrder != drinks[j].catOrder {
				return drinks[i].catOrder < drinks[j].catOrder
			}
			if drinks[i].Category != drinks[j].Category {
				return drinks[i].Category < drinks[j].Category
			}
			return drinks[i].Name < drinks[j].Name
		})

		tbl := table.New("ID", "Category", "Drink").WithWriter(cmd.OutOrStdout())
		for _, d := range drinks {
			tbl.AddRow(d.ID, d.Category, d.Name)
		}
		tbl.Print()
		return nil
	},
}

type drinkEntry struct {
	ID       string
	Category string
	Name     string
}

type categoryGroup struct {
	Name   string
	Order  int
	Drinks []drinkEntry
}

func loadCategories(ctx context.Context, client *firestore.Client) (map[string]*categoryGroup, error) {
	categories := map[string]*categoryGroup{}

	iter := client.Collection("drinkCategories").Documents(ctx)
	defer iter.Stop()

	for {
		doc, err := iter.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return nil, err
		}
		data := doc.Data()
		name, _ := data["name"].(string)
		order := 0
		switch v := data["order"].(type) {
		case int64:
			order = int(v)
		case float64:
			order = int(v)
		}
		categories[doc.Ref.ID] = &categoryGroup{Name: name, Order: order}
	}

	return categories, nil
}

func extractCategoryRefs(v any) []*firestore.DocumentRef {
	if v == nil {
		return nil
	}
	switch val := v.(type) {
	case *firestore.DocumentRef:
		return []*firestore.DocumentRef{val}
	case []any:
		var refs []*firestore.DocumentRef
		for _, item := range val {
			if ref, ok := item.(*firestore.DocumentRef); ok {
				refs = append(refs, ref)
			}
		}
		return refs
	default:
		return nil
	}
}
