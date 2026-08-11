#!/bin/sh
# ★ THE CONTROL THAT LICENSES EVERY OTHER NUMBER IN THIS TASK.
#
# S1(b) needs a "without the fix" trajectory. Rather than spend 28 minutes
# re-running one, it uses PR 324's committed `arm3/B1_scratch_max/iterations.csv`
# — which is only legitimate if THIS task's binary, with every new flag
# defaulted off, still produces that file. So: five iterations of PR 324's ARM 2,
# on the S1/S3 binary, diffed against the committed rows.
#
# The comparison is on the COMPUTED columns only. `iteration_wall_s` is a wall
# clock and `solve_ms`/`sensitivity_ms` are wall clocks; they are excluded by
# name, and the exclusion is listed in the output so it cannot be silently
# widened. Two columns are NEW (`perim_weight`, `interface_area_mm2`) and are
# absent from the old file by construction; they are reported separately and
# must read 0 and a positive area respectively.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NEW="$HERE/arms/C0_control_5it/iterations.csv"
OLD="$REPO/evidence/2026-08-10-parametric-level-set/arm3/B1_scratch_max/iterations.csv"

if [ ! -f "$NEW" ]; then echo "MISSING $NEW"; exit 1; fi
if [ ! -f "$OLD" ]; then echo "MISSING $OLD"; exit 1; fi

python3 - "$NEW" "$OLD" <<'PY'
import csv, sys
new_p, old_p = sys.argv[1], sys.argv[2]
WALL = {"iteration_wall_s", "solve_ms", "sensitivity_ms"}
NEWCOLS = {"perim_weight", "interface_area_mm2"}

def rows(p):
    with open(p, newline="") as f:
        return list(csv.DictReader(f))

new, old = rows(new_p), rows(old_p)
n = min(len(new), len(old))
if n == 0:
    print("FAIL: no rows"); sys.exit(1)

shared = [c for c in old[0] if c in new[0] and c not in WALL]
missing = [c for c in old[0] if c not in new[0]]
added = [c for c in new[0] if c not in old[0]]

bad = 0
for i in range(n):
    for c in shared:
        if new[i][c] != old[i][c]:
            bad += 1
            print(f"  MISMATCH it {new[i]['iteration']} {c}: "
                  f"new {new[i][c]}  old {old[i][c]}")

print(f"rows compared        {n}")
print(f"columns compared     {len(shared)}  (excluded as wall clocks: "
      f"{', '.join(sorted(WALL))})")
print(f"columns DROPPED      {missing if missing else 'none'}")
print(f"columns ADDED        {added}")
for c in added:
    if c not in NEWCOLS:
        print(f"FAIL: unexpected new column {c}"); sys.exit(1)
for i in range(n):
    if float(new[i]["perim_weight"]) != 0.0:
        print(f"FAIL: perim_weight nonzero at it {new[i]['iteration']}"); sys.exit(1)
    if not float(new[i]["interface_area_mm2"]) > 0.0:
        print(f"FAIL: interface_area_mm2 not positive at it {new[i]['iteration']}")
        sys.exit(1)
print(f"perim_weight         0 on every row (the flag is OFF)")
print(f"interface_area_mm2   {new[0]['interface_area_mm2']} .. "
      f"{new[n-1]['interface_area_mm2']}  (new, positive)")
if bad:
    print(f"\n*** FAIL: {bad} mismatches. The new flags are NOT inert and no\n"
          f"*** table in this task may use PR 324's file as its control.")
    sys.exit(1)
print("\nPASS — every computed column reproduces PR 324's ARM 2 exactly.")
PY
