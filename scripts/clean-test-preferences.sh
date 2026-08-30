#!/bin/zsh
set -euo pipefail

preferences_dir="${HOME:?}/Library/Preferences"
[[ -d "$preferences_dir" ]] || exit 0

# Test suites historically used a fresh UUID in every UserDefaults suite name.
# Keep the match narrow: the real application domain is cc.chlc.kmgr.plist and
# must never be touched by this cleanup.
test_plist_regex='.*/(kmgr-[^/]*-[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}\.plist|KmgrAppTests\.ContextualShortcuts\.[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}\.plist)'

if [[ "${1:-}" == "--dry-run" && $# -eq 1 ]]; then
  /usr/bin/find -E "$preferences_dir" \
    -maxdepth 1 \
    -type f \
    -regex "$test_plist_regex" \
    -print
  exit 0
fi

if (( $# > 0 )); then
  print -u2 -- "usage: $0 [--dry-run]"
  exit 2
fi

count=$(/usr/bin/find -E "$preferences_dir" \
  -maxdepth 1 \
  -type f \
  -regex "$test_plist_regex" \
  -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')

if (( count > 0 )); then
  /usr/bin/find -E "$preferences_dir" \
    -maxdepth 1 \
    -type f \
    -regex "$test_plist_regex" \
    -delete
fi

print "removed $count test preference plist(s)"
