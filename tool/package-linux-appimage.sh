#!/usr/bin/env bash
# Package a Flutter Linux bundle as an AppImage.
#
# Usage:
#   tool/package-linux-appimage.sh [bundle-dir] [appimagetool-path]
#
# The appimagetool binary can be downloaded from the AppImageKit release page,
# for example:
#   curl -L -o /tmp/appimagetool.AppImage \
#     https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
#   chmod +x /tmp/appimagetool.AppImage
#   ./tool/package-linux-appimage.sh app/foxtune_app/build/linux/x64/release/bundle /tmp/appimagetool.AppImage
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

# The generated desktop entry expects an icon named "foxtune" in the AppDir
# root, while the bundle keeps PNG assets under data/icons.
icon_src=$(find "$bundle/data/icons" -path '*/apps/foxtune.png' | sort | tail -n 1)
if [ -n "$icon_src" ]; then
  cp "$icon_src" "$app_dir/foxtune.png"
fi

cp "$bundle/data/com.foxtune.foxtune_app.desktop" "$app_dir/com.foxtune.foxtune_app.desktop"

rm -f "$appimage_path"
"$appimagetool" "$app_dir" "$appimage_path"

ls -lh "$appimage_path"
