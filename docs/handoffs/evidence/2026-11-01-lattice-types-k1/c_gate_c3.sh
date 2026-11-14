#!/bin/zsh
# gate_c3.sh COMMIT NAME [WAITFILE]: gate_c.sh in THREE lock chunks (build+identity, stand, ctest), each under 90 min, each waiting for load < 7.
# was: gate_c.sh COMMIT NAME [WAITFILE] (gate_full.sh with "before" = the previous step's stand, gate_A3 at c009fa30): archive build + identity vs eede708a + stand AFTER (before reused) + floating + full ctest.
C=$1; N=$2; WF=${3:-}; P=/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/gate_$N; REF=/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/ref_eede/src/core/build; rm -rf $P; mkdir -p $P/src
if [ -n "$WF" ]; then until [ -e $WF ]; do sleep 5; done; fi
take() {  # $1 = what this chunk runs
  while [ "$(sysctl -n vm.loadavg | awk '{print int($2)}')" -ge 7 ]; do sleep 30; done
  L="LatticeTypes gate $N @ $C ($1), driver pid $$ $(date '+%Y-%m-%d %H:%M')"
  until ( set -o noclobber; echo "$L" > ~/dev/TopOpt/HEAVY.lock ) 2>/dev/null; do sleep 30; done
}
give() { [ "$(cat ~/dev/TopOpt/HEAVY.lock 2>/dev/null)" = "$L" ] && rm -f ~/dev/TopOpt/HEAVY.lock; }  # only my own line
take "build, identity"
(cd /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda && git archive $C core) | tar -x -C $P/src
ln -s /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/app $P/src/app; ln -s /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/docs $P/src/docs; ln -s /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/evidence $P/src/evidence
(cd $P/src/core && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release > $P/cfg.log 2>&1 && nice -n 5 cmake --build build -j 6 > $P/build.log 2>&1); echo "BUILD EXIT $?" >> $P/build.log
B=$P/src/core/build
cp $B/topopt-cli $P/topopt-cli.frozen && chmod a-w $P/topopt-cli.frozen
G=$P/ident; mkdir -p $G/base $G/head
filt() { grep -v -E '\[mg\] S7|\[mg\] smoother check|\[mg-safe\]|\[loose\] flood fill' ; }
for t in $(cat /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/ident_tests.txt); do
  (cd $REF && ./$t > $G/base/$t.out 2> $G/base/$t.err; echo "exit $?" >> $G/base/$t.out)
  (cd $B && ./$t > $G/head/$t.out 2> $G/head/$t.err; echo "exit $?" >> $G/head/$t.out)
  for s in out err; do filt < $G/base/$t.$s > $G/base/$t.$s.f; filt < $G/head/$t.$s > $G/head/$t.$s.f; done
  if cmp -s $G/base/$t.out.f $G/head/$t.out.f && cmp -s $G/base/$t.err.f $G/head/$t.err.f; then echo "IDENTICAL $t" >> $P/ident.txt; else echo "DIFFERS   $t" >> $P/ident.txt; fi
done
give
take "stand after, 9 types"
TYPES=(octet fcc kelvin rhombic diamond bcc sc gyroid schwarz_d)
for T in $TYPES; do
  FX=""; case $T in rhombic|gyroid|schwarz_d) FX=4;; esac
  /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/f7/stand.sh $T $P/topopt-cli.frozen $P/stand/after/$T struct $FX
done
ln -sfn /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/gate_A3/stand/after $P/stand/before
for T in $TYPES; do
  D=$P/stand/after/$T/out_run_struct_$T
  for v in 068 052 038 026; do
    [ -f $D/variant_${v}_lattice.stl ] || continue
    if [ -f $D/variant_${v}_lattice_SPANS.txt ]; then
      echo "== $T rung 0.${v#0}" >> $P/floating.txt
      /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/core/build/lattice_types_probe spans $D/variant_${v}_lattice_SPANS.txt $D/variant_${v}_lattice_SOLID.stl $D/variant_${v}.stl 2.22 >> $P/floating.txt 2>&1
    else
      echo "== $T rung 0.${v#0} (sheet)" >> $P/floating.txt
      /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/tpms_probe.v4 mesh $D/variant_${v}_lattice.stl = $D/variant_${v}.stl 2.22 >> $P/floating.txt 2>&1
    fi
  done
done
echo done > $P/.stand_done
give
take "full ctest"
(cd $B && ctest --output-on-failure > $P/ctest.log 2>&1; echo "CTEST EXIT $?" >> $P/ctest.log)
give
echo done > $P/.done
