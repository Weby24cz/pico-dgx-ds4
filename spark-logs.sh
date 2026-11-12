#!/usr/bin/env bash
# spark-logs.sh — stream this kit's DeepSeek service logs for sparkDash's logs modal (the same
# action GLM's logs-remote.sh serves there). The service is bare processes, not a container:
# rank 0 and the front-end log on this box (spark1), ranks 1-3 on their own Sparks
# (~/dsgb10/service/logs/rank.<r>.log). Everything is tailed, not read once: the modal keeps
# streaming until closed. TAIL/LINES set the initial depth (default 40 per file).
set -uo pipefail
TAIL="${TAIL:-${LINES:-40}}"
L=/home/pavelkubicek/dsgb10/service/logs

streams=(
  "tail -n $TAIL -F $L/service.log 2>&1 | sed -u 's/^/[service] /'"
  "tail -n $TAIL -F $L/front.log 2>&1 | sed -u 's/^/[front] /'"
  "tail -n $TAIL -F $L/rank.0.log 2>&1 | sed -u 's/^/[rank0] /'"
)
for r in 1 2 3; do
  h=spark$((r+1)).lan
  streams+=("bash /home/pavelkubicek/cluster/ring-ssh.sh $h 'tail -n $TAIL -F ~/dsgb10/service/logs/rank.$r.log 2>&1' | sed -u 's/^/[rank$r] /'")
done

cleanup() { jobs -p | xargs -r kill 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT INT TERM
for s in "${streams[@]}"; do eval "$s" & done
wait
