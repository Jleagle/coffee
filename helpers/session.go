package helpers

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
}

func sessionPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving home directory: %w", err)
	}
	return filepath.Join(home, ".coffee.json"), nil
}

func LoadSession() (*Session, error) {
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

func SaveSession(s *Session) error {
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
