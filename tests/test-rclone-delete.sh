#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BASEDIR}/test-lib-rclone.sh"

check_env

# minimal setup that mirrors test-lib behavior
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
REPO_DIR="git-remote-dropbox-test/delete$(date +%s%N)"

echo "file deletion test"

# Create remote directory
rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR}" || true

# Create test repo with multiple files
mkdir repo1
cd repo1
git init >/dev/null
git config user.email "author@example.com"
git config user.name "Author"

# Initial commit with multiple files
echo "file 1 content" > file1.txt
echo "file 2 content" > file2.txt
echo "file 3 content" > file3.txt
git add file1.txt file2.txt file3.txt
git commit -m "initial commit with 3 files"

REMOTE_URL="rclone://${RCLONE_REMOTE}/${REPO_DIR}"
echo "> git remote add origin \"${REMOTE_URL}\""
git remote add origin "${REMOTE_URL}"

echo "> git push -u origin master"
git push -u origin master

# Delete one file and modify another
echo "> rm file2.txt"
rm file2.txt
echo "modified file 1 content" > file1.txt

# Commit the deletion and modification
echo "> git add file1.txt && git rm file2.txt"
git add file1.txt
git rm file2.txt
git commit -m "delete file2.txt and modify file1.txt"

echo "> git push"
git push

# Test clone to verify deletion was properly handled
cd "$TMPDIR"
echo "> git clone \"${REMOTE_URL}\" repo2"
git clone "${REMOTE_URL}" repo2
cd repo2

# Configure git for this repo
git config user.email "author@example.com"
git config user.name "Author"

echo "> verify files after clone"
test -f file1.txt
test ! -f file2.txt
test -f file3.txt
test "$(cat file1.txt)" = "modified file 1 content"
test "$(cat file3.txt)" = "file 3 content"

# Check git log shows both commits
echo "> git log --oneline"
git log --oneline | grep -q "delete file2.txt and modify file1.txt"
git log --oneline | grep -q "initial commit with 3 files"

echo "> add new file and delete another"
echo "new file content" > file4.txt
git add file4.txt
git commit -m "add file4.txt"

rm file3.txt
git rm file3.txt
git commit -m "delete file3.txt"

echo "> git push"
git push

# Pull from first repo to verify sync
cd "$TMPDIR/repo1"
echo "> git pull"
git pull

echo "> verify final state"
test -f file1.txt
test ! -f file2.txt
test ! -f file3.txt
test -f file4.txt
test "$(cat file1.txt)" = "modified file 1 content"
test "$(cat file4.txt)" = "new file content"

echo "done"
echo "  ...ok"

# Cleanup
cd /
rm -rf "${TMPDIR}"
"${BASEDIR}/rclone_delete.sh" "${RCLONE_REMOTE}" "${REPO_DIR}"
