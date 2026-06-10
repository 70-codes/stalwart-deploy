#!/bin/sh
# One-shot init: ensure Stalwart's plaintext "submission" (587, STARTTLS) and
# "imap" (143, STARTTLS) NetworkListener objects exist via the JMAP Registry
# API (x:NetworkListener/set), then restart the stalwart container so any
# newly-created listeners bind. Idempotent - safe on every `docker compose up`.
set -eu

CONTAINER="${STALWART_CONTAINER:-stalwart}"
JMAP_URL="http://${CONTAINER}:8080/jmap/"
SESSION_URL="http://${CONTAINER}:8080/jmap/session"
AUTH_HEADER="Authorization: Basic $(printf '%s' "${STALWART_RECOVERY_ADMIN}" | base64)"

echo "[bootstrap-listeners] waiting for ${CONTAINER} JMAP API..."
until wget -q -O /dev/null --header "${AUTH_HEADER}" "${SESSION_URL}"; do
  sleep 2
done
echo "[bootstrap-listeners] ${CONTAINER} is up"

needs_restart=0

ensure_listener() {
  name="$1"; bind="$2"; protocol="$3"

  query="{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:stalwart:jmap\"],\"methodCalls\":[[\"x:NetworkListener/query\",{\"filter\":{\"name\":\"${name}\"}},\"0\"]]}"
  resp=$(wget -q -O- --header "${AUTH_HEADER}" --header "Content-Type: application/json" \
    --post-data "${query}" "${JMAP_URL}")

  case "${resp}" in
    *'"ids":[]'*)
      echo "[bootstrap-listeners] creating '${name}' listener on ${bind}"
      create="{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:stalwart:jmap\"],\"methodCalls\":[[\"x:NetworkListener/set\",{\"create\":{\"${name}\":{\"name\":\"${name}\",\"bind\":{\"${bind}\":true},\"protocol\":\"${protocol}\",\"useTls\":true,\"tlsImplicit\":false}}},\"0\"]]}"
      out=$(wget -q -O- --header "${AUTH_HEADER}" --header "Content-Type: application/json" \
        --post-data "${create}" "${JMAP_URL}")
      case "${out}" in
        *'"created"'*) needs_restart=1 ;;
        *) echo "[bootstrap-listeners] WARNING: failed to create '${name}': ${out}" >&2; exit 1 ;;
      esac
      ;;
    *)
      echo "[bootstrap-listeners] '${name}' listener already present, skipping"
      ;;
  esac
}

# submission: STARTTLS SMTP submission on 587 (mirrors the implicit-TLS
# "submissions" listener Stalwart creates by default on 465)
ensure_listener submission "[::]:587" smtp

# imap: STARTTLS IMAP on 143 (mirrors the implicit-TLS "imaps" listener
# Stalwart creates by default on 993)
ensure_listener imap "[::]:143" imap

if [ "${needs_restart}" -eq 1 ]; then
  echo "[bootstrap-listeners] restarting ${CONTAINER} so new listener(s) bind"
  docker restart "${CONTAINER}"
else
  echo "[bootstrap-listeners] nothing to do"
fi
