package cruflags

import (
	"errors"
	"testing"
	"time"
)

func TestParseDocumentReadsTheWireFormat(t *testing.T) {
	doc, err := parseDocument([]byte(`{
		"Project": "ararat", "Environment": "release-candidate", "Version": 3, "NotifySlack": true,
		"Flags": {"pilot_banner": {"Enabled": true, "Description": "Pilot", "CreatedAt": "2026-07-31T14:09:01.119Z",
			"UpdatedAt": "2026-07-31T14:09:08.777Z", "UpdatedBy": "Omicron7"}}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if doc.Project != "ararat" || doc.Environment != "release-candidate" || doc.Version != 3 || !doc.NotifySlack {
		t.Errorf("metadata = %+v", doc)
	}
	flag := doc.Flags["pilot_banner"]
	want := time.Date(2026, 7, 31, 14, 9, 8, 777_000_000, time.UTC)
	if !flag.Enabled || flag.Description != "Pilot" || flag.UpdatedBy != "Omicron7" || !flag.UpdatedAt.Equal(want) {
		t.Errorf("flag = %+v", flag)
	}
}

func TestParseDocumentRejectsWhatIsNotAnObject(t *testing.T) {
	for _, body := range []string{``, `{"Flags": `, `[]`, `null`, `"text"`, `3`, `{"Flags": []}`, `{"Flags": "x"}`} {
		_, err := parseDocument([]byte(body))
		var fetchErr *FetchError
		if !errors.As(err, &fetchErr) || fetchErr.Code != CodeParse {
			t.Errorf("parseDocument(%q) error = %v, want a CodeParse FetchError", body, err)
		}
	}
}

func TestParseDocumentIsLenientAboutEverythingElse(t *testing.T) {
	doc, err := parseDocument([]byte(`{
		"Version": "seven", "Project": 12, "Brand": "new",
		"Flags": {
			"real": {"Enabled": true, "Extra": {"nested": 1}},
			"string_true": {"Enabled": "true"}, "one": {"Enabled": 1}, "null": {"Enabled": null},
			"missing": {}, "not_an_object": true, "a_list": [1], "bad_time": {"Enabled": true, "UpdatedAt": "yesterday"}
		}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if doc.Version != 0 || doc.Project != "" {
		t.Errorf("mistyped metadata should be zero, got %+v", doc)
	}
	for name, want := range map[string]bool{"real": true, "string_true": false, "one": false, "null": false, "missing": false} {
		if got := doc.Flags[name].Enabled; got != want {
			t.Errorf("Flags[%q].Enabled = %v, want %v", name, got, want)
		}
	}
	for _, dropped := range []string{"not_an_object", "a_list"} {
		if _, ok := doc.Flags[dropped]; ok {
			t.Errorf("non-object entry %q should be dropped", dropped)
		}
	}
	if bad := doc.Flags["bad_time"]; !bad.Enabled || !bad.UpdatedAt.IsZero() {
		t.Errorf("an unparseable timestamp should be zero, not fatal: %+v", bad)
	}
}

func TestParseDocumentTreatsMissingOrNullFlagsAsNone(t *testing.T) {
	for _, body := range []string{`{}`, `{"Flags": null}`, `{"Flags": {}}`} {
		doc, err := parseDocument([]byte(body))
		if err != nil || doc.Flags == nil || len(doc.Flags) != 0 {
			t.Errorf("parseDocument(%s) = %+v, %v; want no flags and no error", body, doc, err)
		}
	}
}

func TestParseDocumentAcceptsAByteOrderMark(t *testing.T) {
	doc, err := parseDocument([]byte("\xef\xbb\xbf" + `{"Flags": {"a": {"Enabled": true}}}`))
	if err != nil || !doc.Flags["a"].Enabled {
		t.Errorf("parseDocument with a BOM = %+v, %v", doc, err)
	}
}

func TestCloneIsIndependent(t *testing.T) {
	doc, err := parseDocument([]byte(`{"Flags": {"a": {"Enabled": true}}}`))
	if err != nil {
		t.Fatal(err)
	}
	copied := doc.clone()
	copied.Flags["a"] = Flag{}
	copied.Flags["b"] = Flag{Enabled: true}
	if !doc.Flags["a"].Enabled || len(doc.Flags) != 1 {
		t.Errorf("mutating a clone changed the original: %+v", doc.Flags)
	}
}
