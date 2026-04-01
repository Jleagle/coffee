package cmd

import (
	"context"
	"encoding/json"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/helpers"
	"github.com/spf13/cobra"
)

var RootCmd = &cobra.Command{
	Use:               "coffee",
	Short:             "Order coffee from your terminal",
	CompletionOptions: cobra.CompletionOptions{DisableDefaultCmd: true},
}

func init() {
}

func authedClient(ctx context.Context) (*helpers.Session, *firestore.Client, error) {
	sess, err := helpers.GetAuth(RootCmd.Printf)
	if err != nil {
		return nil, nil, err
	}
	client, err := helpers.NewFirestoreClient(ctx, sess.IDToken)
	if err != nil {
		return nil, nil, err
	}
	return sess, client, nil
}

func prettyPrint(cmd *cobra.Command, v any) error {
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
