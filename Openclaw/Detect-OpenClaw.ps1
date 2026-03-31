#Requires -Version 5.1
<#
.SYNOPSIS
    Detects OpenClaw (formerly Clawdbot / Moltbot) installations and associated
    malicious artifacts on a Windows endpoint.

.NOTES
    Run as Administrator for full coverage.
    Does NOT remove anything — use Remove-OpenClaw.ps1 for remediation.
    Use -Sensor for WS1 Sensor mode — outputs "true" or "false".

    Last updated: 2026-03-31
#>

[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$JsonOut,
    [switch]$Sensor
)

if ($Sensor) { $Quiet = $true }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$checked  = 0

function Add-Finding {
    param([string]$Category, [string]$Detail, [string]$Severity = 'HIGH')
    $f = [PSCustomObject]@{
        Severity = $Severity
        Category = $Category
        Detail   = $Detail
        Host     = $env:COMPUTERNAME
        Time     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    }
    $findings.Add($f)
    if (-not $Quiet) {
        $colour = if ($Severity -eq 'HIGH') { 'Red' } elseif ($Severity -eq 'MEDIUM') { 'Yellow' } else { 'Cyan' }
        Write-Host "  [$Severity] $Category — $Detail" -ForegroundColor $colour
    }
}

function Write-Section {
    param([string]$Title)
    $script:checked++
    if (-not $Quiet) { Write-Host "`n==> $Title" -ForegroundColor White }
}

if (-not $Quiet) {
    Write-Host "`nOpenClaw Detection Script for Windows" -ForegroundColor Cyan
    Write-Host "Host   : $env:COMPUTERNAME"
    Write-Host "User   : $env:USERNAME"
    Write-Host "Date   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "Note   : Run as Administrator for full coverage.`n"
}

Write-Section "Running Processes"

$suspiciousProcessNames = @(
    'openclaw', 'clawdbot', 'moltbot',
    'openclaw-agent', 'monitor.js', 'npm_telemetry'
)

Get-Process | ForEach-Object {
    $name = $_.ProcessName.ToLower()
    foreach ($s in $suspiciousProcessNames) {
        if ($name -like "*$s*") {
            Add-Finding 'Process' "PID $($_.Id) — $($_.ProcessName) ($($_.Path))"
        }
    }
}

Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'node*' } | ForEach-Object {
    $cmd = $_.CommandLine
    if ($cmd -match 'openclaw|clawdbot|moltbot|npm_telemetry|monitor\.js') {
        Add-Finding 'Process' "Node.js with suspicious command line: $cmd"
    }
}

Write-Section "npm Global Packages"

if (Get-Command npm -ErrorAction SilentlyContinue) {
    $npmList = npm list -g --depth=0 2>$null
    $suspiciousPkgs = @('@openclaw-ai/openclawai', 'openclaw', 'clawdbot', 'moltbot')
    foreach ($pkg in $suspiciousPkgs) {
        if ($npmList -match [regex]::Escape($pkg)) {
            Add-Finding 'npm Package' "Globally installed: $pkg"
        }
    }
} else {
    if (-not $Quiet) { Write-Host "  npm not found — skipping package check." -ForegroundColor DarkGray }
}

Write-Section "Binary / Install Paths"

$binaryPaths = @(
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
    $binaryPaths += @(
        "$profile\AppData\Roaming\openclaw",
        "$profile\AppData\Roaming\.npm_telemetry",
        "$profile\AppData\Local\openclaw",
        "$profile\.clawdbot",
        "$profile\clawdbot"
    )
}

foreach ($p in $binaryPaths) {
    if (Test-Path $p) {
        $isExe = $p -match '\.(exe|msi)$'
        $sev   = if ($isExe) { 'HIGH' } else { 'MEDIUM' }
        Add-Finding 'FileSystem' "Found: $p" -Severity $sev
    }
}

Write-Section "Payload File Scan"
$payloadNames = @('payload.b64', 'openclaw-agent.exe', 'il24xgriequcys45')
$payloadSearchPaths = @($env:TEMP, "$env:LOCALAPPDATA\Temp", $env:APPDATA, $env:LOCALAPPDATA,
    $env:ProgramData, "$env:SystemRoot\Temp") + $userProfiles
foreach ($searchPath in $payloadSearchPaths) {
    if (-not (Test-Path $searchPath)) { continue }
    foreach ($name in $payloadNames) {
        Get-ChildItem -Path $searchPath -Filter $name -Recurse -Depth 5 -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Add-Finding 'Payload File' "Found suspicious file: $($_.FullName)" }
    }
}

Write-Section "Windows Services"

$suspiciousSvcPatterns = @('openclaw', 'clawdbot', 'moltbot', 'npm_telemetry', 'NPM Telemetry')
Get-Service | ForEach-Object {
    foreach ($pattern in $suspiciousSvcPatterns) {
        if ($_.Name -like "*$pattern*" -or $_.DisplayName -like "*$pattern*") {
            Add-Finding 'Service' "Service found: $($_.Name) [$($_.DisplayName)] — Status: $($_.Status)"
        }
    }
}

$svcReg = 'HKLM:\SYSTEM\CurrentControlSet\Services'
Get-ChildItem $svcReg -ErrorAction SilentlyContinue | ForEach-Object {
    $imagePath = (Get-ItemProperty $_.PSPath -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    if ($imagePath -match 'openclaw|clawdbot|moltbot|npm_telemetry') {
        Add-Finding 'Service' "Service registry entry with suspicious image path: $imagePath"
    }
}

Write-Section "Scheduled Tasks"

Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
    $taskName = $_.TaskName
    $actions  = $_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }
    $actionStr = $actions -join ' '
    if ($taskName -match 'openclaw|clawdbot|moltbot|npm_telemetry' -or
        $actionStr -match 'openclaw|clawdbot|moltbot|npm_telemetry') {
        Add-Finding 'Scheduled Task' "Task: $taskName — Action: $actionStr"
    }
}

Write-Section "Registry Run Keys"

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
                $val = (Get-ItemProperty $key).$($_.Name)
                if ($val -match 'openclaw|clawdbot|moltbot|npm_telemetry') {
                    Add-Finding 'Registry Run Key' "$key\$($_.Name) = $val"
                }
            }
    }
}

Write-Section "Environment Variable — API Key Exposure"

$aiKeyPatterns = @('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'OPENCLAW_TOKEN',
                   'CLAWD_TOKEN', 'CLAWD_KEY', 'OPENAI_KEY')
foreach ($var in $aiKeyPatterns) {
    $val = [System.Environment]::GetEnvironmentVariable($var, 'Machine')
    if ($val) {
        Add-Finding 'Environment Variable' "Machine-level AI key exposed: $var" -Severity 'MEDIUM'
    }
    $val = [System.Environment]::GetEnvironmentVariable($var, 'User')
    if ($val) {
        Add-Finding 'Environment Variable' "User-level AI key exposed: $var" -Severity 'MEDIUM'
    }
}

Write-Section "Network Connections"

$suspiciousDomainPatterns = @(
    'clawdbot', 'openclaw', 'clawhub', 'npm_telemetry', 'glot\.io'
)

# Build a lookup of resolved IPs from DNS cache (instant, no network calls)
$dnsCache = @{}
Get-DnsClientCache -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Data) { $dnsCache[$_.Data] = $_.Entry }
}

$netstat = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue
foreach ($conn in $netstat) {
    $remoteAddr = $conn.RemoteAddress
    $resolvedName = if ($dnsCache.ContainsKey($remoteAddr)) { $dnsCache[$remoteAddr] } else { $remoteAddr }
    foreach ($pattern in $suspiciousDomainPatterns) {
        if ($resolvedName -match $pattern) {
            Add-Finding 'Network' "Active connection to suspicious host: $resolvedName ($remoteAddr):$($conn.RemotePort) — Local PID: $($conn.OwningProcess)"
        }
    }
}

if (-not $Quiet) {
    Write-Host "`n─────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "Checks completed : $checked sections" -ForegroundColor Cyan
    Write-Host "Findings         : $($findings.Count)" -ForegroundColor $(if ($findings.Count -gt 0) { 'Red' } else { 'Green' })
}

if ($findings.Count -eq 0 -and -not $Quiet) {
    Write-Host "No OpenClaw indicators detected on this host." -ForegroundColor Green
}

if ($Sensor) {
    if ($findings.Count -gt 0) { Write-Output 'true' } else { Write-Output 'false' }
    exit 0
}

if ($JsonOut) {
    $findings | ConvertTo-Json -Depth 5
} elseif ($findings.Count -gt 0) {
    Write-Host "`nIMPORTANT: If any HIGH findings are present, consider isolating" -ForegroundColor Yellow
    Write-Host "this host before running Remove-OpenClaw.ps1.`n" -ForegroundColor Yellow
}

exit 0
