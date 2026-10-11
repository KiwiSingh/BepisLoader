#!/bin/bash
set -euo pipefail
# Caller controls the disk used for binaries and compiler caches.
: "${BEPIS_TEST_ROOT:?Set BEPIS_TEST_ROOT to a writable test directory}"
mkdir -p "$BEPIS_TEST_ROOT"
cd "$(dirname "$0")/../.."
common=(Sources/BepisLoader/Compatibility/ReShadePackage.swift)
swiftc -module-cache-path "$BEPIS_TEST_ROOT/swift-cache" "${common[@]}" Tests/SteamacIntegration/reshade_package_test.swift -o "$BEPIS_TEST_ROOT/reshade-package-tests"
"$BEPIS_TEST_ROOT/reshade-package-tests"
swiftc -module-cache-path "$BEPIS_TEST_ROOT/swift-cache" "${common[@]}" Sources/BepisLoader/Compatibility/SteamacReShadeInstaller.swift Sources/BepisLoader/Compatibility/SteamacLaunchOptions.swift Tests/SteamacIntegration/reshade_installer_test.swift -o "$BEPIS_TEST_ROOT/reshade-installer-tests"
"$BEPIS_TEST_ROOT/reshade-installer-tests"
