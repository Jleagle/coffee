package cmd

import (
	"bytes"
	"cmp"
	"fmt"
	"slices"
	"time"

	"github.com/Jleagle/coffee/firebase"
	"github.com/rodaine/table"
	"github.com/spf13/cobra"
)

var topDays int
var topLimit int

func init() {
	topCmd.Flags().IntVarP(&topDays, "days", "d", 28, "Days to look back")
	topCmd.Flags().IntVarP(&topLimit, "limit", "l", 20, "How many people to show")
	RootCmd.AddCommand(topCmd)
}

var topCmd = &cobra.Command{
	Use:   "top-users",
	Short: "List users by number of orders",
	RunE: func(cmd *cobra.Command, args []string) error {

		sess, client, err := firebase.AuthedClient(cmd.Context(), cmd.Printf)
		if err != nil {
			return err
		}
		defer client.Close()

		// Load orders
		start := time.Now().AddDate(0, 0, -topDays).UnixMilli()
		iter := client.Collection("order").Where("orderTimestamp", ">", start).Documents(cmd.Context())
		defer iter.Stop()

		orders, err := firebase.LoadRows[*firebase.Order](iter)
		if err != nil {
			return fmt.Errorf("loading orders: %w", err)
		}

		type userTally struct {
			Name  string
			Count int
		}

		counts := map[string]*userTally{}
		for _, order := range orders {
			if order.Status != "completed" {
				continue
			}
			if order.UserID == "" {
				continue
			}
			if t, ok := counts[order.UserID]; ok {
				t.Count++
			} else {
				counts[order.UserID] = &userTally{Name: order.UserName, Count: 1}
			}
		}

		if len(counts) == 0 {
			cmd.Println("No orders found.")
			return nil
		}

		// Convert to slice to sort
		type entry struct {
			UserID string
			Name   string
			Count  int
		}
		var entries []entry
		for uid, t := range counts {
			entries = append(entries, entry{UserID: uid, Name: t.Name, Count: t.Count})
		}
		slices.SortFunc(entries, func(i, j entry) int {
			return cmp.Compare(j.Count, i.Count)
		})

		var buf bytes.Buffer
		tbl := table.New("#", "Name", "Orders").WithWriter(&buf)

		myRank := -1
		for i, e := range entries {
			if e.UserID == sess.UID {
				myRank = i
			}
			if i < topLimit {
				tbl.AddRow(i+1, e.Name, e.Count)
			}
		}

		// Show own row if outside top 20
		if myRank >= topLimit {
			tbl.AddRow("", "---", "---")
			tbl.AddRow(myRank+1, entries[myRank].Name, entries[myRank].Count)
		}

		tbl.Print()
		_, err = fmt.Fprint(cmd.OutOrStdout(), buf.String())
		if err != nil {
			return err
		}

		return nil
	},
}
