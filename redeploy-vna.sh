#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Global cleanup tracking
TEMP_FILES=()
CLEANUP_NEEDED=false

# Cleanup function for script exit
cleanup_on_exit() {
    local exit_code=$?
    
    if [[ "$CLEANUP_NEEDED" == "true" ]]; then
        echo
        log_step "Cleaning up temporary resources"
        
        # Initialize TEMP_FILES if not already defined (safety)
        if [[ -z "${TEMP_FILES+set}" ]]; then
            TEMP_FILES=()
        fi

        # Clean up temporary files (safe with set -u if TEMP_FILES unset)
        for temp_file in "${TEMP_FILES[@]:-}"; do
            if [[ -f "$temp_file" ]]; then
                log_debug "Removing temporary file: $temp_file"
                rm -f "$temp_file"
            fi
        done
        
        # Clean up any stray temporary manifest files in /tmp
        find /tmp -name "db-inspector-*.yaml" -mtime +1 -delete 2>/dev/null || true
        
        log_debug "Cleanup complete"
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script exited with error code: $exit_code"
    fi
    
    exit $exit_code
}

# Set trap for cleanup
trap cleanup_on_exit EXIT INT TERM

# These will be set in main() after help check
SOURCE_NAMESPACE=""
TARGET_NAMESPACE=""
TARGET_BRANCH=""
DRY_RUN=false
VERBOSE=false
QUICK_MODE=false
RESET_MODE=false
GITHUB_SECRET_KEY=""

# Config file support
CONFIG_FILE=""
USE_CONFIG=false
CONFIG_DB_MODE=""
CONFIG_DB_DEFAULT_HOST=""
CONFIG_DB_VOLATILE_HOST=""
CONFIG_TARGET_BRANCH=""
CONFIG_DICOM_SIZE=""
CONFIG_LOG_SIZE=""

SOURCE_GITHUB_OWNER="radpartners"
SOURCE_GITHUB_REPO="rp-vna-deployments-dev"
SOURCE_GITHUB_BRANCH=""
TARGET_GITHUB_OWNER="achandra-rp"
TARGET_GITHUB_REPO="cluster-config"
TARGET_GITHUB_BRANCH=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Get timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Professional logging functions
log_info() {
    echo -e "${GRAY}$(get_timestamp)${NC} ${BLUE}INFO${NC}  $1"
}

log_success() {
    echo -e "${GRAY}$(get_timestamp)${NC} ${GREEN}✓${NC}     $1"
}

log_error() {
    echo -e "${GRAY}$(get_timestamp)${NC} ${RED}ERROR${NC} $1" >&2
}

log_warning() {
    echo -e "${GRAY}$(get_timestamp)${NC} ${YELLOW}WARN${NC}  $1"
}

log_step() {
    echo
    echo -e "${GRAY}$(get_timestamp)${NC} ${BOLD}====${NC} ${BOLD}$1${NC} ${BOLD}====${NC}"
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${GRAY}$(get_timestamp) DEBUG${NC} $1"
    fi
}

log_task() {
    echo -e "${GRAY}$(get_timestamp)${NC} ${CYAN}→${NC}     $1"
}

# Alias for backward compatibility
log_verbose() {
    log_debug "$1"
}

# Input validation functions
validate_namespace() {
    local namespace="$1"
    if [[ ! "$namespace" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        log_error "Invalid namespace format: $namespace"
        log_info "Namespace must contain only lowercase letters, numbers, and hyphens"
        return 1
    fi
    return 0
}

validate_branch_name() {
    local branch="$1"
    if [[ ! "$branch" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        log_error "Invalid branch name format: $branch"
        log_info "Branch name contains invalid characters"
        return 1
    fi
    return 0
}

confirm_action() {
    # Skip confirmation in quick mode
    if [[ "$QUICK_MODE" == "true" ]]; then
        log_debug "Quick mode: Skipping confirmation"
        return 0
    fi
    
    # Use printf to avoid terminal escape artifacts
    printf "%b%s%b %bPROMPT%b Continue? [Y/n]: " "$GRAY" "$(get_timestamp)" "$NC" "$YELLOW" "$NC"
    read -r response
    # Default to yes if empty response (just pressing enter)
    if [[ -z "$response" ]] || [[ "$response" =~ ^[Yy]$ ]]; then
        log_success "Continuing with deployment..."
        return 0
    elif [[ "$response" =~ ^[Nn]$ ]]; then
        log_warning "Deployment aborted by user"
        exit 1
    else
        log_error "Invalid response. Please enter y/yes or n/no."
        confirm_action
    fi
}

load_namespace_config() {
    local namespace="$1"
    
    if [[ "$USE_CONFIG" == "true" && -f "$CONFIG_FILE" ]]; then
        log_task "Loading configuration for namespace: $namespace"
        
        # Parse config using yq with fallback to defaults
        CONFIG_DB_MODE=$(yq eval ".namespace_configs.$namespace.database.mode // .defaults.database.mode // \"remote\"" "$CONFIG_FILE" 2>/dev/null || echo "remote")
        CONFIG_DB_DEFAULT_HOST=$(yq eval ".namespace_configs.$namespace.database.default_host // .defaults.database.default_host // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
        CONFIG_DB_VOLATILE_HOST=$(yq eval ".namespace_configs.$namespace.database.volatile_host // .defaults.database.volatile_host // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
        CONFIG_TARGET_BRANCH=$(yq eval ".namespace_configs.$namespace.github.config_branch // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
        CONFIG_DICOM_SIZE=$(yq eval ".namespace_configs.$namespace.storage.dicom_size // .defaults.storage.dicom_size // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
        CONFIG_LOG_SIZE=$(yq eval ".namespace_configs.$namespace.storage.log_size // .defaults.storage.log_size // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
        
        # Override TARGET_BRANCH if specified in config and not provided via CLI
        if [[ -n "$CONFIG_TARGET_BRANCH" && "$TARGET_BRANCH" == "$TARGET_NAMESPACE" ]]; then
            TARGET_BRANCH="$CONFIG_TARGET_BRANCH"
            log_success "Using config branch: $TARGET_BRANCH"
        fi
        
        # Log configuration being used
        log_debug "Database mode: $CONFIG_DB_MODE"
        if [[ -n "$CONFIG_DB_DEFAULT_HOST" ]]; then
            log_debug "Database hosts: $CONFIG_DB_DEFAULT_HOST, $CONFIG_DB_VOLATILE_HOST"
        fi
        if [[ -n "$CONFIG_DICOM_SIZE" ]]; then
            log_debug "Storage sizes - DICOM: $CONFIG_DICOM_SIZE, Log: $CONFIG_LOG_SIZE"
        fi
    fi
}

cleanup_local_files() {
    log_step "Cleaning up local files"
    
    # Remove any existing CR files for this namespace
    local cr_file="$SCRIPT_DIR/$TARGET_NAMESPACE-vna.yaml"
    if [[ -f "$cr_file" ]]; then
        log_task "Removing existing CR file: $cr_file"
        rm -f "$cr_file"
    fi
    
    log_debug "Repository directories will be reused and updated if they exist"
    log_debug "  - $SCRIPT_DIR/rpvna-source-config"
    log_debug "  - $SCRIPT_DIR/ac001001-target-config"
    
    log_success "Local cleanup complete"
}

cleanup_target_namespace() {
    # Only run if in reset mode or DRY_RUN is false
    if [[ "$RESET_MODE" != "true" ]] && [[ "$DRY_RUN" == "true" ]]; then
        log_debug "Skipping target namespace cleanup (not in reset mode and dry run)"
        return 0
    fi
    
    log_step "Cleaning up target namespace: $TARGET_NAMESPACE"
    
    # Delete existing VNA CR if it exists
    if kubectl get vna vna-cr -n "$TARGET_NAMESPACE" >/dev/null 2>&1; then
        log_task "Deleting existing VNA CR in namespace $TARGET_NAMESPACE"
        log_debug "kubectl delete vna vna-cr -n $TARGET_NAMESPACE"
        
        if kubectl delete vna vna-cr -n "$TARGET_NAMESPACE"; then
            log_success "VNA CR deletion initiated"
        else
            log_error "Failed to delete existing VNA CR"
            return 1
        fi
        
        # Wait for deletion to complete
        log_task "Waiting for VNA CR deletion to complete (60s timeout)"
        if kubectl wait --for=delete vna/vna-cr -n "$TARGET_NAMESPACE" --timeout=60s; then
            log_success "VNA CR deletion completed"
        else
            log_warning "VNA CR deletion did not complete within timeout"
            log_warning "Continuing anyway - operator should handle remaining resources"
        fi
    else
        log_info "No existing VNA CR found in namespace $TARGET_NAMESPACE"
    fi
    
    log_success "Target namespace cleanup complete"
}

check_target_namespace_requirements() {
    log_step "Checking target namespace requirements"
    
    # Check if github-secret exists and detect the secret key
    if kubectl get secret github-secret -n "$TARGET_NAMESPACE" >/dev/null 2>&1; then
        log_success "github-secret exists in namespace $TARGET_NAMESPACE"
        
        # Check what keys are available in the secret
        local available_keys
        available_keys=$(kubectl get secret github-secret -n "$TARGET_NAMESPACE" -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null || echo "")
        
        if [[ -z "$available_keys" ]]; then
            log_warning "Could not read github-secret keys. Assuming 'token'"
            GITHUB_SECRET_KEY="token"
        elif echo "$available_keys" | grep -q "^token$"; then
            log_success "Using secretKey: token"
            GITHUB_SECRET_KEY="token"
        elif echo "$available_keys" | grep -q "^github-token$"; then
            log_success "Using secretKey: github-token"
            GITHUB_SECRET_KEY="github-token"
        else
            log_debug "Available keys in github-secret: $available_keys"
            log_warning "Neither 'token' nor 'github-token' found. Using 'token' as default"
            GITHUB_SECRET_KEY="token"
        fi
    else
        log_error "github-secret not found in namespace $TARGET_NAMESPACE"
        log_error "Please ensure the github-secret exists with either 'token' or 'github-token' key"
        log_info "Example:"
        log_info "  kubectl create secret generic github-secret --from-literal=token=<your-token> -n $TARGET_NAMESPACE"
        exit 1
    fi
    
    log_success "Target namespace requirements check complete"
}

create_vna_cr() {
    log_step "Creating VNA CR for $TARGET_NAMESPACE"
    
    local output_file="$TARGET_NAMESPACE-vna.yaml"
    local source_cr_file="$SCRIPT_DIR/rpvna-dev.yaml"
    
    # Check if source CR file exists, if not pull it from source namespace
    if [[ ! -f "$source_cr_file" ]]; then
        log_task "Pulling source CR from namespace: $SOURCE_NAMESPACE"
        
        # Check if kubectl neat is available
        if command -v kubectl-neat >/dev/null 2>&1; then
            kubectl get vnas.radpartners.com -n "$SOURCE_NAMESPACE" -o yaml | kubectl neat > "$source_cr_file"
        elif kubectl neat --help >/dev/null 2>&1; then
            kubectl get vnas.radpartners.com -n "$SOURCE_NAMESPACE" -o yaml | kubectl neat > "$source_cr_file"
        else
            log_warning "kubectl neat not available. Using raw kubectl output (may contain extra metadata)"
            kubectl get vnas.radpartners.com -n "$SOURCE_NAMESPACE" -o yaml > "$source_cr_file"
        fi
        
        if [[ ! -f "$source_cr_file" ]]; then
            log_error "Failed to pull VNA CR from source namespace $SOURCE_NAMESPACE"
            log_error "Make sure the VNA CR exists in the source namespace and you have access"
            exit 1
        fi
        
        log_success "Source CR pulled from namespace: $SOURCE_NAMESPACE"
    else
        log_info "Using existing source CR file: $source_cr_file"
    fi
    
    # Create the new CR with comprehensive namespace and GitHub config updates
    sed "s/namespace: $SOURCE_NAMESPACE/namespace: $TARGET_NAMESPACE/g" "$source_cr_file" | \
    sed "s/branch: $SOURCE_GITHUB_BRANCH/branch: $TARGET_GITHUB_BRANCH/g" | \
    sed "s/owner: $SOURCE_GITHUB_OWNER/owner: $TARGET_GITHUB_OWNER/g" | \
    sed "s/repository: $SOURCE_GITHUB_REPO/repository: $TARGET_GITHUB_REPO/g" | \
    sed "s/secretKey: token/secretKey: $GITHUB_SECRET_KEY/g" | \
    sed "s/secretKey: github-token/secretKey: $GITHUB_SECRET_KEY/g" > "$output_file"
    
    # Handle local vs remote database mode
    if [[ "$CONFIG_DB_MODE" == "local" ]]; then
        sed -i 's/postgresDB: remote/postgresDB: local/g' "$output_file"
        sed -i 's/postgresDB: none/postgresDB: local/g' "$output_file"
        log_success "Configured for local PostgreSQL deployment"
    fi
    
    # Apply storage size overrides if configured
    if [[ -n "$CONFIG_DICOM_SIZE" ]]; then
        sed -i "s/storage: [0-9]*G/storage: $CONFIG_DICOM_SIZE/g" "$output_file"
        log_success "Applied DICOM storage size: $CONFIG_DICOM_SIZE"
    fi
    
    log_success "VNA CR created: $output_file"
    log_debug "Using secretKey: $GITHUB_SECRET_KEY"
    if [[ "$CONFIG_DB_MODE" == "local" ]]; then
        log_info "Database mode: ${BOLD}LOCAL${NC}"
    else
        log_info "Database mode: ${BOLD}REMOTE${NC}"
    fi
}

sync_github_configs() {
    log_step "Syncing GitHub configurations"
    
    local source_dir="$SCRIPT_DIR/rpvna-source-config"
    local target_dir="$SCRIPT_DIR/ac001001-target-config"
    
    log_info "Repository directories:"
    log_info "  Source: $source_dir"
    log_info "  Target: $target_dir"
    
    # Clone or update source repository (READ-ONLY)
    log_info "Setting up source repository (READ-ONLY)"
    local source_ssh_url="git@github.com:$SOURCE_GITHUB_OWNER/$SOURCE_GITHUB_REPO.git"
    
    if [[ -d "$source_dir" ]]; then
        log_info "Source repository exists - updating to latest"
        cd "$source_dir"
        # Ensure we're in a clean state and never modify source
        log_verbose "git reset --hard HEAD && git clean -fd"
        git reset --hard HEAD >/dev/null 2>&1
        git clean -fd >/dev/null 2>&1
        
        log_verbose "git fetch origin"
        if git fetch origin >/dev/null 2>&1; then
            log_success "Fetched latest changes from origin"
        else
            log_warning "Failed to fetch from origin - continuing with cached version"
        fi
        
        log_verbose "git checkout $SOURCE_GITHUB_BRANCH"
        git checkout "$SOURCE_GITHUB_BRANCH" >/dev/null 2>&1 || git checkout -b "$SOURCE_GITHUB_BRANCH" origin/"$SOURCE_GITHUB_BRANCH" >/dev/null 2>&1
        git reset --hard origin/"$SOURCE_GITHUB_BRANCH" >/dev/null 2>&1
        log_success "Source repository updated from origin/$SOURCE_GITHUB_BRANCH"
    else
        log_verbose "Cloning source repository with shallow clone for faster performance"
        if ! git clone --depth=1 -b "$SOURCE_GITHUB_BRANCH" "$source_ssh_url" "$source_dir" 2>/dev/null; then
            log_error "Could not clone source repository"
            log_info "Repository: $source_ssh_url@$SOURCE_GITHUB_BRANCH"
            log_info "Check SSH access permissions and branch name"
            return 1
        fi
        log_success "Source repository cloned"
    fi
    
    # Verify source repository is read-only by checking we're not accidentally in it
    cd "$SCRIPT_DIR"
    
    # Clone or update target repository
    log_info "Setting up target repository"
    local target_ssh_url="git@github.com:$TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO.git"
    
    if [[ -d "$target_dir" ]]; then
        log_info "Target directory exists - updating"
        cd "$target_dir"
        git fetch origin
        # Check if target branch exists, create if not
        if git show-ref --verify --quiet "refs/remotes/origin/$TARGET_GITHUB_BRANCH"; then
            log_task "Switching to existing branch: $TARGET_GITHUB_BRANCH"
            git checkout "$TARGET_GITHUB_BRANCH"
            # Don't pull here - we want to completely reset anyway
        else
            log_task "Creating new branch: $TARGET_GITHUB_BRANCH"
            git checkout -b "$TARGET_GITHUB_BRANCH"
        fi
    else
        log_verbose "Cloning target repository"
        if ! git clone --depth=1 "$target_ssh_url" "$target_dir" 2>/dev/null; then
            log_error "Could not clone target repository"
            log_info "Repository: $target_ssh_url"
            log_info "Check SSH access permissions"
            return 1
        fi
        log_success "Target repository cloned"
        cd "$target_dir"
        # Check if target branch exists, create if not
        if git show-ref --verify --quiet "refs/remotes/origin/$TARGET_GITHUB_BRANCH"; then
            log_task "Switching to existing branch: $TARGET_GITHUB_BRANCH"
            git checkout "$TARGET_GITHUB_BRANCH"
        else
            log_task "Creating new branch: $TARGET_GITHUB_BRANCH"
            git checkout -b "$TARGET_GITHUB_BRANCH"
        fi
    fi
    
    # COMPLETE RESET: Remove ALL files except .git to ensure clean state
    log_task "Completely resetting target directory (removing all existing content)"
    find . -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +
    log_success "Target directory completely cleared"
    
    # Copy ALL files from source to target (complete mirror)
    log_task "Copying ALL files from source to target"
    
    # Copy all visible files and directories
    if ls "$source_dir"/* >/dev/null 2>&1; then
        cp -r "$source_dir"/* ./ 2>/dev/null || {
            log_warning "Some files failed to copy with cp"
        }
    fi
    
    # Copy hidden files (but not .git)
    if ls "$source_dir"/.[^.]* >/dev/null 2>&1; then
        for item in "$source_dir"/.[^.]*; do
            if [[ "$(basename "$item")" != ".git" ]]; then
                cp -r "$item" ./ 2>/dev/null || true
            fi
        done
    fi
    
    # Verify that key files exist after copy
    log_task "Verifying copied files"
    local key_files=("rp-vna-common-env.yaml" "rp-vna-common-config.yaml" "rp-vna-db-env.yaml")
    local missing_files=()
    
    for file in "${key_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_error "Critical files missing after copy:"
        printf '  %s\n' "${missing_files[@]}"
        log_info "Source directory contents:"
        ls -la "$source_dir"
        log_info "Target directory contents:"
        ls -la .
        return 1
    fi
    
    log_success "All critical files copied successfully"
    
    # Show file structure comparison for verification
    log_task "Verifying complete file structure match"
    local source_file_count=$(find "$source_dir" -type f ! -path "*/.git/*" | wc -l | xargs)
    local target_file_count=$(find . -type f ! -path "*/.git/*" | wc -l | xargs)
    
    log_info "File count comparison:"
    log_info "  Source: $source_file_count files"
    log_info "  Target: $target_file_count files"
    
    if [[ "$source_file_count" != "$target_file_count" ]]; then
        log_warning "File count mismatch detected"
        log_info "Source files:"
        find "$source_dir" -type f ! -path "*/.git/*" | sort
        log_info "Target files:"
        find . -type f ! -path "*/.git/*" | sort
    else
        log_success "File counts match"
    fi
    
    log_task "Processing configuration files for namespace transformation"
    
    # Process all YAML files for namespace-specific replacements
    process_all_config_files "$target_dir"
    
    # Final verification after processing
    log_task "Final verification - checking for VNA operator required files"
    local vna_required_files=(
        "rp-vna-common-env.yaml"
        "rp-vna-common-config.yaml" 
        "rp-vna-db-env.yaml"
        "prefetcher/rp-vna-prefetcher-common.yaml"
        "hl7/rp-vna-hl7v2-server.yaml"
    )
    
    for file in "${vna_required_files[@]}"; do
        if [[ -f "$file" ]]; then
            log_success "$file"
        else
            log_error "$file (MISSING - VNA operator will fail!)"
        fi
    done
    
    # Stage all changes
    log_task "Staging all changes"
    git add -A
    
    if git diff --cached --quiet; then
        log_info "No changes to commit"
        return 0
    else
        log_task "Committing changes"
        local commit_msg="Sync VNA configs from $SOURCE_NAMESPACE to $TARGET_NAMESPACE

Source: $SOURCE_GITHUB_OWNER/$SOURCE_GITHUB_REPO@$SOURCE_GITHUB_BRANCH
Target: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH
Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        
        log_verbose "git commit -m \"$commit_msg\""
        if git commit -m "$commit_msg"; then
            log_success "Changes committed locally"
        else
            log_error "Failed to commit changes"
            return 1
        fi
        
        # Git push strategy for transient destination repo
        push_to_remote_repository
    fi
}

push_to_remote_repository() {
    log_info "Pushing changes to remote repository"
    
    # Verify remote origin configuration
    local current_remote expected_remote
    current_remote=$(git remote get-url origin 2>/dev/null || echo "")
    expected_remote="git@github.com:$TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO.git"
    
    if [[ "$current_remote" != "$expected_remote" ]]; then
        log_warning "Remote origin mismatch - fixing"
        log_verbose "Current: $current_remote"
        log_verbose "Expected: $expected_remote"
        
        if git remote set-url origin "$expected_remote"; then
            log_success "Remote origin updated"
        else
            log_error "Failed to update remote origin"
            return 1
        fi
    fi
    
    # Since destination is transient, use aggressive push strategy
    log_info "Force pushing to transient destination repository"
    log_verbose "git push --force origin $TARGET_GITHUB_BRANCH"
    
    if git push --force origin "$TARGET_GITHUB_BRANCH" 2>&1; then
        log_success "Configuration sync complete - changes pushed to GitHub"
        log_info "Repository: https://github.com/$TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO/tree/$TARGET_GITHUB_BRANCH"
        return 0
    else
        log_error "CRITICAL: Git push failed"
        log_error "This is a fatal error - VNA deployment cannot proceed without GitHub sync"
        log_info "Check your SSH access to: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO"
        return 1
    fi
}

process_all_config_files() {
    local target_dir="$1"
    
    log_info "Processing configuration files in: $target_dir"
    
    # Find all YAML files and process them
    find "$target_dir" -name "*.yaml" -o -name "*.yml" | while read -r file; do
        if [[ "$file" == */.git/* ]]; then
            continue
        fi
        
        log_verbose "Processing: $(basename "$file")"
        process_single_config_file "$file"
    done
}

process_single_config_file() {
    local file_path="$1"
    local temp_file=$(mktemp)
    TEMP_FILES+=("$temp_file")
    
    # Apply namespace-specific transformations
    sed \
        -e "s/service\.namespace=$SOURCE_NAMESPACE/service.namespace=$TARGET_NAMESPACE/g" \
        -e "s/service\.namespace=\"$SOURCE_NAMESPACE\"/service.namespace=\"$TARGET_NAMESPACE\"/g" \
        -e "s/namespace: $SOURCE_NAMESPACE/namespace: $TARGET_NAMESPACE/g" \
        -e "s/$SOURCE_NAMESPACE-/${TARGET_NAMESPACE}-/g" \
        -e "s/log\/rp\/vna\/$SOURCE_NAMESPACE-/log\/rp\/vna\/$TARGET_NAMESPACE-/g" \
        -e "s/\/var\/log\/rp\/vna\/$SOURCE_NAMESPACE/\/var\/log\/rp\/vna\/$TARGET_NAMESPACE/g" \
        "$file_path" > "$temp_file"
    
    # Apply specific transformations based on file type
    local filename=$(basename "$file_path")
    
    case "$filename" in
        "rp-vna-common-config.yaml")
            process_common_config_file "$temp_file"
            ;;
        "rp-vna-common-env.yaml")
            process_common_env_file "$temp_file"
            ;;
        "rp-vna-db-env.yaml")
            process_db_env_file "$temp_file"
            ;;
        *)
            # For other files, just apply basic namespace replacements
            ;;
    esac
    
    # Replace original file with processed version
    mv "$temp_file" "$file_path"
}

process_common_config_file() {
    local temp_file="$1"
    local temp_file2=$(mktemp)
    TEMP_FILES+=("$temp_file2")
    
    # Update OTLP endpoints to standard port if they're using non-standard ports
    sed \
        -e 's/:12345/:4317/g' \
        -e 's/:8080/:4317/g' \
        "$temp_file" > "$temp_file2"
    
    mv "$temp_file2" "$temp_file"
}

process_common_env_file() {
    local temp_file="$1"
    
    # Ensure DICOM cache is enabled if not present
    if ! grep -q "RP_VNA_CACHE_DICOM_STORE_ENABLED" "$temp_file"; then
        echo "RP_VNA_CACHE_DICOM_STORE_ENABLED: true" >> "$temp_file"
    fi
}

process_db_env_file() {
    local temp_file="$1"
    
    # Use config values if available
    if [[ "$CONFIG_DB_MODE" == "local" ]]; then
        log_info "Using local PostgreSQL deployment - no database host changes needed"
        # For local DB, we don't need to modify database hosts
        # The VNA operator will handle local DB deployment
    elif [[ -n "$CONFIG_DB_DEFAULT_HOST" ]]; then
        log_info "Using configured database hosts"
        
        # Apply configured database hosts
        sed -i \
            -e "s|rpvna02-load-default\.cb4o8sm06f6f\.us-east-1\.rds\.amazonaws\.com|$CONFIG_DB_DEFAULT_HOST|g" \
            -e "s|rpvna02-load-volatile\.cb4o8sm06f6f\.us-east-1\.rds\.amazonaws\.com|$CONFIG_DB_VOLATILE_HOST|g" \
            -e 's/loadprimary/postgres/g' \
            -e 's/loadsecondary/postgres/g' \
            "$temp_file"
        
        log_success "Applied configured database hosts: $CONFIG_DB_DEFAULT_HOST, $CONFIG_DB_VOLATILE_HOST"
    else
        # Fall back to existing hardcoded logic
        log_verbose "Using hardcoded database configuration for namespace: $TARGET_NAMESPACE"
        
        # Handle database host replacements for target namespace
        case "$TARGET_NAMESPACE" in
        "ac001001")
            # Default to proxy connection for ac001001
            sed -i \
                -e 's/rpvna02-load-default\.cb4o8sm06f6f\.us-east-1\.rds\.amazonaws\.com/rpvna-ac001-default-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com/g' \
                -e 's/rpvna02-load-volatile\.cb4o8sm06f6f\.us-east-1\.rds\.amazonaws\.com/rpvna-ac001-volatile-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com/g' \
                -e 's/loadprimary/postgres/g' \
                -e 's/loadsecondary/postgres/g' \
                "$temp_file"
            log_success "Database connection: ac001001 (proxy)"
            ;;
        *)
            log_warning "No specific database configuration for namespace: $TARGET_NAMESPACE"
            log_info "Consider using --config with database settings for this namespace"
            ;;
        esac
    fi
    
    # Ensure DB keep alive is present
    if ! grep -q "RP_VNA_DB_KEEP_ALIVE" "$temp_file"; then
        echo "" >> "$temp_file"
        echo "# Keeps the db-migration pod from restarting" >> "$temp_file"
        echo "RP_VNA_DB_KEEP_ALIVE: true" >> "$temp_file"
    fi
}

verify_deployment_health() {
    local namespace="$1"
    local timeout=300
    local check_interval=10
    local elapsed=0
    
    log_step "Verifying VNA deployment health"
    log_info "Timeout: ${timeout}s, checking every ${check_interval}s"
    
    # Step 1: Verify VNA CR exists and was accepted
    log_task "Checking VNA CR status"
    if kubectl get vna vna-cr -n "$namespace" >/dev/null 2>&1; then
        log_success "VNA CR exists and was accepted by operator"
    else
        log_error "VNA CR not found or not accepted"
        show_deployment_status "$namespace"
        return 1
    fi
    
    # Step 2: Wait for pods to be created and become ready
    log_task "Waiting for VNA pods to be created and become ready"
    while [[ $elapsed -lt $timeout ]]; do
        local running_pods=$(kubectl get pods -n "$namespace" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | xargs)
        local pending_pods=$(kubectl get pods -n "$namespace" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | xargs)
        local total_pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l | xargs)
        
        if [[ "$total_pods" -gt 0 ]]; then
            if [[ "$running_pods" -gt 0 ]]; then
                if [[ $elapsed -gt 0 ]]; then
                    log_success "VNA pods are running: $running_pods/$total_pods (${elapsed}s elapsed)"
                else
                    log_success "VNA pods are running: $running_pods/$total_pods"
                fi
                break
            else
                log_info "Waiting for pods... Running: $running_pods, Pending: $pending_pods, Total: $total_pods (${elapsed}s elapsed)"
            fi
        else
            log_info "Waiting for VNA operator to create pods... (${elapsed}s elapsed)"
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    if [[ $elapsed -ge $timeout ]]; then
        log_warning "VNA deployment did not complete within ${timeout}s timeout"
        show_deployment_status "$namespace"
        return 1
    fi
    
    # Step 3: Quick service check
    local services=$(kubectl get svc -n "$namespace" --no-headers 2>/dev/null | wc -l | xargs)
    if [[ "$services" -gt 0 ]]; then
        log_success "Services created: $services"
    else
        log_warning "No services found"
    fi
    
    log_success "VNA deployment health verification complete"
    
    # Show deployment summary for operator testing
    log_step "VNA Deployment Summary"
    if kubectl get vna -n "$namespace" -o wide 2>/dev/null; then
        log_success "VNA CR status retrieved successfully"
    else
        log_warning "Could not get VNA status"
    fi
    
    return 0
}

show_deployment_status() {
    local namespace="$1"
    
    log_step "Current deployment status"
    
    log_info "VNA Custom Resource:"
    if ! kubectl get vna -n "$namespace" -o wide 2>/dev/null; then
        log_warning "No VNA CR found"
    fi
    
    echo
    log_info "Pods:"
    if ! kubectl get pods -n "$namespace" 2>/dev/null; then
        log_warning "No pods found"
    fi
    
    echo
    log_info "Recent Events:"
    if ! kubectl get events -n "$namespace" --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -5; then
        log_warning "No events found"
    fi
}

deploy_vna() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_step "DRY RUN: Skipping VNA deployment"
        
        local cr_file="$SCRIPT_DIR/$TARGET_NAMESPACE-vna.yaml"
        
        if [[ ! -f "$cr_file" ]]; then
            log_error "VNA CR file $cr_file not found"
            exit 1
        fi
        
        log_success "VNA CR created: $cr_file"
        log_success "GitHub configs synced to: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
        echo
        log_info "To deploy manually:"
        log_info "  kubectl apply -f $cr_file"
        echo
        log_info "To check deployment status after manual apply:"
        log_info "  kubectl get vna -n $TARGET_NAMESPACE"
        log_info "  kubectl get pods -n $TARGET_NAMESPACE"
        return 0
    fi
    
    log_step "Deploying VNA to cluster"
    
    local cr_file="$SCRIPT_DIR/$TARGET_NAMESPACE-vna.yaml"
    
    if [[ ! -f "$cr_file" ]]; then
        log_error "VNA CR file $cr_file not found"
        exit 1
    fi
    
    log_info "Applying VNA CR to cluster"
    log_verbose "kubectl apply -f $cr_file"
    if kubectl apply -f "$cr_file"; then
        log_success "VNA CR applied successfully"
    else
        log_error "Failed to apply VNA CR"
        return 1
    fi
    
    # Post-deployment health verification
    verify_deployment_health "$TARGET_NAMESPACE"
}

check_prerequisites() {
    log_step "Checking prerequisites"
    
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl is not installed"
        exit 1
    fi
    
    if ! command -v git >/dev/null 2>&1; then
        log_error "git is not installed"
        exit 1
    fi
    
    if ! command -v ssh >/dev/null 2>&1; then
        log_error "ssh is not available"
        exit 1
    fi
    
    if ! command -v yq >/dev/null 2>&1; then
        log_error "yq is not installed (required for config file parsing)"
        exit 1
    fi
    
    # Check SSH access to GitHub (basic connectivity test)
    log_task "Checking SSH access to GitHub"
    if ssh -T git@github.com 2>&1 | grep -q "You've successfully authenticated"; then
        log_success "SSH access to GitHub verified"
    else
        # Soften message to avoid false alarms; git operations will validate definitively
        log_info "SSH access not confirmed; will validate during git operations"
        log_debug "Make sure you have:"
        log_debug "  1. SSH key added to your GitHub account"
        log_debug "  2. SSH agent running with your key loaded"
        log_debug "  3. Access to both source and target repositories"
    fi
    
    if ! kubectl get namespace "$TARGET_NAMESPACE" >/dev/null 2>&1; then
        log_task "Creating target namespace: $TARGET_NAMESPACE"
        kubectl create namespace "$TARGET_NAMESPACE"
        log_success "Namespace created: $TARGET_NAMESPACE"
    else
        log_success "Target namespace exists: $TARGET_NAMESPACE"
    fi
    
    log_success "Prerequisites check complete"
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] [SOURCE_NAMESPACE] [TARGET_NAMESPACE] [TARGET_BRANCH]

Creates a test VNA deployment by copying from a working namespace and applying test-specific configurations.
Designed for quick PR testing workflow - copy from a stable Edge deployment to test your changes.

Prerequisites:
  - SSH access to GitHub with keys configured
  - kubectl configured for target cluster
  - yq command available for config file parsing

Options:
  --config FILE                Use configuration file for namespace-specific settings
  --dry-run                    Sync configs and create VNA CR but don't deploy to cluster
  --verbose, -v                Enable verbose logging for debugging
  --quick                      Skip confirmation prompts (for automated testing)
  --reset                      Delete existing VNA CR before deployment
  -h, --help                   Show this help message

Arguments (positional):
  SOURCE_NAMESPACE   Source namespace to copy from (default: rpvna-edge-1)
  TARGET_NAMESPACE   Target namespace to deploy to (required)
  [TARGET_BRANCH]    Target git branch name (optional, uses config or defaults to TARGET_NAMESPACE)

Examples:
  # Quick PR testing workflow (recommended)
  $0 --config test-configs.yaml rpvna-edge-1 test-pr-123
  $0 --config test-configs.yaml --dry-run rpvna-edge-1 test-pr-456
  
  # Reset and deploy for fresh testing
  $0 --config test-configs.yaml --quick --reset rpvna-edge-1 test-pr-123
  
  # Manual testing without config (uses hardcoded database settings)
  $0 --dry-run rpvna-edge-1 manual-test-namespace
  
  # Verbose debugging
  $0 --config test-configs.yaml --verbose rpvna-edge-1 debug-namespace

The script will:
1. Pull the latest configuration from the source GitHub repository
2. Copy ALL files from source to target repository
3. Transform namespace-specific configurations:
   - Service namespaces in OTEL attributes
   - Log file paths
   - Database hosts (for known mappings)
   - Database proxy settings (with --no-proxy)
   - Resource names and references
4. Create a new VNA CR with updated GitHub config
5. Deploy the VNA CR to the target namespace (unless --dry-run)

Dry run mode:
- Syncs all GitHub configurations 
- Creates the VNA CR file locally
- Does NOT apply the CR to the Kubernetes cluster
- Provides manual deployment instructions

This ensures your target namespace always has the latest configuration from source
with appropriate namespace-specific customizations applied automatically.

EOF
}

show_transformations() {
    if [[ "$VERBOSE" == "true" ]]; then
        log_debug "Configuration Transformations Applied:"
        log_debug "  - service.namespace=$SOURCE_NAMESPACE → service.namespace=$TARGET_NAMESPACE"
        log_debug "  - namespace: $SOURCE_NAMESPACE → namespace: $TARGET_NAMESPACE"
        log_debug "  - Log paths: /var/log/rp/vna/$SOURCE_NAMESPACE → /var/log/rp/vna/$TARGET_NAMESPACE"
        log_debug "  - Resource prefixes: $SOURCE_NAMESPACE- → $TARGET_NAMESPACE-"
        
        case "$TARGET_NAMESPACE" in
            "ac001001")
                log_debug "  - Database: rpvna-ac001-*-pgdb-proxy.proxy-*.amazonaws.com"
                ;;
            *)
                if [[ -n "$CONFIG_DB_DEFAULT_HOST" ]]; then
                    log_debug "  - Database: $CONFIG_DB_DEFAULT_HOST"
                else
                    log_debug "  - Database: No specific mappings configured"
                fi
                ;;
        esac
    fi
}

main() {
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --quick)
                QUICK_MODE=true
                shift
                ;;
            --reset)
                RESET_MODE=true
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                USE_CONFIG=true
                shift 2
                ;;
            -*)
                log_error "Unknown option $1"
                show_help
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Set variables after option parsing (positional args override explicit options)
    SOURCE_NAMESPACE="${1:-${SOURCE_NAMESPACE:-rpvna-edge-1}}"
    TARGET_NAMESPACE="${2:-${TARGET_NAMESPACE:-test-pr-default}}"
    TARGET_BRANCH="${3:-${TARGET_BRANCH:-$TARGET_NAMESPACE}}"
    
    SOURCE_GITHUB_BRANCH="$SOURCE_NAMESPACE"
    TARGET_GITHUB_BRANCH="$TARGET_BRANCH"
    
    # Input validation
    validate_namespace "$SOURCE_NAMESPACE" || exit 1
    validate_namespace "$TARGET_NAMESPACE" || exit 1 
    validate_branch_name "$TARGET_BRANCH" || exit 1
    
    # Load namespace configuration if config file is provided
    load_namespace_config "$TARGET_NAMESPACE"
    
    # Set cleanup tracking
    CLEANUP_NEEDED=true
    
    log_step "VNA Redeployment Script Started"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Mode: ${BOLD}DRY RUN${NC} (no deployment)"
    else
        log_info "Mode: ${BOLD}Full deployment${NC}"
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Verbose mode: ${BOLD}ENABLED${NC}"
    fi
    if [[ "$QUICK_MODE" == "true" ]]; then
        log_info "Quick mode: ${BOLD}ENABLED${NC} (skip confirmations)"
    fi
    if [[ "$RESET_MODE" == "true" ]]; then
        log_info "Reset mode: ${BOLD}ENABLED${NC} (delete existing VNA CR first)"
    fi
    if [[ "$USE_CONFIG" == "true" ]]; then
        log_info "Using config file: ${CYAN}$CONFIG_FILE${NC}"
    fi
    
    log_info "Source namespace: ${CYAN}$SOURCE_NAMESPACE${NC}"
    log_info "Target namespace: ${CYAN}$TARGET_NAMESPACE${NC}" 
    log_info "Target branch: ${CYAN}$TARGET_BRANCH${NC}"
    log_debug "Source repo: $SOURCE_GITHUB_OWNER/$SOURCE_GITHUB_REPO@$SOURCE_GITHUB_BRANCH"
    log_debug "Target repo: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
    
    # Execute deployment pipeline with comprehensive error checking
    if ! check_prerequisites; then
        log_error "Prerequisites check failed - aborting deployment"
        exit 1
    fi
    
    if ! cleanup_local_files; then
        log_error "Local cleanup failed - aborting deployment"
        exit 1
    fi
    
    # Only cleanup target namespace if not doing a dry run
    if [[ "$DRY_RUN" != "true" ]]; then
        # Ask before deleting existing CRs/resources
        log_warning "About to delete any existing VNA CR in $TARGET_NAMESPACE"
        confirm_action
        if ! cleanup_target_namespace; then
            log_error "Target namespace cleanup failed - aborting deployment"
            exit 1
        fi
    fi
    
    if ! check_target_namespace_requirements; then
        log_error "Target namespace requirements check failed - aborting deployment"
        exit 1
    fi
    
    log_info "Configuration will be synchronized from source to target"
    show_transformations
    
    confirm_action
    
    if ! create_vna_cr; then
        log_error "VNA CR creation failed - aborting deployment"
        exit 1
    fi
    
    if sync_github_configs; then
        log_success "GitHub configuration sync completed"
        echo
        deploy_vna
    else
        echo
        log_error "CRITICAL: GitHub sync failed"
        log_error "VNA deployment cannot proceed without GitHub configuration"
        log_info "Manual deployment option:"
        log_info "  kubectl apply -f $TARGET_NAMESPACE-vna.yaml"
        log_warning "Note: Manual deployment may fail due to missing configuration"
        exit 1
    fi
    
    echo
    if [[ "$DRY_RUN" == "true" ]]; then
        log_step "Dry Run Summary"
        log_success "VNA CR file created: $TARGET_NAMESPACE-vna.yaml"
        log_success "GitHub configs synced to: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
        log_success "Target namespace: $TARGET_NAMESPACE (ready for deployment)"
        echo
        log_info "To deploy manually:"
        log_info "  ${CYAN}kubectl apply -f $TARGET_NAMESPACE-vna.yaml${NC}"
        echo
        log_info "To run full deployment:"
        if [[ "$USE_CONFIG" == "true" ]]; then
            log_info "  ${CYAN}$0 --config $CONFIG_FILE $SOURCE_NAMESPACE $TARGET_NAMESPACE${NC}"
        else
            log_info "  ${CYAN}$0 $SOURCE_NAMESPACE $TARGET_NAMESPACE $TARGET_BRANCH${NC}"
        fi
    else
        echo
        log_step "VNA DEPLOYMENT COMPLETE"
        log_success "VNA CR file: $TARGET_NAMESPACE-vna.yaml"
        log_success "Target namespace: $TARGET_NAMESPACE"
        log_success "GitHub config: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
        echo
        log_info "Check deployment status with:"
        log_info "  ${CYAN}kubectl get vna -n $TARGET_NAMESPACE${NC}"
        log_info "  ${CYAN}kubectl get pods -n $TARGET_NAMESPACE${NC}"
        echo
        log_info "For quick testing workflow:"
        if [[ "$USE_CONFIG" == "true" ]]; then
            log_info "  ${CYAN}$0 --config $CONFIG_FILE --quick --reset $SOURCE_NAMESPACE $TARGET_NAMESPACE${NC}"
        else
            log_info "  ${CYAN}$0 --quick --reset $SOURCE_NAMESPACE $TARGET_NAMESPACE $TARGET_BRANCH${NC}"
        fi
    fi
}

main "$@"
