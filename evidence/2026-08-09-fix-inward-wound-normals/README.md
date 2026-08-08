# evidence — fix-inward-wound-normals (2026-08-09)

Task `2026-08-09-fix-inward-wound-normals`. Handoff:
`docs/handoffs/2026-08-09-fix-inward-wound-normals.md`.

Branch `claude/fix-inward-wound-normals-7c1a20`, **stacked on**
`strut-clip-matches-shell` (`c586e8d`) — this branch edits that task's
`mesh_distance.cpp` and `test_lattice_clip_shell.cpp`, so every baseline here is
`c586e8d` and NOT `main`. The assertion census takes that baseline explicitly
(`BASE_REF` defaults to `HEAD`); censusing against `main` would credit this PR
with the other one's assertions.

## The three runs everything is compared across

All three are the SAME job — his captured document + `M2_verticalStand.step` at
resolution 128, four rungs — reused verbatim from
`evidence/2026-08-08-strut-clip-matches-shell/job_his_2mm_skinnone.json`.

| run | binary | what it is |
|---|---|---|
| **runB** | `topopt-cli-after` | strut-clip-matches-shell as merged: shell clip armed, **inward** winding |
| **runC** | `topopt-cli-wound` | this branch: same, plus **outward** winding |

The two binaries are asserted to differ by sha256 before anything is compared
(`b_protrusion_remeasured.txt` / `r4_gate_table.txt` headers).

## Files

| file | what |
|---|---|
| `s1_producer_map.txt` | **read this first** — every mesh producer's winding, MEASURED, and the map of synthesizers / importers / transformers / compensations it establishes |
| `s1_winding_probe.cpp` | the probe that produced it |
| `r2_red.txt` / `r2_green.txt` | the new `mesh_winding` ctest failing first (6 failures) then passing |
| `r1_geometry_unchanged.py` / `.txt` | ★ **the precise claim**: every facet of his exported meshes is the SAME triangle, unchanged or reversed, none unmatched. "The bytes differ" is not a bar; this is. |
| `b_protrusion_remeasured.txt` | §A(b) — PR 316's no-protrusion invariant re-measured on both fixtures after the flip |
| `r4_gate_table.txt` | §A(b) on HIS run + the gate table: protrusion, margins, volumes, per rung, runB vs runC |
| `r6_assertion_census.txt` | the message census, baselined on `c586e8d` |
| `ctest_full.txt` | both CI jobs: core 116/116, app package 1367 tests / 0 failures |

## The one assertion message the census reports as REMOVED

```
"marching_cubes output is wound inward — if this flips, re-check every sign in this file"
```

That is deliberate and it is the point of the change. It was
`CHECK(md.inward_wound())` in `test_lattice_clip_shell` case 0; it is now
`CHECK(!md.inward_wound())`. Before the fix, PR 316's no-protrusion invariant was
correct BECAUSE `MeshDistance` compensated for the inward winding at build time.
After it, the compensation does not fire and the invariant's zero comes from the
geometry. That assertion is the receipt for which of the two is doing the work —
so it had to flip, and the census flagging it is the census working.
