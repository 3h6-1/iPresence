#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ipresence-diagnostics-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -DIPDIAGNOSTICS_TESTING=1 -I "$repo_dir/shared" \
  -framework Foundation -framework CoreFoundation \
  "$repo_dir/tests/diagnostics_tests.m" "$repo_dir/shared/IPDiagnostics.m" \
  -o "$build_dir/diagnostics-tests"
"$build_dir/diagnostics-tests"
