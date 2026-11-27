#Requires -Version 5.1
<#
.SYNOPSIS
    Opydigital - Laptop Optimizer for Windows 11.
.DESCRIPTION
    Hardware-aware PowerShell optimization utility for Windows 11 Standard and Gaming laptops.
    Detects RAM, storage type (SSD/NVMe vs HDD), dedicated GPU, and chassis type to apply safe,
    reversible performance and battery-life tweaks, with mandatory first-run System Restore
    protection, Program Files installation, native on-boot re-application, optional headless
    foreground priority loop (with anti-cheat/D3D auto-pause), and full uninstall/rollback.
.PARAMETER DryRun
    Detects hardware and previews the optimization plan without modifying the system.
.PARAMETER Gaming
    Enables the Gaming Laptop optimization suite (HAGS, Game Mode, Game DVR off, MMCSS, AC PCIe/USB).
.PARAMETER Revert
    Restores backed-up registry keys, services, NTFS, and power settings.
.PARAMETER Uninstall
    Stops and removes the scheduled task, reverts all system changes, and deletes the Program Files installation.
.PARAMETER Silent
    Applies optimizations without interactive prompts (combine with -Gaming and/or -InstallTask).
.PARAMETER InstallTask
    Registers the headless logon task with the foreground priority loop.
.PARAMETER UninstallTask
    Removes the scheduled task without reverting registry/service optimizations.
.PARAMETER BootApply
    Internal switch invoked by Task Scheduler at logon to silently re-apply native tweaks and exit.
.PARAMETER PriorityLoop
    Internal switch invoked by Task Scheduler to run the background foreground priority loop.
.NOTES
    License: GNU General Public License v3.0 (GPL-3.0)
    Repository: https://github.com/opydigital/Laptop-Optimizer
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Gaming,
    [switch]$Debloat,
    [switch]$Revert,
    [switch]$Uninstall,
    [switch]$Silent,
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [switch]$BootApply,
    [switch]$PriorityLoop,
    [switch]$Elevated
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$AppVersion      = '1.0.3'
$InstallDir      = Join-Path $env:ProgramFiles 'Opydigital\LaptopOptimizer'
$InstalledScript = Join-Path $InstallDir 'LaptopOptimizer.ps1'
$StateFile       = Join-Path $InstallDir 'install_state.json'
$BackupDir       = Join-Path $InstallDir 'backup_tweaks'
$RestoreMarker   = Join-Path $BackupDir 'restore_point.ok'
$LogFile         = Join-Path $InstallDir 'tweaks_log.txt'
$ExclusionsFile  = Join-Path $InstallDir 'priority_exclusions.txt'
$TaskName        = 'Opydigital_LaptopOptimizer'
$LegacyTaskName  = 'Opydigital_PriorityLoop'

# ---------- Helpers ----------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Elevated'
    )
    if ($Gaming)        { $argList += '-Gaming' }
    if ($Debloat)       { $argList += '-Debloat' }
    if ($Revert)        { $argList += '-Revert' }
    if ($Uninstall)     { $argList += '-Uninstall' }
    if ($Silent)        { $argList += '-Silent' }
    if ($InstallTask)   { $argList += '-InstallTask' }
    if ($UninstallTask) { $argList += '-UninstallTask' }

    try {
        Write-Host "  [*] Requesting Administrator privileges (UAC)..." -ForegroundColor Yellow
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -WindowStyle Maximized -ErrorAction Stop
        exit 0
    } catch {
        Write-Host "  [!] Administrator elevation is required and was cancelled." -ForegroundColor Red
        exit 1
    }
}

function Set-WindowMaximized {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Console {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@ -ErrorAction SilentlyContinue
        $hwnd = [Win32Console]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][Win32Console]::ShowWindow($hwnd, 3) # SW_MAXIMIZE
        }
    } catch {}
}

function Write-Banner {
    Set-WindowMaximized
    try { Clear-Host } catch {}
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║               OPYDIGITAL - LAPTOP OPTIMIZER                ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section([string]$Title) {
    Write-Host "── $Title " -ForegroundColor DarkCyan -NoNewline
    Write-Host ("─" * [Math]::Max(0, 56 - $Title.Length)) -ForegroundColor DarkGray
}

function Write-PlanRow([string]$Label, [bool]$Active, [string]$Condition) {
    $badge = if ($Active) { " YES " } else { " NO  " }
    $color = if ($Active) { "Green" } else { "DarkGray" }
    Write-Host ("  {0,-38}" -f $Label) -NoNewline
    Write-Host $badge -BackgroundColor $color -ForegroundColor Black -NoNewline
    Write-Host "  $Condition" -ForegroundColor Gray
}

function Write-Log([string]$Msg) {
    if (-not (Test-Path $InstallDir)) { New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$ts] $Msg" -Encoding UTF8
}

function Get-InstallState {
    $hasScript   = Test-Path $InstalledScript
    $hasTask     = ($null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) -or
                   ($null -ne (Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue))
    $profile     = 'Unknown'
    $version     = $null
    $installedAt = $null

    if (Test-Path $StateFile) {
        try {
            $json = Get-Content -Path $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.Profile)     { $profile     = $json.Profile }
            if ($json.Version)     { $version     = $json.Version }
            if ($json.InstalledAt) { $installedAt = $json.InstalledAt }
        } catch {}
    }

    [PSCustomObject]@{
        IsInstalled = ($hasScript -or $hasTask -or (Test-Path $BackupDir))
        Profile     = $profile
        Version     = $version
        InstalledAt = $installedAt
        HasTask     = $hasTask
    }
}

function Save-InstallState([string]$ProfileName) {
    if (-not (Test-Path $InstallDir)) { New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null }
    $state = [ordered]@{
        Version     = $AppVersion
        Profile     = $ProfileName
        InstalledAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function Install-ToProgramFiles {
    if (-not (Test-Path $InstallDir)) {
        New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    }
    $sameFile = [string]::Equals(
        [System.IO.Path]::GetFullPath($PSCommandPath),
        [System.IO.Path]::GetFullPath($InstalledScript),
        [StringComparison]::OrdinalIgnoreCase
    )
    if (-not $sameFile) {
        Copy-Item -Path $PSCommandPath -Destination $InstalledScript -Force
        Write-Host "  [OK] Script installed to: $InstalledScript" -ForegroundColor Green
    }
}

# ---------- Hardware Detection ----------
function Get-HardwareProfile {
    $ramBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $ramGB = if ($ramBytes) { [math]::Round($ramBytes / 1GB) } else { 8 }

    $sysDrive = $env:SystemDrive.Substring(0, 1)
    $diskNum  = (Get-Partition -DriveLetter $sysDrive | Select-Object -First 1).DiskNumber
    $physDisk = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq [string]$diskNum } | Select-Object -First 1

    $diskType = if ($physDisk.MediaType -eq 'SSD' -or $physDisk.BusType -eq 'NVMe' -or $physDisk.SpindleSpeed -eq 0) {
        'SSD'
    } elseif ($physDisk.MediaType) {
        [string]$physDisk.MediaType
    } else {
        'HDD'
    }

    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $dGpu = ($gpus | Where-Object { $_ -match 'NVIDIA|GeForce|RTX|GTX|Radeon RX|Intel.*Arc' } | Select-Object -First 1)

    $chassis = (Get-CimInstance Win32_SystemEnclosure).ChassisTypes
    $isPortable = @($chassis | Where-Object { $_ -in 8,9,10,11,12,14,30,31,32 }).Count -ge 1
    $build = [Environment]::OSVersion.Version.Build

    [PSCustomObject]@{
        RAM        = $ramGB
        Disk       = $diskType
        DedicatedGPU = if ($dGpu) { $dGpu } else { 'None (Integrated)' }
        HasDGPU    = [bool]$dGpu
        IsPortable = $isPortable
        Build      = $build
        FX         = ($ramGB -le 4)
        IDX        = ($ramGB -le 4)
        KERN       = ($ramGB -ge 16)
        SSDOpt     = ($diskType -eq 'SSD')
        TurboDC    = $isPortable
    }
}

# ---------- Restore Point & Backup ----------
function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Type) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Ensure-RestorePoint {
    Write-Section "SYSTEM RESTORE POINT (FIRST INSTALL)"
    if (Test-Path $RestoreMarker) {
        $info = Get-Content -Path $RestoreMarker -Raw -ErrorAction SilentlyContinue
        Write-Host "  [OK] Initial restore point already created ($($info.Trim())). Skipping." -ForegroundColor Green
        return $true
    }

    $drive = $env:SystemDrive
    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'

    try {
        $rpInterval = (Get-ItemProperty -Path $srKey -Name 'RPSessionInterval' -ErrorAction SilentlyContinue).RPSessionInterval
        $hasShadow  = @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction SilentlyContinue).Count -gt 0
        $isDisabled = ($rpInterval -eq 0) -or ($null -eq $rpInterval) -or (-not $hasShadow)

        if ($isDisabled) {
            Write-Host "  [*] System Restore is disabled. Enabling on $drive\ with 10% quota..." -ForegroundColor Yellow
            Enable-ComputerRestore -Drive "$drive\" -ErrorAction Stop

            & vssadmin.exe resize shadowstorage /for=$drive /on=$drive /maxsize=10% 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & vssadmin.exe add shadowstorage /for=$drive /on=$drive /maxsize=10% 2>&1 | Out-Null
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to reserve 10% shadow storage quota for System Restore."
            }
            Write-Host "  [OK] System Restore enabled (quota: 10%)" -ForegroundColor Green
        }

        $beforeSeq = 0
        $latestBefore = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber -Descending | Select-Object -First 1
        if ($latestBefore) { $beforeSeq = [int]$latestBefore.SequenceNumber }

        # Temporarily bypass Windows 24-hour restore point frequency throttle
        $hadFreq = $false
        $oldFreq = $null
        if (Test-Path $srKey) {
            $prop = Get-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
            if ($null -ne $prop.SystemRestorePointCreationFrequency) {
                $hadFreq = $true
                $oldFreq = $prop.SystemRestorePointCreationFrequency
            }
        }

        try {
            Set-RegValue $srKey 'SystemRestorePointCreationFrequency' 0 'DWord'
            Checkpoint-Computer -Description 'Opydigital - Laptop Optimizer' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        } finally {
            if ($hadFreq) {
                Set-RegValue $srKey 'SystemRestorePointCreationFrequency' $oldFreq 'DWord'
            } else {
                Remove-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
            }
        }

        $latestAfter = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber -Descending | Select-Object -First 1
        $afterSeq = if ($latestAfter) { [int]$latestAfter.SequenceNumber } else { 0 }

        if ($afterSeq -le $beforeSeq) {
            throw "No new restore point was confirmed by Windows."
        }

        if (-not (Test-Path $BackupDir)) { New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null }
        "SequenceNumber=$afterSeq | CreatedAt=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content -Path $RestoreMarker -Encoding UTF8

        Write-Host "  [OK] Restore point #$afterSeq created successfully." -ForegroundColor Green
        Write-Log "RESTORE_POINT | Created #$afterSeq on $drive"
        return $true
    } catch {
        Write-Host "  [ERROR] Could not create restore point: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  [!] Aborting for safety. No optimizations were applied." -ForegroundColor Red
        Write-Log "ABORT | Restore point failure: $($_.Exception.Message)"
        return $false
    }
}

function Backup-OriginalState {
    if (-not (Test-Path $BackupDir)) { New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null }

    $exports = @{
        'PriorityControl.reg'   = 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl'
        'MemoryManagement.reg'  = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        'Desktop.reg'           = 'HKCU\Control Panel\Desktop'
        'ExplorerAdv.reg'       = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        'VisualEffects.reg'     = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
        'ContentDelivery.reg'   = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        'GraphicsDrivers.reg'   = 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        'GameBar.reg'           = 'HKCU\Software\Microsoft\GameBar'
        'GameConfigStore.reg'   = 'HKCU\System\GameConfigStore'
        'MultimediaProfile.reg' = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        'Svc_DiagTrack.reg'     = 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack'
        'Svc_SysMain.reg'       = 'HKLM\SYSTEM\CurrentControlSet\Services\SysMain'
        'Svc_WSearch.reg'       = 'HKLM\SYSTEM\CurrentControlSet\Services\WSearch'
        'Svc_WerSvc.reg'        = 'HKLM\SYSTEM\CurrentControlSet\Services\WerSvc'
        'Svc_lfsvc.reg'         = 'HKLM\SYSTEM\CurrentControlSet\Services\lfsvc'
        'Svc_MapsBroker.reg'    = 'HKLM\SYSTEM\CurrentControlSet\Services\MapsBroker'
        'Svc_RetailDemo.reg'    = 'HKLM\SYSTEM\CurrentControlSet\Services\RetailDemo'
        'Svc_Fax.reg'           = 'HKLM\SYSTEM\CurrentControlSet\Services\Fax'
        'Svc_WalletService.reg' = 'HKLM\SYSTEM\CurrentControlSet\Services\WalletService'
        'Svc_DPS.reg'           = 'HKLM\SYSTEM\CurrentControlSet\Services\DPS'
        'Svc_PcaSvc.reg'        = 'HKLM\SYSTEM\CurrentControlSet\Services\PcaSvc'
        'Svc_TrkWks.reg'        = 'HKLM\SYSTEM\CurrentControlSet\Services\TrkWks'
        'Svc_StiSvc.reg'        = 'HKLM\SYSTEM\CurrentControlSet\Services\StiSvc'
        'Svc_BITS.reg'          = 'HKLM\SYSTEM\CurrentControlSet\Services\BITS'
        'Svc_DusmSvc.reg'       = 'HKLM\SYSTEM\CurrentControlSet\Services\DusmSvc'
    }

    foreach ($file in $exports.Keys) {
        $dest = Join-Path $BackupDir $file
        if (-not (Test-Path $dest)) {
            & reg.exe export $exports[$file] $dest /y 2>&1 | Out-Null
        }
    }
}

function Invoke-Revert {
    Write-Section "REVERTING SYSTEM CHANGES"
    if (Test-Path $BackupDir) {
        Get-ChildItem -Path $BackupDir -Filter '*.reg' | ForEach-Object {
            & reg.exe import $_.FullName 2>&1 | Out-Null
            Write-Host "  [OK] Imported $($_.Name)" -ForegroundColor Green
        }
    } else {
        Write-Host "  [!] Backup directory not found ($BackupDir). Applying default resets." -ForegroundColor Yellow
    }

    & reg.exe delete "HKLM\SYSTEM\CurrentControlSet\Control" /v WaitToKillServiceTimeout /f 2>&1 | Out-Null
    & reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" /v LetAppsRunInBackground /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DODownloadMode /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /f 2>&1 | Out-Null
    & reg.exe delete "HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v DisableAIDataAnalysis /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\WindowsNotepad" /v DisableAIFeatures /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableActivityFeed /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v PublishUserActivities /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v UploadUserActivities /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Edge" /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate" /v CreateDesktopShortcutDefault /f 2>&1 | Out-Null
    & reg.exe delete "HKCU\Software\Policies\Microsoft\Windows\Explorer" /v DisableSearchBoxSuggestions /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v SettingsPageVisibility /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" /v DisableWpbtExecution /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" /v PreventDeviceMetadataFromNetwork /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9" /v DCSettingIndex /f 2>&1 | Out-Null
    & reg.exe delete "HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell" /v FolderType /f 2>&1 | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control" /v SvcHostSplitThresholdInKB /t REG_DWORD /d 3670016 /f 2>&1 | Out-Null
    Set-RegValue 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\Microsoft.Copilot_8wekyb3d8bbwe\CopilotAutoStart' 'State' 2 'DWord'

    # Re-enable Windows telemetry/maintenance scheduled tasks
    $telemetryTasks = @(
        @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' },
        @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
        @{ Path = '\Microsoft\Windows\Autochk\';                Name = 'Proxy' },
        @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
        @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
        @{ Path = '\Microsoft\Windows\DiskDiagnostic\';         Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' },
        @{ Path = '\Microsoft\Windows\Feedback\Siuf\';          Name = 'DmClient' }
    )
    foreach ($t in $telemetryTasks) {
        Enable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue | Out-Null
    }

    & fsutil.exe behavior set disablelastaccess 2 2>&1 | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>&1 | Out-Null
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 1 2>&1 | Out-Null
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_USB USBSELECTIVESUSPEND 1 2>&1 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null

    if (Test-Path $RestoreMarker) { Remove-Item -Path $RestoreMarker -Force -ErrorAction SilentlyContinue }
    Write-Host "  [OK] System settings reverted." -ForegroundColor Green
}

# ---------- Applying Optimizations ----------
function Apply-NativeTweaks($Hw, [switch]$Quiet) {
    # Base optimizations
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38 'DWord'
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'LargeSystemCache' 0 'DWord'
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'AutoEndTasks' '1' 'String'
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'HungAppTimeout' '4000' 'String'
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'WaitToKillAppTimeout' '5000' 'String'
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' '3000' 'String'
    & fsutil.exe behavior set disablelastaccess 1 2>&1 | Out-Null

    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2 'DWord'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 'DWord'
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0 'DWord'
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0 'DWord'

    & sc.exe config DiagTrack start= disabled 2>&1 | Out-Null
    & sc.exe stop DiagTrack 2>&1 | Out-Null

    # WinUtil laptop-safe base tweaks: svchost consolidation, WPBT, Device Metadata, Explorer, Edge/Copilot background
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control" /v SvcHostSplitThresholdInKB /t REG_DWORD /d 0x04000000 /f 2>&1 | Out-Null
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1 'DWord'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1 'DWord'
    Set-RegValue 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType' 'NotSpecified' 'String'

    # Stop Edge background residency & Copilot auto-startup (keeps both apps installed and usable)
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0 'DWord'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0 'DWord'
    $copilotAutoKey = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\Microsoft.Copilot_8wekyb3d8bbwe\CopilotAutoStart'
    Set-RegValue $copilotAutoKey 'State' 1 'DWord'
    Set-RegValue $copilotAutoKey 'UserEnabledStartupOnce' 1 'DWord'

    # Set safe idle services to Manual (reduces active background threads without breaking features)
    foreach ($svc in @('MapsBroker','RetailDemo','Fax','WalletService','DPS','PcaSvc','TrkWks','StiSvc','BITS','DusmSvc')) {
        if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
            & sc.exe config $svc start= demand 2>&1 | Out-Null
            & sc.exe stop $svc 2>&1 | Out-Null
        }
    }

    # Disable noisy telemetry/maintenance scheduled tasks that cause CPU/disk spikes
    $telemetryTasks = @(
        @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' },
        @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
        @{ Path = '\Microsoft\Windows\Autochk\';                Name = 'Proxy' },
        @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
        @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
        @{ Path = '\Microsoft\Windows\DiskDiagnostic\';         Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' },
        @{ Path = '\Microsoft\Windows\Feedback\Siuf\';          Name = 'DmClient' }
    )
    foreach ($t in $telemetryTasks) {
        Disable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue | Out-Null
    }

    if (-not $Quiet) {
        # Safe temporary files cleanup on interactive/manual apply
        Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Base optimizations applied (svchost grouping, idle services, tasks, Edge/Copilot bg, temp cleanup)" -ForegroundColor Green
    }

    if ($Hw.KERN) {
        Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 1 'DWord'
        if (-not $Quiet) { Write-Host "  [OK] Resident kernel in RAM enabled (RAM >= 16 GB)" -ForegroundColor Green }
    }

    if ($Hw.FX) {
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3 'DWord'
        Set-RegValue 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' 'String'
        Set-RegValue 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0 'DWord'
        Set-RegValue 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
        Set-RegValue 'HKCU:\Control Panel\Desktop' 'FontSmoothingType' 2 'DWord'
        if (-not $Quiet) { Write-Host "  [OK] Minimal visual effects with ClearType preserved (RAM <= 4 GB)" -ForegroundColor Green }
    }

    if ($Hw.SSDOpt) {
        & sc.exe config SysMain start= disabled 2>&1 | Out-Null
        & sc.exe stop SysMain 2>&1 | Out-Null
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0 'DWord'
        if (-not $Quiet) { Write-Host "  [OK] SysMain disabled and zero startup delay applied (SSD)" -ForegroundColor Green }
    }

    if ($Hw.IDX) {
        & sc.exe config WSearch start= demand 2>&1 | Out-Null
        & sc.exe stop WSearch 2>&1 | Out-Null
        if (-not $Quiet) { Write-Host "  [OK] Windows Search set to on-demand (RAM <= 4 GB)" -ForegroundColor Green }
    }

    if ($Hw.TurboDC) {
        & powercfg.exe /setactive SCHEME_BALANCED 2>&1 | Out-Null
        & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 99 2>&1 | Out-Null
        & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null
        # Fix S0 Modern Standby battery drain (disable network connectivity on battery sleep)
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9' 'DCSettingIndex' 0 'DWord'
        if (-not $Quiet) { Write-Host "  [OK] Laptop battery tweaks applied (Turbo DC limit, S0 Standby fix)" -ForegroundColor Green }
    }
}

function Apply-GamingTweaks([switch]$Quiet) {
    # GPU Scheduling (HAGS) + Game Mode + Disable Game DVR background recording
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 'DWord'
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 'DWord'
    Set-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 'DWord'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 'DWord'

    # MMCSS multimedia/gaming scheduler & network throttling
    & reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 0xffffffff /f 2>&1 | Out-Null
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10 'DWord'

    $gamesKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    Set-RegValue $gamesKey 'GPU Priority' 8 'DWord'
    Set-RegValue $gamesKey 'Priority' 6 'DWord'
    Set-RegValue $gamesKey 'Scheduling Category' 'High' 'String'
    Set-RegValue $gamesKey 'SFIO Priority' 'High' 'String'

    # Set Windows Search to on-demand in Gaming mode to prevent indexing spikes during gameplay
    & sc.exe config WSearch start= demand 2>&1 | Out-Null
    & sc.exe stop WSearch 2>&1 | Out-Null

    # AC (plugged-in) power tuning: full Turbo Boost, PCIe ASPM off, USB Selective Suspend off
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>&1 | Out-Null
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 2>&1 | Out-Null
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_USB USBSELECTIVESUSPEND 0 2>&1 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null

    if (-not $Quiet) {
        Write-Host "  [OK] Gaming Laptop optimizations applied (HAGS, Game Mode, Game DVR off, MMCSS, AC PCIe/USB)" -ForegroundColor Green
    }
}

function Invoke-Optimize($Hw, [bool]$EnableGaming, [bool]$EnablePriorityLoop) {
    if (-not (Ensure-RestorePoint)) {
        return $false
    }

    Write-Host ""
    Write-Section "INSTALLING & APPLYING OPTIMIZATIONS"
    Install-ToProgramFiles
    Backup-OriginalState
    Apply-NativeTweaks -Hw $Hw
    if ($EnableGaming) {
        Apply-GamingTweaks
    }

    $tierName    = if ($EnableGaming) { 'Gaming' } else { 'Standard' }
    $bootName    = if ($EnablePriorityLoop) { 'On-Boot + Loop' } else { 'Native On-Boot' }
    $profileName = "$tierName | $bootName"

    Register-OptimizerTask -IncludeGaming $EnableGaming -IncludePriorityLoop $EnablePriorityLoop
    Save-InstallState -ProfileName $profileName

    Write-Log "APPLY | PROFILE=$profileName | RAM=$($Hw.RAM)GB DISK=$($Hw.Disk) DGPU=$($Hw.DedicatedGPU) PORT=$($Hw.IsPortable) BUILD=$($Hw.Build)"
    return $true
}

# ---------- Interactive Windows 11 Debloat (WinUtil-based) ----------
function Read-YesNo([string]$Question) {
    $ans = Read-Host "  $Question [Y/N]"
    return ($ans -in @('Y','y','Yes','yes'))
}

function Prompt-PostAction {
    Write-Host ""
    Write-Host "  [R]     " -ForegroundColor Yellow -NoNewline
    Write-Host "Restart Windows now (recommended to apply all changes)" -ForegroundColor White
    Write-Host "  [Enter] " -ForegroundColor Cyan -NoNewline
    Write-Host "Return to Main Menu" -ForegroundColor White
    Write-Host ""
    $ans = Read-Host "Type R to restart now, or press Enter for Main Menu"
    if ($ans -in @('R','r','Restart','restart')) {
        Write-Host "  [*] Restarting Windows in 5 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        Restart-Computer -Force
        exit 0
    }
}

function Invoke-DebloatWizard([switch]$Auto) {
    $autoMode = [bool]$Auto

    if (-not $autoMode -and -not $Silent) {
        Write-Section "WINDOWS 11 DEBLOAT (WINUTIL-BASED)"
        Write-Host "  [1] " -ForegroundColor Cyan -NoNewline
        Write-Host "Automatic Debloat (Applies all 10 safe tweaks)" -ForegroundColor White
        Write-Host "      Applies Telemetry, Activity History, Location, Consumer Features," -ForegroundColor Gray
        Write-Host "      Copilot/AI policies, Bing Search, Widgets, Edge Debloat, AppX" -ForegroundColor Gray
        Write-Host "      bloatware removal, and Quality-of-Life UI tweaks in one step." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [2] " -ForegroundColor Yellow -NoNewline
        Write-Host "Custom Debloat (Step-by-Step [Y/N])" -ForegroundColor White
        Write-Host "      Prompts individually for each of the 10 categories so you choose" -ForegroundColor Gray
        Write-Host "      exactly what to disable or keep." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [0] " -ForegroundColor DarkGray -NoNewline
        Write-Host "Back to Main Menu" -ForegroundColor Gray
        Write-Host ""

        $dChoice = Read-Host "Choose debloat mode [1 / 2 / 0]"
        switch ($dChoice) {
            '1' { $autoMode = $true }
            '2' { $autoMode = $false }
            default { return $false }
        }
        Write-Host ""
    } elseif ($Silent) {
        $autoMode = $true
    }

    if (-not (Ensure-RestorePoint)) {
        return $false
    }
    Backup-OriginalState
    Write-Host ""
    Write-Section $(if ($autoMode) { "AUTOMATIC DEBLOAT" } else { "CUSTOM DEBLOAT SELECTION" })

    $applied = @()

    # 1. Telemetry & Diagnostics
    Write-Host "`n  [1/10] Telemetry & Diagnostics" -ForegroundColor Cyan
    Write-Host "         Disables Windows telemetry, Advertising ID, Tailored Experiences, DiagTrack & WerSvc." -ForegroundColor Gray
    if ($autoMode -or (Read-YesNo "Disable Telemetry & Diagnostics?")) {
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\Input\TIPC' 'Enabled' 0 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0 'DWord'
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0 'DWord'
        & sc.exe config DiagTrack start= disabled 2>&1 | Out-Null
        & sc.exe stop DiagTrack 2>&1 | Out-Null
        & sc.exe config WerSvc start= disabled 2>&1 | Out-Null
        & sc.exe stop WerSvc 2>&1 | Out-Null
        Write-Host "         [OK] Telemetry disabled." -ForegroundColor Green
        $applied += 'Telemetry'
    }

    # 2. Activity History
    Write-Host "`n  [2/10] Activity History" -ForegroundColor Cyan
    Write-Host "         Stops Windows from collecting and syncing your Activity Feed." -ForegroundColor Gray
    if ($autoMode -or (Read-YesNo "Disable Activity History?")) {
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0 'DWord'
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0 'DWord'
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0 'DWord'
        Write-Host "         [OK] Activity History disabled." -ForegroundColor Green
        $applied += 'ActivityHistory'
    }

    # 3. Location Tracking
    Write-Host "`n  [3/10] Location Tracking" -ForegroundColor Cyan
    Write-Host "         Disables Windows Location service (lfsvc), sensor tracking, and auto map updates." -ForegroundColor Gray
    if ($autoMode -or (Read-YesNo "Disable Location Tracking?")) {
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' 'SensorPermissionState' 0 'DWord'
        Set-RegValue 'HKLM:\SYSTEM\Maps' 'AutoUpdateEnabled' 0 'DWord'
        & sc.exe config lfsvc start= disabled 2>&1 | Out-Null
        & sc.exe stop lfsvc 2>&1 | Out-Null
        Write-Host "         [OK] Location Tracking disabled." -ForegroundColor Green
        $applied += 'Location'
    }

    # 4. Windows Consumer Features
    Write-Host "`n  [4/10] Windows Consumer Features" -ForegroundColor Cyan
    Write-Host "         Prevents Windows from auto-installing promoted Store apps and consumer suggestions." -ForegroundColor Gray
    if ($autoMode -or (Read-YesNo "Disable Consumer Features?")) {
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 'DWord'
        Write-Host "         [OK] Consumer Features disabled." -ForegroundColor Green
        $applied += 'ConsumerFeatures'
    }

    # 5. Windows Copilot & AI Features (Recall / Notepad AI)
    Write-Host "`n  [5/10] Windows Copilot & AI Features" -ForegroundColor Cyan
    Write-Host "         Disables Windows Copilot, Recall AI analysis, Notepad AI, and hides AI Components in Settings." -ForegroundColor Gray
    if ($autoMode -or (Read-YesNo "Disable Copilot & Windows AI?")) {
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 'DWord'
        Set-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 'DWord'
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 'DWord'
        Set-RegValue 'HKLM:\SOFTWARE\Policies\WindowsNotepad' 'DisableAIFeatures' 1 'DWord'
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'hide:aicomponents' 'String'
        Write-Host "         [OK] Copilot & Windows AI disabled." -ForegroundColor Green
        $applied += 'WindowsAI'
    }

    # 6. Start Menu Bing Search & Recommendations
    Write-Host "`n  [6/10] Start Menu Bing Web Search & Recommendations" -ForegroundColor Cyan
    Write-Host "         Disables Bing web results in Windows Search and hides Start Menu recommendations." -ForegroundColor Gray
    if ($autoMode -or (Read-YesNo "Disable Bing Search & Start Recommendations?")) {
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 'DWord'
        Set-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 'DWord'
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'HideRecommendedSection' 1 'DWord'
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecommendedSection' 1 'DWord'
        Write-Host "         [OK] Bing Search & Start Recommendations disabled." -ForegroundColor Green
        $applied += 'BingAndStart'
    }

    # 7. Windows Widgets
    Write-Host "`n  [7/10] Windows Widgets (News & Interests)" -ForegroundColor Cyan
    Write-Host "         Disables the Widgets panel and removes it from the taskbar." -ForegroundColor Gray
    if ($autoMode -or (Read-YesNo "Disable Windows Widgets?")) {
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0 'DWord'
        Write-Host "         [OK] Windows Widgets disabled." -ForegroundColor Green
        $applied += 'Widgets'
    }

    # 8. Microsoft Edge Debloat (keeps Edge installed)
    Write-Host "`n  [8/10] Microsoft Edge Debloat (keeps Edge installed)" -ForegroundColor Cyan
    Write-Host "         Disables Edge telemetry, Shopping Assistant, Rewards, Collections, and recommendations." -ForegroundColor Gray
    if ($autoMode -or (Read-YesNo "Apply Microsoft Edge Debloat policies?")) {
        $edgeKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'CreateDesktopShortcutDefault' 0 'DWord'
        Set-RegValue $edgeKey 'PersonalizationReportingEnabled' 0 'DWord'
        Set-RegValue $edgeKey 'ShowRecommendationsEnabled' 0 'DWord'
        Set-RegValue $edgeKey 'HideFirstRunExperience' 1 'DWord'
        Set-RegValue $edgeKey 'UserFeedbackAllowed' 0 'DWord'
        Set-RegValue $edgeKey 'ConfigureDoNotTrack' 1 'DWord'
        Set-RegValue $edgeKey 'AlternateErrorPagesEnabled' 0 'DWord'
        Set-RegValue $edgeKey 'EdgeCollectionsEnabled' 0 'DWord'
        Set-RegValue $edgeKey 'EdgeShoppingAssistantEnabled' 0 'DWord'
        Set-RegValue $edgeKey 'MicrosoftEdgeInsiderPromotionEnabled' 0 'DWord'
        Set-RegValue $edgeKey 'ShowMicrosoftRewards' 0 'DWord'
        Set-RegValue $edgeKey 'WebWidgetAllowed' 0 'DWord'
        Set-RegValue $edgeKey 'DiagnosticData' 0 'DWord'
        Set-RegValue $edgeKey 'EdgeAssetDeliveryServiceEnabled' 0 'DWord'
        Set-RegValue $edgeKey 'WalletDonationEnabled' 0 'DWord'
        Set-RegValue $edgeKey 'DefaultBrowserSettingsCampaignEnabled' 0 'DWord'
        Write-Host "         [OK] Microsoft Edge debloated." -ForegroundColor Green
        $applied += 'EdgeDebloat'
    }

    # 9. Remove Common Pre-Installed Bloatware Apps (AppX)
    Write-Host "`n  [9/10] Remove Common Pre-Installed Bloatware (AppX)" -ForegroundColor Cyan
    Write-Host "         Removes Clipchamp, Bing News/Weather, Solitaire, People, GetHelp, Tips, FeedbackHub, QuickAssist." -ForegroundColor Gray
    Write-Host "         (Keeps Microsoft Store, Calculator, Photos, Terminal, Xbox & Gaming Services intact.)" -ForegroundColor DarkGray
    if ($autoMode -or (Read-YesNo "Remove pre-installed bloatware apps?")) {
        $bloatApps = @(
            'Clipchamp.Clipchamp',
            'Microsoft.BingNews',
            'Microsoft.BingWeather',
            'Microsoft.BingSearch',
            'Microsoft.MicrosoftSolitaireCollection',
            'Microsoft.People',
            'Microsoft.GetHelp',
            'Microsoft.Getstarted',
            'Microsoft.MicrosoftOfficeHub',
            'Microsoft.WindowsFeedbackHub',
            'Microsoft.PowerAutomateDesktop',
            'MicrosoftCorporationII.QuickAssist'
        )
        $removedCount = 0
        foreach ($app in $bloatApps) {
            $pkgs = Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue
            if ($pkgs) {
                $pkgs | Remove-AppxPackage -ErrorAction SilentlyContinue
                $removedCount++
            }
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $app } |
                Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Host "         [OK] Removed $removedCount bloatware package(s)." -ForegroundColor Green
        $applied += "AppX($removedCount)"
    }

    # 10. Quality-of-Life UI Tweaks (End Task on Taskbar + Clean Explorer)
    Write-Host "`n  [10/10] Quality-of-Life UI Tweaks (WinUtil)" -ForegroundColor Cyan
    Write-Host "          Enables 'End Task' on taskbar right-click and opens File Explorer to This PC (hides Home/Gallery)." -ForegroundColor Gray
    if ($autoMode -or (Read-YesNo "Apply Quality-of-Life UI tweaks?")) {
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1 'DWord'
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1 'DWord'
        Set-RegValue 'HKCU:\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}' 'System.IsPinnedToNameSpaceTree' 0 'DWord'
        Set-RegValue 'HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}' 'System.IsPinnedToNameSpaceTree' 0 'DWord'
        Write-Host "         [OK] Quality-of-Life UI tweaks applied." -ForegroundColor Green
        $applied += 'QoLUI'
    }

    Write-Host ""
    if ($applied.Count -gt 0) {
        $summary = $applied -join ', '
        $modeTag = if ($autoMode) { 'AUTO' } else { 'CUSTOM' }
        Write-Log "DEBLOAT ($modeTag) | Applied: $summary"
        Write-Host "  [OK] Debloat completed ($($applied.Count) item(s) applied: $summary)." -ForegroundColor Green
        Write-Host "  Restart Windows (or Explorer) to see all UI changes take effect." -ForegroundColor Cyan
        return $true
    } else {
        Write-Host "  [--] No debloat items were selected." -ForegroundColor Yellow
        return $false
    }
}

# ---------- Scheduled Task, Uninstall & Priority Loop ----------
function Ensure-ExclusionsFile {
    if (-not (Test-Path $ExclusionsFile)) {
        @(
            '# One process name per line (without .exe) to exclude from the foreground priority loop'
            '# Examples of games or anti-cheat protected apps:'
            '# VALORANT-Win64-Shipping'
            '# FortniteClient-Win64-Shipping'
        ) | Set-Content -Path $ExclusionsFile -Encoding UTF8
    }
}

function Get-ExcludedProcesses {
    $defaults = @(
        # Windows system processes
        'Idle','System','csrss','dwm','explorer','lsass','services','wininit',
        'svchost','smss','audiodg','MsMpEng','Taskmgr','SearchHost',
        'StartMenuExperienceHost','ShellExperienceHost',
        # Common anti-cheat processes
        'vgc','vgtray','EasyAntiCheat','EasyAntiCheat_EOS','BEService','BEDaisy','FACEIT','xhunter1'
    )
    $custom = @()
    if (Test-Path $ExclusionsFile) {
        $custom = Get-Content $ExclusionsFile -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    }
    return ($defaults + $custom) | Select-Object -Unique
}

function Remove-OptimizerTasks {
    foreach ($name in @($TaskName, $LegacyTaskName)) {
        $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  [OK] Scheduled task '$name' removed." -ForegroundColor Green
        }
    }
}

function Register-OptimizerTask([bool]$IncludeGaming, [bool]$IncludePriorityLoop) {
    Install-ToProgramFiles
    Remove-OptimizerTasks

    $flags = '-BootApply'
    if ($IncludeGaming)       { $flags += ' -Gaming' }
    if ($IncludePriorityLoop) { $flags += ' -PriorityLoop' }

    if ($IncludePriorityLoop) {
        Ensure-ExclusionsFile
        $timeLimit = [TimeSpan]::Zero
        $modeDesc  = "headless logon re-apply + foreground priority loop"
    } else {
        $timeLimit = New-TimeSpan -Minutes 5
        $modeDesc  = "headless one-shot logon re-apply (exits immediately, zero background loop)"
    }

    $taskArgs  = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstalledScript`" $flags"
    $action    = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit $timeLimit -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "  [OK] Scheduled task '$TaskName' registered ($modeDesc)." -ForegroundColor Green
    if ($IncludePriorityLoop) {
        Write-Host "  [OK] Exclusions file: $ExclusionsFile" -ForegroundColor Gray
    }
}

function Invoke-Uninstall {
    Write-Section "UNINSTALLING OPYDIGITAL LAPTOP OPTIMIZER"
    Remove-OptimizerTasks
    Invoke-Revert

    if (Test-Path $InstallDir) {
        $runningFromInstallDir = [System.IO.Path]::GetFullPath($PSCommandPath).StartsWith(
            [System.IO.Path]::GetFullPath($InstallDir),
            [StringComparison]::OrdinalIgnoreCase
        )
        if ($runningFromInstallDir) {
            Start-Process -FilePath 'cmd.exe' -ArgumentList "/c timeout /t 2 /nobreak >nul & rd /s /q `"$InstallDir`"" -WindowStyle Hidden
            Write-Host "  [OK] Scheduled removal of $InstallDir on exit." -ForegroundColor Green
        } else {
            Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] Removed installation directory: $InstallDir" -ForegroundColor Green
        }
    }

    Write-Host "`n  Uninstall completed. Restart Windows to finish restoring all settings." -ForegroundColor Cyan
}

function Start-PriorityLoop {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Focus {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int pquns);
}
"@
    $protected = Get-ExcludedProcesses
    $antiCheatWatch = @(
        'vgc','EasyAntiCheat','EasyAntiCheat_EOS','BEService','BEDaisy',
        'FACEIT','FACEITService','EAAntiCheat.GameService','EAAntiCheat.GameServiceLauncher',
        'xhunter1','HoYoKProtect'
    )
    $lastPid = 0

    while ($true) {
        # Auto-pause when a D3D fullscreen app/game or active kernel anti-cheat is detected
        $notifState = 0
        $isFullscreen = ([Win32Focus]::SHQueryUserNotificationState([ref]$notifState) -eq 0) -and ($notifState -in 2, 3)
        $hasAntiCheat = $null -ne (Get-Process -Name $antiCheatWatch -ErrorAction SilentlyContinue)

        if ($isFullscreen -or $hasAntiCheat) {
            if ($lastPid -gt 4) {
                try {
                    $prevProc = Get-Process -Id $lastPid -ErrorAction SilentlyContinue
                    if ($prevProc -and $prevProc.PriorityClass -eq 'AboveNormal') {
                        $prevProc.PriorityClass = 'Normal'
                    }
                } catch {}
                $lastPid = 0
            }
            Start-Sleep -Seconds 5
            continue
        }

        $hwnd = [Win32Focus]::GetForegroundWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            [uint32]$fgPid = 0
            [void][Win32Focus]::GetWindowThreadProcessId($hwnd, [ref]$fgPid)

            if ($fgPid -gt 4 -and $fgPid -ne $lastPid) {
                if ($lastPid -gt 4) {
                    try {
                        $prevProc = Get-Process -Id $lastPid -ErrorAction SilentlyContinue
                        if ($prevProc -and $prevProc.PriorityClass -eq 'AboveNormal') {
                            $prevProc.PriorityClass = 'Normal'
                        }
                    } catch {}
                }

                try {
                    $currProc = Get-Process -Id $fgPid -ErrorAction SilentlyContinue
                    if ($currProc -and ($protected -notcontains $currProc.ProcessName) -and $currProc.PriorityClass -eq 'Normal') {
                        $currProc.PriorityClass = 'AboveNormal'
                        $lastPid = $fgPid
                    } else {
                        $lastPid = 0
                    }
                } catch {
                    $lastPid = 0
                }
            }
        }
        Start-Sleep -Seconds 2
    }
}

# ---------- Headless Boot / Logon Entry Point ----------
if ($BootApply -or $PriorityLoop) {
    if ($BootApply) {
        $hwBoot = Get-HardwareProfile
        Apply-NativeTweaks -Hw $hwBoot -Quiet
        if ($Gaming) {
            Apply-GamingTweaks -Quiet
        }
        Write-Log "BOOT_APPLY | GAMING=$Gaming | RAM=$($hwBoot.RAM)GB DISK=$($hwBoot.Disk) PORT=$($hwBoot.IsPortable)"
    }
    if ($PriorityLoop) {
        Start-PriorityLoop
    }
    exit 0
}

# ---------- Interactive / CLI Entry Point ----------
Write-Banner

if (-not $DryRun -and -not (Test-IsAdmin)) {
    Request-Elevation
}

if ($Debloat)       { Invoke-DebloatWizard; if ($Elevated -and -not $Silent) { Read-Host "`nPress Enter to exit" }; exit 0 }
if ($Uninstall)     { Invoke-Uninstall;     if ($Elevated -and -not $Silent) { Read-Host "`nPress Enter to exit" }; exit 0 }
if ($Revert)        { Invoke-Revert;        Write-Log "REVERT | Completed."; if ($Elevated -and -not $Silent) { Read-Host "`nPress Enter to exit" }; exit 0 }
if ($UninstallTask) { Remove-OptimizerTasks; if ($Elevated -and -not $Silent) { Read-Host "`nPress Enter to exit" }; exit 0 }
if ($InstallTask -and -not $Silent) {
    Register-OptimizerTask -IncludeGaming ([bool]$Gaming) -IncludePriorityLoop $true
    if ($Elevated) { Read-Host "`nPress Enter to exit" }
    exit 0
}

function Show-HardwareSummary($Hw, $State) {
    Write-Section "DETECTED HARDWARE"
    Write-Host ("  Usable RAM .......: {0} GB" -f $Hw.RAM) -ForegroundColor White
    Write-Host ("  System Disk ......: {0}" -f $Hw.Disk) -ForegroundColor White
    Write-Host ("  Dedicated GPU ....: {0}" -f $Hw.DedicatedGPU) -ForegroundColor White
    Write-Host ("  Laptop/Portable ..: {0}" -f $(if ($Hw.IsPortable) { 'Yes' } else { 'No' })) -ForegroundColor White
    Write-Host ("  Windows Build ....: {0}" -f $Hw.Build) -ForegroundColor White
    if ($State.IsInstalled) {
        $verStr = if ($State.Version) { "v$($State.Version)" } else { "installed" }
        Write-Host ("  Install Status ...: Installed ({0} | Profile: {1})" -f $verStr, $State.Profile) -ForegroundColor Green
    } else {
        Write-Host "  Install Status ...: Not installed" -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Section "HARDWARE-ADAPTIVE PLAN"
    Write-PlanRow "Base (timeouts, NTFS, DO, DiagTrack)"   $true           "[Always]"
    Write-PlanRow "Minimal visual effects (+ClearType)"    $Hw.FX          "[RAM <= 4 GB]"
    Write-PlanRow "Resident kernel in RAM"                 $Hw.KERN        "[RAM >= 16 GB]"
    Write-PlanRow "SSD optimizations (SysMain / Boot)"     $Hw.SSDOpt      "[SSD / NVMe]"
    Write-PlanRow "On-demand Search indexing"              $Hw.IDX         "[RAM <= 4 GB]"
    Write-PlanRow "Laptop battery (Turbo DC, S0 fix)"     $Hw.TurboDC     "[Laptop]"
    Write-PlanRow "Gaming Suite (HAGS, DVR, MMCSS, AC)"    ([bool]$Gaming) "[Menu Option 2 / -Gaming]"
    Write-Host ""
}

$hw = Get-HardwareProfile

if ($DryRun) {
    $state = Get-InstallState
    Show-HardwareSummary -Hw $hw -State $state
    Write-Host "  [DRY-RUN] No changes were made to the system." -ForegroundColor Yellow
    exit 0
}

if ($Silent) {
    $ok = Invoke-Optimize -Hw $hw -EnableGaming ([bool]$Gaming) -EnablePriorityLoop ([bool]$InstallTask)
    if (-not $ok) { exit 1 }
    exit 0
}

# Interactive Main Menu Loop
while ($true) {
    Write-Banner
    $state = Get-InstallState
    Show-HardwareSummary -Hw $hw -State $state

    Write-Section "MAIN MENU"
    Write-Host "  [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "Standard Laptop" -ForegroundColor White
    Write-Host "      Everyday responsiveness, SSD/RAM tuning, and battery-life tweaks." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [2] " -ForegroundColor Magenta -NoNewline
    Write-Host "Gaming Laptop" -ForegroundColor White
    Write-Host "      Includes Standard + HAGS, Game Mode, Game DVR off, MMCSS gaming" -ForegroundColor Gray
    Write-Host "      priorities, NetworkThrottling off, and AC PCIe/USB tuning" -ForegroundColor Gray
    Write-Host "      (keeps battery savings on DC; preserves VBS/HVCI for anti-cheats)." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [3] " -ForegroundColor Yellow -NoNewline
    Write-Host "Windows 11 Debloat (Interactive Wizard — WinUtil-based)" -ForegroundColor White
    Write-Host "      Step-by-step [Y/N] wizard for Telemetry, Activity History, Location," -ForegroundColor Gray
    Write-Host "      Consumer Features, Copilot/AI, Bing Search, Widgets, Edge & Bloatware." -ForegroundColor Gray
    Write-Host ""
    if ($state.IsInstalled) {
        Write-Host "  [4] " -ForegroundColor Red -NoNewline
        Write-Host "Uninstall & Revert All Changes" -ForegroundColor White
        Write-Host "      Removes the scheduled task, restores original settings, and deletes" -ForegroundColor Gray
        Write-Host "      $InstallDir." -ForegroundColor Gray
        Write-Host ""
    }
    Write-Host "  [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Exit" -ForegroundColor Gray
    Write-Host ""

    $menuPrompt = if ($state.IsInstalled) { "Choose an option [1 / 2 / 3 / 4 / 0]" } else { "Choose an option [1 / 2 / 3 / 0]" }
    $suiteChoice = Read-Host $menuPrompt

    if ($suiteChoice -eq '0') {
        break
    }

    if ($suiteChoice -eq '3') {
        Write-Host ""
        $debloatApplied = Invoke-DebloatWizard
        if ($debloatApplied) {
            Prompt-PostAction
        }
        continue
    }

    if ($suiteChoice -eq '4' -and $state.IsInstalled) {
        Write-Host ""
        $runningFromInstallDir = [System.IO.Path]::GetFullPath($PSCommandPath).StartsWith(
            [System.IO.Path]::GetFullPath($InstallDir),
            [StringComparison]::OrdinalIgnoreCase
        )
        Invoke-Uninstall
        if ($runningFromInstallDir) {
            break
        }
        Prompt-PostAction
        continue
    }

    if ($suiteChoice -notin @('1','2')) {
        Write-Host "  [!] Invalid option." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        continue
    }

    $enableGaming  = ($suiteChoice -eq '2')
    $selectedLabel = if ($enableGaming) { 'GAMING LAPTOP' } else { 'STANDARD LAPTOP' }

    # Step 2: Submenu — Select Background / Boot Mode (no Exit here, only Back to Main Menu)
    Write-Host ""
    Write-Section "LOGON MODE ($selectedLabel)"
    Write-Host "  [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "On-Boot Re-Apply + Background Priority Loop" -ForegroundColor White
    Write-Host "      Re-applies optimizations at logon + runs headless foreground priority" -ForegroundColor Gray
    Write-Host "      booster (auto-pauses during D3D fullscreen games & active anti-cheats)." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [2] " -ForegroundColor Green -NoNewline
    Write-Host "Native On-Boot Only (Recommended for Competitive Gamers)" -ForegroundColor White
    Write-Host "      Re-applies optimizations once at logon via Task Scheduler (no UAC)" -ForegroundColor Gray
    Write-Host "      and exits immediately (~1-2s) — ZERO background loop." -ForegroundColor Gray
    Write-Host "      Recommended for games with kernel anti-cheats (Riot Vanguard," -ForegroundColor Yellow
    Write-Host "      EasyAntiCheat, BattlEye, FACEIT, Ricochet)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Back to Main Menu" -ForegroundColor Gray
    Write-Host ""

    $modeChoice = Read-Host "Choose logon mode [1 / 2 / 0]"
    if ($modeChoice -notin @('1','2')) {
        continue
    }

    $enableLoop = ($modeChoice -eq '1')
    Write-Host ""
    $ok = Invoke-Optimize -Hw $hw -EnableGaming $enableGaming -EnablePriorityLoop $enableLoop
    if ($ok) {
        Write-Host "`n  Done! Restart Windows to apply all changes." -ForegroundColor Cyan
        Write-Host "  Installed path: $InstalledScript" -ForegroundColor Gray
        Prompt-PostAction
    } else {
        Read-Host "`nPress Enter to return to Main Menu" | Out-Null
    }
}
