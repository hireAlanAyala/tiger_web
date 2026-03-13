package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	tigerAddr := envOr("TIGER_ADDR", "http://127.0.0.1:3000")
	token := os.Getenv("TOKEN")
	port := envOr("PROXY_PORT", "8080")
	pollInterval := envDurationOr("POLL_INTERVAL", 500*time.Millisecond)

	if token == "" {
		log.Fatal("TOKEN not set")
	}

	hub := NewHub()

	go PollOrders(context.Background(), hub, tigerAddr, token, pollInterval)

	mux := http.NewServeMux()
	mux.HandleFunc("/events", HandleSSE(hub, tigerAddr))
	mux.HandleFunc("/", HandleProxy(tigerAddr))

	log.Printf("proxy: listening on :%s, forwarding to %s", port, tigerAddr)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envDurationOr(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		d, err := time.ParseDuration(v)
		if err == nil {
			return d
		}
	}
	return fallback
}
