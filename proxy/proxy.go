package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"
)

// Shared HTTP client with a timeout. Without this, a hung tiger_web blocks
// the forwarding goroutine or poller forever. 5 seconds is generous — tiger_web
// responds in microseconds under normal load.
var httpClient = &http.Client{Timeout: 5 * time.Second}

// Hub manages SSE client connections.
type Hub struct {
	mu      sync.Mutex
	clients map[uint64]chan []byte
	nextID  uint64
}

func NewHub() *Hub {
	return &Hub{clients: make(map[uint64]chan []byte)}
}

func (h *Hub) Add(ch chan []byte) uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	id := h.nextID
	h.nextID++
	h.clients[id] = ch
	return id
}

func (h *Hub) Remove(id uint64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, id)
}

func (h *Hub) Broadcast(data []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, ch := range h.clients {
		select {
		case ch <- data:
		default:
			// Slow consumer — skip, they'll get the next update.
		}
	}
}

func (h *Hub) Len() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// PatchSignalsFrame builds a Datastar patch-signals SSE event.
func PatchSignalsFrame(key string, json []byte) []byte {
	return fmt.Appendf(nil, "event: datastar-patch-signals\ndata: signals {\"%s\":%s}\n\n", key, json)
}

// HandleSSE serves a long-lived SSE connection to a browser.
func HandleSSE(hub *Hub, tigerAddr string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.URL.Query().Get("token")
		if token == "" {
			http.Error(w, "missing token", http.StatusUnauthorized)
			return
		}

		// Validate token by probing tiger_web.
		status, _ := httpDo("GET", tigerAddr+"/orders", token, nil)
		if status == http.StatusUnauthorized {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if status == 0 {
			http.Error(w, "bad gateway", http.StatusBadGateway)
			return
		}

		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming not supported", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		flusher.Flush()

		// Buffer 16 events before dropping. At 500ms poll intervals, this
		// absorbs ~8 seconds of backpressure from a slow browser connection.
		ch := make(chan []byte, 16)
		id := hub.Add(ch)
		defer hub.Remove(id)

		log.Printf("sse: client %d connected", id)
		defer log.Printf("sse: client %d disconnected", id)

		ctx := r.Context()
		for {
			select {
			case <-ctx.Done():
				return
			case data := <-ch:
				_, err := w.Write(data)
				if err != nil {
					return
				}
				flusher.Flush()
			}
		}
	}
}

// HandleProxy forwards requests to tiger_web and relays the response.
// When the Datastar-Request header is present, the JSON response is wrapped
// in an SSE datastar-patch-signals event so Datastar actions (@get, @post, etc.)
// can consume it directly.
func HandleProxy(tigerAddr string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// CORS preflight.
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Datastar-Request")
			w.WriteHeader(http.StatusNoContent)
			return
		}

		token := r.Header.Get("Authorization")

		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}

		var reqBody io.Reader
		// Datastar sends signals as a body on every request, but tiger_web
		// rejects GET/DELETE with a body. Strip it for those methods.
		if len(body) > 0 && r.Method != http.MethodGet && r.Method != http.MethodDelete {
			reqBody = bytes.NewReader(body)
		}

		status, respBody := httpDoFull(r.Method, tigerAddr+r.URL.RequestURI(), token, r.Header.Get("Content-Type"), reqBody)

		w.Header().Set("Access-Control-Allow-Origin", "*")

		if r.Header.Get("Datastar-Request") == "true" {
			w.Header().Set("Content-Type", "text/event-stream")
			w.Header().Set("Cache-Control", "no-cache")
			renderDatastarResponse(w, r.Method, r.URL.Path, tigerAddr, token, status, respBody)
		} else {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			w.Write(respBody)
		}
	}
}

// PollOrders polls tiger_web for order changes and broadcasts to SSE clients.
func PollOrders(ctx context.Context, hub *Hub, tigerAddr, token string, interval time.Duration) {
	var lastBody string
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	log.Printf("poller: started, interval=%s", interval)

	for {
		select {
		case <-ctx.Done():
			log.Printf("poller: stopped")
			return
		case <-ticker.C:
			status, body := httpDo("GET", tigerAddr+"/orders", token, nil)
			if status == http.StatusUnauthorized {
				log.Printf("poller: token expired, stopping")
				return
			}
			if status != http.StatusOK {
				log.Printf("poller: poll failed, status=%d", status)
				continue
			}
			bodyStr := string(body)
			if bodyStr == lastBody {
				continue
			}
			lastBody = bodyStr
			hub.Broadcast(PatchElementsFrame("#order-list", "inner", renderOrderList(body)))
			log.Printf("poller: order change detected, broadcast to %d clients", hub.Len())
		}
	}
}

// httpDo makes an HTTP request and returns (status, body).
func httpDo(method, url, token string, body io.Reader) (int, []byte) {
	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return 0, nil
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return 0, nil
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, respBody
}

// httpDoFull forwards a request preserving content type and auth header as-is.
func httpDoFull(method, url, auth, contentType string, body io.Reader) (int, []byte) {
	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return http.StatusBadGateway, []byte(`{"error":"bad gateway"}`)
	}
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return http.StatusBadGateway, []byte(`{"error":"bad gateway"}`)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, respBody
}
