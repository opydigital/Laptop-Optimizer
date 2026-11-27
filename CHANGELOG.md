# Changelog

All notable changes to **Opydigital - Laptop Optimizer** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.4] - 2026-11-27

### Added
- **Standby RAM Cache & Temp Cleaner** (`[4]` in Main Menu / `-CleanRam`, also runs once after optimization): enables `SeProfileSingleProcessPrivilege` and purges the Windows Standby Memory List via `ntdll.dll` (`NtSetSystemInformation 0x50`) + cleans `%TEMP%`, displaying freed RAM in MB.
- **Complementary NTFS Optimizations** (all profiles, reversible): `fsutil behavior set disable8dot3 1` and `fsutil behavior set memoryusage 2` (for `>= 8 GB` RAM).
- **Enhanced Gaming Laptop Suite** (all reversible):
  - Windows Defender background scan CPU cap (`AvgCPULoadFactor = 15`, keeping real-time protection active).
  - Additional GameBar/GameDVR tweaks (`AppCaptureEnabled = 0`, `AllowAutoGameMode = 1`, `ShowStartupPanel = 0`).
  - Conditional NVIDIA telemetry disable when an NVIDIA GPU is detected (preserves GPU power management for laptop battery life).
  - Wired Ethernet Energy-Efficient Ethernet (`*EEE` / `EnableGreenEthernet = 0`) disabled to reduce ping jitter (leaves Wi-Fi untouched for battery life).
- **Optional Mouse Acceleration Off** (`[11/11]` in Custom Debloat only — skipped in Automatic Debloat to preserve laptop touchpad feel).
- **Post-Action Restart Prompt**: offers `[R] Restart Windows now` alongside `[Enter] Return to Main Menu` after applying changes.
- Shifted **Uninstall & Revert All Changes** to menu option **`[5]`**.

## [1.0.3] - 2026-11-27

### Added
- **Process & Thread Reduction Across All Profiles** (with full backup & rollback):
  - `svchost.exe` consolidation (`SvcHostSplitThresholdInKB = 0x04000000` / 64 GB), significantly reducing process count, threads, and handle overhead on 16 GB+ systems.
  - Expanded safe idle services set to Manual (`DPS`, `PcaSvc`, `TrkWks`, `StiSvc`, `BITS`, `DusmSvc`) plus `WSearch` set to on-demand in Gaming mode.
  - Disabled noisy Windows telemetry/maintenance scheduled tasks (`Microsoft Compatibility Appraiser`, `ProgramDataUpdater`, `Autochk\Proxy`, `Consolidator`, `UsbCeip`, `DiskDiagnosticDataCollector`, `DmClient`).
  - Disabled Microsoft Edge `BackgroundModeEnabled` & `StartupBoostEnabled` and disabled **Copilot auto-startup** (keeping Copilot installed for users who want to open it manually).
- **Debloat Submenu (`[3]`)**: Added choice between **`[1]` Automatic Debloat** (applies all 10 safe tweaks in one click) and **`[2]` Custom Debloat** (step-by-step `[Y/N]` selection), with `[0] Back to Main Menu`.
- Main menu loop: automatically returns to the Main Menu after completing tasks, with `Exit` exclusively in the Main Menu.

### Removed
- Removed forced numeric tray battery percentage (`IsBatteryPercentageEnabled`) to respect personal UI preferences.

## [1.0.2] - 2026-11-27

### Added
- **Interactive Windows 11 Debloat Wizard** as main menu option **`[3]`** (and `-Debloat` CLI flag), based on [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil). Prompts `[Y/N]` step-by-step across 10 curated categories: Telemetry & Diagnostics, Activity History, Location Tracking, Consumer Features, Copilot & Windows AI, Bing Search & Start Recommendations, Widgets, Microsoft Edge Debloat, Pre-Installed AppX Bloatware, and Quality-of-Life UI tweaks.
- **Laptop-specific WinUtil optimizations** added to Standard & Gaming profiles (with full backup and rollback):
  - S0 Modern Standby network drain fix on battery (`DCSettingIndex = 0`).
  - System tray numeric battery percentage (`IsBatteryPercentageEnabled = 1`).
  - BIOS bloatware injection block (`DisableWpbtExecution = 1`) and peripheral companion app block (`PreventDeviceMetadataFromNetwork = 1`).
  - File Explorer automatic folder-type discovery disabled (`FolderType = NotSpecified`).
  - Safe idle services (`MapsBroker`, `RetailDemo`, `Fax`, `WalletService`) set to manual and safe `%TEMP%` cleanup on apply.
- Shifted **Uninstall & Revert All Changes** to menu option **`[4]`** and expanded `-Revert` / `-Uninstall` to restore debloat policy keys and services (`WerSvc`, `lfsvc`).

## [1.0.1] - 2026-11-27

### Added
- **Gaming Laptop Optimization Suite** (`-Gaming` / Step 1 Menu `[2]`): HAGS (`HwSchMode = 2`), Game Mode, Game DVR background recording disabled, MMCSS gaming priorities & `NetworkThrottlingIndex = 0xffffffff`, and AC-only PCIe ASPM + USB Selective Suspend disabled (preserving VBS/HVCI for anti-cheats and DC battery savings).
- **Dedicated GPU (`dGPU`) detection** via `Win32_VideoController` displayed in the hardware summary.
- **Two-step interactive menu**: Step 1 selects **Standard Laptop**, **Gaming Laptop**, or **Uninstall & Revert**; Step 2 submenu lets both suites choose between **On-Boot Re-Apply + Background Priority Loop** or **Native On-Boot Only (Recommended for Competitive Gamers)**.
- Full backup and rollback support for all Gaming suite registry keys and AC power settings.

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
