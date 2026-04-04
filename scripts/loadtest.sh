#!/bin/sh
# Sidecar throughput benchmark — safe, repeatable, no orphans.
#
# Usage:
#   sh scripts/bench.sh              # native only
#   sh scripts/bench.sh sidecar      # native + 1 sidecar + 2 sidecars
#
# Enforces:
#   - Zero orphaned processes before and after each run
#   - 200K requests per concurrency level (avoids keep-alive artifact)
#   - Process group cleanup (kills entire npx→node→tsx tree)
#   - Clean socket/WAL state between runs

set -e

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

REQUESTS=200000
CONCURRENCIES="1 32 64 128"
SEED_COUNT=10

die() { echo "ERROR: $1" >&2; exit 1; }

check_orphans() {
    local count=$(ps aux | grep -E "tiger-web|call_runtime" | grep -v grep | wc -l)
    if [ "$count" -gt 0 ]; then
        echo "WARNING: $count orphaned processes — killing"
        ps aux | grep -E "tiger-web|call_runtime" | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null
        sleep 2
        count=$(ps aux | grep -E "tiger-web|call_runtime" | grep -v grep | wc -l)
        [ "$count" -gt 0 ] && die "Could not kill orphans"
    fi
}

cleanup() {
    [ -n "$SRV_PID" ] && kill -9 "$SRV_PID" 2>/dev/null
    [ -n "$SC1_PID" ] && kill -9 "$SC1_PID" 2>/dev/null
    [ -n "$SC2_PID" ] && kill -9 "$SC2_PID" 2>/dev/null
    sleep 1
    check_orphans
    rm -f /tmp/tiger_web_sidecar.sock /tmp/tiger_web.wal /tmp/tiger_web_admin_*.sock /tmp/bench_port.txt
    SRV_PID="" SC1_PID="" SC2_PID=""
}

run_bench() {
    local label="$1"
    local bin="$2"
    local sidecar_count="$3"

    check_orphans
    rm -f /tmp/tiger_web_sidecar.sock /tmp/tiger_web.wal /tmp/tiger_web_admin_*.sock

    if [ "$sidecar_count" -gt 0 ]; then
        "$bin" start --port=0 --db=:memory: --sidecar=/tmp/tiger_web_sidecar.sock > /tmp/bench_port.txt 2>/dev/null &
    else
        "$bin" start --port=0 --db=:memory: > /tmp/bench_port.txt 2>/dev/null &
    fi
    SRV_PID=$!
    sleep 2
    PORT=$(cat /tmp/bench_port.txt)
    [ -z "$PORT" ] && die "Server failed to start"

    if [ "$sidecar_count" -gt 0 ]; then
        cd "$PROJ/examples/ecommerce-ts"
        npx tsx ../../adapters/call_runtime.ts /tmp/tiger_web_sidecar.sock > /dev/null 2>/dev/null &
        SC1_PID=$!
        sleep 4
        if [ "$sidecar_count" -gt 1 ]; then
            npx tsx ../../adapters/call_runtime.ts /tmp/tiger_web_sidecar.sock > /dev/null 2>/dev/null &
            SC2_PID=$!
            sleep 4
        fi
        cd "$PROJ"
    fi

    # Seed
    for i in $(seq 1 $SEED_COUNT); do
        curl -s -X POST "http://localhost:$PORT/products" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"Widget $i\",\"price_cents\":$((i*100))}" > /dev/null
    done

    # Warmup
    hey -n 10000 -c 32 "http://localhost:$PORT/products" > /dev/null 2>&1

    echo ""
    echo "=== $label ==="
    for c in $CONCURRENCIES; do
        result=$(hey -n "$REQUESTS" -c "$c" "http://localhost:$PORT/products" 2>&1 | grep "Requests/sec" | awk '{print $2}')
        printf "  c=%-3d  %s req/s\n" "$c" "$result"
    done

    cleanup
}

# --- Main ---

trap cleanup EXIT

echo "Tiger Web Benchmark"
echo "==================="
echo "Requests per run: $REQUESTS"
echo "Concurrency levels: $CONCURRENCIES"

check_orphans

# Build
echo ""
echo "Building..."
./zig/zig build -Doptimize=ReleaseSafe 2>&1 | tail -1
cp zig-out/bin/tiger-web /tmp/tiger-web-native

run_bench "Native Zig" /tmp/tiger-web-native 0

if [ "$1" = "sidecar" ]; then
    ./zig/zig build -Dsidecar=true -Doptimize=ReleaseSafe 2>&1 | tail -1
    cp zig-out/bin/tiger-web /tmp/tiger-web-sc1
    run_bench "1 Sidecar" /tmp/tiger-web-sc1 1

    ./zig/zig build -Dsidecar=true -Dsidecar-count=2 -Doptimize=ReleaseSafe 2>&1 | tail -1
    cp zig-out/bin/tiger-web /tmp/tiger-web-sc2
    run_bench "2 Sidecars" /tmp/tiger-web-sc2 2
fi

echo ""
echo "Done. Zero orphans verified."
