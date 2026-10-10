# Music profiles (development 2.3.0)

The asset-mod importer now accepts the supported Ryo BGM folder layout and its data-only dependencies. It keeps raw HCA/YAML names and bytes, ignores macOS folder metadata, and combines music with the existing texture/MBE profile. Distinct tracks for a cue form a random playlist; same-file replacements and settings follow profile priority.

Requires Steamac Kiwi Build 7 with `assetAudioBanksV1`. The guest compiles original sound banks, and the native adapter replaces matching memory-loaded banks. Existing stable launch options remain valid. Current support covers unencrypted HCA and volume YAML in single-cue memory-backed BGM banks; arbitrary Ryo runtime plugins/settings are not supported.

Tests: package parsing and immutable snapshots, installer preflight, ARM64 compiler bank composition/input rejection, full 46-track/17-bank conversion, isolated Proton callback replacement/fallback, and checked combined profile publication passed. Audible playback is pending gameplay confirmation. Builds remain unpublished pending fresh bundle audit.
