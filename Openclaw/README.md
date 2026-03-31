# OpenClaw Detection & Removal Scripts

**Version:** 1.0 | **Date:** 2026-03-31
**Platforms:** Windows (PowerShell), macOS (Bash)

---

## Script Overview

| Script | Platform | Purpose |
|---|---|---|
| `Detect-OpenClaw.ps1` | Windows | Detection only — no changes made |
| `Detect-OpenClaw.sh` | macOS | Detection only — no changes made |
| `Remove-OpenClaw.ps1` | Windows | Removal (run after detection confirms findings) |
| `Remove-OpenClaw.sh` | macOS | Removal (run after detection confirms findings) |

---

## Usage

### Windows

```powershell
# Detection — run as Administrator
.\Detect-OpenClaw.ps1

# Detection — JSON output
.\Detect-OpenClaw.ps1 -JsonOut

# Detection — WS1 Sensor mode (returns "true" or "false")
.\Detect-OpenClaw.ps1 -Sensor

# Removal — dry-run first
.\Remove-OpenClaw.ps1 -WhatIf

# Removal — run as Administrator
.\Remove-OpenClaw.ps1

# Removal — unattended (WS1 deployment)
.\Remove-OpenClaw.ps1 -Force
```

### macOS

```bash
# Detection — run as root for full coverage
sudo ./Detect-OpenClaw.sh

# Detection — JSON output
sudo ./Detect-OpenClaw.sh --json

# Detection — WS1 Sensor mode (returns "true" or "false")
sudo ./Detect-OpenClaw.sh --sensor

# Removal — dry-run first
sudo ./Remove-OpenClaw.sh --dry-run

# Removal
sudo ./Remove-OpenClaw.sh

# Removal — unattended (Jamf / MDM)
sudo ./Remove-OpenClaw.sh --force
```

---

## Detection Scope (both platforms)

- Running processes matching OpenClaw / Clawdbot / Moltbot patterns
- npm global package installations
- Binary and install directory paths
- System service / launchd daemon registrations
- Scheduled Tasks / cron jobs
- Registry Run keys (Windows) / shell profile injections (macOS)
- `npm_telemetry` malware directories
- Known payload files (`payload.b64`, `il24xgriequcys45`, `openclaw-agent`)
- AI API keys in environment variables
- Network connections to suspicious domains

## Removal Scope (both platforms)

All of the above are remediated where detected. Shell profiles are backed up
before modification. A timestamped log is written to `%TEMP%` (Windows) or
`/tmp` (macOS).

---

## Workspace ONE UEM Integration

### WS1 Sensors

Use the `-Sensor` / `--sensor` flag to return a single `true` or `false` value,
suitable for use as a WS1 Sensor. The script suppresses all other output and
always exits `0` so the sensor value is read from stdout.

| Result | Meaning |
|---|---|
| `true` | OpenClaw indicators detected |
| `false` | No indicators found |

### WS1 Scripts

Deploy `Remove-OpenClaw.ps1 -Force` or `Remove-OpenClaw.sh --force` as a
WS1 Script to remediate without user interaction. Both scripts exit `0` on
completion.

### Exit Codes

All scripts exit `0` on successful completion and `1` on failure (e.g. not
running as admin/root). Detection results are conveyed via `--sensor` output
or `--json`, not via exit codes.

---

## Recommended Workflow

1. **Isolate** the host from the network if active compromise is suspected.
2. Run the **detection script** and review findings.
3. Run the **removal script** in `--dry-run` / `-WhatIf` mode first.
4. Run the **removal script** with administrator / root privileges.
5. **Reboot** the host.
6. Re-run the **detection script** to confirm clean state.
7. **Rotate all credentials** — see the checklist printed by the removal scripts.
