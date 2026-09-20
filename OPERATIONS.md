# Operating one repeater

TinRelay is designed for one small Linux container behind a trusted HTTPS edge
and one persistent SQLite volume. It has no Kubernetes, Postgres, HA, federation,
dashboard, billing, or provider API. Deployment configuration belongs to the
operator; this repository owns the image and application runtime contract.

## Container contract

`Dockerfile` builds only `tinrelayd` into a scratch image. The final image contains
the daemon, its minimal runtime libraries, BusyBox for the entrypoint, and no
source, specs, Git metadata, client binary, site content, CSS, or JavaScript.

The image has two entrypoint actions:

- `prepare` runs as root only to make `/var/lib/tinrelay` mode 0700 and owned by
  UID/GID 10001;
- `serve` refuses root, opens `/var/lib/tinrelay/tinrelay.db` mode 0600, binds port
  8787, and starts the one repeater process.

Run the service as UID/GID 10001 with a read-only root filesystem, all Linux
capabilities dropped, `no-new-privileges`, and a writable persistent volume only
at `/var/lib/tinrelay`. Terminate TLS at the trusted edge.

The trusted edge routes API requests to `tinrelayd`. Public HTML and the First
Light journey are built and served independently by `tinrelay-site`.

`script/verify-container` is the executable packaging proof. It builds the real
`linux/amd64` image, prepares an isolated volume, starts the service under the
restrictions above, waits for readiness, checks shutdown and database ownership,
audits the final filesystem, and removes its disposable Docker state:

```sh
script/verify-container
```

An optional `TINRELAY_BUILD_LABEL` can identify a build in `tinrelayd version`.
It is passive debugging provenance, not a runtime setting or trust claim.

`tinrelayd serve` reads an optional `tinrelayd.json` from its working directory;
`--config PATH` or `-c PATH` selects another location and requires it to exist.
Absence of the conventional file at startup uses the defaults. A present file contains
one complete runtime policy:

```json
{
  "registration": {
    "global_hour": 300,
    "global_day": 1000,
    "per_source_hour": 4,
    "per_source_day": 4,
    "deny_cidrs": [],
    "exclude": []
  },
  "client_address": {
    "mode": "direct",
    "trusted_ingress_cidrs": []
  }
}
```

The four registration allowances count successful claims in rolling one-hour and
24-hour windows. Any zero allowance closes registration. `deny_cidrs` rejects new
claims from matching source addresses before reading their bodies. After ordinary
authentication, each canonical name in `exclude` bypasses the source-address
transmission token buckets, hail window, owner-rotation window, and radio-retune
window; it does not bypass registration policy, authentication, request or pending
bounds, or permanent-metadata capacity. An unclaimed excluded name remains dormant
until that exact ship is claimed.

In `direct` client-address mode, registration and transmission admission use the
socket peer and ignore forwarded-address headers. In `trusted_proxy` mode,
`trusted_ingress_cidrs` must name the final trusted proxy ingress. TinRelay accepts
exactly one
`X-Tinrelay-Client-IP` value only from such a peer. The final proxy must overwrite
that header, and the origin firewall must exclude untrusted ingress. IPv4 addresses
use `/32` source buckets; IPv6 addresses use `/64` buckets.

Replace the whole file and send SIGHUP to atomically adopt the complete
registration, logging, and client-address policy without restart. An unreadable,
missing, or invalid reload keeps the complete last-known-good policy. Removing the
conventional file restores defaults only on a fresh startup, not during reload. These
values do not change protocol, command, key, or local-state identity.

## One process and one database

`tinrelayd serve` uses every detected processor by default in one Crystal process.
This lets all runtime threads share parked radio waits without a broker. SQLite
WAL permits concurrent reads, while one process-local writer-admission boundary
serializes every Store transaction that can mutate the database. `--threads N`
may reduce concurrency for a constrained host
or bounded diagnostic; it cannot exceed the detected CPU count.

An authenticated radio request may remain parked for 100 seconds. A reverse proxy
must permit that complete hold; the official client allows 115 seconds for its
HTTP response. Roll out repeater support before clients request a longer hold;
the repeater rejects a request above its own supported maximum. While parked,
the repeater writes JSON whitespace every 25 seconds so a closed client or proxy
connection releases its in-memory waiter before the signed deadline.

Do not start multiple service processes against one database. Migrations, graceful
lifetime, cleanup, and direct waiter ownership belong to the single process.

Ship claims are open and first-claim-unique. The client submits the new ship's
public owner key and owner-signed initial radio certificate; the operator does
not issue claim credentials or approve names. Ordinary trusted-edge request
limits are the service's abuse boundary.

## Health, restart, and retention

- `GET /healthz` proves the process answers.
- `GET /readyz` proves SQLite is queryable.
- `GET /metrics` emits aggregate Prometheus text for an operator-only listener.
- SIGTERM and SIGINT close the listener and database cleanly.
- Cleanup ordinarily runs every 60 seconds. After a full 256-row transmission batch, it runs
  again one second later and repeats until the next batch is not full; `tinrelayd cleanup ...` is
  the idempotent manual equivalent.

Successful registration source buckets and server acceptance times survive process
restart in `registration_events`. Rows at or before the 24-hour cutoff are removed by
the next successful claim or periodic cleanup. Cleanup is periodic, so removal normally
occurs on the first sweep after 24 hours rather than at the exact anniversary.

`/metrics` must not be exposed by the public HTTPS listener. Reach it only through
the deployment's SSH tunnel or another operator-only path. It reports registered
ships and relationships by state, active parked radio waits, queued transmission and hail depth and
age, retained ciphertext bytes, and fixed-outcome counters for registrations,
transmissions, hails, waits, configuration reloads, and cleanup. It contains no
ship, coordinate, network, attention, or correspondent labels. Database-backed
gauges survive restart; process counters and the process start timestamp reset
with `tinrelayd`. Rising queue depth and oldest-item age while accepted traffic
continues without acknowledgements is the primary stuck-delivery signal.

`tinrelay_sqlite_files_bytes` is the current apparent byte-length sum of the
main TinRelay database, its WAL, and its shared-memory file. It measures the
SQLite store's files, including free pages and transient WAL/shared-memory
occupancy; it is distinct from retained ciphertext payload bytes and does not
claim filesystem block allocation.

The fixed registration outcomes are `accepted`, `rate_limited`, `cidr_denied`,
`closed`, `policy_changed`, `capacity`, `invalid`, and `conflict`. Each modeled
terminal registration-admission outcome increments exactly one of these process
counters.

Logs are newline JSON. Request records contain request ID, method, normalized
public path, HTTP status, and duration when `logging.requests` is true in the
runtime configuration. Set it to false when edge metrics provide the production
request view; faults, lifecycle events, configuration reloads, and cleanup
remain logged. Records omit bodies, ciphertexts, signatures, and key material.
Monitor readiness, restart loops, `cleanup_failed`, disk space, pending expiry,
and verified-backup age.

Pending fallback ciphertext expires after 96 hours. Successful local spool
acknowledgement erases relay payload immediately; direct acknowledged handoff never
writes a transmission payload row. A stopped radio loses only its in-memory parked
wait. Valid destinations still receive bounded SQLite store-and-forward.

Maintenance is a separate fixed public/client condition, not a radio event or
relay-authored transmission. An edge that does not provide that bounded response
is ordinary unavailability, and clients use their normal reconnect behavior.

## Backup and restore

TinRelay has no backup format. Use SQLite's online backup command, then an
established encryption tool selected by the operator. For example, with `age`:

```sh
umask 077
sqlite3 /var/lib/tinrelay/tinrelay.db \
  ".backup '/protected-staging/tinrelay.db'"
age -r "$AGE_RECIPIENT" -o /secure-offhost/tinrelay-$(date +%F).db.age \
  /protected-staging/tinrelay.db
rm /protected-staging/tinrelay.db
```

Use explicit protected paths and the operator's recoverable deletion practice. The
relay database and each ship's local identity/history are different assets with
different owners. TinRelay provides no identity-backup subsystem.

A backup is not proven until a separate restore drill decrypts a copy and checks
it:

```sh
age -d -o /protected-restore/tinrelay.db "$BACKUP"
sqlite3 /protected-restore/tinrelay.db 'PRAGMA integrity_check;'
sqlite3 /protected-restore/tinrelay.db \
  'SELECT version, applied_at FROM schema_migrations ORDER BY version;'
```

Start the same inspected daemon against that copy on an isolated port, verify
`/readyz` and the expected ship/key/pending-transmission state, then remove the
restored plaintext through the operator's protected-file procedure. A restore can lose
claims and ciphertext newer than its snapshot. Parked waits are process-local and
radios re-establish them.

## Failure and disclosure boundary

SQLite WAL protects committed transactions across an ordinary restart. Clients
retain their own keys, private spool, and exact outbox envelopes awaiting retry.
There is no operator-mediated owner takeover. If every copy of a ship's owner key
is lost, do not manufacture continuity: retire that identity as possible and claim
a different ship name.

The repeater sees network metadata, relay origin, ship names and public key
generations, signed outer IDs/routes/times, ciphertext sizes, positive relationship
and hail state, parked-wait timing, and request rates. Encrypted backups may
preserve older forensic state according to operator policy.

Auditing this repository can establish what these source bytes do. It cannot prove
that a public operator deployed exactly them, follows the stated edge logging,
retention, or backup practice, or will not delay or drop traffic. TinRelay adds no
remote attestation or policy system.
