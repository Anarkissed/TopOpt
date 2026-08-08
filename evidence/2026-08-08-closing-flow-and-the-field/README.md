# 2026-08-08-closing-flow-and-the-field

Evidence for task `closing-flow-and-the-field`. Two independent questions:

* **S1** — does a morphological CLOSING (an operator that ADDS material) remove
  the staircase on the optimizer-cut population, where three FILTERS have now
  failed? **NO-GO, and the reason is the geometry, not the operator.**
* **S2** — does the pre-binarization density field still carry sub-voxel
  information the mesh threw away? **NO — the field is binary at the boundary,
  and the exported surface is already exactly on its level set.**

| file | what |
|---|---|
| `s1_closing_flow.txt` | full S1 run: the sign control, the crevice-radius distribution, four operator arms x four radii x four rungs, the C4-off calibration, the cost-per-stroke table |
| `s1_closing_flow.csv` | the same rows, machine-readable, PR 314's column set plus the closing-specific ones |
| `s1_sign_control_caught_it.txt` | the positive/negative control that FIRED, the two defects it caught, and the reading after both fixes |
| `s2_field_information.txt` | full S2 run: density histograms, boundary-voxel grayscale, the marching-cubes crossing statistic, the vertex-position fit and its control |
| `s2_field_information.csv` | the per-rung S2 summary. **Every crossing column names its lattice** — `design_*` is the field's own information, `shipped_*` is that plus whatever the tricubic resample interpolated into being. They give opposite-looking answers; see §S2.3 of the handoff before quoting either. |
| `r2_reproduces_pr314_rows.txt` | the Taubin rows against PR 314's committed CSV — 8 shared rows, 64 fields, 0 differing |
| `s2_brief_premise_correction.txt` | `conditional_projection_fired` is `[true,true,true,true]`, not `[false,true,true,true]` |
| `r1_no_production_change.txt` | `git diff main -- core/src core/include app/TopOptKit/Sources` is empty, and why two harness files are carried from PR 314's unmerged branch |
| `r5_instrument_move_and_census.txt` | the 232-line instrument move verified verbatim, and PR 306's committed output reproduced |
| `ctest.txt` | the core suite at CI's full denominator |

Reproduce:

```bash
./app/scripts/build_cli_macos.sh
cmake --build core/build -j8 --target closing_flow_probe field_information_probe
D=evidence/2026-08-03-multiscale-lattice-to
E=evidence/2026-08-08-closing-flow-and-the-field
./core/build/closing_flow_probe      $D/m2_multiscale_final/design.bin $D/M2_verticalStand.step $E
./core/build/field_information_probe $D/m2_multiscale_final/design.bin $D/M2_verticalStand.step $E
```
