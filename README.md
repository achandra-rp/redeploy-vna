# VNA Redeployment Script

This script automates the redeployment of VNA (Virtual Network Archive) from a source namespace to a target namespace. It synchronizes GitHub configurations and Kubernetes resources.

## Usage

```bash
# Default deployment: rpvna → ac001001
./redeploy-vna.sh

# Dry run with defaults
./redeploy-vna.sh --dry-run

# Custom target namespace
./redeploy-vna.sh rpvna ac001002
```

### Options

* `--dry-run`: Sync configs and create VNA CR but don't deploy to the cluster.
* `-h, --help`: Show help message.

### Arguments

* `SOURCE_NAMESPACE`: Source namespace to copy from (default: `rpvna`).
* `TARGET_NAMESPACE`: Target namespace to deploy to (default: `ac001001`).
* `TARGET_BRANCH`: Target git branch name (default: same as `TARGET_NAMESPACE`).

## Prerequisites

* SSH keys configured for GitHub access.
* `kubectl` configured and connected to the target Kubernetes cluster.
* Access to the source namespace (`rpvna`).
* `github-secret` must exist in the target namespace.
* `kubectl-neat` plugin is recommended.
