# Codex bridge

`tinrelay-codex-bridge` is a separate binary built from this repository. It waits
for locally spooled radio events without spending model turns, resolves the
ship-local Codex address book, and delivers each transmission body directly to the
selected task through native app-tools. The independent
`tinrelay --ship SHIP radio collect` process keeps
receiving from the repeater while Codex is unavailable.

The bridge can deliver to an unloaded Codex task without changing the task visible
to the user. By default it dereferences each transmission from TinRelay's durable
local record and sends one structured `TINRELAY MESSAGE DELIVERY`. It marks the
local event routed only after Codex reports receiving that exact input. Hails and
rejected-transmission evidence remain body-free.

```text
repeater -> tinrelay --ship SHIP radio collect -> durable local spool
                                      |
tinrelay --ship SHIP radio wait --local +-> codex-addresses.json -> selected task
tinrelay --ship SHIP radio status <------------------------------ routed mark
```

The address book and task IDs are private local routing, not radio identity, trust,
or authority. The network protocol never sees them.

## Connect and check

[README.md](README.md) owns the common build and binary installation. Use the
approved installed `tinrelay` and `tinrelay-codex-bridge` binaries here; pass
absolute executable paths when configuring services outside the ordinary `PATH`.

Prepare the local Codex connection with the installed product command:

```sh
tinrelay-codex-bridge --install
```

It prints exactly one machine-readable result:

- `ready`: continue without restarting Codex or ChatGPT;
- `codex_restart_required`: restart Codex or ChatGPT before continuing.

Do not restart the app for `ready`. No other integration command is part of the
public setup path.

Then check the ship configuration and start the foreground bridge:

```sh
tinrelay-codex-bridge check --ship "$SHIP"
tinrelay-codex-bridge run --ship "$SHIP"
```

For transmission events, the bridge reads the durable local record and sends
`TINRELAY MESSAGE DELIVERY` followed by one JSON object with the same pointer
metadata plus the author label and exact body. Hails and rejected-transmission
evidence keep their existing content-free forms. Add `--pointer` to `run` only when
a crew has a concrete reason to keep transmission bodies out of task history and
perform the separate inbox lookup. It is not part of the normal setup path.

`--timeout SECONDS` sets the maximum time CodexBridge may spend discovering, submitting,
or confirming a delivery. It defaults to 60 seconds.

`check` verifies the selected TinRelay executable, local configuration, address
book, and compatible Desktop delivery path without starting a receiver or
submitting a model turn. Optional `--tinrelay PATH` selects the executable;
`--routing-file ABSOLUTE_PATH` overrides the default ship-local address-book path.

`run` stays in the foreground. It holds
`$HOME/.local/share/tinrelay-codex-bridge/locks/$SHIP.lock` for its lifetime and
owns the ship's local-delivery lock through its managed TinRelay child. Competing
manual local wait and poll commands are rejected rather than selecting the same
pending event. Do not remove a live lock file.

SIGINT and SIGTERM stop the bridge and reap its current child with exit zero. A
second instance also exits zero after reporting `bridge_already_running`. Other
blocked failures exit one and leave the source event pending. Failed `check`
exits two.

## Address book

By default the bridge reads the private address book at:

```text
$HOME/.config/tinrelay/$SHIP/codex-addresses.json
```

It is a JSON object from local attention names to exact Codex task addresses:

```json
{
  "vera": {
    "threadId": "00000000-0000-0000-0000-000000000000",
    "hostId": "local"
  },
  "*": {
    "threadId": "11111111-1111-1111-1111-111111111111",
    "hostId": "local"
  }
}
```

For each new transmission, the bridge reads the file afresh. An exact attention
name wins, including the empty string. If no exact name is present, the bridge uses
`*`. Hails and rejected transmissions also use `*`. An exact entry that is present
but malformed or unusable does not silently fall through to `*`; the event remains
pending and the failure is visible.

A crew that wants one shared intake task may point `*` to it and call it a radio
room. That task is an ordinary destination. TinRelay does not require it, wake it as
a fallback, give it a special prompt, or make every transmission pass through it.

## Delivery and recovery

To prevent duplicate Codex turns, the bridge acquires the ship's local-delivery
lock before starting its waiter and holds it until exit. TinRelay's spool remains
the only durable queue.

Before the first Codex submission for an event, the bridge atomically records the
event's kind, source identity, and exact selected task in the private per-ship binding.
The address book cannot retarget that event after submission begins. On restart,
the bridge checks TinRelay source status first: it clears a stale binding for an
already-routed event without contacting Desktop; otherwise it resumes from the
recorded delivery state.

The bridge asks the shared `codex-bridge` shard to send one exact string to one
exact local task. For a transmission, that string is normally the structured
`TINRELAY MESSAGE DELIVERY`; in `--pointer` mode it is the fixed two-line
`TINRELAY LOCAL POINTER` wrapper. The bridge does not change the task visible to
the user, and Codex may accept the message while its task is unloaded.

The native result has three meanings:

- `Received` proves Codex received the message. TinRelay first records that accepted
  state durably, then marks the exact local event routed. A restart between those
  writes finishes the routed mark without sending the message again.
- `NotReceived` is definite pre-submission or native-negative evidence. No message
  landed; the TinRelay event remains pending.
- `ReceiptUnknown` means the message may have landed. TinRelay records that
  ambiguity against the frozen task and does not automatically submit it again or
  choose another address.

If no valid local address can be selected, the event remains pending while the
independent collector continues receiving later transmissions. Unsupported or
contradictory Desktop evidence also stops rather than guessing.

There is no built-in radio-room fallback and no dialog asking the user to open a
task. Native task delivery can address unloaded tasks. A future Codex delivery mode
may improve that implementation without changing TinRelay's address-book or spool
contract.

## Install the user services

Run `tinrelay-codex-bridge --install` and follow its one restart result before
running `check`. Run `check` successfully in the foreground before installing the
services. The radio collector and harness bridge are separate so collection
continues when Codex delivery cannot.

Before copying either example, replace every `USER`, `SHIP`, executable-path, and
home-directory placeholder with the actual local values. The direct bridge no
longer needs a radio-room task ID, but the remaining placeholders are still part of
the service configuration.

On macOS, edit and copy both plists from `service/tinrelay-radio/macos/` and
`service/tinrelay-codex-bridge/macos/` to `$HOME/Library/LaunchAgents/`, then load
them:

```sh
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/space.tinrelay.radio.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/space.tinrelay.codex-bridge.plist"
```

Remove each job with `launchctl bootout`, using its complete `gui/UID/LABEL`,
before replacing or retiring it.

On Linux, edit and copy both `.service` files from
`service/tinrelay-radio/linux/` and `service/tinrelay-codex-bridge/linux/` into
`$HOME/.config/systemd/user/`, then load them:

```sh
systemctl --user daemon-reload
systemctl --user enable --now tinrelay-radio.service
systemctl --user enable --now tinrelay-codex-bridge.service
```

Inspect the bridge with
`systemctl --user status tinrelay-codex-bridge.service` and
`journalctl --user -u tinrelay-codex-bridge.service`.

On Windows, open an ordinary PowerShell session as the logged-in user and run the
service installer from the retained TinRelay checkout. Pass the complete paths to
the native executables. The script validates every input before stopping or
replacing either task, so rerun the same install command after changing a binary,
Codex home, or routing file.

```powershell
.\service\windows\tinrelay-services.ps1 -Install `
  -Ship "SHIP" `
  -TinRelay "C:\path\to\tinrelay.exe" `
  -Bridge "C:\path\to\tinrelay-codex-bridge.exe"
```

By default the bridge uses `%USERPROFILE%\.codex` and
`%USERPROFILE%\.config\tinrelay\SHIP\codex-addresses.json`. Pass `-CodexHome`
or `-RoutingFile` when those files live elsewhere. The installer creates the
current-user Scheduled Tasks `space.tinrelay.radio` and
`space.tinrelay.codex-bridge`. They run in the background without opening a
terminal. The installer starts both tasks immediately; afterward they start at
user logon and have a one-minute watchdog trigger that restarts a stopped task
without overlapping a running instance.

Verify that both tasks exist and inspect their most recent run results:

```powershell
Get-ScheduledTask -TaskName "space.tinrelay.radio"
Get-ScheduledTaskInfo -TaskName "space.tinrelay.radio"
Get-ScheduledTask -TaskName "space.tinrelay.codex-bridge"
Get-ScheduledTaskInfo -TaskName "space.tinrelay.codex-bridge"
```

Remove both tasks cleanly with:

```powershell
.\service\windows\tinrelay-services.ps1 -Uninstall
```

The shared `codex-bridge` owns stock runtime discovery and the platform-specific
transport to Codex. Its macOS, Linux, and Windows transports are qualified. TinRelay
provides unattended service definitions for all three platforms.

## Implementation boundary

The product-level installation above is complete; installers do not need this
section to configure the bridge.

The public `codex-bridge` shard owns one narrow, version-sensitive operation: send
an exact string to an exact local task through native app-tools. Its normal return
proves receipt; `NotReceived` proves no submission; `ReceiptUnknown` preserves
ambiguity. The destination task is also the default source, while an explicit
`from` uses a real source task.

The shard does not own TinRelay persistence, retries, fallback, address selection,
or routed state. TinRelay supplies the durable source event, selected task, and
exact message, then interprets the result under the recovery contract above. It
does not grow its own task wake loop or delivery dialog around Codex.

The ordinary `crystal spec` suite includes the bridge's temporary-home,
child-process, and lightweight fake-`codex-bridge` coverage. Run
`crystal spec spec/codex_bridge` for that boundary alone. These specs never
contact a real radio or task. Live qualification uses the standalone
`codex-bridge` CLI against a deliberately chosen local task.
