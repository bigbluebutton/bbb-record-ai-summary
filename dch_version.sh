#!/bin/bash

BASH_COMPAT="4.2"

# Converts a semver 2.0.0 compatible git tag to a Debian-compatible version string.
# Outputs: DCH_VERSION=<version>
GIT_TAG=$(git describe --tags --abbrev=0 "$@")
GIT_DESCRIBE=$(git describe --tags --long --dirty=.d$(date +%Y%m%d) "$@")
GIT_EXTRA="${GIT_DESCRIBE#${GIT_TAG}}"
GIT_TAG="${GIT_TAG//-/~}"
GIT_TAG="${GIT_TAG//alpha./alpha}"
GIT_TAG="${GIT_TAG//beta./beta}"
GIT_TAG="${GIT_TAG//rc./rc}"
DCH_VERSION="${GIT_TAG#v}"

GIT_EXTRA="${GIT_EXTRA#-}"
GIT_DISTANCE="${GIT_EXTRA%%-*}"
GIT_BUILD="${GIT_EXTRA#${GIT_DISTANCE}-}"
GIT_BUILD_HASH="${GIT_BUILD%%.*}"
if [[ $GIT_DISTANCE == 0 ]]; then
    GIT_BUILD="${GIT_BUILD#${GIT_BUILD_HASH}}"
    GIT_BUILD="${GIT_BUILD#.}"
fi
if [[ -n $GIT_BUILD ]]; then
    DCH_VERSION+=".post${GIT_DISTANCE}+${GIT_BUILD}"
elif [[ $GIT_DISTANCE != 0 ]]; then
    DCH_VERSION+=".post${GIT_DISTANCE}"
fi

echo "DCH_VERSION=$(printf %q "${DCH_VERSION}")"
