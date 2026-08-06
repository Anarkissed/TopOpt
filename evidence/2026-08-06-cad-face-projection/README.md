# Evidence — 2026-08-06-cad-face-projection

Handoff: `docs/handoffs/2026-08-06-cad-face-projection.md`

Subject throughout: **`M2_verticalStand.step`** at **resolution 128**
(one voxel = **1.705279 mm**), and the four ladder rungs
`variant_026 / 038 / 052 / 068.stl` from
`evidence/2026-08-03-multiscale-lattice-to/m2_multiscale_final/`.

## The measurements

| file | what it is |
|---|---|
| `s1_probe.txt` | S1 + S2 in full, all four rungs: the CAD-vs-optimizer-cut split by area and by vertex, the distance-to-CAD histogram behind the one-voxel tolerance, the deviation of each population separately, the reviewer's `variant_068.stl` reading reproduced-and-refuted, and the attributor cross-check. Produced by `core/tests/harness/cad_face_probe.cpp`. |
| `s1_split.csv` | the split, per rung, as data |
| `s1_deviation.csv` | deviation-from-CAD per population, per rung |
| `s1_histogram.csv` | distance-to-CAD in quarter-voxel bins, per rung |
| `s3_probe.txt` | S3 + S4 in full, all four rungs: bore roundness and face flatness before/after, how far anything moved, the signed direction of the error (the oversize finding), the seam, the fold guard, and the tolerance × band × guard decision table. Produced by `core/tests/harness/cad_project_probe.cpp`. |
| `s3_probe_068.txt` | the same, rung 068 alone |
| `s3_bores.csv` | every cylindrical face, before and after, per rung |
| `s3_flats.csv` | every planar face, before and after, per rung |
| `s3_motion.csv` | attribution and displacement counts, per rung |
| `variant_068_projected.stl` | the projected mesh for the finished rung, as the shipped settings produce it — the R3 certification's input, and the one to look at. The other three rungs' projected meshes are reproducible from the command below and are not committed (14–16 MB each). |

## The bars

| file | bar |
|---|---|
| `r1_byte_identity.sh`, `r1_byte_identity.txt`, `r1_job.json`, `r1_work/` | **R1** — `topopt-cli` built twice from one build folder (branch, then with `core/` stashed), same job run with each, every artifact compared by sha256. **R1 MET**, 8 artifacts identical. The script REQUIRES the two binary hashes to differ, so the comparison cannot pass vacuously. `r1_work/` keeps the per-arm build logs, binary hashes and artifact hash lists; the two output trees themselves are deleted after comparison. |
| `r1_first_attempt_invalid.txt` | the FIRST R1 run, kept rather than deleted: it built `--target topopt-cli` (hyphen), which no-ops, so both arms hashed the same stale binary. The guard reported `R1 INVALID`. |
| `r2_failing_test.txt` | **R2** — `test_cad_project` with the projection stubbed to a no-op: 3 failures, exit 1. |
| `r2_passing_test.txt` | **R2** — the same test against the real implementation: 31 checks, 0 failures. |
| `r3_cert_original.log`, `r3_cert_original/` | **R3** — `topopt-cli analyze --mesh variant_068.stl` |
| `r3_cert_projected.log`, `r3_cert_projected/` | **R3** — the same job on the projected mesh. Margin +0.4178%, mass −8.03%, verdict ACCEPTED both. |
| `job_analyze.json` | the analyze job both R3 runs used (the multiscale job's material, resolution, model and load block, mode `analyze`) |
| `r5_deleted_assertions.txt` | **R5** — the deleted-assertion sweep and its accounting |
| `ctest.txt` | 107/107 tests pass |

## Reproducing

```bash
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target cad_face_probe cad_project_probe test_cad_project topopt-cli -j 10

E=evidence/2026-08-03-multiscale-lattice-to
V=$E/m2_multiscale_final
O=evidence/2026-08-06-cad-face-projection

./core/build/cad_face_probe    $E/M2_verticalStand.step 128 $O \
    $V/variant_026.stl $V/variant_038.stl $V/variant_052.stl $V/variant_068.stl
./core/build/cad_project_probe $E/M2_verticalStand.step 128 $O \
    $V/variant_026.stl $V/variant_038.stl $V/variant_052.stl $V/variant_068.stl
./core/build/test_cad_project
bash $O/r1_byte_identity.sh
```

Both probes are harnesses, not ctests: they print tables and write CSV, and they
assert only the preconditions that would make their own numbers meaningless —
`cad_face_probe` exits non-zero if its own distance reading and the shipped
attributor stop partitioning the same population.
