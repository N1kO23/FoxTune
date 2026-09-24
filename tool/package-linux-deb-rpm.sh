#!/usr/bin/env bash
# Package a Flutter Linux bundle as a .deb and an .rpm, with nfpm.
#
# Usage:
#   tool/package-linux-deb-rpm.sh [bundle-dir] [nfpm-path] [output-dir]
#
# The nfpm binary can be downloaded from its release page, for example:
#   curl -fL https://github.com/goreleaser/nfpm/releases/download/v2.47.0/nfpm_2.47.0_Linux_x86_64.tar.gz |
#     tar -xz -C /tmp nfpm
#   ./tool/package-linux-deb-rpm.sh app/foxtune_app/build/linux/x64/release/bundle /tmp/nfpm
#
# What goes where is set out in app/foxtune_app/linux/nfpm.yaml. The packages
# are named foxtune-linux-x64-<label>.deb and .rpm. The label is PACKAGE_LABEL
# if set - CI sets the version for a release - and otherwise the commit.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bundle=${1:-"$root/app/foxtune_app/build/linux/x64/release/bundle"}
nfpm=${2:-}
output_dir=${3:-$(dirname "$bundle")}

if [ ! -x "$bundle/foxtune" ]; then
  echo "No FoxTune build in $bundle - run 'flutter build linux' first." >&2
  exit 1
fi

if [ -z "$nfpm" ] || [ ! -x "$nfpm" ]; then
  echo "Usage: $0 [bundle-dir] nfpm-path [output-dir]" >&2
  exit 1
fi

version=$(sed -n 's/^version:[[:space:]]*//p' "$root/app/foxtune_app/pubspec.yaml" |
  tr -d "\"' \r" | head -n 1)

linux=$root/app/foxtune_app/linux
output_dir=$(mkdir -p "$output_dir" && cd "$output_dir" && pwd)
label=${PACKAGE_LABEL:-$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo "local")}

# nfpm expands environment variables in only a few fields, and not in file
# paths, so the placeholders in nfpm.yaml are filled in here instead.
config=$(mktemp)
trap 'rm -f "$config"' EXIT
sed -e "s|\${BUNDLE}|$(cd "$bundle" && pwd)|g" \
  -e "s|\${LINUX}|$linux|g" \
  -e "s|\${LICENSE}|$root/LICENSE|g" \
  -e "s|\${VERSION}|${version%%+*}|g" \
  "$linux/nfpm.yaml" > "$config"

for format in deb rpm; do
  target="$output_dir/foxtune-linux-x64-$label.$format"
  rm -f "$target"
  "$nfpm" package --config "$config" --packager "$format" --target "$target"
  ls -lh "$target"
done
