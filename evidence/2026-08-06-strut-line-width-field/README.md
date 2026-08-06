# evidence — strut-line-width-field (2026-08-06)

Handoff: `docs/handoffs/2026-08-06-strut-line-width-field.md`.
This is **S2** of `strut-line-width-provenance`; S1 is PR #304
(`docs/handoffs/2026-08-05-strut-line-width-provenance.md`, diagnosis only).

★ **Two separate things live in this directory and they must not be conflated.**

* **THE DEFECT (S0).** `production_loadcase_from_job` dropped
  `wall_line_width_outer_mm` on the job.json / LAN-worker path. That is a
  regression being *corrected*. It rides `loads.wall_line_width_outer_mm`.
* **THE DECISION (S2).** The lattice strut floor now has its own field, defaulting
  to `max(outer, inner)` = 0.45 mm on the shipped profile instead of the 0.42 mm
  outer wall bead. That is a deliberate *change*, measured as one. It rides
  `lattice.min_extrudable_width_mm` / `grading.min_extrudable_width_mm`, a
  different key the drop never touched.

| file | bar | what it is |
|---|---|---|
| `S0_failing_test_before_fix.txt` | R2 | the new round-trip test run against the UNFIXED copy: job says 0.42, load case gets −1.0 (the mirror-inner sentinel), wall ring `t` 2.25 mm instead of 2.22 mm |
| `S0_test_after_fix.txt` | R2 | the same test after restoring the assignment |
| `S0_ledger_tripwire.txt` | S0(b) | a probe field added to `JobLoadCase` and NOT copied: the structured-binding ledger stops the build — *"type 'const JobLoadCase' decomposes into 14 elements, but only 13 names were provided"* |
| `S2_missed_call_site_tripwire.sh` / `.txt` | R2 | the missed-call-site failure reproduced in BOTH directions: one lattice site reverted to the wall bead, and the strut width wired into a wall-loop consumer. Both guards fail; the tree is restored |
| `S3_probe_fit_flips.txt` | S3 | `probe_fit_flips` with the new field in force. PR #301's control floor vs PR #302's derivation at 0.45 mm — **delta 0.000e+00 mm, AGREE** — plus the FIT table at both widths |
| `S4a_byte_identity.sh` / `.txt` | R1 | four cases: equal beads with and without a lattice (must be byte-identical), and two positive controls that must move |
| `S4b_flip_table.sh` / `.txt` | S4(b) | the full flip table for the case that moves, on a thin (4 mm) and a thick (12 mm) region, against a 1e-9 mm negative control |
| `S4c_his_part.sh` / `.txt` | S4(c) | WallMount_ShelfBracket.stl at resolution 128, both widths side by side, per region: derived cell, density, strut, cells per member, candidates, latticed — and whether the verdict moved |
| `R4_assertion_sweep.txt` | R4 | the deleted-assertion sweep over `core/tests` and `app/TopOptKit/Tests` |
| `R7_test_suites.txt` | — | the full core `ctest` and the full Swift package suite |

Reproduce (from the repo root, Release build in `core/build`, vendored core
rebuilt with `./app/scripts/build_core.sh`):

```
export BASE_REF=56058c202db59656aa31c3da150d20f6ee776e35
cmake --build core/build --target topopt_cli probe_fit_flips test_job_loadcase_copy
./core/build/test_job_loadcase_copy
./core/build/probe_fit_flips
evidence/2026-08-06-strut-line-width-field/S4a_byte_identity.sh core/build /tmp/s4a
evidence/2026-08-06-strut-line-width-field/S4b_flip_table.sh    core/build /tmp/s4b
evidence/2026-08-06-strut-line-width-field/S4c_his_part.sh      core/build /tmp/s4c 128
evidence/2026-08-06-strut-line-width-field/S2_missed_call_site_tripwire.sh
```

★ **The CMake target is `topopt_cli` (underscore); the binary is `topopt-cli`
(hyphen).** `--target topopt-cli` finds an existing file, declares it up to date and
builds nothing. `S4a_byte_identity.sh` asserts the base and branch binaries **differ**
before it compares a single artifact.

★ **`BASE_REF` is this branch's merge-base with `main`** — commit
`56058c202db59656aa31c3da150d20f6ee776e35`, the merge of PR #304. PRs #301, #302 and
#303 are all in it, so the app files S2 touches are stable and no other branch's
movement is folded into these numbers.
