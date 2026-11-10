package cruflags

import "context"

// std is the package's default client. New does nothing, so this costs
// nothing at import: it reads CRU_FLAGS_URL and CRU_FLAGS_REFRESH_MODE on
// first use, so a test or main that sets them after import still works.
var std = New(Options{})

// Default returns the client behind the package-level functions, for code
// that takes a *Client.
func Default() *Client { return std }

// Enabled reports whether a flag is on, using the default client. See
// [Client.Enabled].
func Enabled(name string) bool { return std.Enabled(name) }

// Ready waits for the default client's first fetch to settle. See
// [Client.Ready].
func Ready(ctx context.Context) bool { return std.Ready(ctx) }

// Refresh refreshes the default client's document if it is stale. See
// [Client.Refresh].
func Refresh(ctx context.Context) bool { return std.Refresh(ctx) }

// Snapshot returns a copy of the default client's document. See
// [Client.Snapshot].
func Snapshot() *Document { return std.Snapshot() }
