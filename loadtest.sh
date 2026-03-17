#!/usr/bin/env bash
#
# Load test the tiger-web server using hey.
#
# Prerequisites:
#   - hey: go install github.com/rakyll/hey@latest
#   - source dev.env (sets SECRET_KEY)
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
#   ./loadtest.sh wal              # mutation burst + WAL disk usage report
#
# Environment:
#   HOST           — server URL (default: http://localhost:3000)
#   SEED_COUNT     — products to seed (default: 50)
#   WORKER_ORDERS  — orders for worker bench (default: 100)
#   WAL_MUTATIONS  — mutations for WAL test (default: 1000)

set -euo pipefail

HOST="${HOST:-http://localhost:3000}"
CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1 8 16 32 64 128}"
SEED_COUNT="${SEED_COUNT:-50}"

# Verify server is reachable before running anything.
if ! curl -sf "$HOST/products" > /dev/null 2>&1; then
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
        result=$(hey -n $((c * 1000)) -c "$c" \
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
        result=$(hey -n $((c * 1000)) -c "$c" \
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
        result=$(hey -n $((c * 1000)) -c "$c" \
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
        -d "{\"id\":\"$PRODUCT_ID\",\"name\":\"Bench Product\",\"price\":999,\"stock\":100000}" \
        > /dev/null

    # Create pending orders.
    echo "Creating $ORDER_COUNT pending orders..."
    for i in $(seq 1 "$ORDER_COUNT"); do
        local ORDER_ID
        ORDER_ID=$(printf '%032x' $((200000 + i)))
        curl -s -X POST "$HOST/orders" \
            -H "Content-Type: application/json" \
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
    ./zig-out/bin/tiger-worker --delay-ms=0 --poll-ms=100 2>/dev/null &
    WORKER_PID=$!

    # Poll until no pending orders remain.
    while true; do
        sleep 0.5
        local RESPONSE PENDING
        RESPONSE=$(curl -s "$HOST/orders")
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

bench_wal() {
    local MUTATIONS PRODUCT_ID WAL_FILE
    MUTATIONS="${WAL_MUTATIONS:-1000}"
    PRODUCT_ID=$(printf '%032x' 1001)
    WAL_FILE="tiger_web.wal"

    echo ""
    echo "=== WAL disk usage: $MUTATIONS mutations ==="
    echo ""

    # Record WAL size before.
    local SIZE_BEFORE=0
    if [ -f "$WAL_FILE" ]; then
        SIZE_BEFORE=$(stat -c%s "$WAL_FILE")
    fi

    # Ensure a product exists for updates/orders.
    curl -s -X POST "$HOST/products" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"$PRODUCT_ID\",\"name\":\"WAL Bench Product\",\"price\":999,\"stock\":1000000}" \
        > /dev/null

    echo "Running $MUTATIONS mutations (creates + updates + orders)..."
    local START i
    START=$(date +%s%N)

    for i in $(seq 1 "$MUTATIONS"); do
        local MOD=$((i % 3))
        if [ "$MOD" -eq 0 ]; then
            # Create product
            local ID
            ID=$(printf '%032x' $((500000 + i)))
            curl -s -X POST "$HOST/products" \
                -H "Content-Type: application/json" \
                -d "{\"id\":\"$ID\",\"name\":\"WAL Product $i\",\"description\":\"Load test\",\"price\":$((i % 9999)),\"stock\":$((i % 100))}" \
                > /dev/null
        elif [ "$MOD" -eq 1 ]; then
            # Update product
            curl -s -X PUT "$HOST/products/$PRODUCT_ID" \
                -H "Content-Type: application/json" \
                -d "{\"name\":\"Updated $i\",\"price_cents\":$((i % 9999)),\"version\":0}" \
                > /dev/null
        else
            # Create order
            local ORDER_ID
            ORDER_ID=$(printf '%032x' $((600000 + i)))
            curl -s -X POST "$HOST/orders" \
                -H "Content-Type: application/json" \
                -d "{\"id\":\"$ORDER_ID\",\"items\":[{\"product_id\":\"$PRODUCT_ID\",\"quantity\":1}]}" \
                > /dev/null
        fi

        # Progress every 100 mutations.
        if [ $((i % 100)) -eq 0 ]; then
            printf "  %d/%d\r" "$i" "$MUTATIONS"
        fi
    done

    local END ELAPSED_MS
    END=$(date +%s%N)
    ELAPSED_MS=$(( (END - START) / 1000000 ))

    # Read WAL size after.
    local SIZE_AFTER=0
    if [ -f "$WAL_FILE" ]; then
        SIZE_AFTER=$(stat -c%s "$WAL_FILE")
    else
        echo "warning: WAL file not found at $WAL_FILE"
        return
    fi

    local GROWTH=$((SIZE_AFTER - SIZE_BEFORE))
    local ENTRIES=$((GROWTH / 784))
    local RATE
    if [ "$ELAPSED_MS" -gt 0 ]; then
        RATE=$(awk "BEGIN { printf \"%.1f\", $MUTATIONS * 1000 / $ELAPSED_MS }")
    else
        RATE="inf"
    fi

    # Projections: based on mutation rate, how fast does disk fill?
    local MB_PER_HOUR MB_PER_DAY MB_PER_WEEK
    if [ "$ELAPSED_MS" -gt 0 ]; then
        MB_PER_HOUR=$(awk "BEGIN { printf \"%.1f\", $ENTRIES / ($ELAPSED_MS / 1000.0) * 3600 * 784 / 1048576 }")
        MB_PER_DAY=$(awk "BEGIN { printf \"%.1f\", $ENTRIES / ($ELAPSED_MS / 1000.0) * 86400 * 784 / 1048576 }")
        MB_PER_WEEK=$(awk "BEGIN { printf \"%.1f\", $ENTRIES / ($ELAPSED_MS / 1000.0) * 604800 * 784 / 1048576 }")
    else
        MB_PER_HOUR="n/a"
        MB_PER_DAY="n/a"
        MB_PER_WEEK="n/a"
    fi

    echo ""
    echo "  mutations:    $MUTATIONS"
    echo "  WAL entries:  $ENTRIES (growth: $GROWTH bytes)"
    echo "  WAL size:     $(awk "BEGIN { printf \"%.2f\", $SIZE_AFTER / 1048576 }") MB total"
    echo "  entry size:   784 bytes"
    echo "  time:         ${ELAPSED_MS}ms"
    echo "  throughput:   ${RATE} mutations/sec"
    echo ""
    echo "  --- Projections (at sustained load) ---"
    echo "  1 hour:       ${MB_PER_HOUR} MB"
    echo "  1 day:        ${MB_PER_DAY} MB"
    echo "  1 week:       ${MB_PER_WEEK} MB"
    echo ""
    echo "  --- At realistic traffic (estimate 1 mutation/sec) ---"
    echo "  1 hour:       $(awk "BEGIN { printf \"%.2f\", 3600 * 784 / 1048576 }") MB"
    echo "  1 day:        $(awk "BEGIN { printf \"%.2f\", 86400 * 784 / 1048576 }") MB"
    echo "  1 week:       $(awk "BEGIN { printf \"%.2f\", 604800 * 784 / 1048576 }") MB"
    echo "  1 month:      $(awk "BEGIN { printf \"%.2f\", 2592000 * 784 / 1048576 }") MB"
    echo "  1 year:       $(awk "BEGIN { printf \"%.2f\", 31536000 * 784 / 1048576 }") MB"
}

case "${1:-all}" in
    seed)   seed ;;
    get)    bench_get ;;
    list)   bench_list ;;
    update) bench_update ;;
    search) bench_search ;;
    order)  bench_create_order ;;
    worker) bench_worker ;;
    wal)    bench_wal ;;
    all)    seed; bench_get; bench_list; bench_update; bench_search; bench_create_order ;;
    *)      echo "Usage: $0 {seed|get|list|update|search|order|worker|wal|all}"; exit 1 ;;
esac
