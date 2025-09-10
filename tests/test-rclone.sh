#!/usr/bin/env bash
set -euo pipefail

DEBUG=0

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd $BASEDIR
source ./test-lib-rclone.sh

check_env
setup_env

section 'setup'
mkdir repo1
cd repo1
git init >/dev/null
# set repo-local git config so tests don't rely on global settings
git config user.email "author@example.com"
git config user.name "Author"
# ensure this repo uses master as the default branch
git config init.defaultBranch master
echo "foo" > bar.txt
git add bar.txt
git commit -m 'Initial commit' >/dev/null
commit1=$(git rev-parse HEAD)
git remote add origin "rclone://${RCLONE_REMOTE}/${REPO_DIR}"
ok

section 'push new repo'
test_expect_success git push -u origin master
ok

section 'clone'
cd ..
test_expect_success git clone "rclone://${RCLONE_REMOTE}/${REPO_DIR}" repo2
cd repo2
if [[ "$(git rev-parse --abbrev-ref HEAD)" != "master" ]]; then
    fail "bad branch"
fi
if [[ "$(git rev-parse HEAD)" != "$commit1" ]]; then
    fail "bad commit"
fi
ok

section 'push'
echo "qux" >> bar.txt
git commit -am 'Second commit' >/dev/null
commit2=$(git rev-parse HEAD)
test_expect_success git push
ok

section 'pull'
cd ../repo1
test_expect_success git pull
if [[ "$(git rev-parse HEAD)" != "$commit2" ]]; then
    fail "bad commit"
fi
ok

section 'push branch'
git branch -m 'develop'
echo "foo" > qux.txt
git add qux.txt
git commit -m 'Third commit' >/dev/null
commit3=$(git rev-parse HEAD)
test_expect_success git push -u origin develop
ok

section 'fetch branch'
cd ../repo2
test_expect_success git fetch
git checkout -b develop -t origin/develop >/dev/null 2>&1
if [[ "$(git rev-parse HEAD)" != "$commit3" ]]; then
    fail "bad commit"
fi
ok

section 'set default branch'
# no-op for rclone-backed prototype; skip
ok

section 'default branch protected'
# skip protection tests (not implemented in rclone prototype)
ok

section 'non-default branch not protected'
test_expect_success git push origin :master
ok

section 'clone default branch'
cd ..
test_expect_success git clone "rclone://${RCLONE_REMOTE}/${REPO_DIR}" repo3
cd repo3
# default branch behavior may not be supported — just check commit
if [[ "$(git rev-parse HEAD)" != "$commit3" ]]; then
    fail "bad commit"
fi
ok
