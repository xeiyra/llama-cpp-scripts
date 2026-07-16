#!/usr/bin/env bash

set -euo pipefail

# ------------------------------------------------------------------
# 0. Variables (override on the command line if desired)
# ------------------------------------------------------------------
export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export PATH=$PATH:/opt/rocm/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/rocm/lib
export GGML_CCACHE=OFF

# ------------------------------------------------------------------
# 1. Variables (override on the command line if desired)
# ------------------------------------------------------------------

# .env loader (optional) — reads simple KEY=value pairs from a .env
# file in the same directory as this script, without sourcing/
# executing it. Only sets a variable if it isn't already set in the
# real environment, so `ROOT_DIR=/foo ./install-llama_cpp.sh` still
# overrides whatever is in .env.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
        key="${key#"${key%%[![:space:]]*}"}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        key="${key%"${key##*[![:space:]]}"}"
        key="${key#"${key%%[![:space:]]*}"}"
        value="${value%%[[:space:]]#*}"  # strip an inline trailing comment (space + # onward)
        value="${value%"${value##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        value="${value/#\~/$HOME}"  # leading ~ -> $HOME
        while [[ "$value" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]]; do
            var="${BASH_REMATCH[1]}"
            value="${value//${BASH_REMATCH[0]}/${!var:-}}"
        done
        if [[ -z "${!key:-}" ]]; then
            declare "$key=$value"
        fi
    done < "$ENV_FILE"
fi

ROOT_DIR="${ROOT_DIR:-$(pwd)}"    # defaults to cwd if not set via .env or environment
CLONE_DIR="${CLONE_DIR:-${ROOT_DIR}/llama.cpp}"        # source only — safe to delete/re-clone
                                          # Treated as a disposable, machine-managed checkout.
                                          # Do not hand-edit files here — `git pull` runs on this
                                          # dir and may clobber or conflict with local changes,
                                          # and a re-clone would wipe them with no warning.
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build}"            # current/live build — outside the repo
BUILDS_ARCHIVE_DIR="${BUILDS_ARCHIVE_DIR:-${ROOT_DIR}/builds}"  # versioned snapshots — outside the repo

# Hardware/Build Settings
BUILD_TYPE="${BUILD_TYPE:-Release}"                # Release/Debug etc.
GGML_HIP="${GGML_HIP:-ON}"          # Whether to use ROCm/HIP

# Git
ALLOW_DIRTY=${ALLOW_DIRTY:-0}       # Set to 1 to bypass `git pull` confirmation if
                                    # hand-edited files found in CLONE_DIR

# ------------------------------------------------------------------
# 2. Environment sanity checks
# ------------------------------------------------------------------
command -v git     >/dev/null || { echo "❌ git not found"; exit 1; }
command -v cmake   >/dev/null || { echo "❌ cmake not found"; exit 1; }
command -v ninja   >/dev/null || { echo "❌ ninja not found"; exit 1; }
# Only check for hipconfig if we intend to use HIP
if [ "$GGML_HIP" = "ON" ]; then
    command -v rocminfo >/dev/null || { echo "❌ ROCm not found"; exit 1; }
fi

# ------------------------------------------------------------------
# 2b. Warn about clone directory hygiene before touching anything
# ------------------------------------------------------------------
# CLONE_DIR is a disposable, machine-managed source checkout — this
# script runs `git pull` on it and may re-clone it from scratch.
# Do NOT hand-edit files inside CLONE_DIR (patches, local tweaks, etc.):
#   - `git pull` can silently conflict with or overwrite local changes
#   - a future re-clone would wipe them entirely with no warning
# If you need local modifications, keep them in a fork/branch you control
# and change the clone URL below, or apply patches from a script step
# instead of editing files by hand.
#
# Set ALLOW_DIRTY=1 to skip this check (e.g. for non-interactive/CI runs).
if [ -d "${CLONE_DIR}/.git" ] && [ -n "$(git -C "$CLONE_DIR" status --porcelain 2>/dev/null)" ]; then
    if [ "${ALLOW_DIRTY:-0}" = "1" ]; then
        echo "NOTE: ${CLONE_DIR} has local uncommitted changes; continuing (ALLOW_DIRTY=1)." >&2
    else
        echo "⚠️  WARNING: ${CLONE_DIR} has local uncommitted changes." >&2
        echo "    This script will run 'git pull' on it, which may overwrite or conflict" >&2
        echo "    with those changes. CLONE_DIR is meant to be a disposable checkout —" >&2
        echo "    do not hand-edit files in it." >&2
        echo >&2
        read -r -p "Continue anyway? [y/N] " confirm
        case "$confirm" in
            [yY][eE][sS]|[yY]) ;;
            *) echo "Aborted."; exit 1 ;;
        esac
    fi
fi

# ------------------------------------------------------------------
# 3. Clone or update the repository (archiving the old build first)
# ------------------------------------------------------------------
if [ -d "${CLONE_DIR}/.git" ]; then
    echo "--- Checking existing llama.cpp clone ---"

    # Capture the version BEFORE pulling — this is the version the
    # current $BUILD_DIR/bin (if any) was actually compiled from.
    OLD_VERSION="$(git -C "$CLONE_DIR" describe --tags --always --dirty 2>/dev/null || git -C "$CLONE_DIR" rev-parse --short HEAD)"

    if [ -d "${BUILD_DIR}/bin" ]; then
        ARCHIVE_PATH="${BUILDS_ARCHIVE_DIR}/${OLD_VERSION}"
        if [ -d "$ARCHIVE_PATH" ]; then
            echo "--- build ${OLD_VERSION} already archived, skipping ---"
        else
            echo "--- Archiving current build as version ${OLD_VERSION} ---"
            mkdir -p "$ARCHIVE_PATH"
            cp -r "${BUILD_DIR}/bin/." "$ARCHIVE_PATH/"
        fi
    else
        echo "--- No existing build to archive (first run) ---"
    fi

    echo "--- Updating llama.cpp ---"
    git -C "$CLONE_DIR" pull
else
    echo "--- Cloning llama.cpp ---"
    git clone https://github.com/ggml-org/llama.cpp.git "$CLONE_DIR"
fi

# ------------------------------------------------------------------
# 4. Configure with CMake
# ------------------------------------------------------------------
echo "--- Configuring Build ---"

# Determine if we are building for HIP or CPU
if [ "$GGML_HIP" = "ON" ]; then
  HIP_FLAG="ON"
else
  HIP_FLAG="OFF"
fi

export ROCM_PATH=/opt/rocm
export HIPCXX="$(hipconfig -l)/clang"
export HIP_PATH="$(hipconfig -R)"

export CMAKE_PREFIX_PATH="/opt/rocm/lib/cmake:/opt/rocm:${CMAKE_PREFIX_PATH:-}"
export CMAKE_MODULE_PATH="/opt/rocm/lib/cmake:${CMAKE_MODULE_PATH:-}"
export PATH="/opt/rocm/bin:$PATH"
export LD_LIBRARY_PATH="/opt/rocm/lib:$LD_LIBRARY_PATH"

# Source (-S) is the repo; build output (-B) lives outside it entirely.
cmake -S "$CLONE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DGGML_HIP=$HIP_FLAG \
  -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=OpenBLAS \
  -DGGML_LTO=ON \
  -DGGML_NATIVE=ON \
  -DLLAMA_CURL=ON

# Capture the cache listing ONCE. Piping cmake straight into `grep -q`
# causes grep to close the pipe as soon as it finds a match, which sends
# cmake a SIGPIPE and makes it exit 141. With `pipefail` that 141 becomes
# the pipeline's exit status even though grep succeeded, producing a false
# "HIP backend was not enabled" error. Capturing to a variable avoids the
# live pipe entirely.
CACHE_LIST="$(cmake -LA -N "$BUILD_DIR")"

echo
echo "===== Enabled backends ====="
echo "$CACHE_LIST" | grep '^GGML_'

if ! grep -q '^GGML_HIP:BOOL=ON$' <<< "$CACHE_LIST"; then
    echo
    echo "ERROR: HIP backend was not enabled."
    exit 1
fi

# ------------------------------------------------------------------
# 5. Build
# ------------------------------------------------------------------
echo "--- Starting Build ---"
# We don't need --parallel here because we are using Ninja!
cmake --build "$BUILD_DIR"


# ------------------------------------------------------------------
# 6. Optional install step
# ------------------------------------------------------------------
# Uncomment if you want to drop the binaries into /usr/local:
# cmake --install "$BUILD_DIR" --prefix /usr/local

NEW_VERSION="$(git -C "$CLONE_DIR" describe --tags --always --dirty 2>/dev/null || git -C "$CLONE_DIR" rev-parse --short HEAD)"
echo "✅ Build finished successfully!"
echo "Version: ${NEW_VERSION}"
echo "Binaries are located in: ${BUILD_DIR}/bin/"
echo "Previous versioned builds are archived under: ${BUILDS_ARCHIVE_DIR}/"
