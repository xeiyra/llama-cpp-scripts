#!/usr/bin/env bash

set -euo pipefail

# ==================================================================
# llama-server launcher
#
# Format: VALUE goes in the *_VALUE variable, ON/OFF in the
# matching *_ENABLED variable. If ENABLED="OFF", the flag is
# skipped entirely regardless of what VALUE is set to.
#
# NOTE: this script builds from bleeding-edge master, and some
# flags below occasionally change syntax upstream
# (flash-attn and numa in particular have changed shape before).
# If a flag errors out, run `"$BIN_PATH"/llama-server --help` and
# check that flag's current syntax before assuming the script is wrong.
# ==================================================================

# ------------------------------------------------------------------
# .env loader (optional) — reads simple KEY=value pairs from a .env
# file in the same directory as this script, without sourcing/
# executing it. Only sets a variable if it isn't already set in the
# real environment, so `FOO=bar ./launch-llama-server.sh` still
# overrides whatever is in .env.
# ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
        # Trim leading whitespace from key, skip blanks and comments
        key="${key#"${key%%[![:space:]]*}"}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        # Trim trailing/leading whitespace on key and value
        key="${key%"${key##*[![:space:]]}"}"
        key="${key#"${key%%[![:space:]]*}"}"
        value="${value%%[[:space:]]#*}"  # strip inline trailing comment (space + #)
        value="${value%"${value##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%\"}"; value="${value#\"}"   # strip quotes
        value="${value%\'}"; value="${value#\'}"
        value="${value//\\n/$'\n'}"                # \n in .env → real newlines (for multi-line values)
        value="${value/#\~/$HOME}"                  # leading ~ → $HOME
        while [[ "$value" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]]; do
            var="${BASH_REMATCH[1]}"
            value="${value//${BASH_REMATCH[0]}/${!var:-}}"  # expand ${VAR} / $VAR references
        done
        if [[ -z "${!key:-}" ]]; then
            declare "$key=$value"
        fi
    done < "$ENV_FILE"
fi

# Ensure exactly one trailing slash, regardless of whether .env or env var provides one
BIN_PATH="${BIN_PATH:-$HOME/ai-stack/engines/llama.cpp/build/bin}"          # the path to your llama.cpp binaries
BIN_PATH="${BIN_PATH%/}"      # strip any trailing slashes
BIN_PATH="$BIN_PATH/"         # add exactly one

# ------------------------------------------------------------------
# Network
# ------------------------------------------------------------------
HOST_VALUE="${HOST_VALUE:-127.0.0.1}"    # 127.0.0.1 for localhost-only, 0.0.0.0 to have access on LAN
HOST_ENABLED="${HOST_ENABLED:-ON}"

PORT_VALUE="${PORT_VALUE:-8011}"          # replace with your port of choice
PORT_ENABLED="${PORT_ENABLED:-ON}"

API_KEY_VALUE="${API_KEY_VALUE:-}"    # leave blank unless you want to require an API key;
                                       # pass in via env var so it never has to live in this file, e.g.
                                       #   API_KEY_VALUE="$(pass show llama-server-key)" ./launch-llama-server.sh
API_KEY_ENABLED="${API_KEY_ENABLED:-OFF}"
ALLOW_UNAUTHENTICATED="${ALLOW_UNAUTHENTICATED:-0}"  # Changing to 1 will allow launching on a host other than 127.0.0.1 or
                                      # localhost without an API key assigned.
                                      # Warning: Only change to 1 if you are on a trusted LAN
                                      # and accept the risks.
# ------------------------------------------------------------------
# Model routing (models-preset.ini)
# ------------------------------------------------------------------
MODELS_PRESET_VALUE="${MODELS_PRESET_VALUE:-$HOME/ai-stack/models/models-preset.ini}"          # path to models-preset.ini
MODELS_PRESET_ENABLED="${MODELS_PRESET_ENABLED:-ON}"

MODELS_MAX_VALUE="${MODELS_MAX_VALUE:-1}"          # how many models loaded concurrently before eviction
MODELS_MAX_ENABLED="${MODELS_MAX_ENABLED:-ON}"

# ------------------------------------------------------------------
# Performance / threading
# ------------------------------------------------------------------
THREADS_VALUE="${THREADS_VALUE:-16}"            # -t — leave OFF to let llama.cpp auto-detect
THREADS_ENABLED="${THREADS_ENABLED:-OFF}"

THREADS_HTTP_VALUE="${THREADS_HTTP_VALUE:-4}"        # HTTP worker threads, separate from inference threads
THREADS_HTTP_ENABLED="${THREADS_HTTP_ENABLED:-OFF}"

PARALLEL_VALUE="${PARALLEL_VALUE:-1}"            # -np — parallel request slots
PARALLEL_ENABLED="${PARALLEL_ENABLED:-OFF}"

CONT_BATCHING_ENABLED="${CONT_BATCHING_ENABLED:-OFF}"   # -cb — continuous batching (flag, no value)

FLASH_ATTN_ENABLED="${FLASH_ATTN_ENABLED:-OFF}"      # -fa — flash attention (flag, no value on most builds;
                               # some newer builds want `--flash-attn on`, check --help)

# ------------------------------------------------------------------
# Context / GPU overrides
# (usually left OFF since models-preset.ini's fit-ctx/fit-target
# already control this per-model)
# ------------------------------------------------------------------
CTX_SIZE_VALUE="${CTX_SIZE_VALUE:-65536}"        # -c — overrides fit-ctx if enabled
CTX_SIZE_ENABLED="${CTX_SIZE_ENABLED:-OFF}"

N_GPU_LAYERS_VALUE="${N_GPU_LAYERS_VALUE:-999}"      # -ngl — overrides fit-target's auto layer split if enabled
N_GPU_LAYERS_ENABLED="${N_GPU_LAYERS_ENABLED:-OFF}"

# ------------------------------------------------------------------
# Memory behavior
# ------------------------------------------------------------------
MLOCK_ENABLED="${MLOCK_ENABLED:-OFF}"           # --mlock — lock model in RAM, no swap
NO_MMAP_ENABLED="${NO_MMAP_ENABLED:-OFF}"         # --no-mmap — disable mmap loading

# ------------------------------------------------------------------
# Logging / debugging
# ------------------------------------------------------------------
LOG_TIMESTAMPS_ENABLED="${LOG_TIMESTAMPS_ENABLED:-ON}"   # --log-timestamps (flag, no value)

VERBOSITY_VALUE="${VERBOSITY_VALUE:-1}"           # -v / --verbosity — higher = more logs
VERBOSITY_ENABLED="${VERBOSITY_ENABLED:-OFF}"

# ------------------------------------------------------------------
# API / endpoints
# ------------------------------------------------------------------
NO_WEBUI_ENABLED="${NO_WEBUI_ENABLED:-OFF}"        # --no-webui — disable the built-in web UI
METRICS_ENABLED="${METRICS_ENABLED:-OFF}"         # --metrics — expose Prometheus metrics endpoint
SLOTS_ENDPOINT_ENABLED="${SLOTS_ENDPOINT_ENABLED:-OFF}"  # --slots — expose /slots endpoint
EMBEDDINGS_ENABLED="${EMBEDDINGS_ENABLED:-OFF}"      # --embeddings — enable embedding endpoint


# ==================================================================
# Build the argument list — you shouldn't need to touch anything
# below this line.
# ==================================================================
ARGS=()

add_valued() {
    # $1 = enabled flag, $2 = cli flag, $3 = value
    if [ "$1" = "ON" ]; then
        ARGS+=("$2" "$3")
    fi
}

add_flag() {
    # $1 = enabled flag, $2 = cli flag (no value)
    if [ "$1" = "ON" ]; then
        ARGS+=("$2")
    fi
}

add_valued "$HOST_ENABLED"           "--host"            "$HOST_VALUE"
add_valued "$PORT_ENABLED"           "--port"            "$PORT_VALUE"
add_valued "$API_KEY_ENABLED"        "--api-key"         "$API_KEY_VALUE"

add_valued "$MODELS_PRESET_ENABLED"  "--models-preset"   "$MODELS_PRESET_VALUE"
add_valued "$MODELS_MAX_ENABLED"     "--models-max"      "$MODELS_MAX_VALUE"

add_valued "$THREADS_ENABLED"        "--threads"         "$THREADS_VALUE"
add_valued "$THREADS_HTTP_ENABLED"   "--threads-http"    "$THREADS_HTTP_VALUE"
add_valued "$PARALLEL_ENABLED"       "-np"               "$PARALLEL_VALUE"
add_flag   "$CONT_BATCHING_ENABLED"  "-cb"
add_flag   "$FLASH_ATTN_ENABLED"     "-fa"

add_valued "$CTX_SIZE_ENABLED"       "--ctx-size"        "$CTX_SIZE_VALUE"
add_valued "$N_GPU_LAYERS_ENABLED"   "-ngl"              "$N_GPU_LAYERS_VALUE"

add_flag   "$MLOCK_ENABLED"          "--mlock"
add_flag   "$NO_MMAP_ENABLED"        "--no-mmap"

add_flag   "$LOG_TIMESTAMPS_ENABLED" "--log-timestamps"
add_valued "$VERBOSITY_ENABLED"      "--verbosity"       "$VERBOSITY_VALUE"

add_flag   "$NO_WEBUI_ENABLED"       "--no-webui"
add_flag   "$METRICS_ENABLED"        "--metrics"
add_flag   "$SLOTS_ENDPOINT_ENABLED" "--slots"
add_flag   "$EMBEDDINGS_ENABLED"     "--embeddings"

# ------------------------------------------------------------------
# Safety check: refuse to bind non-localhost without an API key
# ------------------------------------------------------------------
if [ "$HOST_ENABLED" = "ON" ] && [ "$HOST_VALUE" != "127.0.0.1" ] && [ "$HOST_VALUE" != "localhost" ]; then
    if [ "$API_KEY_ENABLED" != "ON" ] || [ -z "$API_KEY_VALUE" ]; then
        echo "WARNING: HOST_VALUE=$HOST_VALUE exposes llama-server beyond localhost," >&2
        echo "         but no API key is set (API_KEY_ENABLED=$API_KEY_ENABLED)." >&2
        echo "         Set API_KEY_ENABLED=ON and API_KEY_VALUE=<key> to require auth," >&2
        echo "         or set ALLOW_UNAUTHENTICATED=1 to bypass this check." >&2
        if [ "${ALLOW_UNAUTHENTICATED:-0}" != "1" ]; then
            exit 1
        fi
    fi
fi

# ------------------------------------------------------------------
# Launch
# ------------------------------------------------------------------
echo "--- Launching llama-server ---"
echo "${BIN_PATH}/llama-server ${ARGS[*]}"
echo

exec "${BIN_PATH}/llama-server" "${ARGS[@]}"
