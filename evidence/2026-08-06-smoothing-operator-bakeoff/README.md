# evidence — smoothing-operator-bakeoff

Handoff: `docs/handoffs/2026-08-06-smoothing-operator-bakeoff.md`

| file | what it is |
| --- | --- |
| `bakeoff_probe.txt` | the full run of `operator_bakeoff_probe`: the 29-row sphere bake-off (§S3.1), the C1-by-construction test for operator B (§S3.2), the validated instruments (§S3.3), the tendril table (§S3.4), and wall time per stroke at his mesh size (§S3.5) |
| `sphere_bakeoff.csv` | the same sphere table, machine-readable |
| `r2_failing_first.txt` | bar R2 — C1, C2, C3 and the normal orientation each DISABLED in `core/src/mesh/surface_operator.cpp` in turn, with the unmodified `test_surface_operator` re-run and its failures pasted; all constraints restored at the end |
| `r1_byte_identity.txt` | bar R1 — stdout checksums of 11 shipped test binaries across a baseline worktree at `90e9ec5` and this change, plus the two vacuity guards (at least 5 binaries compared; the two `libtopopt.a` archives demonstrably differ) |

## Reproducing

```bash
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j8 --target test_surface_operator operator_bakeoff_probe
./build/test_surface_operator
./build/operator_bakeoff_probe evidence/2026-08-06-smoothing-operator-bakeoff
```

`operator_bakeoff_probe` uses nothing from OCCT, so it builds in every
configuration — unlike `stairstep_probe`, whose fixture it otherwise reproduces
exactly (R = 20 mm sphere, spacing 1.620040 mm, export factor 2, tricubic, through
the STL round trip: 11232 verts, rms 0.3307 mm, max 0.7266 mm, matching PR 299
§S1(d) and PR 303 digit for digit).

## What is NOT here

The classifier from `cad-face-projection` had not landed, so there is no
measurement on the cut population: no §0 re-baseline of Taubin or the SDF route, no
per-rung comparison on his part, and no C4 assertion. The SDF figure quoted in the
handoff (58.9% on this sphere) is **read from PR 303's own evidence** on the
unmerged branch `claude/smoothing-sdf-geometry-477925`, not re-measured here.
