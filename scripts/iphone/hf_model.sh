#!/usr/bin/env bash
# Download model files from Hugging Face and push them to the app over USB.
#
# Usage:
#   bash scripts/iphone/hf_model.sh REPO                  # list the model files in REPO
#   bash scripts/iphone/hf_model.sh REPO FILE [FILE ...]  # download, then push to the iPhone
#
# Examples:
#   bash scripts/iphone/hf_model.sh ggml-org/gemma-4-E2B-it-GGUF
#   bash scripts/iphone/hf_model.sh ggml-org/gemma-4-E2B-it-GGUF \
#     gemma-4-E2B-it-Q4_0.gguf mmproj-gemma-4-E2B-it-Q8_0.gguf
#
# Files are kept in $MODELS_DIR (default ~/models/REPO), outside this repository,
# and an interrupted download resumes on the next run. A GGUF file whose name
# contains "mmproj" becomes the image projector of the model pushed with it.
#
# Environment:
#   HF_TOKEN     access token for gated or private repositories
#   HF_REVISION  branch, tag or commit (default: main)
#   MODELS_DIR   download folder (default: ~/models/REPO)
#   NO_PUSH=1    download only
set -euo pipefail

if [ "$#" -lt 1 ] || [[ ! "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] $cmd is not installed." >&2
    exit 1
  fi
done

repo="$1"
shift
revision="${HF_REVISION:-main}"
models_dir="${MODELS_DIR:-$HOME/models/$repo}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep the token out of the process list: pass it to curl through a config file descriptor.
hf_curl() {
  if [ -n "${HF_TOKEN:-}" ]; then
    curl --config <(printf 'header = "Authorization: Bearer %s"\n' "$HF_TOKEN") "$@"
  else
    curl "$@"
  fi
}

listing="$(hf_curl -fsS "https://huggingface.co/api/models/$repo/tree/$revision?recursive=true")" || {
  echo "[ERROR] Could not read $repo@$revision. Check the name; gated or private repositories need HF_TOKEN." >&2
  exit 1
}
model_files="$(jq -r '.[] | select(.type == "file") | select(.path | test("\\.(gguf|litertlm)$"; "i"))
  | "\(.lfs.size // .size)\t\(.path)"' <<<"$listing")"

if [ "$#" -eq 0 ]; then
  if [ -z "$model_files" ]; then
    echo "[ERROR] $repo has no .gguf or .litertlm files." >&2
    exit 1
  fi
  echo "Model files in $repo ($revision):"
  while IFS=$'\t' read -r size path; do
    printf '  %8s  %s\n' "$(numfmt --to=iec --suffix=B "$size")" "$path"
  done <<<"$model_files"
  exit 0
fi

mkdir -p "$models_dir"
local_files=()
for file in "$@"; do
  size="$(awk -F'\t' -v path="$file" '$2 == path { print $1 }' <<<"$model_files")"
  if [ -z "$size" ]; then
    echo "[ERROR] $file is not a .gguf or .litertlm file of $repo. List the files with: $0 $repo" >&2
    exit 1
  fi
  target="$models_dir/$(basename "$file")"
  if [ -f "$target" ] && [ "$(stat -c %s "$target")" = "$size" ]; then
    echo "[OK] Already downloaded: $target"
  else
    echo "[INFO] Downloading $file ($(numfmt --to=iec --suffix=B "$size"))..."
    hf_curl -fL --retry 3 -C - -o "$target.part" "https://huggingface.co/$repo/resolve/$revision/$file"
    if [ "$(stat -c %s "$target.part")" != "$size" ]; then
      echo "[ERROR] $file is incomplete; run the command again to resume." >&2
      exit 1
    fi
    mv "$target.part" "$target"
    echo "[OK] Downloaded: $target"
  fi
  local_files+=("$target")
done

if [ "${NO_PUSH:-0}" = "1" ]; then
  exit 0
fi
bash "$script_dir/push_model.sh" "${local_files[@]}"

echo
echo "The app registers each model under its lower-cased file name without the extension:"
for target in "${local_files[@]}"; do
  name="$(basename "$target")"
  if [[ "${name,,}" != *mmproj* ]]; then
    id="$(sed -E 's/\.[^.]+$//; s/[^A-Za-z0-9._-]/-/g' <<<"$name" | tr '[:upper:]' '[:lower:]')"
    echo "  bash scripts/iphone/launch.sh $id      # load it and watch the loader output"
    echo "  bash scripts/iphone/try_model.sh $id   # send a test request"
  fi
done
