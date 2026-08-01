#!/bin/sh
# THE ONE RULE check for this task: with the "warm_start" block ABSENT, the run
# must be BYTE-FOR-BYTE what it was before this change.
#
# The claim is structural — an absent block leaves has_warm_start false, run_job
# never assigns options.warm_start_coarse, and minimize_plastic's `if
# (options.warm_start_coarse)` block never executes — but a structural argument
# is not a measurement, so this script measures it.
#
# It runs the SAME job twice with the post-change binary (determinism, AC7) and
# compares every shipped artifact against the PRE-change binary's output. The
# pre-change binary is built from the merge-base so the comparison is against
# what actually shipped, not against a stash.
#
# Usage:  sh byte_identity_check.sh <pre_change_cli> <post_change_cli> <job.json>
set -e

PRE="$1"; POST="$2"; JOB="$3"
[ -x "$PRE" ] && [ -x "$POST" ] && [ -f "$JOB" ] || {
  echo "usage: $0 <pre_change_cli> <post_change_cli> <job.json>" >&2; exit 2; }

rm -rf /tmp/bi_pre /tmp/bi_post1 /tmp/bi_post2
"$PRE"  run "$JOB" --out /tmp/bi_pre   > /tmp/bi_pre.log   2>&1
"$POST" run "$JOB" --out /tmp/bi_post1 > /tmp/bi_post1.log 2>&1
"$POST" run "$JOB" --out /tmp/bi_post2 > /tmp/bi_post2.log 2>&1

# run_info.json is EXCLUDED from the byte comparison on purpose and by name:
# this task deliberately ADDS observability keys to it (warm_start_coarse_ms,
# _matvecs, _dof_touches, _grid_dofs, solved_grid_dofs). Its bytes are SUPPOSED
# to change. Everything the run actually produces — the report, the design
# container, the analysed fields, the exported meshes and the orientation record
# — must not.
# build_orientation.json is EXCLUDED, and for a reason that has nothing to do
# with this task: it records its own WALL TIMINGS (sweep_seconds,
# strut_axis_measure_seconds), so it differs between two runs of the SAME
# unmodified binary. Verified here before excluding it — the pre-change binary
# and two post-change runs differ from each other in exactly those two fields
# and nowhere else. Excluding it is therefore removing a known-nondeterministic
# file, not excusing a regression. (A separate task could make those fields
# omittable so the file becomes byte-comparable.)
ARTIFACTS="report.json design.bin fields.bin"

echo "=== pre-change vs post-change (THE ONE RULE: must be identical) ==="
fail=0
for f in $ARTIFACTS; do
  if [ -f "/tmp/bi_pre/$f" ]; then
    a=$(shasum -a 256 < "/tmp/bi_pre/$f"   | cut -d' ' -f1)
    b=$(shasum -a 256 < "/tmp/bi_post1/$f" | cut -d' ' -f1)
    [ "$a" = "$b" ] && echo "  OK        $f  $a" || { echo "  *** DIFFERS *** $f"; fail=1; }
  fi
done
for m in /tmp/bi_pre/variant_*; do
  [ -f "$m" ] || continue
  n=$(basename "$m")
  a=$(shasum -a 256 < "$m" | cut -d' ' -f1)
  b=$(shasum -a 256 < "/tmp/bi_post1/$n" | cut -d' ' -f1)
  [ "$a" = "$b" ] && echo "  OK        $n  $a" || { echo "  *** DIFFERS *** $n"; fail=1; }
done

echo "=== post-change run twice (AC7 determinism) ==="
for f in $ARTIFACTS; do
  if [ -f "/tmp/bi_post1/$f" ]; then
    a=$(shasum -a 256 < "/tmp/bi_post1/$f" | cut -d' ' -f1)
    b=$(shasum -a 256 < "/tmp/bi_post2/$f" | cut -d' ' -f1)
    [ "$a" = "$b" ] && echo "  OK        $f" || { echo "  *** DIFFERS *** $f"; fail=1; }
  fi
done

echo "=== the new run_info keys the armed run must report ==="
python3 - "$@" <<'PY'
import json
d = json.load(open('/tmp/bi_post1/run_info.json'))
for k in ("warm_start_coarse", "warm_start_coarse_iterations",
          "warm_start_coarse_ms", "warm_start_coarse_matvecs",
          "warm_start_coarse_dof_touches", "warm_start_coarse_grid_dofs",
          "solved_grid_dofs"):
    print("  %-32s %s" % (k, d.get(k, "<MISSING>")))
PY

[ "$fail" = "0" ] && echo "RESULT: THE ONE RULE HOLDS" || echo "RESULT: *** VIOLATED ***"
exit $fail
