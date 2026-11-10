package cruflags_test

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"time"

	cruflags "github.com/CruGlobal/cru-flags"
)

// The usual setup: wait briefly for the first fetch at startup, then read
// flags anywhere. With CRU_FLAGS_URL unset, as in this example, every flag is
// off and nothing is fetched.
func Example() {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	cruflags.Ready(ctx)
	cancel()

	if cruflags.Enabled("checkout_v2") {
		fmt.Println("new checkout")
	} else {
		fmt.Println("old checkout")
	}
	// Output: old checkout
}

// A client of your own, for tests or for code that takes a *Client.
func ExampleNew() {
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("ETag", `"3"`)
		_, _ = w.Write([]byte(`{"Version": 3, "Flags": {"checkout_v2": {"Enabled": true}}}`))
	}))
	defer service.Close()

	flags := cruflags.New(cruflags.Options{URL: service.URL})
	defer flags.Close()
	flags.Ready(context.Background())

	fmt.Println(flags.Enabled("checkout_v2"), flags.Enabled("not_a_flag"))
	// Output: true false
}

// On a runtime that freezes between requests, refresh from the request path
// instead of a poller. Refresh fetches at most once per PollInterval.
func ExampleClient_Refresh() {
	flags := cruflags.New(cruflags.Options{RefreshMode: cruflags.OnDemand})
	defer flags.Close()

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		flags.Refresh(r.Context())
		if flags.Enabled("checkout_v2") {
			_, _ = fmt.Fprintln(w, "new checkout")
			return
		}
		_, _ = fmt.Fprintln(w, "old checkout")
	})
	_ = handler
}

// Route health transitions somewhere other than slog.Default().
func ExampleOptions_onError() {
	logger := slog.New(slog.DiscardHandler)
	flags := cruflags.New(cruflags.Options{
		OnError: func(event cruflags.HealthEvent) {
			logger.Warn("feature flags "+string(event.Kind), "url", event.URL, "error", event.Err)
		},
	})
	defer flags.Close()
}
