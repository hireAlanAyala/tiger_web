#!/usr/bin/env bash
#
# Load test the tiger-web server using hey.
#
# Prerequisites:
#   - hey: go install github.com/rakyll/hey@latest
#   - source dev.env (sets SECRET_KEY and TOKEN)
#   - Server running: ./zig/zig build run
#
# Usage:
#   ./loadtest.sh                  # run all (seed + HTTP benchmarks)
#   ./loadtest.sh seed             # seed products only
#   ./loadtest.sh get              # point read only
#   ./loadtest.sh list             # list scan only
#   ./loadtest.sh search           # full-text search
#   ./loadtest.sh order            # create order
#   ./loadtest.sh worker           # worker drain (creates orders, measures completion)
#
# Environment:
#   TOKEN          — JWT auth token (required, from dev.env)
#   HOST           — server URL (default: http://localhost:3000)
#   SEED_COUNT     — products to seed (default: 50)
#   WORKER_ORDERS  — orders for worker bench (default: 100)

set -euo pipefail

HOST="${HOST:-http://localhost:3000}"
CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1 8 16 32 64 128}"
SEED_COUNT="${SEED_COUNT:-50}"
TOKEN="${TOKEN:-}"

if [ -z "$TOKEN" ]; then
    echo "error: TOKEN not set. Run: source dev.env"
    exit 1
fi

AUTH_HEADER="Authorization: Bearer $TOKEN"

# Verify server is reachable before running anything.
if ! curl -sf "$HOST/products" -H "$AUTH_HEADER" > /dev/null 2>&1; then
    echo "error: server not reachable at $HOST"
    echo "Start it with: source dev.env && ./zig/zig build run"
    exit 1
fi

bench_table_header() {
    printf "%-12s  %-10s  %-12s\n" "Concurrency" "Req/sec" "Avg Latency"
    printf "%-12s  %-10s  %-12s\n" "-----------" "-------" "-----------"
}

bench_row() {
    local result="$1" c="$2"
    local rps avg
    rps=$(echo "$result" | grep "Requests/sec:" | awk '{print $2}')
    avg=$(echo "$result" | grep "Average:" | head -1 | awk '{printf "%.1fms", $2 * 1000}')
    printf "%-12s  %-10s  %-12s\n" "$c" "$rps" "$avg"
}

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
    local ID
    ID=$(printf '%032x' 1001)
    echo ""
    echo "=== GET /products/$ID (point read) ==="
    echo ""
    bench_table_header
    for c in $CONCURRENCY_LEVELS; do
        local result
        result=$(hey -n $((c * 1000)) -c "$c" -H "$AUTH_HEADER" \
            "$HOST/products/$ID" 2>&1)
        bench_row "$result" "$c"
    done
}

bench_list() {
    echo ""
    echo "=== GET /products (list scan) ==="
    echo ""
    bench_table_header
    for c in $CONCURRENCY_LEVELS; do
        local result
        result=$(hey -n $((c * 1000)) -c "$c" -H "$AUTH_HEADER" \
            "$HOST/products" 2>&1)
        bench_row "$result" "$c"
    done
}

bench_update() {
    local ID BODY
    ID=$(printf '%032x' 1001)
    BODY="{\"name\":\"Updated\",\"price_cents\":1234,\"version\":0}"
    echo ""
    echo "=== PUT /products/$ID (update) ==="
    echo ""
    bench_table_header
    for c in $CONCURRENCY_LEVELS; do
        local result
        result=$(hey -n $((c * 1000)) -c "$c" \
            -m PUT \
            -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" \
            -d "$BODY" \
            "$HOST/products/$ID" 2>&1)
        bench_row "$result" "$c"
    done
}

bench_search() {
    echo ""
    echo "=== GET /products?q=Product (search) ==="
    echo ""
    bench_table_header
    for c in $CONCURRENCY_LEVELS; do
        local result
        result=$(hey -n $((c * 1000)) -c "$c" -H "$AUTH_HEADER" \
            "$HOST/products?q=Product" 2>&1)
        bench_row "$result" "$c"
    done
}

bench_create_order() {
    local PRODUCT_ID
    PRODUCT_ID=$(printf '%032x' 1001)
    echo ""
    echo "=== POST /orders (create order) ==="
    echo ""
    bench_table_header
    for c in $CONCURRENCY_LEVELS; do
        local ORDER_ID BODY result
        ORDER_ID=$(printf '%032x' $((RANDOM * RANDOM)))
        BODY="{\"id\":\"$ORDER_ID\",\"items\":[{\"product_id\":\"$PRODUCT_ID\",\"quantity\":1}]}"
        result=$(hey -n $((c * 1000)) -c "$c" \
            -m POST \
            -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" \
            -d "$BODY" \
            "$HOST/orders" 2>&1)
        bench_row "$result" "$c"
    done
}

bench_worker() {
    local ORDER_COUNT PRODUCT_ID
    ORDER_COUNT="${WORKER_ORDERS:-100}"
    PRODUCT_ID=$(printf '%032x' 1001)

    echo ""
    echo "=== Worker drain: $ORDER_COUNT orders ==="
    echo ""

    # Ensure product exists.
    curl -s -X POST "$HOST/products" \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -d "{\"id\":\"$PRODUCT_ID\",\"name\":\"Bench Product\",\"price\":999,\"stock\":100000}" \
        > /dev/null

    # Create pending orders.
    echo "Creating $ORDER_COUNT pending orders..."
    for i in $(seq 1 "$ORDER_COUNT"); do
        local ORDER_ID
        ORDER_ID=$(printf '%032x' $((200000 + i)))
        curl -s -X POST "$HOST/orders" \
            -H "Content-Type: application/json" \
            -H "$AUTH_HEADER" \
            -d "{\"id\":\"$ORDER_ID\",\"items\":[{\"product_id\":\"$PRODUCT_ID\",\"quantity\":1}]}" \
            > /dev/null
    done
    echo "Created $ORDER_COUNT pending orders."

    # Build then run worker binary directly (zig build run-worker doesn't
    # background cleanly because the build system wraps the process).
    ./zig/zig build 2>/dev/null

    echo "Starting worker (delay=0ms, poll=100ms)..."
    local START END ELAPSED_MS RATE WORKER_PID
    START=$(date +%s%N)
    TOKEN="$TOKEN" ./zig-out/bin/tiger-worker --delay-ms=0 --poll-ms=100 2>/dev/null &
    WORKER_PID=$!

    # Poll until no pending orders remain.
    while true; do
        sleep 0.5
        local RESPONSE PENDING
        RESPONSE=$(curl -s "$HOST/orders" -H "$AUTH_HEADER")
        PENDING=$(echo "$RESPONSE" | grep -co '"status":"pending"' || true)
        if [ "$PENDING" -eq 0 ]; then
            break
        fi
        echo "  $PENDING orders still pending..."
    done

    END=$(date +%s%N)
    kill "$WORKER_PID" 2>/dev/null
    wait "$WORKER_PID" 2>/dev/null || true

    ELAPSED_MS=$(( (END - START) / 1000000 ))
    RATE=$(awk "BEGIN { printf \"%.1f\", $ORDER_COUNT * 1000 / $ELAPSED_MS }")
    echo ""
    echo "Drained $ORDER_COUNT orders in ${ELAPSED_MS}ms (${RATE} orders/sec)"
}

case "${1:-all}" in
    seed)   seed ;;
    get)    bench_get ;;
    list)   bench_list ;;
    update) bench_update ;;
    search) bench_search ;;
    order)  bench_create_order ;;
    worker) bench_worker ;;
    all)    seed; bench_get; bench_list; bench_update; bench_search; bench_create_order ;;
    *)      echo "Usage: $0 {seed|get|list|update|search|order|worker|all}"; exit 1 ;;
esac
