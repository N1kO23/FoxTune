#!/usr/bin/env bash
# Run the tests for every pure-Dart workspace package.
#
# `dart test` at a workspace root only looks at the root package's own test/
# directory, so members have to be named explicitly. The list comes from the
# root pubspec's `workspace:` entries rather than a glob over packages/, because
# Flutter-dependent packages (foxtune_transport, the app) are deliberately not
# workspace members - `dart test` cannot load `flutter_test`. Test those with
# `flutter test` from their own directories.
set -euo pipefail

cd "$(dirname "$0")/.."

members=$(awk '
  /^workspace:/ { inside = 1; next }
  inside && /^[[:space:]]*-[[:space:]]/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next }
  inside && /^[^[:space:]-]/ { inside = 0 }
' pubspec.yaml)

targets=()
for member in $members; do
  dir="$member/test"
  [ -d "$dir" ] || continue
  if compgen -G "$dir/**/*_test.dart" > /dev/null || compgen -G "$dir/*_test.dart" > /dev/null; then
    targets+=("$dir")
  fi
done

if [ ${#targets[@]} -eq 0 ]; then
  echo "No test directories with tests found." >&2
  exit 1
fi

echo "Testing: ${targets[*]}"
exec dart test "$@" "${targets[@]}"
