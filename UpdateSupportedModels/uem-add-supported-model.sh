#!/usr/bin/env bash
# uem-add-supported-model.sh
# Adds a supported model ID to macOS internal apps in Workspace ONE UEM via REST API.
# Uses OAuth 2.0 client credentials for authentication.
#
# Usage:
#   ./uem-add-supported-model.sh --model-id <id> [--bundle-id <bundle_id>] [--all]
#
# Required env vars (or pass as args):
#   WS1_CLIENT_ID      OAuth client ID
#   WS1_CLIENT_SECRET  OAuth client secret
#   WS1_TOKEN_URL      OAuth token endpoint
#   WS1_API_BASE_URL   UEM API base URL (e.g. https://as1831.awmdm.com)

set -euo pipefail

# ─── Banner ───────────────────────────────────────────────────────────────────
printf '╔════════════════════════════════════════════════════════════╗\n'
printf '║  Script    : uem-add-supported-model.sh                    ║\n'
printf '║  Function  : Adds a supported model ID to macOS internal   ║\n'
printf '║              apps in Workspace ONE UEM via REST API.       ║\n'
printf '╠════════════════════════════════════════════════════════════╣\n'
printf '║  Author    : Pete Lindley                                  ║\n'
printf '║  GitHub    : github.com/tbwfdu                             ║\n'
printf '║  Email     : plindley@omnissa.com                          ║\n'
printf '╚════════════════════════════════════════════════════════════╝\n'
printf '\n'

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────
MODEL_ID=""
BUNDLE_ID=""
UPDATE_ALL=false
DRY_RUN=false

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Adds a model ID to the SupportedModels list of macOS internal apps in WS1 UEM.

Required:
  --model-id <id>          Numeric model ID to add (e.g. 121 for MacBook Neo)

Target (one required):
  --bundle-id <bundle_id>  Update a single app by its bundle ID
  --all                    Update ALL macOS internal apps

Options:
  --api-base <url>         UEM API base URL (overrides \$WS1_API_BASE_URL)
  --token-url <url>        OAuth token URL (overrides \$WS1_TOKEN_URL)
  --client-id <id>         OAuth client ID (overrides \$WS1_CLIENT_ID)
  --client-secret <secret> OAuth client secret (overrides \$WS1_CLIENT_SECRET)
  --dry-run                Print what would be changed without making API calls
  -h, --help               Show this help

Environment variables (can be used instead of flags):
  WS1_CLIENT_ID, WS1_CLIENT_SECRET, WS1_TOKEN_URL, WS1_API_BASE_URL

Examples:
  # Add MacBook Neo (model 121) to a single app
  ./$(basename "$0") --model-id 121 --bundle-id com.example.myapp

  # Add MacBook Neo to ALL macOS apps (dry run first)
  ./$(basename "$0") --model-id 121 --all --dry-run
  ./$(basename "$0") --model-id 121 --all
EOF
  exit 0
}

# ─── Arg parsing ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model-id)       MODEL_ID="$2";          shift 2 ;;
    --bundle-id)      BUNDLE_ID="$2";         shift 2 ;;
    --all)            UPDATE_ALL=true;         shift   ;;
    --api-base)       WS1_API_BASE_URL="$2";  shift 2 ;;
    --token-url)      WS1_TOKEN_URL="$2";     shift 2 ;;
    --client-id)      WS1_CLIENT_ID="$2";     shift 2 ;;
    --client-secret)  WS1_CLIENT_SECRET="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true;            shift   ;;
    -h|--help)        usage ;;
    *) echo -e "${RED}Unknown option: $1${NC}" >&2; usage ;;
  esac
done

# ─── Validate inputs ──────────────────────────────────────────────────────────
errors=0

if [[ -z "$MODEL_ID" ]]; then
  echo -e "${RED}Error: --model-id is required${NC}" >&2
  ((errors++))
fi

if [[ "$UPDATE_ALL" == false && -z "$BUNDLE_ID" ]]; then
  echo -e "${RED}Error: specify --bundle-id <id> or --all${NC}" >&2
  ((errors++))
fi

if [[ "$UPDATE_ALL" == true && -n "$BUNDLE_ID" ]]; then
  echo -e "${RED}Error: --bundle-id and --all are mutually exclusive${NC}" >&2
  ((errors++))
fi

: "${WS1_CLIENT_ID:?Error: WS1_CLIENT_ID is not set (use --client-id or env var)}"
: "${WS1_CLIENT_SECRET:?Error: WS1_CLIENT_SECRET is not set (use --client-secret or env var)}"
: "${WS1_TOKEN_URL:?Error: WS1_TOKEN_URL is not set (use --token-url or env var)}"
: "${WS1_API_BASE_URL:?Error: WS1_API_BASE_URL is not set (use --api-base or env var)}"

[[ $errors -gt 0 ]] && exit 1

# Check dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Error: '$cmd' is required but not installed${NC}" >&2
    exit 1
  fi
done

# ─── OAuth token ──────────────────────────────────────────────────────────────
get_token() {
  echo -e "${CYAN}Authenticating with OAuth...${NC}" >&2
  local response
  response=$(curl -sf -X POST "$WS1_TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${WS1_CLIENT_ID}" \
    -d "client_secret=${WS1_CLIENT_SECRET}") || {
      echo -e "${RED}Error: Failed to obtain OAuth token${NC}" >&2
      exit 1
    }

  local token
  token=$(echo "$response" | jq -r '.access_token // empty')
  if [[ -z "$token" ]]; then
    echo -e "${RED}Error: No access_token in OAuth response${NC}" >&2
    echo "$response" >&2
    exit 1
  fi
  echo "$token"
}

# ─── API helpers ──────────────────────────────────────────────────────────────
api_get() {
  local path="$1"
  curl -sf -X GET "${WS1_API_BASE_URL}${path}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json"
}

# Returns HTTP status code; response body goes to stderr for debugging
api_put() {
  local path="$1"
  local body="$2"
  local tmp_body tmp_code
  tmp_body=$(mktemp)
  tmp_code=$(curl -s -o "$tmp_body" -w "%{http_code}" -X PUT "${WS1_API_BASE_URL}${path}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$body")
  # Print response body to stderr for debugging
  cat "$tmp_body" >&2
  rm -f "$tmp_body"
  echo "$tmp_code"
}

# ─── Fetch all macOS internal apps (platform=10) ──────────────────────────────
fetch_macos_apps() {
  echo -e "${CYAN}Fetching macOS internal apps...${NC}" >&2
  local response
  response=$(api_get "/api/mam/apps/search?type=internal&pagesize=500") || \
  response=$(api_get "/api/mam/apps/search?pagesize=500") || {
    echo -e "${RED}Error: Failed to fetch apps from UEM${NC}" >&2
    exit 1
  }
  echo "$response" | jq '[.Application[] | select(.Platform == 10)]'
}

# ─── Fetch full app record by numeric ID ──────────────────────────────────────
fetch_full_app() {
  local app_id="$1"
  api_get "/api/mam/apps/internal/${app_id}"
}

# ─── Update a single app ──────────────────────────────────────────────────────
update_app() {
  local app_id="$1"
  local app_uuid="$2"
  local og_uuid="$3"
  local app_name="$4"
  local app_status="$5"

  # Skip retired/inactive apps
  local status_lower
  status_lower=$(echo "$app_status" | tr '[:upper:]' '[:lower:]')
  if [[ "$status_lower" == "retired" || "$status_lower" == "inactive" ]]; then
    echo -e "${YELLOW}  SKIP${NC} ${app_name} (ID: ${app_id}) — status is ${app_status}, skipping"
    return 0
  fi

  # Fetch the full app record
  local full_app
  full_app=$(fetch_full_app "$app_id") || {
    echo -e "${RED}  FAIL${NC} ${app_name} (ID: ${app_id}) — could not fetch full app record" >&2
    return 1
  }

  # Check if model already present
  local already_has
  already_has=$(echo "$full_app" | jq --argjson mid "$MODEL_ID" \
    '[.SupportedModels[]? | select(.id == $mid)] | length')

  if [[ "$already_has" -gt 0 ]]; then
    echo -e "${YELLOW}  SKIP${NC} ${app_name} (ID: ${app_id}) — model ${MODEL_ID} already present"
    return 0
  fi

  # Build updated SupportedModels — keep existing entries, append new one
  # Generic endpoint expects: {"Model": [{"ModelId": N, "ModelName": ""}, ...]}
  # macOS endpoint expects:   [{"id": N, "Name": ""}, ...]
  local new_models_array new_models_object
  new_models_array=$(echo "$full_app" | jq --argjson mid "$MODEL_ID" \
    '[.SupportedModels[]?, {"id": $mid, "Name": "MacBook Neo"}]')
  new_models_object=$(echo "$new_models_array" | jq \
    '{"Model": map({"ModelId": .id, "ModelName": (.Name // "")})}')

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}  DRY-RUN${NC} Would update ${app_name} (ID: ${app_id}) — adding model ${MODEL_ID}"
    echo "    New SupportedModels: $(echo "$new_models_array" | jq -c .)"
    return 0
  fi

  # Payload for macOS-specific endpoint — SupportedModels as array of {id, Name}
  local payload_macos
  payload_macos=$(echo "$full_app" | jq \
    --argjson models "$new_models_array" \
    '{
      ApplicationName:                .ApplicationName,
      DisplayName:                    (.DisplayName // .ApplicationName),
      AppId:                          .AppId,
      AirwatchAppVersion:             .AirwatchAppVersion,
      ActualFileVersion:              .ActualFileVersion,
      Platform:                       10,
      SupportedModels:                $models,
      MinimumOperatingSystem:         (.MinimumOperatingSystem // ""),
      ManagedBy:                      (.ManagedBy | tonumber),
      ManagedByUuid:                  .ManagedByUuid,
      Sdk:                            .Sdk,
      AssumeManagementOfUserInstalledApp: .AssumeManagementOfUserInstalledApp,
      Comments:                       (.Comments // ""),
      ChangeLog:                      (.ChangeLog // ""),
      CategoryList:                   {"Category": (.CategoryList // [])},
      Assignments:                    .Assignments,
      ExcludedSmartGroupIds:          .ExcludedSmartGroupIds
    }')

  # Payload for generic internal endpoint — SupportedModels as {"Model": [{ModelId, ModelName}]}
  local payload_generic
  payload_generic=$(echo "$full_app" | jq \
    --argjson models "$new_models_object" \
    '{
      ApplicationName:                .ApplicationName,
      AppId:                          .AppId,
      AirwatchAppVersion:             .AirwatchAppVersion,
      ActualFileVersion:              .ActualFileVersion,
      Platform:                       10,
      SupportedModels:                $models,
      MinimumOperatingSystem:         (.MinimumOperatingSystem // ""),
      ManagedBy:                      (.ManagedBy | tonumber),
      Sdk:                            .Sdk,
      AssumeManagementOfUserInstalledApp: .AssumeManagementOfUserInstalledApp,
      Comments:                       (.Comments // ""),
      ChangeLog:                      (.ChangeLog // ""),
      CategoryList:                   {"Category": (.CategoryList // [])},
      Assignments:                    .Assignments,
      ExcludedSmartGroupIds:          .ExcludedSmartGroupIds
    }')

  # Try the macOS-specific endpoint first (uses OG UUID + app UUID)
  local http_code
  echo -e "  [DEBUG] Trying macOS endpoint: /api/mam/groups/${og_uuid}/macos/apps/${app_uuid}" >&2
  echo -e "  [DEBUG] Payload: $(echo "$payload_macos" | jq -c .)" >&2
  http_code=$(api_put "/api/mam/groups/${og_uuid}/macos/apps/${app_uuid}" "$payload_macos")
  echo -e "  [DEBUG] macOS endpoint HTTP: ${http_code}" >&2

  # Fall back to generic internal app endpoint with different SupportedModels format
  if [[ ! "$http_code" =~ ^2 ]]; then
    echo -e "  [DEBUG] Trying generic endpoint: /api/mam/apps/internal/${app_id}" >&2
    echo -e "  [DEBUG] Payload: $(echo "$payload_generic" | jq -c .)" >&2
    http_code=$(api_put "/api/mam/apps/internal/${app_id}" "$payload_generic")
    echo -e "  [DEBUG] Generic endpoint HTTP: ${http_code}" >&2
  fi

  if [[ "$http_code" =~ ^2 ]]; then
    echo -e "${GREEN}  OK${NC}   ${app_name} (ID: ${app_id}) — model ${MODEL_ID} added (HTTP ${http_code})"
  else
    echo -e "${RED}  FAIL${NC} ${app_name} (ID: ${app_id}) — HTTP ${http_code}" >&2
    return 1
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
TOKEN=$(get_token)

if [[ "$DRY_RUN" == true ]]; then
  echo -e "${YELLOW}--- DRY RUN MODE — no changes will be made ---${NC}"
fi

echo ""
fail_count=0

if [[ -n "$BUNDLE_ID" ]]; then
  # ── Single app by bundle ID ──────────────────────────────────────────────────
  echo -e "${CYAN}Looking up app with bundle ID: ${BUNDLE_ID}${NC}"
  all_apps=$(fetch_macos_apps)
  app=$(echo "$all_apps" | jq --arg bid "$BUNDLE_ID" \
    '[.[] | select(.BundleId == $bid)] | .[0]')

  if [[ -z "$app" || "$app" == "null" ]]; then
    echo -e "${RED}Error: No macOS app found with bundle ID '${BUNDLE_ID}'${NC}" >&2
    exit 1
  fi

  app_id=$(echo "$app"     | jq -r '.Id.Value // .id')
  app_uuid=$(echo "$app"   | jq -r '.Uuid // .uuid')
  og_uuid=$(echo "$app"    | jq -r '.OrganizationGroupUuid')
  app_name=$(echo "$app"   | jq -r '.ApplicationName')
  app_status=$(echo "$app" | jq -r '.Status // "Active"')

  echo -e "Found: ${app_name} (ID: ${app_id}, Status: ${app_status})\n"
  update_app "$app_id" "$app_uuid" "$og_uuid" "$app_name" "$app_status" || ((fail_count++)) || true

else
  # ── All macOS apps ───────────────────────────────────────────────────────────
  all_apps=$(fetch_macos_apps)
  total=$(echo "$all_apps" | jq 'length')
  echo -e "Found ${total} macOS apps to process\n"

  while IFS= read -r app; do
    app_id=$(echo "$app"     | jq -r '.Id.Value // .id')
    app_uuid=$(echo "$app"   | jq -r '.Uuid // .uuid')
    og_uuid=$(echo "$app"    | jq -r '.OrganizationGroupUuid')
    app_name=$(echo "$app"   | jq -r '.ApplicationName')
    app_status=$(echo "$app" | jq -r '.Status // "Active"')

    update_app "$app_id" "$app_uuid" "$og_uuid" "$app_name" "$app_status" || ((fail_count++)) || true
  done < <(echo "$all_apps" | jq -c '.[]')
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run complete. No changes were made."
else
  echo "Done. Failures: ${fail_count}"
fi
echo "─────────────────────────────────────"

[[ $fail_count -gt 0 ]] && exit 1
exit 0
