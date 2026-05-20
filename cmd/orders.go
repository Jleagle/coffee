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
	"github.com/samber/lo"
	"github.com/spf13/cobra"
)

var (
	ordersWatch     bool
	ordersCancelled bool
)

func init() {
	ordersCmd.Flags().BoolVarP(&ordersWatch, "watch", "w", false, "Refresh every 10 seconds")
	ordersCmd.Flags().BoolVarP(&ordersCancelled, "cancelled", "c", false, "Show cancelled orders")
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

	start := time.Now().Truncate(24 * time.Hour).UnixMilli()
	q := client.Collection("order").Where("orderTimestamp", ">", start)
	iter := q.OrderBy("orderTimestamp", firestore.Asc).Documents(ctx)
	defer iter.Stop()

	ordersMap, err := firebase.LoadRows[*firebase.Order](iter)
	if err != nil {
		return fmt.Errorf("loading orders: %w", err)
	}

	orders := lo.Values(ordersMap)

	// Filter cancelled
	orders = lo.Filter(orders, func(o *firebase.Order, _ int) bool {
		return !(!ordersCancelled && o.Status == "cancelled")
	})

	if len(orders) == 0 {
		cmd.Println("No orders found today.")
		return nil
	}

	// Sort by time
	slices.SortFunc(orders, func(a, b *firebase.Order) int {
		return cmp.Compare(a.OrderTimestamp, b.OrderTimestamp)
	})

	var buf bytes.Buffer
	tbl := table.New("#", "Time", "Name", "Drink", "Status").WithWriter(&buf)

	for k, o := range orders {
		ts := time.UnixMilli(o.OrderTimestamp).Format(time.TimeOnly)

		drinkName := o.DrinkName
		for _, opt := range o.Options {
			if opt.Collection == firebase.CollBeans && opt.Count > 1 {
				drinkName += fmt.Sprintf(" x%d", opt.Count)
				break
			}
		}

		tbl.AddRow(k+1, ts, o.UserName, drinkName, o.Status)
	}
	tbl.Print()

	// Apply colours
	out := strings.ReplaceAll(buf.String(), "cancelled", color.HiRedString("cancelled"))
	out = strings.ReplaceAll(out, "completed", color.HiGreenString("completed"))
	if sess.DisplayName != "" {
		out = strings.ReplaceAll(out, sess.DisplayName, color.HiBlueString(sess.DisplayName))
	}

	_, err = fmt.Fprint(cmd.OutOrStdout(), out)
	if err != nil {
		return err
	}

	// Show queue size
	queuingCount := lo.CountBy(orders, func(o *firebase.Order) bool {
		return o.Status == "queuing" || o.Status == "being-prepared"
	})

	cmd.Printf("\nPeople queuing: %d\n", queuingCount+1)

	if ordersWatch {
		cmd.Printf("\nLast updated: %s (Ctrl+C to stop)\n", time.Now().Format("15:04:05"))
	}

	return nil
}
