#!/bin/bash
# Original project by kainograze. Updated by 3h6_1.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ipresence-daemon-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
source_dir="$repo_dir/iPresence Daemon/iPresence Daemon"
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -Wno-unused-parameter -Wno-deprecated-declarations \
  -I "$source_dir" -I "$repo_dir/shared" -framework Foundation -framework CoreFoundation \
  "$repo_dir/tests/daemon_tests.m" "$source_dir/DCServerCommunicator.m" \
  "$source_dir/DCActivity.m" "$source_dir/PresenceUpdater.m" "$source_dir/Core.m" \
  "$source_dir/UserPreferences.m" "$source_dir/Logger.m" "$source_dir/Tools.m" \
  -o "$build_dir/daemon-tests"
"$build_dir/daemon-tests"
