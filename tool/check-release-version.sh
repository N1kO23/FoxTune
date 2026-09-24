#!/usr/bin/env bash
# Checks a release tag against the app's version before anything is built.
#
# The version comes from the app's pubspec; the tag only names it. A tag that
# disagrees would publish one version under the name of another. And the build
# number after the "+" is Android's version code: Android will not install a
# build over one with a higher code, so a release whose number went backwards
# could never be installed over the one before it.
#
# Usage: tool/check-release-version.sh <tag>
#   The tag is v<version>: v1.2.0 for "version: 1.2.0+7". It need not exist
#   yet; an untagged commit is checked as it stands.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
pubspec=app/foxtune_app/pubspec.yaml
if [ $# -ne 1 ]; then
  echo "Usage: $0 <tag>" >&2
  exit 1
fi
tag=$1

# Reads a pubspec on stdin and prints its version, e.g. 1.2.0+7.
version_of() {
  sed -n 's/^version:[[:space:]]*//p' | tr -d "\"' \r" | head -n 1
}

version=$(version_of < "$root/$pubspec")
if [[ ! $version =~ ^([0-9]+\.[0-9]+\.[0-9]+[^+]*)\+([0-9]+)$ ]]; then
  echo "$pubspec has version '$version'; a release needs one like 1.2.0+7." >&2
  exit 1
fi
name=${BASH_REMATCH[1]}
build=${BASH_REMATCH[2]}

if [ "$tag" != "v$name" ]; then
  echo "Tag $tag does not match the app's version $name." >&2
  echo "Tag the release v$name, or change the version in $pubspec first." >&2
  exit 1
fi

# The newest other release tag the tagged commit builds on.
ref=$tag
git -C "$root" rev-parse -q --verify "$tag^{commit}" > /dev/null || ref=HEAD
previous=$(git -C "$root" describe --tags --abbrev=0 --match 'v*' \
  --exclude "$tag" "$ref" 2> /dev/null || true)

if [ -n "$previous" ]; then
  previous_version=$(git -C "$root" show "$previous:$pubspec" | version_of)
  previous_build=${previous_version##*+}
  if [[ $previous_build =~ ^[0-9]+$ ]] && [ "$build" -le "$previous_build" ]; then
    echo "Build number $build is not above $previous_build, which $previous shipped with." >&2
    echo "Each release needs a higher one; raise the number after the + in $pubspec." >&2
    exit 1
  fi
fi

echo "Releasing $name, build $build${previous:+, after $previous}."
