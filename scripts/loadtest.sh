#!/bin/sh
# Sidecar throughput benchmark — safe, repeatable, no orphans.
#
# Usage:
#   sh scripts/loadtest.sh              # native only
#   sh scripts/loadtest.sh sidecar      # native + sidecar
#
# Enforces:
#   - Zero orphaned processes before AND after each run
#   - Process group cleanup (kills entire npx→node→tsx tree)
#   - Clean socket/WAL/SHM state between runs
#   - Module resolution for sidecar handler imports

set -e

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

REQUESTS=200000
CONNECTIONS=128

die() { echo "ERROR: $1" >&2; cleanup; exit 1; }

check_orphans() {
    local count=$(ps aux | grep -E "tiger-web start|call_runtime_shm|node.*preflight" | grep -v grep | wc -l)
    if [ "$count" -gt 0 ]; then
        echo "WARNING: $count orphaned processes — killing"
        ps aux | grep -E "tiger-web start|call_runtime_shm|node.*preflight" | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null
        sleep 2
        count=$(ps aux | grep -E "tiger-web start|call_runtime_shm|node.*preflight" | grep -v grep | wc -l)
        if [ "$count" -gt 0 ]; then
            echo "ERROR: Could not kill $count orphans"
            return 1
        fi
    fi
    return 0
}

setup_module_shim() {
    # The ecommerce handlers import from "tiger-web" — create a
    # node_modules shim that resolves to the generated types.
    mkdir -p "$PROJ/node_modules/tiger-web"
    cp "$PROJ/generated/types.generated.ts" "$PROJ/node_modules/tiger-web/index.ts"
    echo '{"name":"tiger-web","main":"index.ts"}' > "$PROJ/node_modules/tiger-web/package.json"

    # Regenerate handlers.generated.ts with OperationValues
    npx tsx adapters/typescript.ts generated/manifest.json generated/handlers.generated.ts generated/operations.json > /dev/null 2>&1
}

cleanup_module_shim() {
    rm -f "$PROJ/node_modules/tiger-web/index.ts" "$PROJ/node_modules/tiger-web/package.json"
    rmdir "$PROJ/node_modules/tiger-web" 2>/dev/null || true
}

cleanup() {
    [ -n "$SRV_PID" ] && kill -9 "$SRV_PID" 2>/dev/null || true
    [ -n "$SC_PID" ] && kill -9 "$SC_PID" 2>/dev/null || true
    # Kill entire process group trees (npx spawns node which spawns tsx)
    [ -n "$SC_PID" ] && pkill -9 -P "$SC_PID" 2>/dev/null || true
    sleep 1
    check_orphans
    rm -f /tmp/bench-sock /tmp/bench-port.txt /dev/shm/tiger-* tiger_web.wal /tmp/tiger_web_admin_*.sock
    cleanup_module_shim
    SRV_PID="" SC_PID=""
}

run_bench() {
    local label="$1"
    local bin="$2"
    local use_sidecar="$3"

    check_orphans
    rm -f /tmp/bench-sock /tmp/bench-port.txt /dev/shm/tiger-* tiger_web.wal /tmp/tiger_web_admin_*.sock

    # Start server
    if [ "$use_sidecar" = "1" ]; then
        "$bin" start --port=0 --db=:memory: --sidecar=/tmp/bench-sock > /tmp/bench-port.txt 2>/dev/null &
    else
        "$bin" start --port=0 --db=:memory: > /tmp/bench-port.txt 2>/dev/null &
    fi
    SRV_PID=$!
    sleep 3
    PORT=$(cat /tmp/bench-port.txt)
    [ -z "$PORT" ] && die "Server failed to start"

    # Start sidecar (SHM transport)
    if [ "$use_sidecar" = "1" ]; then
        SHM="tiger-$SRV_PID"
        npx tsx adapters/call_runtime_shm.ts "$SHM" "/tmp/bench-sock" > /dev/null 2>&1 &
        SC_PID=$!
        sleep 5

        # Verify sidecar connected
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/")
        [ "$STATUS" != "200" ] && die "Sidecar not ready (HTTP $STATUS)"
    fi

    echo ""
    echo "=== $label ==="
    echo "    port=$PORT connections=$CONNECTIONS requests=$REQUESTS"
    echo ""

    # Run 1 (cold — includes seeding)
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

# Build
echo "Building..."
./zig/zig build -Doptimize=ReleaseSafe > /dev/null 2>&1
./zig/zig build load -Doptimize=ReleaseSafe > /dev/null 2>&1
echo "  native binary: OK"

run_bench "Native Zig (no sidecar)" ./zig-out/bin/tiger-web 0

if [ "$1" = "sidecar" ]; then
    echo ""
    echo "Building sidecar binary..."
    ./zig/zig build -Dsidecar=true -Dpipeline-slots=4 -Doptimize=ReleaseSafe > /dev/null 2>&1
    echo "  sidecar binary: OK (4 pipeline slots)"

    # Rebuild native addon from source (prevents stale binary bugs)
    cd addons/shm
    ../../zig/zig cc -shared -o shm.node shm.c -I/usr/include/node -lrt -lz -fPIC 2>/dev/null
    cd "$PROJ"
    echo "  native addon: rebuilt from source"

    setup_module_shim
    echo "  module shim: OK"
    echo ""

    run_bench "SHM Sidecar (4 slots)" ./zig-out/bin/tiger-web 1
fi

echo ""
echo "Done. Zero orphans verified."
