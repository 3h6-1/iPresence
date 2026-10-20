<p align="center">
  <img src="assets/ipresence-icon.png" width="128px" height="128px">
</p>
<h1 align="center">iPresence — rootless port</h1>

Original project by [kainograze](https://github.com/kainograze/iPresence).
Rootless port and updates by [3h6_1](https://github.com/3h6-1). See [AUTHORS](AUTHORS).

iPresence shares the iPhone's current listening activity in Apple Music with Discord. This fork
updates the original 32-bit project for arm64 and arm64e rootless jailbreaks.
Version 2.1 uses the official Discord Social SDK and OAuth2 with PKCE. Sign in
through Discord's consent screen; iPresence never asks for your personal
Discord account/session token. It works entirely on the iPhone.

## Compatibility

The OAuth package targets **iOS/iPadOS 15.1–26.0.1** on supported arm64 and arm64e
rootless jailbreaks using `/var/jb`. The current Social SDK's documented minimum
is iOS 15.1. The earlier 2.0.1 artwork-only build targeted 15.0 but used an
unofficial personal-token connection; it does not provide the OAuth safety
improvement. RootHide's different package format is not supported.

| Component | Architecture | Minimum OS |
| --- | --- | --- |
| SpringBoard helper | arm64 + arm64e, modern ABI | iOS 15.1 |
| Settings app and daemon | arm64, runs on both device families | iOS 15.1 |
| Debian package | `iphoneos-arm64` | firmware 15.1 through 26.0.1 |

**Native Discord sign-in is confirmed on an iPhone 13 Pro Max running iOS 16.0
with Dopamine** (version 2.1.2). Full end-to-end device validation is still needed,
including token refresh, lock-screen playback, and daemon connectivity. Discord
documents native iOS apps, not jailbreak launch daemons. Compiling against its
SDK does not establish support for every OS/jailbreak combination, or guarantee
that background authentication works on a physical device.

**Local validation (2026-10-19):** the package builds and passes archive/Mach-O
verification with Xcode 27.1 and the iPhoneOS 27.1 SDK. Twenty packaging tests,
68 offline daemon checks, 121 credential-store checks, 69 OAuth request checks,
37 authorization lifecycle checks, 69 diagnostics privacy/storage checks, and
the media-helper regression suite pass. All 18 optional iOS simulator scenarios pass and exercise
the production callback handlers and UI with mock native/browser handoffs and HTTP
responses. They cover successful sign-in, cancellation, timeout, denial, server
errors, forged/duplicate callbacks, native-opening failure, and retry after
cancellation. These checks do not perform real Discord authentication, external
app/browser handoff, or activity publication. The home-screen icon was also
visually verified on the iOS 18.5 simulator using the release icon staging code.
The diagnostics viewer passes 25 additional simulator checks covering report
presentation, private copy options, repeated taps, document-picker construction,
and snapshot lifetime. Copy writes and Files presentation are intercepted in the
fixture; actual Files export still needs device validation.
Installer tests use isolated stub commands to cover rootless tool selection,
missing tools, failed daemon startup, and removal without touching host launchd.

The package does not provide a jailbreak. Check the actual device and OS support
of [Dopamine](https://github.com/opa334/Dopamine) or
[palera1n](https://docs.palera.in/) before installing.

## Build

Use macOS with full Xcode selected, an iPhoneOS SDK, Python 3, `ldid`, and
`dpkg-deb`. A current Apple linker is required for modern arm64e. The root Makefile
is the canonical build; the original Xcode project files are retained for
historical reference and do not configure the new SDK integration.

1. Open your application in the Discord Developer Portal, enable Social SDK,
   and download the native **DiscordSocialSdk** ZIP (tested against 1.10.19337).
2. Import the licensed SDK locally. It is ignored by Git and not redistributed
   in this repository:

```sh
python3 scripts/import_sdk.py ~/Downloads/DiscordSocialSdk-1.10.19337.zip
brew install ldid dpkg
make test
make package
```

Output: `packages/com.kainograze.ipresence_2.1.4_iphoneos-arm64.deb`.

`make package` builds the optimized device package (`-O2`) using Discord's release
SDK. There is no separate development build mode or Theos `FINALPACKAGE` flag.
Tests and simulator fixtures are not included. The stable Debian version `2.1.4`
upgrades from `2.1.4~oauth5`; app build 9 identifies this packaging revision.
The opt-in diagnostic report remains available in the optimized build.
The SDK runtime is signed and installed at
`/var/jb/Library/Frameworks/discord_partner_sdk.framework`; the daemon uses
that rootless framework search path. The foreground app uses
iOS AuthenticationServices and Foundation networking for OAuth; it does not load
the Social SDK or depend on its implicit URL hooks. SDK notices are included in the
local package. SDK headers and libraries stay under ignored `vendor/`.

`make build` stages signed payloads, `make verify` inspects the actual `.deb`,
and `make clean` removes build output. Compilation treats warnings as errors.
Verification checks archive permissions, architecture, platform, deployment
target, signatures, entitlements, launchd configuration, OAuth URL scheme, and
SDK linkage. Host tests do not need the SDK or any Discord credentials.

To run the optional offline iOS integration fixture, select an installed simulator
from `xcrun simctl list devices available`, then run
`bash tests/run-authorization-simulator-tests.sh <simulator-UDID>`. It installs a
separate test app with synthetic credentials and removes it afterward. It only
shuts down the selected simulator if it booted it. Results and UI screenshots
are saved under `build/auth-routing/`.

`bash tests/run-diagnostics-viewer-simulator-tests.sh <simulator-UDID>` exercises
the report viewer, copy options, document export configuration, and snapshot
cleanup with synthetic reports. It does not change the real device clipboard.

`ci/build.yml` is an inactive host-test workflow template. It needs a credential
with workflow-write permission to install under `.github/workflows/`. Package
builds require a separately licensed SDK download and are not published by CI.

## Discord application configuration

This build uses the owner's **iPresence** application, ID
`1561870047562043402`. Social SDK is enabled, **Public Client** is on, and the
registered redirect is:

```
discord-1561870047562043402:/authorize/callback
```

For another maintained fork, use your own Discord application and change the ID,
redirect, URL scheme, and artwork URL together in the app, daemon, and tests.
Never embed a client secret in an iPhone app. The requested scopes are pinned
to `openid sdk.social_layer_presence`, the
minimum documented for authenticated Social SDK Rich Presence. **This is a
bundle: Discord also grants friend/relationship features.** iPresence does not
use those features, but we cannot remove them from Discord's bundle while
retaining this supported iPhone-only integration. No extra communication,
message, voice, email, or server scopes are requested. The app explains this
before opening sign-in; Discord's own consent screen lists the actual access.

See [Discord's scope documentation](https://docs.discord.com/developers/discord-social-sdk/core-concepts/oauth2-scopes)
for the features included in each permission bundle.

Version 2.1.2 first opens the installed Discord app for native authorization,
matching the native handoff format captured from the official iOS Social SDK
1.10.19337. This avoids loading the web consent page when Discord is installed.
If Discord is absent or cannot open, it falls back to an ephemeral
`ASWebAuthenticationSession`. **Sign in using browser** explicitly chooses that
fresh browser session. The app handles callback URLs itself, checks a random
state value, uses S256 PKCE,
exchanges the code once, and rejects old/forged callbacks. Sign-in has a Cancel
button and a five-minute deadline; token exchange has a 45-second recovery
limit. Network requests use default TLS validation, disable caching and cookies,
and refuse HTTP redirects. No client secret or personal account token is used.

## Install and use

1. Transfer the local `.deb` to a supported rootless device and open it in Sileo
   or Zebra. Let the package manager resolve dependencies, then respring.
2. Open **iPresence**, choose **Sign in with Discord**, and review the bundled permissions
   in Discord's native authorization screen. A browser is used if Discord cannot open.
3. Enable **Share listening activity** and play music; changes save automatically. No Mac or desktop
   Discord client is needed. “Signed in” in the app means credentials were saved;
   confirm actual publication by viewing your Discord activity.
4. Turn sharing off to stop publishing. Use **Sign out** to remove local OAuth
   credentials and attempt to revoke authorization. You can also remove iPresence
   from Discord's **Authorized Apps** settings, especially after an offline sign-out.

Version 2.1.4 fixes installation on rootless devices where `/bin/launchctl` does
not exist. The package declares its `launchctl` dependency and resolves the
executable under `/var/jb` before considering the system path. A failed daemon
bootstrap remains an installation error; it is never reported as success.
If Sileo reports `postinst: /bin/launchctl: not found` from an earlier package,
install the new `.deb` through Sileo to replace that script, then respring after
configuration succeeds. Re-running configuration of the old package alone still
uses the old script.

Opening the new app removes the legacy token setting. The new daemon never reads
or uses that personal token, even if an old preference remains before first launch.
There is no fallback to the old personal-token Gateway transport.

The app must be installed at `/var/jb/Applications` by the package; a normally
sandboxed sideloaded IPA cannot access the shared state. The daemon runs as
**mobile**. Settings and helper state remain under
`/var/mobile/Library/Preferences`, intentionally outside the `/var/jb` prefix.

OAuth access and refresh tokens still exist internally. They are stored in
`com.kainograze.iPresence.oauth.plist` using private permissions, atomic writes,
and locking. The daemon alone refreshes them, and a session check prevents a
late refresh from restoring credentials after sign-out or replacing a newer
login. Remote authorization revocation is owned by the app, so an old daemon
request cannot revoke a newer login. Tokens are not printed in logs. This is a private file, not encrypted
storage: software with mobile/root privileges on a jailbroken device can read it.

## Sign-in diagnostics

If authorization fails or shows a blank page, return to iPresence, cancel any
pending sign-in, and select **View diagnostics**. The report contains recent sign-in
stages, error domains/codes, HTTP statuses, app/OS versions, and the hardware model
identifier. It excludes authorization URLs, codes, state, PKCE verifiers, tokens,
usernames, HTTP bodies, and error descriptions. Review it in the app, then choose
**Copy report** to paste it manually or **Save to Files** to export a copy and attach
it. Copying uses a local-only clipboard item that expires after ten minutes.
Nothing is sent automatically.

Version 2.1.3 replaces the iOS share sheet: a supplied iOS 16.0 crash report showed
a null-pointer crash in CoreImage/MobileIcons while the sheet fetched an AirDrop
activity icon, with SnowBoard in that call stack. The report viewer avoids that
activity/icon-discovery path entirely. The log does not establish the sole cause
of the crash or explain the blank browser page.

Sanitized events also appear in Console under subsystem `com.kainograze.iPresence`,
category `diagnostics`. On-device files live in
`/var/mobile/Library/Preferences/iPresenceDiagnostics/`: `current.jsonl` and
`previous.jsonl`, each limited to 64 KiB with mode 0600 in a mode-0700 directory.
The exported snapshot is revalidated and kept while the viewer is open, then
removed when the viewer closes. A copy explicitly saved to Files remains there.

The iOS 16.0/Dopamine test device shows a blank Discord page in the app's browser
session and at `https://discord.com/login` in both ordinary and Private Safari
tabs. This reproduces independently of iPresence and its OAuth URL. The diagnostic
report shows the authentication session starts and later reports cancellation,
with no callback or token exchange; it does not expose the page's rendering error.
Native sign-in is confirmed working and remains the recommended route.

If Safari also shows a blank page, check that JavaScript is enabled and try a
different network, following [Apple's Safari troubleshooting](https://support.apple.com/en-us/102456).
If it persists, Safari Web Inspector can identify the failing script or request
on the public login page. The underlying website/WebKit/filtering cause remains
unconfirmed; changing OAuth permissions or weakening PKCE would not diagnose it.

## Activity artwork

The installed app has its own iPresence home-screen icon, derived from
`assets/ipresence-icon.png` for iPhone and iPad. The generation prompt is stored
alongside the master image.

The supplied red/pink Apple Music artwork is explicitly sent as the activity's
large image. The original payload only supplied a tooltip, causing Discord to
fall back to the old application's orange icon. The owned iPresence application's
default icon was also updated. See [artwork provenance](assets/README.md).

## Account safety and platform limits

The OAuth build removes the personal-account-token self-bot mechanism. Discord
supports OAuth account linking for native iOS Rich Presence; unauthenticated
Rich Presence is not available on iOS. Using the official mechanism does not
mean zero account risk or Discord endorsement of a jailbreak music app.

References: [mobile account linking](https://docs.discord.com/developers/discord-social-sdk/development-guides/account-linking-on-mobile),
[SDK platform support](https://docs.discord.com/developers/discord-social-sdk/core-concepts/platform-compatibility),
[Rich Presence](https://docs.discord.com/developers/discord-social-sdk/development-guides/setting-rich-presence),
[Developer Policy](https://support-dev.discord.com/hc/en-us/articles/8563934450327-Discord-Developer-Policy).

## Device validation

Record the device model, OS build, jailbreak, and package version. Check:

- Sign in, cancel sign-in, sign out, and reauthorize. Disable sharing while music
  plays; the activity should clear. Re-enable it and verify current playback.
- Play, pause, seek, switch tracks and media apps, and play a live stream. Verify
  title/artist/album, red/pink artwork, remaining time, and clearing on pause.
- Lock the screen, respring, reboot/re-jailbreak, and switch between Wi-Fi and
  cellular. Confirm the daemon reconnects and restores current activity.
- Leave the account linked through token expiry and check automatic refresh.
  Sign out while a refresh or connection is in progress; it must stay signed out.
- Inspect `launchctl print system/com.kainograze.iPresence-Daemon` from a device
  root shell for a crash loop. Share only lifecycle errors, never token files.
- Sign out before uninstalling to discard local credentials. Package removal
  preserves user preferences.

The helper resolves MediaRemote APIs at runtime, checks required symbols,
reports every 30 seconds, and avoids SpringBoard class hooks. The daemon expires
stale playback after 120 seconds (plus its next poll), coalesces updates, clears
paused activity, and disconnects after five idle minutes. SDK timestamps are
converted from the helper's milliseconds to Unix seconds.

Authors: [kainograze](https://github.com/kainograze/iPresence) and
[3h6_1](https://github.com/3h6-1); see [AUTHORS](AUTHORS) for contribution credits.
The original GPL-2.0 license is retained; see [LICENSE](LICENSE). Discord's SDK
is separately licensed under its own terms, is not covered by this repository's
GPL license, and is not committed here. Local SDK-linked packages are for the
SDK license holder's testing; no combined binary release is published here.
