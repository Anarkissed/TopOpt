# Evidence — orientation scoring probe (2026-08-01)

Handoff: `docs/handoffs/2026-08-01-orientation-scoring-probe.md`

PROBE ONLY. Nothing here gates anything; no production source was changed.

| file | what it is |
|---|---|
| `00_bar_declared_before_measuring.md` | The GO/NO-GO bar and the predictions, written **before** the probe was run. Unedited since — S4's honesty depends on it. |
| `01_call_graph.txt` | `grep` output for every orientation entry point across core, app and bridge. Establishes what actually calls what (and corrects three premises in the task brief). |
| `02_ctest_full.txt` | Full `ctest` log: 89/89 passed, including the new `orientation_invariants` test. |
| `03_byte_identity.txt` | S6. sha256 of an ordinary CLI run from this branch vs an independent build at HEAD, plus a second run of the same binary proving the only differences are wall-clock stamps. |
| `probe_run.txt` | The probe's full output: the S-e instrument, three cases, the 26x12 trade-off table, S1 cheap-vs-expensive, S2 self-checks, S4 ratios, S5. |
| `orientation_scores.csv` | Machine-readable: every candidate x every criterion, all three cases. 20 columns. |
| `strut_angle_histogram.csv` | Per-candidate octet strut elevation histogram (nine 10-degree bins) plus flattest and mean elevation. |

## Reproducing

From `core/`:

```bash
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF && cmake --build build -j
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    -DORIENT_FIXTURE_DIR='"tests/fixtures/orient"' \
    -DMATERIALS_JSON='"src/materials/materials.json"' \
    tests/harness/orientation_scoring_probe.cpp build/libtopopt.a \
    -o build/orientation_scoring_probe
TOPOPT_ORIENT_CSV_DIR=../evidence/2026-08-01-orientation-scoring-probe \
    ./build/orientation_scoring_probe
```

Runtime ~3 s. Deterministic (no RNG, no threads): the sphere samples are a
golden-angle spiral, so re-running reproduces every number to the bit.

The invariants the probe relies on are additionally pinned in CI:

```bash
./build/test_orient_invariants     # 320 checks
```
