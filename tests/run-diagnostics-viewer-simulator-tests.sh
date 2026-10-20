#!/bin/bash
# Original project by kainograze. Updated by 3h6_1.
# Optional diagnostics viewer regression: requires Xcode and an already installed iOS runtime.
# Usage: tests/run-diagnostics-viewer-simulator-tests.sh <simulator-UDID>
# Only the selected simulator is touched; no OAuth/network/real credential access.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <simulator-UDID> (see xcrun simctl list devices available)" >&2
  exit 2
fi
simulator_id="$1"
bundle_id="com.kainograze.iPresence.DiagnosticsTests"
output="$PWD/build/diagnostics-viewer"
mkdir -p "$output"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ipresence-diagnostics-viewer.XXXXXX")"
booted_here=0
cleanup() {
  xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  if [ "$booted_here" -eq 1 ]; then xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true; fi
  rm -rf "$build_dir"
}
trap cleanup EXIT
state="$(xcrun simctl list devices --json | python3 -c '
import json,sys
matches=[d for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["udid"]==sys.argv[1] and d.get("isAvailable")]
if len(matches)!=1: raise SystemExit("Select an available simulator UDID")
print(matches[0]["state"])
' "$simulator_id")"
if [ "$state" = Shutdown ]; then
  xcrun simctl boot "$simulator_id"
  booted_here=1
elif [ "$state" != Booted ]; then
  echo "Simulator is transitioning ($state); retry once ready" >&2
  exit 1
fi
xcrun simctl bootstatus "$simulator_id" -b
app="$build_dir/iPresence.app"
mkdir -p "$app"
cp iPresence/iPresence/iPresence-Info.plist "$app/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName iPresence Diagnostics Tests' "$app/Info.plist"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
architecture="$(uname -m)"
xcrun --sdk iphonesimulator clang -target "$architecture-apple-ios15.1-simulator" -isysroot "$sdk" \
  -fobjc-arc -fblocks -O1 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations \
  -DIPOAUTH_STORE_TESTING -DIPDISCORD_OAUTH_REQUEST_TESTING -DIPDIAGNOSTICS_TESTING -IiPresence/iPresence -Ishared \
  -framework Foundation -framework CoreFoundation -framework UIKit -framework AuthenticationServices -framework Security \
  iPresence/iPresence/main.m iPresence/iPresence/AppDelegate.m iPresence/iPresence/ViewController.m \
  iPresence/iPresence/IPDiscordAuthorization.m iPresence/iPresence/IPDiagnosticsViewController.m shared/IPOAuthStore.m shared/IPAuthorizationAttempt.m \
  shared/IPDiscordOAuthRequest.m shared/IPDiagnostics.m tests/diagnostics_viewer_simulator_tests.m -o "$app/iPresence"
codesign --force --sign - "$app"
xcrun simctl install "$simulator_id" "$app"
python3 - "$simulator_id" "$output" <<'PYTEST'
import json, pathlib, shutil, subprocess, sys, time
udid, output = sys.argv[1:]
bundle = 'com.kainograze.iPresence.DiagnosticsTests'
def sim(*args):
    return subprocess.run(['xcrun','simctl',*args], check=True, text=True, capture_output=True)
container = pathlib.Path(sim('get_app_container',udid,bundle,'data').stdout.strip())
documents = container/'Documents'
result = documents/'DiagnosticsViewerResult.json'
result.unlink(missing_ok=True)
sim('launch',udid,bundle)
deadline = time.monotonic()+40
while time.monotonic()<deadline:
    if result.exists():
        value=json.loads(result.read_text())
        assert value['passed'] and not value['activitySheetUsed'], value
        shutil.copy2(result,pathlib.Path(output)/'results.json')
        shutil.copy2(documents/'DiagnosticsViewer.png',pathlib.Path(output)/'viewer.png')
        print(json.dumps(value),flush=True)
        break
    time.sleep(.1)
else:
    raise RuntimeError('Diagnostics viewer fixture did not complete')
PYTEST
