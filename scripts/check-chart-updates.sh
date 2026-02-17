#!/usr/bin/env bash
#
# check-chart-updates.sh - Check for and optionally apply chart dependency updates
#
# Usage:
#   ./scripts/check-chart-updates.sh                              # Check only (dry-run)
#   ./scripts/check-chart-updates.sh --apply                      # Apply chart updates only
#   ./scripts/check-chart-updates.sh --apply --images --all       # Update ALL image tags
#   ./scripts/check-chart-updates.sh --apply --images --files "prod/console.yaml prod/demo.yaml"
#   ./scripts/check-chart-updates.sh --validate                   # Apply and validate
#   ./scripts/check-chart-updates.sh --help                       # Show help
#
# This script handles TWO layers of versioning:
#   1. Chart versions in charts/jetscale/Chart.yaml (Helm sub-chart versions)
#   2. Image tags in envs/*/console.yaml, envs/*/demo.yaml, etc. (container images)
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - helm CLI installed
#   - mage installed (for validation)
#
# Exit codes:
#   0 - Success (updates available or applied)
#   1 - Error (API failure, helm failure, etc.)
#   2 - No updates available

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART_DIR="$REPO_ROOT/charts/jetscale"
CHART_YAML="$CHART_DIR/Chart.yaml"
ENVS_DIR="$REPO_ROOT/envs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_detail() { echo -e "${CYAN}      ${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Check for and optionally apply chart dependency and image tag updates.

Options:
  --apply           Apply chart dependency updates (Chart.yaml + helm deps update)
  --images          Update image tags in envs/ files (requires --all or --files)
  --all             With --images: update ALL files
  --files "LIST"    With --images: update only specified files (space-separated)
                    Use relative paths like "prod/console.yaml prod/demo.yaml"
  --validate        Run mage validate:envs after applying (implies --apply)
  --json            Output status as JSON (for programmatic use)
  --help            Show this help message

Examples:
  $(basename "$0")                                    # Check for updates (dry-run)
  $(basename "$0") --json                             # Check and output JSON
  $(basename "$0") --apply                            # Apply chart updates only
  $(basename "$0") --apply --images --all             # Update all image tags
  $(basename "$0") --apply --images --files "prod/console.yaml"
  $(basename "$0") --validate --images --all          # Apply all and validate

EOF
}

# Parse arguments
APPLY=false
VALIDATE=false
UPDATE_IMAGES=false
UPDATE_ALL=false
OUTPUT_JSON=false
SELECTED_FILES=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --apply)
            APPLY=true
            shift
            ;;
        --images)
            UPDATE_IMAGES=true
            shift
            ;;
        --all)
            UPDATE_ALL=true
            shift
            ;;
        --files)
            SELECTED_FILES="$2"
            shift 2
            ;;
        --validate)
            APPLY=true
            VALIDATE=true
            shift
            ;;
        --json)
            OUTPUT_JSON=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validation
if $UPDATE_IMAGES && ! $APPLY; then
    log_error "--images requires --apply"
    exit 1
fi

if $UPDATE_IMAGES && ! $UPDATE_ALL && [[ -z "$SELECTED_FILES" ]]; then
    log_error "--images requires either --all or --files"
    exit 1
fi

if $UPDATE_ALL && [[ -n "$SELECTED_FILES" ]]; then
    log_error "Cannot use both --all and --files"
    exit 1
fi

# Verify prerequisites
check_prerequisites() {
    local missing=()

    if ! command -v gh &>/dev/null; then
        missing+=("gh")
    fi

    if ! command -v helm &>/dev/null; then
        missing+=("helm")
    fi

    if $VALIDATE && ! command -v mage &>/dev/null; then
        missing+=("mage")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    # Check gh auth
    if ! gh auth status &>/dev/null; then
        log_error "gh CLI not authenticated. Run: gh auth login"
        exit 1
    fi
}

# Get latest release version from GitHub (strips 'v' prefix)
get_latest_version() {
    local repo=$1
    local version

    version=$(gh release list -R "Jetscale-ai/$repo" --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null | sed 's/^v//')

    if [[ -z "$version" ]]; then
        log_error "Failed to get latest version for $repo"
        return 1
    fi

    echo "$version"
}

# Get current version from Chart.yaml
get_current_version() {
    local component=$1
    local version

    case $component in
        backend)
            version=$(grep -A3 'alias: backend-api' "$CHART_YAML" | grep 'version:' | head -1 | awk -F'"' '{print $2}')
            ;;
        frontend)
            version=$(grep -A2 'name: frontend' "$CHART_YAML" | grep 'version:' | awk -F'"' '{print $2}')
            ;;
        *)
            log_error "Unknown component: $component"
            return 1
            ;;
    esac

    if [[ -z "$version" ]]; then
        log_error "Failed to get current version for $component from Chart.yaml"
        return 1
    fi

    echo "$version"
}

# Update version in Chart.yaml
update_chart_version() {
    local component=$1
    local old_version=$2
    local new_version=$3

    log_info "Updating $component chart: $old_version -> $new_version"

    if [[ "$component" == "backend" ]]; then
        sed -i "s/version: \"$old_version\"/version: \"$new_version\"/g" "$CHART_YAML"
    else
        sed -i "/name: $component/,/version:/s/version: \"$old_version\"/version: \"$new_version\"/" "$CHART_YAML"
    fi
}

# Find all env files with hardcoded image tags for a component
find_env_files_with_tags() {
    local component=$1
    grep -l "repository: ghcr.io/jetscale-ai/$component" "$ENVS_DIR"/*/*.yaml 2>/dev/null || true
}

# Get image tag from an env file for a component
get_env_image_tag() {
    local file=$1
    local component=$2

    awk -v comp="$component" '
        /repository: ghcr.io\/jetscale-ai\// && $0 ~ comp {found=1; next}
        found && /tag:/ {
            gsub(/.*tag: */, "")
            gsub(/#.*/, "")
            gsub(/^"/, "")
            gsub(/".*$/, "")
            gsub(/^ *| *$/, "")
            print
            found=0
        }
    ' "$file" | head -1
}

# Update image tag in an env file
update_env_image_tag() {
    local file=$1
    local component=$2
    local old_tag=$3
    local new_tag=$4

    log_detail "  $(basename "$(dirname "$file")")/$(basename "$file"): $component $old_tag -> $new_tag"
    sed -i "/repository: ghcr.io\/jetscale-ai\/$component/,/tag:/s/tag: \"$old_tag\"/tag: \"$new_tag\"/" "$file"
}

# Build status data structure
declare -A ENV_FILE_STATUS=()

build_status() {
    local backend_latest=$1
    local frontend_latest=$2

    # Backend files
    for file in $(find_env_files_with_tags backend); do
        local tag
        tag=$(get_env_image_tag "$file" "backend")
        local rel_path
        rel_path="$(basename "$(dirname "$file")")/$(basename "$file")"
        if [[ -n "$tag" ]]; then
            ENV_FILE_STATUS["$rel_path:backend"]="$tag"
        fi
    done

    # Frontend files
    for file in $(find_env_files_with_tags frontend); do
        local tag
        tag=$(get_env_image_tag "$file" "frontend")
        local rel_path
        rel_path="$(basename "$(dirname "$file")")/$(basename "$file")"
        if [[ -n "$tag" ]]; then
            ENV_FILE_STATUS["$rel_path:frontend"]="$tag"
        fi
    done
}

# Output JSON status
output_json() {
    local backend_current=$1
    local backend_latest=$2
    local frontend_current=$3
    local frontend_latest=$4

    echo "{"
    echo "  \"chart\": {"
    echo "    \"backend\": { \"current\": \"$backend_current\", \"latest\": \"$backend_latest\", \"needs_update\": $([ "$backend_current" != "$backend_latest" ] && echo true || echo false) },"
    echo "    \"frontend\": { \"current\": \"$frontend_current\", \"latest\": \"$frontend_latest\", \"needs_update\": $([ "$frontend_current" != "$frontend_latest" ] && echo true || echo false) }"
    echo "  },"
    echo "  \"images\": ["

    local first=true
    for key in "${!ENV_FILE_STATUS[@]}"; do
        local file component tag latest needs_update
        IFS=':' read -r file component <<< "$key"
        tag="${ENV_FILE_STATUS[$key]}"

        if [[ "$component" == "backend" ]]; then
            latest=$backend_latest
        else
            latest=$frontend_latest
        fi

        needs_update=$([ "$tag" != "$latest" ] && echo true || echo false)

        if ! $first; then echo ","; fi
        first=false

        printf '    { "file": "%s", "component": "%s", "current": "%s", "latest": "%s", "needs_update": %s }' \
            "$file" "$component" "$tag" "$latest" "$needs_update"
    done

    echo ""
    echo "  ]"
    echo "}"
}

# Main logic
main() {
    if ! $OUTPUT_JSON; then
        log_info "Checking chart dependency updates..."
        echo
    fi

    check_prerequisites

    # Get versions
    if ! $OUTPUT_JSON; then
        log_info "Reading current versions from Chart.yaml..."
    fi
    BACKEND_CURRENT=$(get_current_version backend)
    FRONTEND_CURRENT=$(get_current_version frontend)

    if ! $OUTPUT_JSON; then
        log_info "Querying latest versions from GitHub releases..."
    fi
    BACKEND_LATEST=$(get_latest_version backend)
    FRONTEND_LATEST=$(get_latest_version frontend)

    # Build status
    build_status "$BACKEND_LATEST" "$FRONTEND_LATEST"

    # JSON output mode
    if $OUTPUT_JSON; then
        output_json "$BACKEND_CURRENT" "$BACKEND_LATEST" "$FRONTEND_CURRENT" "$FRONTEND_LATEST"
        exit 0
    fi

    # Display chart status
    echo
    echo "┌───────────────────────────────────────────────────────────┐"
    echo "│           Chart Dependency Status (Chart.yaml)           │"
    echo "├───────────────────────────────────────────────────────────┤"
    printf "│ %-12s │ %-14s │ %-14s │ %-8s │\n" "Component" "Current" "Latest" "Status"
    echo "├───────────────────────────────────────────────────────────┤"

    CHART_UPDATES_AVAILABLE=false

    if [[ "$BACKEND_CURRENT" == "$BACKEND_LATEST" ]]; then
        printf "│ %-12s │ %-14s │ %-14s │ ${GREEN}%-8s${NC} │\n" "backend" "$BACKEND_CURRENT" "$BACKEND_LATEST" "OK"
    else
        printf "│ %-12s │ %-14s │ %-14s │ ${YELLOW}%-8s${NC} │\n" "backend" "$BACKEND_CURRENT" "$BACKEND_LATEST" "UPDATE"
        CHART_UPDATES_AVAILABLE=true
    fi

    if [[ "$FRONTEND_CURRENT" == "$FRONTEND_LATEST" ]]; then
        printf "│ %-12s │ %-14s │ %-14s │ ${GREEN}%-8s${NC} │\n" "frontend" "$FRONTEND_CURRENT" "$FRONTEND_LATEST" "OK"
    else
        printf "│ %-12s │ %-14s │ %-14s │ ${YELLOW}%-8s${NC} │\n" "frontend" "$FRONTEND_CURRENT" "$FRONTEND_LATEST" "UPDATE"
        CHART_UPDATES_AVAILABLE=true
    fi

    echo "└───────────────────────────────────────────────────────────┘"
    echo

    # Display image status
    IMAGE_UPDATES_AVAILABLE=false

    log_info "Scanning image tags in envs/..."

    echo "┌───────────────────────────────────────────────────────────┐"
    echo "│              Image Tags Status (envs/*.yaml)             │"
    echo "├───────────────────────────────────────────────────────────┤"
    printf "│ %-30s │ %-10s │ %-8s │\n" "File" "Tag" "Status"
    echo "├───────────────────────────────────────────────────────────┤"

    for key in $(echo "${!ENV_FILE_STATUS[@]}" | tr ' ' '\n' | sort); do
        local file component tag latest
        IFS=':' read -r file component <<< "$key"
        tag="${ENV_FILE_STATUS[$key]}"

        if [[ "$component" == "backend" ]]; then
            latest=$BACKEND_LATEST
        else
            latest=$FRONTEND_LATEST
        fi

        local short_comp
        [[ "$component" == "backend" ]] && short_comp="be" || short_comp="fe"

        if [[ "$tag" == "$latest" ]]; then
            printf "│ %-30s │ %-10s │ ${GREEN}%-8s${NC} │\n" "$file ($short_comp)" "$tag" "OK"
        else
            printf "│ %-30s │ %-10s │ ${YELLOW}%-8s${NC} │\n" "$file ($short_comp)" "$tag" "UPDATE"
            IMAGE_UPDATES_AVAILABLE=true
        fi
    done

    echo "└───────────────────────────────────────────────────────────┘"
    echo

    # Check if any updates available
    if ! $CHART_UPDATES_AVAILABLE && ! $IMAGE_UPDATES_AVAILABLE; then
        log_success "All dependencies and image tags are up to date!"
        exit 2
    fi

    # Dry-run mode
    if ! $APPLY; then
        log_warn "Updates available. Run with --apply to update Chart.yaml"
        if $IMAGE_UPDATES_AVAILABLE; then
            log_warn "Add --images --all to update all image tags"
            log_warn "Or --images --files \"prod/console.yaml\" to update specific files"
        fi
        echo
        echo "Suggested commit message:"
        echo "  fix(deps): bump backend to $BACKEND_LATEST and frontend to $FRONTEND_LATEST"
        exit 0
    fi

    # Apply chart updates
    if $CHART_UPDATES_AVAILABLE; then
        log_info "Applying updates to Chart.yaml..."

        if [[ "$BACKEND_CURRENT" != "$BACKEND_LATEST" ]]; then
            update_chart_version backend "$BACKEND_CURRENT" "$BACKEND_LATEST"
        fi

        if [[ "$FRONTEND_CURRENT" != "$FRONTEND_LATEST" ]]; then
            update_chart_version frontend "$FRONTEND_CURRENT" "$FRONTEND_LATEST"
        fi

        log_info "Regenerating Chart.lock (helm dependency update)..."
        cd "$CHART_DIR"
        if ! helm dependency update; then
            log_error "helm dependency update failed!"
            log_error "The version may not exist in the OCI registry yet."
            exit 1
        fi
        cd "$REPO_ROOT"

        log_success "Chart.yaml and Chart.lock updated successfully!"
    fi

    # Apply image tag updates
    if $UPDATE_IMAGES && $IMAGE_UPDATES_AVAILABLE; then
        echo
        log_info "Updating image tags..."

        # Determine which files to update
        local files_to_update=()

        if $UPDATE_ALL; then
            # All files with outdated tags
            for key in "${!ENV_FILE_STATUS[@]}"; do
                local file component tag latest
                IFS=':' read -r file component <<< "$key"
                tag="${ENV_FILE_STATUS[$key]}"
                [[ "$component" == "backend" ]] && latest=$BACKEND_LATEST || latest=$FRONTEND_LATEST

                if [[ "$tag" != "$latest" ]]; then
                    files_to_update+=("$file")
                fi
            done
        else
            # Only specified files
            for file in $SELECTED_FILES; do
                files_to_update+=("$file")
            done
        fi

        # Remove duplicates
        local unique_files=()
        mapfile -t unique_files < <(printf '%s\n' "${files_to_update[@]}" | sort -u)

        # Update each file
        for file in "${unique_files[@]}"; do
            local full_path="$ENVS_DIR/$file"

            if [[ ! -f "$full_path" ]]; then
                log_warn "File not found: $file (skipping)"
                continue
            fi

            # Update backend tag if present and outdated
            local be_tag
            be_tag=$(get_env_image_tag "$full_path" "backend")
            if [[ -n "$be_tag" && "$be_tag" != "$BACKEND_LATEST" ]]; then
                update_env_image_tag "$full_path" "backend" "$be_tag" "$BACKEND_LATEST"
            fi

            # Update frontend tag if present and outdated
            local fe_tag
            fe_tag=$(get_env_image_tag "$full_path" "frontend")
            if [[ -n "$fe_tag" && "$fe_tag" != "$FRONTEND_LATEST" ]]; then
                update_env_image_tag "$full_path" "frontend" "$fe_tag" "$FRONTEND_LATEST"
            fi
        done

        log_success "Image tags updated!"
    elif $IMAGE_UPDATES_AVAILABLE && ! $UPDATE_IMAGES; then
        log_warn "Image tags not updated (use --images to include)"
    fi

    # Validate
    if $VALIDATE; then
        echo
        log_info "Running validation (mage validate:envs aws)..."
        if ! mage validate:envs aws; then
            log_error "Validation failed!"
            exit 1
        fi
        log_success "Validation passed!"
    fi

    echo
    log_success "Updates applied successfully!"
    echo
    echo "Files modified:"
    if $CHART_UPDATES_AVAILABLE; then
        echo "  - charts/jetscale/Chart.yaml"
        echo "  - charts/jetscale/Chart.lock"
    fi
    if $UPDATE_IMAGES; then
        for file in "${unique_files[@]}"; do
            echo "  - envs/$file"
        done
    fi
    echo
    echo "Suggested commit message:"
    echo "  fix(deps): bump backend to $BACKEND_LATEST and frontend to $FRONTEND_LATEST"
    echo
}

main "$@"
