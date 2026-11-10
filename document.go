package cruflags

import (
	"bytes"
	"encoding/json"
	"maps"
	"time"
)

// Document is a flag document as the service publishes it. Only Flag.Enabled
// changes behavior; the rest is carried for display and debugging.
type Document struct {
	Project     string          `json:"Project,omitempty"`
	Environment string          `json:"Environment,omitempty"`
	Version     int64           `json:"Version,omitempty"`
	NotifySlack bool            `json:"NotifySlack"`
	Flags       map[string]Flag `json:"Flags"`
}

// Flag is one entry in a Document.
type Flag struct {
	Enabled     bool      `json:"Enabled"`
	Description string    `json:"Description,omitempty"`
	CreatedAt   time.Time `json:"CreatedAt,omitzero"`
	UpdatedAt   time.Time `json:"UpdatedAt,omitzero"`
	UpdatedBy   string    `json:"UpdatedBy,omitempty"`
}

func (d *Document) clone() *Document {
	c := *d
	c.Flags = maps.Clone(d.Flags)
	return &c
}

// parseDocument turns a response body into a Document. It rejects only what
// makes the body unusable: anything that is not a JSON object, and a Flags
// that is present but not an object. Everything else is lenient, because an
// older client must never reject a document from a newer service:
//
//   - Unknown keys, top-level or per flag, are ignored.
//   - A missing or null Flags means no flags.
//   - A flag entry that is not an object is dropped, not fatal: one bad flag
//     must not blind the app to the rest.
//   - Enabled is on only when it is the JSON literal true. "true", 1 and null
//     are all off.
//   - A metadata field of the wrong type is left at its zero value.
func parseDocument(body []byte) (*Document, error) {
	// A leading UTF-8 byte-order mark is not JSON, but the Node and Python
	// clients accept one, so this one does too.
	body = bytes.TrimPrefix(body, []byte("\xef\xbb\xbf"))
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, &FetchError{Code: CodeParse, Message: "flag document is not a JSON object", Err: err}
	}
	if raw == nil {
		return nil, &FetchError{Code: CodeParse, Message: "flag document is not a JSON object, got null"}
	}

	doc := &Document{Flags: map[string]Flag{}}
	lenient(raw["Project"], &doc.Project)
	lenient(raw["Environment"], &doc.Environment)
	lenient(raw["Version"], &doc.Version)
	lenient(raw["NotifySlack"], &doc.NotifySlack)

	if flags, ok := raw["Flags"]; ok && !isNull(flags) {
		var entries map[string]json.RawMessage
		if err := json.Unmarshal(flags, &entries); err != nil {
			return nil, &FetchError{Code: CodeParse, Message: `flag document "Flags" is not an object`, Err: err}
		}
		for name, value := range entries {
			var entry map[string]json.RawMessage
			if json.Unmarshal(value, &entry) != nil || entry == nil {
				continue
			}
			flag := Flag{Enabled: isTrue(entry["Enabled"])}
			lenient(entry["Description"], &flag.Description)
			lenient(entry["UpdatedBy"], &flag.UpdatedBy)
			flag.CreatedAt = timestamp(entry["CreatedAt"])
			flag.UpdatedAt = timestamp(entry["UpdatedAt"])
			doc.Flags[name] = flag
		}
	}
	return doc, nil
}

// lenient decodes raw into v, leaving v unchanged when raw is absent or of
// another type.
func lenient[T any](raw json.RawMessage, v *T) {
	var decoded T
	if raw != nil && json.Unmarshal(raw, &decoded) == nil {
		*v = decoded
	}
}

func timestamp(raw json.RawMessage) time.Time {
	var s string
	lenient(raw, &s)
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

func isTrue(raw json.RawMessage) bool { return bytes.Equal(bytes.TrimSpace(raw), []byte("true")) }

func isNull(raw json.RawMessage) bool { return bytes.Equal(bytes.TrimSpace(raw), []byte("null")) }
