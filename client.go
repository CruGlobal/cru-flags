package cruflags

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	// URLEnvVar holds the flag document URL. The pipeline's app modules set it
	// in release-candidate and production; everywhere else it is unset.
	URLEnvVar = "CRU_FLAGS_URL"
	// RefreshModeEnvVar selects "background" or "on-demand" refresh for a
	// client whose Options.RefreshMode is empty.
	RefreshModeEnvVar = "CRU_FLAGS_REFRESH_MODE"
	// MaxBodyBytes caps a response body. A larger 200 is a failed fetch, so a
	// misbehaving endpoint cannot exhaust memory. Matches the other clients.
	MaxBodyBytes = 1 << 20

	defaultPollInterval = 30 * time.Second
	defaultFetchTimeout = 2 * time.Second
	jitter              = 0.2
	maxRedirects        = 3
	snippetLimit        = 200
)

// RefreshMode is how a Client keeps its document current.
type RefreshMode string

const (
	// Background polls on a goroutine every PollInterval, plus or minus 20%
	// jitter. Reads never touch the network. The default.
	Background RefreshMode = "background"
	// OnDemand runs no poller. A read that finds the document PollInterval old
	// starts a refresh without waiting for it, and Refresh refreshes and waits.
	// For runtimes that freeze the process between requests: AWS Lambda, and
	// Cloud Run with CPU throttled outside requests.
	OnDemand RefreshMode = "on-demand"
)

// HealthKind is a health transition.
type HealthKind string

const (
	// Failing means a fetch failed after the client was healthy.
	Failing HealthKind = "failing"
	// Recovered means a fetch succeeded after the client was failing.
	Recovered HealthKind = "recovered"
)

// HealthEvent is passed to Options.OnError on a health transition, never on
// every failed poll: at the default interval, per-poll reporting is 2,880
// identical lines per day per instance, and they bury the one that matters.
type HealthEvent struct {
	Kind HealthKind
	URL  string
	// Err is a *FetchError when Kind is Failing, and nil when it is Recovered.
	Err error
}

// Options configures a Client. The zero value is the usual configuration:
// the URL and refresh mode come from the environment.
type Options struct {
	// URL of the flag document. Empty means os.Getenv(URLEnvVar), read when
	// the client starts rather than when it is built. With neither, the client
	// is inert: every flag is off, and it makes no requests and logs nothing.
	URL string
	// PollInterval is how often the document is refreshed. Default 30s.
	PollInterval time.Duration
	// FetchTimeout bounds one fetch, body included. Default 2s.
	FetchTimeout time.Duration
	// RefreshMode is Background or OnDemand. Empty means
	// os.Getenv(RefreshModeEnvVar), and Background when that is unset.
	RefreshMode RefreshMode
	// OnError is called on health transitions only. It runs on the fetching
	// goroutine before callers waiting on that fetch are released, so it must
	// return quickly, and it must not call Close, Ready, Refresh or
	// ForceRefresh on the same client (for the default client, the package's
	// Ready and Refresh): those wait on the fetch that is running the
	// handler, and deadlock. Enabled and Snapshot are safe. A panic in it is
	// recovered. The default logs both transitions at Warn on slog.Default().
	OnError func(HealthEvent)
}

// Client reads one flag document. Build it with New, or use the package's
// default client through Enabled, Ready, Refresh and Snapshot.
//
// A Client does nothing until its first Enabled, Ready, Refresh or Snapshot
// call: no environment read, no request, no goroutine. That first call reads
// the configuration, starts the first fetch and, in Background mode, the
// poller.
//
// The zero value is ready to use and behaves like New(Options{}). Every
// method is safe for concurrent use, and safe on a nil *Client, which behaves
// as an inert client.
type Client struct {
	opts Options

	// Set by setup, on first use of any method, so the zero value works.
	setupOnce  sync.Once
	poll       time.Duration
	timeout    time.Duration
	onError    func(HealthEvent)
	httpClient *http.Client
	epoch      time.Time

	startOnce sync.Once
	url       string // set once at start; empty means inert
	mode      RefreshMode

	// doc is what reads see: nil before the first document and after a 404.
	// A 200 stores a new *Document; a 304 leaves the pointer as it was.
	doc atomic.Pointer[Document]
	// lastAttempt is when the last fetch settled, as nanoseconds since epoch
	// plus one, so zero means never. Staleness is measured from the last
	// attempt, not the last success, so a dead service costs one request per
	// interval rather than one per read.
	lastAttempt atomic.Int64

	mu       sync.Mutex
	inflight chan struct{} // closed when the fetch in progress settles
	etag     string        // only ever stored with a document that parsed
	healthy  bool
	closed   bool

	// Mirrors of inflight != nil and closed, so an on-demand read can skip
	// the lock when there is nothing for it to start.
	fetching atomic.Bool
	shut     atomic.Bool

	ctx       context.Context
	cancel    context.CancelFunc
	stop      chan struct{}
	ready     chan struct{}
	readyOnce sync.Once
	wg        sync.WaitGroup
}

// New returns an inert Client. Nothing happens until it is first used.
func New(opts Options) *Client {
	return &Client{opts: opts}
}

// setup fills in everything New used to, so that a zero Client and one from
// New behave the same. It allocates; it reads no environment and starts
// nothing.
func (c *Client) setup() {
	c.setupOnce.Do(func() {
		c.poll = positive(c.opts.PollInterval, defaultPollInterval)
		c.timeout = positive(c.opts.FetchTimeout, defaultFetchTimeout)
		c.onError = c.opts.OnError
		if c.onError == nil {
			c.onError = logHealth
		}
		c.httpClient = &http.Client{
			CheckRedirect: func(_ *http.Request, via []*http.Request) error {
				if len(via) > maxRedirects {
					return fmt.Errorf("stopped after %d redirects", maxRedirects)
				}
				return nil
			},
		}
		c.epoch = time.Now()
		c.healthy = true
		c.ctx, c.cancel = context.WithCancel(context.Background())
		c.stop = make(chan struct{})
		c.ready = make(chan struct{})
	})
}

// Enabled reports whether the flag called name is on.
//
// It never blocks, never panics and never fails: an unknown flag, a document
// that has not arrived, a flag-service outage before the first success, and
// an inert client all read off. Only "Enabled": true in the document turns a
// flag on. After the first success, the last good document is served through
// any outage, for as long as it lasts.
//
// In OnDemand mode, Enabled starts a refresh when the document is
// PollInterval old, and answers from the current document without waiting.
func (c *Client) Enabled(name string) (on bool) {
	if c == nil {
		return false
	}
	defer func() {
		if recover() != nil {
			on = false
		}
	}()
	c.start()
	c.refreshOnRead()
	doc := c.doc.Load()
	return doc != nil && doc.Flags[name].Enabled
}

// Ready waits for the first fetch to settle, successfully or not, so the
// first requests a process serves see real flags. Call it once during
// startup, with a deadline:
//
//	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
//	defer cancel()
//	cruflags.Ready(ctx)
//
// It reports whether the wait ended because that fetch settled (true) or
// because ctx did (false). It says nothing about whether the fetch
// succeeded. An inert client has nothing to wait for and returns true at once.
func (c *Client) Ready(ctx context.Context) bool {
	if c == nil {
		return true
	}
	c.start()
	select {
	case <-c.ready:
		return true
	case <-ctx.Done():
		return false
	}
}

// Refresh fetches the document unless the last attempt is younger than
// PollInterval, and waits for it or for ctx. A refresh already in progress is
// shared rather than repeated. It reports whether the document is fresh: an
// attempt has settled and the latest one succeeded.
//
// In OnDemand mode this is how a request handler gets the current document
// before reading flags; it costs at most one conditional GET per PollInterval:
//
//	func middleware(next http.Handler) http.Handler {
//		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
//			cruflags.Refresh(r.Context())
//			next.ServeHTTP(w, r)
//		})
//	}
func (c *Client) Refresh(ctx context.Context) bool { return c.refresh(ctx, false) }

// ForceRefresh is Refresh without the PollInterval check.
func (c *Client) ForceRefresh(ctx context.Context) bool { return c.refresh(ctx, true) }

// Snapshot returns a copy of the document in effect, or nil before the first
// document and after a 404. Changing the copy changes nothing in the client.
func (c *Client) Snapshot() (doc *Document) {
	if c == nil {
		return nil
	}
	defer func() {
		if recover() != nil {
			doc = nil
		}
	}()
	c.start()
	c.refreshOnRead()
	if current := c.doc.Load(); current != nil {
		return current.clone()
	}
	return nil
}

// Close stops the client for good: the poller exits, a fetch in progress is
// abandoned, and Close waits for both. Reads keep answering from the last
// document. Closing is optional for a client that lives as long as the
// process, and safe to repeat: every call waits.
func (c *Client) Close() {
	if c == nil {
		return
	}
	c.setup()
	c.mu.Lock()
	if !c.closed {
		c.closed = true
		c.shut.Store(true)
		close(c.stop)
		c.cancel()
	}
	c.mu.Unlock()
	c.markReady()
	// No Add can follow: beginFetch and start both check closed under mu.
	c.wg.Wait()
}

func (c *Client) start() {
	c.setup()
	var warn func()
	c.startOnce.Do(func() {
		// The warning is logged after Do returns: an slog handler that reads a
		// flag from this client would otherwise re-enter Do and deadlock.
		c.mode, warn = resolveMode(c.opts.RefreshMode)
		url := strings.TrimSpace(c.opts.URL)
		if url == "" {
			url = strings.TrimSpace(os.Getenv(URLEnvVar))
		}
		c.mu.Lock()
		if c.closed {
			url = ""
		}
		c.url = url
		// Added under the lock, so a concurrent Close either sees closed
		// first or waits for this goroutine.
		poller := url != "" && c.mode == Background
		if poller {
			c.wg.Add(1)
		}
		c.mu.Unlock()

		switch {
		case url == "":
			// Inert. Unconfigured is the normal state in local development,
			// CI and lab, so it is silent.
			c.markReady()
		case poller:
			go c.pollLoop()
		default:
			c.beginFetch(true)
		}
	})
	if warn != nil {
		warn()
	}
}

func (c *Client) refresh(ctx context.Context, force bool) bool {
	if c == nil {
		return false
	}
	c.start()
	if done := c.beginFetch(force); done != nil {
		select {
		case <-done:
		case <-ctx.Done():
			return false
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.url != "" && !c.closed && c.lastAttempt.Load() != 0 && c.healthy
}

// refreshOnRead starts, and does not wait for, a refresh of a stale document
// in OnDemand mode. A read cannot wait: a flag read that blocks on the network
// is worse than one that is a poll interval out of date.
func (c *Client) refreshOnRead() {
	// c.url is safe to read here: it was set inside startOnce, which every
	// caller has passed.
	if c.mode != OnDemand || c.url == "" || c.shut.Load() || c.fetching.Load() || !c.stale() {
		return
	}
	c.beginFetch(false)
}

func (c *Client) stale() bool {
	last := c.lastAttempt.Load()
	return last == 0 || time.Since(c.epoch)-time.Duration(last-1) >= c.poll
}

// beginFetch starts a fetch unless one is in progress (then it shares that
// one), the client is inert or closed, or the document is fresh and force is
// false. It returns a channel closed when the fetch settles, or nil when
// there is nothing to wait for.
func (c *Client) beginFetch(force bool) <-chan struct{} {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.inflight != nil {
		return c.inflight
	}
	if c.url == "" || c.closed || (!force && !c.stale()) {
		return nil
	}
	done := make(chan struct{})
	c.inflight = done
	c.fetching.Store(true)
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		c.fetchOnce()
		c.mu.Lock()
		c.inflight = nil
		c.fetching.Store(false)
		c.mu.Unlock()
		c.markReady()
		close(done)
	}()
	return done
}

// pollLoop fetches, waits for that fetch to settle, then sleeps a jittered
// interval. Scheduling after the fetch settles, never on a fixed clock, means
// polls cannot overlap or queue up behind a slow service. The jitter keeps a
// fleet that deployed together from polling in lockstep.
func (c *Client) pollLoop() {
	defer c.wg.Done()
	for {
		if done := c.beginFetch(true); done != nil {
			select {
			case <-done:
			case <-c.stop:
				return
			}
		}
		timer := time.NewTimer(jittered(c.poll))
		select {
		case <-timer.C:
		case <-c.stop:
			timer.Stop()
			return
		}
	}
}

func jittered(d time.Duration) time.Duration {
	return time.Duration(float64(d) * (1 - jitter + rand.Float64()*2*jitter))
}

type outcome int

const (
	gotDocument outcome = iota
	notModified
	noDocument
)

// fetchOnce makes one request and applies the result. There are no retries
// within an attempt: the next poll is the retry, and retrying sooner only
// adds load to a service that is already struggling.
func (c *Client) fetchOnce() {
	c.mu.Lock()
	etag := c.etag
	c.mu.Unlock()

	ctx, cancel := context.WithTimeout(c.ctx, c.timeout)
	result, doc, newETag, err := c.fetch(ctx, etag)
	cancel()

	c.mu.Lock()
	var event *HealthEvent
	switch {
	case c.closed:
		// Close abandoned this fetch; it is not a health event.
	case err != nil:
		// Fail-static: the document and its ETag stay exactly as they were.
		if c.healthy {
			c.healthy = false
			event = &HealthEvent{Kind: Failing, URL: c.url, Err: err}
		}
	default:
		switch result {
		case gotDocument:
			// The ETag is stored only with a document that parsed. Storing a
			// rejected body's ETag would turn every later poll into a 304 for
			// a body the client never accepted.
			c.doc.Store(doc)
			c.etag = newETag
		case noDocument:
			// 404: this app has no flags yet. Not an error. The ETag goes too,
			// so a recreated document cannot 304 against the old version.
			c.doc.Store(nil)
			c.etag = ""
		case notModified:
		}
		if !c.healthy {
			c.healthy = true
			event = &HealthEvent{Kind: Recovered, URL: c.url}
		}
	}
	c.lastAttempt.Store(int64(time.Since(c.epoch)) + 1)
	c.mu.Unlock()

	if event != nil {
		c.emit(*event)
	}
}

func (c *Client) fetch(ctx context.Context, etag string) (outcome, *Document, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url, http.NoBody)
	if err != nil {
		return 0, nil, "", &FetchError{Code: CodeNetwork, Message: "invalid flag document URL", Err: err}
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "cru-flags-go/"+Version)
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return 0, nil, "", transportError(ctx, err)
	}
	defer func() {
		// Drain what is left of a small body so the connection can be reused.
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		_ = resp.Body.Close()
	}()

	switch {
	case resp.StatusCode == http.StatusNotModified:
		return notModified, nil, "", nil
	case resp.StatusCode == http.StatusNotFound:
		return noDocument, nil, "", nil
	case resp.StatusCode < 200 || resp.StatusCode > 299:
		return 0, nil, "", &FetchError{
			Code:    CodeHTTP,
			Status:  resp.StatusCode,
			Message: fmt.Sprintf("flag fetch failed with HTTP %d%s", resp.StatusCode, snippet(resp.Body)),
		}
	}

	// Read one byte past the cap, so a body that overruns it is detected
	// without ever holding more than that in memory.
	body, err := io.ReadAll(io.LimitReader(resp.Body, MaxBodyBytes+1))
	if err != nil {
		return 0, nil, "", transportError(ctx, err)
	}
	if len(body) > MaxBodyBytes {
		return 0, nil, "", &FetchError{Code: CodeParse, Message: fmt.Sprintf("flag document exceeds %d bytes", MaxBodyBytes)}
	}
	doc, err := parseDocument(body)
	if err != nil {
		return 0, nil, "", err
	}
	return gotDocument, doc, resp.Header.Get("ETag"), nil
}

func transportError(ctx context.Context, err error) *FetchError {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return &FetchError{Code: CodeTimeout, Message: "flag fetch timed out", Err: err}
	}
	return &FetchError{Code: CodeNetwork, Message: "flag fetch failed", Err: err}
}

// snippet is a short excerpt of an error response's body for the message.
// The status is the news; the body is a nice-to-have.
func snippet(body io.Reader) string {
	raw, _ := io.ReadAll(io.LimitReader(body, snippetLimit+1))
	text := strings.TrimSpace(string(raw))
	if text == "" {
		return ""
	}
	if len(raw) > snippetLimit {
		text = strings.TrimSpace(string(raw[:snippetLimit])) + "…"
	}
	return ": " + text
}

func (c *Client) emit(event HealthEvent) {
	defer func() { _ = recover() }() // a broken handler must not break polling
	c.onError(event)
}

func (c *Client) markReady() { c.readyOnce.Do(func() { close(c.ready) }) }

// resolveMode picks the refresh mode from the option, then the environment.
// An unrecognized value falls back to Background, with a warning for the
// caller to log: a typo in a deployment's environment must not stop the app
// from booting.
func resolveMode(configured RefreshMode) (RefreshMode, func()) {
	raw, source := string(configured), "Options.RefreshMode"
	if raw == "" {
		raw, source = os.Getenv(RefreshModeEnvVar), RefreshModeEnvVar
	}
	switch mode := RefreshMode(strings.ToLower(strings.TrimSpace(raw))); mode {
	case "":
		return Background, nil
	case Background, OnDemand:
		return mode, nil
	default:
		return Background, func() {
			slog.Warn("cru-flags: unrecognized refresh mode; polling in the background",
				"source", source, "value", raw, "want", "background or on-demand")
		}
	}
}

func logHealth(event HealthEvent) {
	if event.Kind == Failing {
		slog.Warn("cru-flags: flag polling is failing; serving last-known-good flags",
			"url", event.URL, "error", event.Err)
		return
	}
	slog.Warn("cru-flags: flag polling recovered", "url", event.URL)
}

func positive(d, fallback time.Duration) time.Duration {
	if d > 0 {
		return d
	}
	return fallback
}
