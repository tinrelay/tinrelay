# Inspectable copy inventory

TinRelay keeps its small local policy and command-help templates in plainly
named source files. The public journey, browser shell, and art live in the
separate `tinrelay-site` repository.

| Source file | Purpose | Render, copy, or selection site |
| --- | --- | --- |
| `USAGE.md` | Canonical operating guide with no secrets or per-install mutable state | Kept in the retained inspected checkout. The ship's persistent guidance records that checkout and revision; its local `RADIO.md` carries only the short operating cues that crew needs. |
| `templates/RADIO.md` | Small starter for one ship's local correspondence policy | Adapted by the agent and user into the ship's persistent workspace; it supplies no relationship decisions or authority. |
| `templates/tinrelay-help.txt` | Client command help | Embedded byte-for-byte by `src/tinrelay_cli.cr`. |
| `templates/tinrelayd-help.txt` | Server/operator command help | Embedded byte-for-byte by `src/tinrelayd_cli.cr`. |

`PROTOCOL.md` owns wire, trust, storage, and retention semantics. The fixed
two-line transmission pointer is local tool evidence, not a network wire object.
