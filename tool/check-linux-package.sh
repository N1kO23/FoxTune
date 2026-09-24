#!/bin/sh
# Installs a FoxTune .deb or .rpm on the system this runs on, and checks the
# app is in place and links: /usr/bin/foxtune leads to the bundle, and every
# library it needs resolves - glibc's symbol versions included, so a system
# older than the bundle allows fails here rather than at launch.
#
# Meant for CI, as root, on the runner and in containers of other
# distributions. It installs packages, so it is not for your own machine.
#
# Usage: tool/check-linux-package.sh <package.deb|package.rpm>
set -eu

package=$1

case $package in
  *.deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q "$package"
    ;;
  *.rpm)
    dnf install -y -q "$package" /usr/bin/ldd
    ;;
  *)
    echo "Not a .deb or .rpm: $package" >&2
    exit 1
    ;;
esac

test "$(readlink -f /usr/bin/foxtune)" = /usr/lib/foxtune/foxtune

if ldd /usr/lib/foxtune/foxtune | grep "not found"; then
  echo "FoxTune is missing libraries on this system." >&2
  exit 1
fi

echo "FoxTune installs here, and everything it links against resolves."
