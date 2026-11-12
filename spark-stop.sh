#!/usr/bin/env bash
# spark-stop.sh — stop this kit's service (engine/server/service.sh stop; keeps kept sessions).
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$KIT_ROOT/spark-cluster.env"
exec "$KIT_ROOT/ds41f-4xgx10-switchless/engine/server/service.sh" stop
