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
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bundle=${1:-"$root/app/foxtune_app/build/linux/x64/release/bundle"}
appimagetool=${2:-}
output_dir=${3:-$(dirname "$bundle")}

if [ ! -x "$bundle/foxtune_app" ]; then
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
sha=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo "local")
appimage_path="$output_dir/foxtune-linux-x64-${sha}.AppImage"

rm -rf "$app_dir"
mkdir -p "$app_dir"
cp -a "$bundle"/. "$app_dir"/

cat > "$app_dir/AppRun" <<'EOF'
#!/bin/sh
set -eu
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/foxtune_app" "$@"
EOF
chmod +x "$app_dir/AppRun"

# appimagetool wants the entry's icon ("foxtune") in the AppDir root, and makes
# it the .DirIcon that file managers show. AppImageLauncher installs the icons
# it finds under usr/share/icons - every size, and the SVG - and falls back to
# that single .DirIcon only when there are none.
cp "$bundle/data/icons/hicolor/512x512/apps/foxtune.png" "$app_dir/foxtune.png"
mkdir -p "$app_dir/usr/share/icons"
cp -R "$bundle/data/icons/." "$app_dir/usr/share/icons/"

cp "$bundle/data/com.foxtune.foxtune_app.desktop" "$app_dir/com.foxtune.foxtune_app.desktop"

runtime_args=()
if [ -n "${APPIMAGE_RUNTIME:-}" ]; then
  runtime_args=(--runtime-file "$APPIMAGE_RUNTIME")
fi

rm -f "$appimage_path"
"$appimagetool" "${runtime_args[@]}" "$app_dir" "$appimage_path"

ls -lh "$appimage_path"
