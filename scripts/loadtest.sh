#!/bin/sh
# Throughput benchmark — safe, repeatable, no orphans.
#
# Usage:
#   sh scripts/loadtest.sh              # native only
#   sh scripts/loadtest.sh sidecar      # native + Zig sidecar + TS sidecar
#
# Primary benchmark: native Zig → Zig sidecar (deterministic, no GC/JIT variance).
# TS sidecar is informational — tracks Node.js overhead separately.
#
# If Zig sidecar number drops → framework regression.
# If TS drops but Zig stable → Node.js/sidecar issue.

set -e

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

REQUESTS=200000
CONNECTIONS=128

die() { echo "ERROR: $1" >&2; cleanup; exit 1; }

check_orphans() {
    local count=$(ps aux | grep -E "tiger-web start|zig-sidecar|call_runtime_shm|node.*preflight" | grep -v grep | wc -l)
    if [ "$count" -gt 0 ]; then
        echo "WARNING: $count orphaned processes — killing"
        ps aux | grep -E "tiger-web start|zig-sidecar|call_runtime_shm|node.*preflight" | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null
        sleep 2
        count=$(ps aux | grep -E "tiger-web start|zig-sidecar|call_runtime_shm|node.*preflight" | grep -v grep | wc -l)
        if [ "$count" -gt 0 ]; then
            echo "ERROR: Could not kill $count orphans"
            return 1
        fi
    fi
    return 0
}

setup_ts_shim() {
    mkdir -p "$PROJ/node_modules/tiger-web"
    cp "$PROJ/generated/types.generated.ts" "$PROJ/node_modules/tiger-web/index.ts"
    echo '{"name":"tiger-web","main":"index.ts"}' > "$PROJ/node_modules/tiger-web/package.json"
    npx tsx adapters/typescript.ts generated/manifest.json generated/handlers.generated.ts generated/operations.json > /dev/null 2>&1
}

cleanup_ts_shim() {
    rm -f "$PROJ/node_modules/tiger-web/index.ts" "$PROJ/node_modules/tiger-web/package.json"
    rmdir "$PROJ/node_modules/tiger-web" 2>/dev/null || true
}

cleanup() {
    [ -n "$SRV_PID" ] && kill -9 "$SRV_PID" 2>/dev/null || true
    [ -n "$SC_PID" ] && kill -9 "$SC_PID" 2>/dev/null || true
    [ -n "$SC_PID" ] && pkill -9 -P "$SC_PID" 2>/dev/null || true
    sleep 1
    check_orphans
    rm -f /tmp/bench-sock /tmp/bench-port.txt /dev/shm/tiger-* tiger_web.wal /tmp/tiger_web_admin_*.sock
    cleanup_ts_shim
    SRV_PID="" SC_PID=""
}

run_bench() {
    local label="$1"
    local bin="$2"
    local sidecar_type="$3"  # "none", "zig", "ts"

    check_orphans
    rm -f /tmp/bench-sock /tmp/bench-port.txt /dev/shm/tiger-* tiger_web.wal /tmp/tiger_web_admin_*.sock

    # Start server
    if [ "$sidecar_type" != "none" ]; then
        "$bin" start --port=0 --db=:memory: --sidecar=/tmp/bench-sock > /tmp/bench-port.txt 2>/dev/null &
    else
        "$bin" start --port=0 --db=:memory: > /tmp/bench-port.txt 2>/dev/null &
    fi
    SRV_PID=$!
    sleep 3
    PORT=$(cat /tmp/bench-port.txt)
    [ -z "$PORT" ] && die "Server failed to start"
    SHM="tiger-$SRV_PID"

    # Start sidecar
    if [ "$sidecar_type" = "zig" ]; then
        ./zig-out/bin/zig-sidecar "$SHM" "/tmp/bench-sock" &
        SC_PID=$!
        sleep 3
    elif [ "$sidecar_type" = "ts" ]; then
        npx tsx adapters/call_runtime_shm.ts "$SHM" "/tmp/bench-sock" > /dev/null 2>&1 &
        SC_PID=$!
        sleep 5
    fi

    if [ "$sidecar_type" != "none" ]; then
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/")
        [ "$STATUS" != "200" ] && die "Sidecar not ready (HTTP $STATUS)"
    fi

    echo ""
    echo "=== $label ==="
    echo "    port=$PORT connections=$CONNECTIONS requests=$REQUESTS"
    echo ""

    # Run 1 (cold)
    echo "  Run 1 (cold):"
    ./zig-out/bin/tiger-load --port="$PORT" --connections="$CONNECTIONS" --requests="$REQUESTS" 2>&1 \
        | grep -E "throughput|latency p50|latency p99" | sed 's/^/    /'

    # Run 2 (warm)
    echo "  Run 2 (warm):"
    ./zig-out/bin/tiger-load --port="$PORT" --connections="$CONNECTIONS" --requests="$REQUESTS" 2>&1 \
        | grep -E "throughput|latency p50|latency p99" | sed 's/^/    /'

    # Run 3 (warm)
    echo "  Run 3 (warm):"
    ./zig-out/bin/tiger-load --port="$PORT" --connections="$CONNECTIONS" --requests="$REQUESTS" 2>&1 \
        | grep -E "throughput|latency p50|latency p99" | sed 's/^/    /'

    cleanup
}

# --- Main ---

trap cleanup EXIT

echo "Tiger Web Benchmark"
echo "==================="
echo "Requests per run: $REQUESTS"
echo "Connections: $CONNECTIONS"
echo ""

check_orphans

# Build everything
echo "Building..."
./zig/zig build -Doptimize=ReleaseSafe > /dev/null 2>&1
./zig/zig build load -Doptimize=ReleaseSafe > /dev/null 2>&1
echo "  native binary + load tester: OK"

# Native (baseline)
run_bench "Native Zig (no sidecar)" ./zig-out/bin/tiger-web none

if [ "$1" = "sidecar" ]; then
    # Build sidecar binary
    echo ""
    echo "Building sidecar binary..."
    ./zig/zig build -Dsidecar=true -Dpipeline-slots=4 -Doptimize=ReleaseSafe > /dev/null 2>&1
    echo "  sidecar binary: OK (4 pipeline slots)"
    echo "  zig-sidecar binary: OK"

    # Zig sidecar (primary sidecar benchmark — deterministic)
    run_bench "Zig Sidecar (SHM, 4 slots)" ./zig-out/bin/tiger-web zig

    # TS sidecar (informational — tracks Node.js overhead)
    echo ""
    echo "Preparing TS sidecar..."
    cd addons/shm
    ../../zig/zig cc -shared -o shm.node shm.c -I/usr/include/node -lrt -lz -fPIC 2>/dev/null
    cd "$PROJ"
    echo "  native addon: rebuilt from source"
    setup_ts_shim
    echo "  module shim: OK"

    run_bench "TS Sidecar (SHM, Node.js)" ./zig-out/bin/tiger-web ts
fi

echo ""
echo "Done. Zero orphans verified."
