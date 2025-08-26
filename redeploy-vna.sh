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
        echo "=== Cleaning up temporary resources ==="
        
        # Clean up temporary files
        for temp_file in "${TEMP_FILES[@]}"; do
            if [[ -f "$temp_file" ]]; then
                echo "Removing temporary file: $temp_file"
                rm -f "$temp_file"
            fi
        done
        
        # Clean up any stray temporary manifest files in /tmp
        find /tmp -name "db-inspector-*.yaml" -mtime +1 -delete 2>/dev/null || true
        
        echo "Cleanup complete"
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        echo "Script exited with error code: $exit_code"
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
NO_PROXY=false
VERBOSE=false
QUICK_MODE=false
RESET_MODE=false
GITHUB_SECRET_KEY=""

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
NC='\033[0m' # No Color

# Colored output functions
log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
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
        log_verbose "Quick mode: Skipping confirmation"
        return 0
    fi
    
    echo -n "Continue? [Y/n]: "
    read -r response
    # Default to yes if empty response (just pressing enter)
    if [[ -z "$response" ]] || [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    elif [[ "$response" =~ ^[Nn]$ ]]; then
        echo "Aborted."
        exit 1
    else
        echo "Invalid response. Please enter y/yes or n/no."
        confirm_action
    fi
}

cleanup_local_files() {
    echo "=== Cleaning up local files ==="
    
    # Remove any existing CR files for this namespace
    local cr_file="$SCRIPT_DIR/$TARGET_NAMESPACE-vna.yaml"
    if [[ -f "$cr_file" ]]; then
        echo "Removing existing CR file: $cr_file"
        rm -f "$cr_file"
    fi
    
    echo "Note: Repository directories will be reused and updated if they exist:"
    echo "  - $SCRIPT_DIR/rpvna-source-config"
    echo "  - $SCRIPT_DIR/ac001001-target-config"
    
    echo "OK Local cleanup complete"
}

cleanup_target_namespace() {
    # Only run if in reset mode or DRY_RUN is false
    if [[ "$RESET_MODE" != "true" ]] && [[ "$DRY_RUN" == "true" ]]; then
        log_verbose "Skipping target namespace cleanup (not in reset mode and dry run)"
        return 0
    fi
    
    log_info "Cleaning up target namespace: $TARGET_NAMESPACE"
    
    # Delete existing VNA CR if it exists
    if kubectl get vna vna-cr -n "$TARGET_NAMESPACE" >/dev/null 2>&1; then
        log_info "Deleting existing VNA CR in namespace $TARGET_NAMESPACE"
        log_verbose "kubectl delete vna vna-cr -n $TARGET_NAMESPACE"
        
        if kubectl delete vna vna-cr -n "$TARGET_NAMESPACE"; then
            log_success "VNA CR deletion initiated"
        else
            log_warning "Failed to delete existing VNA CR"
            return 1
        fi
        
        # Wait for deletion to complete
        log_info "Waiting for VNA CR deletion to complete (60s timeout)"
        if kubectl wait --for=delete vna/vna-cr -n "$TARGET_NAMESPACE" --timeout=60s; then
            log_success "VNA CR deletion completed"
        else
            log_warning "VNA CR deletion did not complete within timeout"
            log_info "Continuing anyway - operator should handle remaining resources"
        fi
    else
        log_info "No existing VNA CR found in namespace $TARGET_NAMESPACE"
    fi
    
    log_success "Target namespace cleanup complete"
}

check_target_namespace_requirements() {
    echo "=== Checking target namespace requirements ==="
    
    # Check if github-secret exists and detect the secret key
    if kubectl get secret github-secret -n "$TARGET_NAMESPACE" >/dev/null 2>&1; then
        echo "OK github-secret exists in namespace $TARGET_NAMESPACE"
        
        # Check what keys are available in the secret
        local available_keys
        available_keys=$(kubectl get secret github-secret -n "$TARGET_NAMESPACE" -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null || echo "")
        
        if [[ -z "$available_keys" ]]; then
            echo "Warning: Could not read github-secret keys. Assuming 'token'."
            GITHUB_SECRET_KEY="token"
        elif echo "$available_keys" | grep -q "^token$"; then
            echo "OK Using secretKey: token"
            GITHUB_SECRET_KEY="token"
        elif echo "$available_keys" | grep -q "^github-token$"; then
            echo "OK Using secretKey: github-token"
            GITHUB_SECRET_KEY="github-token"
        else
            echo "Available keys in github-secret: $available_keys"
            echo "Warning: Neither 'token' nor 'github-token' found. Using 'token' as default."
            GITHUB_SECRET_KEY="token"
        fi
    else
        echo "Error: github-secret not found in namespace $TARGET_NAMESPACE"
        echo "Please ensure the github-secret exists with either 'token' or 'github-token' key"
        echo "Example:"
        echo "  kubectl create secret generic github-secret --from-literal=token=<your-token> -n $TARGET_NAMESPACE"
        exit 1
    fi
    
    echo "OK Target namespace requirements check complete"
}

create_vna_cr() {
    echo "=== Creating VNA CR for $TARGET_NAMESPACE ==="
    
    local output_file="$TARGET_NAMESPACE-vna.yaml"
    local source_cr_file="$SCRIPT_DIR/rpvna-dev.yaml"
    
    # Check if source CR file exists, if not pull it from source namespace
    if [[ ! -f "$source_cr_file" ]]; then
        echo "Source CR file not found. Pulling from source namespace: $SOURCE_NAMESPACE"
        
        # Check if kubectl neat is available
        if command -v kubectl-neat >/dev/null 2>&1; then
            kubectl get vnas.radpartners.com -n "$SOURCE_NAMESPACE" -o yaml | kubectl neat > "$source_cr_file"
        elif kubectl neat --help >/dev/null 2>&1; then
            kubectl get vnas.radpartners.com -n "$SOURCE_NAMESPACE" -o yaml | kubectl neat > "$source_cr_file"
        else
            echo "Warning: kubectl neat not available. Using raw kubectl output (may contain extra metadata)"
            kubectl get vnas.radpartners.com -n "$SOURCE_NAMESPACE" -o yaml > "$source_cr_file"
        fi
        
        if [[ ! -f "$source_cr_file" ]]; then
            echo "Error: Failed to pull VNA CR from source namespace $SOURCE_NAMESPACE"
            echo "Make sure the VNA CR exists in the source namespace and you have access"
            exit 1
        fi
        
        echo "OK Source CR pulled from namespace: $SOURCE_NAMESPACE"
    else
        echo "Using existing source CR file: $source_cr_file"
    fi
    
    # Create the new CR with comprehensive namespace and GitHub config updates
    sed "s/namespace: $SOURCE_NAMESPACE/namespace: $TARGET_NAMESPACE/g" "$source_cr_file" | \
    sed "s/branch: $SOURCE_GITHUB_BRANCH/branch: $TARGET_GITHUB_BRANCH/g" | \
    sed "s/owner: $SOURCE_GITHUB_OWNER/owner: $TARGET_GITHUB_OWNER/g" | \
    sed "s/repository: $SOURCE_GITHUB_REPO/repository: $TARGET_GITHUB_REPO/g" | \
    sed "s/secretKey: token/secretKey: $GITHUB_SECRET_KEY/g" | \
    sed "s/secretKey: github-token/secretKey: $GITHUB_SECRET_KEY/g" > "$output_file"
    
    echo "VNA CR created: $output_file"
    echo "  - Using secretKey: $GITHUB_SECRET_KEY"
}

sync_github_configs() {
    echo "=== Syncing GitHub configurations ==="
    
    local source_dir="$SCRIPT_DIR/rpvna-source-config"
    local target_dir="$SCRIPT_DIR/ac001001-target-config"
    
    echo "Repository directories:"
    echo "  Source: $source_dir"
    echo "  Target: $target_dir"
    
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
    echo "Setting up target repository..."
    local target_ssh_url="git@github.com:$TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO.git"
    
    if [[ -d "$target_dir" ]]; then
        echo "Target directory exists. Updating..."
        cd "$target_dir"
        git fetch origin
        # Check if target branch exists, create if not
        if git show-ref --verify --quiet "refs/remotes/origin/$TARGET_GITHUB_BRANCH"; then
            echo "Switching to existing branch: $TARGET_GITHUB_BRANCH"
            git checkout "$TARGET_GITHUB_BRANCH"
            # Don't pull here - we want to completely reset anyway
        else
            echo "Creating new branch: $TARGET_GITHUB_BRANCH"
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
            echo "Switching to existing branch: $TARGET_GITHUB_BRANCH"
            git checkout "$TARGET_GITHUB_BRANCH"
        else
            echo "Creating new branch: $TARGET_GITHUB_BRANCH"
            git checkout -b "$TARGET_GITHUB_BRANCH"
        fi
    fi
    
    # COMPLETE RESET: Remove ALL files except .git to ensure clean state
    echo "Completely resetting target directory (removing all existing content)..."
    find . -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +
    echo "OK Target directory completely cleared"
    
    # Copy ALL files from source to target (complete mirror)
    echo "Copying ALL files from source to target..."
    
    # Copy all visible files and directories
    if ls "$source_dir"/* >/dev/null 2>&1; then
        cp -r "$source_dir"/* ./ 2>/dev/null || {
            echo "Warning: Some files failed to copy with cp"
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
    echo "Verifying copied files..."
    local key_files=("rp-vna-common-env.yaml" "rp-vna-common-config.yaml" "rp-vna-db-env.yaml")
    local missing_files=()
    
    for file in "${key_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        echo "Error: Critical files missing after copy:"
        printf '  - %s\n' "${missing_files[@]}"
        echo "Source directory contents:"
        ls -la "$source_dir"
        echo "Target directory contents:"  
        ls -la .
        return 1
    fi
    
    echo "OK All critical files copied successfully"
    
    # Show file structure comparison for verification
    echo "Verifying complete file structure match..."
    local source_file_count=$(find "$source_dir" -type f ! -path "*/.git/*" | wc -l | xargs)
    local target_file_count=$(find . -type f ! -path "*/.git/*" | wc -l | xargs)
    
    echo "File count comparison:"
    echo "  Source: $source_file_count files"
    echo "  Target: $target_file_count files"
    
    if [[ "$source_file_count" != "$target_file_count" ]]; then
        echo "Warning: File count mismatch detected!"
        echo "Source files:"
        find "$source_dir" -type f ! -path "*/.git/*" | sort
        echo "Target files:"
        find . -type f ! -path "*/.git/*" | sort
    else
        echo "OK File counts match"
    fi
    
    echo "Processing configuration files for namespace transformation..."
    
    # Process all YAML files for namespace-specific replacements
    process_all_config_files "$target_dir"
    
    # Final verification after processing
    echo "Final verification - checking for VNA operator required files..."
    local vna_required_files=(
        "rp-vna-common-env.yaml"
        "rp-vna-common-config.yaml" 
        "rp-vna-db-env.yaml"
        "prefetcher/rp-vna-prefetcher-common.yaml"
        "hl7/rp-vna-hl7v2-server.yaml"
    )
    
    for file in "${vna_required_files[@]}"; do
        if [[ -f "$file" ]]; then
            echo "  OK $file"
        else
            echo "  ERROR $file (MISSING - VNA operator will fail!)"
        fi
    done
    
    # Stage all changes
    echo "Staging all changes..."
    git add -A
    
    if git diff --cached --quiet; then
        echo "No changes to commit."
        return 0
    else
        echo "Committing changes..."
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
    
    # Handle database host replacements for target namespace
    case "$TARGET_NAMESPACE" in
        "ac001001")
            if [[ "$NO_PROXY" == "true" ]]; then
                # Direct connection (no proxy)
                sed -i \
                    -e 's/rpvna02-load-default\.cb4o8sm06f6f\.us-east-1\.rds\.amazonaws\.com/rpvna-ac001-default-pgdb.cb4o8sm06f6f.us-east-1.rds.amazonaws.com/g' \
                    -e 's/rpvna02-load-volatile\.cb4o8sm06f6f\.us-east-1\.rds\.amazonaws\.com/rpvna-ac001-volatile-pgdb.cb4o8sm06f6f.us-east-1.rds.amazonaws.com/g' \
                    -e 's/loadprimary/postgres/g' \
                    -e 's/loadsecondary/postgres/g' \
                    "$temp_file"
                log_success "Database connection: DIRECT (no proxy)"
            else
                # Proxy connection (default)
                sed -i \
                    -e 's/rpvna02-load-default\.cb4o8sm06f6f\.us-east-1\.rds\.amazonaws\.com/rpvna-ac001-default-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com/g' \
                    -e 's/rpvna02-load-volatile\.cb4o8sm06f6f\.us-east-1\.rds\.amazonaws\.com/rpvna-ac001-volatile-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com/g' \
                    -e 's/loadprimary/postgres/g' \
                    -e 's/loadsecondary/postgres/g' \
                    "$temp_file"
                log_success "Database connection: PROXY"
            fi
            ;;
        # Add more cases for other target namespaces as needed
        *)
            log_warning "No specific database configuration for namespace: $TARGET_NAMESPACE"
            log_info "Using generic database host pattern replacement"
            # For other namespaces, apply --no-proxy logic if enabled
            if [[ "$NO_PROXY" == "true" ]]; then
                log_info "Removing proxy from database URLs"
                sed -i 's/-proxy\.proxy-/-/g' "$temp_file"
            fi
            ;;
    esac
    
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
    
    log_info "Verifying VNA deployment health (timeout: ${timeout}s)"
    
    # Step 1: Wait for VNA CR to be ready
    log_verbose "Waiting for VNA CR condition=Ready"
    if kubectl wait --for=condition=Ready --timeout=${timeout}s -n "$namespace" vna/vna-cr 2>/dev/null; then
        log_success "VNA CR is ready"
    else
        log_warning "VNA CR did not become ready within timeout"
        show_deployment_status "$namespace"
        return 1
    fi
    
    # Step 2: Check pod status
    log_verbose "Checking pod readiness"
    local ready_pods=$(kubectl get pods -n "$namespace" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | xargs)
    local total_pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l | xargs)
    
    if [[ "$ready_pods" -gt 0 ]]; then
        log_success "Pods running: $ready_pods/$total_pods"
    else
        log_warning "No pods are in running state"
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
    echo
    echo "=== VNA Deployment Summary ==="
    kubectl get vna -n "$namespace" -o wide 2>/dev/null || log_warning "Could not get VNA status"
    echo
    
    return 0
}

show_deployment_status() {
    local namespace="$1"
    
    log_info "Current deployment status:"
    echo
    echo "VNA Custom Resource:"
    kubectl get vna -n "$namespace" -o wide 2>/dev/null || echo "  No VNA CR found"
    echo
    echo "Pods:"
    kubectl get pods -n "$namespace" 2>/dev/null || echo "  No pods found"
    echo
    echo "Events (last 10):"
    kubectl get events -n "$namespace" --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -10 || echo "  No events found"
}

deploy_vna() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== DRY RUN: Skipping VNA deployment ==="
        
        local cr_file="$SCRIPT_DIR/$TARGET_NAMESPACE-vna.yaml"
        
        if [[ ! -f "$cr_file" ]]; then
            echo "Error: VNA CR file $cr_file not found"
            exit 1
        fi
        
        echo "OK VNA CR created: $cr_file"
        echo "OK GitHub configs synced to: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
        echo
        echo "To deploy manually, run:"
        echo "  kubectl apply -f $cr_file"
        echo
        echo "To check deployment status after manual apply:"
        echo "  kubectl get vna -n $TARGET_NAMESPACE"
        echo "  kubectl get pods -n $TARGET_NAMESPACE"
        return 0
    fi
    
    echo "=== Deploying VNA to cluster ==="
    
    local cr_file="$SCRIPT_DIR/$TARGET_NAMESPACE-vna.yaml"
    
    if [[ ! -f "$cr_file" ]]; then
        echo "Error: VNA CR file $cr_file not found"
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
    echo "=== Checking prerequisites ==="
    
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "Error: kubectl is not installed"
        exit 1
    fi
    
    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git is not installed"
        exit 1
    fi
    
    if ! command -v ssh >/dev/null 2>&1; then
        echo "Error: ssh is not available"
        exit 1
    fi
    
    # Check SSH access to GitHub (basic connectivity test)
    echo "Checking SSH access to GitHub..."
    if ! ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        echo "Warning: SSH access to GitHub may not be configured properly."
        echo "Make sure you have:"
        echo "  1. SSH key added to your GitHub account"
        echo "  2. SSH agent running with your key loaded"
        echo "  3. Access to both source and target repositories"
        echo
    fi
    
    if ! kubectl get namespace "$TARGET_NAMESPACE" >/dev/null 2>&1; then
        echo "Target namespace '$TARGET_NAMESPACE' does not exist. Creating it..."
        kubectl create namespace "$TARGET_NAMESPACE"
    fi
    
    echo "OK Prerequisites check complete"
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] [SOURCE_NAMESPACE] [TARGET_NAMESPACE] [TARGET_BRANCH]

Redeploys VNA from source namespace to target namespace by syncing all configurations.

Prerequisites:
  - SSH access to GitHub with keys configured
  - kubectl configured for target cluster
  - Access to both source and target repositories

Options:
  --dry-run                    Sync configs and create VNA CR but don't deploy to cluster
  --no-proxy                   Remove proxy from database URLs (direct connection)
  --verbose, -v                Enable verbose logging for debugging
  --quick                      Skip confirmation prompts (for automated testing)
  --reset                      Delete existing VNA CR before deployment
  --source-namespace NS        Source namespace to copy from (default: rpvna)
  --target-namespace NS        Target namespace to deploy to (default: ac001001)
  --target-branch BRANCH       Target git branch name (default: same as TARGET_NAMESPACE)
  --source-owner OWNER         Source GitHub repository owner (default: radpartners)
  --source-repo REPO           Source GitHub repository name (default: rp-vna-deployments-dev)
  --target-owner OWNER         Target GitHub repository owner (default: achandra-rp)
  --target-repo REPO           Target GitHub repository name (default: cluster-config)
  -h, --help                   Show this help message

Arguments (positional):
  SOURCE_NAMESPACE   Source namespace to copy from (overrides --source-namespace)
  TARGET_NAMESPACE   Target namespace to deploy to (overrides --target-namespace) 
  TARGET_BRANCH      Target git branch name (overrides --target-branch)

Examples:
  $0                                      # Use defaults: rpvna -> ac001001
  $0 --dry-run                           # Dry run with defaults (no deployment)
  $0 --quick --reset                     # Quick reset and deploy (testing workflow)
  $0 --verbose --no-proxy                # Verbose mode with direct DB connection
  $0 --target-namespace ac001002         # rpvna -> ac001002
  $0 rpvna ac001002                      # rpvna -> ac001002, branch ac001002
  $0 --dry-run --no-proxy rpvna ac001003 # Dry run with direct DB connection

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
    cat << EOF
=== Configuration Transformations Applied ===

Namespace-specific replacements:
- service.namespace=$SOURCE_NAMESPACE → service.namespace=$TARGET_NAMESPACE  
- namespace: $SOURCE_NAMESPACE → namespace: $TARGET_NAMESPACE
- Log paths: /var/log/rp/vna/$SOURCE_NAMESPACE → /var/log/rp/vna/$TARGET_NAMESPACE
- Resource prefixes: $SOURCE_NAMESPACE- → $TARGET_NAMESPACE-

File-specific transformations:
- rp-vna-common-config.yaml: OTLP endpoint ports normalized to 4317
- rp-vna-common-env.yaml: Ensure DICOM cache enabled
- rp-vna-db-env.yaml: Database host mappings for target namespace

Database mappings for $TARGET_NAMESPACE:
EOF
    
    case "$TARGET_NAMESPACE" in
        "ac001001")
            if [[ "$NO_PROXY" == "true" ]]; then
                echo "- Default DB: rpvna-ac001-default-pgdb.cb4o8sm06f6f.us-east-1.rds.amazonaws.com (DIRECT)"
                echo "- Volatile DB: rpvna-ac001-volatile-pgdb.cb4o8sm06f6f.us-east-1.rds.amazonaws.com (DIRECT)"
            else
                echo "- Default DB: rpvna-ac001-default-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com"
                echo "- Volatile DB: rpvna-ac001-volatile-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com"
            fi
            ;;
        *)
            echo "- No specific mappings configured (uses source values)"
            if [[ "$NO_PROXY" == "true" ]]; then
                echo "- Proxy removal: ENABLED (removes -proxy.proxy- patterns)"
            fi
            ;;
    esac
    echo
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
            --no-proxy)
                NO_PROXY=true
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
            --source-namespace)
                SOURCE_NAMESPACE="$2"
                shift 2
                ;;
            --target-namespace)
                TARGET_NAMESPACE="$2"
                shift 2
                ;;
            --target-branch)
                TARGET_BRANCH="$2"
                shift 2
                ;;
            --source-owner)
                SOURCE_GITHUB_OWNER="$2"
                shift 2
                ;;
            --source-repo)
                SOURCE_GITHUB_REPO="$2"
                shift 2
                ;;
            --target-owner)
                TARGET_GITHUB_OWNER="$2"
                shift 2
                ;;
            --target-repo)
                TARGET_GITHUB_REPO="$2"
                shift 2
                ;;
            -*)
                echo "Unknown option $1"
                show_help
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Set variables after option parsing (positional args override explicit options)
    SOURCE_NAMESPACE="${1:-${SOURCE_NAMESPACE:-rpvna}}"
    TARGET_NAMESPACE="${2:-${TARGET_NAMESPACE:-ac001001}}"
    TARGET_BRANCH="${3:-${TARGET_BRANCH:-$TARGET_NAMESPACE}}"
    
    SOURCE_GITHUB_BRANCH="$SOURCE_NAMESPACE"
    TARGET_GITHUB_BRANCH="$TARGET_BRANCH"
    
    # Input validation
    validate_namespace "$SOURCE_NAMESPACE" || exit 1
    validate_namespace "$TARGET_NAMESPACE" || exit 1 
    validate_branch_name "$TARGET_BRANCH" || exit 1
    
    # Set cleanup tracking
    CLEANUP_NEEDED=true
    
    echo "=== VNA Redeployment Script ==="
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "Mode: DRY RUN (no deployment)"
    else
        echo "Mode: Full deployment"
    fi
    if [[ "$NO_PROXY" == "true" ]]; then
        echo "Database proxy: DISABLED (direct connection)"
    else
        echo "Database proxy: ENABLED"
    fi
    if [[ "$VERBOSE" == "true" ]]; then
        echo "Verbose mode: ENABLED"
    fi
    if [[ "$QUICK_MODE" == "true" ]]; then
        echo "Quick mode: ENABLED (skip confirmations)"
    fi
    if [[ "$RESET_MODE" == "true" ]]; then
        echo "Reset mode: ENABLED (delete existing VNA CR first)"
    fi
    echo "Source namespace: $SOURCE_NAMESPACE"
    echo "Target namespace: $TARGET_NAMESPACE" 
    echo "Target branch: $TARGET_BRANCH"
    echo "Source repo: $SOURCE_GITHUB_OWNER/$SOURCE_GITHUB_REPO@$SOURCE_GITHUB_BRANCH"
    echo "Target repo: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
    echo
    
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
        if ! cleanup_target_namespace; then
            log_error "Target namespace cleanup failed - aborting deployment"
            exit 1
        fi
    fi
    
    if ! check_target_namespace_requirements; then
        log_error "Target namespace requirements check failed - aborting deployment"
        exit 1
    fi
    
    echo "This script will synchronize ALL configuration files from source to target:"
    show_transformations
    echo "Steps to be performed:"
    echo "1. Clean up local files and directories"
    if [[ "$DRY_RUN" != "true" ]]; then
        echo "2. Delete existing VNA CR from target namespace (if exists)"
        echo "3. Verify github-secret exists and detect secretKey"
        echo "4. Create VNA CR: $TARGET_NAMESPACE-vna.yaml (using secretKey: $GITHUB_SECRET_KEY)"
        echo "5. Sync ALL configs: $SOURCE_GITHUB_OWNER/$SOURCE_GITHUB_REPO@$SOURCE_GITHUB_BRANCH → $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
        echo "6. Deploy VNA to namespace: $TARGET_NAMESPACE"
    else
        echo "2. Verify github-secret exists and detect secretKey (no namespace cleanup in dry-run)"
        echo "3. Create VNA CR: $TARGET_NAMESPACE-vna.yaml (using secretKey: $GITHUB_SECRET_KEY)"
        echo "4. Sync ALL configs: $SOURCE_GITHUB_OWNER/$SOURCE_GITHUB_REPO@$SOURCE_GITHUB_BRANCH → $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
        echo "5. DRY RUN: Create CR but do NOT deploy to cluster"
    fi
    echo
    
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
        echo "  kubectl apply -f $TARGET_NAMESPACE-vna.yaml"
        log_warning "Note: Manual deployment may fail due to missing configuration"
        exit 1
    fi
    
    echo
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== Dry Run Summary ==="
        echo "OK VNA CR file created: $TARGET_NAMESPACE-vna.yaml"
        echo "OK GitHub configs synced to: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
        echo "OK Target namespace: $TARGET_NAMESPACE (ready for deployment)"
        echo
        echo "To deploy manually:"
        echo "  kubectl apply -f $TARGET_NAMESPACE-vna.yaml"
        echo
        echo "To run full deployment:"
        echo "  $0 $SOURCE_NAMESPACE $TARGET_NAMESPACE $TARGET_BRANCH"
    else
        echo
        log_success "=== VNA DEPLOYMENT COMPLETE ==="
        log_info "VNA CR file: $TARGET_NAMESPACE-vna.yaml"
        log_info "Target namespace: $TARGET_NAMESPACE"
        log_info "GitHub config: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
        echo
        echo "Check deployment status with:"
        echo "  kubectl get vna -n $TARGET_NAMESPACE"
        echo "  kubectl get pods -n $TARGET_NAMESPACE"
        echo
        echo "For quick testing workflow:"
        echo "  $0 --quick --reset $SOURCE_NAMESPACE $TARGET_NAMESPACE $TARGET_BRANCH"
    fi
}

main "$@"