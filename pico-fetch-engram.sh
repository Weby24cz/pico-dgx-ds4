#!/usr/bin/env bash
# pico-fetch-engram.sh — download the two missing Engram shards (101.5 GB each) into the HF
# cache on spark1, then re-run the prep pipeline (idempotent; it skips finished pieces).
set -euo pipefail
exec 9>"$HOME/pico-fetch.lock"
flock -n 9 || { echo "pico-fetch: another instance holds ~/pico-fetch.lock" >&2; exit 1; }
log() { echo "[$(date '+%F %T')] $*"; }

log "downloading model-00047/48 (Engram tables, ~203 GB)"
~/.local/bin/hf download deepseek-ai/DeepSeek-V4.1-Flash-1017 \
  model-00047-of-00048.safetensors model-00048-of-00048.safetensors
log "download done"
log "re-running pico-prep.sh"
bash "$HOME/pico-prep.sh"
log "ALL DONE (fetch+prep)"
