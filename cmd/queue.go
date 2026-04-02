package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/helpers"
	"github.com/rodaine/table"
	"github.com/spf13/cobra"
	"google.golang.org/api/iterator"
)

var (
	ordersWatch bool
	ordersMine  bool
)

func init() {
	ordersCmd.Flags().BoolVarP(&ordersWatch, "watch", "w", false, "Refresh every 10 seconds")
	ordersCmd.Flags().BoolVarP(&ordersMine, "mine", "m", false, "Show only your orders")
	RootCmd.AddCommand(ordersCmd)
}

var ordersCmd = &cobra.Command{
	Use:   "queue",
	Short: "List your orders",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
		defer cancel()

		sess, client, err := helpers.AuthedClient(ctx, cmd.Printf)
		if err != nil {
			return err
		}
		defer client.Close()

		if err := printOrders(ctx, cmd, client, sess); err != nil {
			return err
		}

		if !ordersWatch {
			return nil
		}

		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return nil
			case <-ticker.C:
				// Clear screen and reprint
				cmd.Print("\033[2J\033[H")
				if err := printOrders(ctx, cmd, client, sess); err != nil {
					return err
				}
			}
		}
	},
}

type orderEntry struct {
	ID        string
	UserName  string
	DrinkName string
	Status    string
	Timestamp int64
}

func printOrders(ctx context.Context, cmd *cobra.Command, client *firestore.Client, sess *helpers.Session) error {

	iter := client.Collection("order").
		Where("orderTimestamp", ">", time.Now().Truncate(24*time.Hour).UnixMilli()). // Start of day
		OrderBy("orderTimestamp", firestore.Asc).
		Documents(ctx)

	defer iter.Stop()

	var orders []orderEntry
	for {
		doc, err := iter.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return fmt.Errorf("listing orders: %w", err)
		}
		data := doc.Data()
		userName, _ := data["userName"].(string)
		drinkName, _ := data["drinkName"].(string)
		status, _ := data["status"].(string)
		userId, _ := data["userId"].(string)

		if ordersMine && userId != sess.UID {
			continue
		}

		var ts int64
		switch v := data["orderTimestamp"].(type) {
		case int64:
			ts = v
		case float64:
			ts = int64(v)
		}

		orders = append(orders, orderEntry{
			ID:        doc.Ref.ID,
			UserName:  userName,
			DrinkName: drinkName,
			Status:    status,
			Timestamp: ts,
		})
	}

	if len(orders) == 0 {
		cmd.Println("No orders found today.")
		return nil
	}

	var buf bytes.Buffer
	tbl := table.New("Time", "Name", "Drink", "Status").WithWriter(&buf)
	for _, o := range orders {
		ts := time.UnixMilli(o.Timestamp).Format(time.TimeOnly)
		tbl.AddRow(ts, o.UserName, o.DrinkName, o.Status)
	}
	tbl.Print()

	// Apply colors after table formatting so column widths aren't affected
	output := buf.String()
	output = strings.ReplaceAll(output, "cancelled", "\033[31mcancelled\033[0m")
	output = strings.ReplaceAll(output, "completed", "\033[32mcompleted\033[0m")
	fmt.Fprint(cmd.OutOrStdout(), output)

	if ordersWatch {
		cmd.Printf("\nLast updated: %s (Ctrl+C to stop)\n", time.Now().Format("15:04:05"))
	}
	return nil
}
