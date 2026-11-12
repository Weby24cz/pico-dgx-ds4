# spark-cluster bring-up — the Weby24cz fork on this four-Spark cluster

The kit: `ds41f-4xgx10-switchless/` (upstream README, "How to use", is the reference). This file is
the cluster-specific overlay: what is already prepared here, and the steps still pending before the
first start. **Nothing has been started** — the wrapper refuses until every step below is done.

## What is prepared

- **Fork**: `origin` = Picom-code/pico-dgx-ds4 (upstream), `org` = Weby24cz/pico-dgx-ds4 (pushable).
- **Straight-cable patch** (this fork only): per-rank `RANK<r>_NEXT_DEV<d>`/`RANK<r>_PREV_DEV<d>`
  device overrides in `engine/comm/ring_config.h`, `engine/comm/fleet.cpp`, `engine/comm/ring.cpp`
  and `engine/server/fleet.sh`. This cluster's cables join the same port letter at both ends
  (p0-p0, p1-p1; see `/home/pavelkubicek/cluster/README.md`), so the next-facing port alternates
  f0/f1/f0/f1 down the ring — upstream's global `NEXT_DEV`/`PREV_DEV` cannot express that. The
  engine was rebuilt from the patched source on spark1 (2026-11-12).
- **Fleet file**: `ds41f-4xgx10-switchless/fleet/spark-cluster.conf` — ranks 0-3 = spark1-4, GID 3,
  per-rank device overrides, file paths under `~/dsgb10/`. IP pairs share the four cable subnets.
- **Service settings**: `spark-cluster.env` — port 8000 (family rule; ONE DeepSeek kit serves at a
  time — stop the TensorFold kit first), listens on `127.0.0.1` + `10.0.0.100`, tokenizer/encoding
  `1017`, served name `DeepSeek-V4.1-Flash-1017`, strictly lossless engine args (no `DSGB10_OEA`;
  no `DSGB10_RING_DIRECT` — switchless ring), 1M context / 16 slots.
- **Wrappers**: `spark-start.sh` (with prereq checks), `spark-stop.sh`, `spark-restart.sh`.
- **sparkDash**: model card registered on dell (`POST /api/models`), id `pico-ds41f-4x-spark`.
- **Paseo schedules**: `pico-ds41f-checkpoint-branch` (daily 08:00 Europe/Prague) +
  `pico-ds41f-checkpoint-cleanup` (daily 08:30), mirroring the family's sync pipeline.

## Pending before the first start (in order)

1. **`pico-fetch-engram.sh` → `pico-prep.sh`** (ran 2026-11-12; logs `~/pico-fetch.log`,
   `~/pico-prep.log` on spark1): the HF snapshot on spark1 was missing the two Engram shards
   (`model-00047/48-of-00048.safetensors`, 101.5 GB each — `dsw_convert` died on the 12 missing
   layer-1/14 tensors; the TensorFold kit's data was quarter-packed in its own `.tfe` format and
   useless here), so the fetch script downloaded them into the HF cache first. The prep script then
   built dsfront (Rust 1.99.1), cut each rank's file, verified it against the checkpoint, packed
   the rank's Engram shards, shipped ranks 1-3 over the ring (`ring-ssh.sh`), CRC-checked each on
   its target box (`dsw_load --verify-crc`), placed rank 0's files, pre-staged `dsgb10_rank` +
   `dsfront` + `fleet.conf` into every box's `~/dsgb10/bin/`. API key done (`~/dsgb10-data/api-key`,
   0600); gate weights done (`~/cfmlp_cml.bin` on all four, 5536 B).
2. **Ring self-check, no serving** (only while the GLM kit is STOPPED — the ring is one-job-at-a-time
   and the GLM kit is live on spark1+spark2): `cd ds41f-4xgx10-switchless && export
   FLEET=$PWD/fleet/spark-cluster.conf && engine/server/ring.sh engine/comm/run4.sh
   engine/build/comm/ring_test` — every rank must print `passed`. Exercises the patched per-rank
   device wiring end to end.
3. **Start + bench**: `./spark-start.sh` (the family rule: ONE DeepSeek kit holds port 8000 — the
   TensorFold 4x kit is dismantled, the GLM kit uses 8000 only on its own pair), then the README's
   checks (`tools/bench/bench.py http://127.0.0.1:8000/v1 c1 27` with the bearer key) and sparkDash
   on dell.

## Done 2026-11-12 (preparation pass) — READY TO START

- `pico-verify.sh` on spark1: **VERIFY: ALL GOOD** on all four Sparks — every rank's weight file
  (77,719,715,840 B) and two Engram shards present, `engram_hashmap.bin` sha256
  `2405ae1d…` identical everywhere, `cfmlp_cml.bin` identical everywhere, `dsgb10_rank` + `dsfront`
  + `fleet.conf` staged in every `~/dsgb10/bin/`, `kho=off` set everywhere. Disk free: spark1 235G,
  spark2 391G, spark3 192G, spark4 306G — all above `MIN_AVAIL_GIB=100`.
- TensorFold 4x kit dismantled on all four Sparks: `dsv41-nfs-cx7-relay` container stopped+removed
  (spark4), both `tensorfold-dsv41:native-*` images removed everywhere, all 4x data dirs deleted
  (`engram-packed4x-1bae0e10` x4, legacy `engram4x-1bae0e10` 190G on spark2, `rank-cache4x-*` x3,
  head `tensorfold-dsv41/1bae0e10/rank-cache` 75G, `cache/dsv41-tensorfold-4x`). GLM and Qwen
  images/data untouched; the 2x EXL3 kit's image was among the removed `tensorfold-dsv41` tags
  (rebuildable from its kit; its big data was already gone).
- The HF snapshot turned out incomplete: no `model-00047/48` (the Engram tables). The TensorFold
  kit had its own Engram source; this kit reads the checkpoint directly, so the fetch script
  downloaded both shards (~203 GB) — **into the family cache** (`HF_HUB_CACHE` is pinned in the
  script after the first fetch landed in `~/.cache` and cost a re-run). After the packed shards
  were cut, the two source blobs moved to spark4 cold storage (`spark4:~/pico-cold/`, size-checked,
  ring transport) — spark1 keeps the 46 text shards, config, tokenizer; a re-prep copies the two
  blobs back or re-fetches with `pico-fetch-engram.sh` (~30 min).
- Head data prepared: `~/dsgb10/{weights,engram}` filled on every box (rank files ~78 GB each,
  shards ~50.7 GB per rank, one hash map), binaries pre-staged in `~/dsgb10/bin/`, API key at
  `~/dsgb10-data/api-key`, gate weights at `~/cfmlp_cml.bin` (all four).

## Notes

- `kho=off` must be on every box's kernel command line (`grep -o kho=off /proc/cmdline`), or
  `ibv_reg_mr` fails — this cluster's TensorFold kit already relies on RDMA, so it is expected set.
- Rank-0 memory: spark1 also runs the desktop, ai-api-proxy and ~18 containers (the family's
  `.env` notes apply). The engine takes ~90 GiB per box at TP=4; watch `MemAvailable` on the first
  runs, as the TensorFold kit's docs recommend.
- Engram shards here are byte-identical to MiaAI's `pack_engram.py --tp 4` output — the TensorFold
  kit's `engram-packed4x-1bae0e10` on spark1 is a DIFFERENT layout (owned quarters); do not reuse
  paths between the kits.
- The daily Paseo schedules treat `.env`-like local files as untracked: this kit has none —
  `spark-cluster.env` and the fleet file ARE tracked (no secrets in them; the API key is not).
