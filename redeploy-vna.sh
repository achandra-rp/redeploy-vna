#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# These will be set in main() after help check
SOURCE_NAMESPACE=""
TARGET_NAMESPACE=""
TARGET_BRANCH=""
DRY_RUN=false
GITHUB_SECRET_KEY=""

SOURCE_GITHUB_OWNER="radpartners"
SOURCE_GITHUB_REPO="rp-vna-deployments-dev"
TARGET_GITHUB_OWNER="achandra-rp"
TARGET_GITHUB_REPO="cluster-config"

confirm_action() {
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
    echo "=== Cleaning up target namespace: $TARGET_NAMESPACE ==="
    
    # Delete existing VNA CR if it exists
    if kubectl get vna vna-cr -n "$TARGET_NAMESPACE" >/dev/null 2>&1; then
        echo "Deleting existing VNA CR in namespace $TARGET_NAMESPACE..."
        kubectl delete vna vna-cr -n "$TARGET_NAMESPACE" || {
            echo "Warning: Failed to delete existing VNA CR"
        }
        
        # Wait for deletion to complete
        echo "Waiting for VNA CR deletion to complete..."
        kubectl wait --for=delete vna/vna-cr -n "$TARGET_NAMESPACE" --timeout=60s || {
            echo "Warning: VNA CR deletion did not complete within timeout"
        }
    else
        echo "No existing VNA CR found in namespace $TARGET_NAMESPACE"
    fi
    
    echo "OK Target namespace cleanup complete"
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
    echo "Setting up source repository (READ-ONLY)..."
    local source_ssh_url="git@github.com:$SOURCE_GITHUB_OWNER/$SOURCE_GITHUB_REPO.git"
    
    if [[ -d "$source_dir" ]]; then
        echo "Source directory exists. Updating to latest..."
        cd "$source_dir"
        # Ensure we're in a clean state and never modify source
        git reset --hard HEAD
        git clean -fd
        git fetch origin
        git checkout "$SOURCE_GITHUB_BRANCH" || git checkout -b "$SOURCE_GITHUB_BRANCH" origin/"$SOURCE_GITHUB_BRANCH"
        git reset --hard origin/"$SOURCE_GITHUB_BRANCH"
        echo "OK Source repository updated to latest from origin/$SOURCE_GITHUB_BRANCH"
    else
        echo "Cloning source repository..."
        if ! git clone -b "$SOURCE_GITHUB_BRANCH" "$source_ssh_url" "$source_dir" 2>/dev/null; then
            echo "Error: Could not clone source repository. Check SSH access permissions and branch name."
            echo "Repository: $source_ssh_url@$SOURCE_GITHUB_BRANCH"
            echo "Make sure you have SSH access to the repository and the branch exists."
            return 1
        fi
        echo "OK Source repository cloned"
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
        echo "Cloning target repository..."
        if ! git clone "$target_ssh_url" "$target_dir" 2>/dev/null; then
            echo "Error: Could not clone target repository"
            echo "Repository: $target_ssh_url"
            echo "Make sure you have SSH access to the repository."
            return 1
        fi
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
        
        git commit -m "$commit_msg"
        
        echo "Checking remote origin and pulling latest changes..."
        # Ensure we're pushing to the correct target repository
        local current_remote=$(git remote get-url origin)
        local expected_remote="git@github.com:$TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO.git"
        
        if [[ "$current_remote" != "$expected_remote" ]]; then
            echo "Warning: Remote origin mismatch!"
            echo "  Current: $current_remote"
            echo "  Expected: $expected_remote"
            echo "  Fixing remote origin..."
            git remote set-url origin "$expected_remote"
        fi
        
        # Pull latest changes if branch exists on remote to avoid conflicts
        if git ls-remote --heads origin "$TARGET_GITHUB_BRANCH" | grep -q "$TARGET_GITHUB_BRANCH"; then
            echo "Branch exists on remote. Pulling latest changes..."
            git pull origin "$TARGET_GITHUB_BRANCH" --rebase || {
                echo "Warning: Git pull failed. Attempting force push..."
                echo "Pushing to remote..."
                git push origin "$TARGET_GITHUB_BRANCH" --force
                echo "OK Configuration sync complete (force pushed)"
                return 0
            }
        fi
        
        echo "Pushing to remote..."
        git push origin "$TARGET_GITHUB_BRANCH"
        echo "OK Configuration sync complete"
    fi
}

process_all_config_files() {
    local target_dir="$1"
    
    echo "Processing configuration files in: $target_dir"
    
    # Find all YAML files and process them
    find "$target_dir" -name "*.yaml" -o -name "*.yml" | while read -r file; do
        if [[ "$file" == */.git/* ]]; then
            continue
        fi
        
        echo "  Processing: $(basename "$file")"
        process_single_config_file "$file"
    done
}

process_single_config_file() {
    local file_path="$1"
    local temp_file=$(mktemp)
    
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
    # This is where you'd add specific database host mappings if needed
    case "$TARGET_NAMESPACE" in
        "ac001001")
            sed -i \
                -e 's/rpvna02-load-default\.cb4o8sm06f6f\.us-east-1\.rds\.amazonaws\.com/rpvna-ac001-default-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com/g' \
                -e 's/rpvna02-load-volatile\.cb4o8sm06f6f\.us-east-1\.rds\.amazonaws\.com/rpvna-ac001-volatile-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com/g' \
                -e 's/loadprimary/postgres/g' \
                -e 's/loadsecondary/postgres/g' \
                "$temp_file"
            ;;
        # Add more cases for other target namespaces as needed
        *)
            echo "Warning: No specific database configuration for namespace: $TARGET_NAMESPACE"
            echo "Using generic database host pattern replacement"
            ;;
    esac
    
    # Ensure DB keep alive is present
    if ! grep -q "RP_VNA_DB_KEEP_ALIVE" "$temp_file"; then
        echo "" >> "$temp_file"
        echo "# Keeps the db-migration pod from restarting" >> "$temp_file"
        echo "RP_VNA_DB_KEEP_ALIVE: true" >> "$temp_file"
    fi
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
    
    echo "Applying VNA CR to cluster..."
    kubectl apply -f "$cr_file"
    
    echo "Waiting for VNA deployment to be ready..."
    kubectl wait --for=condition=Ready --timeout=300s -n "$TARGET_NAMESPACE" vna/vna-cr || {
        echo "Warning: VNA deployment did not become ready within timeout"
        echo "Check the status with: kubectl get vna -n $TARGET_NAMESPACE"
    }
    
    echo "OK VNA deployment complete"
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
  --dry-run          Sync configs and create VNA CR but don't deploy to cluster
  -h, --help         Show this help message

Arguments:
  SOURCE_NAMESPACE   Source namespace to copy from (default: rpvna)
  TARGET_NAMESPACE   Target namespace to deploy to (default: ac001001) 
  TARGET_BRANCH      Target git branch name (default: same as TARGET_NAMESPACE)

Examples:
  $0                           # Use defaults: rpvna -> ac001001
  $0 --dry-run                 # Dry run with defaults (no deployment)
  $0 rpvna ac001002           # rpvna -> ac001002, branch ac001002
  $0 --dry-run rpvna ac001003 # Dry run: rpvna -> ac001003 (no deployment)

The script will:
1. Pull the latest configuration from the source GitHub repository
2. Copy ALL files from source to target repository
3. Transform namespace-specific configurations:
   - Service namespaces in OTEL attributes
   - Log file paths
   - Database hosts (for known mappings)
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
            echo "- Default DB: rpvna-ac001-default-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com"
            echo "- Volatile DB: rpvna-ac001-volatile-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com"
            ;;
        *)
            echo "- No specific mappings configured (uses source values)"
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
    
    # Set variables after option parsing
    SOURCE_NAMESPACE="${1:-rpvna}"
    TARGET_NAMESPACE="${2:-ac001001}"
    TARGET_BRANCH="${3:-$TARGET_NAMESPACE}"
    
    SOURCE_GITHUB_BRANCH="$SOURCE_NAMESPACE"
    TARGET_GITHUB_BRANCH="$TARGET_BRANCH"
    
    echo "=== VNA Redeployment Script ==="
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "Mode: DRY RUN (no deployment)"
    else
        echo "Mode: Full deployment"
    fi
    echo "Source namespace: $SOURCE_NAMESPACE"
    echo "Target namespace: $TARGET_NAMESPACE" 
    echo "Target branch: $TARGET_BRANCH"
    echo "Source repo: $SOURCE_GITHUB_OWNER/$SOURCE_GITHUB_REPO@$SOURCE_GITHUB_BRANCH"
    echo "Target repo: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
    echo
    
    check_prerequisites
    cleanup_local_files
    
    # Only cleanup target namespace if not doing a dry run
    if [[ "$DRY_RUN" != "true" ]]; then
        cleanup_target_namespace
    fi
    
    check_target_namespace_requirements
    
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
    
    create_vna_cr
    
    if sync_github_configs; then
        echo
        deploy_vna
    else
        echo
        echo "GitHub sync failed. You can still deploy with:"
        echo "  kubectl apply -f $TARGET_NAMESPACE-vna.yaml"
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
        echo "=== Deployment Summary ==="
        echo "VNA CR file: $TARGET_NAMESPACE-vna.yaml"
        echo "Target namespace: $TARGET_NAMESPACE"
        echo "GitHub config: $TARGET_GITHUB_OWNER/$TARGET_GITHUB_REPO@$TARGET_GITHUB_BRANCH"
        echo
        echo "Check deployment status with:"
        echo "  kubectl get vna -n $TARGET_NAMESPACE"
        echo "  kubectl get pods -n $TARGET_NAMESPACE"
        echo
        echo "To run this sync again (dry-run mode):"
        echo "  $0 --dry-run $SOURCE_NAMESPACE $TARGET_NAMESPACE $TARGET_BRANCH"
    fi
}

main "$@"