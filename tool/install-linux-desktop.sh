#!/bin/sh
# Installs FoxTune's desktop entry and icons for the current user, pointing at
# a built Linux bundle.
#
# Wayland compositors do not take a window's icon from the window: they match
# its application ID to an installed .desktop entry and use that entry's icon.
# Until one is installed, FoxTune shows a generic icon in the task manager.
# X11 does not need this - the runner sets the icon on the window itself.
#
# Usage: tool/install-linux-desktop.sh [bundle-dir]
#   bundle-dir defaults to the release build,
#   app/foxtune_app/build/linux/x64/release/bundle.
#
# To remove it again, delete com.foxtune.foxtune_app.desktop from
# ~/.local/share/applications and */apps/foxtune.* from
# ~/.local/share/icons/hicolor.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
bundle=${1:-$root/app/foxtune_app/build/linux/x64/release/bundle}

if [ ! -x "$bundle/foxtune_app" ]; then
  echo "No FoxTune build in $bundle - run 'flutter build linux' first." >&2
  exit 1
fi
bundle=$(cd "$bundle" && pwd)

data=${XDG_DATA_HOME:-$HOME/.local/share}
mkdir -p "$data/icons" "$data/applications"

cp -R "$bundle/data/icons/." "$data/icons/"
# The shipped entry expects foxtune_app on PATH; point it at this bundle.
sed "s|^Exec=.*|Exec=\"$bundle/foxtune_app\"|" \
  "$bundle/data/com.foxtune.foxtune_app.desktop" \
  > "$data/applications/com.foxtune.foxtune_app.desktop"

if command -v update-desktop-database > /dev/null; then
  update-desktop-database -q "$data/applications" || true
fi
# KDE Plasma finds entries through its own cache, not the one above.
for sycoca in kbuildsycoca6 kbuildsycoca5; do
  if command -v "$sycoca" > /dev/null; then
    "$sycoca" > /dev/null 2>&1 || true
    break
  fi
done

echo "Installed com.foxtune.foxtune_app.desktop for $bundle/foxtune_app"
