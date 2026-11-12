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
    rsync -a -e "bash $RING_SSH" "$OUT/rank$r.dsw" "$T.lan:/home/pavelkubicek/dsgb10/weights/rank$r.dsw.part"
    rsync -a -e "bash $RING_SSH" "$OUT/engram-l1-r${r}of4.bin" "$OUT/engram-l14-r${r}of4.bin" "$T.lan:/home/pavelkubicek/dsgb10/engram/"
    rsync -a -e "bash $RING_SSH" "$OUT/engram_hashmap.bin" "$T.lan:/home/pavelkubicek/dsgb10/engram/"
    ssh "$T" "mv ~/dsgb10/weights/rank$r.dsw.part ~/dsgb10/weights/rank$r.dsw"
    if [ -x "$KIT/engine/build/weights/dsw_load" ]; then
      scp -q "$KIT/engine/build/weights/dsw_load" "$T":~/dsw_load
      log "rank $r: CRC load check on $T"
      ssh "$T" "~/dsw_load ~/dsgb10/weights/rank$r.dsw --verify-crc --rank $r"
    fi
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
