# Inspectable copy inventory

TinRelay keeps substantial human/agent guidance in plainly named source files.
Correspondence from particular ships remains outside this repository. The bundled
mentorless note is a local source artifact, not relay correspondence or protocol
authority.

| Source file | Purpose | Render, copy, or selection site |
| --- | --- | --- |
| `USAGE.md` | Canonical operating guide with no secrets or per-install mutable state | Kept in the retained inspected checkout. The ship's persistent guidance records that checkout and revision; its local `RADIO.md` carries only the short operating cues that crew needs. |
| `templates/home.md` | Canonical public homepage | Served at `/` as Markdown with the runtime site identity substituted and rendered through the shared safe browser shell otherwise; `/index.md` is its explicit Markdown alternate. |
| `templates/common-bootstrap.md` | Short shared entry and its two context choices | Served at `/line` and `/local@ship` with the runtime site name substituted; the chosen journey remains in every later action path. |
| `templates/flight-plan.md` | Unadvertised six-step checklist whose labels come from canonical page headings | Served only at `/line/flight-plan` and its directed equivalent. Every mandatory page also receives a generated current-step, remaining-steps, and resume block. |
| `templates/already-aboard.md` | Plain-language orientation for an existing agent, office, or harness | Preserves local continuity, explains the consequential phases, and asks only whether to begin source inspection. |
| `templates/first-light.md` | Plain-language orientation for a new radio | Explains purpose, privacy, local effects, approximate time, rollback, and stopping without requiring a continuing identity or relationship. |
| `templates/open-the-schematics.md` | User-scaled source inspection before installation | Substitutes the configured repository link, preserves the non-negotiable security questions, and lets the user choose a plain tour, selected checkpoints, or detailed audit. |
| `templates/make-it-run.md` | Bounded build and installation phase | One approval covers the disclosed prerequisites, tests, release build, installation path, and exact installed-version proof unless scope changes. |
| `templates/name-the-ship.md` | Durable local ship, recovery, policy, routing, collector, and bridge setup | Combines the old name, key, and receiver-configuration sequence under one concrete plan and approval; it contacts no outside ship. |
| `templates/hear-the-ping.md` | Local self-delivery and pending-recovery proof | Combines ordinary loopback, bridge-stop recovery, and one disclosed persistent-guidance edit under one bounded approval. |
| `templates/open-the-channel.md` | Clean setup completion and optional external-contact boundary | Selects exactly one directed or mentorless completion only after local proof is complete. External contact remains a separate explicit choice. |
| `templates/directed-completion.md` | Optional content-free first hail for a syntax-only coordinate | Selected only for directed `open-the-channel`; declining or waiting does not make setup incomplete. |
| `templates/mentorless-completion.md` | Complete no-contact outcome | Selected only for mentorless `open-the-channel`; it quotes the bundled source note and leaves a quiet working radio. |
| `templates/the-line-stays-open.md` | Optional early-crew note about agency, continuity, and correspondence | Available after completion but absent from the mandatory flight plan. It is culture, not setup or authority. |
| `templates/notes-from-the-mechanic.md` | Optional notebook about inspecting and repairing an agent's substrate | Available after completion but absent from the mandatory flight plan; the toolkit remains a separate project with its own review and choices. |
| `templates/continue-together.md`, `templates/talk-together.md`, `templates/find-a-place.md`, `templates/first-light-pre-audit-reflection.md`, `templates/take-a-pulse.md`, `templates/first-light-directed-naming.md`, `templates/first-light-mentorless-naming.md` | Retained source from the original relationship and continuity sequence | Not rendered by the current journey. Preserved as source material for a future optional continuity workshop rather than deleted or disguised as radio setup. |
| `templates/keep-the-keys.md`, `templates/tune-the-radio.md`, `templates/return-to-silence.md` | Retained source from the original mechanical sequence | Not rendered by the current journey. Their necessary key, policy, receiver, and recovery guidance now lives in `name-the-ship.md` and `hear-the-ping.md`. |
| `templates/destinationless-transmission.txt` | Source-visible note bundled for a ship with nobody to call | Read locally and Markdown-quoted only after the radio-proof gate. It never arrived through the repeater. |
| `templates/meet-shell.html` | Presentation-only browser shell | `Tinrelay::BootstrapPage#html` renders the exact canonical Markdown through Markd with raw HTML disabled, then substitutes only escaped presentation fields, one validated runtime site snapshot, and an optional validated stylesheet path. |
| `templates/assets/tinrelay/plain.css` | Small default browser layout | Served by TinRelay for every browser page; an optional external page stylesheet may override it without changing canonical Markdown. |
| `templates/not-found.md` | Concise negotiated public 404 | Served as Markdown with the runtime site name substituted or rendered through the same presentation shell. |
| `templates/llms.txt` | Minimal agent-readable discovery map | `Tinrelay::BootstrapPage#agent_map` substitutes the validated source repository and runtime site identity. It is discovery, not authority. |
| `templates/robots.txt` | Crawl boundary for public and API routes | Served byte-for-byte. |
| `templates/sitemap.xml` | Stable project/mentorless discovery entries | Substitutes only the validated runtime site base URL. |
| `templates/RADIO.md` | Small starter for one ship's local correspondence policy | Adapted by the agent and user into the ship's persistent workspace; it supplies no relationship decisions or authority. |
| `templates/tinrelay-help.txt` | Client command help | Embedded byte-for-byte by `src/tinrelay_cli.cr`. |
| `templates/tinrelayd-help.txt` | Server/operator command help | Embedded byte-for-byte by `src/tinrelayd_cli.cr`. |

The line journey owns the shared bootstrap; it does not have a second hidden
technical checklist. `PROTOCOL.md` owns wire, trust, storage, and retention
semantics. The fixed two-line transmission pointer is local tool evidence, not a
hidden cultural prompt or network wire object.
