#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
configuration=${CONFIGURATION:-debug}
app_dir="$repo_root/build/Kmgr.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
helpers_dir="$contents_dir/Helpers"
frameworks_dir="$contents_dir/Frameworks"
resources_dir="$contents_dir/Resources"
icon_source="$repo_root/assets/kmgr.icon"
icon_name=kmgr
icon_file="$resources_dir/$icon_name.icns"
asset_catalog="$resources_dir/Assets.car"
version=$(git -C "$repo_root" describe --always --dirty 2>/dev/null || print dev)

case "$configuration" in
  debug)
    go_ldflags=(-X "main.version=$version")
    go_build_flags=(-tags kmgr_dev)
    ;;
  release)
    go_ldflags=(-s -w -X "main.version=$version")
    go_build_flags=()
    ;;
  *) print -u2 "CONFIGURATION must be 'debug' or 'release'"; exit 2 ;;
esac

[[ -d "$icon_source" ]] || {
  print -u2 "missing Icon Composer document: $icon_source"
  exit 1
}

# Assemble from an empty target every time. Reusing an old bundle can retain
# removed helpers/resources or invalid nested signatures from a prior build.
if [[ -d "$app_dir" ]]; then
  app_parent=${app_dir:h}
  app_name=${app_dir:t}
  if [[ "$app_parent" != "$repo_root/build" || "$app_name" != "Kmgr.app" ]]; then
    print -u2 "refusing to replace unexpected app target: $app_dir"
    exit 1
  fi
  rm -rf -- "$app_dir"
fi
mkdir -p "$macos_dir" "$helpers_dir" "$frameworks_dir" "$resources_dir"

xcrun actool "$icon_source" \
  --compile "$resources_dir" \
  --app-icon "$icon_name" \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --platform macosx \
  --enable-icon-stack-fallback-generation=enabled \
  --include-all-app-icons \
  --minimum-deployment-target 15.0 \
  --output-partial-info-plist /dev/null \
  >/dev/null
[[ -s "$asset_catalog" && -s "$icon_file" ]] || {
  print -u2 "actool did not produce the Tahoe icon catalog and pre-Tahoe fallback"
  exit 1
}

go build \
  "${go_build_flags[@]}" \
  -trimpath \
  -ldflags "${(j: :)go_ldflags}" \
  -o "$helpers_dir/kmgr-engine" \
  "$repo_root/backend/cmd/kmgr-engine"

swift build \
  --package-path "$repo_root/macos" \
  --configuration "$configuration" \
  --product Kmgr

swift_bin_dir=$(swift build \
  --package-path "$repo_root/macos" \
  --configuration "$configuration" \
  --show-bin-path)

cp "$swift_bin_dir/Kmgr" "$macos_dir/Kmgr"
cp "$repo_root/macos/Kmgr/Resources/Info.plist" "$contents_dir/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString \
  -string "$version" \
  "$contents_dir/Info.plist"
chmod 0755 "$macos_dir/Kmgr" "$helpers_dir/kmgr-engine"

xcrun swift-stdlib-tool \
  --copy \
  --scan-executable "$macos_dir/Kmgr" \
  --platform macosx \
  --destination "$frameworks_dir"

bundle_frameworks_rpath='@executable_path/../Frameworks'
has_bundle_frameworks_rpath=0
swift_rpaths=("${(@f)$(/usr/bin/otool -l "$macos_dir/Kmgr" |
  /usr/bin/awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }')}")
for rpath in "${swift_rpaths[@]}"; do
  case "$rpath" in
    "$bundle_frameworks_rpath") has_bundle_frameworks_rpath=1 ;;
    /usr/lib/swift|@loader_path*|@executable_path*) ;;
    /*) xcrun install_name_tool -delete_rpath "$rpath" "$macos_dir/Kmgr" ;;
  esac
done
framework_entries=("$frameworks_dir"/*(N.))
(( ${#framework_entries} > 0 )) || {
  print -u2 "swift-stdlib-tool did not copy the required compatibility runtime"
  exit 1
}
(( has_bundle_frameworks_rpath )) ||
  xcrun install_name_tool -add_rpath "$bundle_frameworks_rpath" "$macos_dir/Kmgr"

if [[ "$configuration" == release ]]; then
  # SwiftPM emits a separate dSYM for Release. Remove the copied executable's
  # remaining symbol table before signing; keep the dSYM in macos/.build for
  # crash symbolication and for a distribution pipeline to archive separately.
  xcrun strip -u -r "$macos_dir/Kmgr"
fi

# Copying, changing load paths, and, for Release, stripping SwiftPM's
# linker-signed executable invalidates its original ad-hoc seal. Sign all
# nested code first, then seal the finished bundle. All binary mutations must
# remain above these calls. A distribution pipeline can replace these
# signatures with Developer ID.
for framework in "${framework_entries[@]}"; do
  codesign --force --sign - "$framework"
done
codesign --force --sign - "$helpers_dir/kmgr-engine"
codesign --force --sign - "$app_dir"

"$repo_root/scripts/verify-app.sh" "$app_dir"

print "$app_dir"
