package cruflags

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"slices"
	"strings"
	"testing"
	"time"
)

// TestConformance runs the shared cases in conformance/cases.json against
// this client. Every client in the repository runs the same cases against the
// same server, conformance/server.py. See conformance/README.md.
func TestConformance(t *testing.T) {
	raw, err := os.ReadFile("conformance/cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Cases []conformanceCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	base := startConformanceServer(t)

	for _, tc := range file.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			t.Setenv(URLEnvVar, "")
			t.Setenv(RefreshModeEnvVar, "")
			run := rand.Text()
			url := ""
			if tc.URL == nil || *tc.URL {
				url = fmt.Sprintf("%s/flags/%s/%s", base, tc.Name, run)
			}
			var got events
			c := New(Options{
				URL:          url,
				PollInterval: time.Hour,
				FetchTimeout: time.Second,
				RefreshMode:  Background,
				OnError:      got.record,
			})
			defer c.Close()

			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			for i, step := range tc.Steps {
				where := fmt.Sprintf("step %d (%s)", i, step.Do)
				if step.Do == "ready" {
					c.Ready(ctx)
				} else {
					c.ForceRefresh(ctx)
				}

				for name, want := range step.Enabled {
					if got := c.Enabled(name); got != want {
						t.Errorf("%s: Enabled(%q) = %v, want %v", where, name, got, want)
					}
				}
				if url != "" && (step.Requests != nil || step.IfNoneMatch != nil) {
					seen := requestsSeen(t, fmt.Sprintf("%s/log/%s/%s", base, tc.Name, run))
					if step.Requests != nil && len(seen) != *step.Requests {
						t.Errorf("%s: %d requests, want %d", where, len(seen), *step.Requests)
					}
					if step.IfNoneMatch != nil && len(seen) > 0 {
						var want string // JSON null: the header must be absent
						if err := json.Unmarshal(step.IfNoneMatch, &want); err != nil && string(step.IfNoneMatch) != "null" {
							t.Fatalf("%s: bad ifNoneMatch %s", where, step.IfNoneMatch)
						}
						if sent := seen[len(seen)-1].Headers["if-none-match"]; sent != want {
							t.Errorf("%s: If-None-Match %q, want %q", where, sent, want)
						}
					}
				}
				if step.Events != nil {
					var kinds []string
					for _, kind := range got.kinds() {
						kinds = append(kinds, string(kind))
					}
					if !slices.Equal(kinds, *step.Events) {
						t.Errorf("%s: health events %v, want %v", where, kinds, *step.Events)
					}
				}
			}
		})
	}
}

type conformanceCase struct {
	Name  string `json:"name"`
	URL   *bool  `json:"url"`
	Steps []struct {
		Do       string          `json:"do"`
		Enabled  map[string]bool `json:"enabled"`
		Requests *int            `json:"requests"`
		// Absent: not checked. null: the header must be absent.
		IfNoneMatch json.RawMessage `json:"ifNoneMatch"`
		Events      *[]string       `json:"events"`
	} `json:"steps"`
}

type seenRequest struct {
	Headers map[string]string `json:"headers"`
}

// startConformanceServer runs conformance/server.py for the rest of the test
// and returns its base URL. It needs a python3 on PATH, which every CI runner
// has.
func startConformanceServer(t *testing.T) string {
	t.Helper()
	cmd := exec.CommandContext(t.Context(), "python3", "conformance/server.py")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("starting the conformance server (python3 conformance/server.py): %v", err)
	}
	t.Cleanup(func() {
		_ = stdin.Close() // the server exits when its stdin closes
		_ = cmd.Wait()
	})
	line, err := bufio.NewReader(stdout).ReadString('\n')
	port, ok := strings.CutPrefix(strings.TrimSpace(line), "PORT ")
	if err != nil || !ok {
		t.Fatalf("conformance server did not report its port (%q, %v); it needs a python3 3.11+ on PATH", line, err)
	}
	return "http://127.0.0.1:" + port
}

func requestsSeen(t *testing.T, url string) []seenRequest {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, url, http.NoBody)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	var seen []seenRequest
	if err := json.NewDecoder(resp.Body).Decode(&seen); err != nil {
		t.Fatal(err)
	}
	return seen
}
