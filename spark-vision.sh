#!/usr/bin/env bash
# spark-vision.sh — run the image-encoder sidecar for the pico DeepSeek kit (docs/vision.md).
# The sidecar is tools/vision/vision_encoder.py in docker: it mounts the checkpoint hub
# read-only, imports the publisher's inference/vision.py + image_processor.py and turns
# image_url / image parts into embedding rows on 127.0.0.1:$VISION_PORT (~1 GiB GPU on this
# box, rank 0's). dsfront picks the address up from spark-cluster.env's DSGB10_VISION_ADDR
# (--vision-addr): without it dsfront refuses image parts with the 400 the family saw on
# 2026-11-12.
#
# Lifecycle — the sidecar runs ONLY while the DeepSeek service runs: spark-start.sh /
# spark-restart.sh bring it up (idempotent), spark-stop.sh takes it down, and `start` spawns
# a watcher (`watch`, internal) that removes it when the service's supervisor disappears any
# other way — a crash, a bare `service.sh stop`. The container restarts on failure only
# (on-failure:3, self-heal while serving) and NEVER on a reboot, so a host restart with the
# kit off holds nothing.
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=dsgx10-vision
IMAGE=nvcr.io/nvidia/pytorch:26.07-py3   # torch + PIL + safetensors, already on spark1
# shellcheck disable=SC1091
source "$KIT_ROOT/spark-cluster.env"
HOST=127.0.0.1
PORT=${DSGB10_VISION_ADDR##*:}
SNAP="${DSGB10_SNAPSHOT/#\~/$HOME}"
# The snapshot's files are symlinks into the hub's blob store (../../blobs/…): mounting the
# snapshot dir alone leaves them dangling in the container. Mount the hub root instead and
# address the snapshot by its path under it.
HUB_ROOT="$(dirname "$(dirname "$(dirname "$SNAP")")")"
REL_SNAP="${SNAP#"$HUB_ROOT"/}"
# The service's run dir (service.sh's $H/run): the watcher reads its supervisor.pid from here.
RUN_DIR="${DSGB10_RUN_DIR:-$HOME/dsgb10/service/run}"

fail() { echo "spark-vision: $*" >&2; exit 1; }
running() { [ "$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null)" = running ]; }

check() {  # everything the sidecar and dsfront's vision path need; no side effects
  docker image inspect "$IMAGE" > /dev/null 2>&1 || fail "docker image missing: $IMAGE"
  [ -r "$SNAP/inference/vision.py" ] && [ -r "$SNAP/inference/image_processor.py" ] \
    || fail "snapshot lacks inference/vision.py or image_processor.py: $SNAP"
  grep -q '"vision\.' "$SNAP/model.safetensors.index.json" || fail "no vision.* tensors in $SNAP/model.safetensors.index.json"
  grep -q 'bias_vl' "$SNAP/model.safetensors.index.json" || fail "no ffn.gate.bias_vl entries in the index"
  grep -q -- --vision-addr ~/dsgb10/bin/dsfront 2>/dev/null || fail "staged dsfront predates vision (no --vision-addr in --help): re-run pico-prep.sh"
  grep -q -- --vision-addr <(printf '%s\n' "$DSGB10_FRONT_ARGS") || fail "DSGB10_FRONT_ARGS has no --vision-addr"
  if running; then p="$(docker port "$NAME" 2>/dev/null)"; echo "check: sidecar $NAME is running (${p:+$p — }host network, $HOST:$PORT)"; else echo "check: OK — sidecar not running (./spark-vision.sh start brings it up; the service picks --vision-addr up at its next start)"; fi
}

case "${1:-status}" in
  check) check ;;
  start)
    check
    # Ensure a watcher on every invocation (idempotent: extras exit when the pid changes or dies) —
    # also on the already-running path, where a restart kept the container but the OLD watcher just
    # retired with the old supervisor.
    ( setsid "$0" watch </dev/null >/dev/null 2>&1 & ) 2>/dev/null || true
    running && { echo "spark-vision: $NAME already running"; exit 0; }
    docker rm -f "$NAME" > /dev/null 2>&1 || true   # a crashed/exited container holds the name
    docker run -d --name "$NAME" --restart on-failure:3 --gpus all --net=host --memory=6g \
      -e VISION_PRELOAD=1 \
      -v "$HUB_ROOT":/hub:ro \
      -v "$KIT_ROOT/ds41f-4xgx10-switchless/tools/vision":/app:ro \
      --entrypoint python3 "$IMAGE" /app/vision_encoder.py --model "/hub/$REL_SNAP" --host "$HOST" --port "$PORT" > /dev/null
    echo "spark-vision: $NAME started on $HOST:$PORT (logs: docker logs $NAME)"
    ;;
  watch)  # internal, spawned by start: remove the sidecar when the service's supervisor is gone
          # for good. A stop→start transition cancels it instead: the watcher follows THE pid it
          # saw, and the 30 s grace lets a restart's new supervisor take the pid file first.
    local_p=""
    for i in $(seq 1 24); do  # 2 min for the supervisor to appear (the engine is ready in ~30 s);
      local_p=$(cat "$RUN_DIR/supervisor.pid" 2>/dev/null || true)   # a start that never gets
      [ -n "$local_p" ] && kill -0 "$local_p" 2>/dev/null && break   # there must not leave the
      local_p=""; sleep 5                                            # sidecar idling: remove it
    done
    if [ -z "$local_p" ]; then docker rm -f "$NAME" >/dev/null 2>&1 || true; exit 0; fi
    while [[ "$(cat "$RUN_DIR/supervisor.pid" 2>/dev/null)" == "$local_p" ]] && kill -0 "$local_p" 2>/dev/null; do
      sleep 15
    done
    sleep 30
    # Bail only on a handover: the pid file holding a DIFFERENT pid means a new supervisor took
    # over (a restart passed through). A real stop leaves the same dead pid — or nothing at all
    # (service.sh removes the file) — and must fall through to the removal.
    now=$(cat "$RUN_DIR/supervisor.pid" 2>/dev/null || true)
    [[ -n "$now" && "$now" != "$local_p" ]] && exit 0
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    ;;
  stop)
    running || { echo "spark-vision: $NAME not running"; exit 0; }
    docker rm -f "$NAME" > /dev/null && echo "spark-vision: $NAME stopped"
    ;;
  status)
    if running; then docker ps --filter "name=$NAME" --format "{{.Names}}: {{.Status}}"; nc -z "$HOST" "$PORT" 2>/dev/null && echo "  listening on $HOST:$PORT" || echo "  NOT listening on $HOST:$PORT yet"; else echo "spark-vision: $NAME not running (image requests would 503; text unaffected)"; fi
    ;;
  *) echo "usage: $0 [start|stop|status|check]"; exit 1 ;;
esac
