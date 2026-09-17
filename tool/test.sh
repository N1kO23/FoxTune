#!/usr/bin/env bash
# Run the tests for every pure-Dart workspace package.
#
# `dart test` at a workspace root only looks at the root package's own test/
# directory, so the member packages have to be named explicitly. Directories
# with no *_test.dart yet are skipped rather than failing the run.
set -euo pipefail

cd "$(dirname "$0")/.."

targets=()
for dir in packages/*/test; do
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
