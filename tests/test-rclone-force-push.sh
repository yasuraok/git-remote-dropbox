#!/bin/bash
set -euo pipefail

# Test force-push operations with rclone remote
echo "=== Testing Force-Push Operations ==="

REPO="force-push-repo"
CLONE="force-push-clone"

# Clean up any existing test directories and remote data
rm -rf $REPO $CLONE
rclone purge alias:git-remote-test/$REPO 2>/dev/null || true

# Create initial repository
echo "Creating test repository..."
git init $REPO
cd $REPO

# Configure git
git config user.email "test@example.com"
git config user.name "Test User"

# Create initial file
echo "Initial content" > file.txt
git add file.txt
git commit -m "Initial commit"

# Push to rclone remote
echo "Initial push to rclone remote..."
git remote add origin rclone://alias/git-remote-test/$REPO
git push origin master

cd ..

# Create clone to work in parallel
echo "Cloning repository..."
git clone rclone://alias/git-remote-test/$REPO $CLONE
cd $CLONE

# Configure git
git config user.email "test@example.com"
git config user.name "Test User"

# Make conflicting change in clone
echo "Change from clone" > file.txt
git add file.txt
git commit -m "Change from clone"
git push origin master

cd ../$REPO

# Make conflicting change in original repo
echo "Change from original" > file.txt
git add file.txt
git commit -m "Change from original"

# This should fail with non-fast-forward
echo "Testing non-fast-forward push (should fail)..."
if git push origin master 2>/dev/null; then
    echo "ERROR: Non-fast-forward push should have failed"
    exit 1
else
    echo "✓ Non-fast-forward push correctly failed"
fi

# Test force push
echo "Testing force push..."
git push --force origin master
echo "✓ Force push succeeded"

# Verify clone sees the forced changes
cd ../$CLONE
git fetch origin
git reset --hard origin/master

if [ "$(cat file.txt)" = "Change from original" ]; then
    echo "✓ Force push overwrote remote correctly"
else
    echo "ERROR: Force push did not overwrite remote"
    cat file.txt
    exit 1
fi

# Test force push with divergent history
echo "Testing force push with completely divergent history..."
cd ../$REPO

# Create new branch from earlier point
git reset --hard HEAD~1
echo "Completely different content" > different.txt
rm file.txt
git add -A
git commit -m "Completely different commit"

# Force push this divergent history
git push --force origin master
echo "✓ Force push with divergent history succeeded"

# Verify the change
cd ../$CLONE
git fetch origin
git reset --hard origin/master

if [ -f different.txt ] && [ ! -f file.txt ]; then
    echo "✓ Divergent history force push worked correctly"
    echo "Content: $(cat different.txt)"
else
    echo "ERROR: Divergent history not applied correctly"
    ls -la
    exit 1
fi

cd ..
rm -rf $REPO $CLONE

echo "=== All Force-Push Tests Passed! ==="
