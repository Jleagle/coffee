package cmd

import (
	"bytes"
	"cmp"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/Jleagle/coffee/firebase"
	"github.com/fatih/color"
	"github.com/rodaine/table"
	"github.com/spf13/cobra"
)

var topUsersDays int
var topUsersLimit int
var topUsersShots bool

func init() {
	topCmd.Flags().IntVarP(&topUsersDays, "days", "d", 28, "Days to look back")
	topCmd.Flags().IntVarP(&topUsersLimit, "limit", "l", 20, "How many people to show")
	topCmd.Flags().BoolVarP(&topUsersShots, "shots", "s", false, "Order by shots")
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
		start := time.Now().AddDate(0, 0, -topUsersDays).UnixMilli()
		iter := client.Collection("order").Where("orderTimestamp", ">", start).Documents(cmd.Context())
		defer iter.Stop()

		orders, err := firebase.LoadRows[*firebase.Order](iter)
		if err != nil {
			return fmt.Errorf("loading orders: %w", err)
		}

		type userTally struct {
			Name  string
			Count int
			Shots int
		}

		counts := map[string]*userTally{}
		for _, order := range orders {
			if order.Status != "completed" {
				continue
			}
			if order.UserID == "" {
				continue
			}

			shots := 1
			for _, opt := range order.Options {
				if opt.Collection == "beans" {
					shots = opt.Count
				}
			}

			if t, ok := counts[order.UserID]; ok {
				t.Count++
				t.Shots += shots
			} else {
				counts[order.UserID] = &userTally{Name: order.UserName, Count: 1, Shots: shots}
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
			Shots  int
		}
		var entries []entry
		for uid, t := range counts {
			entries = append(entries, entry{UserID: uid, Name: t.Name, Count: t.Count, Shots: t.Shots})
		}
		slices.SortFunc(entries, func(i, j entry) int {
			if topUsersShots {
				return cmp.Compare(j.Shots, i.Shots)
			}
			return cmp.Compare(j.Count, i.Count)
		})

		// Build content
		var buf bytes.Buffer
		tbl := table.New("#", "Name", "Orders", "Shots").WithWriter(&buf)

		myRank := -1
		for i, e := range entries {
			if e.UserID == sess.UID {
				myRank = i
			}
			if i < topUsersLimit {
				tbl.AddRow(i+1, e.Name, e.Count, e.Shots)
			}
		}

		// Show own row if outside top 20
		if myRank >= topUsersLimit {
			tbl.AddRow("", "---", "---", "---")
			tbl.AddRow(myRank+1, entries[myRank].Name, entries[myRank].Count, entries[myRank].Shots)
		}

		tbl.Print()

		// Apply colours
		out := buf.String()
		if sess.DisplayName != "" {
			out = strings.ReplaceAll(out, sess.DisplayName, color.HiBlueString(sess.DisplayName))
		}

		// Output
		cmd.Println("Top users in the last", topUsersDays, "days:")
		_, err = fmt.Fprint(cmd.OutOrStdout(), out)
		if err != nil {
			return err
		}

		return nil
	},
}
