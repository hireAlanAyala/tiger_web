package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// FuzzMergeSignalsFrame ensures MergeSignalsFrame never panics and always
// produces valid SSE framing regardless of input.
func FuzzMergeSignalsFrame(f *testing.F) {
	f.Add("orders", `[{"id":"1"}]`)
	f.Add("", "")
	f.Add("key with spaces", `null`)
	f.Add("orders", strings.Repeat("x", 10000))
	f.Add("\n\n", "data: injection\n\n")

	f.Fuzz(func(t *testing.T, key string, json string) {
		frame := MergeSignalsFrame(key, []byte(json))
		s := string(frame)

		if !strings.HasPrefix(s, "event: datastar-merge-signals\n") {
			t.Errorf("missing event line: %q", s)
		}
		if !strings.Contains(s, "data: signals {") {
			t.Errorf("missing data line: %q", s)
		}
		if !strings.HasSuffix(s, "\n\n") {
			t.Errorf("missing double newline terminator: %q", s)
		}
	})
}

// FuzzHandleProxy throws random methods, paths, and bodies at the proxy
// handler with a down backend. Verifies: no panics, always returns 502,
// CORS headers always set.
func FuzzHandleProxy(f *testing.F) {
	f.Add("GET", "/products", "", "Bearer token")
	f.Add("POST", "/products", `{"id":"abc","name":"Widget","price_cents":100}`, "Bearer token")
	f.Add("PUT", "/orders/abc", `{"result":"confirmed"}`, "Bearer token")
	f.Add("DELETE", "/products/abc", "", "Bearer token")
	f.Add("GET", "/products?active=true&cursor=abc", "", "Bearer token")
	f.Add("POST", "/", strings.Repeat("{", 10000), "")
	f.Add("PATCH", "/invalid-path", "garbage body", "Bearer bad")

	// Point at a closed port — every request gets 502. This exercises the
	// full HandleProxy code path (read body, build request, forward, handle
	// error) without needing a live server per iteration.
	handler := HandleProxy("http://127.0.0.1:1")

	f.Fuzz(func(t *testing.T, method, path, body, auth string) {
		// OPTIONS is a special CORS path that never forwards — skip it
		// since we test it separately and it would return 204 not 502.
		if method == "OPTIONS" {
			return
		}

		var reqBody io.Reader
		if body != "" {
			reqBody = strings.NewReader(body)
		}

		req, err := http.NewRequest(method, "http://localhost"+path, reqBody)
		if err != nil {
			return
		}
		if req.Body == nil {
			req.Body = http.NoBody
		}
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		rec := httptest.NewRecorder()

		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusBadGateway {
			t.Errorf("status: got %d, want 502", rec.Code)
		}
		if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "*" {
			t.Errorf("missing CORS header, got %q", got)
		}
	})
}

// FuzzHandleSSE throws random tokens at the SSE handler with a down backend.
// Verifies: no panics, returns 401 or 502 (never hangs), no hub leaks.
func FuzzHandleSSE(f *testing.F) {
	f.Add("good-token")
	f.Add("")
	f.Add("bad-token")
	f.Add(strings.Repeat("x", 10000))
	f.Add("\x00\xff")

	f.Fuzz(func(t *testing.T, token string) {
		hub := NewHub()
		// Down backend — SSE handler returns 401 (missing token) or 502.
		handler := HandleSSE(hub, "http://127.0.0.1:1")

		path := "/events"
		if token != "" {
			path += "?token=" + token
		}

		req, err := http.NewRequest("GET", "http://localhost"+path, nil)
		if err != nil {
			return
		}
		rec := httptest.NewRecorder()

		handler.ServeHTTP(rec, req)

		// Token may be empty (param missing) or effectively empty (e.g. "#"
		// acts as fragment separator). Either way: 401 or 502 are valid.
		if rec.Code != http.StatusUnauthorized && rec.Code != http.StatusBadGateway {
			t.Errorf("got %d, want 401 or 502", rec.Code)
		}

		if hub.Len() != 0 {
			t.Errorf("hub leaked %d clients", hub.Len())
		}
	})
}

// FuzzHttpDoFull ensures the internal HTTP forwarding function never panics
// on arbitrary inputs when the backend is unreachable.
func FuzzHttpDoFull(f *testing.F) {
	f.Add("GET", "/products", "", "application/json", "")
	f.Add("POST", "/", "Bearer tok", "text/plain", `{"a":1}`)
	f.Add("DELETE", "/x/y/z", "", "", "")
	f.Add("\x00", "\x00", "\xff", "\xff", "\xff")

	f.Fuzz(func(t *testing.T, method, path, auth, contentType, body string) {
		var reqBody io.Reader
		if body != "" {
			reqBody = bytes.NewReader([]byte(body))
		}

		status, respBody := httpDoFull(method, "http://127.0.0.1:1"+path, auth, contentType, reqBody)

		if status != http.StatusBadGateway {
			t.Errorf("status: got %d, want 502", status)
		}
		if respBody == nil {
			t.Error("response body is nil")
		}
	})
}
