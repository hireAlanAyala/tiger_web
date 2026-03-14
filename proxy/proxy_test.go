package main

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestPatchSignalsFrame(t *testing.T) {
	tests := []struct {
		name string
		key  string
		json string
		want string
	}{
		{
			name: "orders",
			key:  "orders",
			json: `[{"id":"abc","status":"pending"}]`,
			want: "event: datastar-patch-signals\ndata: signals {\"orders\":[{\"id\":\"abc\",\"status\":\"pending\"}]}\n\n",
		},
		{
			name: "empty array",
			key:  "orders",
			json: `[]`,
			want: "event: datastar-patch-signals\ndata: signals {\"orders\":[]}\n\n",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := string(PatchSignalsFrame(tt.key, []byte(tt.json)))
			if got != tt.want {
				t.Errorf("got:\n%s\nwant:\n%s", got, tt.want)
			}
		})
	}
}

func TestPatchSignalsFrameStructure(t *testing.T) {
	frame := string(PatchSignalsFrame("test", []byte(`{"a":1}`)))

	if !strings.HasPrefix(frame, "event: datastar-patch-signals\n") {
		t.Error("missing event line")
	}
	if !strings.Contains(frame, "data: signals ") {
		t.Error("missing data line with signals key")
	}
	if !strings.HasSuffix(frame, "\n\n") {
		t.Error("missing double newline terminator")
	}
}

func TestHubBroadcast(t *testing.T) {
	hub := NewHub()

	ch1 := make(chan []byte, 4)
	ch2 := make(chan []byte, 4)
	hub.Add(ch1)
	hub.Add(ch2)

	msg := []byte("test event")
	hub.Broadcast(msg)

	got1 := <-ch1
	got2 := <-ch2

	if !bytes.Equal(got1, msg) {
		t.Errorf("ch1: got %q, want %q", got1, msg)
	}
	if !bytes.Equal(got2, msg) {
		t.Errorf("ch2: got %q, want %q", got2, msg)
	}
}

func TestHubBroadcastSkipsSlowConsumer(t *testing.T) {
	hub := NewHub()

	// Channel with buffer of 1 — fill it up.
	slow := make(chan []byte, 1)
	fast := make(chan []byte, 4)
	hub.Add(slow)
	hub.Add(fast)

	// Fill the slow channel.
	slow <- []byte("blocking")

	// Broadcast should not block.
	done := make(chan struct{})
	go func() {
		hub.Broadcast([]byte("new event"))
		close(done)
	}()

	select {
	case <-done:
		// Broadcast completed without blocking.
	case <-time.After(100 * time.Millisecond):
		t.Fatal("broadcast blocked on slow consumer")
	}

	// Fast consumer got it.
	got := <-fast
	if string(got) != "new event" {
		t.Errorf("fast: got %q", got)
	}
}

func TestHubRemove(t *testing.T) {
	hub := NewHub()

	ch := make(chan []byte, 4)
	id := hub.Add(ch)

	if hub.Len() != 1 {
		t.Fatalf("len: got %d, want 1", hub.Len())
	}

	hub.Remove(id)

	if hub.Len() != 0 {
		t.Fatalf("len after remove: got %d, want 0", hub.Len())
	}

	// Broadcast to empty hub should not panic.
	hub.Broadcast([]byte("nobody home"))
}

func TestChangeDetection(t *testing.T) {
	hub := NewHub()
	ch := make(chan []byte, 16)
	hub.Add(ch)

	// Simulate two identical polls — only one broadcast.
	body := `[{"id":"1","status":"pending"}]`
	var lastBody string

	for i := 0; i < 3; i++ {
		if body != lastBody {
			hub.Broadcast(PatchSignalsFrame("orders", []byte(body)))
			lastBody = body
		}
	}

	// Should have received exactly one event.
	if len(ch) != 1 {
		t.Errorf("got %d events, want 1", len(ch))
	}

	// Now change the body — should broadcast again.
	body = `[{"id":"1","status":"confirmed"}]`
	if body != lastBody {
		hub.Broadcast(PatchSignalsFrame("orders", []byte(body)))
		lastBody = body
	}

	if len(ch) != 2 {
		t.Errorf("got %d events, want 2", len(ch))
	}
}

// --- Handler tests using httptest ---

// fakeTiger returns an httptest.Server that responds based on path and auth.
func fakeTiger(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	ts := httptest.NewServer(handler)
	t.Cleanup(ts.Close)
	return ts
}

func TestHandleSSE_ValidToken(t *testing.T) {
	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer good-token" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"data":[]}`))
	})

	hub := NewHub()
	handler := HandleSSE(hub, tiger.URL)

	// Use a context we can cancel to end the SSE stream.
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest("GET", "/events?token=good-token", nil).WithContext(ctx)
	rec := &flushRecorder{ResponseRecorder: httptest.NewRecorder()}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		handler.ServeHTTP(rec, req)
	}()

	// Wait for client to register.
	waitFor(t, func() bool { return hub.Len() == 1 })

	// Push an event.
	hub.Broadcast([]byte("event: datastar-patch-signals\ndata: signals {\"test\":1}\n\n"))

	// Give the handler time to write.
	time.Sleep(20 * time.Millisecond)
	cancel()
	wg.Wait()

	body := rec.Body.String()
	if !strings.Contains(body, "datastar-patch-signals") {
		t.Errorf("SSE stream missing event, got: %q", body)
	}

	// Headers.
	if got := rec.Header().Get("Content-Type"); got != "text/event-stream" {
		t.Errorf("Content-Type: got %q, want text/event-stream", got)
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-cache" {
		t.Errorf("Cache-Control: got %q, want no-cache", got)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Errorf("CORS: got %q, want *", got)
	}

	// Client should be removed after disconnect.
	if hub.Len() != 0 {
		t.Errorf("hub.Len after disconnect: got %d, want 0", hub.Len())
	}
}

func TestHandleSSE_BadToken(t *testing.T) {
	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	})

	hub := NewHub()
	handler := HandleSSE(hub, tiger.URL)

	req := httptest.NewRequest("GET", "/events?token=bad-token", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status: got %d, want 401", rec.Code)
	}
	if hub.Len() != 0 {
		t.Errorf("hub should be empty after rejected auth, got %d", hub.Len())
	}
}

func TestHandleSSE_MissingToken(t *testing.T) {
	hub := NewHub()
	handler := HandleSSE(hub, "http://unused")

	req := httptest.NewRequest("GET", "/events", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status: got %d, want 401", rec.Code)
	}
}

func TestHandleProxy_ForwardsRequest(t *testing.T) {
	var gotMethod, gotPath, gotAuth, gotContentType, gotBody string

	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		gotContentType = r.Header.Get("Content-Type")
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"id":"123"}`))
	})

	handler := HandleProxy(tiger.URL)

	body := strings.NewReader(`{"name":"Widget"}`)
	req := httptest.NewRequest("POST", "/products", body)
	req.Header.Set("Authorization", "Bearer my-token")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	// Verify forwarded request.
	if gotMethod != "POST" {
		t.Errorf("method: got %q, want POST", gotMethod)
	}
	if gotPath != "/products" {
		t.Errorf("path: got %q, want /products", gotPath)
	}
	if gotAuth != "Bearer my-token" {
		t.Errorf("auth: got %q, want Bearer my-token", gotAuth)
	}
	if gotContentType != "application/json" {
		t.Errorf("content-type: got %q, want application/json", gotContentType)
	}
	if gotBody != `{"name":"Widget"}` {
		t.Errorf("body: got %q", gotBody)
	}

	// Verify relayed response.
	if rec.Code != http.StatusCreated {
		t.Errorf("status: got %d, want 201", rec.Code)
	}
	if rec.Body.String() != `{"id":"123"}` {
		t.Errorf("response body: got %q", rec.Body.String())
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Errorf("CORS: got %q, want *", got)
	}
}

func TestHandleProxy_Passes401(t *testing.T) {
	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte(`{"error":"unauthorized"}`))
	})

	handler := HandleProxy(tiger.URL)
	req := httptest.NewRequest("GET", "/orders", nil)
	req.Header.Set("Authorization", "Bearer expired-token")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status: got %d, want 401", rec.Code)
	}
}

func TestHandleProxy_CORSPreflight(t *testing.T) {
	handler := HandleProxy("http://unused")

	req := httptest.NewRequest("OPTIONS", "/products", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Errorf("status: got %d, want 204", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Methods"); !strings.Contains(got, "POST") {
		t.Errorf("allow-methods: got %q, want to contain POST", got)
	}
}

func TestHandleProxy_QueryParams(t *testing.T) {
	var gotURI string
	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		gotURI = r.URL.RequestURI()
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"data":[]}`))
	})

	handler := HandleProxy(tiger.URL)
	req := httptest.NewRequest("GET", "/products?active=true&cursor=abc", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if gotURI != "/products?active=true&cursor=abc" {
		t.Errorf("query params not forwarded: got %q", gotURI)
	}
}

func TestPollOrders_BroadcastsOnChange(t *testing.T) {
	var mu sync.Mutex
	callCount := 0
	responses := []string{
		`{"data":[{"id":"1","status":"pending"}]}`,
		`{"data":[{"id":"1","status":"pending"}]}`,
		`{"data":[{"id":"1","status":"confirmed"}]}`,
	}

	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		idx := callCount
		callCount++
		mu.Unlock()

		if idx >= len(responses) {
			idx = len(responses) - 1
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(responses[idx]))
	})

	hub := NewHub()
	ch := make(chan []byte, 16)
	hub.Add(ch)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go PollOrders(ctx, hub, tiger.URL, "test-token", 10*time.Millisecond)

	// Wait for at least 3 polls.
	waitFor(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return callCount >= 3
	})

	// Give final broadcast time to arrive.
	time.Sleep(20 * time.Millisecond)
	cancel()

	// Should have exactly 2 broadcasts: initial + change.
	// (First poll is new, second is same, third is different.)
	got := drainChan(ch)
	if len(got) != 2 {
		t.Errorf("got %d broadcasts, want 2", len(got))
		for i, e := range got {
			t.Logf("  event %d: %s", i, e)
		}
	}
}

func TestHandleSSE_TigerDown(t *testing.T) {
	hub := NewHub()
	// Point at a closed listener — connection refused.
	handler := HandleSSE(hub, "http://127.0.0.1:1")

	req := httptest.NewRequest("GET", "/events?token=some-token", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Errorf("status: got %d, want 502", rec.Code)
	}
	if hub.Len() != 0 {
		t.Errorf("hub should be empty when tiger_web is down, got %d", hub.Len())
	}
}

func TestHandleProxy_TigerDown(t *testing.T) {
	handler := HandleProxy("http://127.0.0.1:1")

	req := httptest.NewRequest("GET", "/products", nil)
	req.Header.Set("Authorization", "Bearer token")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Errorf("status: got %d, want 502", rec.Code)
	}
}

func TestPollOrders_StopsOn401(t *testing.T) {
	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	})

	hub := NewHub()
	done := make(chan struct{})
	go func() {
		PollOrders(context.Background(), hub, tiger.URL, "expired", 10*time.Millisecond)
		close(done)
	}()

	select {
	case <-done:
		// Poller exited as expected.
	case <-time.After(time.Second):
		t.Fatal("poller did not stop on 401")
	}
}

func TestHandleProxy_DeleteMethod(t *testing.T) {
	var gotMethod, gotPath string
	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"deleted":true}`))
	})

	handler := HandleProxy(tiger.URL)
	req := httptest.NewRequest("DELETE", "/products/abc", nil)
	req.Header.Set("Authorization", "Bearer token")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if gotMethod != "DELETE" {
		t.Errorf("method: got %q, want DELETE", gotMethod)
	}
	if gotPath != "/products/abc" {
		t.Errorf("path: got %q, want /products/abc", gotPath)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status: got %d, want 200", rec.Code)
	}
}

func TestHandleProxy_PutMethod(t *testing.T) {
	var gotMethod, gotBody string
	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"updated":true}`))
	})

	handler := HandleProxy(tiger.URL)
	body := strings.NewReader(`{"result":"confirmed"}`)
	req := httptest.NewRequest("PUT", "/orders/abc", body)
	req.Header.Set("Authorization", "Bearer token")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if gotMethod != "PUT" {
		t.Errorf("method: got %q, want PUT", gotMethod)
	}
	if gotBody != `{"result":"confirmed"}` {
		t.Errorf("body: got %q", gotBody)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status: got %d, want 200", rec.Code)
	}
}

func TestHandleProxy_NoAuthHeader(t *testing.T) {
	var gotAuth string
	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusUnauthorized)
	})

	handler := HandleProxy(tiger.URL)
	req := httptest.NewRequest("GET", "/products", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if gotAuth != "" {
		t.Errorf("auth: got %q, want empty", gotAuth)
	}
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status: got %d, want 401", rec.Code)
	}
}

func TestHandleProxy_LargeBody(t *testing.T) {
	var gotLen int
	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotLen = len(b)
		w.WriteHeader(http.StatusOK)
	})

	handler := HandleProxy(tiger.URL)
	largeBody := strings.Repeat("x", 64*1024)
	req := httptest.NewRequest("POST", "/products", strings.NewReader(largeBody))
	req.Header.Set("Authorization", "Bearer token")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if gotLen != 64*1024 {
		t.Errorf("body length: got %d, want %d", gotLen, 64*1024)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status: got %d, want 200", rec.Code)
	}
}

func TestPollOrders_ContinuesOnServerError(t *testing.T) {
	var mu sync.Mutex
	callCount := 0

	tiger := fakeTiger(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		callCount++
		n := callCount
		mu.Unlock()

		if n <= 2 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"data":[]}`))
	})

	hub := NewHub()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go PollOrders(ctx, hub, tiger.URL, "token", 10*time.Millisecond)

	// Wait for poller to recover past the errors.
	waitFor(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return callCount >= 4
	})

	// Poller is still running (didn't exit on 500).
	cancel()
}

// --- helpers ---

// flushRecorder wraps httptest.ResponseRecorder to implement http.Flusher.
type flushRecorder struct {
	*httptest.ResponseRecorder
}

func (f *flushRecorder) Flush() {}

// waitFor polls a condition with a timeout.
func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("waitFor: timed out")
}

// drainChan reads all buffered messages from a channel.
func drainChan(ch chan []byte) [][]byte {
	var out [][]byte
	for {
		select {
		case msg := <-ch:
			out = append(out, msg)
		default:
			return out
		}
	}
}
