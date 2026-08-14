#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
configuration=${CONFIGURATION:-debug}
app_dir="$repo_root/build/Kmgr.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
helpers_dir="$contents_dir/Helpers"
resources_dir="$contents_dir/Resources"
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
mkdir -p "$macos_dir" "$helpers_dir" "$resources_dir"

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
chmod 0755 "$macos_dir/Kmgr" "$helpers_dir/kmgr-engine"

if [[ "$configuration" == release ]]; then
  # SwiftPM emits a separate dSYM for Release. Remove the copied executable's
  # remaining symbol table before signing; keep the dSYM in macos/.build for
  # crash symbolication and for a distribution pipeline to archive separately.
  xcrun strip -u -r "$macos_dir/Kmgr"
fi

# Copying and, for Release, stripping SwiftPM's linker-signed executable
# invalidates its original ad-hoc seal. Sign nested code first, then seal the
# finished bundle. All binary mutations must remain above these calls.
# A distribution pipeline can replace both signatures with Developer ID.
codesign --force --sign - "$helpers_dir/kmgr-engine"
codesign --force --sign - "$app_dir"

print "$app_dir"
