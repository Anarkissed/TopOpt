# evidence — cell-mode-fit-and-swept-floor (2026-08-07)

Handoff: `docs/handoffs/2026-08-07-cell-mode-fit-and-swept-floor.md`.
Baseline for every A/B bar: **`origin/main` = `d9fe8f7`** (this branch's merge-base).

Every script takes the branch build dir as its first argument and rebuilds the base
side itself from a detached worktree. **They all assert the two binaries differ before
comparing anything** — the CMake target is `topopt_cli` (underscore) and the binary is
`topopt-cli` (hyphen), so `--target topopt-cli` silently builds nothing and both arms
would hash the same stale file.

| file | bar | what it shows |
|---|---|---|
| `s1_disagreement.sh` / `.txt` | S1a, S1b, S1d, R2 | Which function produced `4.931378498`, that `plan_cell_sizes` applies **no** floor, and the failing test first: on the unfixed binary a declared `cell_min_mm: 1.173` produced a refusal **byte-identical** to `cell_mode: "auto"` (same sha256). |
| `r1_byte_identity.sh` / `.txt` | R1 | Seven cases. A/B/C/F/G byte-identical across meshes, `design.bin`, `fields.bin`, `report.json`, the lattice receipts, `run_info.json` (minus named clocks) and `iterations.csv`. D: geometry identical, text deliberately different. E: refused → runs. **Case G is the blocked-stop probe** — the one path where the swept floor reaches geometry. |
| `r3_gate_table.sh` / `.txt` | R3 | 7 swept jobs × 3 rungs, base vs branch. Verdict and margin per rung; voxel-classification flips with a **1e-9 negative control**. 0 flips of 27,691 on every job that ran on both sides; two jobs previously refused now run. |
| `r4_his_case.sh` / `.txt` | R4 | His nine-region job at res 128 in all three modes, with the per-region table (thinnest, cell, density, strut, cells/member, candidates, latticed) and the refusal verbatim. |
| `r5_assertion_census.sh` / `.txt` | R5 | Set difference of **assertion messages** (C++ `CHECK` + Swift `XCTAssert*`) between `origin/main` and the branch. 5,435 → 5,466, none removed. |
| `s3_message_before_after.sh` / `.txt` | S3c, S3d | Characters, logical lines and **wrapped lines at 60 columns**, before and after, for his case and the three other message shapes — plus both texts verbatim. |
| `r2_s2_app_failing_first.txt` | R2 (S2) | The app-side reproduction on **unfixed** sources: 4 tests, 5 failures. |
| `r2_s2_repro_test.swift.txt` | R2 (S2) | That reproduction's source, kept because it was deleted before the branch was pushed (it cannot compile against the fixed enum). |

## Traps this evidence set hit, so the next one does not

* **The base binary bakes in its own worktree's paths.** `r1_byte_identity.sh` removes
  its detached worktree on exit, after which the base `topopt-cli` dies on
  `cannot open materials file` / `cannot open rules file`. The S3 and R3 scripts pass
  `--materials` and `--rules` explicitly, and the S3 script **asserts the BEFORE arm
  actually reached the pre-flight** — without that guard it silently measured a
  four-word error message against a full refusal and reported a *+1035 %* "improvement".
* **`grep -q "lattice"` is not a guard when the scratch path contains the word
  "lattice".** The first version of that check passed on a log whose only mention was
  the worktree name.
* **Core refuses `cell_mode: "fit"` with no include region.** Any fixture — including a
  schema *probe* document — that omits one measures that rule instead of the intended
  one. This made the app's capability probe report `fit` unsupported on a core that
  supports it.
