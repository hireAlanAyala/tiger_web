#!/bin/sh
# Smoke test: focus new → build → dev → CRUD.
#
# Catches bugs that only appear in new projects (not the ecommerce example):
# - OperationValues missing new operations
# - Schema not initialized
# - Ecommerce route table shadowing user routes
#
# Requires: Docker (podman or docker), focus image built.
# Usage: sh scripts/test_new_project.sh

set -e

FRAMEWORK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="focus:0.1.0"
PORT=3334
PROJECT="/tmp/focus-smoke-$$"
CONTAINER="focus-smoke-$$"
PASS=0
FAIL=0

cleanup() {
  podman stop "$CONTAINER" 2>/dev/null || docker stop "$CONTAINER" 2>/dev/null || true
  rm -rf "$PROJECT"
}
trap cleanup EXIT INT TERM

run() {
  if command -v podman >/dev/null 2>&1; then
    podman "$@"
  else
    docker "$@"
  fi
}

assert_contains() {
  local label="$1" body="$2" expected="$3"
  if echo "$body" | grep -qF "$expected"; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected to contain: $expected"
    echo "    got: $(echo "$body" | head -3)"
  fi
}

assert_status() {
  local label="$1" status="$2" expected="$3"
  if [ "$status" = "$expected" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — expected $expected, got $status"
  fi
}

# --- Check image exists ---
if ! run image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "error: $IMAGE not found. Run: podman build -t $IMAGE ." >&2
  exit 1
fi

echo "=== Focus new project smoke test ==="
echo ""

# --- Step 1: Scaffold ---
echo "1. Scaffolding project..."
"$FRAMEWORK_ROOT/focus" new "$PROJECT"
test -f "$PROJECT/handlers/list_items.ts" || { echo "FAIL: scaffold missing list_items.ts"; exit 1; }
test -f "$PROJECT/handlers/create_item.ts" || { echo "FAIL: scaffold missing create_item.ts"; exit 1; }
test -f "$PROJECT/schema.sql" || { echo "FAIL: scaffold missing schema.sql"; exit 1; }
test -f "$PROJECT/package.json" || { echo "FAIL: scaffold missing package.json"; exit 1; }
test -f "$PROJECT/tsconfig.json" || { echo "FAIL: scaffold missing tsconfig.json"; exit 1; }
test -f "$PROJECT/.gitignore" || { echo "FAIL: scaffold missing .gitignore"; exit 1; }
echo "  PASS: scaffold complete (6 files)"
PASS=$((PASS + 1))

# --- Step 2: Start server ---
echo ""
echo "2. Starting server in Docker..."
run run --rm -d --name "$CONTAINER" -p "$PORT:3000" \
  --security-opt seccomp=unconfined \
  -v "$PROJECT:/app:Z" -w /app \
  "$IMAGE" \
  sh -c "npm install --silent 2>/dev/null && focus-internal dev" >/dev/null 2>&1

# Wait for server to be ready (up to 30s).
READY=0
for i in $(seq 1 30); do
  if curl -s -4 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/" 2>/dev/null | grep -q "200"; then
    READY=1
    break
  fi
  sleep 1
done
if [ "$READY" = "0" ]; then
  echo "  FAIL: server did not start within 30s"
  echo "  Logs:"
  run logs "$CONTAINER" 2>&1 | tail -20
  exit 1
fi
echo "  PASS: server started"
PASS=$((PASS + 1))

# --- Step 3: GET / (empty) ---
echo ""
echo "3. GET / (empty database)..."
BODY=$(curl -s -4 "http://127.0.0.1:$PORT/")
STATUS=$(curl -s -4 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/")
assert_status "HTTP 200" "$STATUS" "200"
assert_contains "empty list message" "$BODY" "No items yet"

# --- Step 4: POST / (create) ---
echo ""
echo "4. POST / (create item)..."
BODY=$(curl -s -4 -X POST -d '{"id":"aabbccdd11223344aabbccdd11223300","name":"Smoke Test Item"}' "http://127.0.0.1:$PORT/")
STATUS=$(curl -s -4 -o /dev/null -w "%{http_code}" -X POST -d '{"id":"bbccddee22334455bbccddee22334400","name":"Second Item"}' "http://127.0.0.1:$PORT/")
assert_status "HTTP 200" "$STATUS" "200"
assert_contains "created response" "$BODY" "Created"

# --- Step 5: GET / (has items) ---
echo ""
echo "5. GET / (items in database)..."
BODY=$(curl -s -4 "http://127.0.0.1:$PORT/")
assert_contains "first item in list" "$BODY" "Smoke Test Item"
assert_contains "second item in list" "$BODY" "Second Item"
assert_contains "HTML list structure" "$BODY" "<ul>"

# --- Step 6: Verify schema persists ---
echo ""
echo "6. Database state..."
ROWS=$(run exec "$CONTAINER" sqlite3 /app/tiger_web.db "SELECT COUNT(*) FROM items" 2>/dev/null)
if [ "$ROWS" = "2" ]; then
  PASS=$((PASS + 1))
  echo "  PASS: 2 rows in items table"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: expected 2 rows, got $ROWS"
fi

# --- Results ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Logs from container:"
  run logs "$CONTAINER" 2>&1 | tail -15
  exit 1
fi
