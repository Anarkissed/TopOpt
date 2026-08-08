# evidence — semdot-does-it-come-out-smoother (2026-08-08)

Task: **does the optimizer produce smoother geometry on HIS part?** SEMDOT
(Smooth-Edged Material Distribution for Optimizing Topology) built as an opt-in
second mode beside SIMP, and measured on the maintainer's own captured job at
resolution 128, all four rungs, against the SIMP path.

Handoff: `docs/handoffs/2026-08-08-semdot-does-it-come-out-smoother.md`.

Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang, library Release.
**The host was NOT idle** — two other worktrees ran their own solver jobs
throughout; `host_contention.txt` samples the load and every process over 50% CPU
once a minute, for the whole of S2, so the wall numbers can be read with that in
front of them rather than behind them. **Iteration counts are unaffected by it and
are the primary cost reading; wall is reported separately (bar R6) and second.**

## the two arms

| file | what it is |
|---|---|
| `job_simp.json` | `evidence/2026-08-03-multiscale-lattice-to/job_twostep.json` — his own captured job document from `~/.topopt-worker` — with its `lattice` and `grading` blocks removed |
| `job_semdot.json` | the same document plus `"semdot": {"enabled": true, "grid_points": 4}`, and nothing else |
| `M2_verticalStand.step` | his part |
| `s2_simp_preflight_refusal.txt` | why the blocks came out: the cell-fit pre-flight refuses his document as captured on current main (5 of 8 declared include regions are thinner than the planned 4.6026 mm cell). Verbatim. |
| `run_s2.sh` | runs both arms sequentially; the header states why the classic document and not the multiscale one |

The lattice/grading blocks do not reach the optimizer on a non-multiscale job —
the complete list of lattice keys that touch `MinimizePlasticOptions` is behind
`job.lattice.multiscale` at `core/src/cli/run_job.cpp:7181-7195` — so `design.bin`
and `variant_*.stl`, the only artifacts this task reads, are unaffected.

## S2 — the measurement

| file | what it is |
|---|---|
| `s2_semdot_vs_simp.csv` | the geometry table, both arms, every rung |
| `s2_surface_probe.txt` | the probe's full output |
| `s2_cost_and_verdict.csv` / `.txt` | compliance, margin, verdict, achieved vf, and **iterations and wall SEPARATELY** (R6), split further into the grayscale phase and SIMP's β-polish phase, which has no SEMDOT counterpart |
| `s2_simp/`, `s2_semdot/` | the two runs' artifacts (`design.bin`, `report.json`, `run_info.json`, `iterations.csv`, `variant_*.stl`) |

Probe: `core/tests/harness/semdot_surface_probe.cpp`. It **includes** PR 299's
`stairstep_metric.hpp` and PR 306's `surface_instruments.hpp` — it does not retype
them (bar R3) — and uses PR 307's `attribute_to_cad_faces` for the CAD/cut split.

```
cmake --build core/build --target semdot_surface_probe
./core/build/semdot_surface_probe s2_simp/design.bin s2_semdot/design.bin \
    M2_verticalStand.step .
./s2_cost_and_verdict.py .
```

## S3 — read only

`s3_lattice_law_reading.txt` — every read of the design density in the lattice
law, with file and line, and the verdict: **works unchanged for the classic law,
breaks for the multiscale one**, at two lines with one cause.

## the bars

| file | bar |
|---|---|
| `r1_byte_identity.sh`, `r1_byte_identity.txt`, `r1_byteid/` | R1 — off is byte-identical, base **detached worktree** vs branch, artifact checksums |
| `r1_app_build.txt` | R1 — the second build output (`app/scripts/build_core.sh` + the package tests) |
| `r1_refactor_neutrality.txt` | the three `std::move` / dead-copy cleanups made after the S2 binary was pinned, proved behaviour-neutral by byte-comparing a re-run of the smoke job |
| `s2_binary_of_record.txt` | the sha256 of the one `topopt-cli` **both** S2 arms ran |
| `ctest_full.txt`, `ctest_116.txt` | the suite, at CI's denominator (116 — the local default is 114 because lib3mf is not on the Homebrew path; see the note in `ctest_116.txt`) |
| `r7_assertion_census.py`, `r7_assertion_census.txt` | R7 — assertion/throw **message** census, comment-stripped and multi-line aware, base vs branch |
| `host_s2.txt`, `host_contention.txt` | the host, before/between/after, and the contention that was on it |
