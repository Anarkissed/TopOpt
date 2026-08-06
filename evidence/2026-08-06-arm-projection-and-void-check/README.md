# Evidence — `arm-projection-and-void-check`

Handoff: [`docs/handoffs/2026-08-06-arm-projection-and-void-check.md`](../../docs/handoffs/2026-08-06-arm-projection-and-void-check.md)

Both defaults are armed in core:
`output.project_cad_faces` and `lattice.require_lattice_void_reaches_exterior`.
**The default path changes on purpose, so nothing here claims byte-identity for
it** — it is measured instead. Byte-identity is still claimed, and proved, with
both switches OFF.

Nothing large is committed. Every run output, mesh and certification lived in the
session scratchpad; what is here is the scripts that produce them and the text
they produced.

## The bars

| file | what it shows |
|---|---|
| `r3_failing_test_core.txt` | **R3** — the test failing on the merge-base tree, printing the OLD default (`= false`) rather than only failing. |
| `r3_passing_test_core.txt` | the same test after the flip: 10/10, the same lines now `= true`. |
| `r1_byte_identity.sh` / `.txt` | **R1** — with BOTH switches off, 11 artifacts byte-identical across two separately built binaries. Guards itself: exits non-zero if the two binaries hash the same. |
| `r1_table_128.py` / `.txt` | **R1** — his part, resolution 128, all four rungs: exported volume, mesh mass, every bolt bore, every flat face, motion and guards. |
| `r1_cert_table.py` / `.txt` | **R1** — certified margin and verdict, before and after, all four rungs. **The verdict does not move.** |
| `r1_before_after.py` | **R1** — the default-path runner: same job document, two binaries, neither key present. |
| `r1r2_analysis.py` / `r1r2_defaultpath_res64.txt` | **R1 + R2** — the default-path before/after and the voxel-flip table, with the 1e-9 negative control run first. **0 flips.** |
| `r4_end_to_end.sh` / `.txt`, `r4_app_bytes.txt`, `app_blocks_*.json` | **R4** — the app's REAL serializer output, written to disk, fed to the real CLI, in all four combinations. Both effects visible in the result; the two switches move independently. |
| `r5_assertion_census.sh` / `.txt` | **R5** — assertion-message census, merge base vs branch. 1 C++ message lost (named and accounted for), 0 Swift test functions lost. |
| `ctest.txt` | **112/112 passed.** |
| `app_tests.txt` | 1334 app tests, 8 failures — all pre-existing 3MF, **proved** by rerunning with this task's `app/` changes stashed (8 failures either way). |

## The sections

| file | what it shows |
|---|---|
| `s1d_mass_audit.md` | **S1(d)** — every mass and volume the app displays, with file:line and MESH-vs-VOXEL provenance. Nothing was changed. Includes the measured before/after and the warning that the −8% is his part's, not the feature's. |
| `s2e_refusal_sweep.py` / `.txt` | **S2(e)** — every committed job document run through BOTH binaries so a new refusal is attributable. Partial at the time of writing; skip list printed in full. |
| `s3_mesh_flood_fill.py` / `.txt` | **S3** — a 6-connected flood fill on the EXPORTED GEOMETRY, all four rungs at 128, **swept across three measuring grids**. No pore seals. The sweep is the point: a single grid showed a 6960 mm³ cavity that vanished at every finer one. Refuses to print a cavity count for a non-watertight mesh, because parity has no defined inside on one. |

## Reproducing

```bash
# two binaries from ONE build folder (the guard requires them to differ)
cmake --build core/build --target topopt_cli -j8     # NOT topopt-cli — that no-ops

./evidence/2026-08-06-arm-projection-and-void-check/r1_byte_identity.sh \
    <base-cli> <branch-cli> /tmp/r1_byteid

./evidence/2026-08-06-arm-projection-and-void-check/r1_before_after.py \
    <base-cli> <branch-cli> /tmp/r1_work
./evidence/2026-08-06-arm-projection-and-void-check/r1r2_analysis.py \
    /tmp/r1_work core/build/cad_project_probe <branch-cli>

cmake --build core/build --target cad_project_probe -j8
./core/build/cad_project_probe <part.step> 128 /tmp/probe <variant>.stl ...
./evidence/2026-08-06-arm-projection-and-void-check/r1_table_128.py /tmp/probe

./evidence/2026-08-06-arm-projection-and-void-check/s3_mesh_flood_fill.py 128 <mesh>.stl ...
./evidence/2026-08-06-arm-projection-and-void-check/s2e_refusal_sweep.py \
    <base-cli> <branch-cli> /tmp/s2e 48

TOPOPT_R4_OUT=$PWD/evidence/2026-08-06-arm-projection-and-void-check \
  swift test --package-path app/TopOptKit --filter DefaultArmingEvidenceGen
./evidence/2026-08-06-arm-projection-and-void-check/r4_end_to_end.sh <branch-cli> /tmp/r4
```

`s3_mesh_flood_fill.py` needs numpy and scipy. Everything else is stdlib.
