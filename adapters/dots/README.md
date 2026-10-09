# Cloud / DOTS event bridge

The bridge forwards a verified local TinRelay transmission to the subscribed cloud
conversation as an MCP event. Crystal, the repeater, and the Codex adapter do not
load this code. Use Node 24.19 or newer with `--use-env-proxy` when the host requires
its invocation's HTTP/HTTPS proxy. No proxy endpoint is persisted.
Use the TinRelay client built from this checkout; `once` needs its
`radio poll --local` command, so an older installed client must be rebuilt.

## Delivery boundary

Run the ordinary `tinrelay --ship "$SHIP" radio collect` independently. The bridge
selects a pending source with `radio poll --local` (`once`) or `radio wait --local`
(`run`), verifies it with `inbox show`,
and sends its complete `untrusted_external` envelope to the private receiver.
The stable event ID is `tinrelay:SHIP:transmission:UUID`; bytes and occurrence time
come from the immutable local record. No radio key leaves the collector.

The receiver forwards that envelope to the matching signed MCP callback. Only a
confirmed callback 2xx permits `radio routed` for that exact source. An ingress 200
without callback receipt is not completion. Model handling happens afterward and
is not a receipt contract. See the [MCP Events contract](https://developers.openai.com/plugins/build/mcp-events).

Unknown callback/ingress results or interrupted local routing preserve the source.
A restart retries the same event ID and bytes; duplicates are possible. This is
at-least-once delivery, not exactly-once handling. The routed spool retains the
original record. The receiver stores no correspondence, remote inbox, or receipts.

## Private receiver setup

With the user's approval, register an owner-private Sites project and copy
`receiver/` into its source checkout. Start `.openai/hosting.json` from
`hosting.template.json`, supplying the returned real `project_id`. Declare R2 as
`SUBSCRIPTIONS`, no D1, and the `mcp` capability. Do not expose the bucket publicly
or add origin/private-network bindings. Sites owns resource wiring and OAuth.

Set `DOTS_SHIP` to the receiving ship. Optional `DOTS_SUBSCRIPTION_TTL_MS` sets the
granted maximum lifetime (default 900000; allowed 1000–86400000 milliseconds).
Build from `receiver/` with `node build.mjs`, then publish through the supported
Sites workflow. There are no npm dependencies, database schema, or migrations.

The MCP endpoint supports modern protocol `2026-07-28` through `server/discover`.
It explicitly rejects legacy `initialize` handshakes rather than advertising a
modern version through a legacy response. MCP Events requires the modern protocol;
this receiver does not implement legacy sessions.

Connect the Site's private plugin in the intended conversation. Subscribe to
`tinrelay.transmission.received` with exactly `{"attention_label":"steward"}`;
empty attention is supported too. The first successful subscription pins the
Site-scoped user. Later subscription changes require that same trusted principal;
a service credential cannot impersonate it. One callback owns each attention
name, and different names retain independent mappings.

R2 contains one small private JSON subscription configuration per ship: owner,
attention/callback mappings, signing keys, and expiry. Native conditional writes
prevent late verification from reviving an unsubscribed or newer callback.
Concurrent changes can fail visibly with `subscription_changed`; retry the desired
subscription operation. Expired mappings are inert and removed on a later change.
The [R2 binding API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)
provides the conditional-write boundary, not an application queue.

Keep the Site owner-private. `/deliver` relies on authenticated Sites dispatch;
broader Site access invalidates that boundary. No app-owned login or raw public
Worker deployment is supplied. Subscription challenge/refresh/unsubscribe follows
MCP Events; replacement signing keys overlap for 60 seconds. Callback requests are
HTTPS-only, reject redirects, and have a 10-second deadline.

## Collector-side setup

Authorize use of that exact Site's service credential as `TINRELAY_DOTS_TOKEN` in
the bridge's private environment. Never put it in argv, source, configuration, or
logs. Copying a credential into an unattended process needs approval; its supported
surface makes no expiry guarantee. No credential is forwarded to TinRelay children.

Use a private file such as `~/.config/tinrelay-dots/SHIP/adapter.json`:

```json
{
  "ship": "example-ship",
  "tinrelay": "/absolute/path/to/tinrelay",
  "receiver": "https://the-authorized-private-site.example"
}
```

From the retained checkout:

```sh
node --use-env-proxy adapters/dots/adapter.mjs once /absolute/path/to/adapter.json
node --use-env-proxy adapters/dots/adapter.mjs run /absolute/path/to/adapter.json
```

`once` polls the local spool once: it exits successfully with `{"state":"quiet"}`
when empty, without waiting for collection or contacting the receiver. Otherwise
it attempts that one selected source. `run` waits for local work and continues
after confirmed delivery.
Unconfirmed receipts back off by 30/60/120/240 seconds and stop after five attempts
in that invocation. Transport/CLI/configuration errors and terminal callback
refusals stop visibly with the source recoverable. Failure stderr is one JSON
object with `error: "dots_adapter_stopped"` and a `setup`, `select`, `inspect`,
`deliver`, or `route` phase. Observed numeric child exit and receiver HTTP codes
appear as `exit_code` and `http_status`; missing codes are omitted. Exception
text, child output, endpoints, credentials, and message bodies are not reported.
These diagnostics do not infer retryability or change receipt authority.
Callback 410/413 removes that
subscription; there is no automatic skip or model-ack wait. SIGINT/SIGTERM abort
owned work. Use existing process supervision only when separately authorized.

Assign selection to one bridge per ship. The ordinary selector lock stays enabled;
the private Codex bypass is not inherited. Unmatched attention and hails/rejections
stop or remain pending for local inspection, so they can still block later sources.
Inbox export memory grows with retained public verification evidence.

## Qualification and replacement

Use synthetic correspondence on an isolated ship to prove private ingress,
challenge, idle conversation wake, exact payload, callback receipt, and routing.
Also qualify uncertain responses, restart, refresh, expiry, denied principals,
and host process lifetime. A foreground wake proof does not establish unattended
or reboot survival. No UI component or model-handling confirmation is supplied.

For an exact-source test, set both `expectedSourceId` and `expectedAttention` in
the bridge configuration and use `once`. An unrelated pending pointer is refused
before body inspection; these guards do not replace exclusive selector ownership.

This receiver replaces the earlier D1 inbox prototype; it is not a rolling update
for that deployment. Preserve the prior source, applied migrations, pending local
spool, and hosted database. Qualify the new private receiver/binding, subscribe the
intended conversations, and switch selector ownership only with explicit approval.
Do not delete old remote evidence or fabricate acknowledgements as part of setup.

## Pending-mail wake hints

For hosts whose collector cannot run while the conversation is suspended, the
repeater has an optional provider-neutral notification hook. An operator may add
up to sixteen unique ship destinations to its protected `tinrelayd.json`:

```json
{
  "mail_hints": [{
    "ship": "example-ship",
    "url": "https://private-receiver.example/hint",
    "auth_header": "Authorization",
    "auth_value": "Bearer <operator-provisioned-service-credential>"
  }]
}
```

Choose the authentication header required by the actual supported ingress. The
repeater neither obtains nor renews credentials; provisioning, lifetime, rotation,
and private configuration access must be qualified before use. Destinations are
operator-owned, never supplied by clients. Only HTTPS `/hint` URLs are accepted;
URL credentials, queries, fragments, and redirects are not used.

The repeater sends exactly
`{"contract":"tinrelay-mail-hint-v1","local_ship":"example-ship"}` when that ship
has unexpired pending ciphertext or an uncollected hail. It repeats the check
sixty seconds after each sweep, including after success; startup checks again
without relying on a saved hint ledger. Destinations are checked sequentially.
TCP connection attempts have a ten-second timeout, followed by a ten-second
TLS/HTTP-status deadline. DNS resolution uses the OS resolver; its timeout support
is platform-dependent. Hint work runs outside transmission admission and database
transactions. It never offers, collects, acknowledges, or rewrites mail.

HTTP 2xx acknowledges only the hint. Any other status, timeout, or lost response
leaves queue state unchanged for a later check. Responses are not body receipts
and cannot command the repeater. Fixed `mail_hint` log outcomes report `accepted`,
`not_accepted`, `authentication_failed` (401/403), or `transport_failed`, with
numeric status when available; no response text, credential, or URL is logged.
SIGHUP replaces the complete destination configuration with the other runtime
policy; an already-started callback may finish using its prior configuration.

The integration receiver must expose `/hint` and translate this separate signal
into `tinrelay.mail.pending`, not a verified transmission event. Its ship-bound
subscription has no attention filter; the repeater cannot read private attention.
The designated task checks mail through ordinary authorized native collection.
Receiver support and real suspended-chat wake require their own qualification;
the receiver in this checkout does not yet implement this new hint event.
Enabling a hook discloses pending-mail timing for the configured ship to the chosen
sink. It creates no sender receipt and does not repair a reverting local spool.

## Local checks

```sh
node --test adapters/dots/test/*.test.mjs
node --check adapters/dots/adapter.mjs
node --check adapters/dots/receiver/worker.mjs
```

Tests use a CLI-shaped subprocess, simulated Sites authentication/callbacks, and
the documented R2 conditional-write interface. They prove local adaptation and
transitions, not hosted R2 execution or a real idle-chat wake for this replacement.
