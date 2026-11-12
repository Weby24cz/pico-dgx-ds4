#!/usr/bin/env bash
# pico-verify.sh — readiness audit of the pico kit's data on all four Sparks, run from spark1.
# Read-only: sizes, cross-node checksums of the small shared files, presence of every fleet path.
set -uo pipefail
fail=0
row() { printf "%-44s %s\n" "$1" "$2"; }
GATE_REF=$(sha256sum ~/cfmlp_cml.bin | cut -d' ' -f1)
HASH_REF="2405ae1d345ec2f76f637e2de71918060c2160f24bc7ed5a0e0ac4f9e123b02e"

for r in 0 1 2 3; do
  T="spark$((r + 1))"
  echo "== rank $r on $T"
  for pair in "rank$r.dsw:dsgb10/weights" \
              "engram-l1-r${r}of4.bin:dsgb10/engram" \
              "engram-l14-r${r}of4.bin:dsgb10/engram"; do
    f="${pair%%:*}"; d="${pair#*:}"
    p="/home/pavelkubicek/$d/$f"
    if sz=$(ssh "$T" "stat -c %s '$p' 2>/dev/null"); then
      row "$d/$f" "OK ($sz bytes)"
    else
      row "$d/$f" "MISSING"; fail=1
    fi
  done
  h=$(ssh "$T" "sha256sum /home/pavelkubicek/dsgb10/engram/engram_hashmap.bin 2>/dev/null | cut -d' ' -f1")
  if [ "$h" = "$HASH_REF" ]; then row "engram_hashmap.bin" "OK ($HASH_REF)"
  else row "engram_hashmap.bin" "BAD (${h:-none})"; fail=1; fi
  g=$(ssh "$T" "sha256sum /home/pavelkubicek/cfmlp_cml.bin 2>/dev/null | cut -d' ' -f1")
  if [ "$g" = "$GATE_REF" ]; then row "cfmlp_cml.bin" "OK"
  else row "cfmlp_cml.bin" "BAD (${g:-none})"; fail=1; fi
  for b in dsgb10_rank dsfront fleet.conf; do
    if ssh "$T" "[ -s /home/pavelkubicek/dsgb10/bin/$b ]"; then row "dsgb10/bin/$b" OK
    else row "dsgb10/bin/$b" MISSING; fail=1; fi
  done
  k=$(ssh "$T" 'grep -o kho=off /proc/cmdline || echo MISSING')
  row "kho=off" "$k"; [ "$k" = "kho=off" ] || fail=1
  row "disk free" "$(ssh "$T" 'df -h / | tail -1 | awk "{print \$4}"')"
done
echo
[ "$fail" = 0 ] && echo "VERIFY: ALL GOOD" || { echo "VERIFY: GAPS FOUND (above)"; exit 1; }
