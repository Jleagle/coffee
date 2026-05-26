package firebase

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/session"
	"github.com/spf13/cobra"
	"golang.org/x/oauth2"
	"google.golang.org/api/iterator"
	"google.golang.org/api/option"
)

var (
	VarProjectID = os.Getenv("COFFEE_PROJECT_ID")
	VarAPIKey    = os.Getenv("COFFEE_API_KEY")
)

func AuthedClient(ctx context.Context, printer func(format string, a ...any)) (*session.Session, *firestore.Client, error) {

	if VarProjectID == "" {
		return nil, nil, fmt.Errorf("required environment variable COFFEE_PROJECT_ID is not set")
	}

	sess, err := getAuth(printer)
	if err != nil {
		return nil, nil, err
	}

	ts := oauth2.StaticTokenSource(&oauth2.Token{AccessToken: sess.IDToken, TokenType: "Bearer"})
	client, err := firestore.NewClient(ctx, VarProjectID, option.WithTokenSource(ts))
	if err != nil {
		return nil, nil, fmt.Errorf("creating firestore client: %w", err)
	}

	return sess, client, nil
}

func GetToken(refreshToken string) (newIDToken, newRefreshToken string, err error) {

	if VarAPIKey == "" {
		return "", "", fmt.Errorf("required environment variable COFFEE_API_KEY is not set")
	}

	payload := fmt.Sprintf("grant_type=refresh_token&refresh_token=%s", refreshToken)
	apiURL := "https://securetoken.googleapis.com/v1/token?key=" + VarAPIKey
	resp, err := http.Post(apiURL, "application/x-www-form-urlencoded", strings.NewReader(payload))
	if err != nil {
		return "", "", fmt.Errorf("POST to token refresh: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", "", fmt.Errorf("reading refresh response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("token refresh returned %d: %s", resp.StatusCode, body)
	}

	var result Token
	if err := json.Unmarshal(body, &result); err != nil {
		return "", "", fmt.Errorf("parsing refresh response: %w", err)
	}
	if result.IDToken == "" {
		return "", "", fmt.Errorf("no id_token in refresh response")
	}
	if result.RefreshToken == "" {
		result.RefreshToken = refreshToken
	}

	return result.IDToken, result.RefreshToken, nil
}

func GetAccount(idToken string) (account Account, err error) {

	if VarAPIKey == "" {
		return account, fmt.Errorf("required environment variable COFFEE_API_KEY is not set")
	}

	data, err := json.Marshal(map[string]string{"idToken": idToken})
	if err != nil {
		return account, fmt.Errorf("marshalling lookup payload: %w", err)
	}

	apiURL := "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=" + VarAPIKey
	resp, err := http.Post(apiURL, "application/json", bytes.NewReader(data))
	if err != nil {
		return account, fmt.Errorf("POST to accounts:lookup: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return account, fmt.Errorf("reading lookup response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return account, fmt.Errorf("accounts:lookup returned %d: %s", resp.StatusCode, body)
	}

	var result struct {
		Users []Account `json:"users"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return account, fmt.Errorf("parsing lookup response: %w", err)
	}
	if len(result.Users) == 0 {
		return account, fmt.Errorf("no user found for token")
	}

	return result.Users[0], nil
}

// getAuth returns a valid session with Firebase ID token.
func getAuth(printer func(format string, a ...any)) (*session.Session, error) {

	s, err := session.Load()
	if err != nil {
		return nil, fmt.Errorf("no session found, use set-token")
	}

	_, err = GetAccount(s.IDToken)
	if err == nil {
		return s, nil
	}

	printer("Session expired, refreshing...\n")
	newID, newRefresh, err := GetToken(s.RefreshToken)
	if err == nil {
		s.IDToken = newID
		s.RefreshToken = newRefresh
		if saveErr := session.Save(s); saveErr != nil {
			printer("Warning: could not save refreshed session: %v\n", saveErr)
		}
		return s, nil
	}

	return nil, fmt.Errorf("refresh failed (%v), use set-token", err)
}

func LoadRows[T Modeler](iter *firestore.DocumentIterator) (map[string]T, error) {

	m := map[string]T{}
	for {
		doc, err := iter.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return nil, err
		}

		var d T
		if err := doc.DataTo(&d); err != nil {
			return nil, fmt.Errorf("decoding row %s: %w", doc.Ref.ID, err)
		}
		d.SetID(doc)
		m[d.GetID()] = d
	}

	return m, nil
}

func LoadRow[T Modeler](ctx context.Context, client *firestore.Client, collection string, id string) (T, error) {
	var d T
	snap, err := client.Collection(collection).Doc(id).Get(ctx)
	if err != nil {
		return d, err
	}
	if err := snap.DataTo(&d); err != nil {
		return d, err
	}
	d.SetID(snap)
	return d, nil
}

func WaitForShopOpen(ctx context.Context, client *firestore.Client, cmd *cobra.Command) (bool, error) {
	doc := client.Collection("coffeeShop").Doc("info")

	// Initial check
	info, err := LoadRow[*ShopInfo](ctx, client, "coffeeShop", "info")
	if err != nil {
		return false, fmt.Errorf("reading shop status: %w", err)
	}
	if info.Open {
		return false, nil
	}

	cmd.Printf("The coffee shop is currently closed. Waiting for it to open...\n")

	iter := doc.Snapshots(ctx)
	defer iter.Stop()
	for {
		snap, err := iter.Next()
		if err != nil {
			return false, fmt.Errorf("listening for shop status: %w", err)
		}

		var info ShopInfo
		if err := snap.DataTo(&info); err != nil {
			return false, fmt.Errorf("decoding shop status: %w", err)
		}

		if info.Open {
			cmd.Printf("The coffee shop is now open!\n")
			_ = exec.Command("afplay", "/System/Library/Sounds/Funk.aiff").Run()
			return true, nil
		}
	}
}
