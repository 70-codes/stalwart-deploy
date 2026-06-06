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
├── stalwart/
│   └── config.toml                # Stalwart config (url_https commented out, use_x_forwarded = false)
├── cloudflared/
│   └── config.yml                 # Default tunnel ingress, no originRequest options
└── scripts/
    └── test_jmap.sh               # curl-based JMAP smoke test that reproduces the hang
```

The cloudflared credentials JSON file is provisioned out of band (see "How to
reproduce" below) and not committed.

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
