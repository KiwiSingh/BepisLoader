# 🥤 BepisLoader

![BepisLoader Logo](BepisLogo.png)

**BepisLoader** is a native macOS power-tool for installing and managing **BepInEx 6** mods in Windows Unity games. It is specifically designed to handle the complexities of macOS compatibility layers like **CrossOver**, **CrossOver Preview**, **Whisky**, and **GameHub**.

---

## 🚀 Key Features

| Feature | Details |
|---|---|
| **Universal Bottle Scanning** | Automatically detects bottles in CrossOver (including Preview builds), GameHub, Whisky, and external drives. |
| **External SSD Support** | Scans `dosdevices` to find games installed on external APFS/ExFAT drives. |
| **BepInEx 6 "Bleeding Edge"** | Automatically fetches and configures the latest BepInEx 6 IL2CPP builds for modern games. |
| **CrossOver "Nuclear" Patching** | Directly patches `cxbottle.conf` to ensure mods load even when Steam tries to block them. |
| **Auto-Quarantine Removal** | Automatically runs `xattr -rd com.apple.quarantine` on all BepInEx files to prevent macOS "Developer cannot be verified" errors. |
| **Persistence** | Remembers your games, engine selections (Mono/IL2CPP), and bottle assignments across launches. |

---

## 🛠 Installation & Usage

1. **Download**: Grab the latest `BepisLoader.app` from the Releases page.
2. **Select Game**: The app will scan your bottles. If your game is on an external drive, use the **"+ Add Game"** button.
3. **Install**: Click **"Install BepisLoader"**. It will download the correct version and configure your Wine registry.
4. **Add Mods**: Drag and drop your `.dll` mod files into the Plugins tab.
5. **Launch**: 
   - **IMPORTANT**: For Steam games on Mac, you must launch the game **directly through CrossOver** to ensure the mods are injected.
   - Look for the BepInEx terminal to pop up on launch!

---

## 🏗 Building from Source

If you want to build BepisLoader yourself:

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
> [!TIP]
> You can drag this `.app` into your `/Applications` folder for permanent use.

---

## 📋 Technical Details

- **Language**: Swift 5.9 (Native macOS)
- **Minimum OS**: macOS 13.0 Ventura
- **Compatibility**: Supports both Intel and Apple Silicon (via Rosetta 2 for the games themselves).
- **Injection Method**: Uses `winhttp.dll` or `version.dll` proxying via `WINEDLLOVERRIDES`.

---

## 🤝 Credits

Created by **Kiwi Singh** and the community. Special thanks to the BepInEx team for the legendary modding framework.

*Disclaimer: BepisLoader is not affiliated with PepsiCo, BepInEx, or CodeWeavers. Stay hydrated.*
