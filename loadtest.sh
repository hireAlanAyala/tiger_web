#!/usr/bin/env bash
#
# Load test the tiger-web server using hey.
#
# Prerequisites:
#   - hey: go install github.com/rakyll/hey@latest
#   - Server running: ./zig/zig build run
#   - Seed some products first (see seed section below)
#
# Usage:
#   ./loadtest.sh                  # run all tests
#   ./loadtest.sh seed             # seed products only
#   ./loadtest.sh get              # point read only
#   ./loadtest.sh list             # list scan only

set -euo pipefail

HOST="${HOST:-http://localhost:3000}"
DURATION="${DURATION:-10}"
CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1 8 16 32 64 128}"
SEED_COUNT="${SEED_COUNT:-50}"

# Generate a JWT token for auth (valid for 1 hour).
# Uses the default HMAC secret from auth.zig.
TOKEN="${TOKEN:-}"

if [ -z "$TOKEN" ]; then
    echo "TOKEN env var not set. Generate one from testgraph.html or set TOKEN=<jwt>"
    echo "Example: TOKEN=eyJ... ./loadtest.sh"
    exit 1
fi

AUTH_HEADER="Authorization: Bearer $TOKEN"

seed() {
    echo "=== Seeding $SEED_COUNT products ==="
    for i in $(seq 1 "$SEED_COUNT"); do
        id=$(printf '%032x' $((i + 1000)))
        curl -s -X POST "$HOST/products" \
            -H "Content-Type: application/json" \
            -H "$AUTH_HEADER" \
            -d "{\"id\":\"$id\",\"name\":\"Product $i\",\"description\":\"Bench product\",\"price\":999,\"stock\":100}" \
            > /dev/null
    done
    echo "Seeded $SEED_COUNT products."
}

bench_get() {
    # Pick a known product ID for point reads.
    ID=$(printf '%032x' 1001)
    echo ""
    echo "=== GET /products/$ID (point read) ==="
    echo ""
    printf "%-12s  %-10s  %-12s\n" "Concurrency" "Req/sec" "Avg Latency"
    printf "%-12s  %-10s  %-12s\n" "-----------" "-------" "-----------"
    for c in $CONCURRENCY_LEVELS; do
        result=$(hey -n $((c * 1000)) -c "$c" -H "$AUTH_HEADER" \
            "$HOST/products/$ID" 2>&1)
        rps=$(echo "$result" | grep "Requests/sec:" | awk '{print $2}')
        avg=$(echo "$result" | grep "Average:" | head -1 | awk '{printf "%.1fms", $2 * 1000}')
        printf "%-12s  %-10s  %-12s\n" "$c" "$rps" "$avg"
    done
}

bench_list() {
    echo ""
    echo "=== GET /products (list scan) ==="
    echo ""
    printf "%-12s  %-10s  %-12s\n" "Concurrency" "Req/sec" "Avg Latency"
    printf "%-12s  %-10s  %-12s\n" "-----------" "-------" "-----------"
    for c in $CONCURRENCY_LEVELS; do
        result=$(hey -n $((c * 1000)) -c "$c" -H "$AUTH_HEADER" \
            "$HOST/products" 2>&1)
        rps=$(echo "$result" | grep "Requests/sec:" | awk '{print $2}')
        avg=$(echo "$result" | grep "Average:" | head -1 | awk '{printf "%.1fms", $2 * 1000}')
        printf "%-12s  %-10s  %-12s\n" "$c" "$rps" "$avg"
    done
}

case "${1:-all}" in
    seed) seed ;;
    get)  bench_get ;;
    list) bench_list ;;
    all)  seed; bench_get; bench_list ;;
    *)    echo "Usage: $0 {seed|get|list|all}"; exit 1 ;;
esac
