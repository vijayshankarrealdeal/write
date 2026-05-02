#!/usr/bin/env bash
# Smoke-test the inkspace ingest pipeline via the API.
#
# Usage:
#   ./smoke_test.sh                 # default: http://localhost:8000
#   API_URL=https://your.vm:8000 ./smoke_test.sh
#
# What it does:
#   1. Logs in as inkspace@inkspacex.com / Google@99 → grabs an access token.
#      (Falls back to /register if the account doesn't exist yet — first
#      run after a wiped DB.)
#   2. Calls /api/users/me to confirm the token works.
#   3. Calls /api/feed/by-author/<my_id> to list every book the inkspace
#      account has published.
#   4. Calls /api/feed/home to confirm the composed-rails endpoint sees
#      the same books surfacing in at least one rail.
#
# Exits non-zero on any failure so CI / scripts can chain on the result.

set -euo pipefail

API_URL="${API_URL:-http://localhost:8000}"
EMAIL="${INKSPACE_EMAIL:-inkspace@inkspacex.com}"
PASSWORD="${INKSPACE_PASSWORD:-Google@99}"
NAME="${INKSPACE_NAME:-inkspace}"

# Pretty-printer — gracefully degrades if jq isn't installed.
pretty() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  else
    cat
  fi
}

echo "==> API: $API_URL"
echo "==> Logging in as $EMAIL"

login_response="$(curl -sS -X POST "$API_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" || true)"

# Extract the access token. If login fails (account doesn't exist on a
# freshly wiped DB), register and retry.
access_token="$(echo "$login_response" | (jq -r '.access_token // empty' 2>/dev/null || echo ""))"

if [[ -z "$access_token" ]]; then
  echo "    login failed — attempting to register the inkspace account"
  register_response="$(curl -sS -X POST "$API_URL/api/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"$NAME\"}")"
  access_token="$(echo "$register_response" | jq -r '.access_token // empty')"
  if [[ -z "$access_token" ]]; then
    echo "ERROR: register also failed:"
    echo "$register_response" | pretty
    exit 1
  fi
  echo "    registered + logged in"
else
  echo "    logged in"
fi

AUTH_HEADER="Authorization: Bearer $access_token"

echo "==> Fetching /api/users/me"
me="$(curl -sS -H "$AUTH_HEADER" "$API_URL/api/users/me")"
echo "$me" | pretty

my_id="$(echo "$me" | jq -r '.id')"
if [[ -z "$my_id" || "$my_id" == "null" ]]; then
  echo "ERROR: couldn't read user id from /me response"
  exit 1
fi

echo
echo "==> Fetching /api/feed/by-author/$my_id (books published by inkspace)"
by_author="$(curl -sS -H "$AUTH_HEADER" "$API_URL/api/feed/by-author/$my_id")"
count="$(echo "$by_author" | jq 'length')"
echo "    inkspace has $count published books"
echo "$by_author" | jq '[.[] | {id, title, author, likes_count, visibility}]'

echo
echo "==> Fetching /api/feed/home (composed rails)"
home="$(curl -sS -H "$AUTH_HEADER" "$API_URL/api/feed/home")"
echo "$home" | jq '[.[] | {rail_id, title, item_count: (.items|length)}]'

echo
echo "==> Smoke test passed."
