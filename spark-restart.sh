#!/usr/bin/env bash
# spark-restart.sh — stop, then start with the current spark-cluster.env (service.sh restart).
# sparkDash's model card calls this script by name.
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$KIT_ROOT/spark-cluster.env"
exec "$KIT_ROOT/ds41f-4xgx10-switchless/engine/server/service.sh" restart
