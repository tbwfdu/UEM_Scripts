#!/usr/bin/env bash
# =============================================================================
# Detect-OpenClaw.sh — OpenClaw Detection Script for macOS
# =============================================================================
# Does NOT remove anything — use Remove-OpenClaw.sh for remediation.
#
# Usage:
#   sudo ./Detect-OpenClaw.sh           # Full scan (recommended)
#   ./Detect-OpenClaw.sh                # User-scope scan only
#   ./Detect-OpenClaw.sh --quiet        # Suppress informational output
#   ./Detect-OpenClaw.sh --json         # JSON output to stdout
#   ./Detect-OpenClaw.sh --sensor       # WS1 Sensor mode — outputs "true" or "false"
#
# Exit code: 0 = script completed successfully, 1 = script error
#
# Last updated: 2026-03-31
# =============================================================================

set -euo pipefail

QUIET=false
JSON_OUT=false
SENSOR=false
FINDINGS=()
CHECKED=0

for arg in "$@"; do
    case "$arg" in
        --quiet)  QUIET=true ;;
        --json)   JSON_OUT=true ;;
        --sensor) SENSOR=true; QUIET=true ;;
    esac
done

RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
GREEN='\033[0;32m'; WHITE='\033[1;37m'; DGRAY='\033[0;90m'; RESET='\033[0m'

banner() {
    $QUIET && return
    echo -e "${CYAN}OpenClaw Detection Script for macOS${RESET}"
    echo "Host   : $(hostname)"
    echo "User   : $(whoami)"
    echo "Date   : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "EUID   : $EUID"
    [[ $EUID -ne 0 ]] && echo -e "${YELLOW}NOTE   : Not running as root — some checks may be incomplete.${RESET}"
    echo ""
}

section() {
    ((CHECKED++)) || true
    $QUIET || echo -e "\n${WHITE}==> $1${RESET}"
}

finding() {
    local severity="$1" category="$2" detail="$3"
    FINDINGS+=("{\"severity\":\"$severity\",\"category\":\"$category\",\"detail\":\"$(echo "$detail" | sed 's/"/\\"/g')\",\"host\":\"$(hostname)\",\"time\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}")
    if ! $QUIET; then
        local colour="$RED"
        [[ "$severity" == "MEDIUM" ]] && colour="$YELLOW"
        [[ "$severity" == "INFO" ]]   && colour="$CYAN"
        echo -e "  ${colour}[$severity]${RESET} ${WHITE}$category${RESET} — $detail"
    fi
}

banner

get_home_dirs() {
    if [[ $EUID -eq 0 ]]; then
        dscl . list /Users | grep -v '^_' | while read -r u; do
            local home
            home=$(dscl . read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
            [[ -d "$home" ]] && echo "$home"
        done
    else
        echo "$HOME"
    fi
}

HOME_DIRS=$(get_home_dirs)

section "Running Processes"

PROC_PATTERNS=('openclaw' 'clawdbot' 'moltbot' 'openclaw-agent' 'monitor\.js' 'npm_telemetry')

for pat in "${PROC_PATTERNS[@]}"; do
    matches=$(ps aux 2>/dev/null | grep -i "$pat" | grep -v grep | grep -v "Detect-OpenClaw" || true)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pid=$(echo "$line" | awk '{print $2}')
        cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf $i" "; print ""}')
        finding HIGH Process "PID $pid — $cmd"
    done <<< "$matches"
done

section "npm Global Packages"

if command -v npm &>/dev/null; then
    NPM_LIST=$(npm list -g --depth=0 2>/dev/null || true)
    for pkg in '@openclaw-ai/openclawai' 'openclaw' 'clawdbot' 'moltbot'; do
        if echo "$NPM_LIST" | grep -qi "$pkg"; then
            finding HIGH "npm Package" "Globally installed: $pkg"
        fi
    done
else
    $QUIET || echo -e "  ${DGRAY}npm not found — skipping package check.${RESET}"
fi

section "Binary / Install Paths"

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
    "/tmp/il24xgriequcys45"
    "/var/tmp/il24xgriequcys45"
)

for path in "${STATIC_PATHS[@]}"; do
    [[ -e "$path" ]] && finding HIGH FileSystem "Found: $path"
done

while IFS= read -r home; do
    USER_PATHS=(
        "$home/.openclaw"
        "$home/.clawdbot"
        "$home/clawdbot"
        "$home/.cache/.npm_telemetry"
        "$home/.clawdbot"
        "$home/Library/Application Support/openclaw"
        "$home/Library/Application Support/clawdbot"
        "$home/Library/Caches/openclaw"
    )
    for path in "${USER_PATHS[@]}"; do
        [[ -e "$path" ]] && finding HIGH FileSystem "Found: $path (home: $home)"
    done
done <<< "$HOME_DIRS"

section "Payload File Scan"

PAYLOAD_NAMES=('payload.b64' 'il24xgriequcys45' 'openclaw-agent' 'AuthTool')

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

for name in "${PAYLOAD_NAMES[@]}"; do
    while IFS= read -r hit; do
        finding HIGH "Payload File" "Found suspicious file: $hit"
    done < <(
        timeout 30 find /tmp /var/tmp /opt "$HOME" -maxdepth 6 \
            "${PRUNE_EXPR[@]}" \
            -name "*${name}*" -print 2>/dev/null || true
    )
done

section "launchd Persistence"

LAUNCHD_DIRS=(
    "/Library/LaunchDaemons"
    "/Library/LaunchAgents"
)

while IFS= read -r home; do
    LAUNCHD_DIRS+=("$home/Library/LaunchAgents")
done <<< "$HOME_DIRS"

for dir in "${LAUNCHD_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r plist; do
        content=$(cat "$plist" 2>/dev/null || true)
        if echo "$content" | grep -qiE 'openclaw|clawdbot|moltbot|npm_telemetry'; then
            label=$(defaults read "$plist" Label 2>/dev/null || basename "$plist")
            finding HIGH "launchd" "Suspicious plist: $plist (Label: $label)"
        fi
    done < <(find "$dir" -name '*.plist' 2>/dev/null || true)
done

section "Shell Profile Modifications"

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
            finding HIGH "Shell Profile" "$profile contains suspicious entry"
        fi
    done
done <<< "$HOME_DIRS"

section "Cron Jobs"

while IFS= read -r home; do
    user=$(stat -f '%Su' "$home" 2>/dev/null || echo "unknown")
    crontab_out=$(crontab -l -u "$user" 2>/dev/null || true)
    if echo "$crontab_out" | grep -qiE 'npm_telemetry|openclaw|clawdbot|monitor\.js'; then
        finding HIGH "Cron Job" "Suspicious cron entry for user $user"
    fi
done <<< "$HOME_DIRS"

section "API Key Exposure"

AI_KEY_VARS=('OPENAI_API_KEY' 'ANTHROPIC_API_KEY' 'OPENCLAW_TOKEN' 'CLAWD_TOKEN' 'CLAWD_KEY')

for var in "${AI_KEY_VARS[@]}"; do
    [[ -n "${!var:-}" ]] && finding MEDIUM "Environment Variable" "AI key exposed in environment: $var"
done

while IFS= read -r home; do
    ENV_DIRS=("$home/.openclaw" "$home/.clawdbot" "$home/Library/Application Support/openclaw")
    for d in "${ENV_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r envfile; do
            for var in "${AI_KEY_VARS[@]}"; do
                if grep -q "^${var}=" "$envfile" 2>/dev/null; then
                    finding MEDIUM "Config File" "AI key found in $envfile: $var"
                fi
            done
        done < <(find "$d" -name '.env' 2>/dev/null || true)
    done
done <<< "$HOME_DIRS"

section "Network Connections"

SUSPICIOUS_DOMAINS=('clawdbot' 'openclaw' 'clawhub' 'npm_telemetry' 'glot\.io')

if command -v lsof &>/dev/null; then
    NET_OUTPUT=$(lsof -i -n -P 2>/dev/null | grep ESTABLISHED || true)
    for domain in "${SUSPICIOUS_DOMAINS[@]}"; do
        matches=$(echo "$NET_OUTPUT" | grep -i "$domain" || true)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            finding HIGH Network "Active connection matching '$domain': $line"
        done <<< "$matches"
    done
fi

count=${#FINDINGS[@]}

if ! $QUIET; then
    echo -e "\n${DGRAY}─────────────────────────────────────────${RESET}"
    echo -e "Checks completed : $CHECKED sections"
    if [[ $count -gt 0 ]]; then
        echo -e "Findings         : ${RED}$count${RESET}"
        echo -e "\n${YELLOW}IMPORTANT: If HIGH findings are present, consider isolating this"
        echo -e "host (disconnect from network) before running Remove-OpenClaw.sh.${RESET}\n"
    else
        echo -e "Findings         : ${GREEN}0${RESET}"
        echo -e "${GREEN}No OpenClaw indicators detected on this host.${RESET}\n"
    fi
fi

if $SENSOR; then
    [[ $count -gt 0 ]] && echo "true" || echo "false"
    exit 0
fi

if $JSON_OUT; then
    echo "["
    for i in "${!FINDINGS[@]}"; do
        echo "${FINDINGS[$i]}"
        [[ $i -lt $((count - 1)) ]] && echo ","
    done
    echo "]"
fi

exit 0
