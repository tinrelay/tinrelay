# TinRelay source guidance

TinRelay is both a small encrypted-radio protocol and source that capable agents
are expected to inspect before they trust or build it. Names, comments, file
boundaries, help text, and tests all teach the system. Keep the implementation
literal enough that a new reader can recover its safety story in one complete
reading.

It is also a carefully authored bootstrapping prose path and an experimental art
project. Those are product surfaces, not packaging generated around the radio.
Protocol behavior, language, and visual direction must remain truthful to one
another, but authority to change code does not confer authority to rewrite the
journey or recast its art. Report cross-surface consequences to their owners
instead of absorbing another discipline into an implementation task.

## Begin with the product

Read `README.md` and `PROTOCOL.md`, then the source and tests governing the
change. Read the relevant files under `templates/` for meet-flow or local-bridge
work. For service packaging, also read `OPERATIONS.md`, `Dockerfile`, the
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
security boundaries. Do not add tests that lock in prose with literal sentence
fragments; the source-owned Markdown is editorial product copy, not a snapshot
API.

Canonical meet guidance lives in Markdown under `templates/`. Browser HTML is a
rendering of those same bytes. Do not duplicate that prose in Crystal, parallel
templates, or tests. Keep the JS-less path journey working in both Markdown and
HTML representations.

TinRelay's public voice is authored product work owned by Mike and Vera. Anonymous
implementation, review, research, and ticket agents must not write, rewrite,
shorten, normalize, or make opportunistic “necessary” edits to body copy,
onboarding prose, journey templates, README/usage language, help text, headings,
link captions, or bridge guidance. When behavior makes existing words false
or incomplete, report the exact factual delta, affected surface, and any structural
or layout consequence to Mike and Vera; they choose the language. An agent may
mechanically apply exact replacement text only when Mike or Vera supplies that text
and explicitly asks the agent to place it. Code authority, correctness work, or a
documentation-update requirement does not confer authorship of the prose.

Keep handwritten Crystal source at 100 columns or fewer. This applies to
`src/`, `spec/`, and Crystal programs under `script/`; use
`script/check-source-width` rather than relying on the formatter to catch long
strings, SQL, or test data.

Run focused checks first, then the relevant broad gates:

```sh
script/check-source-width
crystal tool format --check src spec
crystal spec
shards build tinrelay tinrelayd --release --warnings=all --error-on-warnings
```

When container behavior changes, also run `script/verify-container`; it is the
real Linux image/runtime proof. Keep test databases, keys, servers, and processes
isolated from user-owned state and default ports.

## Documents have separate jobs

- `README.md` is the brief public orientation, not a second protocol manual.
- `PROTOCOL.md` owns wire, trust, storage, limits, and retention.
- `USAGE.md` is the concise far-context guide installed with a claimed ship.
- `OPERATIONS.md` owns one-node service operation and recovery.
- `TEMPLATES.md` inventories every source-owned prompt and public copy surface.
- `SECURITY.md` owns private vulnerability-reporting guidance.

Update the owning document when behavior changes. Remove obsolete documents and
duplicated explanations instead of leaving competing stories for the next agent
to reconcile.
