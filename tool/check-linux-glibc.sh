#!/usr/bin/env bash
# Fails if a Linux bundle needs a newer glibc than the given floor.
#
# Every binary built for the bundle links against the build machine's glibc and
# binds the newest version of each symbol it finds there, so the build machine
# decides the oldest system the bundle - and the AppImage made from it - will
# start on. libserialport, compiled from source, is where it shows: built
# against glibc 2.42 its termios calls need 2.42, which shuts out nearly every
# distribution released before it. This makes such a change fail the build
# instead of reaching users.
#
# Usage: tool/check-linux-glibc.sh [bundle-dir] [max-version]
#   bundle-dir defaults to the release build,
#   app/foxtune_app/build/linux/x64/release/bundle.
#   max-version defaults to 2.35, Ubuntu 22.04's.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bundle=${1:-"$root/app/foxtune_app/build/linux/x64/release/bundle"}
max=${2:-2.35}

if [ ! -x "$bundle/foxtune" ]; then
  echo "No FoxTune build in $bundle - run 'flutter build linux' first." >&2
  exit 1
fi

status=0
while IFS= read -r -d '' file; do
  needed=$(objdump -T "$file" 2> /dev/null |
    { grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' || true; } |
    sed 's/^GLIBC_//' | sort -uV | tail -1)
  [ -n "$needed" ] || continue
  if [ "$(printf '%s\n' "$max" "$needed" | sort -V | tail -1)" != "$max" ]; then
    echo "${file#"$bundle"/} needs glibc $needed, newer than $max" >&2
    status=1
  fi
done < <(find "$bundle" -type f \( -name foxtune -o -name '*.so' \) -print0)

if [ "$status" -eq 0 ]; then
  echo "The bundle runs on glibc $max and newer."
fi
exit "$status"
