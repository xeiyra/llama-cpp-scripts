# llama-cpp-scripts

A small set of scripts for building `llama.cpp` from source with ROCm/HIP,
generating a `--models-preset` router config from an LM Studio-style model
directory, and launching `llama-server` with sane, configurable defaults.

Built around a workflow of: one `llama-server` process, multiple models,
automatic swapping via `--models-preset` + `--models-max 1`.

## Contents

| Script                      | Purpose                                                                                                                                                           |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `install-llama.cpp.sh`      | Clones/updates and builds `llama.cpp` from master with ROCm/HIP, archiving each previous build by version before rebuilding.                                      |
| `generate-models-preset.sh` | Scans a models directory and generates a `models-preset.ini`, pairing multimodal models with their `mmproj` file and handling multi-shard models.                 |
| `launch-llama-server.sh`    | Launches `llama-server` using a toggle-style config block (`*_VALUE` / `*_ENABLED` pairs) so flags can be turned on/off without editing the argument list itself. |

## Prerequisites

- An AMD GPU + ROCm installed (`install-llama.cpp.sh` builds specifically
  for the HIP backend; see `GGML_HIP` below to build CPU-only instead)
- `git`, `cmake`, `ninja`
- Bash 4+

## .env file

All three scripts read an optional `.env` file from the same directory as
the script itself. It uses a simple `KEY=value` parser — no shell sourcing
or execution. Variables set in the real shell environment always take
precedence over values in `.env`, so a one-off override like
`BIN_PATH=/tmp/test ./launch-llama-server.sh` still wins.

The loader also supports:
- `\n` in `.env` values → converted to real newlines (useful for `EXTRA_ARGS`)
- `~` expansion in leading positions (`~/models` → `$HOME/models`)
- `${VAR}` and `$VAR` expansion in values

See `example.env` for a fully commented reference covering all variables
for every script. Copy it to `.env` and uncomment / adjust the settings
you want to change from their built-in defaults.

## Quick start

```bash
# 1. Build llama.cpp
./install-llama.cpp.sh

# 2. Generate a models-preset.ini from your models directory
./generate-models-preset.sh /path/to/models models-preset.ini

# 3. Point the launcher at it and start the server
MODELS_PRESET_VALUE=/path/to/models-preset.ini ./launch-llama-server.sh
```

Expected models directory layout (LM Studio style — one extra depth vs.
the raw llama.cpp `--models-dir` convention):

```
models_dir/
  quantizer-name/
    model-name/
      model-name.gguf
    multimodal-model-name/
      multimodal-model-name.gguf
      mmproj-F16.gguf          # filename must start with "mmproj"
    sharded-model-name/
      sharded-model-name-00001-of-00006.gguf
      sharded-model-name-00002-of-00006.gguf
      ...
```

Flat `.gguf` files directly under `models_dir/` or a quantizer folder are
also handled. See `examples/models-preset.ini.example` for what the
generated output looks like.

## Configuration

Each script is self-contained and configurable via environment variables
(no need to edit the scripts themselves for normal use).

### `install-llama.cpp.sh`

| Variable              | Default                            | Description                                                                                                 |
| --------------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `ROOT_DIR`            | current working directory          | Parent directory; all other clone/build/archive dirs default to subdirs of this                              |
| `CLONE_DIR`           | `$ROOT_DIR/llama.cpp`              | Source checkout — treated as disposable; the script runs `git pull` on it                                    |
| `BUILD_DIR`           | `$ROOT_DIR/build`                  | Current/live build output directory                                                                          |
| `BUILDS_ARCHIVE_DIR`  | `$ROOT_DIR/builds`                 | Versioned snapshots of previous builds, archived before each rebuild                                         |
| `BUILD_TYPE`          | `Release`                          | CMake build type (`Release`, `Debug`, `RelWithDebInfo`, etc.)                                                |
| `GGML_HIP`            | `ON`                               | Set to `OFF` to build CPU-only instead of ROCm/HIP                                                           |
| `GGML_CCACHE`         | `OFF`                              | Whether to enable ccache for faster rebuilds                                                                 |
| `ALLOW_DIRTY`         | `0`                                | Set to `1` to skip the confirmation prompt when `llama.cpp/` has local uncommitted changes (see note below) |

#### ROCm/HIP paths

These are set after `.env` loads, so they can be overridden in `.env` or
via environment variables. Defaults to `/opt/rocm` unless your ROCm
installation is elsewhere:

| Variable        | Default              | Description                                                                  |
| --------------- | -------------------- | ---------------------------------------------------------------------------- |
| `ROCM_PATH`     | `/opt/rocm`          | Root directory of the ROCm installation                                        |
| `HIP_PATH`      | `${hipconfig -R}`    | HIP runtime path (auto-detected via `hipconfig`, falls back to `/opt/rocm`)  |
| `HIPCXX`        | —                    | Full path to the HIP C++ compiler (`$(hipconfig -l)/clang`)                  |

The `llama.cpp/` clone is treated as a **disposable, machine-managed
checkout** — the script runs `git pull` on it and may re-clone it. Don't
hand-edit files inside it; local changes can be silently overwritten or
wiped on the next run. If you need local modifications, keep them in a
fork/branch and point the clone URL at that instead.

Each build is archived by version under `builds/` before the next one
overwrites `build/`, so you can roll back to a previous binary if needed.

### `generate-models-preset.sh`

```
Usage: ./generate-models-preset.sh <models_dir> [output.ini]
```

| Variable                    | Default   | Description                                                                                                                                                                                                    |
| --------------------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PREFIX_QUANTIZER`          | `1`       | Set to `0` to name entries after the model folder only, instead of `quantizer_modelname`                                                                                                                       |
| `STRIP_SUFFIXES`            | `GGUF`    | Comma-separated, case-insensitive suffixes stripped from model folder names before naming the entry. Set to `""` to disable                                                                                    |
| `FOLLOW_SYMLINKS_ENABLED`   | `OFF`     | Set to `ON` to follow symlinks when scanning for models (default: off for safety — symlinked directories could be traversed unintentionally)                                                                   |
| `EXTRA_ARGS`                | *(unset)* | Newline-separated `key = value` lines applied to every generated section. Keys must match the long-form flag names `llama-server`'s preset parser expects — check with `llama-server --help \| grep -i <flag>` |

The script is safe to re-run against a growing model collection: it dedups
on model file path (not section name), so manually renaming a section
won't cause it to be re-added, and it flags any `model =` / `mmproj =` entries whose target file no longer exists on disk with a `# MISSING` comment instead of silently leaving a broken config.

### `launch-llama-server.sh`

The script is one big block of `*_VALUE` / `*_ENABLED` pairs — set the
value and flip `*_ENABLED="ON"` to include that flag; leave it `"OFF"` to
omit it entirely. A few of the more relevant ones:

| Variable                            | Default                              | Description                                                                                                                                                                       |
| ----------------------------------- | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BIN_PATH`                          | `$HOME/ai-stack/engines/llama.cpp/build/bin/` | Path to the built `llama-server` binary (trailing slash is normalized automatically)                                                                                                                                           |
| `HOST_VALUE`                        | `127.0.0.1`                          | `127.0.0.1` for localhost-only, `0.0.0.0` for LAN access                                                                                                                          |
| `API_KEY_VALUE` / `API_KEY_ENABLED` | *(unset)* / `OFF`                    | Set both to require an API key. Pass the key in via env var at launch rather than editing the file, e.g. `API_KEY_VALUE="$(pass show llama-server-key)" ./launch-llama-server.sh` |
| `ALLOW_UNAUTHENTICATED`             | `0`                                  | Set to `1` to bypass the safety check that refuses to bind a non-localhost host without an API key. Only on trusted LAN — see safety note below                                    |
| `MODELS_PRESET_VALUE`               | `$HOME/ai-stack/models/models-preset.ini` | Path to your generated preset file                                                                                                                                               |
| `MODELS_MAX_VALUE`                  | `1`                                  | How many models stay loaded concurrently before eviction                                                                                                                          |

Run `"$BIN_PATH"/llama-server --help` to check current flag syntax before
assuming the script is wrong — this builds from bleeding-edge master, and
a few flags (flash-attn, numa) have changed shape upstream before.

#### Safety note: network binding

If `HOST_VALUE` is set to anything other than `127.0.0.1` / `localhost` (e.g. `0.0.0.0` for LAN access) **without** an API key configured, the
script will refuse to launch and print a warning — an unauthenticated
inference server bound beyond localhost is easy to expose accidentally.
To proceed anyway (e.g. on a trusted LAN), set `ALLOW_UNAUTHENTICATED=1`.

## License

MIT — see `LICENSE`.
