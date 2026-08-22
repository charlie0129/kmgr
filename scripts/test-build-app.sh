#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
build_script="$repo_root/scripts/build-app.sh"
info_plist="$repo_root/macos/Kmgr/Resources/Info.plist"
icon_source="$repo_root/assets/kmgr.icon"

fail() {
  print -u2 -- "build-app test failed: $1"
  exit 1
}

script=$(<"$build_script")

icon_assets=("$icon_source/Assets"/*(N.))
[[ -f "$icon_source/icon.json" && ${#icon_assets} -gt 0 ]] ||
  fail "the Icon Composer source document is incomplete"
bundle_icon_file=$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$info_plist" 2>/dev/null) ||
  fail "Info.plist has no CFBundleIconFile"
bundle_icon_name=$(/usr/bin/plutil -extract CFBundleIconName raw -o - "$info_plist" 2>/dev/null) ||
  fail "Info.plist has no CFBundleIconName"
[[ "$bundle_icon_file" == kmgr && "$bundle_icon_name" == kmgr ]] ||
  fail "Info.plist does not select the compiled kmgr icon"
[[ "$script" == *'xcrun actool "$icon_source"'* ]] ||
  fail "build-app no longer compiles the Icon Composer document with actool"
[[ "$script" == *'--compile "$resources_dir"'* &&
  "$script" == *'--app-icon "$icon_name"'* ]] ||
  fail "actool no longer compiles the selected app icon into bundle resources"
[[ "$script" == *'--enable-icon-stack-fallback-generation=enabled'* ]] ||
  fail "actool no longer generates the pre-Tahoe ICNS fallback"
[[ "$script" == *'--minimum-deployment-target 15.0'* ]] ||
  fail "actool no longer targets the app's minimum macOS version"
[[ "$script" == *'xcrun swift-stdlib-tool'* &&
  "$script" == *'--destination "$frameworks_dir"'* ]] ||
  fail "build-app no longer embeds the Swift compatibility runtime"
[[ "$script" == *'xcrun install_name_tool -delete_rpath'* &&
  "$script" == *'xcrun install_name_tool -add_rpath'* ]] ||
  fail "build-app no longer replaces toolchain-local runtime search paths"

[[ "$script" == *'configuration=${CONFIGURATION:-debug}'* ]] ||
  fail "Debug is no longer the default configuration"
[[ "$script" == *'go_ldflags=(-X "main.version=$version")'* ]] ||
  fail "Debug Go builds lost version injection"
[[ "$script" == *'go_build_flags=(-tags kmgr_dev)'* ]] ||
  fail "Debug Go builds lost the explicit development-only build tag"
[[ "$script" == *'go_ldflags=(-s -w -X "main.version=$version")'* ]] ||
  fail "Release Go builds do not strip symbols while injecting the version"
[[ "$script" == *'/usr/bin/plutil -replace CFBundleShortVersionString'* &&
  "$script" == *'-string "$version"'* ]] ||
  fail "the app bundle no longer receives the backend build version"
[[ "$script" == *'go_build_flags=()'* ]] ||
  fail "Release Go builds no longer clear development-only build tags"
[[ "$script" == *'"${go_build_flags[@]}"'* ]] ||
  fail "Go builds no longer apply configuration-specific build tags"
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
icon_compile_number=$(grep -nF 'xcrun actool "$icon_source"' "$build_script" | cut -d: -f1)
runtime_copy_number=$(grep -nF 'xcrun swift-stdlib-tool' "$build_script" | cut -d: -f1)
rpath_delete_number=$(grep -nF 'xcrun install_name_tool -delete_rpath' "$build_script" | cut -d: -f1)
framework_sign_number=$(grep -nF 'codesign --force --sign - "$framework"' "$build_script" | cut -d: -f1)
version_write_number=$(grep -nF '/usr/bin/plutil -replace CFBundleShortVersionString' "$build_script" | cut -d: -f1)
verify_number=$(grep -nF '"$repo_root/scripts/verify-app.sh" "$app_dir"' "$build_script" | cut -d: -f1)
[[ -n "$strip_number" && -n "$helper_sign_number" &&
  -n "$bundle_sign_number" && -n "$icon_compile_number" &&
  -n "$runtime_copy_number" && -n "$rpath_delete_number" &&
  -n "$framework_sign_number" && -n "$version_write_number" &&
  -n "$verify_number" ]] ||
  fail "could not locate strip/signing commands"
(( icon_compile_number < helper_sign_number &&
  version_write_number < helper_sign_number &&
  runtime_copy_number < rpath_delete_number &&
  rpath_delete_number < strip_number &&
  strip_number < framework_sign_number &&
  framework_sign_number < helper_sign_number &&
  helper_sign_number < bundle_sign_number &&
  bundle_sign_number < verify_number )) ||
  fail "binary mutations must precede signing and signed-bundle verification"

release_pprof_dependency=$(cd "$repo_root" && go list -deps -f \
  '{{if eq .ImportPath "net/http/pprof"}}{{.ImportPath}}{{end}}' ./backend/cmd/kmgr-engine)
[[ -z "$release_pprof_dependency" ]] ||
  fail "Release helper unexpectedly links net/http/pprof"
development_pprof_dependency=$(cd "$repo_root" && go list -tags kmgr_dev -deps -f \
  '{{if eq .ImportPath "net/http/pprof"}}{{.ImportPath}}{{end}}' ./backend/cmd/kmgr-engine)
[[ "$development_pprof_dependency" == "net/http/pprof" ]] ||
  fail "Development helper does not link the opt-in pprof implementation"

print "build-app policy: ok"
