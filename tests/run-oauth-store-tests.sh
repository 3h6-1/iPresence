#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ipresence-oauth-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -DIPOAUTH_STORE_TESTING=1 -I "$repo_dir/shared" \
  -framework Foundation -framework CoreFoundation \
  "$repo_dir/tests/oauth_store_tests.m" "$repo_dir/shared/IPOAuthStore.m" \
  -o "$build_dir/oauth-store-tests"
"$build_dir/oauth-store-tests"
