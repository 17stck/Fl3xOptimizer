# Fl3xOptimizer

Windows + FiveM low-latency optimizer for gaming PCs. WinUI 3 / .NET 8.

> Source is closed. Only the launcher script and signed obfuscated releases
> live in this repo. Build artifacts ship via [Releases](../../releases/latest).

## Install & run

Open PowerShell and paste:

```powershell
iwr -useb https://raw.githubusercontent.com/17stck/Fl3xOptimizer/main/launcher.ps1 | iex
```

What happens:

1. Downloads the latest `Fl3xOptimizer.exe` from this repo's Releases page
2. Caches it at `%LOCALAPPDATA%\Fl3xOptimizer\`
3. Launches with UAC elevation (admin is required for HKLM / service / netsh tweaks)

On subsequent runs the same command just launches the cached exe instantly —
no re-download.

### Force re-download (after a new release ships)

```powershell
& ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/17stck/Fl3xOptimizer/main/launcher.ps1).Content)) -Force
```

### Uninstall

```powershell
& ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/17stck/Fl3xOptimizer/main/launcher.ps1).Content)) -Uninstall
```

## Direct download

If PowerShell isn't your thing:

[Fl3xOptimizer.exe (latest)](https://github.com/17stck/Fl3xOptimizer/releases/latest/download/Fl3xOptimizer.exe)

Double-click the downloaded .exe to launch. Windows SmartScreen may warn on
first run because the binary isn't code-signed — click **More info → Run anyway**.

## Requirements

- Windows 10 build 17763+ or Windows 11 (x64)
- ~250 MB free disk (self-extracts on first launch)
- Admin permission (required for system tweaks)

No need to install .NET runtime, WinUI 3, or anything else — the .exe is
self-contained.

## What it does

Reversible, snapshot-first system tweaks targeting low-latency online gaming
(FiveM, GTA Online, competitive FPS):

- Network stack (TCP/IP, Nagle, QoS, NIC, DNS, AFD buffers)
- Windows services / background app reduction
- GPU vendor-specific (NVIDIA telemetry off + NVCP profile, AMD per-app
  Adrenalin profile, MMCSS Games)
- FiveM client (process priority, commandline flags, cache hygiene,
  Defender exclusion)
- Input precision (raw mouse, low frame latency, input queue sizes)
- Savenz-style .reg bundles

Every change is individually revertible from the UI. Nothing is silent.

## License

All rights reserved. The launcher script is provided for distribution of
the official binary only. Do not redistribute or modify the binary.
