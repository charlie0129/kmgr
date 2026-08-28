#!/bin/zsh
set -uo pipefail

repo_root=${0:A:h:h}
cleanup_script="$repo_root/scripts/clean-test-preferences.sh"
test_status=0

cleanup() {
  test_status=$?
  "$cleanup_script" >/dev/null || true
  exit "$test_status"
}

# Keep a final cleanup even when Swift Testing reports a failure. The test
# suites use in-memory defaults today, but this also bounds any future test
# that accidentally creates a real UUID-named suite.
trap cleanup EXIT

swift test --package-path "$repo_root/macos" --no-parallel "$@"
