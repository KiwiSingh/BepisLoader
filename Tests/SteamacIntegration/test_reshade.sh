#!/bin/bash
set -euo pipefail
# Caller controls the disk used for binaries and compiler caches.
: "${BEPIS_TEST_ROOT:?Set BEPIS_TEST_ROOT to a writable test directory}"
mkdir -p "$BEPIS_TEST_ROOT"
cd "$(dirname "$0")/../.."
common=(Sources/BepisLoader/Compatibility/ReShadePackage.swift Sources/BepisLoader/Compatibility/ModArchive.swift)
swiftc -module-cache-path "$BEPIS_TEST_ROOT/swift-cache" "${common[@]}" Tests/SteamacIntegration/reshade_package_test.swift -o "$BEPIS_TEST_ROOT/reshade-package-tests"
"$BEPIS_TEST_ROOT/reshade-package-tests"
swiftc -module-cache-path "$BEPIS_TEST_ROOT/swift-cache" "${common[@]}" Sources/BepisLoader/Compatibility/SteamacReShadeInstaller.swift Sources/BepisLoader/Compatibility/SteamacLaunchOptions.swift Tests/SteamacIntegration/reshade_installer_test.swift -o "$BEPIS_TEST_ROOT/reshade-installer-tests"
"$BEPIS_TEST_ROOT/reshade-installer-tests"

if [[ -n "${BEPIS_ARCHIVE_FIXTURES:-}" ]]; then
    swiftc -module-cache-path "$BEPIS_TEST_ROOT/swift-cache" "${common[@]}" Sources/BepisLoader/Compatibility/AssetModPackage.swift Tests/SteamacIntegration/mod_archive_test.swift -o "$BEPIS_TEST_ROOT/mod-archive-tests"
    "$BEPIS_TEST_ROOT/mod-archive-tests"
fi

if [[ "${BEPIS_TEST_LARGE_PACKAGES:-0}" == 1 ]]; then
    swiftc -module-cache-path "$BEPIS_TEST_ROOT/swift-cache" Sources/BepisLoader/Compatibility/AssetModPackage.swift Tests/SteamacIntegration/package_size_test.swift -o "$BEPIS_TEST_ROOT/package-size-tests"
    "$BEPIS_TEST_ROOT/package-size-tests"
fi
