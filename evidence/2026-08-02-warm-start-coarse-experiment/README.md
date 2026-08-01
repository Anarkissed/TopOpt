# Evidence — does `warm_start_coarse` rescue the startup transient? (2026-08-02)

Handoff: `docs/handoffs/2026-08-02-warm-start-coarse-experiment.md`

This task MEASURES a built-but-unreachable option and changes NO default. The
gate is untouched.

| file | what it is |
| --- | --- |
| `e0_expected_before_measuring.md` | **AC1's pre-registration.** Eight numbered predictions with mechanisms, written and committed BEFORE the first experimental run so they cannot be fitted to the result. Read this first, then the tables. |
| `summarize_run.py` | Pure reader for an instrumented CLI `iterations.csv` + `run_info.json`: per-rung iterations, wall, stagnating-iteration count and the wall inside them, the compliance-settle iteration, and the pre-solve's own cost on its own line. |
| `healthy48_cold.json` / `healthy48_warm.json` | The res-48 no-design-box demo job, unarmed and armed, used to prove the new `"warm_start"` block reaches `MinimizePlasticOptions` through the production CLI path. |
| `stag_gate.csv` / `healthy_gate.csv` / `nobox_gate.csv` | The harness's per-rung tables: verdict and margin OFF -> ON, compliance both ways, iterations, wall, stagnating iterations and their wall, the settle iteration, and mean/max \|Δρ\| **beside the 1e-9 negative control's own value on the same rung**. |
| `harness_transcript.txt` | The full harness transcript for all three fixtures — every ladder, the determinism checks, the DOF-weighted headline, the gate table and the compliance comparison. The primary record. |
| `wall_noise_demo.txt` | **Why wall is not evidence here.** Three runs of the IDENTICAL OFF posture, same fixture, deterministic solver, all 394 iterations: 1034.9 / 1200.7 / 1255.7 s — a 21.3% spread on identical work. Also shows the pre- and post-instrument binaries producing the same 394 iterations, i.e. the added counters observe without perturbing. |
| `byte_identity_check.sh` | THE ONE RULE check: same job through the pre-change and post-change binaries, comparing `report.json` / `design.bin` / `fields.bin` / meshes. `run_info.json` is excluded BY NAME and on purpose — this task deliberately adds observability keys to it. |
| `host_load.txt` | **The measurement conditions.** This host was shared with other agents' benchmark runs for the whole window; see the handoff §3. Recorded rather than hidden, because a wall ratio measured under contention is not evidence — the same reason handoff 2026-07-29-geneo-arming refused to cite one. |
| `ctest.txt` | Full `ctest` tail (AC8). |
| `byte_identity.txt` | That script's output. |

## The result in one line

`warm_start_coarse` **eliminates the transient on the fixture it was designed for**
(rung 0: 128 -> 58 iterations, 1 -> 0 stagnating iterations, compliance settling at
iteration 9 instead of 43) but **loses on both honest controls**, and **loses
outright in the persistently-stagnating regime it exists to fix** (+7.2% work,
+26% compliance on one rung). Recommendation: **DO NOT ARM.**

## The harness

`core/tests/harness/warm_start_coarse_gate.cpp` — standalone, NOT wired into
CTest, a sibling of `ad_disarm_gate.cpp` whose three fixtures, 1e-9
negative-control discipline and comparison quantities (5-class flips, printed
flips at kIso = 0.5) it reuses verbatim so the two tables read side by side.

```bash
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
    -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
    core/tests/harness/warm_start_coarse_gate.cpp build/libtopopt.a -o /tmp/wscg
TOPOPT_WSC_DIR=evidence/2026-08-02-warm-start-coarse-experiment /tmp/wscg all
```

Three postures per fixture, each run TWICE (AC7 determinism):
`OFF` = shipped default · `ON` = `warm_start_coarse` · `CTL` = OFF under a 1e-9
relative load nudge, the noise floor.

## Arming it on a real job (the plumbing this task added)

```bash
./build/topopt-cli run job.json --out out
```
with, in `job.json`:
```json
"warm_start": { "coarse": true }
```
Absent block => the driver keeps its OFF default and the run is byte-identical.
`run_info.json` then reports `warm_start_coarse`, plus the pre-solve's own
`warm_start_coarse_iterations`, `warm_start_coarse_ms` and
`warm_start_coarse_matvecs` — the price, in both currencies, beside the posture.

Machine of record: Apple M2 Pro (6P+4E), 16 GB, macOS 25.5.0 — the same machine
as `evidence/2026-08-02-iteration-phase-timing/`.
