#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BASEDIR}/test-lib-rclone.sh"

check_env

# minimal setup that mirrors test-lib behavior
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
REPO_DIR="git-remote-dropbox-test/branches$(date +%s%N)"

echo "branch operations test"

# Create remote directory
rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR}" || true

# Create test repo
mkdir repo1
cd repo1
git init >/dev/null
# repo-local config
git config user.email "author@example.com"
git config user.name "Author"

# Initial commit on master
echo "initial content" > file0.txt
git add file0.txt
git commit -m "initial commit"

REMOTE_URL="rclone://${RCLONE_REMOTE}/${REPO_DIR}"
echo "> git remote add origin \"${REMOTE_URL}\""
git remote add origin "${REMOTE_URL}"

echo "> git push -u origin master"
git push -u origin master

# Create and switch to feature branch
echo "> git checkout -b feature/test"
git checkout -b feature/test

# Add content to feature branch
echo "feature content" > feature.txt
git add feature.txt
git commit -m "add feature"

echo "> git push -u origin feature/test"
git push -u origin feature/test

# Create another branch from master
echo "> git checkout master"
git checkout master
echo "> git checkout -b dev"
git checkout -b dev

# Add different content to dev branch
echo "dev content" > dev.txt
echo "modified initial" > file0.txt
git add dev.txt file0.txt
git commit -m "dev changes"

echo "> git push -u origin dev"
git push -u origin dev

# Test clone and branch switching
cd "$TMPDIR"
echo "> git clone \"${REMOTE_URL}\" repo2"
git clone "${REMOTE_URL}" repo2
cd repo2

echo "> test default branch (master)"
test "$(git branch --show-current)" = "master"
test -f file0.txt
test "$(cat file0.txt)" = "initial content"
test ! -f feature.txt
test ! -f dev.txt

echo "> git checkout feature/test"
git checkout feature/test
test "$(git branch --show-current)" = "feature/test"
test -f file0.txt
test -f feature.txt
test "$(cat feature.txt)" = "feature content"
test ! -f dev.txt

echo "> git checkout dev"
git checkout dev
test "$(git branch --show-current)" = "dev"
test -f file0.txt
test "$(cat file0.txt)" = "modified initial"
test -f dev.txt
test "$(cat dev.txt)" = "dev content"
test ! -f feature.txt

echo "> git checkout master"
git checkout master
test "$(git branch --show-current)" = "master"
test -f file0.txt
test "$(cat file0.txt)" = "initial content"
test ! -f feature.txt
test ! -f dev.txt

# Test branch list
echo "> git branch -a"
git branch -a | grep -q "master"
git branch -a | grep -q "remotes/origin/master"
git branch -a | grep -q "remotes/origin/feature/test"
git branch -a | grep -q "remotes/origin/dev"

echo "done"
echo "  ...ok"

# Cleanup
cd /
rm -rf "${TMPDIR}"
"${BASEDIR}/rclone_delete.sh" "${RCLONE_REMOTE}" "${REPO_DIR}"
