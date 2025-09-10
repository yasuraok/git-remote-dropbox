#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BASEDIR}/test-lib-rclone.sh"

check_env

# minimal setup that mirrors test-lib behavior
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
REPO_DIR="git-remote-dropbox-test/binary$(date +%s%N)"

echo "binary file test"

# Create remote directory
rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR}" || true

# Create test repo
mkdir repo1
cd repo1
git init >/dev/null
git config user.email "author@example.com"
git config user.name "Author"

echo "> create binary files"
# Create a small binary file (PNG header + some binary data)
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x10\x00\x00\x00\x10\x08\x02\x00\x00\x00\x90\x91h6' > small.png
echo -n "more binary data" >> small.png
for i in {1..100}; do
    printf '\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f' >> small.png
done

# Create another binary file with different content
dd if=/dev/urandom of=random.bin bs=1024 count=2 2>/dev/null || {
    # Fallback if /dev/urandom not available
    for i in {1..2048}; do
        printf '\x%02x' $((RANDOM % 256)) >> random.bin
    done
}

# Create a text file for comparison
echo "This is a text file for comparison" > text.txt

# Add initial text file
git add text.txt
git commit -m "initial commit with text"

REMOTE_URL="rclone://${RCLONE_REMOTE}/${REPO_DIR}"
echo "> git remote add origin \"${REMOTE_URL}\""
git remote add origin "${REMOTE_URL}"

echo "> git push -u origin master"
git push -u origin master

echo "> add binary files"
git add small.png random.bin
git commit -m "add binary files"

echo "> git push"
git push

echo "> modify binary files"
# Append to both binary files
printf '\xFF\xFE\xFD\xFC' >> small.png
printf '\xAA\xBB\xCC\xDD' >> random.bin
# Also modify text file
echo "Modified text content" > text.txt

git add small.png random.bin text.txt
git commit -m "modify all files (binary and text)"

echo "> git push"
git push

# Test clone to verify binary files are properly handled
cd "$TMPDIR"
echo "> git clone \"${REMOTE_URL}\" repo2"
git clone "${REMOTE_URL}" repo2
cd repo2

# Configure git for this repo
git config user.email "author@example.com"
git config user.name "Author"

echo "> verify binary files after clone"
test -f small.png
test -f random.bin
test -f text.txt

# Check that binary files have correct sizes (approximate)
SMALL_SIZE=$(wc -c < small.png)
RANDOM_SIZE=$(wc -c < random.bin)

echo "small.png size: $SMALL_SIZE bytes"
echo "random.bin size: $RANDOM_SIZE bytes"

# Verify sizes are reasonable
test "$SMALL_SIZE" -gt 1000  # Should be > 1000 bytes
test "$RANDOM_SIZE" -gt 2000  # Should be > 2000 bytes

# Verify text file content
test "$(cat text.txt)" = "Modified text content"

# Check git recognizes them as binary
echo "> git show --name-status HEAD"
git show --name-status HEAD

# Verify binary content hasn't been corrupted by checking specific bytes
echo "> verify PNG header"
head -c 8 small.png | od -tx1 | grep -q "89 50 4e 47"  # PNG header

echo "> create and push a larger binary file"
dd if=/dev/zero of=large.bin bs=1024 count=10 2>/dev/null || {
    # Fallback for systems without dd
    for i in {1..10240}; do
        printf '\x00' >> large.bin
    done
}
git add large.bin
git commit -m "add large binary file"
git push

# Pull from first repo to verify sync
cd "$TMPDIR/repo1"
git config user.email "author@example.com"  # Configure git for this repo too
git config user.name "Author"
echo "> git pull"
git pull

echo "> verify large binary file synced"
test -f large.bin
LARGE_SIZE=$(wc -c < large.bin)
echo "large.bin size: $LARGE_SIZE bytes"
test "$LARGE_SIZE" -ge 10240  # Should be >= 10KB

echo "done"
echo "  ...ok"

# Cleanup
cd /
rm -rf "${TMPDIR}"
"${BASEDIR}/rclone_delete.sh" "${RCLONE_REMOTE}" "${REPO_DIR}"
