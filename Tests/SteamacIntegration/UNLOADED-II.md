# Digimon Unloaded-II integration

The cockpit launch check now adds read-only Digimon diagnostics using the
existing hello, executable inspection, Proton resolution and Reloaded inventory
operations. Windows payloads remain win-x64 even on ARM64 SteamOS. Inventory
never grants modded launch. The native loose-MVGL-asset prototype lives in the
companion Unloaded-II branch and does not yet have an attested installation or
launch capability here.

Validation:

```
bash ./build_app.sh
swiftc Sources/BepisLoader/Compatibility/SteamacUnloadedIIPlan.swift Tests/SteamacIntegration/unloaded_plan_test.swift -o .build/unloaded-plan-tests
.build/unloaded-plan-tests
python3 Tests/SteamacIntegration/test_41f_regressions.py
```

Full app build passes with existing unrelated warnings. Six compiled policy
cases and eight existing source regression checks pass. Protocol failures,
unknown executable architecture, unsupported games and absent Proton all block.
No guest mutation or launch is added.

This branch starts at committed main in an isolated checkout. The original
BepisLoader checkout's uncommitted Steamac/recovery changes remain untouched.
Merge this small diagnostics addition into that work only after reviewing any
cockpit conflicts; no reset/stash/cleanup is required.
