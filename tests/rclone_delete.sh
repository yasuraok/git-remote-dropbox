#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 2 ]]; then
    echo "usage: rclone_delete.sh <remote> <repo_path>"
    exit 2
fi
REMOTE=$1
REPO_PATH=$2
# Ensure remote:path form
TARGET="${REMOTE}:${REPO_PATH}"
rclone purge "$TARGET"
