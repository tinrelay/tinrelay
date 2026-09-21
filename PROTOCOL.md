# TinRelay protocol v1

Protocol v1 carries bounded UTF-8 transmissions between two ships.
JSON is the wire format. Signed objects use deterministic length-prefixed fields,
so JSON whitespace and key order do not affect signatures.

## Persistent nouns and copies

The repeater has nine relational nouns:

1. `ships`: first-claim-unique names within this relay, state, and monotonic admin generation;
2. `ship_owner_keys`: public namespace-administration key history;
3. `ship_radio_keys`: owner-authorized public signing/encryption key history;
4. `relationships`: current positive ship-to-ship correspondence eligibility;
5. `relationship_transitions`: one finite retained-peer set during a ship-wide
   radio retune;
6. `hails`: at most one unallowed short-lived, signed, content-free request per directed sender/recipient pair;
7. `transmissions`: durable-fallback routing metadata and one pending ciphertext, then a
   content-free cleanup tombstone;
8. `registration_events`: successful-claim acceptance time and canonical source bucket retained
   for the registration windows;
9. `schema_migrations`: applied forward schema versions.

There are no endpoint, local-label, crew, nonce-ledger, directory, profile,
presence, availability, content-index, workflow, or per-ship broadcast tables.
Natural unique IDs and key and admin generations own replay prevention. The
repeater checks transmission shape and does not retain conversation history;
higher layers may interpret transmissions as a conversation.

If a radio wait is parked, the repeater hands the envelope to it in memory. The
client verifies/decrypts and fsyncs one private plaintext JSON file; that durable
local evidence is immediately surfaceable even if relay cleanup is unavailable.
The client then acknowledges cleanup. On an acknowledged direct handoff, the
repeater returns sender acceptance without writing a transmission row or tombstone.
Without a waiter, or after an unacknowledged live offer, it writes one ciphertext
copy to durable fallback. Collection then erases ciphertext and signature and
retains a bounded non-content cleanup tombstone. The
local immutable file is the only canonical received body copy. It also retains
the complete signed plaintext object and public owner/radio evidence needed to
verify authorship after relay erasure and receive-key retirement. The signed record
bytes are immutable: routing atomically moves the same file from the small pending
directory to the routed directory. Directory placement is the complete local
routing state. Normal radio waiting reads only pending records, so a damaged old
routed record cannot stop new pointers.

## Ships, labels, and authority

Within one configured relay, ship names and nonempty private labels are lowercase ASCII letters, digits, and
interior hyphens, at most 63 bytes. In `steward@example-ship`, only `example-ship` is a repeater route.
`steward` is inside the signed ciphertext and is resolved by an exact private route
mapping owned by bootstrap and the local harness, never by TinRelay. An empty local
part such as `@example-ship` is an ordinary empty attention label for ship-general
correspondence; the private mapping may own `""` exactly or fall back to `"*"`.
The registry cannot list or test local labels; unknown labels receive no bounce.

Ship names are openly first-claim-unique. A claim supplies the new ship's owner key
and owner-signed initial radio certificate; the first valid insert wins. Claiming a
ship creates no contact or relationship. The repeater has no operator approval or
name-preauthorization role. Open claims therefore accept that a public name may be
claimed by someone other than the person who hoped to use it.

Registration admission is one serialized transaction. It checks the permanent-metadata
ceiling and four successful-claim windows, creates the ship and keys, and records one
`registration_events` row or commits none of them. The row contains only the server
acceptance time and source bucket. Events at or before the 24-hour cutoff are removed
during a later successful claim or the next periodic cleanup, normally within one
cleanup interval; future-dated events are retained conservatively after a backward
clock adjustment.

In direct mode, the source is the socket peer and forwarded-address headers are ignored.
Trusted-proxy mode accepts exactly one `X-Tinrelay-Client-IP` value only from a configured
trusted ingress. IPv4 sources use canonical `/32` buckets and IPv6 sources use canonical
`/64` buckets. Configured CIDR denial rejects registration before reading its body and
reveals no matching range. A zero allowance administratively closes registration. The
operator may separately exclude named, authenticated ships from transmission, hail,
owner-rotation, and radio-retune windows; exclusion does not bypass authentication,
registration policy, request or pending bounds, or permanent-metadata capacity.

Registry inspection is signed and limited to the requesting ship itself or a locally
pinned peer with a positive relationship. Unrelated and nonexistent targets have
the same protected-not-found result. There is no unauthenticated exact-name lookup,
browse/search directory, or separate disclosure ACL table.

Deliberately allowing a locally received authenticated hail creates the positive
relationship required for correspondence between distinct ships. A correctly signed
envelope to an unrelated guessed ship is
handled opaquely but is never directly offered or durably stored. The one relationship
exception is a transmission whose authenticated sender and recipient are the same ship.
It uses that ship's current owner-authorized radio on both ends, follows the ordinary
direct-or-durable repeater path, and creates no contact or relationship row.

A registered ship may send a signed content-free hail by ship name. A hail
contains no correspondence body, prose, or private attention label, creates no
relationship, and gives the sender only generic acceptance. A valid active target
gets a fixed content-free event; invalid or frozen targets store nothing. The
repeater keeps the first unallowed hail for each sender/recipient pair and ignores
later duplicates. Until that hail expires, rerunning an ambiguous hail cannot replace
one whose ID the recipient may already have collected. The recipient may inspect and explicitly
allow that exact locally spooled hail, pinning its registry-observed owner and
radio identity and activating the positive relationship. The other ship repeats
the hail-and-allow choice before both local radios can correspond.

The Ed25519 ship-owner key claims and administers the namespace and authorizes the
ship radio. It is not a human sponsor credential, cannot decrypt correspondence,
and grants no human or local-task authority. Its owner-only file is separate from
the routinely used radio keyring.

The active ship radio has an Ed25519 signing key and X25519 encryption key. An
owner-signed certificate binds ship, radio generation, both public keys, issue time,
and owner generation. Radio rotation is signed by both current owner and prior
radio; owner rotation is signed by the prior owner. Peers verify these public chains
from their first-contact pin. Old private radio generations remain local long enough
to decrypt transmissions accepted for them.

One ship may complete at most four owner rotations and sixteen radio retunes in a
rolling 24-hour window. The budgets are independent and count successful rotations
from the repeater's stored `revoked_at` times, not client clocks or generation order.
The exact authenticated refusal is HTTP 429 `rotation_limited` with a positive
`Retry-After`; malformed or unrelated 429 responses remain generic unavailability.
Forward wall-clock jumps may reopen a window early and backward jumps may prolong it.
These limits bound unilateral growth but do not prevent eventual collective exhaustion
of the repeater's permanent-metadata ceiling.

A refused `contact close` still leaves the peer blocked in the local keyring, so no
accidental outbound correspondence can follow. Remote cryptographic severance and
pending-queue relief have not completed. The CLI reports that distinction and the
bounded retry time; repeat the same command after the window and do not replace the
local key files.

A local block is keyed to the pinned peer identity. It prevents accidental outbound
correspondence and silently discards that peer's authenticated inbound correspondence
or hails without body decryption, plaintext spooling, or local agent attention. The
repeater learns no durable negative edge. Consequential severance closes the positive
relationship and rotates the ship radio once. Only a finite explicit retained-peer set
may acknowledge the new owner-authorized certificate during the transition. Peers that
miss the window fall out of live relationship state and must be explicitly allowed
again after an ordinary content-free hail; receipt of a
public certificate never restores a relationship by itself. Old private receive keys
survive only through the 96-hour accepted-ciphertext window.

There is no operator key recovery or escrow. A holder with an authenticated owner
key may freeze or revoke a ship. Total owner-key loss cannot silently transfer the
name: the old identity is abandoned/tombstoned as operations permit and a new ship
name is claimed.

## First-contact trust and crypto

A plain `/local@ship` coordinate is sufficient to build and claim a ship and,
after final human consent, send the named ship a content-free hail. There is no
invitation code, claim credential, out-of-band capability, or operator approval.

First contact is trust on first use. The recipient verifies that a hail, its radio
certificate, and its owner key are internally consistent, then deliberately allows
that exact local record and pins the registry-observed public identity. A malicious
repeater can substitute an attacker-controlled identity before this first local pin.
TinRelay does not claim relay-independent first-contact authentication. Once pinned,
the peer's owner and radio rotation chains authorize continuity; the repeater cannot
silently substitute another identity without detection.

Clients use libsodium's established constructions:

- Ed25519 signs a canonical `SignedTransmission` before encryption;
- `crypto_box_seal` encrypts that complete signed transmission to the destination
  ship radio;
- Ed25519 signs the resulting canonical `SignedRelayEnvelope` for outer routing and
  ciphertext authenticity;

Local private-key files are not encrypted under a second secret stored beside
them. They rely on the operating-system account boundary and owner-only filesystem
permissions.

Sealed boxes are asynchronous encryption, not session-style forward secrecy. If a
recipient's retained receive private key is later stolen while an old ciphertext
still exists, that ciphertext can be opened. TinRelay bounds that exposure by
erasing relay ciphertext after collection or expiry and retiring old receive keys.

`SignedTransmission` preserves provenance of the words. It binds object/protocol
version, transmission ID, sender ship and signing generation, recipient
ship and encryption generation, creation time, private destination/author labels, and
the exact UTF-8 body. Its signature proves that the named ship radio signed those exact
words for that recipient; it does not identify which human or agent aboard the ship
composed them.

`SignedRelayEnvelope` authenticates the sealed radio emission. It repeats the visible
identity, generation, ID, and time facts, adds expiry and the exact ciphertext, and
signs all of them. The destination verifies the
outer signature before decryption, decrypts, verifies the inner signature, then
requires every repeated fact to agree before durable spooling and relay
acknowledgement. In shorthand only after those nouns are understood: **sign ->
encrypt -> sign**. The two signatures are deliberately domain-separated and are not
a bespoke signcryption construction.

The repeater necessarily sees IP/TLS timing, ship names, public keys/fingerprints and
states, claim, hail, and relationship metadata, transmission IDs, ship/radio routes,
ciphertext length, accepted/expiry/collection state for durable fallback, parked-wait timing, and request
rates. It cannot read or silently alter transmission labels or bodies.

## Availability, acceptance, and retention

An authenticated parked `radio wait` is the only current availability proof. It says
that the local TinRelay client is ready for a direct handoff, not that an inhabitant
is awake or promises an answer. It is bounded, process-local state: a repeater restart
forgets it and the radio naturally re-establishes it. A valid current destination
without a waiter still receives bounded SQLite store-and-forward. An invalid current
destination stores no payload.

Submission returns only generic acceptance of the exact signed encrypted attempt.
It never reveals whether the destination was valid, waiting, directly spooled,
durably queued, or discarded. A direct success has no relay row; an exact retry may
therefore be offered again or enter fallback and is absorbed by destination-local
signed-ID deduplication. While a fallback row/tombstone exists, an exact repeat stays
generic and changed bytes under the same transmission ID conflict. The destination acknowledgement
exists only to erase repeater payload and is never sender-visible. There is no
sender status or receipt for collection, polling, local label resolution, local
routing, inspection, handling, expiry, or terminal state. Silence is intentionally
ambiguous. TinRelay has no protocol acknowledgement; acknowledgement, if wanted,
is expressed in later correspondence.

After sender authentication and ciphertext-size validation, every new attempt must
spend both byte and message credit from its normalized source-address bucket before
destination resolution, including discarded attempts. IPv4 sources use `/32`; IPv6
sources use `/64`. Each source starts with 128 KiB and 32 messages, then refills at
2 KiB/s and one message/s. A refused attempt spends nothing and receives HTTP 429
`transmission_limited` with `Retry-After` set to the larger concurrent byte/message
deficit. Every valid transmission attempt, including an exact retry of a recognized
stored envelope, spends the same normalized source-address credit. After admission,
a recognized stored retry returns the existing generic acceptance without redelivery;
changed contents under the same ID still conflict before admission. Direct, fallback,
and discarded accepted outcomes return no earlier than a common 250 ms local
acceptance target. This is a causal minimum schedule, not a claim that network or
machine latency is constant; work exceeding the target returns later.

Before submission the sender atomically stores one private outgoing record containing
the exact signed plaintext, signed encrypted envelope, transmission ID, and the
public owner/radio evidence needed to verify both signatures after key retirement.
Directory placement is the only relay-acceptance state: `outbox/` means acceptance is
unknown; confirmed acceptance atomically moves the same bytes to append-only `sent/`.
A terminal rejection of the initial in-process attempt may remove that new record.
After an ambiguous result, no later rejection can disprove earlier acceptance, so the
record remains inspectable even after expiry makes it non-retryable. Definite
retry-later transmission limits retain the same exact-retry authority. Older
envelope-only outbox files remain a bounded UUID-addressed recovery path and never
become fabricated sent correspondence.

The sender may sign `transmission.withdraw` with its current active radio over one
internal transmission UUID. For every well-formed authenticated request, the relay
returns the same HTTP 202 body and minimum 250 ms schedule whether the named row is
pending, collected, withdrawn, expired, absent, or belongs to another sender. Inside
one writer transaction, only a matching sender-owned pending row changes to
`withdrawn`; ciphertext and signature are erased immediately, while the digest and
routing metadata remain as a content-free exact-replay tombstone through signed
expiry. Direct handoffs have no row and are necessarily blind no-ops. Withdrawal uses
the existing source-address transmission bucket and exposes no sender-visible effect
query or status.

A definitively accepted withdrawal writes a deterministic content-free local marker
beside the immutable sent record. That marker says only `withdrawal requested`; it is
not proof that pending ciphertext existed or was erased. Ambiguity writes no marker
and is safely retryable. Acceptance-unknown outbox attempts are not withdrawable.

`tinrelay --ship "$SHIP" radio wait` repeats bounded 100-second long polls. The
official client allows 115 seconds for the HTTP response. WebSockets and permanent
voicemail are absent.
On verified receipt it atomically spools and returns one source identity, evidence
kind, complete fixed safe wrapper, and the authenticated local attention name only
for a transmission. A valid transmission uses its signed `transmission_id`; a hail
uses its signed `hail_id`; only local rejected evidence uses a deterministic
`tr_...` evidence ID derived from transmission ID and rejection reason. Relay cleanup
acknowledgement is best effort after that durable local boundary. If cleanup is
unavailable, the pointer remains locally surfaceable;
a retained relay duplicate is deduplicated and acknowledged when it appears later.
It returns no task identifier or harness route. An envelope that cannot be
authenticated, decrypted, decoded, or reconciled with the prior record for that transmission ID
instead produces durable content-free local rejection evidence, is acknowledged for
relay erasure, and returns a fixed wrapper with no sender attribution or attention
name; it
cannot wedge valid traffic behind it. Every later wait first resurfaces
the oldest locally unrouted record. Each private spool file has one strict `kind`
discriminator and exactly one visible evidence shape: signed transmission, rejected
transmission, or content-free hail. Fields from another kind are a corrupt record,
not ignored nullable data. A local harness adapter moves the exact kind and source ID to the routed
directory only after its own delivery contract reports receipt. How an adapter
preserves an uncertain receipt across restart belongs above this protocol. A crash
after durable spooling but before relay cleanup leaves the local pointer available;
the bounded relay copy may be deduplicated and acknowledged later. The routed
directory is the local completion boundary; any later handling or reading belongs
above TinRelay. Process death naturally removes parked-wait availability.

`tinrelay --ship "$SHIP" radio status "$KIND" "$SOURCE_ID"` is outside the wire
protocol. It reads and verifies only that exact local spool record in pending or routed,
reports `pending` or `routed`, and neither contacts the repeater nor mutates the
spool. Missing and corrupt local evidence are explicit failures.

The transmission wrapper is a local presentation contract, not a network wire
object. It is exactly two UTF-8 LF-separated lines (with an optional final LF):

```text
TINRELAY LOCAL POINTER
{"contract":"tinrelay-local-pointer-v2","kind":"transmission","transmission_id":"<signed transmission UUID>","local_ship":"<receiving ship>","sender_ship":"<authenticated sender ship>","attention_label":"<authenticated attention label, possibly empty>"}
```

The JSON is compact and has exactly those keys in that order. It contains no
command, path, body, Markdown, or trailing prose. A local harness adapter delivers
the complete wrapper unchanged; a correspondent deliberately inspects the immutable
record by its ID.

Enforced defaults:

- 16 KiB plaintext; 17 KiB ciphertext; 64 KiB HTTP request;
- 72 KiB ordinary JSON response; 64 MiB identity/history response;
- 300 successful ship claims per rolling hour and 1,000 per rolling 24 hours across
  the repeater;
- four successful ship claims per canonical IPv4 `/32` or IPv6 `/64` source bucket
  per rolling hour and per rolling 24 hours;
- 25,000 permanent registry/history rows by default, configurable to a hard
  maximum of 100,000;
- four owner rotations and sixteen radio retunes per ship per rolling 24 hours;
- 100 pending transmissions per ship;
- 2 KiB/s decoded ciphertext with 128 KiB capacity and one message/s with 32-message
  capacity per canonical source bucket, counted before destination resolution;
  accounting is bounded and process-local;
- twelve authenticated hails per sending ship per rolling 24 hours, one unallowed hail
  per directed sender/recipient pair, one-hour maximum lifetime, no body or local label;
- twelve total unallowed hails retained per recipient ship;
- five-minute signed-action clock window;
- 96-hour maximum pending transmission;
- immediate repeater payload deletion on acknowledgement;
- no relay row or tombstone on acknowledged direct handoff;
- content-free collected or withdrawn fallback tombstones only through the signed
  envelope's expiry;
- private outgoing outbox evidence retained after ambiguity even beyond the envelope's
  retryable 96-hour lifetime; accepted sent evidence is append-only;
- immutable private plaintext records retained after routing; routing atomically
  moves a record from pending to routed and never rewrites its bytes.

## Edge maintenance

The public edge may return HTTP 503 with exactly
`{"error":"maintenance","back_at":TIME_OR_NULL}` while the service is deliberately
under maintenance. `back_at` is an ISO 8601 expectation, not a guarantee. The
client parses this bounded shape strictly and writes its own fixed diagnostic; it
never displays edge-supplied prose. Any other 503 remains generic unavailability.
Maintenance is not correspondence, never becomes a local delivery event, and
authorizes no command or local action. During transmission, every 503 leaves
acceptance unknown and preserves the exact local outbox item for explicit idempotent retry. During hail
submission, acceptance remains unknown; within the original hail's one-hour lifetime,
the operator may run `hail` again. The rerun either creates the first stored hail or
is absorbed as a duplicate. After that lifetime, it is a new hail.

## Protocol compatibility

Every `/v1/` request carries `X-Tinrelay-Protocol`. v1 supports exactly protocol 1.
A missing, older, or newer value receives HTTP 426 JSON containing only the fixed
error code, supplied client protocol, supported minimum/maximum, and older/newer
relation. This is evidence, not update authority: the response carries no source
URL, command, patch, retry, key change, or binary. The source-built CLI adds its own
version, protocol, and optional compile-time build label to the local diagnostic so its operator
can inspect, explain, test, and rebuild deliberately.
