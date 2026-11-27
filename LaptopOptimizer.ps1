#Requires -Version 5.1
<#
.SYNOPSIS
    Opydigital - Laptop Optimizer for Windows 11.
.DESCRIPTION
    Hardware-aware PowerShell optimization utility for Windows 11 laptops and desktops.
    Detects RAM, storage type (SSD/NVMe vs HDD), and chassis type to apply safe, reversible
    performance and battery-life tweaks, with mandatory first-run System Restore protection
    and an optional headless logon foreground-priority booster.
.PARAMETER DryRun
    Detects hardware and previews the optimization plan without modifying the system.
.PARAMETER Revert
    Restores backed-up registry keys, services, NTFS, and power settings.
.PARAMETER Silent
    Applies the optimization plan without interactive confirmation prompts.
.PARAMETER InstallTask
    Registers a headless Windows Scheduled Task at user logon for the foreground priority loop.
.PARAMETER UninstallTask
    Removes the scheduled foreground priority loop task.
.PARAMETER PriorityLoop
    Internal switch invoked by the Scheduled Task to run the background priority loop.
.NOTES
    License: GNU General Public License v3.0 (GPL-3.0)
    Repository: https://github.com/opydigital/Laptop-Optimizer
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Revert,
    [switch]$Silent,
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [switch]$PriorityLoop
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir      = $PSScriptRoot
$BackupDir      = Join-Path $ScriptDir 'backup_tweaks'
$RestoreMarker  = Join-Path $BackupDir 'restore_point.ok'
$LogFile        = Join-Path $ScriptDir 'tweaks_log.txt'
$ExclusionsFile = Join-Path $ScriptDir 'priority_exclusions.txt'
$TaskName       = 'Opydigital_PriorityLoop'

# ---------- Visual Helpers ----------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Banner {
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
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$ts] $Msg" -Encoding UTF8
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

    $chassis = (Get-CimInstance Win32_SystemEnclosure).ChassisTypes
    $isPortable = @($chassis | Where-Object { $_ -in 8,9,10,11,12,14,30,31,32 }).Count -ge 1
    $build = [Environment]::OSVersion.Version.Build

    [PSCustomObject]@{
        RAM        = $ramGB
        Disk       = $diskType
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
        # Check if System Restore is disabled (OS-language independent)
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
        'PriorityControl.reg'  = 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl'
        'MemoryManagement.reg' = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        'Desktop.reg'          = 'HKCU\Control Panel\Desktop'
        'ExplorerAdv.reg'      = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        'VisualEffects.reg'    = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
        'ContentDelivery.reg'  = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        'Svc_DiagTrack.reg'    = 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack'
        'Svc_SysMain.reg'      = 'HKLM\SYSTEM\CurrentControlSet\Services\SysMain'
        'Svc_WSearch.reg'      = 'HKLM\SYSTEM\CurrentControlSet\Services\WSearch'
    }

    foreach ($file in $exports.Keys) {
        $dest = Join-Path $BackupDir $file
        if (-not (Test-Path $dest)) {
            & reg.exe export $exports[$file] $dest /y 2>&1 | Out-Null
        }
    }
}

function Invoke-Revert {
    Write-Section "REVERTING CHANGES"
    if (-not (Test-Path $BackupDir)) {
        Write-Host "  [!] Backup directory not found: $BackupDir" -ForegroundColor Yellow
        return
    }

    Get-ChildItem -Path $BackupDir -Filter '*.reg' | ForEach-Object {
        & reg.exe import $_.FullName 2>&1 | Out-Null
        Write-Host "  [OK] Imported $($_.Name)" -ForegroundColor Green
    }

    & reg.exe delete "HKLM\SYSTEM\CurrentControlSet\Control" /v WaitToKillServiceTimeout /f 2>&1 | Out-Null
    & reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" /v LetAppsRunInBackground /f 2>&1 | Out-Null
    & reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DODownloadMode /f 2>&1 | Out-Null

    & fsutil.exe behavior set disablelastaccess 2 2>&1 | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>&1 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null

    if (Test-Path $RestoreMarker) { Remove-Item -Path $RestoreMarker -Force -ErrorAction SilentlyContinue }
    Write-Log "REVERT | Completed successfully."
    Write-Host "`n  Revert completed. Restart Windows to apply all restored settings." -ForegroundColor Cyan
}

# ---------- Applying Optimizations ----------
function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Type) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Invoke-Optimize($Hw) {
    if (-not (Ensure-RestorePoint)) {
        exit 1
    }

    Write-Host ""
    Write-Section "APPLYING OPTIMIZATIONS"
    Backup-OriginalState

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
    Write-Host "  [OK] Base optimizations applied" -ForegroundColor Green

    if ($Hw.KERN) {
        Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 1 'DWord'
        Write-Host "  [OK] Resident kernel in RAM enabled (RAM >= 16 GB)" -ForegroundColor Green
    }

    if ($Hw.FX) {
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3 'DWord'
        Set-RegValue 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' 'String'
        Set-RegValue 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0 'DWord'
        Set-RegValue 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
        Set-RegValue 'HKCU:\Control Panel\Desktop' 'FontSmoothingType' 2 'DWord'
        Write-Host "  [OK] Minimal visual effects with ClearType preserved (RAM <= 4 GB)" -ForegroundColor Green
    }

    if ($Hw.SSDOpt) {
        & sc.exe config SysMain start= disabled 2>&1 | Out-Null
        & sc.exe stop SysMain 2>&1 | Out-Null
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0 'DWord'
        Write-Host "  [OK] SysMain disabled and zero startup delay applied (SSD)" -ForegroundColor Green
    }

    if ($Hw.IDX) {
        & sc.exe config WSearch start= demand 2>&1 | Out-Null
        & sc.exe stop WSearch 2>&1 | Out-Null
        Write-Host "  [OK] Windows Search set to on-demand (RAM <= 4 GB)" -ForegroundColor Green
    }

    if ($Hw.TurboDC) {
        & powercfg.exe /setactive SCHEME_BALANCED 2>&1 | Out-Null
        & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 99 2>&1 | Out-Null
        & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null
        Write-Host "  [OK] CPU Turbo Boost disabled on battery (Laptop)" -ForegroundColor Green
    }

    Write-Log "APPLY | RAM=$($Hw.RAM)GB DISK=$($Hw.Disk) PORT=$($Hw.IsPortable) BUILD=$($Hw.Build) | FX=$($Hw.FX) KERN=$($Hw.KERN) SSD=$($Hw.SSDOpt) IDX=$($Hw.IDX) TURBO=$($Hw.TurboDC)"
}

# ---------- Scheduled Task & Foreground Priority Loop ----------
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

function Install-PriorityTask {
    Ensure-ExclusionsFile
    $scriptPath = $PSCommandPath

    $action    = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -PriorityLoop"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "  [OK] Scheduled task '$TaskName' installed (headless at logon, no taskbar window)." -ForegroundColor Green
    Write-Host "  [OK] Exclusions file: $ExclusionsFile" -ForegroundColor Gray
}

function Uninstall-PriorityTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false 2>&1 | Out-Null
    Write-Host "  [OK] Scheduled task '$TaskName' removed." -ForegroundColor Green
}

function Start-PriorityLoop {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Focus {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
}
"@
    $protected = Get-ExcludedProcesses
    $lastPid = 0

    while ($true) {
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

# ---------- Main Entry Point ----------
if ($PriorityLoop) {
    Start-PriorityLoop
    exit 0
}

Write-Banner

if (-not $DryRun -and -not (Test-IsAdmin)) {
    Write-Host "  [!] Please run PowerShell as Administrator to apply system changes." -ForegroundColor Red
    Write-Host "  Tip: preview safely without admin privileges using: .\LaptopOptimizer.ps1 -DryRun" -ForegroundColor Gray
    exit 1
}

if ($Revert)        { Invoke-Revert; exit 0 }
if ($InstallTask)   { Install-PriorityTask; exit 0 }
if ($UninstallTask) { Uninstall-PriorityTask; exit 0 }

$hw = Get-HardwareProfile

Write-Section "DETECTED HARDWARE"
Write-Host ("  Usable RAM .......: {0} GB" -f $hw.RAM) -ForegroundColor White
Write-Host ("  System Disk ......: {0}" -f $hw.Disk) -ForegroundColor White
Write-Host ("  Laptop/Portable ..: {0}" -f $(if ($hw.IsPortable) { 'Yes' } else { 'No' })) -ForegroundColor White
Write-Host ("  Windows Build ....: {0}" -f $hw.Build) -ForegroundColor White
Write-Host ""

Write-Section "OPTIMIZATION PLAN"
Write-PlanRow "Base (timeouts, NTFS, DO, DiagTrack)"   $true       "[Always]"
Write-PlanRow "Minimal visual effects (+ClearType)"    $hw.FX      "[RAM <= 4 GB]"
Write-PlanRow "Resident kernel in RAM"                 $hw.KERN    "[RAM >= 16 GB]"
Write-PlanRow "SSD optimizations (SysMain / Boot)"     $hw.SSDOpt  "[SSD / NVMe]"
Write-PlanRow "On-demand Search indexing"              $hw.IDX     "[RAM <= 4 GB]"
Write-PlanRow "Disable Turbo Boost on battery"         $hw.TurboDC "[Laptop]"
Write-Host ""

if ($DryRun) {
    Write-Host "  [DRY-RUN] No changes were made to the system." -ForegroundColor Yellow
    exit 0
}

if (-not $Silent) {
    $resp = Read-Host "Apply this optimization plan? [Y/N]"
    if ($resp -notin @('Y','y','Yes','yes')) { exit 0 }
}

Invoke-Optimize $hw
Write-Host "`n  Done! Restart Windows to apply all changes." -ForegroundColor Cyan
Write-Host "  To enable the headless logon priority loop: .\LaptopOptimizer.ps1 -InstallTask" -ForegroundColor Gray
