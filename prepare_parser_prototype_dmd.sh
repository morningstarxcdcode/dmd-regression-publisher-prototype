#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/dlang/dmd}"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR/external/dmd}"
PATCH_PATH="${PATCH_PATH:-$SCRIPT_DIR/patches/external_dmd_parser_parallel_prototype.patch}"
REF="${REF:-4faeee39cf33c1e3491b7e1da83a71111f05606f}"

usage() {
    cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Prepare a reproducible DMD source checkout for the parser-threading prototype.

Options:
  --repo-url <url>     Upstream DMD git URL (default: https://github.com/dlang/dmd)
  --repo-dir <path>    Local checkout path (default: external/dmd)
  --ref <commit>       Pinned upstream commit to checkout
  --patch <path>       Patch to apply after checkout
  --help               Show this help
EOF_USAGE
}

log() {
    printf '[prepare-parser-prototype] %s\n' "$*" >&2
}

make_abs() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$PWD" "$path"
    fi
}

patch_applied() {
    git -C "$REPO_DIR" apply --reverse --check "$PATCH_PATH" >/dev/null 2>&1
}

repo_ready() {
    local head
    head="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
    [[ "$head" == "$REF" ]] && patch_applied
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --repo-dir) REPO_DIR="$2"; shift 2 ;;
        --ref) REF="$2"; shift 2 ;;
        --patch) PATCH_PATH="$2"; shift 2 ;;
        --help) usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

REPO_DIR="$(make_abs "$REPO_DIR")"
PATCH_PATH="$(make_abs "$PATCH_PATH")"

if [[ ! -f "$PATCH_PATH" ]]; then
    echo "Patch file not found: $PATCH_PATH" >&2
    exit 2
fi

export GIT_TERMINAL_PROMPT=0

if [[ -d "$REPO_DIR" ]]; then
    if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        echo "Repo directory exists but is not a git checkout: $REPO_DIR" >&2
        exit 2
    fi

    if [[ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ]]; then
        if repo_ready; then
            log "Existing checkout already matches pinned ref with patch applied: $REPO_DIR"
            printf '%s\n' "$REPO_DIR"
            exit 0
        fi
        echo "Existing checkout is dirty and does not match the pinned parser prototype state: $REPO_DIR" >&2
        exit 3
    fi
else
    mkdir -p "$(dirname "$REPO_DIR")"
    log "Cloning $REPO_URL into $REPO_DIR"
    CLONE_ARGS=(--no-checkout)
    if [[ "$REPO_URL" == http://* || "$REPO_URL" == https://* || "$REPO_URL" == ssh://* || "$REPO_URL" == git@*:* ]]; then
        CLONE_ARGS=(--filter=blob:none --no-checkout)
    fi
    git clone "${CLONE_ARGS[@]}" "$REPO_URL" "$REPO_DIR"
fi

git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
log "Fetching upstream refs"
git -C "$REPO_DIR" fetch origin --tags --prune

log "Checking out pinned ref $REF"
git -C "$REPO_DIR" checkout --detach "$REF"
git -C "$REPO_DIR" submodule sync --recursive
git -C "$REPO_DIR" submodule update --init --recursive

if patch_applied; then
    log "Patch is already applied at $(git -C "$REPO_DIR" rev-parse HEAD)"
    printf '%s\n' "$REPO_DIR"
    exit 0
fi

log "Verifying parser prototype patch"
git -C "$REPO_DIR" apply --check "$PATCH_PATH"

log "Applying parser prototype patch"
git -C "$REPO_DIR" apply "$PATCH_PATH"

log "Prepared parser prototype source at $(git -C "$REPO_DIR" rev-parse HEAD)"
printf '%s\n' "$REPO_DIR"
