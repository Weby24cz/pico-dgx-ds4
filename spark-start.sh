#!/usr/bin/env bash
# spark-start.sh — start this kit's DeepSeek-V4.1-Flash-1017 service on the four-Spark ring,
# via ds41f-4xgx10-switchless/engine/server/service.sh with spark-cluster.env's settings.
# NEVER starts anything until the bring-up in README-SPARK-CLUSTER.md is done: it checks the
# binaries, the fleet file, the gate weights on all four boxes and, when one is configured, the API key.
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$KIT_ROOT/ds41f-4xgx10-switchless"
# shellcheck disable=SC1091
source "$KIT_ROOT/spark-cluster.env"

fail() { echo "spark-start: $*" >&2; exit 1; }
[ -r "$FLEET" ] || fail "fleet file missing: $FLEET"
[ -x "$KIT/engine/build/server/dsgb10_rank" ] || fail "engine not built: $KIT/engine/build (README-SPARK-CLUSTER.md step 2)"
[ -x "$KIT/frontend/target/release/dsfront" ] || fail "front-end not built: $KIT/frontend (README-SPARK-CLUSTER.md step 2)"
if [ -n "${DSGB10_KEY_FILE:-}" ]; then  # keyless (DSGB10_KEY_FILE="") is the LAN convention
  [ -r "${DSGB10_KEY_FILE/#\~/$HOME}" ] || fail "API key missing: $DSGB10_KEY_FILE (README-SPARK-CLUSTER.md step 3)"
fi
for h in spark1 spark2 spark3 spark4; do
  ssh "$h" 'test -r ~/cfmlp_cml.bin' || fail "gate weights missing on $h: ~/cfmlp_cml.bin (README-SPARK-CLUSTER.md step 4)"
done

exec "$KIT/engine/server/service.sh" start
