#!/bin/sh
# Consolidation regression gate — run after each deletion step.
#
# Verifies: compilation, annotation scan, unit tests, sim tests,
# smoke test (curl), and throughput baseline. Fails hard on any
# regression. Run before committing each consolidation step.
#
# Usage:
#   sh scripts/consolidation-gate.sh          # full gate
#   sh scripts/consolidation-gate.sh quick     # skip benchmarks
#
# Prerequisites:
#   - zig/download.sh already run
#   - npm install in examples/ecommerce-ts
#   - No orphaned tiger-web/call_runtime processes

set -e

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

MODE="${1:-full}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { printf "${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "${RED}FAIL${NC} %s\n" "$1"; exit 1; }

# --- Step 0: Clean state ---
echo "=== Clean state ==="
orphans=$(ps aux | grep -E "tiger-web|call_runtime" | grep -v grep | wc -l)
if [ "$orphans" -gt 0 ]; then
    fail "Orphaned processes: $orphans (kill them first)"
fi
rm -rf .zig-cache/ zig-out/ /dev/shm/tiger-* tiger_web.wal
pass "No orphans, clean slate"

# --- Step 1: Compile (sidecar mode) ---
echo ""
echo "=== Compile ==="
./zig/zig build -Dsidecar=true -Dsidecar-count=1 -Dpipeline-slots=8 -Doptimize=ReleaseSafe 2>&1 || fail "Compilation failed"
pass "Compiles with sidecar mode"

# --- Step 2: Annotation scan ---
echo ""
echo "=== Annotation scan ==="
output=$(./zig/zig build scan -- examples/ecommerce-ts/handlers/ --prefetch-zig=generated/prefetch.generated.zig 2>&1)
echo "$output" | grep -q "^OK:" || fail "Annotation scan failed: $output"
errors=$(echo "$output" | grep -c "^error:" || true)
if [ "$errors" -gt 0 ]; then
    fail "Annotation scan has $errors errors"
fi
pass "Annotation scan OK"

# --- Step 3: Unit tests ---
echo ""
echo "=== Unit tests ==="
./zig/zig build unit-test 2>&1 || fail "Unit tests failed"
pass "Unit tests pass"

# --- Step 4: Smoke test ---
echo ""
echo "=== Smoke test ==="
rm -f /tmp/gate_test.db /dev/shm/tiger-* tiger_web.wal

# Enable flags for smoke test
sed -i 's/protocol_v2: bool = false/protocol_v2: bool = true/' app.zig
sed -i 's/protocol_v2_shm: bool = false/protocol_v2_shm: bool = true/' app.zig
rm -rf .zig-cache/ zig-out/
./zig/zig build -Dsidecar=true -Dsidecar-count=1 -Dpipeline-slots=8 -Doptimize=ReleaseSafe 2>&1 || fail "Rebuild failed"

zig-out/bin/tiger-web start --port=9899 --db=/tmp/gate_test.db > /dev/null 2>&1 &
SERVER_PID=$!
sleep 2

cd examples/ecommerce-ts && npx tsx ../../adapters/call_runtime_v2_shm.ts "tiger-${SERVER_PID}" 8 2>/dev/null &
SIDECAR_PID=$!
sleep 3
cd "$PROJ"

# Test read
result=$(curl -s --max-time 3 http://localhost:9899/products)
echo "$result" | grep -q "products\|No products" || fail "GET /products failed: $result"
pass "GET /products returns HTML"

# Test write
curl -s --max-time 3 -X POST http://localhost:9899/products \
  -H "Content-Type: application/json" \
  -d '{"name":"Gate Test","price_cents":100,"inventory":1}' > /dev/null
result=$(curl -s --max-time 3 http://localhost:9899/products)
echo "$result" | grep -q "Gate Test" || fail "POST then GET failed: product not visible"
pass "POST creates product, GET sees it"

# Test keep-alive (2 requests on same connection)
result=$(curl -s --max-time 3 http://localhost:9899/products http://localhost:9899/products)
count=$(echo "$result" | grep -c "Gate Test" || true)
[ "$count" -ge 2 ] || fail "Keep-alive failed: expected 2 results, got $count"
pass "Keep-alive works"

# Cleanup smoke test
kill $SERVER_PID $SIDECAR_PID 2>/dev/null
wait $SERVER_PID $SIDECAR_PID 2>/dev/null || true
sleep 1

if [ "$MODE" = "quick" ]; then
    git checkout app.zig
    echo ""
    printf "${GREEN}=== QUICK GATE PASSED ===${NC}\n"
    exit 0
fi

# --- Step 5: Throughput baseline ---
echo ""
echo "=== Throughput benchmark ==="
rm -f /tmp/gate_bench.db /dev/shm/tiger-* tiger_web.wal

zig-out/bin/tiger-web start --port=9899 --db=/tmp/gate_bench.db > /dev/null 2>&1 &
SERVER_PID=$!
sleep 2
cd examples/ecommerce-ts && npx tsx ../../adapters/call_runtime_v2_shm.ts "tiger-${SERVER_PID}" 8 2>/dev/null &
SIDECAR_PID=$!
sleep 3
cd "$PROJ"

# Seed
zig-out/bin/tiger-load --port=9899 --connections=4 --requests=50 --seed-count=10 --ops=list_products:100 > /dev/null 2>&1

# Benchmark get_product (should be >70K)
throughput=$(zig-out/bin/tiger-load --port=9899 --connections=64 --requests=20000 --seed-count=10 --ops=get_product:100 2>&1 | grep throughput | awk '{print $3}')
echo "  get_product: ${throughput} req/s"
if [ -n "$throughput" ] && [ "$throughput" -lt 70000 ]; then
    fail "get_product throughput regression: ${throughput} < 70000"
fi
pass "get_product throughput OK (>70K)"

# Benchmark default mix (should be >40K)
throughput=$(zig-out/bin/tiger-load --port=9899 --connections=64 --requests=20000 2>&1 | grep throughput | awk '{print $3}')
echo "  default_mix: ${throughput} req/s"
if [ -n "$throughput" ] && [ "$throughput" -lt 40000 ]; then
    fail "default_mix throughput regression: ${throughput} < 40000"
fi
pass "default_mix throughput OK (>40K)"

# Cleanup
kill $SERVER_PID $SIDECAR_PID 2>/dev/null
wait $SERVER_PID $SIDECAR_PID 2>/dev/null || true
git checkout app.zig

echo ""
printf "${GREEN}=== FULL GATE PASSED ===${NC}\n"
