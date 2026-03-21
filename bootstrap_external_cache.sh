#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACK="both"
CACHE_DIR="$SCRIPT_DIR/.cache/dmd-releases"
LATEST_SOURCE="snapshot"
DUB_CACHE_DIR="$SCRIPT_DIR/artifacts/cache/dub_pgo"
DUB_SLUG="dlang/dub"
SKIP_RELEASES=0
SKIP_DUB=0

usage() {
    cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Bootstraps the repo-local caches required for offline verification.

Options:
  --track <name>         latest20, compatible20, or both (default: both)
  --cache-dir <path>     Release archive cache directory
  --latest-source <m>    snapshot or refresh for latest20 resolution (default: snapshot)
  --dub-cache-dir <p>    Cache root for dlang/dub source
  --dub-slug <slug>      GitHub slug to clone for dub source (default: dlang/dub)
  --skip-releases        Do not populate release archives
  --skip-dub             Do not populate the dub source cache
  --help                 Show this help
EOF_USAGE
}

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --track) TRACK="$2"; shift 2 ;;
        --cache-dir) CACHE_DIR="$2"; shift 2 ;;
        --latest-source) LATEST_SOURCE="$2"; shift 2 ;;
        --dub-cache-dir) DUB_CACHE_DIR="$2"; shift 2 ;;
        --dub-slug) DUB_SLUG="$2"; shift 2 ;;
        --skip-releases) SKIP_RELEASES=1; shift ;;
        --skip-dub) SKIP_DUB=1; shift ;;
        --help) usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$TRACK" != "latest20" && "$TRACK" != "compatible20" && "$TRACK" != "both" ]]; then
    echo "--track must be one of: latest20, compatible20, both" >&2
    exit 1
fi

if [[ "$LATEST_SOURCE" != "snapshot" && "$LATEST_SOURCE" != "refresh" ]]; then
    echo "--latest-source must be one of: snapshot, refresh" >&2
    exit 1
fi

if [[ $SKIP_RELEASES -eq 0 ]]; then
    log "Bootstrapping release archive cache"
    "$SCRIPT_DIR/bench_releases.sh" \
        --track "$TRACK" \
        --cache-dir "$CACHE_DIR" \
        --latest-source "$LATEST_SOURCE" \
        --archive-source bootstrap \
        --prepare-cache-only
fi

if [[ $SKIP_DUB -eq 0 ]]; then
    log "Bootstrapping dub source cache"
    mkdir -p "$DUB_CACHE_DIR"
    local_repo="$DUB_CACHE_DIR/${DUB_SLUG//\//__}"
    if [[ -d "$local_repo/.git" ]]; then
        git -C "$local_repo" fetch --depth 1 origin '+refs/heads/*:refs/remotes/origin/*'
    else
        git clone --depth 1 "https://github.com/${DUB_SLUG}.git" "$local_repo"
    fi
fi
