#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
xcrun clang -fobjc-arc -c MacEngine/VirtualDesktop.m -o "$temp/VirtualDesktop.o"
xcrun swiftc -swift-version 5 -import-objc-header MacEngine/MacEngine-Bridging-Header.h \
    Shared/DisplayLink.swift MacEngine/DesktopVideoOutput.swift MacEngine/MacDisplayEngine.swift \
    "$temp/VirtualDesktop.o" Tests/MacEngine/MacEngineChecks.swift -o "$temp/MacEngineChecks"
"$temp/MacEngineChecks"
