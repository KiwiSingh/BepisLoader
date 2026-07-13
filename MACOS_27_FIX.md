# macOS 27 Golden Gate crash fix

Version: 1.0.3

## Fixed

- Prevents `EXC_BREAKPOINT / SIGTRAP` crashes when AppKit requests a stale bottle row during `NSTableView.reloadData()` and layout reconciliation.
- Adds equivalent bounds validation to the game and mod tables and their selection/toggle callbacks.
- Removes force-unwrapped bottle name-label access in the affected table-cell construction path.
- Asserts that bottle/game model updates which trigger AppKit reloads occur on the main thread.
- Corrects the Swift Package target path from the nonexistent `Sources/BepInExMacClient` to `Sources/BepisLoader`.
- Bumps the generated app bundle version to 1.0.3.

## Build on macOS

```bash
chmod +x build_app.sh
./build_app.sh
open .build/release/BepisLoader.app
```
