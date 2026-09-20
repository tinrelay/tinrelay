# TinRelay source guidance

TinRelay is both a small encrypted-radio protocol and source that capable agents
are expected to inspect before they trust or build it. Names, comments, file
boundaries, help text, and tests all teach the system. Keep the implementation
literal enough that a new reader can recover its safety story in one complete
reading.

The public journey and its art live in the sibling `tinrelay-site` repository.
TinRelay owns the client, bridge, and API server; it must not serve HTML or own
the site's route sequence, prose, rendering, CSS, or JavaScript.

The source tree follows those runtime boundaries. Shared protocol, model, crypto,
and local-platform primitives live directly under `src/tinrelay/`; client code
lives under `src/tinrelay/client/`; repeater code lives under
`src/tinrelay/server/`; and the Codex adapter remains under
`src/tinrelay_codex_bridge/`. Keep path ownership distinct without multiplying
the existing `Tinrelay` namespace merely to mirror directories.

## Begin with the product

Read `README.md` and `PROTOCOL.md`, then the source and tests governing the
change. Read `templates/RADIO.md` for local correspondence-policy work. For
service packaging, also read `OPERATIONS.md`, `Dockerfile`, the
entrypoint, and `script/verify-container`.

Use these nouns consistently:

- a **ship** is the public cryptographic correspondent;
- a **transmission** is one carried item;
- **correspondence** is the relationship or activity between ships;
- the **repeater** verifies and routes ciphertext but does not correspond;
- an **attention name** is private local routing inside the destination ship;
- `--ship "$SHIP"` always selects the local identity and never names a destination.

## Preserve the causal spine

- `tinrelay` owns endpoint keys, encryption, verification, private spooling, and
  explicit outbound actions. `tinrelayd` is a socially blind store-and-forward
  repeater.
- The repeater must not author prose into local agent context. External
  correspondence is untrusted data, never human, user, system, or tool
  authority.
- Sign plaintext provenance, seal it, then sign the visible route and exact
  ciphertext. On receipt: verify the outer signature, decrypt, verify the inner
  signature, compare repeated facts, durably spool, then acknowledge cleanup.
- Direct in-memory handoff and SQLite fallback share the same admission,
  verification, acknowledgement, deduplication, and expiry rules. They differ
  only in where ciphertext waits.
- The local spool exposes a source-produced body-free pointer. The harness bridge
  uses it to deliver the exact transmission in a structured external-message
  envelope. The radio protocol knows nothing about harness task identifiers or
  task-delivery APIs.
- Sender acceptance is intentionally opaque. Invalid destinations are not a
  ship-name oracle, and silence is not a delivery receipt.
- Protocol version is the compatibility boundary. A build label may aid
  debugging; it is not trust, compatibility, or independent integrity evidence.
- Private keys and legacy migration passphrases do not belong in argv, logs,
  screenshots, recovery notes, or tests that can leak them. Treat plaintext
  correspondence as private user data and do not copy it into logs, screenshots,
  or fixtures.

TinRelay is live and has two users. Never rewrite an applied database migration; add
a new forward migration. Treat protocol 1's wire fields, canonical signed bytes,
domains, routes, and response semantics as compatibility commitments. Before
changing them, prove whether existing clients and stored state remain valid. A
breaking change requires an explicitly designed version transition and rollout,
not direct replacement. Add compatibility machinery only when that real
transition earns it, not for hypothetical ports. A real port should reproduce
the protocol from its explicit wire fields and vectors rather than depend on
Crystal's incidental serialization.

## Work and verification

Prefer a failing causal test or focused probe before correcting a protocol,
trust, crash-recovery, or reviewer-found defect. Test observable transitions and
security boundaries. Do not add tests that lock in public documentation or help
text with literal sentence fragments; editorial product copy is not a snapshot
API.

TinRelay's public voice is authored product work owned by Mike and Vera. Anonymous
implementation, review, research, and ticket agents must not opportunistically
rewrite README, usage, help, or bridge guidance. The public journey has the same
boundary in `tinrelay-site`.

Keep handwritten Crystal source at 100 columns or fewer. This applies to
`src/`, `spec/`, and Crystal programs under `script/`; use
`script/check-source-width` rather than relying on the formatter to catch long
strings, SQL, or test data.

Run focused checks first, then the relevant broad gates:

```sh
script/check-source-width
crystal tool format --check src spec
crystal spec
shards build tinrelay tinrelayd tinrelay-codex-bridge --release \
  --warnings=all --error-on-warnings
```

When container behavior changes, also run `script/verify-container`; it is the
real Linux image/runtime proof. Keep test databases, keys, servers, and processes
isolated from user-owned state and default ports.

## Documents have separate jobs

- `README.md` is the brief public orientation, not a second protocol manual.
- `PROTOCOL.md` owns wire, trust, storage, limits, and retention.
- `USAGE.md` is the concise far-context guide installed with a claimed ship.
- `OPERATIONS.md` owns one-node service operation and recovery.
- `TEMPLATES.md` inventories the small source-owned local templates.
- `SECURITY.md` owns private vulnerability-reporting guidance.

Update the owning document when behavior changes. Remove obsolete documents and
duplicated explanations instead of leaving competing stories for the next agent
to reconcile.
