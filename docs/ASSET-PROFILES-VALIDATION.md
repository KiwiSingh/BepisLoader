# Asset profiles and batch plugins validation

The development builds are BepisLoader 2.2.0 and Steamac 1.7.6 Kiwi Build 6. Publication awaits the requested app-bundle audit.

## Passed checks

- Universal macOS app compilation and icon injection.
- Profile merge: disjoint union, exact raw filenames, case-insensitive conflicts, priority reversal, individual disable, all disabled, removal and persistent JSON round trip.
- Batch plugins: multiple immutable snapshots, full-selection validation, duplicate/count/type/empty-file/symlink/directory rejection.
- Installer: payload hashing, upload before guest publication, stable profile publication, and unsupported capability/game/ABI/runtime rejection before mutation.
- Eight existing Steamac source regression checks.
- Static ARM64 Linux guest build: 53 bridge tests and 50 progress-agent tests.
- Isolated ARM64 SteamOS publication smoke using a private copy of the pinned EXE and exact bundled bootstrap payloads: old-package import, persistent state, stable root, conflicting raw `.img` winner selection, priority reversal, individual/all disable, stale-update rejection and retention of originals. The EXE was not launched.
- Isolated x64 native callback fixture under ARM64 Proton: replacement assets read through a relative Unix directory symlink; immutable snapshot, paired size/read callbacks, vanilla fallback and hook removal passed.

The last two fixtures used task directories on the VM's Zweidrive-backed disk. Game files, live game prefixes and Steam launch settings were not changed. These are synthetic installation/runtime checks, not gameplay proof for arbitrary mod combinations.

## User flow

Install matching Steamac, shut down and restart the VM with its bundled layer, then refresh BepisLoader. Add one or more extracted asset packages, review enablement/order, and apply. Copy the reported stable Steam Launch Options once. Use Manage asset mods for subsequent changes. Close the game before applying and restart afterward; Steam can stay open.

Existing package-specific launch paths must be changed once. Verified previous packages are imported disabled for review. Profiles retain historical snapshots; automatic disk cleanup is not included.

MBE CSV support now compiles the original game tables, merges changed cells in enabled-mod order, and appends `.ap.csv` rows afterward. Distinct cell edits coexist; later mods win competing edits. Requires Steamac with `assetMbeTablesV1`. Whole MBE replacements mixed with CSV edits to the same table are rejected for review. The native adapter resolves the managed stable folder before snapshotting its assets.

DigiRide's actual package compiled nine MBE tables and passed isolated checked publication alongside both costume mods, including pinned loader migration. Gameplay verification is pending; the previous Kanan/Inori pair was confirmed together using the direct snapshot path. Development builds remain unpublished pending bundle audit.
