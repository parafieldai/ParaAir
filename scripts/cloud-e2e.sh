#!/bin/bash
# End-to-end check of the Mac client against a local ParaAir Cloud service (spec 9, A9).
# Starts `wrangler dev` with throwaway local D1/R2 state and dev-only secrets, invites
# one test address, runs ParaAirCloudE2ETests, checks the Worker log for leaked
# secrets (A12), then stops the service and removes only what this run created.
# Nothing is deployed and no real email is sent.
# PARAAIR_E2E_PORT moves the service off 8787 (the issuer follows the port).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
port="${PARAAIR_E2E_PORT:-8787}"
[[ "$port" =~ ^[0-9]{2,5}$ ]] || { echo "PARAAIR_E2E_PORT must be a port number." >&2; exit 1; }
base="http://127.0.0.1:$port"

free_kib=$(df -Pk /System/Volumes/Data | awk 'NR==2 {print $4}')
if [[ -z "$free_kib" || "$free_kib" -lt 104857600 ]]; then
  echo "At least 100 GiB free on /System/Volumes/Data is required before the end-to-end run." >&2
  df -h /System/Volumes/Data >&2
  exit 1
fi
[[ -d "$root/cloud" ]] || { echo "The ParaAir Cloud service (cloud/) is not in this checkout." >&2; exit 1; }
for tool in npx openssl curl lsof node; do
  command -v "$tool" >/dev/null || { echo "$tool is required." >&2; exit 1; }
done
listener() { lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true; }
if [[ -n "$(listener)" ]]; then
  echo "Port $port is already in use; stop that service or set PARAAIR_E2E_PORT." >&2; exit 1
fi

(cd "$root/cloud" && { [[ -d node_modules ]] || npm ci; })

made_runtime=0
[[ -d "$root/.runtime" ]] || { mkdir -p "$root/.runtime"; made_runtime=1; }
made_wrangler_dir=0
[[ -d "$root/cloud/.wrangler" ]] || made_wrangler_dir=1
tmp="$(mktemp -d "$root/.runtime/cloud-e2e-XXXX")"
wrangler_pid=""
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done
  kill "$pid" 2>/dev/null || true
}
cleanup() {
  local status=$?
  if [[ -n "$wrangler_pid" ]]; then
    kill_tree "$wrangler_pid"
    wait "$wrangler_pid" 2>/dev/null || true
    # The port was free before this run, so anything still listening on it is ours.
    for _ in $(seq 1 50); do [[ -n "$(listener)" ]] || break; sleep 0.2; done
    local pids; pids="$(listener)"
    [[ -z "$pids" ]] || kill $pids 2>/dev/null || true
  fi
  rm -rf "$tmp"
  [[ "$made_wrangler_dir" == 0 ]] || rm -rf "$root/cloud/.wrangler"
  [[ "$made_runtime" == 0 ]] || rmdir "$root/.runtime" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT INT TERM

# WRANGLER_LOG=log keeps the Worker's request log lines for the A12 check below;
# WRANGLER_WRITE_LOGS=false keeps wrangler's debug log out of ~/Library/Preferences/.wrangler/logs.
export WRANGLER_SEND_METRICS=false WRANGLER_LOG=log WRANGLER_WRITE_LOGS=false
ADMIN="$(openssl rand -hex 32)"
PEPPER="$(openssl rand -hex 32)"
RKEY="$(openssl rand -hex 32)"
KKEY="$(openssl rand -hex 32)"
umask 077
printf 'Authorization: Bearer %s\n' "$ADMIN" > "$tmp/admin-header"

cd "$root/cloud"
npx wrangler d1 migrations apply paraair-index --local --persist-to "$tmp/state" > "$tmp/migrations.log" 2>&1 || {
  echo "Applying local D1 migrations failed:" >&2; tail -n 40 "$tmp/migrations.log" >&2; exit 1
}
npx wrangler dev --ip 127.0.0.1 --port "$port" --persist-to "$tmp/state" --var "ISSUER:$base" \
  --var "DEV_MODE:1" --var "ADMIN_TOKEN:$ADMIN" --var "CODE_PEPPER:$PEPPER" \
  --var "REFRESH_TOKEN_KEY:$RKEY" --var "READ_TOKEN_KEY:$KKEY" \
  --var "ACCESS_TOKEN_TTL_SECONDS:120" --var "AUTH_LIMITS:relaxed" > "$tmp/wrangler.log" 2>&1 &
wrangler_pid=$!

ready=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "$base/v1/health" >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "$wrangler_pid" 2>/dev/null || break
  sleep 1
done
if [[ "$ready" != 1 ]]; then
  echo "wrangler dev did not become healthy within 60 s:" >&2; tail -n 40 "$tmp/wrangler.log" >&2; exit 1
fi

email="e2e-$RANDOM$RANDOM@example.test"
status=$(curl -sS -o "$tmp/invite.json" -w '%{http_code}' -X POST "$base/admin/v1/invites" \
  -H @"$tmp/admin-header" -H 'Content-Type: application/json' \
  --data "{\"email\":\"$email\",\"plan\":\"beta\",\"workspaceId\":null,\"role\":\"owner\",\"expiresInDays\":14}")
if [[ "$status" != 201 ]]; then
  echo "Creating the test invite failed (HTTP $status)." >&2; exit 1
fi

cd "$root"
set +e
PARAAIR_E2E_BASE_URL="$base" PARAAIR_E2E_ADMIN_TOKEN="$ADMIN" PARAAIR_E2E_EMAIL="$email" PARAAIR_CLOUD_ALLOW_LOOPBACK_HTTP=1 \
  swift test --build-system native --jobs 4 --filter ParaAirCloudE2ETests
result=$?
set -e

# A12: the Worker logs route templates only; no email, token, code, secret or file path.
leaks=0
check() { if grep -qF -- "$1" "$tmp/wrangler.log"; then echo "A12: wrangler log contains $2" >&2; leaks=1; fi; }
if ! grep -qF '"route":"POST /v1/drives/:driveId/uploads/:uploadId/commit"' "$tmp/wrangler.log"; then
  echo "A12: the Worker's request log lines are missing" >&2; leaks=1
fi
if grep -qF '"event":"unhandled"' "$tmp/wrangler.log" || grep -qF 'Uncaught' "$tmp/wrangler.log"; then
  echo "A12: the Worker logged an unhandled error" >&2; leaks=1
fi
check "$email" "the test email"; check "${email%@*}" "the email's local part"
check "$ADMIN" "the admin token"; check "$PEPPER" "the code pepper"; check "$RKEY" "the refresh key"; check "$KKEY" "the read-token key"
for prefix in pca_ pcr_ pcc_ prt1. pa_ar=; do check "$prefix" "a token ($prefix)"; done
for path in /Movies a+b.mov a%2Bb.mov doc.txt big.bin never-cached; do check "$path" "a file path"; done
codes="$(curl -sS -H @"$tmp/admin-header" -G "$base/__dev/outbox" --data-urlencode "email=$email" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const m of JSON.parse(s).messages)console.log(m.code)})')"
for code in $codes; do
  if grep -qE "(^|[^0-9A-Za-z])$code([^0-9A-Za-z]|$)" "$tmp/wrangler.log"; then echo "A12: wrangler log contains a sign-in code" >&2; leaks=1; fi
done
lines=$(grep -c '"route":' "$tmp/wrangler.log" || true)
if [[ "$leaks" == 0 ]]; then
  echo "A12 PASS: $lines request log lines, $(printf '%s\n' $codes | grep -c .) sign-in codes checked; no emails, tokens, codes, secrets or paths"
fi

if [[ "$result" == 0 && "$leaks" == 0 ]]; then echo "cloud e2e PASS"; exit 0; fi
echo "cloud e2e FAIL (swift test exit $result, log check $leaks)" >&2
exit 1
