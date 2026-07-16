#!/usr/bin/env bash
#
# generate-models-preset.sh
#
# Scans a llama.cpp --models-dir style directory and generates a
# --models-preset INI file, correctly pairing multimodal models with
# their mmproj file, and handling multi-shard models.
#
# Usage:
#   ./generate-models-preset.sh <models_dir> [output.ini]
#
# Optional environment overrides:
#   PREFIX_QUANTIZER=0  # set to 0 to name entries after the model folder only,
#                        # instead of "quantizer_modelname" (default: 1)
#   STRIP_SUFFIXES=GGUF # comma-separated, case-insensitive list of trailing
#                        # "-suffix" strings to strip from model folder names
#                        # before building the preset name (default: GGUF)
#                        # e.g. "Tesslate_OmniCoder-9B-GGUF" -> "Tesslate_OmniCoder-9B"
#                        # Set to "" to disable stripping entirely.
#   FOLLOW_SYMLINKS_ENABLED  # ON to follow symlinks when scanning for models;
#                            # leave OFF (default) to ignore them safely.
#   EXTRA_ARGS          # newline-separated "key = value" lines applied to
#                        # every generated section. Key names must match the
#                        # long-form flag name llama-server's preset parser
#                        # expects (check with: llama-server --help | grep -i <flag>)
#                        # Example:
#                        #   EXTRA_ARGS=$'fitt = 2048\nfitc = 8192' \
#                        #     ./generate-models-preset.sh llm out.ini
#
# Expected layout (LM Studio style, one extra depth vs. the raw llama.cpp
# --models-dir convention):
#   models_dir/
#     quantizer-name/
#       model-name/
#         model-name.gguf
#       multimodal-model-name/
#         multimodal-model-name.gguf
#         mmproj-F16.gguf          # filename must start with "mmproj"
#       sharded-model-name/
#         sharded-model-name-00001-of-00006.gguf
#         sharded-model-name-00002-of-00006.gguf
#         ...
#
# Also still handles flat .gguf files directly under models_dir/ or
# directly under a quantizer folder, in case your layout isn't fully
# consistent.

set -euo pipefail

# ------------------------------------------------------------------
# .env loader (optional) — reads simple KEY=value pairs from a .env
# file in the same directory as this script, without sourcing/
# executing it. Only sets a variable if it isn't already set in the
# real environment. Lets you set MODELS_DIR / OUT_FILE in .env instead
# of passing them as positional args every time.
# ------------------------------------------------------------------
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
        value="${value//\\n/$'\n'}"  # allow literal \n in .env to become real newlines (for multi-line values like EXTRA_ARGS)
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

# Positional args still take priority over .env / environment
MODELS_DIR="${1:-${MODELS_DIR:-}}"
OUT_FILE="${2:-${OUT_FILE:-models-preset.ini}}"
mkdir -p "$(dirname "$OUT_FILE")"    # ensure output directory exists

PREFIX_QUANTIZER="${PREFIX_QUANTIZER:-1}"
STRIP_SUFFIXES="${STRIP_SUFFIXES:-GGUF}"
# Newline-separated "key = value" lines applied to every generated section.
# Key names must match the long-form flag name (dashes, no leading "--"),
# as accepted by llama-server's preset INI parser. Check with:
#   llama-server --help | grep -i <flag>
# Example:
#   EXTRA_ARGS=$'fitt = 2048\nfitc = 8192' ./generate-models-preset.sh llm out.ini
EXTRA_ARGS="${EXTRA_ARGS:-}"

# Whether to follow symlinks when scanning for model files.
# Set to ON if your model layout uses intentional symlinks; leave OFF (default)
# to safely ignore them and avoid accidentally pulling in unrelated paths.
FOLLOW_SYMLINKS_ENABLED="${FOLLOW_SYMLINKS_ENABLED:-OFF}"

if [[ -z "$MODELS_DIR" ]]; then
  echo "Usage: $0 <models_dir> [output.ini]" >&2
  exit 1
fi

if [[ ! -d "$MODELS_DIR" ]]; then
  echo "Error: '$MODELS_DIR' is not a directory" >&2
  exit 1
fi

MODELS_DIR="$(realpath "$MODELS_DIR")"

# Build find options — only follow symlinks when explicitly enabled.
if [[ "${FOLLOW_SYMLINKS_ENABLED:-OFF}" == "ON" ]]; then
  FIND_OPTS="-L"
else
  FIND_OPTS=""
fi

is_mmproj() {
  [[ "$(basename "$1" | tr '[:upper:]' '[:lower:]')" == mmproj* ]]
}

is_shard() {
  [[ "$(basename "$1")" =~ -[0-9]{5}-of-[0-9]{5}\.gguf$ ]]
}

is_shard_one() {
  [[ "$(basename "$1")" =~ -00001-of-[0-9]{5}\.gguf$ ]]
}

strip_shard_suffix() {
  local name="$1"
  echo "$name" | sed -E 's/-[0-9]{5}-of-[0-9]{5}$//'
}

strip_suffixes() {
  local name="$1"
  local suf
  IFS=',' read -r -a _suffix_list <<< "$STRIP_SUFFIXES"
  for suf in "${_suffix_list[@]}"; do
    [[ -z "$suf" ]] && continue
    local lower_name lower_suf
    lower_name="${name,,}"        # bash lowercase (portable, no GNU sed needed)
    lower_suf="${suf,,}"
    if [[ "$lower_name" == *"-${lower_suf}" ]]; then
      name="${name%-${suf}}"  # only strip the original-case suffix that was found
    fi
  done
  echo "$name"
}

write_section() {
  local name="$1" model="$2" mmproj="${3:-}"

  if [[ -n "${EXISTING_MODELS[$model]+x}" ]]; then
    echo "Skipping '$name': model file already present in '$OUT_FILE' (as '${EXISTING_MODELS[$model]}')" >&2
    skipped=$((skipped + 1))
    return 1
  fi

  # Name collision with a *different* model already in the file -> disambiguate
  # rather than silently overwrite/duplicate a section header.
  if [[ -n "${EXISTING_SECTIONS[$name]+x}" ]]; then
    local orig_name="$name" n=2
    while [[ -n "${EXISTING_SECTIONS[$name]+x}" ]]; do
      name="${orig_name}_${n}"
      n=$((n + 1))
    done
    echo "Note: preset name '$orig_name' already used by a different model; using '$name' instead" >&2
  fi

  {
    echo "[$name]"
    echo "model = $model"
    [[ -n "$mmproj" ]] && echo "mmproj = $mmproj"
    if [[ -n "$EXTRA_ARGS" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && echo "$line"
      done <<< "$EXTRA_ARGS"
    fi
    echo
  } >> "$OUT_FILE"

  EXISTING_SECTIONS["$name"]=1
  EXISTING_MODELS["$model"]="$name"
  return 0
}

# --- Load existing preset names AND model paths from OUT_FILE, if it
#     already exists, so we only append genuinely new models instead of
#     duplicating or clobbering what's already there. Dedup is keyed on
#     the model file path, not the section name, so manually renaming a
#     section in the INI won't cause it to be re-added on the next run. ---
declare -A EXISTING_SECTIONS
declare -A EXISTING_MODELS
declare -a MISSING_ENTRIES=()
if [[ -f "$OUT_FILE" ]]; then
  current_section=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      current_section="${BASH_REMATCH[1]}"
      EXISTING_SECTIONS["$current_section"]=1
    elif [[ "$line" =~ ^[[:space:]]*model[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      model_path="${BASH_REMATCH[1]}"
      model_path="${model_path%"${model_path##*[![:space:]]}"}"  # trim trailing whitespace
      EXISTING_MODELS["$model_path"]="$current_section"
    fi
  done < "$OUT_FILE"
  echo "Found ${#EXISTING_SECTIONS[@]} existing preset(s) in '$OUT_FILE' -- will skip models already present." >&2

  # --- Flag any existing "model = ..." (and "mmproj = ...") lines whose
  #     target file no longer exists on disk, by inserting a "# MISSING:"
  #     comment directly above the offending line. Idempotent: if that
  #     comment is already there from a previous run, it isn't duplicated. ---
  missing=0
  tmp_file="$(mktemp "${OUT_FILE}.XXXXXX")"
  prev_line=""
  scan_section=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      scan_section="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*(model|mmproj)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      path="${BASH_REMATCH[2]}"
      path="${path%"${path##*[![:space:]]}"}"  # trim trailing whitespace
      if [[ ! -f "$path" ]]; then
        if [[ "$prev_line" != "# MISSING: $key file not found on disk" ]]; then
          echo "# MISSING: $key file not found on disk" >> "$tmp_file"
          missing=$((missing + 1))
        fi
        MISSING_ENTRIES+=("[$scan_section] $key = $path")
      fi
    fi
    echo "$line" >> "$tmp_file"
    prev_line="$line"
  done < "$OUT_FILE"
  mv "$tmp_file" "$OUT_FILE"
  [[ $missing -gt 0 ]] && echo "Flagged $missing missing model/mmproj path(s) in '$OUT_FILE' with '# MISSING' comments." >&2

  {
    echo
    echo "# --- Appended by generate-models-preset.sh on $(date) ---"
    echo "# Source directory: $MODELS_DIR"
    echo
  } >> "$OUT_FILE"
else
  {
    echo "# Auto-generated by generate-models-preset.sh on $(date)"
    echo "# Source directory: $MODELS_DIR"
    echo
  } >> "$OUT_FILE"
fi

count=0
skipped=0

# --- Top-level flat .gguf files ---
while IFS= read -r -d '' f; do
  is_mmproj "$f" && continue
  if is_shard "$f" && ! is_shard_one "$f"; then
    continue  # only the first shard is used as the entrypoint
  fi

  base="$(basename "$f" .gguf)"
  if is_shard_one "$f"; then
    base="$(strip_shard_suffix "$base")"
  fi

  if write_section "$base" "$f"; then
    echo "Added: $base -> $(basename "$f")"
    count=$((count + 1))
  fi
done < <(find $FIND_OPTS "$MODELS_DIR" -maxdepth 1 -type f -iname "*.gguf" -print0)

# Processes a single "model folder" (one that should contain a model .gguf,
# optionally an mmproj file, or shards). $1 = folder path, $2 = name to use
# for this entry (already includes quantizer prefix if applicable).
process_model_dir() {
  local dir="$1" entry_name="$2"

  mapfile -d '' -t gguf_files < <(find $FIND_OPTS "$dir" -maxdepth 1 -type f -iname "*.gguf" -print0)

  if [[ ${#gguf_files[@]} -eq 0 ]]; then
    echo "Skipping '$entry_name': no .gguf files found" >&2
    return
  fi

  local mmproj_file=""
  local model_files=()
  for f in "${gguf_files[@]}"; do
    if is_mmproj "$f"; then
      mmproj_file="$f"
    else
      model_files+=("$f")
    fi
  done

  if [[ ${#model_files[@]} -eq 0 ]]; then
    echo "Skipping '$entry_name': only mmproj file(s) found, no model" >&2
    return
  fi

  # Case 1: sharded model -> use shard 1 as the entrypoint
  local shard_one=""
  for f in "${model_files[@]}"; do
    if is_shard_one "$f"; then
      shard_one="$f"
      break
    fi
  done

  if [[ -n "$shard_one" ]]; then
    if write_section "$entry_name" "$shard_one" "$mmproj_file"; then
      echo "Added: $entry_name -> $(basename "$shard_one") (multi-shard)$( [[ -n "$mmproj_file" ]] && echo " + mmproj")"
      count=$((count + 1))
    fi

  # Case 2: single model file (with or without mmproj) -> one entry
  elif [[ ${#model_files[@]} -eq 1 ]]; then
    if write_section "$entry_name" "${model_files[0]}" "$mmproj_file"; then
      echo "Added: $entry_name -> $(basename "${model_files[0]}")$( [[ -n "$mmproj_file" ]] && echo " + mmproj")"
      count=$((count + 1))
    fi

  # Case 3: multiple independent, non-sharded model files in one folder
  # (e.g. a folder of standalone embedding models) -> add each separately
  else
    echo "Note: '$entry_name' has multiple independent model files (no mmproj/shard pairing detected)." >&2
    echo "      Adding each as its own preset entry." >&2
    for f in "${model_files[@]}"; do
      local base sub_entry_name
      base="$(basename "$f" .gguf)"
      sub_entry_name="${entry_name}_${base}"
      if write_section "$sub_entry_name" "$f"; then
        echo "Added: $sub_entry_name -> $(basename "$f")"
        count=$((count + 1))
      fi
    done
  fi
}

# --- Quantizer folders (models_dir/quantizer-name/model-name/model-name.gguf) ---
while IFS= read -r -d '' quant_dir; do
  quant_name="$(basename "$quant_dir")"

  # Flat .gguf files directly under a quantizer folder (layout isn't always
  # perfectly consistent, so handle this defensively too)
  while IFS= read -r -d '' f; do
    is_mmproj "$f" && continue
    if is_shard "$f" && ! is_shard_one "$f"; then
      continue
    fi
    base="$(basename "$f" .gguf)"
    is_shard_one "$f" && base="$(strip_shard_suffix "$base")"
    entry_name="$base"
    [[ "$PREFIX_QUANTIZER" == "1" ]] && entry_name="${quant_name}_${base}"
    if write_section "$entry_name" "$f"; then
      echo "Added: $entry_name -> $(basename "$f")"
      count=$((count + 1))
    fi
  done < <(find $FIND_OPTS "$quant_dir" -maxdepth 1 -type f -iname "*.gguf" -print0)

  # Model folders: quantizer-name/model-name/
  while IFS= read -r -d '' model_dir; do
    model_name="$(basename "$model_dir")"
    model_name="$(strip_suffixes "$model_name")"
    entry_name="$model_name"
    [[ "$PREFIX_QUANTIZER" == "1" ]] && entry_name="${quant_name}_${model_name}"
    process_model_dir "$model_dir" "$entry_name"
  done < <(find $FIND_OPTS "$quant_dir" -mindepth 1 -maxdepth 1 -type d -print0)

done < <(find $FIND_OPTS "$MODELS_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

echo
echo "Done. Wrote $count new model preset(s) to '$OUT_FILE'."
[[ $skipped -gt 0 ]] && echo "Skipped $skipped preset(s) already present in the file."
if [[ ${#MISSING_ENTRIES[@]} -gt 0 ]]; then
  echo
  echo "WARNING: ${#MISSING_ENTRIES[@]} model/mmproj path(s) in '$OUT_FILE' point to files that no longer exist:"
  for entry in "${MISSING_ENTRIES[@]}"; do
    echo "  - $entry"
  done
  echo "Consider removing these entries from preset file manually."
fi
echo "Review it, then run:"
echo "  llama-server --models-preset '$OUT_FILE' --port 8011"
