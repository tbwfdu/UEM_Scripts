#Requires -Version 5.1
<#
.SYNOPSIS
    Removes OpenClaw (formerly Clawdbot / Moltbot) and associated malicious
    artifacts from a Windows endpoint.

.NOTES
    MUST run as Administrator.
    Use -Force to skip confirmation (suitable for WS1 deployment).
    Log is written to $env:TEMP\Remove-OpenClaw-<timestamp>.log

    Last updated: 2026-03-31
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator. Exiting."
    exit 1
}

$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath    = "$env:TEMP\Remove-OpenClaw-$timestamp.log"
Start-Transcript -Path $logPath -Append | Out-Null

$removedItems = [System.Collections.Generic.List[string]]::new()
$warnings     = [System.Collections.Generic.List[string]]::new()

function Write-Section {
    param([string]$Title)
    Write-Host "`n══ $Title ══" -ForegroundColor Cyan
}

function Remove-ItemSafely {
    param([string]$Path, [string]$Description)
    if (Test-Path $Path) {
        if ($PSCmdlet.ShouldProcess($Path, "Remove $Description")) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $Path)) {
                Write-Host "  [REMOVED] $Path" -ForegroundColor Green
                $removedItems.Add($Path)
            } else {
                Write-Host "  [FAILED]  Could not remove: $Path" -ForegroundColor Red
                $warnings.Add("Failed to remove: $Path")
            }
        }
    }
}

function Stop-ProcessSafely {
    param([string]$Pattern, [string]$Description)
    $procs = Get-Process | Where-Object { $_.ProcessName -match $Pattern -or
                                          ($_.Path -and $_.Path -match $Pattern) }
    foreach ($p in $procs) {
        if ($PSCmdlet.ShouldProcess("PID $($p.Id) ($($p.ProcessName))", "Stop process")) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Write-Host "  [STOPPED] PID $($p.Id) — $($p.ProcessName)" -ForegroundColor Green
            $removedItems.Add("Process: $($p.ProcessName) (PID $($p.Id))")
        }
    }

    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -like 'node*' -and $_.CommandLine -match $Pattern } |
        ForEach-Object {
            if ($PSCmdlet.ShouldProcess("PID $($_.ProcessId) (node — $($_.CommandLine))", "Stop process")) {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                Write-Host "  [STOPPED] Node PID $($_.ProcessId)" -ForegroundColor Green
                $removedItems.Add("Process: node (PID $($_.ProcessId))")
            }
        }
}

Write-Host "`nOpenClaw Removal Script for Windows" -ForegroundColor Cyan
Write-Host "Host      : $env:COMPUTERNAME"
Write-Host "User      : $env:USERNAME"
Write-Host "Date      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Log       : $logPath"
Write-Host ""
Write-Host "WARNING: This script will remove OpenClaw and related artifacts." -ForegroundColor Yellow
Write-Host "Ensure you have reviewed Detect-OpenClaw.ps1 output first." -ForegroundColor Yellow

if (-not $Force -and -not $WhatIfPreference) {
    $confirm = Read-Host "`nProceed? [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "Aborted." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 0
    }
}

Write-Section "Phase 1 — Kill Running Processes"

$processPatterns = @('openclaw', 'clawdbot', 'moltbot', 'monitor\.js', 'npm_telemetry')
foreach ($pat in $processPatterns) {
    Stop-ProcessSafely -Pattern $pat -Description "OpenClaw process"
}

Write-Section "Phase 2 — Remove npm Global Packages"

if (Get-Command npm -ErrorAction SilentlyContinue) {
    $pkgs = @('@openclaw-ai/openclawai', 'openclaw', 'clawdbot', 'moltbot')
    foreach ($pkg in $pkgs) {
        $installed = npm list -g --depth=0 2>$null | Select-String -Pattern ([regex]::Escape($pkg))
        if ($installed) {
            if ($PSCmdlet.ShouldProcess($pkg, "npm uninstall -g")) {
                npm uninstall -g $pkg 2>&1 | Out-Null
                Write-Host "  [REMOVED] npm package: $pkg" -ForegroundColor Green
                $removedItems.Add("npm: $pkg")
            }
        }
    }
} else {
    Write-Host "  npm not found — skipping." -ForegroundColor DarkGray
}

Write-Section "Phase 3 — Remove File System Artifacts"

$staticPaths = @(
    "$env:ProgramFiles\openclaw",
    "$env:ProgramFiles\clawdbot",
    "${env:ProgramFiles(x86)}\openclaw",
    "$env:ProgramData\openclaw",
    "$env:APPDATA\openclaw",
    "$env:LOCALAPPDATA\openclaw",
    "$env:APPDATA\npm\node_modules\openclaw",
    "$env:APPDATA\npm\node_modules\@openclaw-ai",
    "$env:APPDATA\.npm_telemetry",
    "$env:TEMP\openclaw-agent.exe",
    "$env:TEMP\TradeAI.exe"
)

$userProfiles = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

foreach ($profile in $userProfiles) {
    $staticPaths += @(
        "$profile\AppData\Roaming\openclaw",
        "$profile\AppData\Roaming\.npm_telemetry",
        "$profile\AppData\Local\openclaw",
        "$profile\.clawdbot",
        "$profile\clawdbot"
    )
}

foreach ($p in $staticPaths) {
    Remove-ItemSafely -Path $p -Description "OpenClaw artifact"
}

$payloadNames = @('payload.b64', 'openclaw-agent.exe', 'il24xgriequcys45', 'TradeAI.exe')
foreach ($name in $payloadNames) {
    Get-ChildItem -Path 'C:\' -Filter $name -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-ItemSafely -Path $_.FullName -Description "Payload file" }
}

Write-Section "Phase 4 — Remove Windows Services"

$svcPatterns = @('openclaw', 'clawdbot', 'moltbot', 'npm_telemetry')
Get-Service | ForEach-Object {
    $svc = $_
    foreach ($pat in $svcPatterns) {
        if ($svc.Name -like "*$pat*" -or $svc.DisplayName -like "*$pat*") {
            if ($PSCmdlet.ShouldProcess($svc.Name, "Stop and remove service")) {
                if ($svc.Status -eq 'Running') {
                    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                    Write-Host "  [STOPPED] Service: $($svc.Name)" -ForegroundColor Yellow
                }
                sc.exe delete $svc.Name | Out-Null
                Write-Host "  [REMOVED] Service: $($svc.Name)" -ForegroundColor Green
                $removedItems.Add("Service: $($svc.Name)")
            }
        }
    }
}

Write-Section "Phase 5 — Remove Scheduled Tasks"

Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
    $task = $_
    $actionStr = ($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
    if ($task.TaskName -match 'openclaw|clawdbot|moltbot|npm_telemetry' -or
        $actionStr     -match 'openclaw|clawdbot|moltbot|npm_telemetry') {
        if ($PSCmdlet.ShouldProcess($task.TaskName, "Unregister scheduled task")) {
            Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  [REMOVED] Scheduled Task: $($task.TaskName)" -ForegroundColor Green
            $removedItems.Add("ScheduledTask: $($task.TaskName)")
        }
    }
}

Write-Section "Phase 6 — Remove Registry Run Keys"

$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)

foreach ($key in $runKeys) {
    if (Test-Path $key) {
        Get-ItemProperty $key -ErrorAction SilentlyContinue |
            Get-Member -MemberType NoteProperty |
            Where-Object { $_.Name -notmatch '^PS' } |
            ForEach-Object {
                $name = $_.Name
                $val  = (Get-ItemProperty $key).$name
                if ($val -match 'openclaw|clawdbot|moltbot|npm_telemetry') {
                    if ($PSCmdlet.ShouldProcess("$key\$name", "Remove registry value")) {
                        Remove-ItemProperty -Path $key -Name $name -Force -ErrorAction SilentlyContinue
                        Write-Host "  [REMOVED] Registry: $key\$name" -ForegroundColor Green
                        $removedItems.Add("Registry: $key\$name")
                    }
                }
            }
    }
}

Write-Section "Phase 7 — Clean Shell Profile Injections"

$psProfiles = @(
    $PROFILE.AllUsersAllHosts,
    $PROFILE.AllUsersCurrentHost,
    $PROFILE.CurrentUserAllHosts,
    $PROFILE.CurrentUserCurrentHost
)
foreach ($pf in $psProfiles) {
    if (Test-Path $pf) {
        $content = Get-Content $pf -Raw -ErrorAction SilentlyContinue
        if ($content -match 'openclaw|clawdbot|moltbot|npm_telemetry') {
            if ($PSCmdlet.ShouldProcess($pf, "Remove OpenClaw injection from PowerShell profile")) {
                $cleaned = ($content -split "`n" | Where-Object { $_ -notmatch 'openclaw|clawdbot|moltbot|npm_telemetry' }) -join "`n"
                Set-Content -Path $pf -Value $cleaned -Force
                Write-Host "  [CLEANED] PowerShell profile: $pf" -ForegroundColor Green
                $removedItems.Add("ProfileClean: $pf")
            }
        }
    }
}

Write-Host "`n══ Summary ══" -ForegroundColor Cyan
Write-Host "Items removed : $($removedItems.Count)" -ForegroundColor $(if ($removedItems.Count -gt 0) { 'Green' } else { 'DarkGray' })
Write-Host "Warnings      : $($warnings.Count)" -ForegroundColor $(if ($warnings.Count -gt 0) { 'Yellow' } else { 'DarkGray' })
Write-Host "Log written   : $logPath" -ForegroundColor Cyan

if ($removedItems.Count -gt 0) {
    Write-Host "`n── Removed items ──" -ForegroundColor DarkGray
    $removedItems | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

Write-Host @"

════════════════════════════════════════════════════════
  NEXT STEPS — MANDATORY CREDENTIAL ROTATION
════════════════════════════════════════════════════════
  If OpenClaw (or associated malware) was confirmed on
  this host, rotate ALL of the following immediately:

  [ ] Windows account password
  [ ] OpenAI / Anthropic API keys
  [ ] AWS, GCP, Azure credentials in environment
  [ ] SSH private keys
  [ ] GitHub / GitLab tokens
  [ ] Browser saved passwords (all profiles)
  [ ] Any OAuth tokens OpenClaw had access to
  [ ] Crypto wallet seed phrases (if applicable)

  Re-run Detect-OpenClaw.ps1 after reboot to confirm
  clean state.
════════════════════════════════════════════════════════
"@ -ForegroundColor Yellow

Stop-Transcript | Out-Null
exit 0
