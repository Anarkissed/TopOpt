# Evidence — `krylov-recycle-reassessment`

Handoff: `docs/handoffs/2026-08-03-krylov-recycle-reassessment.md`.

All of it produced by one harness, `core/tests/harness/recycle_reassess.cpp`
(built manually; not a CTest target). Rebuild and reproduce with:

```bash
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF
cmake --build core/build --target topopt -j
c++ -std=c++17 -O2 -I core/include -I core/src -I core/tests/harness \
  core/tests/harness/recycle_reassess.cpp core/build/libtopopt.a \
  -o core/build/recycle_reassess
TOPOPT_RRA_DIR=evidence/2026-08-03-krylov-recycle-reassessment \
  ./core/build/recycle_reassess <mode>
```

| file | mode / origin | what it is |
| --- | --- | --- |
| `00-predictions.md` | — | written BEFORE any measurement; graded in §2 of the handoff |
| `regime.txt` `regime.csv` | `regime` | the three fixture classes, pinned and characterised |
| `ab.txt` `ab_rep2.txt` `ab.csv` `ab_raw.csv` | `ab` | **AG1** — the ABBA A/B, latched and healthy, two independent runs |
| `cert.txt` `cert.csv` | `cert` | **AG1(c)** — certification solves, warm and cold basis |
| `phases.txt` `phases.csv` | `phases` | **AG2** — the recycle bill split six ways; closure 99.95 % |
| `phases_wrap1.txt` | `phases` + `TOPOPT_RRA_WRAP=1` | the bill the multigrid call site cannot see |
| `dim.txt` `dim_rep2.txt` `dim.csv` | `dim` | **AG3** — k sweep at `vf=0.50`, two runs |
| `dim_vf020_rep2.txt` | `dim` + `TOPOPT_RRA_VF=0.20` | **AG3** — k sweep at the second operating point |
| `dim_vf020.txt` | same, earlier attempt | **DISCARDED wall column** (host load 57.6); kept so the discard is auditable |
| `cycle.txt` `cycle.csv` | `cycle` | **AG4** — harvest-cadence sweep |
| `wrapmg.txt` `wrapmg.csv` | `wrapmg` | **AG5** — `wrap_multigrid` on the healthy path |
| `exact.txt` | `exact` | **AG7** — exactness (single solve and trajectory) + determinism |
| `byteid_before.txt` `byteid_after.txt` | `geneo_byteid_xbuild` | **AG8** — stash-rebuild fingerprint over a 2-rung production ladder |
| `ctest.txt` | `ctest` | **AG8** — 94/94 passed |

## Reading the numbers

Every table carries **two bars that must not be traded against each other**:

* **DOF-weighted work** = `(CG iterations + recycle setup matvecs) x free DOFs`.
  A deterministic count. Reproduces to three digits on any host under any load —
  check `dim.txt` against `dim_rep2.txt`.
* **Wall**, median per solve, from **interleaved** postures only, with the spread
  printed. The 1-minute host load average is printed at the start and end of
  every run and beside every block.

The host was shared for the whole task (a concurrent task owned the multigrid
coarsening probe); observed load ranged 10 – 58 on 10 cores. Where the load made
a wall column meaningless it was discarded and said so, not smoothed.
