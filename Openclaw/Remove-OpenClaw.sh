#!/usr/bin/env bash
# =============================================================================
# Remove-OpenClaw.sh — OpenClaw Removal Script for macOS
# =============================================================================
# Usage:
#   sudo ./Remove-OpenClaw.sh            # Full removal (recommended)
#   sudo ./Remove-OpenClaw.sh --dry-run  # Show what would be removed
#   sudo ./Remove-OpenClaw.sh --force    # Skip confirmation prompt
#
# Log is written to /tmp/Remove-OpenClaw-<timestamp>.log
#
# Last updated: 2026-03-31
# =============================================================================

set -uo pipefail

DRY_RUN=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo ./Remove-OpenClaw.sh)."
    exit 1
fi

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG="/tmp/Remove-OpenClaw-${TIMESTAMP}.log"
exec > >(tee -a "$LOG") 2>&1

REMOVED=()
WARNINGS=()

RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
GREEN='\033[0;32m'; WHITE='\033[1;37m'; DGRAY='\033[0;90m'; RESET='\033[0m'

section() { echo -e "\n${CYAN}══ $1 ══${RESET}"; }

log_removed() { REMOVED+=("$1"); echo -e "  ${GREEN}[REMOVED]${RESET} $1"; }
log_warning() { WARNINGS+=("$1"); echo -e "  ${YELLOW}[WARNING]${RESET} $1"; }
log_skip()    { echo -e "  ${DGRAY}[SKIP]${RESET} $1 (not found)"; }

remove_path() {
    local path="$1" desc="${2:-}"
    if [[ -e "$path" ]]; then
        if $DRY_RUN; then
            echo -e "  ${CYAN}[DRY-RUN]${RESET} Would remove: $path"
        else
            rm -rf "$path" 2>/dev/null && log_removed "$path" || log_warning "Failed to remove: $path"
        fi
    else
        log_skip "$path"
    fi
}

get_home_dirs() {
    dscl . list /Users | grep -v '^_' | while read -r u; do
        local home
        home=$(dscl . read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        [[ -d "$home" ]] && echo "$home"
    done
}

HOME_DIRS=$(get_home_dirs)

echo -e "${CYAN}OpenClaw Removal Script for macOS${RESET}"
echo "Host   : $(hostname)"
echo "User   : $(whoami)"
echo "Date   : $(date '+%Y-%m-%d %H:%M:%S')"
echo "Log    : $LOG"
$DRY_RUN && echo -e "${CYAN}Mode   : DRY-RUN — no changes will be made.${RESET}"
echo ""
echo -e "${YELLOW}WARNING: This script will remove OpenClaw and related artifacts."
echo -e "Ensure you have reviewed Detect-OpenClaw.sh output first.${RESET}"

if ! $FORCE && ! $DRY_RUN; then
    read -rp $'\nProceed? [y/N] ' confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

section "Phase 1 — Kill Running Processes"

KILL_PATTERNS=('openclaw' 'clawdbot' 'moltbot' 'monitor\.js' 'npm_telemetry')

for pat in "${KILL_PATTERNS[@]}"; do
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pid=$(echo "$line" | awk '{print $2}')
        cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf $i" "; print ""}')
        if $DRY_RUN; then
            echo -e "  ${CYAN}[DRY-RUN]${RESET} Would kill PID $pid: $cmd"
        else
            kill -9 "$pid" 2>/dev/null && log_removed "Process PID $pid ($cmd)" || true
        fi
    done < <(ps aux 2>/dev/null | grep -iE "$pat" | grep -v grep | grep -v "Remove-OpenClaw" || true)
done

section "Phase 2 — Remove launchd Persistence"

LAUNCHD_DIRS=("/Library/LaunchDaemons" "/Library/LaunchAgents")
while IFS= read -r home; do
    LAUNCHD_DIRS+=("$home/Library/LaunchAgents")
done <<< "$HOME_DIRS"

for dir in "${LAUNCHD_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r plist; do
        content=$(cat "$plist" 2>/dev/null || true)
        if echo "$content" | grep -qiE 'openclaw|clawdbot|moltbot|npm_telemetry'; then
            label=$(defaults read "$plist" Label 2>/dev/null || basename "$plist" .plist)
            if $DRY_RUN; then
                echo -e "  ${CYAN}[DRY-RUN]${RESET} Would unload and remove: $plist"
            else
                launchctl unload "$plist" 2>/dev/null || true
                launchctl bootout system "$plist" 2>/dev/null || true
                remove_path "$plist" "launchd plist"
            fi
        fi
    done < <(find "$dir" -name '*.plist' 2>/dev/null || true)
done

section "Phase 3 — Remove npm Global Packages"

if command -v npm &>/dev/null; then
    NPM_LIST=$(npm list -g --depth=0 2>/dev/null || true)
    for pkg in '@openclaw-ai/openclawai' 'openclaw' 'clawdbot' 'moltbot'; do
        if echo "$NPM_LIST" | grep -qi "$pkg"; then
            if $DRY_RUN; then
                echo -e "  ${CYAN}[DRY-RUN]${RESET} Would run: npm uninstall -g $pkg"
            else
                npm uninstall -g "$pkg" 2>/dev/null && log_removed "npm: $pkg" || log_warning "npm uninstall failed for $pkg"
            fi
        else
            log_skip "npm: $pkg"
        fi
    done
else
    echo -e "  ${DGRAY}npm not found — skipping.${RESET}"
fi

section "Phase 4 — Remove File System Artifacts"

STATIC_PATHS=(
    "/usr/local/bin/openclaw"
    "/usr/local/bin/clawdbot"
    "/usr/local/bin/moltbot"
    "/opt/openclaw"
    "/opt/clawdbot"
    "/usr/local/lib/node_modules/openclaw"
    "/usr/local/lib/node_modules/@openclaw-ai"
    "/Applications/OpenClaw.app"
    "/Applications/Clawdbot.app"
)

for path in "${STATIC_PATHS[@]}"; do
    remove_path "$path"
done

while IFS= read -r home; do
    USER_PATHS=(
        "$home/.openclaw"
        "$home/.clawdbot"
        "$home/clawdbot"
        "$home/Library/Application Support/openclaw"
        "$home/Library/Application Support/clawdbot"
        "$home/Library/Caches/openclaw"
    )
    for path in "${USER_PATHS[@]}"; do
        remove_path "$path"
    done
done <<< "$HOME_DIRS"

section "Phase 5 — Remove npm_telemetry Malware"

while IFS= read -r home; do
    remove_path "$home/.cache/.npm_telemetry"
done <<< "$HOME_DIRS"

section "Phase 6 — Remove Payload Files"

PRUNE_EXPR=(
    \( -path "$HOME/Library"
    -o -path "$HOME/Pictures"
    -o -path "$HOME/Movies"
    -o -path "$HOME/Music"
    -o -path "*/node_modules"
    -o -path "*/.git"
    -o -path "*/iCloud Drive"
    -o -path "*/.Trash" \)
    -prune -o
)

PAYLOAD_NAMES=('payload.b64' 'il24xgriequcys45' 'openclaw-agent')
for name in "${PAYLOAD_NAMES[@]}"; do
    while IFS= read -r hit; do
        remove_path "$hit" "payload file"
    done < <(
        timeout 30 find /tmp /var/tmp /opt "$HOME" -maxdepth 6 \
            "${PRUNE_EXPR[@]}" \
            -name "*${name}*" -print 2>/dev/null || true
    )
done

section "Phase 7 — Remove Cron Job Entries"

while IFS= read -r home; do
    user=$(stat -f '%Su' "$home" 2>/dev/null || echo "")
    [[ -z "$user" ]] && continue
    existing=$(crontab -l -u "$user" 2>/dev/null || true)
    if echo "$existing" | grep -qiE 'npm_telemetry|openclaw|clawdbot|monitor\.js'; then
        cleaned=$(echo "$existing" | grep -viE 'npm_telemetry|openclaw|clawdbot|monitor\.js')
        if $DRY_RUN; then
            echo -e "  ${CYAN}[DRY-RUN]${RESET} Would clean crontab for $user"
        else
            echo "$cleaned" | crontab -u "$user" - 2>/dev/null && \
                log_removed "Cron entries for $user" || \
                log_warning "Failed to update crontab for $user"
        fi
    else
        log_skip "crontab for $user (no matching entries)"
    fi
done <<< "$HOME_DIRS"

section "Phase 8 — Clean Shell Profile Injections"

while IFS= read -r home; do
    PROFILES=(
        "$home/.zshrc"
        "$home/.bashrc"
        "$home/.bash_profile"
        "$home/.zshenv"
        "$home/.profile"
    )
    for profile in "${PROFILES[@]}"; do
        [[ -f "$profile" ]] || continue
        if grep -qiE 'npm_telemetry|NPM Telemetry Integration Service|openclaw|clawdbot' "$profile" 2>/dev/null; then
            if $DRY_RUN; then
                echo -e "  ${CYAN}[DRY-RUN]${RESET} Would clean: $profile"
            else
                cp "$profile" "${profile}.bak.${TIMESTAMP}"
                grep -viE 'npm_telemetry|NPM Telemetry Integration Service|openclaw|clawdbot' \
                    "${profile}.bak.${TIMESTAMP}" > "$profile" && \
                    log_removed "Profile injection in $profile (backup: ${profile}.bak.${TIMESTAMP})" || \
                    log_warning "Failed to clean $profile"
            fi
        else
            log_skip "Profile $profile (no suspicious entries)"
        fi
    done
done <<< "$HOME_DIRS"

removed_count=${#REMOVED[@]}
warning_count=${#WARNINGS[@]}

echo ""
echo -e "${DGRAY}─────────────────────────────────────────${RESET}"
echo "Items removed : $removed_count"
echo "Warnings      : $warning_count"
echo "Log written   : $LOG"

if [[ $removed_count -gt 0 ]]; then
    echo -e "\n${DGRAY}── Removed items ──${RESET}"
    for item in "${REMOVED[@]}"; do echo "  $item"; done
fi

if [[ $warning_count -gt 0 ]]; then
    echo -e "\n${YELLOW}── Warnings ──${RESET}"
    for warn in "${WARNINGS[@]}"; do echo -e "  ${YELLOW}$warn${RESET}"; done
fi

echo -e "
${YELLOW}════════════════════════════════════════════════════════
  NEXT STEPS — MANDATORY CREDENTIAL ROTATION
════════════════════════════════════════════════════════
  If OpenClaw (or associated malware) was confirmed on
  this host, rotate ALL of the following immediately:

  [ ] macOS login password / FileVault recovery key
  [ ] OpenAI / Anthropic API keys
  [ ] AWS, GCP, Azure credentials
  [ ] SSH private keys (~/.ssh/)
  [ ] GitHub / GitLab tokens
  [ ] Browser saved passwords (Safari, Chrome, Firefox)
  [ ] iCloud Keychain entries (if AMOS accessed keychain)
  [ ] KeePass / 1Password master password
  [ ] Crypto wallet seed phrases (if applicable)
  [ ] Any OAuth tokens OpenClaw had access to

  Re-run Detect-OpenClaw.sh after reboot to confirm
  clean state.
════════════════════════════════════════════════════════${RESET}
"

exit 0
