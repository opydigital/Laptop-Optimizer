# Opydigital - Laptop Optimizer

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](https://learn.microsoft.com/en-us/powershell/)
[![Platform: Windows 11](https://img.shields.io/badge/Platform-Windows%2011-0078D6.svg)](https://www.microsoft.com/windows)

A lightweight, hardware-aware PowerShell utility to optimize **Windows 11 laptop responsiveness and battery life**. It inspects your RAM, system storage (SSD/NVMe vs. HDD), and chassis type before applying safe, reversible tweaks — protected by a **mandatory first-run System Restore point**, full registry backups, and one-click install/uninstall management via **`RUNME.bat`**.

---

## Key Features

- **One-Click Launcher (`RUNME.bat`)**: Double-click to launch with automatic `ExecutionPolicy Bypass`, UAC elevation, installation status detection, profile switching, and full uninstall.
- **Hardware-Adaptive Optimization**: Automatically tailors tweaks to your system's usable RAM, storage media (including NVMe/RAID fallback detection), and portable chassis type.
- **Mandatory First-Run System Restore**:
  - Automatically enables Windows System Restore and reserves a **10% shadow storage quota** if disabled.
  - Confirms that a new restore point was actually created before modifying any system setting — **aborts safely if restore point creation fails**.
  - Records a completion marker so subsequent runs and boot tasks never trigger redundant restore points.
- **Persistent Program Files Installation**: Installs `LaptopOptimizer.ps1`, backups (`backup_tweaks/`), logs, state (`install_state.json`), and exclusions under `%ProgramFiles%\Opydigital\LaptopOptimizer\`.
- **Two Logon Profiles (Anti-Cheat Safe)**:
  - **Profile `[1]` — Standard + Background Priority Loop**: Re-applies native optimizations at logon via Task Scheduler (headless, no UAC), then runs a foreground priority booster (`AboveNormal`) that **automatically pauses during Direct3D fullscreen games or active anti-cheats** (`vgc`, `EasyAntiCheat`, `BEService`, `FACEIT`, `EAAntiCheat`, etc.).
  - **Profile `[2]` — Native On-Boot Only (Recommended for Competitive Gamers)**: Re-applies native Windows optimizations **once at logon** via Task Scheduler (`conhost.exe --headless`, `RunLevel Highest`, no UAC prompt) so changes persist even if another program resets them, and **exits immediately (~1–2s)** — leaving **zero background processes** while gaming.
- **Built-in Uninstall & Full Rollback**: When an existing installation is detected, `RUNME.bat` offers **`[3] Uninstall & Revert All Changes`** (also available via `-Uninstall`), which removes the scheduled task, restores all backed-up registry/service/NTFS/power settings, and deletes `%ProgramFiles%\Opydigital\LaptopOptimizer\`.
- **Dry-Run Mode**: Inspect detected hardware, install status, and optimization plan without Administrator privileges (`RUNME.bat -DryRun`).

---

## Hardware Decision Matrix

| Optimization | Condition | What It Does |
| :--- | :--- | :--- |
| **Base Tweaks** | Always | Tunes `Win32PrioritySeparation`, shutdown/hang timeouts, NTFS `disablelastaccess`, disables P2P Delivery Optimization (`DODownloadMode = 0`), disables silent app installs/suggestions, and disables `DiagTrack`. |
| **Minimal Visual Effects (+ClearType)** | `RAM <= 4 GB` | Disables heavy window/taskbar animations while preserving ClearType font smoothing (`FontSmoothing = 2`). |
| **On-Demand Search Indexing** | `RAM <= 4 GB` | Sets `WSearch` to `demand` (manual) so search still works when needed without constant background indexing. |
| **Resident Kernel in RAM** | `RAM >= 16 GB` | Sets `DisablePagingExecutive = 1` to keep kernel-mode drivers in physical memory. |
| **SSD / NVMe Optimizations** | `Disk == SSD/NVMe` | Disables `SysMain` (Superfetch) and sets `StartupDelayInMSec = 0` for faster post-login app startup. |
| **Battery Turbo Boost Limit** | `Laptop / Portable` | Activates Balanced plan and sets `PROCTHROTTLEMAX = 99` on battery (DC) to cut heat, fan noise, and power draw while keeping full Turbo Boost on AC power. |

For a complete technical breakdown of every registry key, service, and command, see [docs/TWEAKS.md](docs/TWEAKS.md).

---

## Requirements

- **OS**: Windows 11 (Windows PowerShell 5.1+ built-in)
- **Privileges**: Administrator required (requested automatically via UAC). `-DryRun` works without elevation.

---

## Quick Start

### Option A — One-Click Launcher (Recommended)

1. Download `RUNME.bat` and `LaptopOptimizer.ps1` into the same folder (or clone the repository).
2. **Double-click `RUNME.bat`** — it automatically requests UAC elevation, shows your hardware & current install status, and lets you choose Profile `[1]`, Profile `[2]`, or `[3] Uninstall & Revert` (when already installed).

### Option B — PowerShell CLI

```powershell
# Preview without changes (no admin required)
.\RUNME.bat -DryRun

# Interactive setup / profile switch / uninstall
.\RUNME.bat

# Full uninstall and rollback from CLI
.\RUNME.bat -Uninstall
```

---

## CLI Parameters

| Parameter | Admin Required | Description |
| :--- | :---: | :--- |
| `-DryRun` | No | Displays detected hardware, install status, and optimization plan without making any changes. |
| `-Silent` | Yes | Applies Profile `[2]` (Native On-Boot) without prompts (combine with `-InstallTask` for Profile `[1]`). |
| `-Uninstall` | Yes | Removes the scheduled task, reverts all system settings, and deletes `%ProgramFiles%\Opydigital\LaptopOptimizer\`. |
| `-Revert` | Yes | Restores all backed-up `.reg` files, service states, NTFS behavior, and power settings. |
| `-InstallTask` | Yes | Registers `Opydigital_LaptopOptimizer` in Profile `[1]` mode (`-BootApply -PriorityLoop`). |
| `-UninstallTask` | Yes | Removes the `Opydigital_LaptopOptimizer` scheduled task without reverting registry tweaks. |
| `-BootApply` | Internal | Invoked automatically by Task Scheduler at logon to silently re-apply native tweaks and exit. |
| `-PriorityLoop` | Internal | Invoked automatically by Task Scheduler in Profile `[1]` after `-BootApply`. |

---

## Process Exclusions (Profile 1 Priority Loop)

When Profile `[1]` is selected, critical Windows processes (`dwm`, `explorer`, `audiodg`, `MsMpEng`, etc.) and common anti-cheat services (`vgc`, `EasyAntiCheat`, `BEService`, `FACEIT`, etc.) are excluded by default, and the loop automatically pauses during fullscreen Direct3D games or active anti-cheats.

To exclude additional apps, edit `%ProgramFiles%\Opydigital\LaptopOptimizer\priority_exclusions.txt` (one process name per line, without `.exe`) — see [priority_exclusions.example.txt](priority_exclusions.example.txt).

---

## License

This project is licensed under the **GNU General Public License v3.0** — see the [LICENSE](LICENSE) file for details.
