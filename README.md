# 🥤 BepisLoader

![BepisLoader Logo](BepisLogo.png)

**BepisLoader** is a native macOS power-tool for installing and managing **BepInEx** mods in Windows Unity games. It is specifically designed to handle the complexities of macOS compatibility layers like **CrossOver**, **CrossOver Preview**, **Whisky**, **GameHub**, **Wineskin**, and **Porting Kit**.

---

## 🚀 Key Features

| Feature | Details |
|---|---|
| **Universal Bottle Scanning** | Automatically detects bottles in CrossOver (including Preview builds), Whisky, GameHub, Wineskin, Porting Kit, and `~/.wine`. |
| **External SSD Support** | Reads GameHub's `game_container_store.json` and resolves `dosdevices/` symlinks to find games installed anywhere, including external APFS/ExFAT drives. |
| **Mono & IL2CPP Support** | Auto-detects the Unity backend and downloads the correct BepInEx build — stable 5.x for Mono, bleeding-edge 6.x for IL2CPP. |
| **Per-Layer Config Patching** | Patches `cxbottle.conf` (CrossOver), `bottle.plist` (Whisky), `game-settings/<hash>.json` + Wine registry (GameHub), `wine.cfg` (Porting Kit), and `Info.plist` (Wineskin) so mods load automatically when you hit Play. |
| **Direct Env Injection** | For GameHub, BepisLoader injects `DOORSTOP_ENABLE`, `DOORSTOP_INVOKE_DLL_PATH`, and mandatory Mono runtime paths directly into the `environment` dictionary in GameHub's settings JSON for maximum reliability. |
| **Auto-Quarantine Removal** | Automatically runs `xattr -rs com.apple.quarantine` on all BepInEx files to prevent macOS "Developer cannot be verified" errors. |
| **Mod Manager** | Install `.dll` plugins by file picker; handles macOS security scoping for external drives; reads `[BepInPlugin]` metadata for display. |

---

## 🛠 Installation & Usage

1. **Download**: Grab the latest `BepisLoader.app` from the Releases page.
2. **Select Game**: The app will scan your bottles automatically. If your game is on an external drive, use the **"+ Add Game → From Mac / External Drive"** option.
3. **Install**: Click **"Install BepisLoader"**. It will download the correct BepInEx version, configure your Wine registry, and patch your compatibility layer's config files.
4. **Add Mods**: Use **"+ Add Mod…"** to install `.dll` plugin files into the game's `BepInEx/plugins/` folder.
5. **Launch**:
   - **IMPORTANT**: Launch the game **directly through your compatibility layer** (CrossOver, Whisky, GameHub, etc.)
   - **IL2CPP Games**: On the very first launch, you may see a black screen for 10-30 seconds. **Do not close the game.** BepInEx is generating interop assemblies (check `BepInEx/LogOutput.log` to see progress). Subsequent launches will be instant.

---

## 🏗 Building from Source

```bash
# Clone the project
git clone https://github.com/yourusername/BepisLoader
cd BepisLoader

# Build the .app bundle using the included script
chmod +x build_app.sh inject_icon.sh
./build_app.sh

# (Optional) Inject the Bepis icon into the bundle
./inject_icon.sh BepisLogo.png
```

The resulting `BepisLoader.app` will be in `.build/release/`.

---

## 📋 Technical Details

- **Language**: Swift 5.9 (Native macOS)
- **Minimum OS**: macOS 13.0 Ventura (macOS 26 Tahoe for GameHub users)
- **Compatibility**: Supports both Intel and Apple Silicon (via Rosetta 2 for the games themselves).
- **Injection Method**: Uses `winhttp.dll` + `version.dll` proxying via `WINEDLLOVERRIDES`.
- **GameHub Injection**: Patches `game-settings/<hash>.json` at `settings.environment`. Uses absolute `Z:\` paths for all Doorstop variables to support games on external volumes.
- **Security Scoping**: BepisLoader uses `startAccessingSecurityScopedResource` when copying mods from external drives to bypass macOS read/write restrictions.

---

## 📝 Changelog

### v1.0.2
- **Fixed GameHub mod injection.** BepInEx mods now load correctly in GameHub games via authoritative `settings.environment` patching.
- **Fixed Mod Installation (Security Scoping)**: Resolved a macOS permission issue where mod DLLs selected via the GUI were being blocked from copying to external drives.
- **IL2CPP Runtime Support**: Added automatic injection of `DOORSTOP_MONO_RUNTIME_LIB` and `DOORSTOP_MONO_CONFIG_DIR`.
- **Fixed Wine registry corruption** by using `wine reg add` via the layer's own Wine binary.
- **External SSD Discovery**: Fully supported via `game_container_store.json` and `dosdevices` resolving.
- **UI Refinement**: Improved the mod list refresh logic.

### v1.0.1
- Added per-layer config patching for Whisky, GameHub, Porting Kit, and Wineskin.
- GameHub bottle names now resolved from `game_container_store.json`.

### v1.0.0
- Initial release.

---

## 🤝 Credits

Created by **Kiwi Singh** and the community. Special thanks to the BepInEx team for the legendary modding framework.

------------------------------------------------------------------------

## ☕ Support the Project

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/kiwisingh)\

------------------------------------------------------------------------

*Disclaimer: BepisLoader is not affiliated with PepsiCo, BepInEx, CodeWeavers, or GameSir. Stay hydrated.*
