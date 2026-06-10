# stalwart-deploy

Broken baseline of a Stalwart Mail Server deployment behind a Cloudflare Tunnel.

SMTP and IMAP work, webmail loads fine, but every JMAP client (Thunderbird's
JMAP module, FairEmail) hangs on the inbox sync right after auth. The Stalwart
access log shows the JMAP session call returns 200 and then nothing else hits
the server. The corrected versions of the files in this repo should make JMAP
push survive the tunnel without dropping Cloudflare for a different reverse
proxy.

## Layout

```
.
├── docker-compose.yml             # Stalwart + cloudflared sidecar on a shared bridge
├── env.example                    # Copy to .env — set STALWART_PUBLIC_URL here
├── stalwart/
│   ├── config.json                # Data-store bootstrap pointer (RocksDB path only)
│   └── config.toml                # Human-readable settings mirror ([server.http].url, use-x-forwarded)
├── cloudflared/
│   └── config.yml                 # Tunnel ingress with originRequest keep-alive options
└── scripts/
    └── test_jmap.sh               # curl-based JMAP smoke test
```

The cloudflared credentials JSON file is provisioned out of band (see "How to
reproduce" below) and not committed.

## Why does this work

Two bugs were stacked on top of each other. Either one alone was enough to
produce the "session returns 200, nothing else hits the server" symptom.

### Bug 1 — config.json filename mismatch caused permanent bootstrap suppression

The image entrypoint is:

```
/usr/local/bin/stalwart --config /etc/stalwart/config.json
```

The original compose file mounted `stalwart/config.toml` at
`/etc/stalwart/config.toml`. The binary never saw it and fell into
**bootstrap / recovery mode** — an ephemeral in-memory store used for the
initial setup wizard — on every single restart.

In recovery mode Stalwart's HTTP config is set in
`crates/common/src/config/network.rs`:

```rust
url_https: if !bp.registry.is_recovery_mode() {
    if let Some(url) = bp.registry.public_url() {  // STALWART_PUBLIC_URL
        url.to_string()
    } else {
        format!("https://{server_name}")            // fallback: container hostname
    }
} else {
    String::new()  // recovery mode: base URL always empty, env var bypassed
},
```

`STALWART_PUBLIC_URL` was silently discarded on every restart. The JMAP
session response emitted relative paths (`/jmap/`) or, depending on client
behaviour, resolved them against the container's random hostname — either way
unreachable from outside Docker.

The fix is `stalwart/config.json`:

```json
{ "@type": "RocksDb", "path": "/var/lib/stalwart/data" }
```

This four-line file is the only thing Stalwart v0.7+ reads from disk at
startup. Every other setting — listeners, domains, accounts, SMTP rules — is
stored inside the RocksDB data store and configured once via `/admin` after
first boot. The compose file now mounts it at `/etc/stalwart/config.json`,
the path the binary expects.

### Bug 2 — STALWART_PUBLIC_URL not set, JMAP session advertised unreachable URLs

Once the server is out of recovery mode, `STALWART_PUBLIC_URL` is read from
the environment (`crates/store/src/registry/local.rs`):

```rust
env_public_url: std::env::var("STALWART_PUBLIC_URL")
    .ok()
    .map(|v| v.trim().trim_end_matches('/').to_string())
    .filter(|u| !u.is_empty())
```

That value flows into `url_https`, which `Session::new` in
`crates/jmap-proto/src/request/capability.rs` uses to construct every URL the
server publishes:

```rust
api_url:          format!("{base_url}/jmap/"),
download_url:     format!("{base_url}/jmap/download/..."),
upload_url:       format!("{base_url}/jmap/upload/..."),
event_source_url: format!("{base_url}/jmap/eventsource/..."),
```

Without the variable the fallback is `https://<container-hostname>`. A client
that authenticated against `https://mail.example.com` reads the session body
and then tries to `POST` to `https://stalwart/jmap/` — unreachable from the
internet. Auth succeeds, then every subsequent request silently fails. Server
access logs show one request and then nothing.

`STALWART_PUBLIC_URL: https://mail.example.com` in `docker-compose.yml` (or
`.env` copied from `env.example`) fixes this. The older TOML path —
`[server.http] url = "https://mail.example.com"` in `stalwart/config.toml` —
also sets the same value for pre-v0.7 deployments; keeping both is harmless.

### SSE keep-alive for ongoing push

The JMAP event source (`/jmap/eventsource/`) is a chunked HTTP/1.1
Server-Sent Events stream. Cloudflare's edge drops connections idle for more
than 100 seconds. Clients that request a ping interval (`?ping=60`) receive
keep-alive frames from Stalwart every 60 seconds and survive the timeout.
The `originRequest` block in `cloudflared/config.yml` adds TCP-level
keep-alives and raises the pooled-connection timeout so the tunnel does not
recycle long-lived push streams between frames.

One thing intentionally absent: `http2Origin: true`. Stalwart's HTTP listener
uses `hyper::server::conn::http1` — HTTP/1.1 only. Forcing HTTP/2 to the
origin breaks the connection.

## Rollback: what to do if STALWART_PUBLIC_URL is set wrong in production

**Symptom:** JMAP clients hang after auth, same as the original bug. The
healthcheck will show `unhealthy` within two failed intervals (60 s) which
is the fastest signal.

### Confirm the misconfiguration

```sh
# From outside the host — should print an absolute https:// URL for apiUrl
curl -s https://mail.example.com/jmap/session | grep apiUrl

# From the host itself — compare what the server is advertising vs what is set
docker exec stalwart env | grep STALWART_PUBLIC_URL
docker exec stalwart curl -fs http://127.0.0.1:8080/jmap/session | grep -o '"apiUrl":"[^"]*"'
```

If the two values don't match, or `apiUrl` is empty/relative, the variable is
wrong.

### Fix forward (preferred)

Edit `.env` (or `docker-compose.yml` directly if you're not using `.env`),
correct `STALWART_PUBLIC_URL`, then do a **zero-downtime environment reload**:

```sh
# docker compose re-creates only containers whose config changed
docker compose up -d --force-recreate stalwart

# Watch the healthcheck recover — should flip to healthy within ~90 s
watch -n5 'docker inspect stalwart --format "{{.State.Health.Status}}"'
```

SMTP and IMAP connections are not affected; they use direct TCP ports that
compose does not restart. Existing webmail sessions survive the recreate
because the RocksDB data volume is unchanged.

### Emergency rollback to the last known-good image

If the URL was never correct and you want to roll back to the previous working
image tag rather than editing the config:

```sh
# 1. Note the current image digest for later reference
docker inspect stalwart --format '{{.Image}}'

# 2. Pin the compose file to the previous tag, e.g.:
#    image: stalwartlabs/stalwart:0.16.7
# then:
docker compose up -d --force-recreate stalwart
```

The RocksDB data store is version-locked to the Stalwart release that wrote
it. Rolling forward to a higher minor version after a downgrade may require
running `docker compose exec stalwart stalwart --migrate` first — check the
Stalwart changelog before pinning a downgrade across a minor boundary.

### Prevent recurrence

The healthcheck in `docker-compose.yml` catches a wrong URL before clients do:

```
test: curl -fs http://127.0.0.1:8080/jmap/session
      | grep -q '"apiUrl":"$STALWART_PUBLIC_URL'
interval: 30s  retries: 3  start_period: 30s
```

After changing `STALWART_PUBLIC_URL`, run the smoke test before declaring the
deploy healthy:

```sh
HOSTNAME_OVERRIDE=mail.example.com JMAP_USER=youruser JMAP_PASS=yourpass \
  ./scripts/test_jmap.sh
```

The first phase of the test (`apiUrl` check) will immediately tell you whether
the URL is correct without needing to open a JMAP client.

## Source code for understanding the failure path

Stalwart's source lives at https://github.com/stalwartlabs/stalwart. The three
files that explain how the JMAP session response is built and why the broken
baseline hangs are:

- `crates/http/src/request.rs` — handles GET /jmap/session, calls
  handle_session_resource with the configured base URL as the only input
- `crates/jmap-proto/src/request/capability.rs` — Session::new interpolates
  that single base URL into api_url, download_url, upload_url, and
  event_source_url
- `crates/common/src/config/network.rs` — exposes the url_https and
  use_forwarded fields. The toml keys are network.http.url_https and
  network.http.use_x_forwarded (the rust field is named use_forwarded
  internally, the toml key adds the x_)

## How to reproduce

```sh
# 1. Provision a Cloudflare tunnel under your account.
cloudflared tunnel login
cloudflared tunnel create stalwart-mail
cp ~/.cloudflared/<tunnel-id>.json ./cloudflared/credentials.json
cloudflared tunnel route dns stalwart-mail mail.example.com

# 2. Bring the stack up.
docker compose up -d

# 3. Watch the JMAP smoke test fail (or hang).
HOSTNAME_OVERRIDE=mail.example.com JMAP_USER=admin JMAP_PASS=changeme \
  ./scripts/test_jmap.sh
```

## Acceptance criteria for the fix

The corrected deploy must:

- Make the JMAP smoke test print advertised URLs whose hostname matches the
  tunnel hostname (not the container internal hostname).
- Make the event source phase of the test receive at least the initial state
  event plus periodic ping events within the 30 second window.
- Continue to keep SMTP / IMAP / webmail working.
- Not require switching off Cloudflare for a different reverse proxy.
- Not require editing Stalwart's Rust source. The fix is configuration only:
  this repo plus the cloudflared config plus the Stalwart toml.
