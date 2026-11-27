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
- One-click `INSTALL.bat` launcher with automatic `ExecutionPolicy Bypass` and argument forwarding.
- Automatic UAC self-elevation (`Start-Process -Verb RunAs`) so `LaptopOptimizer.ps1` can be launched directly from a standard user PowerShell window.
- Persistent installation to `%ProgramFiles%\Opydigital\LaptopOptimizer\LaptopOptimizer.ps1` on first run, with automatic Scheduled Task registration pointing to the installed copy.
- Headless logon Scheduled Task (`conhost.exe --headless`) for dynamic foreground process priority boosting (`AboveNormal`), with built-in system/anti-cheat exclusions and user-configurable `priority_exclusions.txt`.
- ClearType font-smoothing preservation when applying minimal visual effects on `<= 4 GB` RAM systems.
- English documentation (`README.md`, `docs/TWEAKS.md`, `CONTRIBUTING.md`, `priority_exclusions.example.txt`).
