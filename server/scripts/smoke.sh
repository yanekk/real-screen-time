#!/usr/bin/env bash
#
# smoke.sh — post-deploy smoke test of the remote-grant backend (T10; DESIGN §3.6, §4, §2.3, §2.7).
#
# Runs against a DEPLOYED stack whose base URL you pass. It needs no browser and no Google
# sign-in: it exercises the whole RECEIVE side over HTTP and proves the create side turns a
# device token away. It never covers a screen and touches only the backend, so it is safe to run.
#
#   1. redeem a pairing code          → a read-only 64-hex device token           (POST /pair/redeem)
#   2. list grants with that token    → the current grant list, possibly empty    (GET  /grants)
#   3. create a grant with that token → refused 403; a device token cannot create (POST /grant, §2.3)
#   4. list grants with a bogus token → refused 401; the receive gate holds        (GET  /grants, §2.7)
#
# The pairing code comes from the web page: sign in as the parent, choose "connect a Mac", read
# the code it shows. A code is single-use (DESIGN §2.4), so each run consumes one — mint a fresh
# code per run. The device token this script obtains is a real, live token: running the script
# re-pairs, which REVOKES whatever Mac was paired before (DESIGN §2.4). Run it before pairing the
# real Mac, or re-pair the Mac afterwards.
#
# Usage:   server/scripts/smoke.sh <base-url> <pairing-code>
# Example: server/scripts/smoke.sh https://abc123.execute-api.eu-west-1.amazonaws.com 8F3K2Q
#
# Exit status: 0 if every check passed, 1 otherwise. Requires bash and curl; jq is used only to
# pretty-print the grant list when present, and the script works without it.

set -euo pipefail

# ---- arguments -------------------------------------------------------------------------------

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <base-url> <pairing-code>" >&2
  echo "  <base-url>      the deployed stack's ApiUrl, e.g. https://xxxx.execute-api.<region>.amazonaws.com" >&2
  echo "  <pairing-code>  a fresh single-use code from the web page (sign in → connect a Mac)" >&2
  exit 2
fi

BASE=${1%/}   # strip one trailing slash so "<url>" and "<url>/" behave the same
CODE=$2

pass=0
fail=0

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }

# ok <expected-status> <actual-status> <label> — record and print one check's outcome.
ok() {
  local want=$1 got=$2 label=$3
  if [[ "$got" == "$want" ]]; then
    printf '  [%s] %s (HTTP %s)\n' "$(green PASS)" "$label" "$got"
    pass=$((pass + 1))
  else
    printf '  [%s] %s (expected HTTP %s, got %s)\n' "$(red FAIL)" "$label" "$want" "$got"
    fail=$((fail + 1))
  fi
}

# request METHOD PATH [AUTH] [JSON-BODY]
# Performs the call and sets the globals STATUS and BODY. Aborts (via set -e) only if curl itself
# cannot reach the host — a non-2xx response is data here, not an error, so `-f` is not used.
STATUS=""
BODY=""
request() {
  local method=$1 path=$2 auth=${3:-} body=${4:-}
  local args=(-sS -X "$method" "$BASE$path")
  [[ -n "$auth" ]] && args+=(-H "Authorization: Bearer $auth")
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  # Append the status code on its own trailing line, then split it back off. Using the last
  # newline as the separator is robust even if a body ever contained one.
  local resp
  if ! resp=$(curl "${args[@]}" -w $'\n%{http_code}'); then
    echo "  $(red 'FAIL') could not reach $BASE$path — is the URL right and the stack deployed?" >&2
    exit 1
  fi
  STATUS=${resp##*$'\n'}
  BODY=${resp%$'\n'*}
}

# Extract a top-level string field from a compact JSON object without needing jq.
json_field() {
  local field=$1 doc=$2
  printf '%s' "$doc" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

echo "Smoke-testing $BASE"
echo

# ---- 1. redeem the pairing code -------------------------------------------------------------

request POST /pair/redeem "" "{\"code\":\"$CODE\"}"
ok 200 "$STATUS" "redeem pairing code"
TOKEN=$(json_field token "$BODY")
if [[ "$STATUS" != "200" || -z "$TOKEN" ]]; then
  echo
  echo "  Could not obtain a device token. The code may be used, expired, or mistyped —"
  echo "  mint a fresh one from the web page and try again. Server said: $BODY"
  echo
  echo "Result: $(red 'FAILED') (1/1 so far); cannot continue without a token."
  exit 1
fi
echo "       obtained a device token (${#TOKEN} chars)"

# ---- 2. list grants with the device token ---------------------------------------------------

request GET /grants "$TOKEN"
ok 200 "$STATUS" "list grants with the device token"
if [[ "$STATUS" == "200" ]]; then
  if command -v jq >/dev/null 2>&1; then
    count=$(printf '%s' "$BODY" | jq 'length' 2>/dev/null || echo '?')
    echo "       $count grant(s) waiting:"
    printf '%s' "$BODY" | jq . 2>/dev/null | sed 's/^/         /' || true
  else
    echo "       grants: $BODY"
  fi
fi

# ---- 3. a device token must NOT be able to create a grant -----------------------------------

request POST /grant "$TOKEN" '{"minutes":15}'
ok 403 "$STATUS" "device token refused for POST /grant (create is parent-only, §2.3)"

# ---- 4. an unknown device token must be refused on the receive side -------------------------

request GET /grants "0000000000000000000000000000000000000000000000000000000000000000"
ok 401 "$STATUS" "unknown device token refused for GET /grants (receive gate, §2.7)"

# ---- verdict --------------------------------------------------------------------------------

echo
if [[ "$fail" -eq 0 ]]; then
  echo "Result: $(green 'ALL PASSED') ($pass/$pass). The backend's receive side and create-side gate are live."
  exit 0
else
  echo "Result: $(red 'FAILED') ($pass passed, $fail failed)."
  exit 1
fi
