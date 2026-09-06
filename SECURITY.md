# Security notes

HCE Co-op Expanded runs inside the Halo process through UE4SS.

The project-owned native components are intentionally narrow in scope:

- `HCEPerspectiveNative.dll` applies the validated release-specific in-process Perspective hook required by the feature.
- `HCEPerspectiveContextShift.dll` calls a private export in `HCEPerspectiveNative.dll` and performs no independent code scan.
- The project-owned `xinput1_4.dll` handles the local XInput slot route and forwards to Windows System32 XInput.
- `HCEXInputSteamBypass.dll` is the adaptive `Controllers=1` companion. On Steam it can preserve a Steam Input relay while presenting the first gamepad as Halo's logical P2 slot. On WinGDK it accepts only the native Xbox/System-XInput route.

The adaptive input companion is deliberately constrained:

- it modifies only the project-owned local `xinput1_4.dll` entry/cache used by this mod;
- it does not patch `HaloCampaignEvolved.exe`;
- it does not patch `gameoverlayrenderer64.dll`;
- it does not install a driver or virtual controller;
- it does not use an AOB/code-cave scan;
- it does not download code, launch helper processes, modify firewall rules, or change network adapters.

For handoff between the native companion and Lua, the companion writes a small temporary `HCEXInputSteamBypass.snapshot` diagnostics/state file in the current working directory. Co-op Expanded reads it immediately and attempts to delete it. It contains routing return codes/pointers and no account credentials or gameplay save data.

Because the project includes unsigned in-process native DLLs and an `xinput1_4.dll` proxy/forwarder, heuristic antivirus engines can scrutinize these files more aggressively than ordinary data-only mods.

v1.10.0 intentionally retains the already validated Perspective binaries and the complete-package project-owned `xinput1_4.dll`. The tested adaptive router v0.7.4 binary is also promoted unchanged from the successful hardware-tested pre-release build. Reference SHA-256 hashes are included in `PROJECT-FILE-HASHES.txt`; the adaptive-router source is provided in the separate v1.10.0 Source Snapshot.
