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

---

## 4. Headless Logon Priority Loop (`-InstallTask`)

- Registers task `Opydigital_PriorityLoop` triggered `AtLogOn` for the current user (`LogonType Interactive`, `RunLevel Highest`, unlimited execution time, `MultipleInstances IgnoreNew`).
- Launches via `conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path>" -PriorityLoop` so no console window or taskbar button appears.
- Polls `GetForegroundWindow()` every 2 seconds, elevates the active non-excluded process from `Normal` to `AboveNormal`, and restores the previously boosted process back to `Normal`.

---

## 5. Rollback (`-Revert`)

Running `.\LaptopOptimizer.ps1 -Revert`:
1. Re-imports every `.reg` backup saved in `backup_tweaks/` (including service configurations for `DiagTrack`, `SysMain`, and `WSearch`).
2. Removes added override values (`WaitToKillServiceTimeout`, `StartupDelayInMSec`, `LetAppsRunInBackground`, `DODownloadMode`).
3. Restores NTFS `disablelastaccess` to `2` (System Managed).
4. Restores battery `PROCTHROTTLEMAX` to `100`.
5. Removes `backup_tweaks/restore_point.ok` so a future installation creates a fresh restore point.
