# AWDL Guard

AWDL Guard is a Mac menu bar app that holds Apple Wireless Direct Link (AWDL, the
`awdl0` interface behind AirDrop and Continuity) down while a game or another app you
choose is in the foreground, and lets it back up when you switch away.

AWDL shares the Wi-Fi radio and can hop channels in the background, which some people
see as brief latency spikes in online games and game streaming. Whether AWDL causes a
particular stutter isn't something this app can prove; it shows exactly what it did
and what it observed so you can judge.

Requires macOS 26 or later.

## Using it

AWDL Guard lives in the menu bar. It starts in the background, at login or from Finder,
without taking focus from the app you're using. Its menu holds the mode, the current
state, the app in the foreground with its switch, and Open at Login. The mode picker
chooses:

- **Automatic**: suppress on Wi-Fi while a game or an app with a rule is in the foreground.
- **Allow**: never suppress.
- **Suppress**: always suppress.

"AWDL Off" with a green antenna appears only after the helper has read `awdl0` back and
confirmed it is down. If macOS turns it back on, the helper turns it off again and the
menu counts it. Installing, approving or repairing the helper is offered in the same card
when it's needed. Approval is the AWDL Guard switch under **Allow in the Background** in
System Settings › General › Login Items, not the Open at Login list on the same page.

**App Rules…** opens the app's window, centred on the current screen. AWDL Guard shows in
the Dock only while that window is open. Holding Option in the menu turns Quit into
**Hide Menu Bar Item**; AWDL Guard keeps running in its mode, and opening it from Finder
shows the item again. Dragging the item out of the menu bar quits the app.

### App rules

Games are detected from their Info.plist, the same keys macOS uses for Game Mode
(`LSApplicationCategoryType = public.app-category.games` or `LSSupportsGameMode`). App
rules cover everything else:

- A rule that's on suppresses AWDL while that app is in the foreground.
- A rule that's off never suppresses for that app, even if it's a game.

The App Rules window lists rules for running apps first, then the rest, each group
alphabetical.

Mac apps are identified by bundle identifier. **CrossOver** runs Windows games from a
temporary folder whose name changes on each launch, with no bundle identifier, so a
Windows game is identified by its `.exe` file name (case-insensitive). The quickest way to
add one is to start the game, open the menu and flip the switch under **App in
foreground**, which saves a rule. **+** in the App Rules window also lets you pick the
`.exe` in its bottle.

## How it works

| Part | Owns |
|---|---|
| `AWDLGuardKit/HelperInterface` | The XPC messages (`SuppressionRequest` and `InterfaceObservation`) and the helper's table of what each session asks for (`SessionRequests`). |
| `AWDLGuardKit/GuardPolicy` | Rules, the `Decision` (suppress or not, and why) and the `Status` shown to the user. Tested with `swift test`. |
| `AWDLGuardHelper` | The privileged launchd daemon. It sets `awdl0`'s `IFF_UP` flag and watches the routing socket. |
| `AWDLGuard` | The menu bar app: inputs (mode, rules, frontmost app, Wi-Fi), the helper connection and the UI. |

**Helper.** Registered with `SMAppService` as a bundled launch daemon, so removing the
app removes it. It accepts connections only from the AWDL Guard app signed by the same
team (`XPCPeerRequirement.isFromSameTeam`). launchd starts it when the app connects.

Each connected app session asks for `awdl0` to be held down or not, and the request lasts
until the session ends. `awdl0` is held down while any session asks for it, so a second
user, or a second copy of the app, can't release it under the other; a session that
allows AWDL while another holds it shows "Kept off for another user". When the last
session ends, or launchd stops the helper with SIGTERM (unregistering, turning it off under
Allow in the Background, shutdown), the helper restores `awdl0` and exits, so it never runs unseen.
Everything in the helper runs on one serial queue.

The file `/var/run/io.reefsoft.AWDLGuard.Helper.suppressing` is the one record that the
helper owes `awdl0` a bring-up. It is written before `awdl0` goes down and removed only
once `awdl0` is back up, so a failed bring-up is retried on the next release, at exit and
by the next helper. If the file can't be written the helper doesn't suppress, and the
menu shows "Couldn't Turn Off". A helper that starts and finds the file brings `awdl0` up,
undoing a crashed helper's change; without it, it leaves `awdl0` as macOS has it. launchd
starts the helper only when the app connects, so if the app and the helper both die, AWDL
stays off until AWDL Guard is opened again or the Mac restarts. `/var/run` is cleared at
boot, when `awdl0` starts up anyway.

Suppression is reactive: when macOS brings `awdl0` up, the routing socket reports it and
the helper takes it down again, so there is a brief window each time. Each one is counted
as a reactivation and shown in the menu. If the routing socket fails for good, the menu
shows "Not Watching AWDL" with Repair, which restarts the helper and its socket.

**Connection.** Driven by events, with no heartbeat. XPC ends the app's session when the
helper exits, crashes or is stopped. If the session had answered, the app rereads the
registration and opens a new session at once, which launches the helper again, and sends
its current decision. A session that ends before ever answering shows "Helper Not
Responding" and is retried after 1 second, doubling up to 30. The helper pushes every
change to `awdl0`, and the app sends a request whenever its decision changes. A request
unanswered for 10 seconds shows "Helper Not Responding"; that timer uses the suspending
clock, so time asleep doesn't count. Replies and pushes from an ended session are ignored.

SMAppService posts nothing when the helper is approved in System Settings, so while it
waits for approval the app rereads the registration every 2 seconds, and also whenever
the menu opens.

Turning AWDL Guard off under Allow in the Background makes macOS stop the
helper and also force quit the app (`forceQuitAppWithURL` in Background Task
Management). The helper restores `awdl0` on its SIGTERM either way. macOS waits for the
app's child processes first, such as the Open panel service left by Add App, so the quit
can come more than a minute later.

**Identity.** The helper's bundle identifier, launchd label and Mach service name are all
the app's bundle identifier plus `.Helper` (`HelperIdentity`); the launchd plist in
`AWDLGuardHelper/` must match.

## Building

Open `AWDLGuard.xcodeproj` and build the `AWDLGuard` scheme. Signing uses the ReefSoft
team; the helper's connection check depends on both binaries being signed by the same team.

Policy tests: `cd AWDLGuardKit && swift test`.

## Credits

Based on [AWDL Control](https://github.com/james-howard/AWDLControl) by James Howard,
after an idea from [awdlkiller](https://github.com/jamestut/awdlkiller) by James Nugraha.
MIT licensed; see `LICENSE.txt`.
