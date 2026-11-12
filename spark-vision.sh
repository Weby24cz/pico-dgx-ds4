#!/usr/bin/env bash
# spark-vision.sh — run the image-encoder sidecar for the pico DeepSeek kit (docs/vision.md).
# The sidecar is tools/vision/vision_encoder.py in docker: it mounts the checkpoint snapshot
# read-only, imports the publisher's inference/vision.py + image_processor.py and turns
# image_url / image parts into embedding rows on 127.0.0.1:$VISION_PORT (~1 GiB GPU on this
# box, rank 0's). dsfront picks the address up from spark-cluster.env's DSGB10_VISION_ADDR
# (--vision-addr): without it dsfront refuses image parts with the 400 the family saw on
# 2026-11-12. The sidecar is independent of the service: start/stop it any time — sidecar
# down only turns image requests into 503s; text is untouched. `check` verifies everything
# without starting anything.
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=dsgx10-vision
IMAGE=nvcr.io/nvidia/pytorch:26.07-py3   # torch + PIL + safetensors, already on spark1
# shellcheck disable=SC1091
source "$KIT_ROOT/spark-cluster.env"
HOST=127.0.0.1
PORT=${DSGB10_VISION_ADDR##*:}
SNAP="${DSGB10_SNAPSHOT/#\~/$HOME}"

fail() { echo "spark-vision: $*" >&2; exit 1; }
up()   { docker ps --format '{{.Names}}' | grep -qx "$NAME"; }

check() {  # everything the sidecar and dsfront's vision path need; no side effects
  docker image inspect "$IMAGE" > /dev/null 2>&1 || fail "docker image missing: $IMAGE"
  [ -r "$SNAP/inference/vision.py" ] && [ -r "$SNAP/inference/image_processor.py" ] \
    || fail "snapshot lacks inference/vision.py or image_processor.py: $SNAP"
  grep -q '"vision\.' "$SNAP/model.safetensors.index.json" || fail "no vision.* tensors in $SNAP/model.safetensors.index.json"
  grep -q 'bias_vl' "$SNAP/model.safetensors.index.json" || fail "no ffn.gate.bias_vl entries in the index"
  grep -q -- --vision-addr ~/dsgb10/bin/dsfront 2>/dev/null || fail "staged dsfront predates vision (no --vision-addr in --help): re-run pico-prep.sh"
  grep -q -- --vision-addr <(printf '%s\n' "$DSGB10_FRONT_ARGS") || fail "DSGB10_FRONT_ARGS has no --vision-addr"
  if up; then echo "check: sidecar $NAME is up ($(docker port "$NAME" 2>/dev/null || echo "host net"), $HOST:$PORT)"; else echo "check: OK — sidecar not running; ./spark-vision.sh start, then restart the service so dsfront re-reads --vision-addr"; fi
}

case "${1:-status}" in
  check) check ;;
  start)
    check
    up && { echo "spark-vision: $NAME already up"; exit 0; }
    docker run -d --name "$NAME" --restart unless-stopped --gpus all --net=host --memory=6g \
      -e VISION_PRELOAD=1 \
      -v "$SNAP":/model:ro \
      -v "$KIT_ROOT/ds41f-4xgx10-switchless/tools/vision":/app:ro \
      --entrypoint python3 "$IMAGE" /app/vision_encoder.py --host "$HOST" --port "$PORT" > /dev/null
    echo "spark-vision: $NAME started on $HOST:$PORT (logs: docker logs $NAME)"
    ;;
  stop)
    up || { echo "spark-vision: $NAME not running"; exit 0; }
    docker rm -f "$NAME" > /dev/null && echo "spark-vision: $NAME stopped"
    ;;
  status)
    if up; then docker ps --filter "name=$NAME" --format "{{.Names}}: {{.Status}}"; nc -z "$HOST" "$PORT" 2>/dev/null && echo "  listening on $HOST:$PORT" || echo "  NOT listening on $HOST:$PORT yet"; else echo "spark-vision: $NAME not running (image requests would 503; text unaffected)"; fi
    ;;
  *) echo "usage: $0 [start|stop|status|check]"; exit 1 ;;
esac
