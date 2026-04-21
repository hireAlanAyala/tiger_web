#!/bin/sh
# SHM protocol integration test — verifies server + native addon + sidecar.
#
# Catches: stale addon binary, slot_state drift, CRC convention mismatch,
# seq ordering bugs. This is the test that would have caught the 503 bug
# where the prebuilt shm.node didn't write slot_state=2.
#
# Requires: tiger-web binary built with -Dsidecar=true, node_modules/tiger-web shim.
#
# Exit 0 = pass, exit 1 = fail.

set -e
cd "$(dirname "$0")/.."

# Setup
rm -f /tmp/ci-shm-sock /dev/shm/tiger-ci-*
mkdir -p node_modules/tiger-web 2>/dev/null
cp generated/types.generated.ts node_modules/tiger-web/index.ts
echo '{"name":"tiger-web","main":"index.ts"}' > node_modules/tiger-web/package.json

# Ensure handlers.generated.ts has OperationValues
npx tsx adapters/typescript.ts generated/manifest.json generated/handlers.generated.ts generated/operations.json > /dev/null 2>&1

# Start server (sidecar mode, in-memory)
./zig-out/bin/tiger-web start --port=0 --db=:memory: --sidecar=/tmp/ci-shm-sock > /tmp/ci-shm-port.txt 2>/dev/null &
SRV_PID=$!
sleep 3
PORT=$(cat /tmp/ci-shm-port.txt)
SHM="tiger-$SRV_PID"

if [ -z "$PORT" ]; then
    echo "FAIL: server did not start"
    kill $SRV_PID 2>/dev/null
    exit 1
fi

# Start sidecar (uses rebuilt addon from addons/shm/)
npx tsx adapters/call_runtime_shm.ts "$SHM" "/tmp/ci-shm-sock" > /dev/null 2>&1 &
SC_PID=$!
sleep 5

# Send one HTTP request — must get 200
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/")

# Cleanup
kill $SRV_PID 2>/dev/null
kill $SC_PID 2>/dev/null
rm -f /tmp/ci-shm-sock /tmp/ci-shm-port.txt
rm -f node_modules/tiger-web/index.ts node_modules/tiger-web/package.json
rmdir node_modules/tiger-web 2>/dev/null

# Assert
if [ "$STATUS" = "200" ]; then
    echo "PASS: SHM protocol smoke test (HTTP $STATUS)"
    exit 0
else
    echo "FAIL: expected HTTP 200, got $STATUS"
    echo "  Likely cause: stale addons/shm/shm.node — rebuild with:"
    echo "  cd addons/shm && ../../zig/zig cc -shared -o shm.node shm.c -I/usr/include/node -lrt -lz -fPIC"
    exit 1
fi
