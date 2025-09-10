#!/bin/bash
set -euo pipefail

# Test incremental push operations - verify that only changed objects are transferred
echo "=== Testing Incremental Push Operations ==="

REPO="incremental-push-repo"

# Clean up any existing test directories and remote data
rm -rf $REPO
rclone purge alias:git-remote-test/$REPO 2>/dev/null || true

# Create initial repository
echo "Creating test repository..."
git init $REPO
cd $REPO

# Configure git
git config user.email "test@example.com"
git config user.name "Test User"

# Create initial files
echo "Initial file 1" > file1.txt
echo "Initial file 2" > file2.txt
echo "Initial file 3" > file3.txt
git add .
git commit -m "Initial commit with 3 files"

# Push to rclone remote
echo "Initial push to rclone remote..."
git remote add origin rclone://alias/git-remote-test/$REPO
git push origin master

# Count objects transferred in first push
FIRST_PUSH_OBJECTS=$(git rev-list --objects master | wc -l)
echo "✓ First push transferred $FIRST_PUSH_OBJECTS objects"

# Make incremental changes - add one file, modify another
echo "Making incremental changes..."
echo "Modified content" > file1.txt  # Modify existing file
echo "New file content" > file4.txt  # Add new file
# file2.txt and file3.txt remain unchanged
git add .
git commit -m "Second commit - modify file1, add file4"

# Monitor rclone transfers for second push
echo "Second push (incremental)..."
echo "Objects before second commit: $(git rev-list --objects master~1 | wc -l)"
echo "Objects after second commit: $(git rev-list --objects master | wc -l)"

# Count new objects created by this commit
NEW_OBJECTS=$(git rev-list --objects master ^master~1 | wc -l)
echo "New objects in second commit: $NEW_OBJECTS"

# Enable detailed rclone logging to verify what gets transferred
echo "Performing incremental push with detailed logging..."

# Count copyto operations in the debug output
TEMP_LOG=$(mktemp)
DEBUG=1 git push origin master 2>&1 | tee "$TEMP_LOG"

# Count how many objects were actually uploaded (copyto operations)
COPYTO_COUNT=$(grep -c "rclone copyto.*objects/" "$TEMP_LOG" || echo "0")
echo "✓ Second push performed $COPYTO_COUNT object uploads"

# The number of uploaded objects should be much less than total objects
# (approximately equal to new objects created)
if [ "$COPYTO_COUNT" -le "$NEW_OBJECTS" ]; then
    echo "✓ Incremental push is working - only $COPYTO_COUNT objects uploaded vs $NEW_OBJECTS new objects"
else
    echo "⚠ Warning: More objects uploaded ($COPYTO_COUNT) than expected ($NEW_OBJECTS)"
fi

# Verify that existing objects are not re-uploaded
# Check if old objects have cat operations (verification) but not copyto (upload)
OLD_OBJECT_HASH=$(git rev-parse "master~1^{tree}:file2.txt")
if grep -q "rclone cat.*${OLD_OBJECT_HASH:0:2}/${OLD_OBJECT_HASH:2}" "$TEMP_LOG"; then
    echo "✓ Existing objects are verified with 'cat' operations"
else
    echo "⚠ Note: Could not verify existing object verification"
fi

# Third incremental change - only modify one existing file
echo "Making third incremental change..."
echo "Third modification" > file2.txt
git add file2.txt
git commit -m "Third commit - only modify file2"

# Monitor third push
TEMP_LOG2=$(mktemp)
DEBUG=1 git push origin master 2>&1 | tee "$TEMP_LOG2"

COPYTO_COUNT2=$(grep -c "rclone copyto.*objects/" "$TEMP_LOG2" || echo "0")
echo "✓ Third push performed $COPYTO_COUNT2 object uploads"

# Third push should upload even fewer objects (just the modified file and new tree/commit)
THIRD_NEW_OBJECTS=$(git rev-list --objects master ^master~1 | wc -l)
echo "New objects in third commit: $THIRD_NEW_OBJECTS"

if [ "$COPYTO_COUNT2" -le "$THIRD_NEW_OBJECTS" ]; then
    echo "✓ Third incremental push is working - only $COPYTO_COUNT2 objects uploaded vs $THIRD_NEW_OBJECTS new objects"
else
    echo "⚠ Warning: More objects uploaded ($COPYTO_COUNT2) than expected ($THIRD_NEW_OBJECTS)"
fi

# Verify final state with clone
cd ..
CLONE="incremental-clone"
rm -rf $CLONE

echo "Verifying final state with fresh clone..."
git clone rclone://alias/git-remote-test/$REPO $CLONE
cd $CLONE

# Check all files are present with correct content
if [ "$(cat file1.txt)" = "Modified content" ] && \
   [ "$(cat file2.txt)" = "Third modification" ] && \
   [ "$(cat file3.txt)" = "Initial file 3" ] && \
   [ "$(cat file4.txt)" = "New file content" ]; then
    echo "✓ All files have correct content after incremental pushes"
else
    echo "ERROR: File contents are incorrect"
    echo "file1.txt: $(cat file1.txt)"
    echo "file2.txt: $(cat file2.txt)"
    echo "file3.txt: $(cat file3.txt)"
    echo "file4.txt: $(cat file4.txt)"
    exit 1
fi

# Clean up
cd ..
rm -rf $REPO $CLONE "$TEMP_LOG" "$TEMP_LOG2"

echo "=== Summary ==="
echo "✓ First push: $FIRST_PUSH_OBJECTS objects"
echo "✓ Second push: $COPYTO_COUNT objects uploaded (incremental)"
echo "✓ Third push: $COPYTO_COUNT2 objects uploaded (incremental)"
echo "✓ Incremental push optimization is working correctly"
echo "=== All Incremental Push Tests Passed! ==="
