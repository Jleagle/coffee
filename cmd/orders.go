package cmd

import (
	"bytes"
	"cmp"
	"context"
	"fmt"
	"os"
	"os/signal"
	"slices"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/firebase"
	"github.com/Jleagle/coffee/session"
	"github.com/fatih/color"
	"github.com/rodaine/table"
	"github.com/spf13/cobra"
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
	Use:     "queue",
	Aliases: []string{"orders"},
	Short:   "Show todays queue",
	RunE: func(cmd *cobra.Command, args []string) error {

		ctx, cancel := signal.NotifyContext(cmd.Context(), os.Interrupt)
		defer cancel()

		sess, client, err := firebase.AuthedClient(ctx, cmd.Printf)
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

func printOrders(ctx context.Context, cmd *cobra.Command, client *firestore.Client, sess *session.Session) error {

	q := client.Collection("order").
		Where("orderTimestamp", ">", time.Now().Truncate(24*time.Hour).UnixMilli()) // Start of day
	if ordersMine {
		q = q.Where("userId", "==", sess.UID)
	}
	iter := q.OrderBy("orderTimestamp", firestore.Asc).Documents(ctx)
	defer iter.Stop()

	ordersMap, err := firebase.LoadRows[*firebase.Order](iter)
	if err != nil {
		return fmt.Errorf("loading orders: %w", err)
	}

	orders := make([]*firebase.Order, 0, len(ordersMap))
	for _, o := range ordersMap {
		orders = append(orders, o)
	}
	slices.SortFunc(orders, func(a, b *firebase.Order) int {
		return cmp.Compare(a.OrderTimestamp, b.OrderTimestamp)
	})

	if len(orders) == 0 {
		cmd.Println("No orders found today.")
		return nil
	}

	var buf bytes.Buffer
	tbl := table.New("Order", "Time", "Name", "Drink", "Status").WithWriter(&buf)
	for k, o := range orders {
		ts := time.UnixMilli(o.OrderTimestamp).Format(time.TimeOnly)
		tbl.AddRow(k+1, ts, o.UserName, o.DrinkName, o.Status)
	}
	tbl.Print()

	// Apply colors after table formatting so column widths aren't affected
	output := buf.String()
	output = strings.ReplaceAll(output, "cancelled", color.RedString("cancelled"))
	output = strings.ReplaceAll(output, "completed", color.GreenString("completed"))

	_, err = fmt.Fprint(cmd.OutOrStdout(), output)
	if err != nil {
		return err
	}

	if ordersWatch {
		cmd.Printf("\nLast updated: %s (Ctrl+C to stop)\n", time.Now().Format("15:04:05"))
	}
	return nil
}
