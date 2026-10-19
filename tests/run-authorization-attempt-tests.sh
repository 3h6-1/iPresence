#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ipresence-authorization-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -I "$repo_dir/shared" -framework Foundation \
  "$repo_dir/tests/authorization_attempt_tests.m" "$repo_dir/shared/IPAuthorizationAttempt.m" \
  -o "$build_dir/authorization-attempt-tests"
"$build_dir/authorization-attempt-tests"
