package firebase

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/Jleagle/coffee/session"
	"golang.org/x/oauth2"
	"google.golang.org/api/iterator"
	"google.golang.org/api/option"
)

var (
	varAPIKey     = os.Getenv("COFFEE_API_KEY")
	varAuthDomain = os.Getenv("COFFEE_AUTH_DOMAIN")
	varAppID      = os.Getenv("COFFEE_APP_ID")
	varProjectID  = os.Getenv("COFFEE_PROJECT_ID")
)

func AuthedClient(ctx context.Context, printer func(format string, a ...any)) (*session.Session, *firestore.Client, error) {
	sess, err := GetAuth(printer)
	if err != nil {
		return nil, nil, err
	}
	client, err := newFirestoreClient(ctx, sess.IDToken)
	if err != nil {
		return nil, nil, err
	}
	return sess, client, nil
}

//go:embed signin.html
var signInHTML string

func doFirebaseAuth(printer func(format string, a ...any)) (firebaseToken, uid string, err error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", "", fmt.Errorf("starting local server: %w", err)
	}
	port := listener.Addr().(*net.TCPAddr).Port

	type authResult struct {
		Token        string `json:"token"`
		RefreshToken string `json:"refreshToken"`
		UID          string `json:"uid"`
		Email        string `json:"email"`
		DisplayName  string `json:"displayName"`
		Error        string `json:"error"`
	}

	resultCh := make(chan authResult, 1)
	errCh := make(chan error, 1)

	mux := http.NewServeMux()

	signInTmpl, err := template.New("signin").Parse(signInHTML)
	if err != nil {
		return "", "", fmt.Errorf("parsing signin template: %w", err)
	}

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		signInTmpl.Execute(w, map[string]any{
			"APIKey":     varAPIKey,
			"AuthDomain": varAuthDomain,
			"ProjectID":  varProjectID,
			"AppID":      varAppID,
			"Port":       port,
		})
	})

	mux.HandleFunc("/auth-callback", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "failed to read body", http.StatusBadRequest)
			return
		}
		defer r.Body.Close()

		var result authResult
		if err := json.Unmarshal(body, &result); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"ok":true}`)
		resultCh <- result
	})

	srv := &http.Server{Handler: mux}
	go func() {
		if serveErr := srv.Serve(listener); serveErr != nil && serveErr != http.ErrServerClosed {
			errCh <- fmt.Errorf("local server: %w", serveErr)
		}
	}()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(ctx)
	}()

	localURL := fmt.Sprintf("http://localhost:%d", port)
	printer("Opening browser for Google sign-in...\n")
	printer("If the browser doesn't open, visit: %s\n\n", localURL)
	if err := exec.Command("open", localURL).Start(); err != nil {
		printer("Warning: could not open browser: %v\n", err)
	}

	select {
	case result := <-resultCh:
		if result.Error != "" {
			return "", "", fmt.Errorf("sign-in failed: %s", result.Error)
		}
		if result.Token == "" {
			return "", "", fmt.Errorf("no token received from sign-in")
		}
		printer("Signed in as: %s (uid: %s)\n", result.Email, result.UID)

		s := &session.Session{
			IDToken:      result.Token,
			RefreshToken: result.RefreshToken,
			UID:          result.UID,
			Email:        result.Email,
			DisplayName:  result.DisplayName,
		}
		if saveErr := session.Save(s); saveErr != nil {
			printer("Warning: could not save session: %v\n", saveErr)
		}

		return result.Token, result.UID, nil
	case err := <-errCh:
		return "", "", err
	case <-time.After(2 * time.Minute):
		return "", "", fmt.Errorf("authentication timed out after 2 minutes")
	}
}

func newFirestoreClient(ctx context.Context, idToken string) (*firestore.Client, error) {
	ts := oauth2.StaticTokenSource(&oauth2.Token{AccessToken: idToken})
	client, err := firestore.NewClient(ctx, varProjectID, option.WithTokenSource(ts))
	if err != nil {
		return nil, fmt.Errorf("creating firestore client: %w", err)
	}
	return client, nil
}

func GetToken(refreshToken string) (newIDToken, newRefreshToken string, err error) {
	payload := fmt.Sprintf("grant_type=refresh_token&refresh_token=%s", refreshToken)
	apiURL := "https://securetoken.googleapis.com/v1/token?key=" + varAPIKey
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

	data, err := json.Marshal(map[string]string{"idToken": idToken})
	if err != nil {
		return account, fmt.Errorf("marshalling lookup payload: %w", err)
	}

	apiURL := "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=" + varAPIKey
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

// GetAuth returns a valid session with Firebase ID token.
func GetAuth(printer func(format string, a ...any)) (*session.Session, error) {
	s, err := session.Load()
	if err == nil {
		_, err := GetAccount(s.IDToken)
		if err == nil {
			//printer("Authenticated as: %s (%s)\n", s.Email, s.UID)
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
			//printer("Authenticated as: %s (%s)\n", s.Email, s.UID)
			return s, nil
		}
		printer("Refresh failed (%v), re-authenticating...\n", err)
	}

	token, uid, err := doFirebaseAuth(printer)
	if err != nil {
		return nil, err
	}
	s, err = session.Load()
	if err != nil {
		return &session.Session{IDToken: token, UID: uid}, nil
	}
	return s, nil
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
			return nil, fmt.Errorf("decoding category %s: %w", doc.Ref.ID, err)
		}

		d.SetID(doc)

		m[d.GetID()] = d
	}

	return m, nil
}
