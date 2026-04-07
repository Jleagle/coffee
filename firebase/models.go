package firebase

import "cloud.google.com/go/firestore"

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
	UserName       string           `firestore:"userName"`
	UserEmail      string           `firestore:"userEmail"`
	UserID         string           `firestore:"userId"`
	OrderTimestamp int64            `firestore:"orderTimestamp"`
	Options        []map[string]any `firestore:"options"`
	Status         string           `firestore:"status"`
	DrinkName      string           `firestore:"drinkName"`
	DrinkID        string           `firestore:"drinkId"`
	LastUpdated    int64            `firestore:"lastUpdatedTimestamp"`
}

type OrderOption struct {
	Base
	Collection string                 `firestore:"collection"`
	OptionName string                 `firestore:"optionName"`
	OptionRef  *firestore.DocumentRef `firestore:"optionRef"`
	OptionID   string                 `firestore:"optionId"`
	Count      int                    `firestore:"count,omitempty"`
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
