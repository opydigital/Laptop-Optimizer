# Opydigital - Laptop Optimizer

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](https://learn.microsoft.com/en-us/powershell/)
[![Platform: Windows 11](https://img.shields.io/badge/Platform-Windows%2011-0078D6.svg)](https://www.microsoft.com/windows)

A lightweight, hardware-aware PowerShell utility to optimize **Windows 11 laptop responsiveness and battery life**. It inspects your RAM, system storage (SSD/NVMe vs. HDD), and chassis type before applying safe, reversible tweaks — protected by a **mandatory first-run System Restore point** and full registry backups.

---

## Key Features

- **Hardware-Adaptive Optimization**: Automatically tailors tweaks to your system's usable RAM, storage media (including NVMe/RAID fallback detection), and portable chassis type.
- **Mandatory First-Run System Restore**:
  - Automatically enables Windows System Restore and reserves a **10% shadow storage quota** if disabled.
  - Confirms that a new restore point was actually created before modifying any system setting — **aborts safely if restore point creation fails**.
  - Records a completion marker so subsequent runs and boot tasks never trigger redundant restore points.
- **Idempotent Backup & One-Command Rollback**: Exports original registry keys and service configurations into `backup_tweaks/` on first run only, and supports full rollback via `-Revert`.
- **Automatic UAC Elevation**: Can be launched directly from a standard user PowerShell window — automatically prompts for Administrator privileges (UAC) when system changes are requested (`-DryRun` runs without elevation).
- **Persistent Program Files Installation**: On first install, copies `LaptopOptimizer.ps1` into `%ProgramFiles%\Opydigital\LaptopOptimizer\` along with backups, logs, and exclusions, so the script and scheduled task keep working even if the original download is deleted.
- **Headless Logon Foreground Priority Booster**: Automatically registered on first install as a Windows Scheduled Task pointing to `%ProgramFiles%\Opydigital\LaptopOptimizer\LaptopOptimizer.ps1`, running via `conhost.exe --headless` (zero taskbar window or console flash) to dynamically boost the active foreground application to `AboveNormal` while excluding critical system and anti-cheat processes.
- **Dry-Run Mode**: Inspect detected hardware and preview the exact optimization plan without Administrator privileges (`-DryRun`).

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
- **Privileges**: Administrator required to apply tweaks, create restore points, revert changes, or manage the scheduled task. (`-DryRun` works without elevation.)

---

## Quick Start

### Option A — One-Click Installer (Recommended)

1. Download `INSTALL.bat` and `LaptopOptimizer.ps1` into the same folder (or clone the repository).
2. **Double-click `INSTALL.bat`** — it automatically bypasses PowerShell's execution policy, prompts for UAC elevation, creates the first-run restore point, installs to `%ProgramFiles%\Opydigital\LaptopOptimizer\`, applies the optimizations, and registers the headless logon task.

### Option B — PowerShell CLI

1. Clone or download this repository:
   ```powershell
   git clone https://github.com/opydigital/Laptop-Optimizer.git
   cd Laptop-Optimizer
   ```

2. Preview your hardware profile and optimization plan (no admin required):
   ```powershell
   .\INSTALL.bat -DryRun
   ```

3. Apply optimizations, install to `%ProgramFiles%\Opydigital\LaptopOptimizer\`, and register the headless logon task (can be run from a regular user PowerShell — UAC elevation is requested automatically):
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LaptopOptimizer.ps1
   ```

4. *(Optional)* Re-register or remove the scheduled task later:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:ProgramFiles\Opydigital\LaptopOptimizer\LaptopOptimizer.ps1" -UninstallTask
   ```

---

## CLI Parameters

| Parameter | Admin Required | Description |
| :--- | :---: | :--- |
| `-DryRun` | No | Displays detected hardware and the optimization plan without making any changes. |
| `-Silent` | Yes | Applies the optimization plan without interactive `[Y/N]` confirmation. |
| `-Revert` | Yes | Restores all backed-up `.reg` files, service states, NTFS behavior, and power settings. |
| `-InstallTask` | Yes | Registers the `Opydigital_PriorityLoop` headless logon scheduled task and creates `priority_exclusions.txt`. |
| `-UninstallTask` | Yes | Removes the `Opydigital_PriorityLoop` scheduled task. |
| `-PriorityLoop` | Internal | Invoked automatically by Task Scheduler at logon; runs only the priority loop (never touches System Restore). |

---

## Process Exclusions (Priority Loop)

When `-InstallTask` is enabled, critical Windows processes (`dwm`, `explorer`, `audiodg`, `MsMpEng`, etc.) and common anti-cheat services (`vgc`, `EasyAntiCheat`, `BEService`, `FACEIT`, etc.) are excluded by default.

To exclude additional games or applications, edit `priority_exclusions.txt` (one process name per line, without `.exe`) — see [priority_exclusions.example.txt](priority_exclusions.example.txt).

---

## License

This project is licensed under the **GNU General Public License v3.0** — see the [LICENSE](LICENSE) file for details.
