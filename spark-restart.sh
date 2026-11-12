#!/usr/bin/env bash
# spark-restart.sh — stop, then start with the current spark-cluster.env (service.sh restart).
# sparkDash's model card calls this script by name. The vision sidecar is ensured here too: a
# restart after a stop (which takes the sidecar down) must serve images again without a manual step.
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$KIT_ROOT/spark-cluster.env"
if [ -n "${DSGB10_VISION_ADDR:-}" ]; then
  "$KIT_ROOT/spark-vision.sh" start
fi
exec "$KIT_ROOT/ds41f-4xgx10-switchless/engine/server/service.sh" restart
