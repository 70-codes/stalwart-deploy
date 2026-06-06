#!/usr/bin/env bash
# JMAP smoke test reproducing the operator's symptom.
#
# Step 1: POST /jmap/session with basic auth and print the advertised URLs.
# Step 2: Subscribe to event_source_url and watch for events for a timeout.
#
# Expected behavior on the BROKEN baseline:
#   - Step 1 returns 200 and prints api_url / event_source_url pointing at an
#     unreachable host (whatever Stalwart's default base URL resolves to).
#   - Step 2 either fails immediately (URL unreachable) or hangs with no
#     events arriving because the tunnel is buffering the chunked stream.
#
# Expected behavior on the FIXED stack:
#   - Step 1 returns 200 and advertised URLs all point at the tunnel hostname.
#   - Step 2 establishes the event source and at least the initial state
#     event plus periodic ping events arrive within the timeout window.

set -euo pipefail

HOSTNAME="${HOSTNAME_OVERRIDE:-mail.example.com}"
USER="${JMAP_USER:-admin}"
PASS="${JMAP_PASS:-changeme-rotate-on-first-login}"
WATCH_SECONDS="${WATCH_SECONDS:-30}"

SESSION_URL="https://${HOSTNAME}/.well-known/jmap"

echo "==> [1] POST ${SESSION_URL}"
session_json=$(
  curl --silent --show-error --fail-with-body \
    --user "${USER}:${PASS}" \
    --request GET \
    --header "Accept: application/json" \
    "${SESSION_URL}"
)
echo "${session_json}" | jq '{ apiUrl, downloadUrl, uploadUrl, eventSourceUrl, capabilities: (.capabilities | keys) }'

event_source_url=$(echo "${session_json}" | jq -r '.eventSourceUrl')
echo
echo "==> [2] connecting to event source for ${WATCH_SECONDS}s"
echo "       ${event_source_url}"
echo

# Substitute the well-known template params. JMAP advertises a URL like
#   https://host/jmap/eventsource/?types={types}&closeafter={closeafter}&ping={ping}
# which we instantiate to "watch everything, never close, ping every 5s".
populated_url="${event_source_url//\{types\}/*}"
populated_url="${populated_url//\{closeafter\}/no}"
populated_url="${populated_url//\{ping\}/5}"

# Use curl with the SSE Accept header. Time out after WATCH_SECONDS.
curl --silent --show-error --fail-with-body \
  --user "${USER}:${PASS}" \
  --max-time "${WATCH_SECONDS}" \
  --header "Accept: text/event-stream" \
  --no-buffer \
  "${populated_url}" || rc=$?

rc="${rc:-0}"
if [[ "${rc}" -eq 28 ]]; then
  echo "==> event source reached timeout (${WATCH_SECONDS}s) - if events printed above this is the green path"
elif [[ "${rc}" -ne 0 ]]; then
  echo "==> event source failed with exit code ${rc} - this is the broken path"
  exit "${rc}"
fi
