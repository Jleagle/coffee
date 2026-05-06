package firebase

import (
	"time"

	"cloud.google.com/go/firestore"
)

type Modeler interface {
	GetID() string
	SetID(doc *firestore.DocumentSnapshot)
}

type Base struct {
	ID string `firestore:"-"`
}

func (b *Base) GetID() string {
	return b.ID
}

func (b *Base) SetID(doc *firestore.DocumentSnapshot) {
	b.ID = doc.Ref.ID
}

type Order struct {
	Base
	UserName       string        `firestore:"userName"`
	UserEmail      string        `firestore:"userEmail"`
	UserID         string        `firestore:"userId"`
	OrderTimestamp int64         `firestore:"orderTimestamp"`
	Options        []OrderOption `firestore:"options"`
	Status         string        `firestore:"status"`
	DrinkName      string        `firestore:"drinkName"`
	DrinkID        string        `firestore:"drinkId"`
	LastUpdated    int64         `firestore:"lastUpdatedTimestamp"`
}

type OrderOption struct {
	Base
	Collection string                 `firestore:"collection"`
	OptionName string                 `firestore:"optionName"`
	OptionRef  *firestore.DocumentRef `firestore:"optionRef"`
	OptionID   string                 `firestore:"optionId"`
	Count      int                    `firestore:"count"`
}

type ShopInfo struct {
	Base
	Open bool `firestore:"open"`
}

type Drink struct {
	Base
	DefaultOptions  map[string]any           `firestore:"defaultOptions"`
	OptionGroups    map[string]any           `firestore:"optionGroups"`
	Name            string                   `firestore:"name"`
	Categories      []*firestore.DocumentRef `firestore:"category"`
	Description     string                   `firestore:"description"`
	Image           string                   `firestore:"image"`
	RequiredOptions []string                 `firestore:"requiredOptions"`
}

type Option struct {
	Base
	Name string `firestore:"name"`
}

type DrinkCategory struct {
	Base
	Name  string `firestore:"name"`
	Order int    `firestore:"order"`
}

type Account struct {
	LocalID          string `json:"localId"`
	Email            string `json:"email"`
	DisplayName      string `json:"displayName"`
	PhotoURL         string `json:"photoUrl"`
	EmailVerified    bool   `json:"emailVerified"`
	ProviderUserInfo []struct {
		ProviderID  string `json:"providerId"`
		DisplayName string `json:"displayName"`
		PhotoUrl    string `json:"photoUrl"`
		FederatedID string `json:"federatedId"`
		Email       string `json:"email"`
		RawID       string `json:"rawId"`
	} `json:"providerUserInfo"`
	ValidSince    string    `json:"validSince"`
	LastLoginAt   string    `json:"lastLoginAt"`
	CreatedAt     string    `json:"createdAt"`
	CustomAuth    bool      `json:"customAuth"`
	LastRefreshAt time.Time `json:"lastRefreshAt"`
}

type Token struct {
	AccessToken  string `json:"access_token"`
	ExpiresIn    string `json:"expires_in"`
	TokenType    string `json:"token_type"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
	UserID       string `json:"user_id"`
	ProjectID    string `json:"project_id"`
}
