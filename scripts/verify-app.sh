#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
app_dir=${1:-"$repo_root/build/Kmgr.app"}
contents_dir="$app_dir/Contents"
info_plist="$contents_dir/Info.plist"
expected_identifier=cc.chlc.kmgr
expected_minimum_system=15.0

fail() {
  print -u2 -- "app verification failed: $1"
  exit 1
}

plist_value() {
  local key=$1
  local value
  value=$(/usr/bin/plutil -extract "$key" raw -o - "$info_plist" 2>/dev/null) ||
    fail "Info.plist is missing $key"
  print -r -- "$value"
}

verify_load_paths() {
  local executable=$1
  local dependency
  local rpath
  local dependencies=("${(@f)$(/usr/bin/otool -L "$executable" |
    /usr/bin/awk 'NR > 1 { print $1 }')}")
  local rpaths=("${(@f)$(/usr/bin/otool -l "$executable" |
    /usr/bin/awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }')}")

  for dependency in "${dependencies[@]}"; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      *) fail "non-portable dynamic library path in $executable: $dependency" ;;
    esac
  done
  for rpath in "${rpaths[@]}"; do
    [[ -n "$rpath" ]] || continue
    case "$rpath" in
      @loader_path*|@executable_path*) ;;
      *) fail "non-portable runtime search path in $executable: $rpath" ;;
    esac
  done
}

[[ -d "$app_dir" && ! -L "$app_dir" ]] ||
  fail "bundle is missing or is not a real directory: $app_dir"
[[ -f "$info_plist" && ! -L "$info_plist" ]] ||
  fail "bundle has no regular Info.plist"
/usr/bin/plutil -lint "$info_plist" >/dev/null || fail "Info.plist is invalid"

bundle_identifier=$(plist_value CFBundleIdentifier)
bundle_name=$(plist_value CFBundleName)
bundle_display_name=$(plist_value CFBundleDisplayName)
bundle_executable=$(plist_value CFBundleExecutable)
bundle_type=$(plist_value CFBundlePackageType)
minimum_system=$(plist_value LSMinimumSystemVersion)
principal_class=$(plist_value NSPrincipalClass)

[[ "${app_dir:t}" == Kmgr.app ]] || fail "application bundle must be named Kmgr.app"
[[ "$bundle_identifier" == "$expected_identifier" ]] ||
  fail "bundle identifier is $bundle_identifier, expected $expected_identifier"
[[ "$bundle_name" == Kmgr && "$bundle_display_name" == Kmgr ]] ||
  fail "bundle and display names must both be Kmgr"
[[ "$bundle_executable" == Kmgr ]] ||
  fail "CFBundleExecutable is $bundle_executable, expected Kmgr"
[[ "$bundle_type" == APPL ]] || fail "CFBundlePackageType is not APPL"
[[ "$minimum_system" == "$expected_minimum_system" ]] ||
  fail "minimum system is $minimum_system, expected $expected_minimum_system"
[[ "$principal_class" == NSApplication ]] ||
  fail "NSPrincipalClass is $principal_class, expected NSApplication"
[[ -n "$(plist_value CFBundleShortVersionString)" ]] ||
  fail "CFBundleShortVersionString is empty"
[[ -n "$(plist_value CFBundleVersion)" ]] || fail "CFBundleVersion is empty"

main_executable="$contents_dir/MacOS/$bundle_executable"
helper_executable="$contents_dir/Helpers/kmgr-engine"
main_entries=("$contents_dir/MacOS"/*(N))
helper_entries=("$contents_dir/Helpers"/*(N))

(( ${#main_entries} == 1 )) ||
  fail "Contents/MacOS must contain exactly one executable"
(( ${#helper_entries} == 1 )) ||
  fail "Contents/Helpers must contain exactly kmgr-engine"
for executable in "$main_executable" "$helper_executable"; do
  [[ -f "$executable" && ! -L "$executable" && -x "$executable" ]] ||
    fail "missing regular executable: $executable"
  /usr/bin/file -b "$executable" | /usr/bin/grep -Fq "Mach-O" ||
    fail "not a Mach-O executable: $executable"
  verify_load_paths "$executable"
done

main_build=$(/usr/bin/xcrun vtool -show-build "$main_executable") ||
  fail "could not inspect the main executable's build target"
helper_build=$(/usr/bin/xcrun vtool -show-build "$helper_executable") ||
  fail "could not inspect the helper executable's build target"
[[ "$main_build" == *"platform MACOS"* && "$helper_build" == *"platform MACOS"* ]] ||
  fail "all embedded executables must target macOS"
main_minimum=$(print -r -- "$main_build" | /usr/bin/awk '$1 == "minos" { print $2; exit }')
[[ "$main_minimum" == "$expected_minimum_system" ]] ||
  fail "main executable targets macOS $main_minimum, expected $expected_minimum_system"

# Verify the nested seal independently before checking the complete bundle.
# This remains valid when ad-hoc signatures are replaced with Developer ID.
/usr/bin/codesign --verify --strict --verbose=2 "$helper_executable" ||
  fail "embedded helper signature is invalid"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir" ||
  fail "application signature or nested seal is invalid"

for executable in "$main_executable" "$helper_executable"; do
  entitlements=$(/usr/bin/codesign -d --entitlements :- "$executable" 2>&1) ||
    fail "could not inspect entitlements for $executable"
  [[ "$entitlements" != *com.apple.security.app-sandbox* ]] ||
    fail "App Sandbox entitlement is not permitted: $executable"
done

engine_version=$("$helper_executable" --version) ||
  fail "embedded helper cannot execute on the build host"
[[ "$engine_version" == "kmgr-engine "* ]] ||
  fail "embedded helper returned an unexpected version string"

print "verified app bundle: $app_dir"
