# Changelog

All notable changes to **Opydigital - Laptop Optimizer** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-11-27

### Added
- Full PowerShell 5.1+ implementation (`LaptopOptimizer.ps1`) with color-coded terminal UI and hardware-adaptive decision plan.
- Single-pass hardware detection for usable RAM, SSD/NVMe/HDD storage (including NVMe/SpindleSpeed fallback), portable chassis types, and Windows build.
- Mandatory first-run System Restore point creation with automatic System Restore activation and 10% shadow storage quota reservation if disabled.
- Language-independent System Restore status detection (`RPSessionInterval` + `Win32_ShadowStorage`) and safe temporary bypass of Windows' 24-hour restore point throttle.
- Idempotent registry and service backup in `backup_tweaks/` with full rollback via `-Revert`.
- CLI flags: `-DryRun`, `-Silent`, `-Revert`, `-InstallTask`, `-UninstallTask`, and `-PriorityLoop`.
- One-click `RUNME.bat` launcher with automatic `ExecutionPolicy Bypass` and argument forwarding.
- Automatic UAC self-elevation (`Start-Process -Verb RunAs`) so `LaptopOptimizer.ps1` can be launched directly from a standard user PowerShell window.
- Persistent installation to `%ProgramFiles%\Opydigital\LaptopOptimizer\LaptopOptimizer.ps1` with installation status detection (`install_state.json`) and built-in full uninstall (`[3]` / `-Uninstall`).
- Unified headless logon Scheduled Task (`Opydigital_LaptopOptimizer` via `conhost.exe --headless`, no UAC at boot):
  - **Profile `[1]` (Standard + Background Priority Loop)**: re-applies native tweaks at logon (`-BootApply`) and runs the foreground priority loop with Direct3D fullscreen and anti-cheat auto-pause.
  - **Profile `[2]` (Native On-Boot Only — Competitive Gamers)**: re-applies native tweaks once at logon (`-BootApply`) and exits immediately with zero background loop.
- ClearType font-smoothing preservation when applying minimal visual effects on `<= 4 GB` RAM systems.
- English documentation (`README.md`, `docs/TWEAKS.md`, `CONTRIBUTING.md`, `priority_exclusions.example.txt`).
