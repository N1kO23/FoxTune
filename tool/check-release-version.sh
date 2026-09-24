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

# The highest build number of the release tags the tagged commit builds on. A
# tag whose pubspec does not match it could never have passed this check, so
# it was never released - a botched tag left behind - and does not count.
ref=$tag
git -C "$root" rev-parse -q --verify "$tag^{commit}" > /dev/null || ref=HEAD
previous=""
previous_build=0
while read -r other; do
  [ "$other" != "$tag" ] || continue
  other_version=$(git -C "$root" show "$other:$pubspec" 2> /dev/null | version_of || true)
  [[ $other_version =~ ^([0-9]+\.[0-9]+\.[0-9]+[^+]*)\+([0-9]+)$ ]] || continue
  [ "$other" = "v${BASH_REMATCH[1]}" ] || continue
  if [ -z "$previous" ] || [ "${BASH_REMATCH[2]}" -gt "$previous_build" ]; then
    previous=$other
    previous_build=${BASH_REMATCH[2]}
  fi
done < <(git -C "$root" tag --merged "$ref" --list 'v*')

if [ -n "$previous" ] && [ "$build" -le "$previous_build" ]; then
  echo "Build number $build is not above $previous_build, which $previous was tagged with." >&2
  echo "Each release needs a higher one; raise the number after the + in $pubspec." >&2
  echo "If $previous never became a release, delete that tag instead." >&2
  exit 1
fi

echo "Releasing $name, build $build${previous:+, after $previous}."
