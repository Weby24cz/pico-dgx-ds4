#!/usr/bin/env bash
# spark-stop.sh — stop this kit's service (engine/server/service.sh stop; keeps kept sessions) and,
# when the kit serves vision (DSGB10_VISION_ADDR set), its image-encoder sidecar: spark1's GPU is
# shared with the Qwen pair, and a stopped kit must not hold ~1 GiB there. The next start (or
# restart) brings the sidecar back (./spark-vision.sh start is what they call).
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$KIT_ROOT/spark-cluster.env"
"$KIT_ROOT/ds41f-4xgx10-switchless/engine/server/service.sh" stop
rc=$?
if [ -n "${DSGB10_VISION_ADDR:-}" ]; then
  "$KIT_ROOT/spark-vision.sh" stop
fi
exit $rc
