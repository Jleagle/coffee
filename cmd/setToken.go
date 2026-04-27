package cmd

import (
	"fmt"

	"github.com/Jleagle/coffee/firebase"
	"github.com/Jleagle/coffee/session"
	"github.com/spf13/cobra"
)

var setTokenRefresh string

func init() {
	setTokenCmd.Flags().StringVarP(&setTokenRefresh, "token", "t", "", "Refresh token from another session")
	setTokenCmd.MarkFlagRequired("token")
	RootCmd.AddCommand(setTokenCmd)
}

var setTokenCmd = &cobra.Command{
	Use:   "set-token --token [refresh-token]",
	Short: "Set session from a refresh token",
	RunE: func(cmd *cobra.Command, args []string) error {

		cmd.Printf("Exchanging refresh token...\n")

		idToken, refreshToken, err := firebase.GetToken(setTokenRefresh)
		if err != nil {
			return fmt.Errorf("refreshing token: %w", err)
		}

		account, err := firebase.GetAccount(idToken)
		if err != nil {
			return fmt.Errorf("looking up user: %w", err)
		}

		s := &session.Session{
			IDToken:      idToken,
			RefreshToken: refreshToken,
			UID:          account.LocalID,
			Email:        account.Email,
			DisplayName:  account.DisplayName,
		}

		if err := session.Save(s); err != nil {
			return fmt.Errorf("saving session: %w", err)
		}

		cmd.Println("User set to %s (%s)", account.Email, account.LocalID)
		return nil
	},
}
