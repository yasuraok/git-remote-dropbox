#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# default remote name to 'alias' if not provided
export RCLONE_REMOTE="${RCLONE_REMOTE:-alias}"

section() {
    printf '\e[33m%s\e[0m\n' "$*"
}

fail() {
    printf '\e[31m  fail: %s\e[0m\n' "$*"
    exit 1
}

ok() {
    printf '\e[32m  ...ok\e[0m\n'
}

info() {
    printf '%s\n' "$*"
}

check_env() {
    if [[ ! -f /.dockerenv ]]; then
        if [[ "${CI}" != true ]]; then
            echo "error: `basename \"$0\"` should only be used in a Vagrant VM or in CI"
            exit 2
        fi
    fi
    # rclone tests do not require DROPBOX_TOKEN
}

setup_env() {
    export GIT_AUTHOR_EMAIL=author@example.com
    export GIT_AUTHOR_NAME='Author'
    export GIT_COMMITTER_EMAIL=committer@example.com
    export GIT_COMMITTER_NAME='Committer'
    # Do not set global git config here; tests will set repo-local config after git init
    local RANDOM_STR
    RANDOM_STR=$(python3 -c "import random, string; print(''.join(random.choices(string.ascii_letters, k=16)))")
    REPO_DIR="git-remote-dropbox-test/${RANDOM_STR}"
    TMP_DIR=$(mktemp -d)
    cd ${TMP_DIR}
    # No PATH mutation or debug output here — tests should be run in a controlled env
    # create remote directory for tests so pushes have a place to land
    rclone mkdir "${RCLONE_REMOTE}:${REPO_DIR}" || true
    trap cleanup EXIT
}

cleanup() {
    info 'cleaning up'
    if [[ -n "${TMP_DIR}" ]]; then
        rm -rf ${TMP_DIR}
    fi
    if [[ -n "${REPO_DIR}" ]]; then
        "${BASEDIR}/rclone_delete.sh" "${RCLONE_REMOTE}" "${REPO_DIR}"
    fi
}

test_run() {
    if [[ "${DEBUG}" == "0" ]]; then
        (eval "$*") >/dev/null 2>&1
    else
        (eval "$*")
    fi
}

test_expect_success() {
    test_run "$@"
    ret=$?
    if [[ "$ret" != "0" ]]; then
        fail "command $* returned non-zero exit status $ret"
    fi
}
