package cruflags

import "fmt"

// ErrorCode says why a fetch failed.
type ErrorCode string

const (
	// CodeHTTP means the service answered with an unexpected status (5xx, 400, and
	// so on). FetchError.Status carries it. A 404 is not an error, and a 304
	// is a success.
	CodeHTTP ErrorCode = "http"
	// CodeNetwork means the request never completed (DNS, connection refused or
	// reset, TLS, too many redirects, a malformed URL).
	CodeNetwork ErrorCode = "network"
	// CodeTimeout means the fetch outlived Options.FetchTimeout and was abandoned.
	CodeTimeout ErrorCode = "timeout"
	// CodeParse means a 2xx arrived whose body is not a usable flag document,
	// including a body over MaxBodyBytes.
	CodeParse ErrorCode = "parse"
)

// FetchError is the error carried by a Failing HealthEvent. Nothing in the
// package returns it: Enabled, Ready and Refresh never return errors. It
// exists so an OnError handler can branch on Code and Status instead of
// matching message text.
type FetchError struct {
	Code ErrorCode
	// Status is the HTTP status, when Code is CodeHTTP.
	Status int
	// Message describes the failure.
	Message string
	// Err is the underlying error, when there is one.
	Err error
}

func (e *FetchError) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("cru-flags: %s: %v", e.Message, e.Err)
	}
	return "cru-flags: " + e.Message
}

func (e *FetchError) Unwrap() error { return e.Err }
