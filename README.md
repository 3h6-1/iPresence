# iPresence — rootless port

iPresence shares the device's current listening activity with Discord. This fork
updates the original iOS 5 / 32-bit project with an iOS 15.0 deployment target,
a modern SpringBoard media observer, a system WebSocket client, and a single
rootless Debian package containing the app, helper, and background daemon.

## Compatibility

The target range is **iOS/iPadOS 15.0–26.0.1 on supported arm64 and arm64e
rootless jailbreaks**. The package uses the standard `/var/jb` layout used by
Dopamine and rootless palera1n. It does not provide a jailbreak, bypass device
support restrictions, or support RootHide's different package format.

| Component | Architecture | Minimum OS |
| --- | --- | --- |
| SpringBoard helper | arm64 + arm64e (modern ABI) | iOS 15.0 |
| Settings app | arm64, runs on both device families | iOS 15.0 |
| Background daemon | arm64, runs on both device families | iOS 15.0 |
| Debian package | `iphoneos-arm64` | firmware 15.0 through 26.0.1 |

**Validation status (2026-10-19):** built and verified with Xcode 27.1 / iPhoneOS
27.1 SDK, targeting iOS 15.0. All 53 offline daemon checks, the media-helper
regression suite, and nine packaging tests passed. The settings app also passed
a launch/layout smoke test in the iOS 18.5 iPhone 16 Pro simulator. No physical
iOS device was available for this port.
Installation, MediaRemote behavior, tweak injection, and end-to-end Discord
presence on each OS/jailbreak combination still require the device checks below.
A successful build is not a claim that every listed OS/device combination has
been tested.

The [Dopamine support matrix](https://github.com/opa334/Dopamine) lists the actual
supported hardware/OS combinations, including a restricted 26.0–26.0.1 range.
The [palera1n documentation](https://docs.palera.in/) describes its supported
hardware. Check the jailbreak's own requirements before installing.

## Build

Use macOS with full Xcode selected (Xcode 16 or later recommended), its iPhoneOS
SDK, Python 3, `ldid`, and `dpkg-deb`. A current Apple linker is required for the
modern arm64e ABI. The root Makefile is the canonical build; Theos and a paid
Apple signing identity are not required.

```sh
brew install ldid dpkg
make test
make package
```

The result is
`packages/com.kainograze.ipresence_2.0.0~rootless1_iphoneos-arm64.deb`.
`make build` stages signed payloads without making a package; `make verify`
inspects the existing `.deb`. `make clean` removes the staging/build directory.
Builds compile with warnings treated as errors. The retired `Websocket/`
transport is not compiled by either the native build or the updated daemon
Xcode target.

`make package` verifies the actual archive, Mach-O architectures, minimum OS,
code signatures, entitlements, launch daemon, and rootless paths.

`ci/build.yml` is a ready-to-enable GitHub Actions template for the same tests
and package build. Copy it to `.github/workflows/build.yml` using a credential
with workflow-write permission to enable it. The credential used for this port
could push source but could not create workflows, so CI has not run remotely.
The template uploads a `.deb` artifact; it does not publish a release or install
anything on a device.

## Install and use

1. Transfer the `.deb` to a device with a supported rootless jailbreak and open it
   in Sileo or Zebra. Let the package manager resolve its dependencies.
2. Respring when installation completes, so the SpringBoard helper loads.
3. Open **iPresence**, enter your token, enable **Share listening activity**, and
   save. Play music in Apple Music or another app publishing system now-playing
   information.

The installer registers the app and loads the daemon. The helper publishes
metadata from SpringBoard using dynamically resolved MediaRemote APIs. If a
required private API is missing, it disables reporting safely instead of
preventing SpringBoard from launching. Metadata is refreshed on notifications
and every 30 seconds. The daemon clears stale helper state after 120 seconds
(with up to 30 seconds until its next check), and disconnects after five minutes
without playback.

The app is installed under `/var/jb/Applications`. Do not separately sideload
it as an IPA: a normally sandboxed app cannot read/write the shared settings.
The daemon runs as **mobile**, not root. Preferences remain in
`/var/mobile/Library/Preferences/com.kainograze.iPresence.plist`; helper state is
stored alongside it as `com.kainograze.iPresence-Springboard-Helper.plist`.
These user-data paths are intentionally not prefixed with `/var/jb`.

### Discord integration

This port preserves the original project's unofficial user-token integration.
It is not a supported Discord OAuth/Rich Presence SDK integration. Discord
[prohibits automated normal-user accounts](https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots)
and may disable an account using one; service acceptance cannot be guaranteed.
No token is included in this repository or needed for the build/tests. The app
writes settings atomically with mode `0600`, masks token entry, and the daemon
never logs credentials or Gateway payloads. Other software running as mobile or
root on the jailbroken device can still read the file.

## Device validation checklist

Run this on representative arm64 and arm64e devices for each OS range you intend
to distribute to. Record device model, OS build, jailbreak version, package
version, and the results; **all device rows are currently unverified**.

- Install/upgrade/remove through the package manager. Confirm the app appears,
  launches after a respring, and the daemon runs as mobile without a crash loop.
- Inspect `launchctl print system/com.kainograze.iPresence-Daemon` from a device
  root shell. Check the system log for iPresence lifecycle errors.
- Start, pause, resume, seek, change track, switch media apps, and play a live
  stream. Verify title/artist/album, remaining duration, and clearing on pause.
- Lock the screen, respring, restart the media service, then reboot and
  re-jailbreak. Playback reporting should recover, and old state should expire.
- Disable sharing, enable it while playback is already active, replace the
  token, and test an invalid token. Invalid authentication should stop repeated
  reconnect attempts until settings are changed.
- Test Wi-Fi/cellular transitions, airplane mode, and sleep/wake. Verify resumed
  sessions continue heartbeats and refresh the activity.
- Confirm the settings and helper-state files are owned by mobile, mode `0600`,
  and logs do not contain credentials. Removal preserves preferences; clear the
  token and save before uninstalling if you want to discard it.

## Implementation and references

- Runtime-resolved MediaRemote functions avoid link-time dependency on a
  private framework and avoid hooks into version-specific SpringBoard classes.
- `NSURLSessionWebSocketTask` uses platform TLS trust validation. Gateway v10
  handles Hello, heartbeat/ACK, server heartbeat requests, resumable sessions,
  invalid sessions, fatal authentication closes, and reconnect backoff.
- Missing/invalid preferences fail closed; state and activity parsing tolerate
  absent metadata and live streams. Presence updates are coalesced.
- Installed payloads are under `/var/jb`; the helper's install name uses
  `@rpath`. Only Apple system frameworks are linked, so no third-party rootful
  library paths are embedded.

References: [Theos rootless packaging](https://theos.dev/docs/rootless),
[arm64e ABI](https://theos.dev/docs/arm64e-deployment),
[MediaRemote declarations](https://github.com/theos/headers/blob/master/MediaRemote/MediaRemote.h),
[Discord Gateway](https://docs.discord.com/developers/events/gateway).

Original project by [kainograze](https://github.com/kainograze/iPresence).
The original GPL-2.0 license is retained; see [LICENSE](LICENSE).
