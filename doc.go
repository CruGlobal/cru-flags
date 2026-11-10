// Package cruflags is the Go client for Cru's pipeline feature-flag service.
//
// The service publishes one small JSON document per app per environment. The
// pipeline's app modules put its URL in CRU_FLAGS_URL in release-candidate and
// production; local development, CI, preview and lab have no flag document and
// no variable, and there every flag is off.
//
//	import cruflags "github.com/CruGlobal/cru-flags"
//
//	func main() {
//		// Optional: wait for the first fetch, so the first requests after a
//		// deploy see real flags instead of every flag off.
//		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
//		cruflags.Ready(ctx)
//		cancel()
//
//		// ...
//		if cruflags.Enabled("checkout_v2") {
//			// ...
//		}
//	}
//
// Enabled is a memory lookup. It never blocks, never fails and never panics,
// and anything other than "Enabled": true in the document reads off, including
// a flag the document does not name. Flags are created and flipped with
// `cru app flags`; this package only reads them.
//
// # How the document stays current
//
// By default a goroutine polls every 30 seconds, plus or minus 20% jitter,
// sending If-None-Match so an unchanged document costs a 304. A failed poll
// changes nothing: the last good document is served for as long as the
// outage lasts, and flags never fall back to off. A 404 means the app has no
// flags yet; every flag is off and nothing is logged. Health is logged on
// transitions only, once when polling starts failing and once when it
// recovers, through slog.Default() unless Options.OnError says otherwise.
//
// # AWS Lambda and Cloud Run
//
// A runtime that freezes the process between requests stops the poller's
// clock too. Set CRU_FLAGS_REFRESH_MODE=on-demand (or Options.RefreshMode) and
// the client runs no goroutine: a read that finds the document 30 seconds old
// starts a refresh in the background, and Refresh fetches and waits, at most
// once per interval. On Lambda, call Ready during init and Refresh at the top
// of the handler:
//
//	func init() {
//		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
//		defer cancel()
//		cruflags.Ready(ctx)
//	}
//
//	func handler(ctx context.Context, event Event) (Response, error) {
//		cruflags.Refresh(ctx)
//		if cruflags.Enabled("checkout_v2") {
//			// ...
//		}
//	}
//
// # Tests
//
// Code under test can take a *Client and be handed one built with New and an
// Options.URL pointing at an httptest server. With CRU_FLAGS_URL unset, the
// package-level functions answer every flag off and make no requests.
//
// The behavior shared with the TypeScript, Python and Ruby clients is
// specified by the conformance suite in this repository, and the reasoning
// behind each decision is in docs/go/design.md.
package cruflags
