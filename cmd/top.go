package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/rodaine/table"
	"github.com/spf13/cobra"
	"google.golang.org/api/iterator"
)

var topAll bool

var topCmd = &cobra.Command{
	Use:   "top",
	Short: "Leaderboard of most orders in the last 28 days",
	RunE:  runTop,
}

func init() {
	topCmd.Flags().BoolVarP(&topAll, "all", "a", false, "Show all time leaderboard")
	RootCmd.AddCommand(topCmd)
}

func runTop(cmd *cobra.Command, args []string) error {

	ctx := context.Background()
	sess, client, err := authedClient(ctx)
	if err != nil {
		return err
	}
	defer client.Close()

	query := client.Collection("order").Query
	if !topAll {
		query = client.Collection("order").
			Where("orderTimestamp", ">", time.Now().AddDate(0, 0, -28).UnixMilli())
	}

	iter := query.Documents(ctx)
	defer iter.Stop()

	type userTally struct {
		Name  string
		Count int
	}

	counts := map[string]*userTally{}
	for {
		doc, err := iter.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return fmt.Errorf("listing orders: %w", err)
		}
		data := doc.Data()
		status, _ := data["status"].(string)
		if status == "cancelled" {
			continue
		}
		userId, _ := data["userId"].(string)
		userName, _ := data["userName"].(string)
		if userId == "" {
			continue
		}
		if t, ok := counts[userId]; ok {
			t.Count++
		} else {
			counts[userId] = &userTally{Name: userName, Count: 1}
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
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Count > entries[j].Count
	})

	var buf bytes.Buffer
	tbl := table.New("#", "Name", "Orders").WithWriter(&buf)

	myRank := -1
	for i, e := range entries {
		if e.UserID == sess.UID {
			myRank = i
		}
		if i < 20 {
			tbl.AddRow(i+1, e.Name, e.Count)
		}
	}

	// Show own row if outside top 20
	if myRank >= 20 {
		tbl.AddRow("", "---", "---")
		tbl.AddRow(myRank+1, entries[myRank].Name, entries[myRank].Count)
	}

	tbl.Print()
	fmt.Fprint(cmd.OutOrStdout(), buf.String())

	return nil
}
