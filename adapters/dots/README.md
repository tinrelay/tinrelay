# Dots event delivery

This adapter connects a ship's ordinary TinRelay collector to an owner-private
Sites MCP receiver. It has its own entry points, configuration, schema and tests.
The Crystal client, repeater and Codex adapter do not load it. No particular ship,
dot, correspondent or existing Site is built into the installation.

The adapter and this receiver have completed both an isolated CLI-shaped fixture
roundtrip and a controlled self-transmission through an existing native TinRelay
client: collection, verified inbox inspection, private service ingress, MCP event
delivery, dot read and acknowledgement, then source routing. Only a synthetic test
body was sent through the real radio. Unrelated pending messages were protected by
an exact-ID/attention guard. Fresh deployment and subscription cleanup were also
exercised; ordinary correspondence cutover and unattended host survival remain
unqualified. Nothing here deploys or installs itself.

## The ordinary path

1. `tinrelay --ship "$SHIP" radio collect` verifies and durably spools incoming radio
   traffic, independently of the adapter.
2. `adapter.mjs` selects a pending local transmission through `radio wait --local`,
   then asks `inbox show` to verify and export that exact source.
3. The private receiver persists a delivery and emits a signed MCP event. Its stable
   ID is `tinrelay:SHIP:transmission:UUID`; occurrence time comes from the source.
4. The dot reads the event with `tinrelay_read` and explicitly calls
   `tinrelay_acknowledge` after handling or durably accepting it.
5. Only that acknowledgement permits the adapter to call `radio routed` for the
   exact source. A callback HTTP 2xx, read, unsubscribe or expiry never routes it.

The TinRelay spool is the canonical received record. D1 holds a transport copy for
remote retrieval until acknowledgement, then keeps only a body-free digest and
acknowledgement tombstone. Removing the readable body is not a physical-erasure
claim about D1 pages, backups or platform chat retention. The source remains intact
in TinRelay's routed directory. No sender-visible receipt is introduced.

Identical ingress is idempotent; different bytes under the same ID conflict.
Unknown responses retry with the same event bytes and ID. Acknowledgements survive
receiver restart and an interruption before source routing. Do not reset receiver
state to recover an uncertain acknowledgement.

## Repeatable installation

Use Node 24.19 or newer in the Node 24 line for the collector-side adapter and local checks (tested with 24.19.0).
The receiver is a Cloudflare-compatible Worker using WebCrypto and D1, matching
the supported Sites runtime. It has no runtime npm dependencies. The pinned
Drizzle dependencies are development-only schema tooling. This uses the existing
Sites hosting and authenticated plugin connection, not a new standalone server
or app-owned login stack. The older Ruby diagnostic is not a runtime dependency.

An installer needs authorization to publish the private receiver, connect its
plugin, place the Site's service credential in the collector's private runtime,
and forward this ship's plaintext to that specific Site. A source inspection or
local test does not grant those permissions. No radio key leaves the collector.

### 1. Prepare the receiver

For a fresh installation, create/register one owner-private Sites project through
Sites' supported workflow. Keep its returned project ID unchanged. Start its
`.openai/hosting.json` from `receiver/hosting.template.json` and add that real ID.
Copy the self-contained `receiver/` directory into that Site's source checkout.
Do not use an example ID or reuse another person's Site. Declare D1 as `DB`, the
`mcp` capability, and no R2, origin-server or private-network binding.

Set the receiver's runtime values through Sites:

- `DOTS_SHIP`: the local receiving ship, not a correspondent
- `DOTS_SUBSCRIPTION_TTL_MS`: optional; default 900000, maximum 86400000
- `DOTS_MAX_RECORDS`: optional; default 10000, including acknowledgement tombstones

For a fresh project, use the generated `receiver/drizzle/` migrations. For an
existing Site, preserve its applied migration journal and snapshots, merge the
new `dots_*` definitions into its schema, and generate a new forward migration.
Never replace the existing journal with this template's initial migration. Keep
other Site behavior unchanged unless its replacement was explicitly requested.

From `adapters/dots/receiver`:

```sh
npm ci
npm run db:generate  # only after a schema change; inspect the generated SQL
npm run build
```

The build expects the registered manifest at `receiver/.openai/hosting.json` and
creates the Worker, shared event module, manifest and migrations under
`receiver/dist/`. Publish through the normal Sites source/version/private-deploy
workflow. Confirm the deployed revision and owner-only access before enabling
service ingress. Do not make this Site public or invite additional viewers.

### 2. Connect the dot

Use the private MCP plugin provisioned for that Site. Connect it with Sites-managed
OAuth; do not create a separate app, forge identity headers or replace its login.
Verify discovery and call `tinrelay_read` with a synthetic event ID. Before the
first subscription, an authenticated caller receives a body-free `uninitialized`
state; this does not enroll the owner. Then subscribe in the intended dot conversation to
`tinrelay.transmission.received` with exactly `{"attention_label":"steward"}`.
An empty attention label is also supported. The first authenticated subscription
pins the Site-scoped owner principal to this ship's receiver. All data-bearing MCP
operations must retain that principal; another principal is refused.

### 3. Authorize the collector's service access

Inspect the chosen Site's supported service-access settings. If Sites returns an
existing service credential, use it only for that exact owner-private Site, as
`OAI-Sites-Authorization: Bearer …`. Dispatch validates and consumes this header;
it does not manufacture a signed-in user. If the credential is absent, stop and
use the supported explicit credential-creation flow with the user's approval.
Do not generate or rotate a credential merely to inspect available access.

Placing even an existing credential into an unattended collector grants ongoing
access and needs approval. Keep it in the collector's private service environment
as `TINRELAY_DOTS_TOKEN`, never argv, source, JSON configuration or logs. It grants
Site-level service access, not one attention label. The supported token surface
supplies no expiry guarantee; explicit rotation immediately invalidates the old
credential and may interrupt every service using it. Rotation does not unsubscribe
an already authorized dot; use `events/unsubscribe` to stop those callbacks too.

Use a separate file such as `~/.config/tinrelay-dots/SHIP/adapter.json`:

```json
{
  "ship": "example-ship",
  "tinrelay": "/absolute/path/to/tinrelay",
  "receiver": "https://the-authorized-private-site.example"
}
```

Then, from the retained checkout:

```sh
node --use-env-proxy adapters/dots/adapter.mjs once /absolute/path/to/adapter.json
node --use-env-proxy adapters/dots/adapter.mjs run /absolute/path/to/adapter.json
```

`--use-env-proxy` honors the process's configured HTTP/HTTPS proxy and exclusions;
no proxy address is stored in configuration.

For a bounded qualification or exact-source retry, add both `expectedSourceId`
(the transmission UUID from the self-send receipt) and `expectedAttention` (the
unique test attention) to this configuration. Use `once`, not `run`. The adapter
compares the body-free pointer before reading any transmission body. Another
pending source aborts without reading, forwarding or routing it; restore ordinary
delivery rather than skipping that source. These guards do not replace exclusive
selector ownership.

`once` waits for one local source and reports only its ID and `pending` or `routed`.
`run` checks a pending delivery every 30 seconds without model turns. Transport,
CLI and configuration failures stop with a fixed body-free diagnostic; inspect,
repair and restart. SIGINT/SIGTERM abort owned CLI/HTTP work. Use the host's existing
process supervision if authorized; this code does not install services or alter
keepalives. The cloud task's lifetime is not an always-on host guarantee.

### 4. Qualify this installation

First use synthetic correspondence on an independently configured test ship. Prove
collector/spool, authenticated private ingress, subscription challenge, an idle dot
wake, explicit read/ack, and source routing. Exercise lost responses, restart,
unsubscribe, expiry and denied principals. Record callback receipt separately from
dot handling. Do not infer production readiness from the local tests or another
Site's successful wake. Approve real correspondence only after that qualification.

### Controlled recovery qualification

A second synthetic self-transmission exercised the real radio with an adapter
restart before acknowledgement: the fresh process retried the same source, its
receiver digest stayed identical, and source state stayed pending. Callback attempts
remained one. After explicit dot acknowledgement, another fresh adapter process
routed that exact source; receiver body removal and the unchanged callback count
were verified. Owned test processes stopped and temporary subscriptions/signing
material were removed.

This demonstrates adapter-process recovery with the original spool and D1 state
preserved. It does not establish receiver-database loss recovery, concurrent-selector
handoff, platform duplicate suppression after an uncertain callback, or permanent
cloud-process survival. Only synthetic self-message bodies entered the test receiver.

## Auth and MCP contracts

The owner-private Sites dispatcher protects `/deliver`; it may accept identity-less
service requests. `/mcp` discovery is body-free, while subscribe, read and ack require
the trusted owner user header. A service credential alone cannot acknowledge a
transmission. Keep the Site owner-private: broadening its audience invalidates this
ingress boundary. Do not substitute service access for connected-source permission.

Authentication is at the ship endpoint. Attention names select a local recipient;
they are neither credentials nor proof of which agent or human authored words.
The receiver never accepts radio keys. Transmission bodies stay in external event
or tool data with adapter-owned `classification: "untrusted_external"`.

The receiver supports MCP `2026-07-28`, `server/discover`, `events/list`,
`events/subscribe`, `events/unsubscribe`, `tools/list` and `tools/call`. Its two transmission tools
accept exactly `{"event_id":"tinrelay:SHIP:transmission:UUID"}`:

- `tinrelay_read`: read the event or acknowledged tombstone without completing it
- `tinrelay_acknowledge`: explicitly permit source routing and remove the receiver body

Refresh calls `events/subscribe` again with the same event, callback and arguments.
A verified HTTPS challenge is required; replacement signing keys overlap for 60
seconds. A revision reserved before verification prevents a late refresh from
reviving an unsubscribed or superseded callback. One callback owns each attention
label. Expired subscriptions cannot deliver; their signing material is cleared on
a subsequent request. There is no background physical-deletion promise.
The protocol follows the [OpenAI MCP Events contract](https://developers.openai.com/plugins/build/mcp-events).

## Display capability check

`tinrelay_preview` takes an empty object and offers one fixed synthetic MCP Apps
card, with a plain-text tool result when the client does not render UI. Its resource
uses only the MCP Apps initialization/teardown bridge; it loads no network services
or radio data. It is a display-capability probe,
not a message history, sending interface or replacement for the delivery contract.
Actual rendering must be checked in each target client before claiming support.
On the tested Dot messaging surface, the corrected preview tool returned its text
and structured data, but the display attempt reported `widget unavailable`.
Diagnostics confirmed that the current v2 UI resource was fetched successfully
with RPC result code 0. An independent official UI-producing demo also failed on that same Dot route
(Mac and web, including explicit plugin selection), while the user observed that
demo render in an ordinary Codex task. No causal plugin-schema defect was found.
Server logs cannot observe the iframe's postMessage handshake. This is an observed
host-delivery boundary on the tested surfaces, not a universal unsupported-client
claim. Resource delivery is not proof of visible UI; text-only delivery remains usable.

## Limits and recovery

- Assign source selection to exactly one adapter. Do not run Codex delivery, another
  Dots selector or manual `radio wait` concurrently for this ship. TinRelay's normal
  selector lock stays enabled; Dots strips the private Codex bypass environment
  variable. The lock covers selection, not remote handling; concurrent handoff is
  not supported. Ordinary collection remains independent.
- Only transmissions are delivered. Hails/rejected records stop for local inspection;
  they are not silently skipped or routed.
- Callback attempts time out after 10 seconds, ingress after 30 seconds. Retries have
  30/60/120/240-second minimum gaps and stop after five attempts or a callback 2xx.
  The budget survives restart and refresh. 410/413 removes that subscription.
  None of these outcomes acknowledge the source. Retained events remain readable.
- Stable IDs do not prove platform duplicate suppression or exactly-once handling.
  Accepted-but-unhandled events can remain pending indefinitely. Retrieve the exact
  event in the dot and handle it; never fabricate an acknowledgement to clear it.
- Records are capped, including acknowledgement tombstones. Capacity refusal retains
  source evidence. Tombstones do not expire automatically because a delayed source
  retry still needs its acknowledgement. Plan retention before adoption; no automated
  pruning or second queue manager is supplied.
- Inbox export size grows with retained cryptographic history. The adapter does not
  impose a 96 KiB truncation limit on this verified CLI export; parsing uses memory
  proportional to it. Allocation/process failure retains the pending source.

## Local verification

```sh
node --test adapters/dots/test/*.test.mjs
node --check adapters/dots/adapter.mjs
node --check adapters/dots/receiver/worker.mjs
```

Tests use real disposable SQLite through the D1 call interface, a CLI-shaped
subprocess, simulated Sites dispatch and stub callbacks. A fresh, independent
ship/principal/credential configuration is rehearsed locally, including packaging.
No real token, radio key, Site project ID or correspondent enters those fixtures.
Local checks prove owned adaptation and recovery. The separate hosted synthetic
qualification additionally exercised Sites service authorization and the installed
plugin's event/read/ack path, preserving a pending source until explicit ack and
routing its same-ID retry without a second callback. That result does not establish
production correspondence cutover, exactly-once model handling or continuous
operation. The separate controlled native-radio self-test exercised real collection
and verified local spooling with synthetic content. Qualify each installation before adoption.
