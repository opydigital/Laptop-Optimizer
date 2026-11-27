# Technical Reference — Applied Tweaks

This document lists every system modification performed by `LaptopOptimizer.ps1`, the condition under which it runs, and how `-Revert` restores the original state.

---

## 1. Mandatory First-Run System Restore

Before any tweak is applied on the first run:

1. Checks `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\RPSessionInterval` and `Win32_ShadowStorage` (OS-language independent).
2. If System Restore is disabled, enables it on `%SystemDrive%\` via `Enable-ComputerRestore` and reserves a **10%** shadow storage quota via `vssadmin resize/add shadowstorage /maxsize=10%`.
3. Temporarily sets `SystemRestorePointCreationFrequency = 0` (restored in a `finally` block) so Windows' 24-hour throttle does not silently skip creation.
4. Calls `Checkpoint-Computer -Description 'Opydigital - Laptop Optimizer' -RestorePointType 'MODIFY_SETTINGS'`.
5. Confirms via `Get-ComputerRestorePoint` that a higher `SequenceNumber` was created. If not, the script **aborts with exit code `1`**.
6. Writes `backup_tweaks/restore_point.ok` so future runs do not create duplicate restore points, and the scheduled `-PriorityLoop` task never interacts with System Restore at boot.

---

## 2. Base Tweaks (Always Applied)

| Target | Value | Purpose |
| :--- | :--- | :--- |
| `HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl\Win32PrioritySeparation` | `38` (`0x26` DWORD) | Short, variable quantum with balanced foreground responsiveness. |
| `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\LargeSystemCache` | `0` (DWORD) | Prioritizes application memory over file-server system cache. |
| `HKCU\Control Panel\Desktop\MenuShowDelay` | `100` (SZ) | Reduces classic Win32 menu open delay from 400 ms to 100 ms. |
| `HKCU\Control Panel\Desktop\AutoEndTasks` | `1` (SZ) | Automatically closes unresponsive apps at shutdown/logoff. |
| `HKCU\Control Panel\Desktop\HungAppTimeout` | `4000` (SZ) | Marks unresponsive applications after 4 seconds. |
| `HKCU\Control Panel\Desktop\WaitToKillAppTimeout` | `5000` (SZ) | Waits up to 5 seconds before terminating apps during shutdown. |
| `HKLM\SYSTEM\CurrentControlSet\Control\WaitToKillServiceTimeout` | `3000` (SZ) | Reduces service shutdown wait timeout to 3 seconds. |
| `fsutil behavior set disablelastaccess` | `1` | Disables NTFS last-access timestamp writes to reduce disk metadata I/O. |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsRunInBackground` | `2` (DWORD) | Policy to restrict legacy background UWP apps. |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization\DODownloadMode` | `0` (DWORD) | Disables Windows Update P2P sharing (HTTP only, saves bandwidth and battery). |
| `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SilentInstalledAppsEnabled` | `0` (DWORD) | Prevents silent installation of promoted apps. |
| `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SystemPaneSuggestionsEnabled` | `0` (DWORD) | Disables Start/system pane suggestions. |
| Service `DiagTrack` | `disabled` + stopped | Disables Connected User Experiences and Telemetry service. |
| `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\DisableWpbtExecution` | `1` (DWORD) | Blocks OEM BIOS/UEFI bloatware injection via Windows Platform Binary Table (WPBT). |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata\PreventDeviceMetadataFromNetwork` | `1` (DWORD) | Prevents auto-installing vendor companion apps when connecting peripherals. |
| `HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell\FolderType` | `NotSpecified` (SZ) | Disables File Explorer automatic folder-type discovery for faster browsing. |
| Services `MapsBroker`, `RetailDemo`, `Fax`, `WalletService` | `demand` (manual) | Reduces idle background services without affecting Bluetooth, printing, or Xbox. |
| Temporary Files (`%TEMP%`, `%SystemRoot%\Temp`) | Cleaned on apply | Safely removes unlocked temporary files to reclaim SSD space. |

---

## 3. Conditional Tweaks

### RAM >= 16 GB (`KERN`)
- `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\DisablePagingExecutive = 1` (DWORD)
- Keeps kernel-mode drivers and executive code resident in physical RAM. Restricted to `>= 16 GB` so 8 GB Windows 11 systems retain headroom for user applications.

### RAM <= 4 GB (`FX` & `IDX`)
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\VisualFXSetting = 3` (Custom)
- `HKCU\Control Panel\Desktop\DragFullWindows = 0`
- `HKCU\Control Panel\Desktop\WindowMetrics\MinAnimate = 0`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarAnimations = 0`
- `HKCU\Control Panel\Desktop\FontSmoothing = 2` and `FontSmoothingType = 2` (preserves ClearType so fonts remain crisp)
- Service `WSearch` set to `demand` (manual) + stopped to avoid continuous background indexing on low-RAM systems.

### System Disk is SSD / NVMe (`SSDOpt`)
- Detected via `Get-PhysicalDisk` (`MediaType -eq 'SSD'`, `BusType -eq 'NVMe'`, or `SpindleSpeed -eq 0`).
- Service `SysMain` (Superfetch) set to `disabled` + stopped (kept enabled on HDDs where prefetching improves load times).
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize\StartupDelayInMSec = 0` (removes post-login startup app delay on SSDs).

### Portable / Laptop Chassis (`TurboDC`)
- Detected via `Win32_SystemEnclosure.ChassisTypes` (`8, 9, 10, 11, 12, 14, 30, 31, 32`).
- Activates `SCHEME_BALANCED` and sets `PROCTHROTTLEMAX = 99` on **DC (battery)** only, disabling CPU Turbo Boost on battery to reduce heat, fan noise, and power draw while keeping 100% performance on AC power.
- `HKLM\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9\DCSettingIndex = 0` (disables network connectivity during S0 Modern Standby on battery to prevent bag battery drain/overheating).
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\IsBatteryPercentageEnabled = 1` (enables numeric battery percentage in the Windows 11 system tray).

### Gaming Laptop Suite (`-Gaming` / Menu Option `[2]`)
- `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\HwSchMode = 2` (enables Hardware-Accelerated GPU Scheduling / HAGS).
- `HKCU\Software\Microsoft\GameBar\AutoGameModeEnabled = 1` (ensures Windows Game Mode is enabled).
- `HKCU\System\GameConfigStore\GameDVR_Enabled = 0` and `HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR\AllowGameDVR = 0` (disables background Game DVR recording without removing Game Bar).
- `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile`:
  - `NetworkThrottlingIndex = 0xffffffff` (disables multimedia network packet throttling).
  - `SystemResponsiveness = 10` (reduces background reservation while keeping audio stable).
- `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games`:
  - `GPU Priority = 8`, `Priority = 6`, `Scheduling Category = High`, `SFIO Priority = High`.
- AC (plugged-in) power tuning via `powercfg`:
  - `PROCTHROTTLEMAX = 100` (full Turbo Boost on AC; DC battery limit `99` preserved).
  - `SUB_PCIEXPRESS ASPM = 0` (disables PCIe Link State Power Management on AC to prevent dGPU micro-stutters).
  - `SUB_USB USBSELECTIVESUSPEND = 0` (disables USB Selective Suspend on AC for high-polling gaming mice/headsets).
- **Anti-Cheat Safe by Design**: VBS/HVCI (Memory Integrity), TPM, and `pagefile.sys` are intentionally left untouched so competitive titles (Riot Vanguard, FACEIT, EAC, BattlEye) continue working without issues.

---

## 4. Program Files Installation & Headless Logon Task (`Opydigital_LaptopOptimizer`)

- On first install, `LaptopOptimizer.ps1` copies itself to `%ProgramFiles%\Opydigital\LaptopOptimizer\LaptopOptimizer.ps1`.
- Backups (`backup_tweaks/`), installation metadata (`install_state.json`), logs (`tweaks_log.txt`), and exclusions (`priority_exclusions.txt`) are stored in `%ProgramFiles%\Opydigital\LaptopOptimizer\`.
- A single Scheduled Task named `Opydigital_LaptopOptimizer` is registered (`AtLogOn` for the current user, `LogonType Interactive`, `RunLevel Highest`, `conhost.exe --headless`, `MultipleInstances IgnoreNew`), avoiding any UAC prompt or taskbar window at logon:
  - **Profile `[2]` — Native On-Boot Only (Competitive Gamers)**: runs `-BootApply` once at logon to re-verify/re-apply native registry, service, NTFS, and battery power tweaks (in case Windows Updates or OEM utilities reset them), then exits immediately (`exit 0`). No background PowerShell process remains running.
  - **Profile `[1]` — Standard + Background Priority Loop**: runs `-BootApply -PriorityLoop`. After re-applying native tweaks, it polls `GetForegroundWindow()` every 2 seconds and boosts the active non-excluded process to `AboveNormal`, while **automatically pausing** whenever `SHQueryUserNotificationState` reports a fullscreen Direct3D app (`QUNS_BUSY` / `QUNS_RUNNING_D3D_FULL_SCREEN`) or an active kernel anti-cheat (`vgc`, `EasyAntiCheat`, `EasyAntiCheat_EOS`, `BEService`, `BEDaisy`, `FACEIT`, `EAAntiCheat`, `xhunter1`, `HoYoKProtect`) is detected.
- Switching between Profile `[1]` and `[2]` cleanly replaces the existing task.

---

## 5. Interactive Windows 11 Debloat Wizard (`[3]` / `-Debloat`)

Based on [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil), the interactive wizard prompts `[Y/N]` individually for each item (after ensuring the mandatory first-run System Restore point and registry backups):

1. **Telemetry & Diagnostics**: `AllowTelemetry = 0`, `AdvertisingInfo\Enabled = 0`, `TailoredExperiencesWithDiagnosticDataEnabled = 0`, `OnlineSpeechPrivacy\HasAccepted = 0`, `Input\TIPC\Enabled = 0`, `RestrictImplicitInkCollection/TextCollection = 1`, `Start_TrackProgs = 0`, `NumberOfSIUFInPeriod = 0`, disables `DiagTrack` and `WerSvc`.
2. **Activity History**: `EnableActivityFeed = 0`, `PublishUserActivities = 0`, `UploadUserActivities = 0`.
3. **Location Tracking**: `ConsentStore\location = Deny`, `SensorPermissionState = 0`, `Maps\AutoUpdateEnabled = 0`, disables `lfsvc`.
4. **Windows Consumer Features**: `CloudContent\DisableWindowsConsumerFeatures = 1`.
5. **Windows Copilot & AI Features**: `WindowsCopilot\TurnOffWindowsCopilot = 1`, `WindowsAI\DisableAIDataAnalysis = 1`, `WindowsNotepad\DisableAIFeatures = 1`, `SettingsPageVisibility = hide:aicomponents`.
6. **Start Menu Bing Search & Recommendations**: `BingSearchEnabled = 0`, `DisableSearchBoxSuggestions = 1`, `HideRecommendedSection = 1`.
7. **Windows Widgets**: `Dsh\AllowNewsAndInterests = 0`, `TaskbarDa = 0`.
8. **Microsoft Edge Debloat** *(keeps Edge installed)*: disables Edge telemetry, Shopping Assistant, Rewards, Collections, First-Run Experience, and desktop shortcut creation via official `HKLM\SOFTWARE\Policies\Microsoft\Edge` policies.
9. **Remove Pre-Installed Bloatware (AppX)**: removes Clipchamp, Bing News/Weather/Search, Solitaire, People, GetHelp, Tips, OfficeHub, FeedbackHub, PowerAutomateDesktop, and QuickAssist (preserves Store, Calculator, Photos, Terminal, Xbox & Gaming Services).
10. **Quality-of-Life UI Tweaks**: enables `End Task` on taskbar right-click (`TaskbarEndTask = 1`) and sets File Explorer to open to **This PC** (`LaunchTo = 1`) while unpinning Home & Gallery.

---

## 6. Rollback (`-Revert`) & Full Uninstall (`-Uninstall`)

Running `.\RUNME.bat -Uninstall` (or choosing `[4]` in the menu when already installed):
1. Stops and unregisters `Opydigital_LaptopOptimizer`.
2. Re-imports every `.reg` backup saved in `backup_tweaks/` (including service configurations for `DiagTrack`, `SysMain`, and `WSearch`).
3. Removes added override values (`WaitToKillServiceTimeout`, `StartupDelayInMSec`, `LetAppsRunInBackground`, `DODownloadMode`).
4. Restores NTFS `disablelastaccess` to `2` (System Managed) and battery `PROCTHROTTLEMAX` to `100`.
5. Deletes `%ProgramFiles%\Opydigital\LaptopOptimizer\` cleanly.
