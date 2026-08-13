#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
build_script="$repo_root/scripts/build-app.sh"

fail() {
  print -u2 -- "build-app test failed: $1"
  exit 1
}

script=$(<"$build_script")

[[ "$script" == *'configuration=${CONFIGURATION:-debug}'* ]] ||
  fail "Debug is no longer the default configuration"
[[ "$script" == *'go_ldflags=(-X "main.version=$version")'* ]] ||
  fail "Debug Go builds lost version injection"
[[ "$script" == *'go_ldflags=(-s -w -X "main.version=$version")'* ]] ||
  fail "Release Go builds do not strip symbols while injecting the version"
[[ "$script" == *'-trimpath'* ]] || fail "Go builds lost -trimpath"
[[ "$script" == *'--configuration "$configuration"'* ]] ||
  fail "SwiftPM no longer receives the selected configuration"
[[ "$script" == *'if [[ "$configuration" == release ]]'* ]] ||
  fail "Swift stripping is not scoped to Release"
[[ "$script" == *'xcrun strip -u -r "$macos_dir/Kmgr"'* ]] ||
  fail "Release does not safely strip the copied Swift executable"

strip_number=$(grep -nF 'xcrun strip -u -r "$macos_dir/Kmgr"' "$build_script" | cut -d: -f1)
helper_sign_number=$(grep -nF 'codesign --force --sign - "$helpers_dir/kmgr-engine"' "$build_script" | cut -d: -f1)
bundle_sign_number=$(grep -nF 'codesign --force --sign - "$app_dir"' "$build_script" | cut -d: -f1)
[[ -n "$strip_number" && -n "$helper_sign_number" && -n "$bundle_sign_number" ]] ||
  fail "could not locate strip/signing commands"
(( strip_number < helper_sign_number && helper_sign_number < bundle_sign_number )) ||
  fail "binary mutations must precede nested-code and bundle signing"

print "build-app release policy: ok"
