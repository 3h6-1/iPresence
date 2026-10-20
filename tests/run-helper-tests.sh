#!/bin/bash
# Original project by kainograze. Updated by 3h6_1.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_root/build/tests"
xcrun --sdk macosx clang \
    -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework CoreFoundation \
    "$repo_root/iPresence Springboard Helper/tests/NowPlayingStateTests.m" \
    -o "$repo_root/build/tests/now-playing-tests"
"$repo_root/build/tests/now-playing-tests"
