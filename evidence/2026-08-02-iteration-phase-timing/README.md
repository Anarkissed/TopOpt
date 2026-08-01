# Evidence — per-phase iteration timing (2026-08-02)

Handoff: `docs/handoffs/2026-08-02-iteration-phase-timing.md`

This is a DIAGNOSTIC task: it adds measurement and changes no behaviour. Every
artifact here is either a checksum proving that, or a measurement made with the
new instrument.

| file | what it is |
| --- | --- |
| `summarize_phases.py` | The reader used for every table below. Takes an instrumented `iterations.csv`; prints the per-rung phase split, the accounting residue, the solver's internal split and the memory record. Pure reader. |
| `y1_bit_identity.txt` | Bar Y1 + Y6. SHA-256 of `report.json`, `fields.bin`, `build_orientation.json` and all three variant meshes from THREE runs of the same job: the stash-rebuilt pre-instrumentation binary, and two runs of the instrumented one. |
| `y2_instrument_cost.txt` | Bar Y2. The overhead probe's output: the marginal cost of one clock read and one memory sample, the per-iteration read counts, and the resulting percentage against measured iteration walls. The bar is stated in the probe source, before any number. |
| `demo_phase_summary.txt` | The 48-scale gate fixture (`core/tests/fixtures/demo/job.json`, STL output), instrumented. The HEALTHY multigrid regime: what a normal iteration's phase split looks like. |
| `demo_iterations.csv` | That run's raw per-iteration CSV. |
| `ladder32_phase_summary.txt` | Bar Y3/Y4/Y5. The design-box reproduction: l-bracket in a 9.24x design box, the production ladder `[0.68, 0.52, 0.38, 0.26]`, res 32. Reproduces the maintainer's signature — multigrid latched OFF, ultra-dilute design, iterations whose CG arithmetic is a small fraction of their wall. |
| `ladder32_iterations.csv` | That run's raw per-iteration CSV — the primary evidence for the attribution. |
| `ladder32_run_info.json` | Its run record: the armed posture (GenEO on, trigger 500, rebuild factor 2) and the post-run GenEO lifecycle counters. |
| `y5_volume_basis.txt` | Bar Y5. `volume_basis_probe`'s direct COUNT of the part-solid, active-envelope and frozen voxel sets, the effective per-rung target each implies, and the ladder's own rows beside them. Not a fit — a count. |
| `ladder32.json` | The reproduction job, verbatim. |
| `abort20.json` | The fastest configuration that reproduces the pre-existing non-finite-margin abort (used to show it predates this change). |
| `ctest.txt` | Full `ctest` tail after the change: 91/91. |

## Reproducing

```bash
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
# the healthy regime
./build/topopt-cli run core/tests/fixtures/demo/job.json --out out_demo
# the anomaly (see ladder32.json in this directory)
./build/topopt-cli run ladder32.json --out out_ladder32
python3 evidence/2026-08-02-iteration-phase-timing/summarize_phases.py \
    out_ladder32/iterations.csv --rows
```

The overhead probe:

```bash
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
    core/tests/harness/phase_timing_overhead_probe.cpp build/libtopopt.a \
    -o build/phase_timing_overhead_probe
./build/phase_timing_overhead_probe
```

The volume-basis probe (Y5):

```bash
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
    -DVB_MODEL='"core/tests/fixtures/demo/l-bracket.step"' \
    core/tests/harness/volume_basis_probe.cpp build/libtopopt.a \
    -L/opt/homebrew/lib $(ls /opt/homebrew/lib/libTK*.dylib \
      | sed 's|.*/lib\(TK[^.]*\)\.dylib|-l\1|' | tr '\n' ' ') \
    -o build/volume_basis_probe
./build/volume_basis_probe
```

Machine of record: Apple M2 Pro (6P+4E), 16 GB, macOS 25.5.0. The reproduction
run aborts after rung 1 on a PRE-EXISTING non-finite-margin refusal — see the end
of `ladder32_phase_summary.txt`, where the same abort is shown on the
pre-instrumentation binary.
