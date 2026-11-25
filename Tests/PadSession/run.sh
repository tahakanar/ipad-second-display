#!/bin/sh
set -eu
: "${1:?Pass the UUID of a booted iPad simulator}"
cd "$(dirname "$0")/../.."
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target "$(uname -m)-apple-ios15.0-simulator" \
    Shared/DisplayLink.swift iPadClient/VideoSurface.swift iPadClient/PadSession.swift \
    Tests/PadSession/PadSessionChecks.swift -o "$temp/checks"
xcrun simctl spawn "$1" "$temp/checks"
