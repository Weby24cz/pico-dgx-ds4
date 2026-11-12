#!/usr/bin/env bash
# pico-prep.sh — one-shot bring-up data preparation on spark1 for the pico-dgx-ds4 kit.
# Cuts the four rank files and the Engram shards from the local 1017 checkpoint, distributes
# ranks 1-3 over the ring (cluster ring-ssh.sh), CRC-verifies each on its target box, places
# rank 0's files, and pre-stages binaries + fleet.conf. Idempotent-ish: skips finished pieces.
set -euo pipefail
source "$HOME/.cargo/env"
KIT="$HOME/cluster/docker/pico-dgx-ds4/ds41f-4xgx10-switchless"
CKPT="$HOME/ai/models/hub/models--deepseek-ai--DeepSeek-V4.1-Flash-1017/snapshots/1bae0e1088993b9b82de08f59de5be5a34e42170"
OUT="$HOME/pico-prep"
RING_SSH=/home/pavelkubicek/cluster/ring-ssh.sh
log() { echo "[$(date '+%F %T')] $*"; }
exec 9>"$HOME/pico-prep.lock"
flock -n 9 || { echo "pico-prep: another instance holds ~/pico-prep.lock" >&2; exit 1; }

[ -d "$CKPT" ] || { echo "checkpoint missing: $CKPT" >&2; exit 1; }
[ -f "$RING_SSH" ] || { echo "ring-ssh missing" >&2; exit 1; }
for h in spark2.lan spark3.lan spark4.lan; do bash "$RING_SSH" "$h" hostname >/dev/null || { echo "ring-ssh to $h fails" >&2; exit 1; }; done
mkdir -p "$OUT" "$HOME/dsgb10/weights" "$HOME/dsgb10/engram"

# 0. the front-end (crate fetch on the first run)
if [ ! -x "$KIT/frontend/target/release/dsfront" ]; then
  log "building dsfront"
  (cd "$KIT/frontend" && cargo build --release -j4 >> "$OUT/dsfront-build.log" 2>&1)
fi
log "dsfront: $(ls -la "$KIT/frontend/target/release/dsfront" | awk '{print $5}') bytes"

# 1. the Engram hash map, once for all
if [ ! -s "$OUT/engram_hashmap.bin" ]; then
  log "making the Engram hash map"
  python3 "$KIT/engine/engram/py/make_hashmap_stdlib.py" "$CKPT" "$OUT/engram_hashmap.bin"
fi

# 2. per rank: convert, verify, pack, distribute, clean up locally
for r in 1 2 3 0; do
  WF="$HOME/dsgb10/weights/rank$r.dsw"
  if [ ! -s "$OUT/rank$r.dsw" ]; then
    log "rank $r: converting"
    "$KIT/engine/build/weights/dsw_convert" --ckpt "$CKPT" --rank "$r" --out "$OUT/rank$r.dsw"
  fi
  log "rank $r: verifying against the checkpoint"
  "$KIT/engine/build/weights/dsw_verify" --ckpt "$CKPT" --file "$OUT/rank$r.dsw" --threads 4
  if [ ! -s "$OUT/engram-l1-r${r}of4.bin" ]; then
    log "rank $r: packing the Engram shards"
    "$KIT/engine/build/engram/engram_pack" "$CKPT" "$OUT" "$r"
  fi
  if [ "$r" != 0 ]; then
    T="spark$((r + 1))"   # this fleet: rank 1 = spark2, rank 2 = spark3, rank 3 = spark4
    log "rank $r: shipping rank file + shards + hashmap to $T"
    ssh "$T" 'mkdir -p ~/dsgb10/weights ~/dsgb10/engram ~/dsgb10/bin'
    ship() {  # skip when the target already holds the file at the right size (resumable runs)
      local src="$1" dst="$2"
      local ssz tsz
      ssz=$(stat -c %s "$src")
      tsz=$(ssh "$T" "stat -c %s '$dst' 2>/dev/null || echo 0")
      if [ "$ssz" = "$tsz" ]; then
        log "  $dst: already shipped ($ssz bytes)"
      else
        rsync -a -e "bash $RING_SSH" "$src" "$T.lan:$dst.part"
        ssh "$T" "mv '$dst.part' '$dst'"
      fi
    }
    ship "$OUT/rank$r.dsw" "/home/pavelkubicek/dsgb10/weights/rank$r.dsw"
    ship "$OUT/engram-l1-r${r}of4.bin" "/home/pavelkubicek/dsgb10/engram/engram-l1-r${r}of4.bin"
    ship "$OUT/engram-l14-r${r}of4.bin" "/home/pavelkubicek/dsgb10/engram/engram-l14-r${r}of4.bin"
    ship "$OUT/engram_hashmap.bin" "/home/pavelkubicek/dsgb10/engram/engram_hashmap.bin"
    # transfer integrity, CPU-only (the GLM kit holds the workers' GPUs; the engine re-checks every
    # tensor's CRC against its own header at load, so this guards the ring transfer only)
    log "rank $r: sha256 transfer check on $T"
    for pair in \
      "$OUT/rank$r.dsw:/home/pavelkubicek/dsgb10/weights/rank$r.dsw" \
      "$OUT/engram-l1-r${r}of4.bin:/home/pavelkubicek/dsgb10/engram/engram-l1-r${r}of4.bin" \
      "$OUT/engram-l14-r${r}of4.bin:/home/pavelkubicek/dsgb10/engram/engram-l14-r${r}of4.bin"; do
      src="${pair%%:*}"; dst="${pair#*:}"
      s=$(sha256sum "$src" | cut -d' ' -f1)
      t=$(ssh "$T" "sha256sum '$dst' | cut -d' ' -f1")
      [ "$s" = "$t" ] || { echo "sha256 mismatch for $(basename "$src"): $s vs $t" >&2; exit 1; }
      log "  $(basename "$src"): $t"
    done
    log "rank $r: done; dropping the local copies"
    rm -f "$OUT/rank$r.dsw" "$OUT/engram-l1-r${r}of4.bin" "$OUT/engram-l14-r${r}of4.bin"
  fi
done

# 3. rank 0's files in place
log "placing rank 0's files"
mv "$OUT/rank0.dsw" "$HOME/dsgb10/weights/rank0.dsw"
mv "$OUT/engram-l1-r0of4.bin" "$OUT/engram-l14-r0of4.bin" "$HOME/dsgb10/engram/"
cp "$OUT/engram_hashmap.bin" "$HOME/dsgb10/engram/engram_hashmap.bin"

# 4. pre-stage binaries + fleet.conf on every box (service.sh re-copies at start anyway)
cp "$KIT/fleet/spark-cluster.conf" "$HOME/dsgb10/bin/fleet.conf"
for r in 1 2 3; do
  T="spark$((r + 1))"   # this fleet: rank 1 = spark2, rank 2 = spark3, rank 3 = spark4
  log "pre-staging binaries on $T"
  scp -q "$KIT/engine/build/server/dsgb10_rank" "$T":~/dsgb10/bin/
  scp -q "$KIT/frontend/target/release/dsfront" "$T":~/dsgb10/bin/
  scp -q "$KIT/fleet/spark-cluster.conf" "$T":~/dsgb10/bin/fleet.conf
done
cp "$KIT/engine/build/server/dsgb10_rank" "$KIT/frontend/target/release/dsfront" "$HOME/dsgb10/bin/"

log "ALL DONE"
df -h / | tail -1
ls -la "$HOME/dsgb10/weights" "$HOME/dsgb10/engram"
