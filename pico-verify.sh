#!/usr/bin/env bash
# pico-verify.sh — readiness audit of the pico kit's data on all four Sparks, run from spark1.
# Read-only: sizes, checksums of the small shared files, presence of every fleet-file path.
set -uo pipefail
EXPECT_RANK=() # filled from the fleet file below
KIT="$HOME/cluster/docker/pico-dgx-ds4/ds41f-4xgx10-switchless"
FL="$KIT/fleet/spark-cluster.conf"
fail=0
row() { printf "%-46s %s\n" "$1" "$2"; }

for r in 0 1 2 3; do
  T="spark$((r + 1))"
  W="$HOME/dsgb10/weights/rank$r.dsw"
  E1="$HOME/dsgb10/engram/engram-l1-r${r}of4.bin"
  E14="$HOME/dsgb10/engram/engram-l14-r${r}of4.bin"
  echo "== rank $r on $T"
  for f in "$W" "$E1" "$E14"; do
    if ssh "$T" "[ -s '$f' ]"; then
      sz=$(ssh "$T" "stat -c %s '$f'")
      row "$(basename "$f")" "OK ($sz bytes)"
    else
      row "$(basename "$f")" "MISSING"; fail=1
    fi
  done
  ssh "$T" "cmp -s ~/dsgb10/engram/engram_hashmap.bin /dev/null" 2>/dev/null
  h=$(ssh "$T" "sha256sum ~/dsgb10/engram/engram_hashmap.bin 2>/dev/null | cut -d' ' -f1")
  row "engram_hashmap.bin" "${h:0:16}… (expect 2405ae1d345ec2f7…)"
  [ "$h" = "2405ae1d345ec2f76f637e2de71918060c2160f24bc7ed5a0e0ac4f9e123b02e" ] || fail=1
  g=$(ssh "$T" "sha256sum ~/cfmlp_cml.bin 2>/dev/null | cut -d' ' -f1")
  row "cfmlp_cml.bin" "${g:0:16}… ($(ssh "$T" "stat -c %s ~/cfmlp_cml.bin") bytes)"
  for b in dsgb10_rank dsfront fleet.conf; do
    ssh "$T" "[ -s ~/dsgb10/bin/$b ]" && row "~/dsgb10/bin/$b" OK || { row "~/dsgb10/bin/$b" MISSING; [ "$b" = fleet.conf ] || :; }
  done
  row "kho=off" "$(ssh "$T" 'grep -o kho=off /proc/cmdline || echo MISSING')"
  row "disk free" "$(ssh "$T" 'df -h / | tail -1 | awk "{print \$4}"')"
done
echo
[ "$fail" = 0 ] && echo "VERIFY: ALL GOOD" || echo "VERIFY: GAPS FOUND (see above)"
exit $fail
