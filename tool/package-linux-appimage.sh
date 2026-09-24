#!/usr/bin/env bash
# Package a Flutter Linux bundle as an AppImage.
#
# Usage:
#   tool/package-linux-appimage.sh [bundle-dir] [appimagetool-path] [output-dir]
#
# The appimagetool binary can be downloaded from its release page, for example:
#   curl -fL -o /tmp/appimagetool.AppImage \
#     https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
#   chmod +x /tmp/appimagetool.AppImage
#   ./tool/package-linux-appimage.sh app/foxtune_app/build/linux/x64/release/bundle /tmp/appimagetool.AppImage
#
# appimagetool embeds a runtime - the part of the AppImage that runs first on
# the user's machine - and unless told otherwise downloads it afresh from a
# floating "continuous" release. Set APPIMAGE_RUNTIME to a runtime file to use
# that one instead; CI does, with a pinned and checksummed release.
#
# The AppImage is named foxtune-linux-x64-<label>.AppImage. The label is
# APPIMAGE_LABEL if set - CI sets the version for a release - and otherwise
# the commit.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bundle=${1:-"$root/app/foxtune_app/build/linux/x64/release/bundle"}
appimagetool=${2:-}
output_dir=${3:-$(dirname "$bundle")}

if [ ! -x "$bundle/foxtune" ]; then
  echo "No FoxTune build in $bundle - run 'flutter build linux' first." >&2
  exit 1
fi

if [ -z "$appimagetool" ]; then
  echo "Usage: $0 [bundle-dir] [appimagetool-path] [output-dir]" >&2
  exit 1
fi

if [ ! -x "$appimagetool" ]; then
  echo "AppImage tool not found: $appimagetool" >&2
  exit 1
fi

bundle=$(cd "$bundle" && pwd)
output_dir=$(mkdir -p "$output_dir" && cd "$output_dir" && pwd)
app_dir="$output_dir/AppDir"
label=${APPIMAGE_LABEL:-$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo "local")}
appimage_path="$output_dir/foxtune-linux-x64-${label}.AppImage"

rm -rf "$app_dir"
mkdir -p "$app_dir"
cp -a "$bundle"/. "$app_dir"/

cat > "$app_dir/AppRun" <<'EOF'
#!/bin/sh
set -eu
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/foxtune" "$@"
EOF
chmod +x "$app_dir/AppRun"

# appimagetool wants the entry's icon ("foxtune") in the AppDir root, and makes
# it the .DirIcon that file managers show. AppImageLauncher installs the icons
# it finds under usr/share/icons - every size, and the SVG - and falls back to
# that single .DirIcon only when there are none.
cp "$bundle/data/icons/hicolor/512x512/apps/foxtune.png" "$app_dir/foxtune.png"
mkdir -p "$app_dir/usr/share/icons"
cp -R "$bundle/data/icons/." "$app_dir/usr/share/icons/"

# The entry goes in the root, where appimagetool wants it, and under
# usr/share/applications, where the AppStream metadata expects to find it.
cp "$bundle/data/com.foxtune.foxtune_app.desktop" "$app_dir/com.foxtune.foxtune_app.desktop"
mkdir -p "$app_dir/usr/share/applications"
cp "$bundle/data/com.foxtune.foxtune_app.desktop" "$app_dir/usr/share/applications/"

# AppStream metadata, for software centres and AppImageLauncher. appimagetool
# only looks for it under the older .appdata.xml name, which AppStream still
# reads the same as .metainfo.xml.
mkdir -p "$app_dir/usr/share/metainfo"
cp "$bundle/data/com.foxtune.foxtune_app.metainfo.xml" \
  "$app_dir/usr/share/metainfo/com.foxtune.foxtune_app.appdata.xml"

runtime_args=()
if [ -n "${APPIMAGE_RUNTIME:-}" ]; then
  runtime_args=(--runtime-file "$APPIMAGE_RUNTIME")
fi

# appimagetool's own AppStream check fetches every URL in the metadata, which
# ties packaging to the network and to each link being reachable from the build
# machine. It is switched off, and the metadata checked here offline instead -
# always in CI, which installs appstreamcli, and locally when it is present.
if command -v appstreamcli > /dev/null; then
  appstreamcli validate-tree --no-net "$app_dir"
fi

rm -f "$appimage_path"
"$appimagetool" --no-appstream "${runtime_args[@]}" "$app_dir" "$appimage_path"

ls -lh "$appimage_path"
