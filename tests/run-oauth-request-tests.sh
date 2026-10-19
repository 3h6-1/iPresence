#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ipresence-oauth-request-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -DIPDISCORD_OAUTH_REQUEST_TESTING=1 -I "$repo_dir/shared" \
  -framework Foundation -framework Security \
  "$repo_dir/tests/oauth_request_tests.m" "$repo_dir/shared/IPDiscordOAuthRequest.m" \
  -o "$build_dir/oauth-request-tests"
"$build_dir/oauth-request-tests"
