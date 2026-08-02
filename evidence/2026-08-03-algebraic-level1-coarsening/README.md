# Evidence — algebraic level-1 coarsening, from measurement to production

**Task:** `algebraic-level1-coarsening` ·
**Handoff:** `docs/handoffs/2026-08-03-algebraic-level1-coarsening.md`

This task turns PR 283's §4 measurement — that aggregating multigrid's LEVEL 1
from the FINE operator lifts its energy capture from 1.5954 % to 56.3293 % on the
maintainer's dilute field — into a PRODUCTION path, behind a named constant, with
the LIBRARY DEFAULT OFF.

It STACKS ON PR 283 (`claude/algebraic-coarse-space-dilute-733b33`), which was
still open when this work started: it consumes that PR's coarse-space hook
(`build_hierarchy_from_prolongators`, used here as the consumer for levels 2..)
and its energy-capture instrument, and rebuilds neither.

## The machine

Apple silicon, **6 performance cores / 10 logical, 16 GB RAM**. The host was NOT
quiet: other campaigns ran throughout and the 1-minute load average sat between
10 and 18 on 10 logical cores. PR 277's discipline is applied — the load average
is printed at the start and end of every measurement and appears in every file
below. **Every headline number here is a count** (iterations, aggregates, coarse
dimensions, bytes, verdicts) or a ratio of exact solves; wall is reported and is
deliberately not ranked on.

## Files

| file | what it is |
| --- | --- |
| `tripwire.txt` | `test_mg_algebraic_level1` — the CTest tripwire: disarmed by default, arm+disarm BIT-IDENTICAL, armed genuinely non-geometric, same field, deterministic refusal with bit-identical fallback |
| `ctest.txt` | the full suite |
| `mem.csv`, `mem_fit.txt` | AH3 — aggregates / coarse dimension / bytes at six grid sizes over a 108x DOF range, the fitted growth law and the 8.44M-DOF projection |
| `capture.csv`, `capture.txt` | AH2 — energy capture of the geometric and the production-algebraic level-1 spaces, against PR 283's published numbers as a control |
| `converge.csv`, `converge.txt` | AH2 / AH5 / AH6 / AH8 — iterations, DOF-weighted work, setup vs cycle cost and field deviation, armed vs disarmed, on the stagnating field and a healthy control |
| `gate.csv`, `gate_summary.csv`, `gate.txt` | AH4 / AH7 / AH9 / AH11 — the full production ladder disarmed vs armed: stagnating solves and the latch, the gate table with verdicts and margins, classification flips against a 1e-9 negative-control floor, the GenEO and recycler counters, and wall |
| `det_out.txt` (transcript), `det.txt` (rows) | AH10 — byte-identical rerun in each posture |
| `byteid.txt` | AH1 — the stash-rebuild byte-identity check of the reference world, including the CORRECTED per-column classification of `iterations.csv` (the first pass's timing-column list was too narrow; both are kept) |
| `byteid_job.json`, `byteid_check.sh` | the job and the script that produced it |
| `fixture_stag.txt` | the stagnating fixture reproduced to the grid — PR 280's ladder32, 48x32x40, 80 snapshots |
| `host_load.txt` | the load average through the campaign |

## Reproducing

Build the library and the harnesses (the harnesses are deliberately NOT CTest
targets — they run for minutes to hours):

```
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build -j
c++ -std=c++17 -O2 -I core/include -I core/src -I core/src/fea -I core/tests/harness \
    -I /opt/homebrew/include/eigen3 \
    -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
    core/tests/harness/alg_level1_probe.cpp core/build/libtopopt.a <OCCT libs> \
    -o core/build/alg_level1_probe
c++ -std=c++17 -O2 -I core/include -I core/src -I /opt/homebrew/include/eigen3 \
    -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
    core/tests/harness/alg_level1_gate.cpp core/build/libtopopt.a <OCCT libs> \
    -o core/build/alg_level1_gate
```

The stagnating field is PR 280's, read from the cache `mg_component_sweep`
writes, so this task, PR 280 and PR 283 all measure literally the same
trajectory rather than three re-derivations of it:

```
MG_STEP=core/tests/fixtures/demo/l-bracket.step MG_RES=32 \
  ./core/build/mg_component_sweep stag <dir>
./core/build/alg_level1_probe capture  <dir>
./core/build/alg_level1_probe converge <dir>
./core/build/alg_level1_probe mem      <dir>
./core/build/alg_level1_probe det      <dir>
./core/build/alg_level1_gate  gate     <dir>
```
