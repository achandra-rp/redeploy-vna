# VNA Redeployment Script

## Overview
A comprehensive bash script that automates the redeployment of VNA (Virtual Network Archive) from a source namespace to target namespaces by synchronizing GitHub configurations and Kubernetes resources.

## Purpose
This script addresses the need to quickly deploy VNA instances to new namespaces while maintaining consistency with a source namespace configuration. It's designed for scenarios where you need to replicate VNA deployments with namespace-specific customizations.

## Core Requirements

### Functional Requirements

#### 1. Namespace Redeployment
- **Source**: Pull latest configuration from `rpvna` namespace
- **Target**: Deploy to configurable target namespace (default: `ac001001`)
- **Automated**: Full sync and deployment process with minimal manual intervention

#### 2. GitHub Configuration Sync
- **Source Repository**: `git@github.com:radpartners/rp-vna-deployments-dev.git@rpvna`
- **Target Repository**: `git@github.com:achandra-rp/cluster-config.git@{target_namespace}`
- **Complete Sync**: Copy ALL files from source to target repository
- **Smart Processing**: Apply namespace-specific transformations to YAML files

#### 3. VNA Custom Resource (CR) Management
- **Auto-generation**: Pull VNA CR from source namespace if missing locally
- **Dynamic Configuration**: Update GitHub config, namespace, and secret keys
- **Secret Key Detection**: Auto-detect between `token` and `github-token` in github-secret

#### 4. Prerequisites Validation
- **SSH Access**: Verify GitHub SSH connectivity and keys
- **Kubernetes Access**: Validate kubectl and cluster connectivity  
- **Secret Verification**: Ensure github-secret exists in target namespace
- **Namespace Management**: Create target namespace if missing

#### 5. Cleanup and Preparation
- **Local Cleanup**: Remove existing CR files, reuse persistent git directories
- **Namespace Cleanup**: Delete existing VNA CR from target namespace (full mode only)
- **Repository Management**: Clone repositories once, then fetch/pull updates on subsequent runs
- **Conflict Resolution**: Handle git push conflicts with pull/rebase or force push

### Technical Requirements

#### 1. SSH Configuration
- **Mandatory**: All git operations use SSH URLs
- **Key Management**: User's SSH keys must be configured for GitHub access
- **Repository Access**: SSH access to both source and target repositories

#### 2. Namespace Transformations
Apply the following transformations to all YAML files:
- `service.namespace=rpvna` → `service.namespace={target_namespace}`
- `namespace: rpvna` → `namespace: {target_namespace}`
- `rpvna-` → `{target_namespace}-` (resource prefixes)
- `/var/log/rp/vna/rpvna` → `/var/log/rp/vna/{target_namespace}`

#### 3. File-Specific Processing
- **rp-vna-common-config.yaml**: Normalize OTLP endpoint ports to 4317
- **rp-vna-common-env.yaml**: Ensure DICOM cache enabled
- **rp-vna-db-env.yaml**: Apply database host mappings for target namespaces

#### 4. Database Configuration Mapping
For `ac001001` namespace:
- Default DB: `rpvna-ac001-default-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com`
- Volatile DB: `rpvna-ac001-volatile-pgdb-proxy.proxy-cb4o8sm06f6f.us-east-1.rds.amazonaws.com`
- Database names: Change `loadprimary/loadsecondary` to `postgres`

#### 5. User Experience
- **Default Confirmation**: Press Enter = Yes (Y/n prompt)
- **Clear Messaging**: Comprehensive status messages and error handling
- **Help Documentation**: Complete usage examples and prerequisites

### Operational Modes

#### 1. Full Deployment Mode (Default)
1. Clean up local files and directories
2. **Delete existing VNA CR** from target namespace
3. Verify github-secret exists and detect secretKey
4. Pull/generate VNA CR from source namespace
5. Sync ALL configs to target GitHub repository
6. Deploy VNA CR to target Kubernetes namespace
7. Wait for deployment readiness

#### 2. Dry-Run Mode (`--dry-run`)
1. Clean up local files and directories  
2. **Skip namespace cleanup** (preserve existing VNA CR)
3. Verify github-secret exists and detect secretKey
4. Pull/generate VNA CR from source namespace
5. Sync ALL configs to target GitHub repository
6. **Skip Kubernetes deployment**
7. Provide manual deployment instructions

### Script Parameters
```bash
Usage: ./redeploy-vna.sh [OPTIONS] [SOURCE_NAMESPACE] [TARGET_NAMESPACE] [TARGET_BRANCH]

Options:
  --dry-run          Sync configs and create VNA CR but don't deploy to cluster
  -h, --help         Show help message

Arguments:
  SOURCE_NAMESPACE   Source namespace to copy from (default: rpvna)
  TARGET_NAMESPACE   Target namespace to deploy to (default: ac001001)
  TARGET_BRANCH      Target git branch name (default: same as TARGET_NAMESPACE)
```

### Examples
```bash
# Default deployment: rpvna → ac001001
./redeploy-vna.sh

# Dry run with defaults
./redeploy-vna.sh --dry-run

# Custom target namespace
./redeploy-vna.sh rpvna ac001002

# Dry run with custom namespace  
./redeploy-vna.sh --dry-run rpvna ac001003
```

## Implementation Status

### Completed Features
- SSH-based git operations for all repository access
- Automatic VNA CR generation from source namespace using `kubectl neat`
- Dynamic github-secret key detection (token vs github-token)
- Comprehensive namespace transformation for all YAML files
- File-specific processing (OTLP endpoints, database configs, etc.)
- Smart git conflict resolution with pull/rebase and force push fallback
- Default-to-yes confirmation prompt (Enter = continue)
- Dry-run mode with selective cleanup
- Robust error handling and prerequisite validation
- Complete local and namespace cleanup before deployment
- Database host mapping for ac001001 namespace
- Defensive cleanup function to prevent unbound variable errors
- **Persistent repository clones**: Repositories are cloned in script directory and reused across runs

### Recent Fixes
- **Repository Target**: Fixed script pushing to wrong repository
- **Git Conflicts**: Added pull/rebase before push with force push fallback
- **File Paths**: Fixed CR file path resolution in deployment function
- **Variable Scope**: Made cleanup function defensive against unbound variables
- **Persistent Repositories**: Changed from temporary directories to persistent clones for better performance and debugging
- **Complete Repository Reset**: Target repository branch is completely cleared and rebuilt from source to ensure exact match
- **Source Protection**: Added safeguards to never modify source repository (read-only operations)
- **File Structure Verification**: Added comprehensive verification that all required VNA files are present

### Key Design Decisions
- **SSH-Only**: All git operations use SSH for security and simplicity
- **Complete Sync**: Copy ALL files from source to maintain full consistency
- **Complete Reset**: Target repository branch is completely cleared and rebuilt from source
- **Source Protection**: Source repository is treated as read-only, never modified
- **Automatic CR Pull**: Generate source CR from live namespace for accuracy
- **Namespace-Aware**: Comprehensive transformations for clean separation
- **Defensive Programming**: Robust error handling and graceful degradation
- **Structure Verification**: Comprehensive checks ensure all VNA operator required files are present

## Prerequisites
- SSH keys configured for GitHub access to both repositories
- kubectl configured and connected to target Kubernetes cluster
- Access to source namespace (`rpvna`) for VNA CR extraction
- github-secret must exist in target namespace with either `token` or `github-token` key
- kubectl-neat plugin recommended (optional, falls back to raw kubectl output)

## Repository Structure
```
redeploy-vna/
├── redeploy-vna.sh          # Main deployment script
├── rpvna-dev.yaml           # Source VNA CR (auto-generated if missing)
├── {target}-vna.yaml        # Generated target VNA CR
├── rpvna-source-config/     # Persistent clone of source repository
├── ac001001-target-config/  # Persistent clone of target repository
└── README.md                # This documentation
```

## Future Considerations
- Support for additional target namespaces with custom database mappings
- Configuration validation before deployment
- Rollback capabilities
- Integration with CI/CD pipelines
- Metrics and logging enhancements