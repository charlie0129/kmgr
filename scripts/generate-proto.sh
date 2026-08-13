#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
tools_root="$repo_root/.tools/proto"
bin_dir="$tools_root/bin"
protoc_version=29.3
protoc_gen_go_version=1.36.11
protoc_gen_go_grpc_version=1.6.2

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)
    protoc_asset="protoc-${protoc_version}-osx-aarch_64.zip"
    protoc_sha256="2b8a3403cd097f95f3ba656e14b76c732b6b26d7f183330b11e36ef2bc028765"
    ;;
  Darwin-x86_64)
    protoc_asset="protoc-${protoc_version}-osx-x86_64.zip"
    protoc_sha256="9a788036d8f9854f7b03c305df4777cf0e54e5b081e25bf15252da87e0e90875"
    ;;
  Linux-aarch64|Linux-arm64)
    protoc_asset="protoc-${protoc_version}-linux-aarch_64.zip"
    protoc_sha256="6427349140e01f06e049e707a58709a4f221ae73ab9a0425bc4a00c8d0e1ab32"
    ;;
  Linux-x86_64)
    protoc_asset="protoc-${protoc_version}-linux-x86_64.zip"
    protoc_sha256="3e866620c5be27664f3d2fa2d656b5f3e09b5152b42f1bedbf427b333e90021a"
    ;;
  *)
    print -u2 "unsupported protobuf generation host: $(uname -s) $(uname -m)"
    exit 1
    ;;
esac

mkdir -p "$tools_root" "$bin_dir"

go_out="$repo_root/gen/go"
swift_out="$repo_root/macos/KmgrProto/Generated"
mkdir -p "$go_out" "$swift_out"

protoc="$tools_root/protoc-${protoc_version}/bin/protoc"
if [[ ! -x "$protoc" ]]; then
  archive="$tools_root/$protoc_asset"
  url="https://github.com/protocolbuffers/protobuf/releases/download/v${protoc_version}/${protoc_asset}"
  curl --fail --location --silent --show-error "$url" --output "$archive"
  actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
  if [[ "$actual_sha256" != "$protoc_sha256" ]]; then
    print -u2 "checksum mismatch for $protoc_asset"
    exit 1
  fi
  mkdir -p "$tools_root/protoc-${protoc_version}"
  ditto -x -k "$archive" "$tools_root/protoc-${protoc_version}" 2>/dev/null \
    || unzip -q "$archive" -d "$tools_root/protoc-${protoc_version}"
fi

export GOBIN="$bin_dir"
if [[ ! -x "$bin_dir/protoc-gen-go" ]] \
  || [[ "$($bin_dir/protoc-gen-go --version)" != "protoc-gen-go v${protoc_gen_go_version}" ]]; then
  go install "google.golang.org/protobuf/cmd/protoc-gen-go@v${protoc_gen_go_version}"
fi
if [[ ! -x "$bin_dir/protoc-gen-go-grpc" ]] \
  || [[ "$($bin_dir/protoc-gen-go-grpc --version)" != "protoc-gen-go-grpc ${protoc_gen_go_grpc_version}" ]]; then
  go install "google.golang.org/grpc/cmd/protoc-gen-go-grpc@v${protoc_gen_go_grpc_version}"
fi

# Swift generator versions are pinned in macos/Package.swift. SwiftPM builds
# them into its repo-local build directory, so no globally installed plugins
# are consulted.
swift build --package-path "$repo_root/macos" --product protoc-gen-swift
swift build --package-path "$repo_root/macos" --product protoc-gen-grpc-swift-2
swift_bin_dir=$(swift build --package-path "$repo_root/macos" --show-bin-path)

# Generation writes a complete deterministic set. Stale checked-in outputs are
# identified after generation and removed individually below.
proto_files=("$repo_root"/proto/kmgr/v1/*.proto(N))
if (( ${#proto_files} == 0 )); then
  print -u2 "no protobuf definitions found"
  exit 1
fi

"$protoc" \
  --proto_path="$repo_root/proto" \
  --plugin="protoc-gen-go=$bin_dir/protoc-gen-go" \
  --go_out="$go_out" \
  --go_opt=paths=source_relative \
  --plugin="protoc-gen-go-grpc=$bin_dir/protoc-gen-go-grpc" \
  --go-grpc_out="$go_out" \
  --go-grpc_opt=paths=source_relative \
  --plugin="protoc-gen-swift=$swift_bin_dir/protoc-gen-swift" \
  --swift_out="$swift_out" \
  --swift_opt=Visibility=Public,FileNaming=DropPath \
  --plugin="protoc-gen-grpc-swift-2=$swift_bin_dir/protoc-gen-grpc-swift-2" \
  --grpc-swift-2_out="$swift_out" \
  --grpc-swift-2_opt=Visibility=Public,Client=True,Server=False,FileNaming=DropPath \
  "${proto_files[@]}"

expected_go=()
expected_swift=()
for proto_file in "${proto_files[@]}"; do
  stem=${proto_file:t:r}
  expected_go+=("$go_out/kmgr/v1/${stem}.pb.go" "$go_out/kmgr/v1/${stem}_grpc.pb.go")
  expected_swift+=("$swift_out/${stem}.pb.swift" "$swift_out/${stem}.grpc.swift")
done

for generated in "$go_out"/kmgr/v1/*.pb.go(N); do
  if (( ${expected_go[(Ie)$generated]} == 0 )); then
    rm -- "$generated"
  fi
done
for generated in "$swift_out"/*.{pb,grpc}.swift(N); do
  if (( ${expected_swift[(Ie)$generated]} == 0 )); then
    rm -- "$generated"
  fi
done

gofmt -w "$go_out/kmgr/v1"/*.go
print "generated Go and Swift protobuf sources"
