# Developing AWDL Guard

How AWDL Guard is built, how it works, and how a release is made. The README covers using it.

## Building

You need Xcode 27.2 or later. The project uses Xcode's JSON project format, which older
versions can't open.

1. Open `AWDLGuard.xcodeproj`.
2. Set your own team for the project, under Signing & Capabilities or as `DEVELOPMENT_TEAM`
   in the project's build settings. Both targets must be signed by the same team, because
   the helper accepts connections only from an app signed by its own team.
3. Build and run the `AWDLGuard` scheme.

Tests: `xcodebuild test -scheme AWDLGuard`, or `swift test` in `AWDLGuardKit/`.

Logs: the app and the helper log under their own bundle identifiers, so
`log stream --predicate 'subsystem BEGINSWITH "io.reefsoft.AWDLGuard"'` shows both, for
release and Debug builds.

Debug builds are a separate app, `io.reefsoft.AWDLGuard.debug`, shown as "AWDL Guard Debug",
with their own helper, settings and Background App Activity entry. Release and Debug builds
are signed by different certificates, and macOS saves the signer of a helper's first
registration: sharing one identity made launchd refuse whichever build came second. The
identity comes from `APP_BUNDLE_IDENTIFIER` in the project's build settings. In the JSON
project format a `[config=…]` value is ignored when the same setting also has a plain one, so
it is set per configuration only.

If the helper still won't start, turn the app off and on under Background App Activity in
System Settings, which makes macOS rebuild its record of the helper. The last resort is
`sfltool resetbtm`, which resets the background items of every app and needs a restart.
macOS reads a Debug build's location to check its helper; if the log shows "Item real path
failed", run the build from `/Applications`.

## How it works

| Part | Owns |
|---|---|
| `AWDLGuardKit/HelperInterface` | The XPC messages (`SuppressionRequest`, `InterfaceObservation`) and the helper's table of what each session asks for (`SessionRequests`). |
| `AWDLGuardKit/GuardPolicy` | Rules and how they're stored, the `Decision` (suppress or not, and why), the helper's setup (`HelperSetup`) and the `Status` the menu shows, with its wording. |
| `AWDLGuardHelper` | The privileged launchd daemon. It sets `awdl0`'s `IFF_UP` flag and watches the routing socket. |
| `AWDLGuard` | The menu bar app: its inputs (mode, rules, foreground app, Wi-Fi), the helper connection and the UI. |

### Decision

In Automatic mode AWDL is suppressed on Wi-Fi while the foreground app is a game or has a
rule that's on. A rule that's off never suppresses, even for a game. Allow and Suppress
ignore the foreground app and the network.

Games are recognised from their Info.plist, by the same keys macOS uses for Game Mode:
`LSApplicationCategoryType = public.app-category.games` or `LSSupportsGameMode`.

Mac apps are identified by bundle identifier. CrossOver runs Windows programs from a
temporary folder that changes on every launch, with no bundle identifier, so a Windows app
is identified by its `.exe` file name, ignoring case.

Rules are stored in user defaults as JSON. Loading reads them entry by entry: an entry
that can't be read is skipped, and the stored data is first copied once to
`rules.unreadable`, so a save can't lose it.

### Helper

The helper is registered with `SMAppService` as a launch daemon inside the app bundle, so
deleting the app removes it. It accepts connections only from the AWDL Guard app signed by
the same team (`XPCPeerRequirement.isFromSameTeam`). launchd starts it when the app
connects.

Each connected app session asks for `awdl0` to be held down or not, and the request lasts
until the session ends. `awdl0` stays down while any session asks for it, so a second user,
or a second copy of the app, can't release it under the other. A session that allows AWDL
while another holds it shows "Kept off for another user". When the last session ends, or
launchd stops the helper with SIGTERM (unregistering, turning it off under Background
App Activity, shutdown), the helper restores `awdl0` and exits. It never runs unseen.
Everything in the helper runs on one serial queue.

The file `/var/run/<helper identifier>.suppressing` is the one record that the
helper owes `awdl0` a bring-up:
- It is written before `awdl0` goes down and removed only once `awdl0` is back up, so a
  failed bring-up is retried on the next release, at exit and by the next helper.
- If it can't be written, the helper doesn't suppress, and the menu shows "Couldn't Turn
  Off".
- A helper that starts and finds it brings `awdl0` up, undoing a crashed helper's change.
  Without it, the helper leaves `awdl0` as macOS has it.
- launchd starts the helper only when the app connects. If the app and the helper both
  die, AWDL stays off until AWDL Guard is opened again or the Mac restarts. `/var/run` is
  cleared at boot, when `awdl0` starts up anyway.

Suppression is reactive. When macOS brings `awdl0` up, the routing socket reports it and
the helper takes it down again, so there's a brief window each time. Each one is counted
and shown in the menu. If the routing socket fails for good, the menu shows "Not Watching
AWDL" with Repair, which restarts the helper and its socket.

### Setup and connection

The app sets the helper up by itself. The only thing the user does is turn it on under
Background App Activity, once. `HelperSetup` is a state machine with no side effects: it
takes events (the registration macOS reports, a register or unregister finishing, replies,
a session ending, a timer, Repair) and returns effects (register, unregister, open or close
the session, send a request, start or cancel its one timer, open Settings, reread the
registration).
`HelperConnection` performs the effects and feeds the events back. Its tests cover every
transition.

- Not registered: the app registers the helper. `register()` can report an error and still
  succeed, so the registration read afterwards decides.
- Waiting for approval: the app opens Settings when its own first registration led there,
  which is the first install. A retry or a registration already waiting at launch shows
  Open Settings… instead. macOS posts nothing when the user approves, so the registration
  is reread every 2 seconds.
- Enabled: the app opens a session, which launches the helper, and sends its decision.
- A helper that answered and then went away (exited, crashed, stopped) is reconnected at
  once. A request unanswered for 10 seconds ends the session the same way. The timer uses
  the suspending clock, so time asleep doesn't count.
- A helper that never answers is re-registered: unregister, wait a second, register.
  Registering straight after unregistering is refused while macOS is still removing the
  old job ("Job is not allowed to bootstrap"). An unregister that doesn't finish within 10
  seconds is treated as finished.
- Each failure is retried after 1, 2, then 4 seconds. The count carries through approval
  and clears only when the helper answers. After four failures in a row the menu shows
  "Helper Not Working" with Repair, which re-registers and starts the count again. Opening
  the menu then also tries once more, for example after the user turned the app off and on
  under Background App Activity.
- A helper that has answered is only reconnected, never re-registered. Each app judges
  this by its own session, so with two users on the Mac one user's app can still
  re-register the helper the other is using, when its own sessions never get an answer.
- The helper pushes every change to `awdl0`, and the app sends a request whenever its
  decision changes. Events from an earlier session or a replaced timer are ignored.

Turning AWDL Guard off under Background App Activity makes macOS stop the helper and also
force quit the app (`forceQuitAppWithURL` in Background Task Management). The helper
restores `awdl0` on its SIGTERM either way. macOS waits for the app's child processes
first, such as the Open panel service left by Add App, so the quit can come more than a
minute later.

### Identity

The helper's bundle identifier, launchd label and Mach service name are all the app's
bundle identifier plus `.Helper` (`HelperIdentity`). The "Write Helper Plist" build phase
writes the launchd plist from `AWDLGuardHelper/Helper.plist` with those values, so each
build's plist matches its identity.

### App behaviour

- AWDL Guard starts as just its menu bar item, without taking focus, at login or from
  Finder.
- **App Rules…** opens the AWDL Guard window, centred on the screen with the pointer. The
  app shows in the Dock only while that window is open.
- The window lists rules for running apps first, then the rest, each group alphabetical.
  The details shown for each rule (icon, kind, location) are looked up in the background
  while the window is open, and again each time it opens, never while drawing.
- A hidden menu bar item stays hidden only for a launch at login. Opening the app any other
  way shows it again. Dragging the item out of the menu bar quits the app.

## Releasing

Releases are built on a Mac, because GitHub's runners don't have the Xcode this project
needs. `scripts/release.sh` does everything, and nothing private is stored in the repo.

### One-time setup

1. Create a **Developer ID Application** certificate for the team in your Apple Developer
   account, and install it in your login Keychain.
2. Store notarisation credentials in the Keychain under the profile name `AWDLGuard`:
   `xcrun notarytool store-credentials AWDLGuard`. Use an App Store Connect API key or an
   app-specific password.
3. Make sure `gh` is logged in to an account that can push tags and create releases.

### Each release

1. Set `MARKETING_VERSION` in the project's build settings, then commit and push to
   `main`. The build number is set by the script, from the number of commits, so it rises
   with every release.
2. Run `scripts/release.sh <version>`.
   - It checks the version, the working tree, the tag, the certificate, the notarisation
     profile and `gh`'s login.
   - It runs the tests, then archives and signs with Developer ID.
   - It checks both signatures, then notarises and staples the app and zips it.
   - It pushes tag `v<version>` and creates the GitHub Release with the zip.
3. Check the release page. The script prints the zip's SHA-256.

If pushing the tag fails, the script removes the local tag so it can run again. If the tag
is pushed but the release can't be created, it prints the `gh release create` command that
finishes the job.

`scripts/release.sh <version> --dry-run` builds and notarises without the git checks, the
tag or the release, leaving the zip in `build/release/`.

### Homebrew

The cask goes into Homebrew's main repository once the project meets its
[notability requirements](https://docs.brew.sh/Acceptable-Casks). After that, Homebrew's
autobump follows new GitHub releases. The cask to submit, as `Casks/a/awdl-guard.rb`:

```ruby
cask "awdl-guard" do
  version "0.1.0"
  sha256 "<the SHA-256 the release script prints>"

  url "https://github.com/reefsoft-io/AWDLGuard/releases/download/v#{version}/AWDL-Guard-#{version}.zip"
  name "AWDL Guard"
  desc "Turns off AWDL while games are in the foreground"
  homepage "https://github.com/reefsoft-io/AWDLGuard"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :tahoe"

  app "AWDL Guard.app"

  uninstall launchctl: "io.reefsoft.AWDLGuard.Helper",
            quit:      "io.reefsoft.AWDLGuard"

  zap trash: "~/Library/Preferences/io.reefsoft.AWDLGuard.plist"
end
```
