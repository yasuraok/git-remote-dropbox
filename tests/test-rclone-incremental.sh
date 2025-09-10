#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BASEDIR}/test-lib-rclone.sh"

check_env

# minimal setup that mirrors test-lib behavior
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
REPO_DIR="git-remote-dropbox-test/incremental$(date +%s%N)"

section "incremental setup"
mkdir repo1
cd repo1
git init >/dev/null
# repo-local config
git config user.email "author@example.com"
git config user.name "Author"

auth() {
    echo "Author <author@example.com>"
}

# create remote dir
rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR}" || true

# Helper to run a command and fail with message
run_expect() {
    echo "> $*"
    if ! eval "$*"; then
        echo "FAIL: command failed: $*"
        exit 1
    fi
}

# initial commit
section "initial commit"
echo "file0" > file0.txt
git add file0.txt
git commit -m "add file0" >/dev/null
run_expect "git remote add origin \"rclone://${RCLONE_REMOTE}/${REPO_DIR}\""
run_expect "git push -u origin master"

# clone to verify
cd ..
run_expect "git clone \"rclone://${RCLONE_REMOTE}/${REPO_DIR}\" repo2"
cd repo2
run_expect "test -f file0.txt"
cd ../repo1

# incremental adds
for i in 1 2 3; do
    section "add file ${i}"
    echo "file${i}" > file${i}.txt
    git add file${i}.txt
    git commit -m "add file${i}" >/dev/null
    run_expect "git push"
    # verify in repo2 via pull
    cd ../repo2
    run_expect "git pull"
    run_expect "test -f file${i}.txt"
    cd ../repo1
done

section "done"
ok

