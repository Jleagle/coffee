package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type Session struct {
	IDToken      string `json:"id_token"`
	RefreshToken string `json:"refresh_token"`
	UID          string `json:"uid"`
	Email        string `json:"email"`
	DisplayName  string `json:"display_name"`

	// Written by the macOS menu bar app (macos/). Declared here so Save
	// doesn't drop them when the CLI rewrites the file on token refresh.
	ProjectID string     `json:"project_id,omitempty"`
	APIKey    string     `json:"api_key,omitempty"`
	LastOrder *LastOrder `json:"last_order,omitempty"`
}

// LastOrder is the most recent order placed from the menu bar app, kept so it
// can offer a one-click reorder.
type LastOrder struct {
	DrinkID   string            `json:"drink_id"`
	DrinkName string            `json:"drink_name"`
	Shots     int               `json:"shots,omitempty"`
	Options   []LastOrderOption `json:"options,omitempty"`
	PlacedAt  string            `json:"placed_at,omitempty"`
}

type LastOrderOption struct {
	Collection string `json:"collection"`
	ID         string `json:"id"`
	Name       string `json:"name"`
	Count      int    `json:"count,omitempty"`
}

func sessionPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving home directory: %w", err)
	}
	return filepath.Join(home, ".coffee.json"), nil
}

func Load() (*Session, error) {
	path, err := sessionPath()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Session
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	if s.IDToken == "" || s.RefreshToken == "" || s.UID == "" {
		return nil, fmt.Errorf("incomplete session in %s", path)
	}
	return &s, nil
}

func Save(s *Session) error {
	path, err := sessionPath()
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("marshalling session: %w", err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	return nil
}
