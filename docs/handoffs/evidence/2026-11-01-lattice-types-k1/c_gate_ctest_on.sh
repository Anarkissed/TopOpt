#!/bin/zsh
# gate_ctest_on.sh BASE NEW NAME: a gate whose library and CLI are BASE's (NEW changes only
# test sources). Brings gate_NAME's archive build of BASE up to NEW, PROVES the tree equals
# `git archive NEW core` (diff -r, build excluded), rebuilds incrementally and runs the full
# ctest under the heavy lock (load < 7, noclobber, pid line, removes only its own line).
# Identity, stand and floating are BASE's gate's: the commit cannot change them.
BASE=$1; NEW=$2; N=$3
W=/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda
P=/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/gate_$N
OUT=$P/ctest_$NEW; mkdir -p $OUT
take() {
  while [ "$(sysctl -n vm.loadavg | awk '{print int($2)}')" -ge 7 ]; do sleep 30; done
  L="LatticeTypes gate $N @ $NEW ($1), driver pid $$ $(date '+%Y-%m-%d %H:%M')"
  until ( set -o noclobber; echo "$L" > ~/dev/TopOpt/HEAVY.lock ) 2>/dev/null; do sleep 30; done
}
give() { [ "$(cat ~/dev/TopOpt/HEAVY.lock 2>/dev/null)" = "$L" ] && rm -f ~/dev/TopOpt/HEAVY.lock; }
CHANGED=$(cd $W && git diff --name-only $BASE $NEW)
echo "$CHANGED" > $OUT/changed.txt
if echo "$CHANGED" | grep -qvE '^core/tests/'; then echo "NOT TESTS-ONLY" >> $OUT/changed.txt; exit 2; fi
for f in ${(f)CHANGED}; do (cd $W && git show $NEW:$f) > $P/src/$f; done
rm -rf $OUT/arch; mkdir -p $OUT/arch
(cd $W && git archive $NEW core) | tar -x -C $OUT/arch
diff -rq -x build $OUT/arch/core $P/src/core > $OUT/tree_diff.txt; echo "TREE DIFF EXIT $?" >> $OUT/tree_diff.txt
rm -rf $OUT/arch
grep -q "TREE DIFF EXIT 0" $OUT/tree_diff.txt || exit 3
take "full ctest"
(cd $P/src/core && nice -n 5 cmake --build build -j 6 > $OUT/build.log 2>&1); echo "BUILD EXIT $?" >> $OUT/build.log
(cd $P/src/core/build && ctest --output-on-failure > $OUT/ctest.log 2>&1; echo "CTEST EXIT $?" >> $OUT/ctest.log)
give
echo done > $OUT/.done
