package cruflags

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const docV3 = `{"Version": 3, "Flags": {"on": {"Enabled": true}, "off": {"Enabled": false}}}`

// TestMain clears the configuration variables: tests set what they need, and
// one exported in a developer's shell must not leak in, or send Example to a
// real flag service.
func TestMain(m *testing.M) {
	_ = os.Unsetenv(URLEnvVar)
	_ = os.Unsetenv(RefreshModeEnvVar)
	os.Exit(m.Run())
}

// service is a scriptable flag service: request N gets responses[N], and the
// last response repeats. A response with a non-nil hold waits on it first.
type service struct {
	*httptest.Server
	mu        sync.Mutex
	responses []reply
	seen      []http.Header
}

type reply struct {
	status int
	etag   string
	body   string
	hold   chan struct{}
}

func newService(t *testing.T, responses ...reply) *service {
	t.Helper()
	s := &service{responses: responses}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.seen = append(s.seen, r.Header.Clone())
		next := s.responses[min(len(s.seen), len(s.responses))-1]
		s.mu.Unlock()
		if next.hold != nil {
			select {
			case <-next.hold:
			case <-r.Context().Done():
				return
			}
		}
		if next.etag != "" {
			w.Header().Set("ETag", next.etag)
		}
		w.WriteHeader(next.status)
		_, _ = w.Write([]byte(next.body))
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *service) requests() []http.Header {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]http.Header(nil), s.seen...)
}

// events records health transitions.
type events struct {
	mu   sync.Mutex
	list []HealthEvent
}

func (e *events) record(event HealthEvent) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.list = append(e.list, event)
}

func (e *events) kinds() []HealthKind {
	e.mu.Lock()
	defer e.mu.Unlock()
	kinds := make([]HealthKind, len(e.list))
	for i, event := range e.list {
		kinds[i] = event.Kind
	}
	return kinds
}

func newClient(t *testing.T, opts Options) *Client {
	t.Helper()
	if opts.PollInterval == 0 {
		opts.PollInterval = time.Hour
	}
	c := New(opts)
	t.Cleanup(c.Close)
	return c
}

func ready(t *testing.T, c *Client) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if !c.Ready(ctx) {
		t.Fatal("Ready timed out")
	}
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
		if cond() {
			return
		}
	}
	t.Fatalf("timed out waiting for %s", what)
}

// captureLogs points slog's default logger at a buffer for one test.
func captureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&lockedWriter{w: &buf}, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return &buf
}

type lockedWriter struct {
	mu sync.Mutex
	w  *bytes.Buffer
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}

func TestInertWithoutAURL(t *testing.T) {
	t.Setenv(URLEnvVar, "")
	logs := captureLogs(t)
	c := newClient(t, Options{})

	if c.Enabled("anything") {
		t.Error("Enabled should be false on an inert client")
	}
	if !c.Ready(context.Background()) {
		t.Error("Ready should return true at once on an inert client")
	}
	if c.Refresh(context.Background()) || c.ForceRefresh(context.Background()) {
		t.Error("an inert client is never fresh")
	}
	if c.Snapshot() != nil {
		t.Error("Snapshot should be nil on an inert client")
	}
	if logs.Len() != 0 {
		t.Errorf("an inert client must log nothing, got %q", logs.String())
	}
}

func TestNothingHappensUntilFirstUse(t *testing.T) {
	svc := newService(t, reply{status: 200, body: docV3})
	c := newClient(t, Options{URL: svc.URL})
	time.Sleep(50 * time.Millisecond)
	if n := len(svc.requests()); n != 0 {
		t.Fatalf("New made %d requests; it must make none", n)
	}
	c.Enabled("on")
	eventually(t, "the first fetch", func() bool { return len(svc.requests()) == 1 })
}

func TestURLComesFromTheEnvironmentAtFirstUse(t *testing.T) {
	svc := newService(t, reply{status: 200, body: docV3})
	t.Setenv(URLEnvVar, "")
	c := newClient(t, Options{})
	t.Setenv(URLEnvVar, "  "+svc.URL+"  ") // set after New, trimmed
	ready(t, c)
	if !c.Enabled("on") {
		t.Error("the client should read CRU_FLAGS_URL when it starts, not when it is built")
	}
}

func TestEnabledReadsTheDocument(t *testing.T) {
	hold := make(chan struct{})
	svc := newService(t, reply{status: 200, etag: `"3"`, body: docV3, hold: hold})
	c := newClient(t, Options{URL: svc.URL})
	if c.Enabled("on") {
		t.Error("every flag is off before the first fetch settles")
	}
	close(hold)
	ready(t, c)
	for name, want := range map[string]bool{"on": true, "off": false, "unknown": false, "ON": false} {
		if got := c.Enabled(name); got != want {
			t.Errorf("Enabled(%q) = %v, want %v", name, got, want)
		}
	}
	if ua := svc.requests()[0].Get("User-Agent"); ua != "cru-flags-go/"+Version {
		t.Errorf("User-Agent = %q", ua)
	}
}

func TestBackgroundPollingRevalidatesWithTheETag(t *testing.T) {
	svc := newService(t, reply{status: 200, etag: `"3"`, body: docV3}, reply{status: 304})
	c := newClient(t, Options{URL: svc.URL, PollInterval: 20 * time.Millisecond})
	ready(t, c)
	first := c.doc.Load()
	eventually(t, "three polls", func() bool { return len(svc.requests()) >= 3 })

	seen := svc.requests()
	if seen[0].Get("If-None-Match") != "" {
		t.Error("the first fetch has no ETag to send")
	}
	for i, headers := range seen[1:] {
		if got := headers.Get("If-None-Match"); got != `"3"` {
			t.Errorf("poll %d sent If-None-Match %q, want %q", i+1, got, `"3"`)
		}
	}
	if c.doc.Load() != first {
		t.Error("a 304 must keep the same document, not replace it")
	}
}

func TestJitterStaysWithinTwentyPercent(t *testing.T) {
	for range 10_000 {
		if d := jittered(time.Second); d < 800*time.Millisecond || d > 1200*time.Millisecond {
			t.Fatalf("jittered(1s) = %v", d)
		}
	}
}

func TestConcurrentRefreshesShareOneRequest(t *testing.T) {
	hold := make(chan struct{})
	svc := newService(t, reply{status: 200, etag: `"3"`, body: docV3}, reply{status: 200, body: docV3, hold: hold})
	c := newClient(t, Options{URL: svc.URL})
	ready(t, c)

	shared := c.beginFetch(true) // held open until close(hold)
	joined := make([]<-chan struct{}, 20)
	var wg sync.WaitGroup
	for i := range joined {
		wg.Go(func() { joined[i] = c.beginFetch(true) })
	}
	wg.Wait()
	for i, ch := range joined {
		if ch != shared {
			t.Fatalf("caller %d started its own fetch instead of sharing the one in flight", i)
		}
	}
	close(hold)
	<-shared
	if n := len(svc.requests()); n != 2 {
		t.Errorf("21 concurrent forced refreshes made %d requests after the first; want 1", n-1)
	}
	if !c.Refresh(context.Background()) {
		t.Error("the shared refresh should leave the document fresh")
	}
}

func TestRefreshSkipsAFreshDocument(t *testing.T) {
	svc := newService(t, reply{status: 200, body: docV3})
	c := newClient(t, Options{URL: svc.URL})
	ready(t, c)
	if !c.Refresh(context.Background()) {
		t.Error("Refresh should report a fresh document")
	}
	if n := len(svc.requests()); n != 1 {
		t.Errorf("Refresh within PollInterval made a request (%d total)", n)
	}
}

func TestRefreshGivesUpWhenItsContextDoes(t *testing.T) {
	hold := make(chan struct{})
	defer close(hold)
	svc := newService(t, reply{status: 200, body: docV3, hold: hold})
	c := newClient(t, Options{URL: svc.URL, FetchTimeout: 10 * time.Second})
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if c.ForceRefresh(ctx) {
		t.Error("ForceRefresh should report false when its context ends first")
	}
	if c.Ready(ctx) {
		t.Error("Ready should report false when its context ends first")
	}
}

func TestOnDemandRefreshesFromReadsWithoutWaiting(t *testing.T) {
	hold := make(chan struct{})
	svc := newService(t,
		reply{status: 200, etag: `"3"`, body: docV3},
		reply{status: 200, etag: `"4"`, body: `{"Flags": {"on": {"Enabled": false}}}`, hold: hold},
	)
	c := newClient(t, Options{URL: svc.URL, RefreshMode: OnDemand, PollInterval: time.Hour})
	ready(t, c)
	for range 50 {
		c.Enabled("on")
		c.Snapshot()
	}
	if n := len(svc.requests()); n != 1 {
		t.Fatalf("reads of a fresh document made %d requests; want 1", n)
	}

	// Make the last attempt two hours old. A read now starts a refresh, which
	// is held open, and must answer from the current document without waiting.
	c.lastAttempt.Store(-int64(2 * time.Hour))
	read := make(chan bool, 1)
	go func() { read <- c.Enabled("on") }()
	select {
	case on := <-read:
		if !on {
			t.Error("a stale read should answer from the current document")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Enabled waited for the refresh it started")
	}
	eventually(t, "the refresh a stale read started", func() bool { return len(svc.requests()) == 2 })
	for range 50 {
		c.Enabled("on")
	}
	if n := len(svc.requests()); n != 2 {
		t.Errorf("reads during an in-flight refresh made more requests: %d in all, want 2", n)
	}
	close(hold)
	eventually(t, "the new document", func() bool { return !c.Enabled("on") })
}

func TestOnDemandAgainstADeadServiceCostsOneRequestPerInterval(t *testing.T) {
	svc := newService(t, reply{status: 500})
	c := newClient(t, Options{URL: svc.URL, RefreshMode: OnDemand, PollInterval: time.Hour, OnError: func(HealthEvent) {}})
	ready(t, c)
	for range 100 {
		c.Enabled("on")
		c.Refresh(context.Background())
	}
	if n := len(svc.requests()); n != 1 {
		t.Errorf("a dead service got %d requests within one interval; want 1", n)
	}
}

func TestRefreshModeFromTheEnvironment(t *testing.T) {
	svc := newService(t, reply{status: 200, body: docV3})

	t.Setenv(RefreshModeEnvVar, " On-Demand ")
	c := newClient(t, Options{URL: svc.URL, PollInterval: 10 * time.Millisecond})
	ready(t, c)
	time.Sleep(60 * time.Millisecond)
	if n := len(svc.requests()); n != 1 {
		t.Errorf("CRU_FLAGS_REFRESH_MODE=on-demand should run no poller; saw %d requests", n)
	}

	logs := captureLogs(t)
	t.Setenv(RefreshModeEnvVar, "sometimes")
	inert := newClient(t, Options{})
	inert.Enabled("on")
	if inert.mode != Background {
		t.Errorf("an unrecognized mode should fall back to background, got %q", inert.mode)
	}
	if !strings.Contains(logs.String(), "sometimes") {
		t.Errorf("an unrecognized mode should warn, got %q", logs.String())
	}
	if mode, _ := resolveMode(OnDemand); mode != OnDemand {
		t.Errorf("Options.RefreshMode should win over the environment, got %q", mode)
	}
}

// callbackHandler is an slog.Handler that runs fn for every record.
type callbackHandler struct{ fn func() }

func (h callbackHandler) Enabled(context.Context, slog.Level) bool  { return true }
func (h callbackHandler) Handle(context.Context, slog.Record) error { h.fn(); return nil }
func (h callbackHandler) WithAttrs([]slog.Attr) slog.Handler        { return h }
func (h callbackHandler) WithGroup(string) slog.Handler             { return h }

// A log handler that reads a flag must not deadlock against the client's
// own start-up warning.
func TestAModeWarningMayReadFlags(t *testing.T) {
	c := newClient(t, Options{RefreshMode: "ondemand"})
	var reentered atomic.Bool
	previous := slog.Default()
	slog.SetDefault(slog.New(callbackHandler{fn: func() {
		c.Enabled("on")
		reentered.Store(true)
	}}))
	t.Cleanup(func() { slog.SetDefault(previous) })

	done := make(chan struct{})
	go func() {
		c.Enabled("on")
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Enabled deadlocked while logging the refresh-mode warning")
	}
	if !reentered.Load() {
		t.Error("the warning should have been logged")
	}
}

func TestHealthIsReportedOnTransitionsOnly(t *testing.T) {
	svc := newService(t,
		reply{status: 200, etag: `"3"`, body: docV3},
		reply{status: 503, body: "  down for maintenance  "},
		reply{status: 503},
		reply{status: 503},
		reply{status: 304},
		reply{status: 304},
	)
	var got events
	c := newClient(t, Options{URL: svc.URL, OnError: got.record})
	ready(t, c)
	for range 5 {
		c.ForceRefresh(context.Background())
		if !c.Enabled("on") {
			t.Fatal("failures must keep the last good document")
		}
	}
	if kinds := got.kinds(); fmt.Sprint(kinds) != "[failing recovered]" {
		t.Fatalf("events = %v, want [failing recovered]", kinds)
	}
	var fetchErr *FetchError
	if !errors.As(got.list[0].Err, &fetchErr) || fetchErr.Code != CodeHTTP || fetchErr.Status != 503 ||
		!strings.Contains(fetchErr.Error(), "down for maintenance") {
		t.Errorf("failing event error = %v", got.list[0].Err)
	}
	if got.list[0].URL != svc.URL || got.list[1].Err != nil {
		t.Errorf("events = %+v", got.list)
	}
}

func TestDefaultHealthHandlerLogsBothTransitions(t *testing.T) {
	logs := captureLogs(t)
	svc := newService(t, reply{status: 500}, reply{status: 200, body: docV3})
	c := newClient(t, Options{URL: svc.URL})
	ready(t, c)
	c.ForceRefresh(context.Background())
	out := logs.String()
	if !strings.Contains(out, "failing") || !strings.Contains(out, "recovered") || strings.Count(out, "\n") != 2 {
		t.Errorf("default handler logged %q", out)
	}
}

func TestOnErrorMayReadFlags(t *testing.T) {
	svc := newService(t, reply{status: 500}, reply{status: 200, body: docV3})
	var c *Client
	var calls atomic.Int32
	c = newClient(t, Options{URL: svc.URL, RefreshMode: OnDemand, OnError: func(HealthEvent) {
		c.Enabled("on")
		c.Snapshot()
		calls.Add(1)
	}})
	ready(t, c)
	c.ForceRefresh(context.Background())
	if calls.Load() != 2 {
		t.Errorf("OnError ran %d times; want 2 (failing, recovered)", calls.Load())
	}
}

func TestAPanickingHandlerDoesNotStopPolling(t *testing.T) {
	svc := newService(t, reply{status: 500}, reply{status: 200, body: docV3})
	c := newClient(t, Options{URL: svc.URL, OnError: func(HealthEvent) { panic("boom") }})
	ready(t, c)
	if !c.ForceRefresh(context.Background()) || !c.Enabled("on") {
		t.Error("the client should keep working after OnError panics")
	}
}

func TestErrorCodes(t *testing.T) {
	hold := make(chan struct{})
	defer close(hold)
	slow := newService(t, reply{status: 200, body: docV3, hold: hold})
	malformed := newService(t, reply{status: 200, body: `{"Flags":`})
	refused := httptest.NewServer(http.NotFoundHandler())
	refused.Close()

	for name, tc := range map[string]struct {
		url     string
		timeout time.Duration
		want    ErrorCode
	}{
		"timeout": {slow.URL, 50 * time.Millisecond, CodeTimeout},
		"parse":   {malformed.URL, 5 * time.Second, CodeParse},
		"network": {refused.URL, 5 * time.Second, CodeNetwork},
		"bad url": {"http://[::1", 5 * time.Second, CodeNetwork},
	} {
		t.Run(name, func(t *testing.T) {
			var got events
			c := newClient(t, Options{URL: tc.url, FetchTimeout: tc.timeout, OnError: got.record})
			ready(t, c)
			var fetchErr *FetchError
			if len(got.list) != 1 || !errors.As(got.list[0].Err, &fetchErr) || fetchErr.Code != tc.want {
				t.Errorf("events = %+v, want one %s failure", got.list, tc.want)
			}
		})
	}
}

func TestBodyCap(t *testing.T) {
	pad := func(n int) string {
		base := `{"Flags": {"on": {"Enabled": true}}, "Padding": ""}`
		return strings.Replace(base, `""`, `"`+strings.Repeat("x", n-len(base))+`"`, 1)
	}
	for _, tc := range []struct {
		size int
		ok   bool
	}{{MaxBodyBytes, true}, {MaxBodyBytes + 1, false}} {
		svc := newService(t, reply{status: 200, body: pad(tc.size)})
		var got events
		c := newClient(t, Options{URL: svc.URL, OnError: got.record})
		ready(t, c)
		if c.Enabled("on") != tc.ok || (len(got.list) == 0) != tc.ok {
			t.Errorf("a %d-byte body: enabled=%v events=%v, want accepted=%v", tc.size, c.Enabled("on"), got.kinds(), tc.ok)
		}
	}
}

func TestRedirectsAreFollowedThreeTimes(t *testing.T) {
	svc := newService(t, reply{status: 200, body: docV3})
	chain := func(hops int) string {
		target := svc.URL
		for range hops {
			next := target
			hop := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				http.Redirect(w, r, next, http.StatusFound)
			}))
			t.Cleanup(hop.Close)
			target = hop.URL
		}
		return target
	}
	for hops, want := range map[int]bool{3: true, 4: false} {
		c := newClient(t, Options{URL: chain(hops), OnError: func(HealthEvent) {}})
		ready(t, c)
		if got := c.Enabled("on"); got != want {
			t.Errorf("%d redirects: Enabled = %v, want %v", hops, got, want)
		}
	}
}

func TestSnapshotIsACopy(t *testing.T) {
	hold := make(chan struct{})
	svc := newService(t, reply{status: 200, body: docV3, hold: hold}, reply{status: 404})
	c := newClient(t, Options{URL: svc.URL})
	if c.Snapshot() != nil {
		t.Error("Snapshot should be nil before the first document")
	}
	close(hold)
	ready(t, c)
	snap := c.Snapshot()
	snap.Flags["on"] = Flag{}
	if !c.Enabled("on") {
		t.Error("changing a snapshot changed the client")
	}
	c.ForceRefresh(context.Background())
	if c.Snapshot() != nil {
		t.Error("Snapshot should be nil after a 404")
	}
}

func TestCloseStopsPolling(t *testing.T) {
	svc := newService(t, reply{status: 200, body: docV3})
	c := New(Options{URL: svc.URL, PollInterval: 10 * time.Millisecond})
	ready(t, c)
	c.Close()
	c.Close()
	n := len(svc.requests())
	time.Sleep(60 * time.Millisecond)
	if after := len(svc.requests()); after != n {
		t.Errorf("polling continued after Close: %d -> %d requests", n, after)
	}
	if !c.Enabled("on") {
		t.Error("reads keep answering from the last document after Close")
	}
	if c.ForceRefresh(context.Background()) {
		t.Error("a closed client is never fresh")
	}
}

func TestCloseAbandonsAFetchInProgressQuietly(t *testing.T) {
	hold := make(chan struct{})
	defer close(hold)
	svc := newService(t, reply{status: 200, body: docV3, hold: hold})
	var got events
	c := New(Options{URL: svc.URL, FetchTimeout: time.Minute, OnError: got.record})
	c.Enabled("on")
	eventually(t, "the request", func() bool { return len(svc.requests()) == 1 })

	done := make(chan struct{})
	go func() { c.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not return")
	}
	if !c.Ready(context.Background()) || len(got.list) != 0 {
		t.Errorf("after Close: events %v", got.kinds())
	}
}

func TestCloseBeforeFirstUseLeavesTheClientInert(t *testing.T) {
	svc := newService(t, reply{status: 200, body: docV3})
	c := New(Options{URL: svc.URL})
	c.Close()
	if c.Enabled("on") || !c.Ready(context.Background()) || len(svc.requests()) != 0 {
		t.Error("a client closed before first use should be inert")
	}
}

func TestEveryCloseWaits(t *testing.T) {
	hold := make(chan struct{})
	defer close(hold)
	svc := newService(t, reply{status: 200, body: docV3, hold: hold})
	c := New(Options{URL: svc.URL, FetchTimeout: time.Minute})
	c.Enabled("on")
	eventually(t, "the request", func() bool { return len(svc.requests()) == 1 })

	var early atomic.Bool
	var wg sync.WaitGroup
	for range 5 {
		wg.Go(func() {
			c.Close()
			if c.fetching.Load() {
				early.Store(true)
			}
		})
	}
	wg.Wait()
	if early.Load() {
		t.Error("a Close returned while the fetch it abandoned was still running")
	}
}

func TestZeroValueClient(t *testing.T) {
	svc := newService(t, reply{status: 200, body: docV3})
	t.Setenv(URLEnvVar, svc.URL)
	var c Client
	t.Cleanup(c.Close)
	ready(t, &c)
	if !c.Enabled("on") || c.Snapshot() == nil {
		t.Error("a zero Client should read CRU_FLAGS_URL and fetch like New(Options{})")
	}

	var unused Client
	unused.Close()
	if !unused.Ready(context.Background()) || unused.Enabled("on") {
		t.Error("a zero Client closed before use should be inert")
	}
}

func TestNilClientIsInert(t *testing.T) {
	var c *Client
	if c.Enabled("on") || !c.Ready(context.Background()) || c.Refresh(context.Background()) || c.Snapshot() != nil {
		t.Error("a nil *Client should behave as an inert client")
	}
	c.Close()
}

func TestConcurrentUse(t *testing.T) {
	svc := newService(t, reply{status: 200, etag: `"3"`, body: docV3}, reply{status: 304})
	c := newClient(t, Options{URL: svc.URL, PollInterval: time.Millisecond})
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			for range 500 {
				c.Enabled("on")
				c.Snapshot()
				c.Refresh(context.Background())
			}
		})
	}
	wg.Wait()
}

func TestDefaultClient(t *testing.T) {
	if Default() != std || Default() == nil {
		t.Error("Default should return the package's client")
	}
}
