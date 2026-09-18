#!/bin/bash

# =============================================================================
# OpenCode Model Updater
# Updates opencode.json with available models from OpenAI-compatible API backends
#
# Merge behavior (user customizations are preserved):
#   - Models still present on the server keep their existing config entry as-is
#     (custom limits, reasoningEffort, etc. are not overwritten)
#   - Models new to the server are added with the default MODEL_CONFIG
#   - Models no longer returned by the server are removed from the config
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration Variables - Modify these values as needed
# -----------------------------------------------------------------------------

CONFIG_FILE="$HOME/.config/opencode/opencode.json"
AUTH_FILE="$HOME/.local/share/opencode/auth.json"

TEMP_FILE="/tmp/opencode_updated_$$.json"
BACKUP_FILE="/tmp/opencode_backup_$(date +%Y%m%d_%H%M%S).json"

MODEL_CONFIG='{"tools":true,"skill":true,"task":true,"lsp":true,"codesearch":true,"websearch":true,"webfetch":true,"limit":{"context":262144,"output":128000}}'

# Mode flags (populated by parse_args)
DIRECT_MODE=false
DRY_RUN=false

USAGE="Usage: $(basename "$0") [--direct] [--dry-run] [--help]

Updates opencode.json with models fetched from each provider's baseURL.

Modes:
  (default)  Strip the provider prefix from each model id (everything before
             and including the first '/', e.g. boiler50/Model -> Model) and
             deduplicate model names per provider (within each provider's own
             model list). Use this when each provider is an independent backend
             that may return prefixed model ids.
   --direct   Previous behavior: fetch raw model ids as returned by the server,
              no stripping, no deduplication.

Behavior:
   Model entries that already exist in opencode.json are kept as-is, so user
   customizations (reasoningEffort, context/output limits, etc.) are never
   overwritten. Only models new to the provider get the default config, and
   models that no longer exist on the provider are removed.

Options:
  --dry-run  Compute and print what would change, but do not write to the
             config file (no backup is created either).
  --help     Show this help and exit.
"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log_info() {
    echo "[INFO] $1"
}

log_ok() {
    echo "[OK] $1"
}

log_warn() {
    echo "[WARN] $1"
}

check_dependencies() {
    if ! command -v curl &> /dev/null; then
        log_warn "curl is required but not installed"
        return 1
    fi

    if ! command -v jq &> /dev/null; then
        log_warn "jq is required but not installed"
        return 1
    fi

    return 0
}

# Parse command-line arguments into the global mode flags.
# Exits the script on --help or an unknown flag.
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --direct)
                DIRECT_MODE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                echo "$USAGE"
                exit 0
                ;;
            *)
                echo "[ERROR] Unknown option: $1" >&2
                echo "$USAGE" >&2
                exit 2
                ;;
        esac
    done
}

# Get list of providers from opencode.json
get_providers_from_config() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        echo ""
        return
    fi

    # Check if provider key exists and is not empty
    local providers
    providers=$(jq -r '.provider // {} | keys[]' "$config_file" 2>/dev/null) || true

    echo "$providers"
}

# Get API key for a provider from auth.json
get_api_key() {
    local provider="$1"
    local auth_file="$2"

    if [ ! -f "$auth_file" ]; then
        echo ""
        return
    fi

    # Try to get key for this provider (may be nested under "type"/"key" or at root)
    local key
    key=$(jq -r ".$provider.key // \"\" " "$auth_file" 2>/dev/null) || true

    if [ -z "$key" ]; then
        # Try direct lookup at root level (some keys are stored as .<name>)
        key=$(jq -r "if has(\"$provider\") then .\"$provider\".key // \"\" else \"\" end" "$auth_file" 2>/dev/null) || true
    fi

    echo "$key"
}

# Extract host:port from baseURL
# Input: http://192.0.2.10:8888/v1 -> Output: 192.0.2.10:8888
extract_host_port() {
    local url="$1"

    # Remove protocol (http:// or https://)
    local without_protocol
    without_protocol=$(echo "$url" | sed -E 's|^https?://||')

    # Remove /v1 or /v1/ suffix and anything after
    local host_port
    host_port=$(echo "$without_protocol" | sed -E 's|/v1/*$||' | cut -d'/' -f1)

    echo "$host_port"
}

# Get baseURL for a provider from opencode.json
get_baseurl() {
    local config_file="$1"
    local provider="$2"

    jq -r ".provider.\"$provider\".options.baseURL // \"\" " "$config_file" 2>/dev/null || echo ""
}

# Get existing models for a provider from config
get_existing_models() {
    local config_file="$1"
    local provider="$2"

    jq -r ".provider.\"$provider\".models | keys[] // \"\" " "$config_file" 2>/dev/null || true
}

# Remove the provider prefix from a model id by stripping everything before
# and including the first '/'. Models without a '/' are returned unchanged.
strip_prefix() {
    local model="$1"

    case "$model" in
        */*)
            echo "${model#*/}"
            ;;
        *)
            echo "$model"
            ;;
    esac
}

# Normalize a newline-separated list of model ids by stripping the prefix from
# each entry. Used so the diff against existing config entries is fair even if
# the config still contains prefixed names from a previous (pre-migration) run.
normalize_model_list() {
    local models="$1"
    local out=""
    local base

    while IFS= read -r model; do
        [ -z "$model" ] && continue
        base=$(strip_prefix "$model")
        out="${out:+$out$'\n'}$base"
    done <<< "$models"

    echo "$out"
}

# Fetch models from an OpenAI-compatible API endpoint
fetch_models_from_server() {
    local host_port="$1"
    local api_key="$2"

    if [ -z "$api_key" ]; then
        return 1
    fi

    local response
    local http_code

    http_code=$(curl -s --max-time 10 -o /tmp/models_fetch_$$.json -w "%{http_code}" \
        "http://${host_port}/v1/models" \
        -H "accept: application/json" \
        -H "Authorization: Bearer $api_key") || true

    if [ "$http_code" != "200" ] || [ ! -s /tmp/models_fetch_$$.json ]; then
        rm -f /tmp/models_fetch_$$.json
        return 1
    fi

    # Extract model IDs from response
    jq -r '.data[].id' /tmp/models_fetch_$$.json 2>/dev/null || true
    rm -f /tmp/models_fetch_$$.json
}

# Get existing models for a provider from config as a JSON object.
# Prints "{}" when the provider or its models map is absent.
get_existing_models_json() {
    local config_file="$1"
    local provider="$2"

    local result
    result=$(jq -c ".provider.\"$provider\".models // {}" "$config_file" 2>/dev/null) || true

    if [ -z "$result" ]; then
        echo "{}"
    else
        echo "$result"
    fi
}

# Merge the fetched model list into the provider's existing models object so
# user customizations are preserved:
#   - models still present on the server keep their existing entry as-is
#   - models new to the server are added with the default model config
#   - models no longer returned by the server are removed
# When strip is "true" (default mode), a provider prefix ("prefix/Name") on
# existing keys is stripped so such entries migrate to the bare name while
# keeping their customizations.
merge_models_json() {
    local existing_json="$1"
    local models="$2"
    local model_config="$3"
    local strip="$4"

    local allowed_json
    allowed_json=$(printf '%s\n' "$models" | jq -R 'select(length > 0)' | jq -s .)

    jq -c --argjson allowed "$allowed_json" --argjson default "$model_config" --argjson strip "$strip" '
        (if type == "object" then . else {} end) as $base
        | (if $strip
           then $base | with_entries({key: (.key | if contains("/") then .[index("/") + 1:] else . end), value: .value})
           else $base
           end) as $normalized
        | ($normalized | with_entries(select(.key as $k | ($allowed | index($k)) != null))) as $kept
        | reduce $allowed[] as $m ($kept; if has($m) then . else . + {($m): $default} end)
    ' <<< "$existing_json"
}

# Update a specific provider in the config file
update_provider_models() {
    local config_file="$1"
    local temp_file="$2"
    local provider="$3"
    local models_json="$4"

    jq --arg p "$provider" --argjson m "$models_json" \
       '.provider[$p] = (.provider[$p] | .models = $m)' \
       "$config_file" > "$temp_file"
}

# -----------------------------------------------------------------------------
# Main Script Logic
# -----------------------------------------------------------------------------

# Parse arguments first so --help works regardless of the environment.
parse_args "$@"

set -e

# Temp file holding the globally-seen set of base model names (default mode
# only). Uses a file rather than an associative array to stay bash-3.2
# compatible (macOS ships bash 3.2 as /bin/bash).
SEEN_FILE=$(mktemp)
trap 'rm -f "$SEEN_FILE"' EXIT

echo "=========================================="
echo "OpenCode Model Updater"
if [ "$DIRECT_MODE" = true ]; then
    echo "Mode: direct (raw model ids, no strip / no dedup)"
else
    echo "Mode: default (strip prefix, per-provider dedup)"
fi
if [ "$DRY_RUN" = true ]; then
    echo "Dry-run: ON (no files will be written)"
fi
echo "=========================================="

# Check dependencies
if ! check_dependencies; then
    echo "[ERROR] Missing required dependencies (curl, jq)"
    exit 1
fi

# Step 1: Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Config file not found: $CONFIG_FILE"
    exit 1
fi

log_info "Reading providers from config..."

# Step 2: Get list of providers to update (only from opencode.json)
PROVIDERS=$(get_providers_from_config "$CONFIG_FILE")

if [ -z "$PROVIDERS" ]; then
    echo "[ERROR] No providers found in config file"
    exit 1
fi

PROVIDER_COUNT=$(echo "$PROVIDERS" | wc -l)
log_info "Found $PROVIDER_COUNT provider(s) in config: $(echo "$PROVIDERS" | tr '\n' ', ' | sed 's/,$//')"

# Step 3: Create backup (skip in dry-run)
if [ "$DRY_RUN" = true ]; then
    log_info "Dry-run mode: skipping backup creation"
else
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    log_info "Backup created: $BACKUP_FILE"
fi

# Working copy for incremental updates
WORKING_CONFIG="$CONFIG_FILE"

echo ""

# Step 4: Process each provider
while IFS= read -r provider; do
    [ -z "$provider" ] && continue

    # Get baseURL from config
    BASE_URL=$(get_baseurl "$CONFIG_FILE" "$provider")

    if [ -z "$BASE_URL" ]; then
        log_warn "No baseURL for $provider - skipped"
        continue
    fi

    # Extract host:port from URL
    HOST_PORT=$(extract_host_port "$BASE_URL")

    # Get API key from auth file
    API_KEY=$(get_api_key "$provider" "$AUTH_FILE")

    if [ -z "$API_KEY" ]; then
        log_warn "No API key for $provider - skipped"
        continue
    fi

    # Fetch models from server
    RAW_MODELS=$(fetch_models_from_server "$HOST_PORT" "$API_KEY") || true

    if [ -z "$RAW_MODELS" ]; then
        log_warn "Failed to fetch models from $provider ($HOST_PORT) - skipped"
        continue
    fi

    # Process fetched models according to the active mode.
    PROCESSED_MODELS=""
    if [ "$DIRECT_MODE" = true ]; then
        # Direct mode: use raw ids verbatim (previous behavior).
        PROCESSED_MODELS="$RAW_MODELS"
    else
        # Default mode: strip prefix and deduplicate per provider (each
        # provider is an independent backend, so no cross-provider dedup).
        # Reset the seen-file so dedup is scoped to this provider only.
        : > "$SEEN_FILE"
        DEDUPED=""
        while IFS= read -r model; do
            [ -z "$model" ] && continue
            base=$(strip_prefix "$model")

            # Skip duplicates within this provider's own model list.
            if grep -qxF "$base" "$SEEN_FILE" 2>/dev/null; then
                continue
            fi

            printf '%s\n' "$base" >> "$SEEN_FILE"
            DEDUPED="${DEDUPED:+$DEDUPED$'\n'}$base"
        done <<< "$RAW_MODELS"
        PROCESSED_MODELS="$DEDUPED"
    fi

    if [ -z "$PROCESSED_MODELS" ]; then
        log_warn "No new models to add for $provider ($HOST_PORT) - skipped"
        continue
    fi

    # Get existing models before update for comparison (read from original config)
    EXISTING_MODELS=$(get_existing_models "$CONFIG_FILE" "$provider")

    # In default mode, normalize existing entries too so the diff is fair even
    # if the config still holds prefixed names from a previous run.
    if [ "$DIRECT_MODE" = false ]; then
        EXISTING_MODELS=$(normalize_model_list "$EXISTING_MODELS")
    fi

    # Calculate added and removed models
    NEW_COUNT=0
    ADDED_COUNT=0
    ADDED=""
    REMOVED=""

    while IFS= read -r model; do
        [ -z "$model" ] && continue

        # Check if this new model exists in the original config
        if echo "$EXISTING_MODELS" | grep -qxF "$model"; then
            :  # Model still exists, no change
        else
            ADDED="${ADDED:+$ADDED, }$model"
            ADDED_COUNT=$((ADDED_COUNT + 1))
        fi
        NEW_COUNT=$((NEW_COUNT + 1))
    done <<< "$PROCESSED_MODELS"

    # Check for removed models (exist in original but not in new)
    while IFS= read -r model; do
        [ -z "$model" ] && continue

        if echo "$PROCESSED_MODELS" | grep -qxF "$model"; then
            :  # Model still exists
        else
            REMOVED="${REMOVED:+$REMOVED, }$model"
        fi
    done <<< "$EXISTING_MODELS"

    # Build the log message
    LOG_MSG="Updated $provider ($HOST_PORT): $NEW_COUNT models ($((NEW_COUNT - ADDED_COUNT)) kept as-is)"
    if [ -n "$ADDED" ]; then
        LOG_MSG="$LOG_MSG (+ added: $ADDED)"
    fi
    if [ -n "$REMOVED" ]; then
        LOG_MSG="$LOG_MSG (- removed: $REMOVED)"
    fi

    # Build the new models object by merging the fetched list with the existing
    # one: entries for models still on the server are preserved untouched (user
    # customizations survive), new models get the default config, and models
    # deleted on the provider side are dropped.
    EXISTING_MODELS_JSON=$(get_existing_models_json "$CONFIG_FILE" "$provider")
    if [ "$DIRECT_MODE" = true ]; then
        MODELS_JSON=$(merge_models_json "$EXISTING_MODELS_JSON" "$PROCESSED_MODELS" "$MODEL_CONFIG" false)
    else
        MODELS_JSON=$(merge_models_json "$EXISTING_MODELS_JSON" "$PROCESSED_MODELS" "$MODEL_CONFIG" true)
    fi

    # Dry-run: report only, do not touch the config.
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] $LOG_MSG"
        continue
    fi

    # Update config file (work on a copy to preserve other providers)
    TEMP_UPDATE="/tmp/opencode_provider_$$.json"
    if update_provider_models "$WORKING_CONFIG" "$TEMP_UPDATE" "$provider" "$MODELS_JSON"; then
        mv "$TEMP_UPDATE" "$WORKING_CONFIG"
        log_ok "$LOG_MSG"
    else
        rm -f "$TEMP_UPDATE"
        log_warn "Failed to update $provider"
    fi

done <<< "$PROVIDERS"

# Step 5: Move working config back to original location (if different)
if [ "$DRY_RUN" = false ] && [ "$WORKING_CONFIG" != "$CONFIG_FILE" ]; then
    mv "$WORKING_CONFIG" "$CONFIG_FILE"
fi

echo ""
echo "=========================================="
echo "Update Complete!"
echo "=========================================="
if [ "$DRY_RUN" = false ]; then
    echo "Backup saved to: $BACKUP_FILE"
else
    echo "Dry-run: no changes were written"
fi
