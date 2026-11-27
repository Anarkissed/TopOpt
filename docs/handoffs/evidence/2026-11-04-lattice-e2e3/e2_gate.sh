#!/bin/zsh
# gate_e21.sh COMMIT: the gate for E2.1, E2.2-3, E2.5, E3 and the cell-plan slice. (1) build 4e7648d8, TO-core's grading + design box tip that E2/E3 merged (the reference: library, the 21 identity
# binaries, the CLI) and COMMIT (everything); the 21 binaries base vs head. (2) the scenario
# flip table: e21_scen_red.py's four bar jobs on the reference CLI and on COMMIT's. (3) the full
# ctest (cli_demo included) on COMMIT. The M2 stand is not re-run: none of its jobs has load
# scenarios, and a job without them takes the unchanged calls (the 21 binaries prove the path).
C=$1; P=/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/gate_e21; R=/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/ref_4e76; rm -rf $P; mkdir -p $P/src
take() {
  while [ "$(sysctl -n vm.loadavg | awk '{print int($2)}')" -ge 7 ]; do sleep 30; done
  L="LatticeTypes gate E2.1 @ $C ($1), driver pid $$ $(date '+%Y-%m-%d %H:%M')"
  until ( set -o noclobber; echo "$L" > ~/dev/TopOpt/HEAVY.lock ) 2>/dev/null; do sleep 30; done
}
give() { [ "$(cat ~/dev/TopOpt/HEAVY.lock 2>/dev/null)" = "$L" ] && rm -f ~/dev/TopOpt/HEAVY.lock; }
take "build, identity, scenario flip"
if [ ! -x $R/src/core/build/topopt-cli ]; then
  rm -rf $R; mkdir -p $R/src
  (cd /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda && git archive 4e7648d8 core) | tar -x -C $R/src
  ln -s /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/app $R/src/app; ln -s /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/docs $R/src/docs; ln -s /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/evidence $R/src/evidence
  (cd $R/src/core && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -Dmanifold_DIR=/Users/nadim/dev/TopOpt/TopOpt/.vcpkg/installed-manifold/arm64-osx/share/manifold > $R/cfg.log 2>&1 && nice -n 5 cmake --build build -j 6 --target topopt_cli $(cat /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/ident_tests.txt | tr '\n' ' ') > $R/build.log 2>&1); echo "REF BUILD EXIT $?" >> $R/build.log
fi
(cd /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda && git archive $C core) | tar -x -C $P/src
ln -s /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/app $P/src/app; ln -s /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/docs $P/src/docs; ln -s /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/evidence $P/src/evidence
(cd $P/src/core && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -Dmanifold_DIR=/Users/nadim/dev/TopOpt/TopOpt/.vcpkg/installed-manifold/arm64-osx/share/manifold > $P/cfg.log 2>&1 && nice -n 5 cmake --build build -j 6 > $P/build.log 2>&1); echo "BUILD EXIT $?" >> $P/build.log
B=$P/src/core/build; REFB=$R/src/core/build
G=$P/ident; mkdir -p $G/base $G/head
filt() { grep -v -E '\[mg\] S7|\[mg\] smoother check|\[mg-safe\]|\[loose\] flood fill' | sed -e "s#$REFB#BUILD#g" -e "s#$B#BUILD#g" | grep -v 'wall time' ; }
for t in $(cat /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/ident_tests.txt); do
  (cd $REFB && ./$t > $G/base/$t.out 2> $G/base/$t.err; echo "exit $?" >> $G/base/$t.out)
  (cd $B && ./$t > $G/head/$t.out 2> $G/head/$t.err; echo "exit $?" >> $G/head/$t.out)
  for s in out err; do filt < $G/base/$t.$s > $G/base/$t.$s.f; filt < $G/head/$t.$s > $G/head/$t.$s.f; done
  if cmp -s $G/base/$t.out.f $G/head/$t.out.f && cmp -s $G/base/$t.err.f $G/head/$t.err.f; then echo "IDENTICAL $t" >> $P/ident.txt; else echo "DIFFERS   $t" >> $P/ident.txt; fi
done
python3 /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/docs/handoffs/evidence/2026-11-04-lattice-e2e3/e21_scen_red.py $REFB/topopt-cli /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/e2/faces_probe $P/flip/before > $P/flip_before.txt 2>&1
python3 /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/docs/handoffs/evidence/2026-11-04-lattice-e2e3/e21_scen_red.py $B/topopt-cli /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/e2/faces_probe $P/flip/after > $P/flip_after.txt 2>&1
# E2.5 before/after: two regions on one face (10 mm at 0.75, 16 mm at 0.88), both orders.
mkdir -p $P/e25; cp /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/e2/e23/bar.stl $P/e25/
for side in before after; do
  CL=$REFB/topopt-cli; [ $side = after ] && CL=$B/topopt-cli
  for j in e_shallow_first f_deep_first; do
    cp /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/e2/e23/$j.json $P/e25/$j.json
    (cd $P/e25 && $CL lattice-variant $j.json --out ${side}_$j > ${side}_$j.log 2>&1; echo "$side $j exit $?" >> $P/e25.txt)
    python3 -c "import json,glob,sys
for f in glob.glob('$P/e25/${side}_$j/*lattice.report.json'):
    g=json.load(open(f)).get('grading',{}); print('$side $j', {k:g.get(k) for k in ['latticed_voxels','rho_min_used','rho_max_used']})" >> $P/e25.txt
  done
done
echo done > $P/.flip_done
give
take "full ctest"
(cd $B && ctest --output-on-failure > $P/ctest.log 2>&1; echo "CTEST EXIT $?" >> $P/ctest.log)
give
echo done > $P/.done
