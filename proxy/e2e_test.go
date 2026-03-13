package main

import (
	"bufio"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestE2E_SSEReceivesBroadcast verifies the full flow:
// browser connects SSE → poller detects change → browser receives event.
func TestE2E_SSEReceivesBroadcast(t *testing.T) {
	// Fake tiger_web: serves orders, returns 200 for auth probe.
	var mu sync.Mutex
	orderResponse := `{"data":[]}`

	tiger := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer good-token" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		mu.Lock()
		resp := orderResponse
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(resp))
	}))
	defer tiger.Close()

	hub := NewHub()

	// Start poller.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go PollOrders(ctx, hub, tiger.URL, "good-token", 50*time.Millisecond)

	// Wait for first poll to establish baseline.
	time.Sleep(100 * time.Millisecond)

	// Connect SSE client.
	sseHandler := HandleSSE(hub, tiger.URL)
	sseCtx, sseCancel := context.WithCancel(context.Background())
	defer sseCancel()

	req := httptest.NewRequest("GET", "/events?token=good-token", nil).WithContext(sseCtx)
	rec := &flushRecorder{ResponseRecorder: httptest.NewRecorder()}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		sseHandler.ServeHTTP(rec, req)
	}()

	// Wait for client registration.
	waitFor(t, func() bool { return hub.Len() == 1 })

	// Change order state — poller should detect and broadcast.
	mu.Lock()
	orderResponse = `{"data":[{"id":"abc","status":"pending"}]}`
	mu.Unlock()

	// Wait for broadcast to arrive.
	time.Sleep(200 * time.Millisecond)
	sseCancel()
	wg.Wait()

	body := rec.Body.String()
	if !strings.Contains(body, "event: datastar-merge-signals") {
		t.Errorf("SSE stream missing event line, got:\n%s", body)
	}
	if !strings.Contains(body, `"orders"`) {
		t.Errorf("SSE stream missing orders key, got:\n%s", body)
	}
	if !strings.Contains(body, `"status":"pending"`) {
		t.Errorf("SSE stream missing order data, got:\n%s", body)
	}
}

// TestE2E_ProxyRoundTrip tests the full proxy flow with a fake tiger_web.
func TestE2E_ProxyRoundTrip(t *testing.T) {
	tiger := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer good-token" {
			w.WriteHeader(http.StatusUnauthorized)
			w.Write([]byte(`{"error":"unauthorized"}`))
			return
		}

		switch {
		case r.Method == "GET" && r.URL.Path == "/products":
			w.WriteHeader(http.StatusOK)
			w.Write([]byte(`{"data":[{"id":"abc","name":"Widget"}]}`))

		case r.Method == "POST" && r.URL.Path == "/products":
			body, _ := io.ReadAll(r.Body)
			if len(body) == 0 {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			w.WriteHeader(http.StatusOK)
			w.Write(body) // Echo back for verification.

		case r.Method == "GET" && r.URL.Path == "/orders":
			w.WriteHeader(http.StatusOK)
			w.Write([]byte(`{"data":[]}`))

		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer tiger.Close()

	proxyHandler := HandleProxy(tiger.URL)

	tests := []struct {
		name       string
		method     string
		path       string
		auth       string
		body       string
		wantStatus int
		wantBody   string
	}{
		{
			name:       "GET products with valid token",
			method:     "GET",
			path:       "/products",
			auth:       "Bearer good-token",
			wantStatus: 200,
			wantBody:   `{"data":[{"id":"abc","name":"Widget"}]}`,
		},
		{
			name:       "POST products with body",
			method:     "POST",
			path:       "/products",
			auth:       "Bearer good-token",
			body:       `{"id":"123","name":"Gadget"}`,
			wantStatus: 200,
			wantBody:   `{"id":"123","name":"Gadget"}`,
		},
		{
			name:       "GET with bad token",
			method:     "GET",
			path:       "/products",
			auth:       "Bearer bad-token",
			wantStatus: 401,
		},
		{
			name:       "GET with query params",
			method:     "GET",
			path:       "/products?active=true",
			auth:       "Bearer good-token",
			wantStatus: 200,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var body io.Reader
			if tt.body != "" {
				body = strings.NewReader(tt.body)
			}
			req := httptest.NewRequest(tt.method, tt.path, body)
			if tt.auth != "" {
				req.Header.Set("Authorization", tt.auth)
			}
			if tt.body != "" {
				req.Header.Set("Content-Type", "application/json")
			}
			rec := httptest.NewRecorder()
			proxyHandler.ServeHTTP(rec, req)

			if rec.Code != tt.wantStatus {
				t.Errorf("status: got %d, want %d", rec.Code, tt.wantStatus)
			}
			if tt.wantBody != "" && rec.Body.String() != tt.wantBody {
				t.Errorf("body: got %q, want %q", rec.Body.String(), tt.wantBody)
			}
		})
	}
}

// TestE2E_SSEMultipleEvents verifies a client receives multiple events
// as the order state changes over time.
func TestE2E_SSEMultipleEvents(t *testing.T) {
	var mu sync.Mutex
	callCount := 0
	responses := []string{
		`{"data":[]}`,
		`{"data":[{"id":"1","status":"pending"}]}`,
		`{"data":[{"id":"1","status":"pending"}]}`,
		`{"data":[{"id":"1","status":"confirmed"}]}`,
	}

	tiger := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		idx := callCount
		callCount++
		mu.Unlock()
		if idx >= len(responses) {
			idx = len(responses) - 1
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(responses[idx]))
	}))
	defer tiger.Close()

	hub := NewHub()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Connect SSE client first.
	sseCtx, sseCancel := context.WithCancel(context.Background())
	defer sseCancel()

	req := httptest.NewRequest("GET", "/events?token=t", nil).WithContext(sseCtx)
	rec := &flushRecorder{ResponseRecorder: httptest.NewRecorder()}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		HandleSSE(hub, tiger.URL).ServeHTTP(rec, req)
	}()

	waitFor(t, func() bool { return hub.Len() == 1 })

	// Start poller — first response is baseline, next three produce 2 changes.
	go PollOrders(ctx, hub, tiger.URL, "t", 20*time.Millisecond)

	// Wait for all polls to complete.
	waitFor(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return callCount >= len(responses)
	})

	time.Sleep(50 * time.Millisecond)
	sseCancel()
	wg.Wait()

	body := rec.Body.String()
	events := countSSEEvents(body)

	// Expect 3 events: initial empty→pending (from poller baseline establishing),
	// then the actual pending and confirmed changes.
	// The poller's first call establishes baseline. Auth probe also hits tiger.
	// Exact count depends on timing, but we should have at least 2.
	if events < 2 {
		t.Errorf("expected at least 2 SSE events, got %d\nbody:\n%s", events, body)
	}

	if !strings.Contains(body, `"confirmed"`) {
		t.Errorf("final confirmed state not in SSE stream:\n%s", body)
	}
}

func countSSEEvents(body string) int {
	count := 0
	scanner := bufio.NewScanner(strings.NewReader(body))
	for scanner.Scan() {
		if strings.HasPrefix(scanner.Text(), "event: ") {
			count++
		}
	}
	return count
}
