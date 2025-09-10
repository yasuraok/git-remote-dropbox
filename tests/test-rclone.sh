#!/usr/bin/env bash
set -euo pipefail

# Consolidated test runner for rclone-backed tests
# This collects the individual test files into one ordered script so
# running the full suite is less noisy.

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BASEDIR}/test-lib-rclone.sh"

check_env

DEBUG=${DEBUG:-0}

section "tests: consolidated start"

run_case() {
    echo
    section "Case: $1"
    shift
    echo "> $*"
    if [[ "$DEBUG" == "0" ]]; then
        (eval "$*") >/dev/null 2>&1
    else
        (eval "$*")
    fi
}

# Order: basic push/clone -> branches -> delete -> incremental -> binary -> force-push

section "basic push/pull and branch handling"
TMP_ROOT=$(mktemp -d)
pushd "$TMP_ROOT" >/dev/null

# Basic push/pull/clone from original test-rclone.sh (simplified)
REPO_DIR_BASE="git-remote-dropbox-test/basic-$(date +%s%N)"
rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR_BASE}" || true

mkdir repo1
cd repo1
git init >/dev/null
git config user.email "author@example.com"
git config user.name "Author"
git config init.defaultBranch master || true
echo "foo" > bar.txt
git add bar.txt
git commit -m 'Initial commit' >/dev/null
commit1=$(git rev-parse HEAD)
REMOTE_URL="rclone://${RCLONE_REMOTE}/${REPO_DIR_BASE}"
git remote add origin "$REMOTE_URL"
git push -u origin master

cd ..
git clone "$REMOTE_URL" repo2
cd repo2
# Ensure repo-local git identity for commits in the clone
git config user.email "author@example.com"
git config user.name "Author"
if [[ "$(git rev-parse --abbrev-ref HEAD)" != "master" ]]; then
    echo "fail: bad branch"
    exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$commit1" ]]; then
    echo "fail: bad commit"
    exit 1
fi
section "push and pull"
echo "qux" >> bar.txt
git commit -am 'Second commit' >/dev/null
commit2=$(git rev-parse HEAD)
git push
cd ../repo1
git pull
if [[ "$(git rev-parse HEAD)" != "$commit2" ]]; then
    echo "fail: bad commit after pull"
    exit 1
fi

# push branch
git branch -m 'develop'
echo "foo" > qux.txt
git add qux.txt
git commit -m 'Third commit' >/dev/null
commit3=$(git rev-parse HEAD)
git push -u origin develop

# fetch in clone
cd ../repo2
git fetch
git checkout -b develop -t origin/develop >/dev/null 2>&1 || true
if [[ "$(git rev-parse HEAD)" != "$commit3" ]]; then
    echo "fail: bad commit for develop"
    exit 1
fi

popd >/dev/null

section "branch operations"
TMP_ROOT=$(mktemp -d)
pushd "$TMP_ROOT" >/dev/null
REPO_DIR_BASE="git-remote-dropbox-test/branches-$(date +%s%N)"
rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR_BASE}" || true

mkdir repo1
cd repo1
git init >/dev/null
git config user.email "author@example.com"
git config user.name "Author"
echo "initial content" > file0.txt
git add file0.txt
git commit -m "initial commit"
REMOTE_URL="rclone://${RCLONE_REMOTE}/${REPO_DIR_BASE}"
git remote add origin "$REMOTE_URL"
git push -u origin master

# feature branch
git checkout -b feature/test
echo "feature content" > feature.txt
git add feature.txt
git commit -m "add feature"
git push -u origin feature/test

# dev branch
git checkout master
git checkout -b dev
echo "dev content" > dev.txt
echo "modified initial" > file0.txt
git add dev.txt file0.txt
git commit -m "dev changes"
git push -u origin dev

# clone and verify
cd ..
git clone "$REMOTE_URL" repo2
cd repo2
# Ensure repo-local git identity for commits in the clone
git config user.email "author@example.com"
git config user.name "Author"
if [[ "$(git branch --show-current)" != "master" ]]; then
    echo "fail: not on master"
    exit 1
fi
test -f file0.txt || (echo fail && exit 1)
git checkout feature/test
test -f feature.txt || (echo fail && exit 1)
git checkout dev
test -f dev.txt || (echo fail && exit 1)
git checkout master

popd >/dev/null

section "deletion handling"
TMP_ROOT=$(mktemp -d)
pushd "$TMP_ROOT" >/dev/null
REPO_DIR_BASE="git-remote-dropbox-test/delete-$(date +%s%N)"
rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR_BASE}" || true

mkdir repo1
cd repo1
git init >/dev/null
git config user.email "author@example.com"
git config user.name "Author"
echo "file 1 content" > file1.txt
echo "file 2 content" > file2.txt
echo "file 3 content" > file3.txt
git add file1.txt file2.txt file3.txt
git commit -m "initial commit with 3 files"
REMOTE_URL="rclone://${RCLONE_REMOTE}/${REPO_DIR_BASE}"
git remote add origin "$REMOTE_URL"
git push -u origin master

# delete and modify
rm file2.txt
echo "modified file 1 content" > file1.txt
git add file1.txt
git rm file2.txt
git commit -m "delete file2.txt and modify file1.txt"
git push

# verify via clone
cd ..
git clone "$REMOTE_URL" repo2
cd repo2
# Ensure repo-local git identity for commits in the clone
git config user.email "author@example.com"
git config user.name "Author"
test -f file1.txt || (echo fail && exit 1)
test ! -f file2.txt || (echo fail && exit 1)
test -f file3.txt || (echo fail && exit 1)
popd >/dev/null

section "incremental basic"
TMP_ROOT=$(mktemp -d)
pushd "$TMP_ROOT" >/dev/null
REPO_DIR_BASE="git-remote-dropbox-test/incremental-$(date +%s%N)"
rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR_BASE}" || true

mkdir repo1
cd repo1
git init >/dev/null
git config user.email "author@example.com"
git config user.name "Author"
echo "file0" > file0.txt
git add file0.txt
git commit -m "add file0" >/dev/null
git remote add origin "rclone://${RCLONE_REMOTE}/${REPO_DIR_BASE}"
git push -u origin master

# add files incrementally and push
for i in 1 2 3; do
    echo "file${i}" > file${i}.txt
    git add file${i}.txt
    git commit -m "add file${i}" >/dev/null
    git push
    # verify via clone/pull
    if [[ $i -eq 1 ]]; then
        git clone "rclone://${RCLONE_REMOTE}/${REPO_DIR_BASE}" repo2
        # set repo-local identity on the fresh clone
        git -C repo2 config user.email "author@example.com"
        git -C repo2 config user.name "Author"
    else
        (cd repo2 && git pull)
    fi
    test -f repo2/file${i}.txt || (echo fail && exit 1)
done
popd >/dev/null

section "binary files"
TMP_ROOT=$(mktemp -d)
pushd "$TMP_ROOT" >/dev/null
REPO_DIR_BASE="git-remote-dropbox-test/binary-$(date +%s%N)"
rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR_BASE}" || true

mkdir repo1
cd repo1
git init >/dev/null
git config user.email "author@example.com"
git config user.name "Author"

# small png
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > small.png
for i in {1..100}; do printf '\x00' >> small.png; done
dd if=/dev/urandom of=random.bin bs=1024 count=2 2>/dev/null || true
echo "This is a text file for comparison" > text.txt
git add text.txt
git commit -m "initial commit with text"
git remote add origin "rclone://${RCLONE_REMOTE}/${REPO_DIR_BASE}"
git push -u origin master

git add small.png random.bin
git commit -m "add binary files"
git push

# modify
printf '\xFF\xFE' >> small.png
printf '\xAA\xBB' >> random.bin
echo "Modified text content" > text.txt
git add small.png random.bin text.txt
git commit -m "modify all files (binary and text)"
git push

# clone and verify
cd ..
git clone "rclone://${RCLONE_REMOTE}/${REPO_DIR_BASE}" repo2
cd repo2
# Ensure repo-local git identity for commits in the clone
git config user.email "author@example.com"
git config user.name "Author"
test -f small.png || (echo fail && exit 1)
test -f random.bin || (echo fail && exit 1)
test -f text.txt || (echo fail && exit 1)
popd >/dev/null

section "force-push scenarios"
TMP_ROOT=$(mktemp -d)
pushd "$TMP_ROOT" >/dev/null
REPO_DIR_BASE="git-remote-dropbox-test/force-$(date +%s%N)"
rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR_BASE}" || true

REPO="repo"
CLONE="clone"
mkdir $REPO
cd $REPO
git init >/dev/null
git config user.email "test@example.com"
git config user.name "Test User"
echo "Initial content" > file.txt
git add file.txt
git commit -m "Initial commit"
git remote add origin "rclone://${RCLONE_REMOTE}/${REPO_DIR_BASE}"
git push origin master
cd ..
git clone "rclone://${RCLONE_REMOTE}/${REPO_DIR_BASE}" $CLONE
cd $CLONE
# Ensure repo-local git identity for commits in the clone
git config user.email "test@example.com"
git config user.name "Test User"
echo "Change from clone" > file.txt
git add file.txt
git commit -m "Change from clone"
git push origin master
cd ../$REPO
echo "Change from original" > file.txt
git add file.txt
git commit -m "Change from original"
if git push origin master 2>/dev/null; then
    echo "fail: non-fast-forward push should have failed"
    exit 1
fi
git push --force origin master
cd ../$CLONE
git fetch origin
git reset --hard origin/master
if [[ "$(cat file.txt)" != "Change from original" ]]; then
    echo "fail: force push did not apply"
    exit 1
fi

# divergent history
cd ../$REPO
git reset --hard HEAD~1
echo "Completely different content" > different.txt
rm -f file.txt
git add -A
git commit -m "Completely different commit"
git push --force origin master
cd ../$CLONE
git fetch origin
git reset --hard origin/master
if [[ -f different.txt && ! -f file.txt ]]; then
    echo "force-push divergent applied"
else
    echo "fail: force-push divergent failed"
    exit 1
fi
popd >/dev/null

section "tests: consolidated done"

echo
echo "All consolidated tests completed."
