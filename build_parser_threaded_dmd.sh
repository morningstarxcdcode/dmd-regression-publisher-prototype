#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin)
        HOST_GENERATED_DIR="osx"
        HOST_DMD_BIN_SUBDIR="bin"
        ;;
    Linux)
        HOST_GENERATED_DIR="linux"
        HOST_DMD_BIN_SUBDIR="bin64"
        ;;
    *)
        echo "Unsupported host OS for this helper: $HOST_OS" >&2
        exit 2
        ;;
esac

DMD_REPO="${DMD_REPO:-$SCRIPT_DIR/external/dmd}"
HOST_DMD="${HOST_DMD:-$SCRIPT_DIR/.locald/dmd-nightly/$HOST_GENERATED_DIR/$HOST_DMD_BIN_SUBDIR/dmd}"
BUILD_MODE="${BUILD_MODE:-debug}"
HOST_DFLAGS="${HOST_DFLAGS:--version=ParserParallelPrototype}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Builds a DMD binary with the ParserParallelPrototype version flag enabled.

Options:
  --dmd-repo <path>       DMD repo root (default: external/dmd)
  --host-dmd <path>       Host compiler path (default: .locald/dmd-nightly/osx/bin/dmd)
  --build-mode <name>     Build mode passed to make BUILD=<name> (default: debug)
  --host-dflags <flags>   HOST_DFLAGS value (default: -version=ParserParallelPrototype)
  --help                  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmd-repo) DMD_REPO="$2"; shift 2 ;;
        --host-dmd) HOST_DMD="$2"; shift 2 ;;
        --build-mode) BUILD_MODE="$2"; shift 2 ;;
        --host-dflags) HOST_DFLAGS="$2"; shift 2 ;;
        --help) usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$DMD_REPO" != /* ]]; then
    DMD_REPO="$(cd "$DMD_REPO" && pwd)"
fi

if [[ "$HOST_DMD" != /* ]]; then
    HOST_DMD="$(cd "$(dirname "$HOST_DMD")" && pwd)/$(basename "$HOST_DMD")"
fi

if [[ ! -d "$DMD_REPO" ]]; then
    echo "DMD repo not found: $DMD_REPO" >&2
    exit 2
fi

if [[ ! -x "$HOST_DMD" ]]; then
    echo "Host DMD not executable: $HOST_DMD" >&2
    exit 2
fi

make -C "$DMD_REPO" dmd \
    HOST_DMD="$HOST_DMD" \
    HOST_DFLAGS="$HOST_DFLAGS" \
    BUILD="$BUILD_MODE" \
    -j2

BIN_PATH="$DMD_REPO/generated/$HOST_GENERATED_DIR/$BUILD_MODE/64/dmd"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Build completed but binary not found at: $BIN_PATH" >&2
    exit 3
fi

echo "$BIN_PATH"
