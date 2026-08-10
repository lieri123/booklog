#!/usr/bin/env bash
# End-to-end smoke test. Hits a running server and checks real responses.

set -uo pipefail

BASE="${1:-http://127.0.0.1:8080}"
EMAIL="smoke-$(date +%s)@example.com"
PASS="correcthorse1"
PASSED=0
FAILED=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASSED=$((PASSED+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s (%s)\n' "$1" "$2"; FAILED=$((FAILED+1)); }

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected $2, got $3"; fi
}

code() { # code <method> <path> [json] [auth]
  local m=$1 p=$2 body=${3:-} auth=${4:-}
  local args=(-s -o /tmp/smoke_body -w '%{http_code}' -X "$m" "$BASE$p")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  [ -n "$auth" ] && args+=(-H "Authorization: Bearer $auth")
  curl "${args[@]}"
}

echo "Smoke testing $BASE"
echo

# --- ops 
echo "ops:"
check "healthz returns 200" 200 "$(code GET /healthz)"
check "readyz returns 200 (database reachable)" 200 "$(code GET /readyz)"

# --- auth 
echo "auth:"
check "register" 201 "$(code POST /register "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")"
check "duplicate register rejected" 409 \
      "$(code POST /register "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")"
check "wrong password rejected" 401 \
      "$(code POST /login "{\"email\":\"$EMAIL\",\"password\":\"wrongpassword\"}")"
check "login" 200 "$(code POST /login "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")"

TOKEN=$(python3 -c 'import json,sys;print(json.load(open("/tmp/smoke_body"))["access_token"])' 2>/dev/null)
if [ -z "$TOKEN" ]; then echo "  could not get token, aborting"; exit 1; fi

check "no token rejected"      401 "$(code GET /library)"
check "bad token rejected"     401 "$(code GET /library '' 'not-a-jwt')"

# --- library 
echo "library:"
DUNE='{"ol_work_key":"OL893415W","title":"Dune","authors":["Frank Herbert"],"page_count":604,"cover_id":12345}'
LOTR='{"ol_work_key":"OL27448W","title":"The Lord of the Rings","authors":["J. R. R. Tolkien"],"page_count":1178}'

check "add book" 201 "$(code POST /library "$DUNE" "$TOKEN")"
ENTRY=$(python3 -c 'import json;print(json.load(open("/tmp/smoke_body"))["id"])')
check "duplicate book rejected" 409 "$(code POST /library "$DUNE" "$TOKEN")"
check "add second book" 201 "$(code POST /library "$LOTR" "$TOKEN")"
check "list library" 200 "$(code GET /library '' "$TOKEN")"
check "get one entry" 200 "$(code GET "/library/$ENTRY" '' "$TOKEN")"
check "missing entry is 404" 404 "$(code GET /library/99999999 '' "$TOKEN")"
check "set progress" 200 \
      "$(code PATCH "/library/$ENTRY/progress" '{"page":302}' "$TOKEN")"

PCT=$(python3 -c 'import json;print(json.load(open("/tmp/smoke_body"))["percent_complete"])')
check "progress computes 50%" 50.0 "$PCT"

check "change status" 200 \
      "$(code PATCH "/library/$ENTRY/status" '{"status":"reading"}' "$TOKEN")"
check "rate the book" 200 "$(code PATCH "/library/$ENTRY" '{"rating":5}' "$TOKEN")"
check "invalid rating rejected" 422 "$(code PATCH "/library/$ENTRY" '{"rating":9}' "$TOKEN")"

# --- isolation 
echo "isolation:"
OTHER="smoke-other-$(date +%s)@example.com"
code POST /register "{\"email\":\"$OTHER\",\"password\":\"$PASS\"}" > /dev/null
code POST /login "{\"email\":\"$OTHER\",\"password\":\"$PASS\"}" > /dev/null
TOKEN2=$(python3 -c 'import json;print(json.load(open("/tmp/smoke_body"))["access_token"])')

# 404 rather than 403 — a 403 confirms the entry exists and belongs to someone else
check "other user cannot read entry"   404 "$(code GET "/library/$ENTRY" '' "$TOKEN2")"
check "other user cannot modify entry" 404 \
      "$(code PATCH "/library/$ENTRY" '{"rating":1}' "$TOKEN2")"
check "other user cannot delete entry" 404 "$(code DELETE "/library/$ENTRY" '' "$TOKEN2")"

# --- stats 
echo "stats:"
check "stats returns 200" 200 "$(code GET /stats '' "$TOKEN")"
UNREAD=$(python3 -c 'import json;print(json.load(open("/tmp/smoke_body"))["backlog"]["unread_pages"])')
check "backlog counts only unread (1178, not 1782)" 1178 "$UNREAD"

# --- upstream dependency 
echo "search (upstream):"
SEARCH=$(code GET "/search?q=dune")
case "$SEARCH" in
  200) pass "search returned results" ;;
  503) pass "search degraded to 503 (upstream unreachable — correct behaviour)" ;;
  *)   fail "search" "got $SEARCH, expected 200 or 503" ;;
esac

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
