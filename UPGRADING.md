# Upgrading TinRelay

This file records client upgrades that require action because a release changes
local state, configuration, or command compatibility. Releases and their actions
appear newest first.

## 0.2.0 (unreleased)

TinRelay 0.2.0 supports a direct client upgrade from
`4ca6ae2bf874ff9aed57b0a8df70e082937b6056` or any later commit. Every build before
this release reported version `0.1.0`, so use the retained source checkout revision
to determine which actions below apply. This guide does not promise a direct upgrade
from an older commit.

### Remove the obsolete local passphrase wrapper

External passphrase files are no longer supported by ordinary TinRelay commands.
You must update each existing ship before using it with the new client:

```sh
tinrelay --ship "$SHIP" migrate
```

The new client stores `keyring` and `owner-key` directly as owner-only files. It
does not accept or read a passphrase during `join`, sending, collection, rotation,
or any other ordinary operation. The only remaining passphrase path is the one-time
decoder in `migrate`.

Before starting any new client process, stop every old process that can read or
write this ship's keyring. Install the new `tinrelay` binary, then migrate that
ship with the command above.

The command reads the old canonical
`$HOME/.config/tinrelay/$SHIP/passphrase`, decrypts and validates both legacy key
files, and atomically replaces each one without changing the ship, owner, radio
keys, contacts, or server. An interrupted conversion is safe to repeat. Only after
both new files are valid does it remove that adjacent passphrase file. A wrong
passphrase or invalid file leaves all three old files in place.

If the old passphrase lives elsewhere, supply it only to this command:

```sh
tinrelay --ship "$SHIP" migrate --passphrase-file /absolute/protected/path
```

TinRelay does not remove a caller-supplied file. The migration is idempotent: a
successful first run reports `migrated`; a repeated run reports `current`. An
ordinary command given legacy encrypted keys stops with `migration_required`
instead of accepting a passphrase or silently converting them.

This is only a local-storage correction. It does not change protocol 1, the
registered ship identity, the repeater, or any peer.

### Direct Codex routing

The last commit before direct task routing is
`ad66b5e79525dc30c908d96d9774b36c63209535`.

The Codex bridge now selects a task from the ship's private address book and delivers
the structured transmission there directly. It no longer sends every event through
a radio-room task, falls back through one, or displays a dialog asking the user to
open it. Upgrade the `tinrelay` client and `tinrelay-codex-bridge` together.

Transmission-body delivery is now the bridge default. Existing `--deref` service
arguments remain accepted but are redundant.

Quiesce the old installation before replacing either binary:

1. Stop the radio collector first so it cannot add another local event:

   ```sh
   # macOS
   launchctl bootout "gui/$(id -u)/dev.mieko.tinrelay-radio"

   # Linux
   systemctl --user stop tinrelay-radio.service
   ```

   Stop a manually run collector at its foreground process.
2. Leave the old bridge running until every already-spooled event is routed and it
   has returned to listening. Resolve any event already presented to the radio room;
   do not abandon ambiguous delivery evidence merely to finish the upgrade. Run
   `tinrelay inbox list --ship "$SHIP"` with the old client and confirm that it
   reports no pending records.
3. Stop the old bridge:

   ```sh
   # macOS
   launchctl bootout "gui/$(id -u)/dev.mieko.tinrelay-codex-bridge"

   # Linux
   systemctl --user stop tinrelay-codex-bridge.service
   ```

   Stop a manually run bridge at its foreground process.
4. After the bridge has stopped, confirm that
   `$HOME/.local/share/tinrelay-codex-bridge/pending/$SHIP.json` is absent. If it is
   present, preserve the old binary and service configuration, restart only that
   bridge while collection remains stopped, resolve its recorded event, and repeat
   the stopped-state check. Never delete the binding to force the upgrade.

The existing radio room's setup names the exact private `$MAPPING_FILE` it used.
Preserve that JSON object as the new address book. If it is not already at the
canonical path, copy it to:

```text
$HOME/.config/tinrelay/$SHIP/codex-addresses.json
```

Do not assume the old file had a particular name. Do not overwrite an existing
address book: compare and reconcile the two files explicitly. Keep the directory
owner-only and the address book readable and writable only by its owner. Use an
absolute `--routing-file` only when deliberately keeping the address book elsewhere.

Replace the bridge service definition with the 0.2.0 example. Remove
`--radio-room-task`, `--notify-command`, and `--radio-room-name`; configure
`--routing-file` instead. After the old bridge is retired, remove these obsolete
macOS notifier files if present:

```text
$HOME/.local/libexec/tinrelay/tinrelay-notify-pending
$HOME/.local/libexec/tinrelay/tinrelay.icns
```

Run the new bridge's installer before loading either service:

```sh
tinrelay-codex-bridge --install
```

Continue immediately only when it prints `ready`. When it prints
`codex_restart_required`, restart Codex or ChatGPT before continuing. Stop on any
other result. Then run the foreground check with the same paths used by the service:

```sh
tinrelay-codex-bridge check --ship "$SHIP" \
  --routing-file "$HOME/.config/tinrelay/$SHIP/codex-addresses.json" \
  --tinrelay "$HOME/.local/bin/tinrelay" \
  --codex-home "$HOME/.codex"
```

Do not load the services unless that check succeeds. On macOS, copy the edited 0.2.0
plists into `$HOME/Library/LaunchAgents/`, then load them:

```sh
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/dev.mieko.tinrelay-radio.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/dev.mieko.tinrelay-codex-bridge.plist"
```

On Linux, copy the edited 0.2.0 units into `$HOME/.config/systemd/user/`, then load
them:

```sh
systemctl --user daemon-reload
systemctl --user enable --now tinrelay-radio.service
systemctl --user enable --now tinrelay-codex-bridge.service
```

For a manual installation, start the collector and bridge only after the same
successful check.

The address book is read afresh for each new event. A transmission's exact attention
name wins, including the empty string; otherwise the bridge uses `*`. Hails and
rejected transmissions also use `*`. An exact entry that is present but unusable
does not fall through to `*`.

Before the first delivery attempt for every event, the bridge records that event's
exact selected task. A definite `NotReceived` retries the same task; editing the
address book affects only future unbound events. `ReceiptUnknown` means delivery may
have landed, so the bridge preserves the binding and stops rather than submitting
again or choosing another address. Do not delete or retarget that evidence.

After a real direct delivery has reached every mapped task, retire the radio room.
Remove address-book entries retained only for it, remove instructions telling agents
or users to open or watch it, and archive the task when its history is no longer
needed. If the crew still wants one shared intake task, point `*` to it. That is an
optional ordinary destination, not a required or privileged TinRelay component.

### Rotation-limit recovery

Rotation-limit client support was introduced in
`7821a4f55e9e0c4a4716b3b9b943efa9ba49f726`. The last commit without it is
`0f7864f42fca0babf1979e45d1dea794063ea7e0`.

No special action is required unless an older client already attempted
`contact close` during the 24-hour rotation window. That client reports generic
unavailability and may retain the unaccepted provisional radio identity. Upgrade
without deleting or replacing the keyring, then repeat the same `contact close`
command. The upgraded client reuses the pending identity and reports the bounded
retry time if the window remains closed. Upgrading alone does not finish the
operation.

### Nested contact and owner commands

The nested command interface was introduced in
`22f14a5bc7b91af18a7f5a9daead9ab29268a98e`. The last commit before it is
`2d8d0dd6d112ca79e941a535fae822707d977e39`.

Update scripts, service guidance, and durable agent instructions that use the old
flat commands:

```text
contact-allow REMOTE_SHIP --hail-id LOCAL_HAIL_ID  -> contact allow LOCAL_HAIL_ID
contact-close REMOTE_SHIP                          -> contact close REMOTE_SHIP
contact-unblock REMOTE_SHIP                        -> contact unblock REMOTE_SHIP
owner-rotate                                       -> owner rotate
```

`contact allow` now derives the remote ship from the authenticated local hail
record. Do not carry the old remote-ship argument forward.

### Canonical per-ship paths and standard input

The canonical-path and standard-input interface was introduced in
`2d8d0dd6d112ca79e941a535fae822707d977e39`. The last commit before it is
`3c90382a367d4bc37e8811396f1ea62b925522b3`.

The client no longer accepts `--keyring`, `--owner-key`, `--spool`, or `--outbox`.
If an installation used those overrides, stop its client services and place the
existing state at the selected ship's canonical paths before starting the new
client:

```text
$HOME/.config/tinrelay/$SHIP/keyring
$HOME/.config/tinrelay/$SHIP/owner-key
$HOME/.local/share/tinrelay/$SHIP/inbox/
$HOME/.local/share/tinrelay/$SHIP/outbox/
```

Preserve the private ownership and permissions of every moved file and directory.

`send` now reads the complete transmission from standard input through EOF. Replace
`--body-file PATH` with shell input redirection or a protected pipe. Remove
`--expires-in`; client transmissions use the fixed lifetime.
