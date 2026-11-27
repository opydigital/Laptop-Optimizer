#Requires -Version 5.1
<#
.SYNOPSIS
    Opydigital - Laptop Optimizer for Windows 11.
.DESCRIPTION
    Hardware-aware PowerShell optimization utility for Windows 11 laptops and desktops.
    Detects RAM, storage type (SSD/NVMe vs HDD), and chassis type to apply safe, reversible
    performance and battery-life tweaks, with mandatory first-run System Restore protection,
    Program Files installation, native on-boot re-application, optional headless foreground
    priority loop (with anti-cheat/D3D auto-pause), and full uninstall/rollback.
.PARAMETER DryRun
    Detects hardware and previews the optimization plan without modifying the system.
.PARAMETER Revert
    Restores backed-up registry keys, services, NTFS, and power settings.
.PARAMETER Uninstall
    Stops and removes the scheduled task, reverts all system changes, and deletes the Program Files installation.
.PARAMETER Silent
    Applies the Native On-Boot profile without interactive prompts (combine with -InstallTask for Standard + Priority Loop).
.PARAMETER InstallTask
    Registers the headless logon task (with priority loop if called standalone or combined with -Silent).
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

$AppVersion      = '1.0.0'
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
    $hasScript = Test-Path $InstalledScript
    $hasTask   = ($null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) -or
                 ($null -ne (Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue))
    $profile   = 'Unknown'
    $version   = $null
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

    & fsutil.exe behavior set disablelastaccess 2 2>&1 | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>&1 | Out-Null
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
    if (-not $Quiet) { Write-Host "  [OK] Base optimizations applied" -ForegroundColor Green }

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
        if (-not $Quiet) { Write-Host "  [OK] CPU Turbo Boost disabled on battery (Laptop)" -ForegroundColor Green }
    }
}

function Invoke-Optimize($Hw, [bool]$EnablePriorityLoop) {
    if (-not (Ensure-RestorePoint)) {
        if ($Elevated -and -not $Silent) { Read-Host "`nPress Enter to exit" }
        exit 1
    }

    Write-Host ""
    Write-Section "INSTALLING & APPLYING OPTIMIZATIONS"
    Install-ToProgramFiles
    Backup-OriginalState
    Apply-NativeTweaks -Hw $Hw

    $profileName = if ($EnablePriorityLoop) { 'Standard+Loop' } else { 'NativeOnBoot' }
    Register-OptimizerTask -IncludePriorityLoop $EnablePriorityLoop
    Save-InstallState -ProfileName $profileName

    Write-Log "APPLY | PROFILE=$profileName | RAM=$($Hw.RAM)GB DISK=$($Hw.Disk) PORT=$($Hw.IsPortable) BUILD=$($Hw.Build) | FX=$($Hw.FX) KERN=$($Hw.KERN) SSD=$($Hw.SSDOpt) IDX=$($Hw.IDX) TURBO=$($Hw.TurboDC)"
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

function Register-OptimizerTask([bool]$IncludePriorityLoop) {
    Install-ToProgramFiles
    Remove-OptimizerTasks

    if ($IncludePriorityLoop) {
        Ensure-ExclusionsFile
        $taskArgs  = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstalledScript`" -BootApply -PriorityLoop"
        $timeLimit = [TimeSpan]::Zero
        $modeDesc  = "headless logon re-apply + foreground priority loop"
    } else {
        $taskArgs  = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstalledScript`" -BootApply"
        $timeLimit = New-TimeSpan -Minutes 5
        $modeDesc  = "headless one-shot logon re-apply (exits immediately, zero background loop)"
    }

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
        Write-Log "BOOT_APPLY | RAM=$($hwBoot.RAM)GB DISK=$($hwBoot.Disk) PORT=$($hwBoot.IsPortable)"
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

if ($Uninstall)     { Invoke-Uninstall;     if ($Elevated -and -not $Silent) { Read-Host "`nPress Enter to exit" }; exit 0 }
if ($Revert)        { Invoke-Revert;        Write-Log "REVERT | Completed."; if ($Elevated -and -not $Silent) { Read-Host "`nPress Enter to exit" }; exit 0 }
if ($UninstallTask) { Remove-OptimizerTasks; if ($Elevated -and -not $Silent) { Read-Host "`nPress Enter to exit" }; exit 0 }
if ($InstallTask -and -not $Silent) {
    Register-OptimizerTask -IncludePriorityLoop $true
    if ($Elevated) { Read-Host "`nPress Enter to exit" }
    exit 0
}

$hw    = Get-HardwareProfile
$state = Get-InstallState

Write-Section "DETECTED HARDWARE"
Write-Host ("  Usable RAM .......: {0} GB" -f $hw.RAM) -ForegroundColor White
Write-Host ("  System Disk ......: {0}" -f $hw.Disk) -ForegroundColor White
Write-Host ("  Laptop/Portable ..: {0}" -f $(if ($hw.IsPortable) { 'Yes' } else { 'No' })) -ForegroundColor White
Write-Host ("  Windows Build ....: {0}" -f $hw.Build) -ForegroundColor White
if ($state.IsInstalled) {
    $verStr = if ($state.Version) { "v$($state.Version)" } else { "installed" }
    Write-Host ("  Install Status ...: Installed ({0} | Profile: {1})" -f $verStr, $state.Profile) -ForegroundColor Green
} else {
    Write-Host "  Install Status ...: Not installed" -ForegroundColor DarkGray
}
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

$enableLoop = [bool]$InstallTask
if (-not $Silent) {
    Write-Section "SELECT ACTION / PROFILE"
    Write-Host "  [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "Standard + Background Priority Loop" -ForegroundColor White
    Write-Host "      Re-applies native optimizations at logon + runs headless foreground" -ForegroundColor Gray
    Write-Host "      priority booster (auto-pauses during D3D fullscreen & anti-cheats)." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [2] " -ForegroundColor Green -NoNewline
    Write-Host "Native On-Boot Only (Recommended for Competitive Gamers)" -ForegroundColor White
    Write-Host "      Re-applies native Windows optimizations once at logon via Task" -ForegroundColor Gray
    Write-Host "      Scheduler (no UAC) and exits immediately — ZERO background loop." -ForegroundColor Gray
    Write-Host "      Recommended for games with kernel anti-cheats (Riot Vanguard," -ForegroundColor Yellow
    Write-Host "      EasyAntiCheat, BattlEye, FACEIT, Ricochet)." -ForegroundColor Yellow
    Write-Host ""
    if ($state.IsInstalled) {
        Write-Host "  [3] " -ForegroundColor Red -NoNewline
        Write-Host "Uninstall & Revert All Changes" -ForegroundColor White
        Write-Host "      Removes the scheduled task, restores original settings, and deletes" -ForegroundColor Gray
        Write-Host "      $InstallDir." -ForegroundColor Gray
        Write-Host ""
    }
    Write-Host "  [0] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Cancel" -ForegroundColor Gray
    Write-Host ""

    $prompt = if ($state.IsInstalled) { "Choose an option [1 / 2 / 3 / 0]" } else { "Choose an option [1 / 2 / 0]" }
    $choice = Read-Host $prompt
    switch ($choice) {
        '1' { $enableLoop = $true }
        '2' { $enableLoop = $false }
        '3' {
            if ($state.IsInstalled) {
                Invoke-Uninstall
                if ($Elevated) { Read-Host "`nPress Enter to exit" }
                exit 0
            }
            Write-Host "  Cancelled. No changes were made." -ForegroundColor Yellow
            if ($Elevated) { Read-Host "`nPress Enter to exit" }
            exit 0
        }
        default {
            Write-Host "  Cancelled. No changes were made." -ForegroundColor Yellow
            if ($Elevated) { Read-Host "`nPress Enter to exit" }
            exit 0
        }
    }
}

Invoke-Optimize $hw $enableLoop
Write-Host "`n  Done! Restart Windows to apply all changes." -ForegroundColor Cyan
Write-Host "  Installed path: $InstalledScript" -ForegroundColor Gray
if ($Elevated -and -not $Silent) { Read-Host "`nPress Enter to exit" }
