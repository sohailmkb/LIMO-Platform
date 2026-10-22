#!/usr/bin/env bash
# UAT script for the partner API + webhook worker (migration 0024, functions partner-api
# and webhook-delivery-worker). Run this AFTER you've deployed both functions, run the
# migration, and set WEBHOOK_WORKER_SECRET.
#
# Fill in the four values below (or export them before running), then:
#   chmod +x scripts/uat-partner-api.sh
#   ./scripts/uat-partner-api.sh
#
# Required:
#   SUPABASE_URL          e.g. https://abcxyz.supabase.co
#   API_CREDENTIAL         key_id.secret for an API client/credential you've already issued
# Optional (skips the relevant test if unset):
#   API_CREDENTIAL_2       a SECOND credential/client, to prove cross-client isolation (404s)
#   WEBHOOK_WORKER_SECRET  the secret you set with `supabase secrets set WEBHOOK_WORKER_SECRET=...`
#
# Send me the full output if anything fails -- status codes and bodies are all that's needed.

set -uo pipefail

: "${SUPABASE_URL:?set SUPABASE_URL, e.g. https://abcxyz.supabase.co}"
: "${API_CREDENTIAL:?set API_CREDENTIAL to key_id.secret for an issued credential}"
API_CREDENTIAL_2="${API_CREDENTIAL_2:-}"
WEBHOOK_WORKER_SECRET="${WEBHOOK_WORKER_SECRET:-}"

BASE="${SUPABASE_URL%/}/functions/v1/partner-api"
AUTH="Authorization: Bearer ${API_CREDENTIAL}"
PASS=0; FAIL=0

check() {
  local label="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    echo "  OK   $label (got $got)"
    PASS=$((PASS+1))
  else
    echo "  FAIL $label (expected $expected, got $got)"
    FAIL=$((FAIL+1))
  fi
}

echo "== 1. GET /v1/vehicle-classes =="
resp=$(curl -sS -w '\n%{http_code}' -H "$AUTH" "$BASE/v1/vehicle-classes")
body=$(echo "$resp" | head -n -1); code=$(echo "$resp" | tail -n1)
echo "$body"
check "vehicle-classes status" 200 "$code"
VEHICLE_CLASS_ID=$(echo "$body" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1)
echo "  using vehicle_class_id=$VEHICLE_CLASS_ID"
echo

echo "== 2. POST /v1/quotes =="
resp=$(curl -sS -w '\n%{http_code}' -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"vehicle_class_id\":\"$VEHICLE_CLASS_ID\",\"service_type\":\"one_way\",\"distance\":20}" \
  "$BASE/v1/quotes")
body=$(echo "$resp" | head -n -1); code=$(echo "$resp" | tail -n1)
echo "$body"
check "quote status" 200 "$code"
echo

echo "== 3. POST /v1/bookings (first booking, fresh idempotency key) =="
KEY1="uat-$(date +%s)-create"
resp=$(curl -sS -w '\n%{http_code}' -H "$AUTH" -H "Content-Type: application/json" -H "Idempotency-Key: $KEY1" \
  -d "{\"passenger_name\":\"UAT Tester\",\"service_type\":\"one_way\",\"vehicle_class_id\":\"$VEHICLE_CLASS_ID\",\"pickup_at\":\"$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1d +%Y-%m-%dT%H:%M:%SZ)\",\"pickup_address\":\"UAT Pickup\",\"dropoff_address\":\"UAT Dropoff\",\"distance\":20}" \
  "$BASE/v1/bookings")
body=$(echo "$resp" | head -n -1); code=$(echo "$resp" | tail -n1)
echo "$body"
check "create booking status" 201 "$code"
BOOKING_ID=$(echo "$body" | sed -n 's/.*"booking_id":"\([^"]*\)".*/\1/p')
echo "  booking_id=$BOOKING_ID"
echo

echo "== 4. Replay same key + same body -> must return the SAME booking_id, no new row =="
resp=$(curl -sS -w '\n%{http_code}' -H "$AUTH" -H "Content-Type: application/json" -H "Idempotency-Key: $KEY1" \
  -d "{\"passenger_name\":\"UAT Tester\",\"service_type\":\"one_way\",\"vehicle_class_id\":\"$VEHICLE_CLASS_ID\",\"pickup_at\":\"$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1d +%Y-%m-%dT%H:%M:%SZ)\",\"pickup_address\":\"UAT Pickup\",\"dropoff_address\":\"UAT Dropoff\",\"distance\":20}" \
  "$BASE/v1/bookings")
body=$(echo "$resp" | head -n -1); code=$(echo "$resp" | tail -n1)
echo "$body"
REPLAY_ID=$(echo "$body" | sed -n 's/.*"booking_id":"\([^"]*\)".*/\1/p')
check "replay status" 201 "$code"
check "replay returns same booking_id" "$BOOKING_ID" "$REPLAY_ID"
echo

echo "== 5. Same key + DIFFERENT body -> must be 409 =="
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$AUTH" -H "Content-Type: application/json" -H "Idempotency-Key: $KEY1" \
  -d "{\"passenger_name\":\"A Different Name\",\"service_type\":\"one_way\",\"vehicle_class_id\":\"$VEHICLE_CLASS_ID\",\"pickup_at\":\"2027-01-01T00:00:00Z\",\"pickup_address\":\"x\",\"distance\":1}" \
  "$BASE/v1/bookings")
check "reused-key-different-body status" 409 "$code"
echo

echo "== 6. Concurrency check -- the actual bug that was fixed (fire 5 identical requests, same NEW key, in parallel) =="
KEY2="uat-$(date +%s)-concurrent"
PICKUP="$(date -u -d '+2 day' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+2d +%Y-%m-%dT%H:%M:%SZ)"
BODY="{\"passenger_name\":\"UAT Concurrent\",\"service_type\":\"one_way\",\"vehicle_class_id\":\"$VEHICLE_CLASS_ID\",\"pickup_at\":\"$PICKUP\",\"pickup_address\":\"UAT Pickup\",\"dropoff_address\":\"UAT Dropoff\",\"distance\":20}"
TMPDIR=$(mktemp -d)
for i in 1 2 3 4 5; do
  curl -sS -H "$AUTH" -H "Content-Type: application/json" -H "Idempotency-Key: $KEY2" -d "$BODY" "$BASE/v1/bookings" > "$TMPDIR/r$i.json" &
done
wait
UNIQUE_IDS=$(grep -oh '"booking_id":"[^"]*"' "$TMPDIR"/r*.json | sort -u | wc -l | tr -d ' ')
echo "  responses:"; cat "$TMPDIR"/r*.json; echo
check "exactly one distinct booking_id across 5 concurrent requests" "1" "$UNIQUE_IDS"
rm -rf "$TMPDIR"
echo

echo "== 7. GET /v1/bookings/:id (status) =="
resp=$(curl -sS -w '\n%{http_code}' -H "$AUTH" "$BASE/v1/bookings/$BOOKING_ID")
body=$(echo "$resp" | head -n -1); code=$(echo "$resp" | tail -n1)
echo "$body"
check "status lookup" 200 "$code"
echo

if [ -n "$API_CREDENTIAL_2" ]; then
  echo "== 8. Cross-client isolation: second credential must NOT see first client's booking =="
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $API_CREDENTIAL_2" "$BASE/v1/bookings/$BOOKING_ID")
  check "other client sees 404 for this booking" 404 "$code"
  echo
else
  echo "== 8. Skipped (set API_CREDENTIAL_2 to test cross-client isolation) =="
  echo
fi

echo "== 9. POST /v1/bookings/:id/modify =="
KEY3="uat-$(date +%s)-modify"
resp=$(curl -sS -w '\n%{http_code}' -H "$AUTH" -H "Content-Type: application/json" -H "Idempotency-Key: $KEY3" \
  -d '{"dropoff_address":"UAT Dropoff Changed"}' "$BASE/v1/bookings/$BOOKING_ID/modify")
body=$(echo "$resp" | head -n -1); code=$(echo "$resp" | tail -n1)
echo "$body"
check "modify status" 200 "$code"
echo

echo "== 10. POST /v1/bookings/:id/cancel =="
KEY4="uat-$(date +%s)-cancel"
resp=$(curl -sS -w '\n%{http_code}' -H "$AUTH" -H "Content-Type: application/json" -H "Idempotency-Key: $KEY4" \
  -d '{"reason":"UAT cleanup"}' "$BASE/v1/bookings/$BOOKING_ID/cancel")
body=$(echo "$resp" | head -n -1); code=$(echo "$resp" | tail -n1)
echo "$body"
check "cancel status" 200 "$code"
echo

echo "== 11. No Idempotency-Key header on a mutating route -> 400 =="
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$AUTH" -H "Content-Type: application/json" \
  -d "$BODY" "$BASE/v1/bookings")
check "missing idempotency key status" 400 "$code"
echo

if [ -n "$WEBHOOK_WORKER_SECRET" ]; then
  WORKER_URL="${SUPABASE_URL%/}/functions/v1/webhook-delivery-worker"
  echo "== 12. Webhook worker: wrong secret -> 403 =="
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Worker-Secret: definitely-wrong" "$WORKER_URL")
  check "wrong worker secret status" 403 "$code"
  echo
  echo "== 13. Webhook worker: correct secret -> 200, with a JSON summary =="
  resp=$(curl -sS -w '\n%{http_code}' -H "X-Worker-Secret: $WEBHOOK_WORKER_SECRET" "$WORKER_URL")
  body=$(echo "$resp" | head -n -1); code=$(echo "$resp" | tail -n1)
  echo "$body"
  check "correct worker secret status" 200 "$code"
  echo
else
  echo "== 12/13. Skipped (set WEBHOOK_WORKER_SECRET to test the worker's own auth) =="
  echo "  Note: you cannot test the fail-closed 500 case here without temporarily UNSETTING"
  echo "  the secret in Supabase, which isn't safe to script against a live deployment --"
  echo "  that path was fixed and is covered in the code review notes, not here."
  echo
fi

echo "================================"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
