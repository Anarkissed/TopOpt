# Handoff — 2026-11-01-lattice-types-k1: the strut and sheet generators, one type at a time (TRACK core)

Branch `claude/lattice-types-k1`, from `origin/claude/flexible-screens` at `da6cbd9f` (K0's
`0a5f86df` is in it). Plan: `docs/design/lattice-types/`. Previous core handoff:
`docs/handoffs/2026-09-28-lattice-types-core.md` (K0). Evidence:
`docs/handoffs/evidence/2026-11-01-lattice-types-k1/`.

## Where this stands, in plain language

**Live: FCC, Kelvin, Rhombic dodecahedron, Diamond, BCC, Simple cubic**: every strut type of K1
(rhombic without Doubled cells: measured, its struts do not meet across a halving). **BCC and SC are
offered for Structural parts only** (Finding 6, ruled 2026-11-02).

**Live (K2, the sheets): Gyroid, Schwarz-D**, with one cell size for the whole part (Doubled and
Stepped refused, R5) and a Rim or no skin (Diagrid refused, R8). A 4 mm sheet needs members
36-40 mm across and costs 15-19 times octet's triangles a cell (Findings 8 and 9). Not
print-tested.

Parked: none.

**The rulings of 2026-11-02**, in the order ruled, each pushed when its gate is green:
1. Finding 6 + Finding 7 (a)+(b) + ruling (3): **DONE** (`e2b1bf5c`, `a717389e`, `c009fa30`; the
   section below). Every cell over a latticed voxel is laid, struts and nodes are emitted at the
   round strut's area and the sphere's volume, and every run measures what its file holds and
   certifies the lesser of that and the law. On the stand every type's file is within 10 % of its
   certificate on the light side (worst -3.5 %), with 0 floating pieces.
2. (c) octet made honest: **DONE** (`262b731f`, `3a1b9b3d`; the section below). Octet's law and
   tensor are the full cell's, the one the generator lays. On the stand its file holds what its
   certificate credits (+0.0 %, it was +28-30 %), and no rung flips. Auto's octet cell at a 0.45 mm
   bead is 7.03 mm (it was 4.93), and a plan saved on the old law near the print limit is refused,
   naming the cell.
3. Finding 8 (sheet triangles), the coupon, the samples: queued, in that order.

<!-- STATUS -->

## Rulings of 2026-11-02, step 1: Findings 6 and 7, ruling (3) — DONE (`c009fa30`)

What changed (core only):

1. **Finding 6: BCC and SC are Structural only.** `LatticeTypeFacts` carries `structural` and
   `aesthetic`, each `{allowed, reason}`. `aesthetic` is refused when the type's R11 ceiling lies
   below its band (BCC, SC), with one plain line, e.g. "BCC is offered for Structural parts only:
   its thinnest certifiable strut is 0.219 of the cell, already wider than the open-print limit of a
   fifth of the cell, so no BCC density prints open (Finding 6)." A job with aesthetic intent and
   one of those types is refused with the same words (`job.cpp`).
2. **Finding 7, activation by COVER.** A cell is laid when it overlaps a latticed voxel's volume, not
   only when it holds the voxel's centre (`cells_covering_span`, `cell_plan.hpp`; the graded, uniform,
   design-box/roles and stepped activations, the added-material policy, the cell plan's aggregation
   and rejection reasons, the certification mask). A voxel stays latticed only when EVERY cell over
   it can be laid; otherwise it goes solid at its graded density and is counted in
   `solid_fallback_voxels`. So a latticed voxel is now filled completely, and a voxel that cannot be
   is solid, never four-fifths empty. Audits gain `voxels_strut_and_solid_bond`.
3. **(b) equal AREA prisms and equal VOLUME nodes** (Finding 2 fixed). The 8-gon prism is emitted at
   r x 1.0539 (its area equals the round strut's) and the icosahedral node at circumradius x 1.1824
   (its volume equals the sphere's): `lattice_strut_emit_scale`, `lattice_node_emit_scale`
   (`lattice_gen.hpp`). The clip, the node drop, the anchor balls and the skin's radius read the
   emitted size. Organic keeps the raw shapes (`lattice_emit_prism`, `lattice_emit_icosahedron`).
   On a single cell every K1 type's exported fraction is within 0.7 % of its law after (b).
4. **The volume check** (`lattice_volume_check.hpp`). The run rebuilds the exact pieces it emitted
   (prisms, icosahedra, skin and rim prisms; a sheet's own inside test on the contoured wall) and
   measures each latticed voxel's solid fraction (Halton points, deterministic). Pockets are the
   face-connected latticed voxels; a pocket smaller than one cell is listed but not judged.
   **(a) One-sided LOW:** a rung is refused only when a judged pocket holds more than 10 % LESS than
   certified (`kLatticeVolumeGapLimit`); the high side is reported ("file +N % over certified") and
   never refuses. A refused rung's files are removed and the ladder moves on.
5. **(3) The certificate is rebuilt from what shipped.** Each latticed voxel is certified at
   min(the law's density, the measured fraction), never below the band floor
   (`lattice_certify_shipped`); the 10 % check then judges THAT certificate. Where the file is light
   the margin drops; where it is heavy the law's density stands.
6. **Receipts.** Each lattice receipt has a `volume_check` block (rule, limit, pockets judged and not,
   certified and exported mm3, the overall gap, the lightest and heaviest judged pocket, the high-side
   line, voxels lowered to the file and held at the floor, the law's own gap, refused); the run's
   lattice block aggregates them (`volume_check: {refused_variants, worst_gap, ...}`).

### The flip table (M2 stand, Structural ladder; before = `eede708a`, after = `c009fa30`)

Full table with cells, density range, mass, margin and every pocket gap: `f7_stand_flip_table.txt`
(by `f7_gate_full.sh` + `f7_flip.py`). "gap" = exported / certified - 1 over the judged pockets.

| type | 0.68 | 0.52 | 0.38 | 0.26 | lightest judged pocket | floating |
|---|---|---|---|---|---|---|
| octet | sealed / sealed | sealed / sealed | acc / acc (+27.9 %) | acc / acc (+30.2 %) | +0.0 % | 0 |
| FCC | acc / **sealed** | acc / **sealed** | acc / acc (0.0 %) | acc / acc (0.0 %) | 0.0 % | 0 |
| Kelvin | acc / acc (0.0 %) | acc / acc | acc / acc | acc / acc | 0.0 % | 0 |
| Rhombic | sealed / sealed | acc / acc (-3.1 %) | acc / acc | none / none | **-3.5 %** | 0 |
| Diamond | acc / acc | acc / acc | sealed / **acc** | acc / acc | 0.0 % | 0 |
| BCC | acc / **sealed** | acc / acc (-1.1 %) | sealed / **acc** | acc / acc | -1.5 % | 0 |
| SC | acc / **sealed** | acc / acc (+5.6 %) | acc / acc (+8.8 %) | acc / acc (+9.0 %) | -0.0 % | 0 |
| Gyroid (4 mm) | sealed / sealed | acc / acc (+1.1 %) | acc / acc | none / none | 0.0 % | 0 |
| Schwarz-D (4 mm) | sealed / sealed | acc / acc (+1.4 %) | acc / acc | none / none | 0.0 % | 0 |

(before / after; acc = accepted; sealed = refused, sealed cavity; none = the law could lattice no
cell, unchanged.) **BAR met:** the light-side gap is within 10 % on every rung of every type (worst
-3.5 %, rhombic 0.52), BCC's rung 0.52 is accepted, 0 floating pieces on every latticed rung
(`f7_stand_floating.txt`), no rung refused by the volume check.

**Every flip, in plain words:**
- **FCC 0.68 and 0.52, BCC 0.68, SC 0.68: now refused, sealed cavity.** The small declared include
  region 8, at (19.2, -8.0, 17.1) to (29.5, -1.2, 23.9) mm, is boxed in. Under the cover rule the
  voxels between it and the rest of the lattice are solid (not every cell over them can be laid), so
  the space between the struts in region 8 (12 voxels on FCC 0.68, 4 on 0.52, 18 on BCC 0.68, 12 on
  SC 0.68) has no path out, and core's existing sealed-cavity rule refuses the rung. Nothing is
  auto-corrected. Each type's 0.38 rung is accepted.
- **Diamond 0.38 and BCC 0.38: now accepted.** Before, one latticed voxel in region 8 was sealed
  and the rung was refused; after, every latticed voxel reaches the outside (4 of 4 on diamond).
- No rung flips because of the volume check or (b).

Two things the table shows that are not flips. **Fewer latticed voxels, more cells:** FCC 0.38 goes
from 61 latticed voxels holding 61 cells to 12 voxels holding 419. The stand solves on 3.41 mm voxels
and lays 2 mm cells; before, each voxel got the one cell at its centre (about a fifth of its volume)
and was certified as if full; now a voxel is latticed only when it can be filled. The lattice mass
moves by under 1.5 % (510.4 to 512.1 g). **Octet is 28-30 % heavy:** its law and tensor are the
legs-only cell's, and the generator lays the full octet (Finding 1, Q2). That is step (c).

### The gate (`c009fa30`)

ctest 167 / 167 passed, 4,607 s (`f7_ctest.txt`); cli_demo passed, 2,146 s. The 21 binaries
(`f7_identity_21.txt`): 12 identical; 9 differ, each passing with the same check count:
`test_lattice_boundary` (B3's oblique overshoot -0.117 to -0.124 mm and 18 more skin struts: the
clip and the skin read the emitted radius), `test_lattice_clip_shell` (the control's worst
0.178 to 0.156 mm), `test_lattice_skin_freeform` (3,012 to 3,288 landings, largest piece still
100 %), `test_lattice_hookup` (the new volume-check lines only), `test_lattice_variant` (11,904 to
11,894 latticed voxels: the cover rule; a wall time), `test_designbox_lattice_recert` (composite
12,086.9 to 11,660.6, -3.5 %: its file is lighter than the law, so the certificate drops; recorded
still equals reproduced), `test_lattice_void_exterior` (lattice margins 3,384.15 to 3,383.72 and
3,000.73 to 2,954.28, the same reason; a build path), `test_bake_build_orientation` (112,428
vertices compared, 0 drifted; exclude-region occupancy 965 = 965), and every octet run's stderr
shows its high side (+45 to +81 %: step (c)). Tests: `test_lattice_volume_check` (new, 40 checks),
`test_lattice_types` (Finding 6, 253), `test_mesh_winding` (its pin moves with (b): 755.506110 to
858.361992 mm3).

## Rulings of 2026-11-02, step (c): octet made honest — DONE (`262b731f`, `3a1b9b3d`)

What changed (core only):

1. **Octet's density law is the full cell's.** The strut diameter per density (`kOctetDia`) was
   PR 198's table, measured on the LEGS-ONLY cell (each face centre joined to its four corners: that
   is FCC's geometry), while the generator lays the full octet, legs and braces. It is now octet's own
   law, measured the way every other type's is (`lattice_types_probe law octet`, 17 rows, density
   0.045 to 0.95: `c_octet_law.txt`, `c_octet_law_ends.txt`). `octet_relative_density` is its
   inverse. On one 8 mm cell the file now holds 0.1 to 0.3 % more than the certificate at the band's
   floor, middle and top; before it held 90 % and 59 % more at the floor and middle, and 3 % less at
   the top (`c_gapcell_before_c.txt`, `c_gapcell_after_c.txt`; the other six types are unchanged to
   the digit).
2. **Octet's stiffness rows are the full cell's** (PR 246's tensor rows landed, plus the two ends
   measured now). 18 rows, density 0.0496 to 0.9003 (`c_octet_tensor_rows.txt`):
   - low end, 6 rows, measured 2026-11-03 at 96 voxels a cell against 128;
   - middle, 4 rows, PR 246's validated rows (48 against 64, measured 2026-07-29, never landed);
   - high end, 8 rows, measured 2026-11-03 at 64 against 96.
   Each row passes PR 246's rule: within 2.4 % of the finer resolution (worst +2.29 %), at least 6
   voxels across the strut, the solve converged. The sweep ran one density per process (each inside
   the heavy lock's hour), so each process compared its row against a one-point curve. The drift is
   re-judged on each set's whole curve by `c_octet_tensor_assemble.py`, which reproduces the table
   from `c_octet_tensor_sweep/`. One row, 0.18522, lies past the end of its curve and is left out
   (the rule never extrapolates). The certifiable band is now **0.0496 to 0.9003** (it was 0.0505 to
   0.8999). Multiscale's bars still hold (top 0.90027 >= 0.85; 18 resolved rows >= 6).
   In plain words: at the same density the full octet is about 16 % stiffer in shear and about 4 %
   softer along an axis than the legs-only rows said (density 0.30). FCC keeps the legs-only rows
   byte for byte; it is that geometry.
3. **"Prints open" is the geometry, for every type (ruling (A)).** A tile prints open when a
   bead-wide strut is at most **0.1898 of the tile** (`kSteppedPrintsOpenMaxStrutPerCell`, 0.7592 / 4:
   the strut-to-cell ratio at octet's old density bound of 0.20). No density is read
   (`lattice_prints_open`, `stepped_plan.hpp`). The menus at a 12 mm base and a 0.45 mm bead
   (`c_menus_12mm_045.txt`; "before" is the 0.20 density rule on each type's own law):
   - **Octet: unchanged**, 12 9.6 9 8 7.2 6 4.8 4 3 2.4, the menu he approved. The density rule on the
     full cell's law would have cut it to 12 8 6 4 (option (B), not taken).
   - **Rhombic gains** 9.6, 7.2, 4.8 and the 2.4 mm tile: 12 9 8 6 4 3 becomes octet's menu.
   - **SC loses the 2 mm tile and the 10 mm size** (12 10 9.6 ... 2.4 2 becomes the same menu as
     every other strut type). A bead-wide strut in a 2 mm tile is 0.225 of it, wider than 0.1898. This
     was not in the ruling and is named here.
   - FCC, Kelvin, Diamond, BCC: unchanged. BCC and SC stay Structural only (Finding 6).
4. **The aesthetic ceiling is the same geometry with a new number.** Octet's strut is a fifth of its
   cell at density **0.3788** on the full cell's law (0.2189 on the legs-only law). The full cell has
   twice the legs-only cell's struts, so the same strut holds about twice the density. The cap's
   finest cell at a 0.45 mm bead stays 2.25 mm.
5. **Auto picks a coarser octet cell**: at a 0.45 mm bead the light floor (the cell whose bead-wide
   strut is the band's floor density) goes from **4.93 to 7.03 mm**. In plain words: the old 4.93 mm
   cell with its thinnest printable strut, 0.45 mm, held about 0.09 of the cell in the file (0.0965),
   not the 0.05 it claimed. A 0.45 mm strut makes a 5 % lattice only in a 7.03 mm cell. At a
   0.42 mm bead it is 4.60 to 6.56 mm, and a member needs 32.8 mm (5 of those cells) where 23.0 mm was
   quoted. The finest printable cell (the band's top) moves the other way: 1.173 to 1.117 mm at
   0.45 mm, so the thinnest member that holds a certified octet is 5.58 mm (it was 5.87).
6. **The rounding fix in "finest printable cell"** (`cell_whose_strut_prints`, `lattice.cpp`; kept,
   with its test). bead / phi(density) is only exact to rounding: on the full cell's law
   0.42 / phi(0.9003) builds a 0.41999999999999993 mm strut, which every strut-against-bead check
   reads as under the bead (Fit derives exactly that cell for a thin wall, and grading's audit threw).
   The cell is nudged up by ulps until its strut prints. Test (`test_strut_diameter_per_type`, "a
   cell core calls printable prints"): every type with its own law, beads 0.20 to 1.00 mm by 0.005 mm,
   the light, uncapped and mid-cap floors; the strut is at least the bead and the cell within 1e-14 of
   the quotient. Positive control: the bare quotient builds a short strut in 162 of those cases.
7. **The strut-strength report reads the full cell's stresses through a legs-only law** (measured,
   not changed). PR 259's strut law (the K table behind `lattice_strut_strength`, a report that never
   gates) was measured on the legs-only cell: its library columns are those rows, and its measured
   shear stiffness tracks them (C44 34.10 against 33.79 legs-only and about 35.9 full, at density
   0.095). `test_strut_report_j6` now pins the production path's numbers on the full cell's tensor:
   strut margins 0.5875 / 0.6265 / 0.6212 where the probe printed 0.6164 / 0.6320 / 0.6266. The
   probe's table stays in the test as the provenance.

8. **A plan sent at an octet density near the old print limit is now refused** (core's existing D5
   check, unchanged; named because his saved plans can carry one). At the same density the full
   cell's strut is about 0.7 of the legs-only one (twice the struts share the material), so a
   `stepped_cells` entry the app sized on the old law can build a strut under the bead. Example, the
   test fixture `plan_doubled_receipt`: 3 mm cells at 0.18 built over 0.45 mm before; now 0.386 mm, and
   the run stops with "stepped cell 4 in region 1 is 3 mm at a density of 0.18, which builds a
   0.3859 mm strut -- under the 0.45 mm bead". The app sizes plans from core
   (`lattice_min_density_for_strut`), so a plan made on this core passes. A plan saved before it
   needs re-planning, and core says which cell and why.
   The same is true where a plan sends no `rho` and core's own law sizes its cells: a 3 mm cell
   at a 0.45 mm bead prints from a density of 0.235 (it was 0.131) and a 2 mm cell from 0.455 (it
   was 0.265), so the light voxels go solid. If none is left, the plan is refused for having
   no density, with the count.

Tests that moved with the law, each re-derived from core where the test allows:
- `test_grading`: the band numbers. The sub-floor fixture's body grows from 30 to 40 mm: five cells of
  6.25 mm need 31.2 mm, so no voxel of a 30 mm body read thick enough to grade, and the junction band
  the test relies on vanished. It now puts 3,980 of 70,400 voxels under the floor (5.65 %, still over
  the 3 % cap). S1's declared minimum is 1.116 mm, just under the new frontier (1.173 before). S2c's
  target is 7 mm, above the new floor (6 mm before).
- `test_strut_diameter_per_type`: the E1 pins (7.026627796 and 1.116948948 mm) and the new section
  in item 6.
- `test_lattice_certification`: the B2 anchor is the full cell's row. FCC keeps the legs-only row,
  and octet now differs from it (shear more than 5 %).
- The material-model harness: the same 18 rows (`test_lattice_material_model` pins the copy).
- `test_strut_report_j6`: item 7.
- `test_stepped_plan`: the geometry rule (391 checks).
- `test_lattice_hookup`: its 30 mm cylinder holds 5 cells only at a finer bead, so the fixture's
  bead is 0.28 mm (floor 4.37 mm, the cell it was built around).
- `test_lattice_density_field`: "prints at a 2 mm cell, 0.45 mm bead" moves from a 30 % lattice to
  a 50 % one (0.347 to 0.480 mm strut).
- `test_plan_is_the_design`: the doubled arm runs a copy of `plan_doubled_receipt` whose cells carry
  core's lightest printable density at 3 mm (item 8). The fixture itself is not edited (see Blocked).
- Found by the gate's full ctest, fixed in `3a1b9b3d` (those three test files only):
  - `test_build_direction` U4: PR 266's table was the legs-only tensor's (the eede708a build
    still prints 0.6968 / 1.3285, interlayer 6.3494, 9.11x). Its region is octet at 0.30, and on
    the full cell's tensor production gives 0.6975 / 1.3242, interlayer 6.9058, 9.90x. Every
    verdict, the 48 support voxels and the 6x height are unchanged; the pins are the new numbers.
  - `test_slot_origin`, `test_region_ownership`: their plans send no `rho` (item 8), so at 0.45 mm
    the law kept every voxel they lattice solid. Their runs read a copy at a 0.32 mm bead, where a
    3 mm cell prints from 0.128, the threshold the plans were built around. Premises read core:
    0.45 mm gives over 0.2, 0.32 mm about 0.131.
    `test_slot_origin`'s two K1 arms keep their fixtures: they are refusals at 0.45 mm, one by the
    prints-open rule (a 7 mm base's 2.33 mm tile, which would print at 0.32 mm).

### Blocked (maintainer data, proposed, not edited)
- `core/tests/fixtures/organic/plan_doubled_receipt.json`: its 20 cells' `"rho": 0.18` no longer
  print at 3 mm on octet's full-cell law. Proposed: `0.24` (the lightest that prints there is 0.235).
  Until then the test runs a copy.
- `core/tests/fixtures/organic/{slot_origin_inplane,slot_origin_absent,slot_origin_off_plane,
  owner_corner_fwd,owner_corner_rev,straddler_collision,straddler_seam}.json`: both
  `"min_extrudable_width_mm": 0.45` become `0.32` (what the two tests' copies do). `plan_base_missing`
  and `plan_base_used` stay at 0.45. Until then the tests run copies.

### The flip table (M2 stand, Structural ladder; before = `c009fa30`, after = `262b731f`)

Full table with cells, density range, mass, margin and every pocket gap: `c_stand_flip_table.txt`
(by `c_gate_c3.sh` + `f7_flip.py`). **No rung flips:** every verdict is the same before and after,
on every type. The other eight types are identical to the digit on every rung (density range, mass,
margin, verdict, every pocket gap). Octet:

| octet rung | before | after |
|---|---|---|
| 0.68, 0.52 | refused, sealed cavity | refused, sealed cavity |
| 0.38 | density 0.289-0.889, 511.8 g, margin 1,686.2, accepted; file +27.9 % over certified (heaviest pocket +63.2 %) | 0.519-0.889, 512.2 g, 1,686.5, accepted; +0.0 % (heaviest +0.0 %) |
| 0.26 | 0.320-0.836, 484.1 g, 1,649.2, accepted; +30.2 % (heaviest +57.1 %) | 0.553-0.836, 484.4 g, 1,649.9, accepted; +0.0 % (heaviest +0.0 %) |

**Octet's rows, in plain words.** The stand lays octet at a 2 mm cell. On the full cell's law a 2 mm
cell prints only from a density of 0.455 (it was 0.265 on the legs-only law). So the light voxels the
law grades between about 0.29 and 0.52 now build struts under the bead and stay solid: 7 and 4 of
the part's voxels are latticed at 0.38 and 0.26, where 16 and 14 were. The lattice left in the file
is 138.7 and 78.3 mm3 (it was 438.1 and 357.4), and the certificate credits all of it (it credited
342.6 and 274.5). The part is 0.4 g and 0.3 g heavier, solid where light struts were. The margin rises
by 0.3 and 0.7, and both rungs stay accepted.

**BAR met:**
- The light side is within 10 % on every latticed rung of every type: every lightest judged pocket
  is between -3.5 % (rhombic 0.52) and +0.0 %. The largest whole-rung gap is SC's +9.0 %, on the
  high side.
- 0 floating pieces on the 24 latticed rungs probed, 20 strut and 4 sheet (`c_stand_floating.txt`).
- Octet's high side: its heaviest judged pocket is +0.0 % on both latticed rungs (it was +63.2 % and
  +57.1 %). On one 8 mm cell it is +0.31 / +0.12 / +0.12 % at the band's floor, middle and top (it
  was +90 / +59 / -3 %).
- The full ctest is below.

### The gate (`3a1b9b3d`)

ctest on `262b731f`: 164 / 167 (`c_ctest_262b731f.txt`). The three that failed pinned the legs-only
law (the tests above) and are fixed in `3a1b9b3d`, which changes those three test files only, so its
library and CLI are `262b731f`'s byte for byte, and the stand and identity here are theirs.
ctest on `3a1b9b3d`: **167 / 167 passed**, 5,153 s; cli_demo passed, 2,412 s
(`c_ctest_3a1b9b3d.txt`, by `c_gate_ctest_on.sh`, which proved the build tree equal to
`git archive 3a1b9b3d core` before building).

The 21 binaries (`c_identity_21.txt`, against eede708a): 9 identical, 12 differ. Every one exits 0,
each with its check count unchanged except `test_grading` (26,334 to 55,089: its sub-floor body
grew from 30 to 40 mm, so more voxels are checked). Against step 1:
- Three print exactly what they printed there (`test_lattice_boundary`, `test_lattice_clip_shell`,
  `test_lattice_skin_freeform`).
- Nine move with the law:
  - `test_stepped_plan`: the ceiling goes 0.218871 to 0.378846. Its parity control's strut goes
    0.4000 to 0.2879 mm (the same density builds a thinner strut on the full cell).
  - `test_grading`: the cap goes 0.218871 to 0.378846, and the uncapped top 0.899880 to 0.900270.
  - `test_lattice_certification`: "fcc == octet-legs at the shared anchor row" becomes two checks:
    FCC keeps the legs-only row, and octet is its own tensor (its shear differs by more than 5 %).
  - `test_lattice_density_field`: its Jacobian samples and MODE 2 loop move with the law. The worst
    derivative error is 5.2e-10 (it was 6.0e-10).
  - `test_lattice_hookup`, `test_lattice_variant`, `test_bake_build_orientation`: the law now
    counts 524.7 / 524.7 / 483.5 mm3 against a file of 361.6 / 361.6 / 333.4 (it counted 317.2 /
    317.2 / 292.4). The high side falls from +45.6 % to +12.6 % (bake: +45.7 % to +12.7 %).
    Variant's lightest graded density at 3 mm and 0.42 mm is 0.2084 (it was 0.1124).
  - `test_designbox_lattice_recert`: its composite goes 11,660.6 to 13,380.1 (+14.7 %), because the
    full cell's law credits more of what the file holds. Recorded still equals reproduced, and the
    high side goes +36.8 % to +9.9 %.
  - `test_lattice_void_exterior`: an 8 mm cell with 1.2 mm struts reads density 0.6774 (it was
    0.4096). Its margins go 3,383.72 to 3,386.14 and 2,954.28 to 3,102.44, the high side +81.5 % to
    +20.1 %, and a build path changes.

## What changed in core, once, for every strut type (and, 9-10, for the sheets)

1. **One canonical cell per type** (`topopt/strut_cell.hpp`). Octet, SC, BCC, FCC, Diamond,
   Kelvin, Rhombic as `(S, struts, nodes)` on an integer grid. `test_strut_cell` compiles the
   tensor probe's own source (`tensor_library_nine_probe.cpp`, its `main` renamed) and asserts the
   production table equals its `make_lattice()` element for element, and that the production
   voxeliser reproduces the probe's `build_cell` voxel for voxel. So the certified cell and the
   generated cell are one cell (go-live item 1), by test.
2. **The generator builds any of them through octet's machinery** (`lattice_gen.cpp`). Octet keeps
   its hand-written PR 201 tables; every other type gets a generic table from its canonical cell:
   every strut and node inside the closed cell, ownership by the cell holding the midpoint, else
   the lexicographically smallest ACTIVE cell sharing it (octet's node rule, applied to struts).
   Clipping, Rim, Diagrid (plain and freeform), the outline, streaming, determinism, Doubled and
   Stepped are the same code. Node balls are decided among the cells that hold one of the node's
   struts — diamond's cell corners are reached by no strut of the cell they cap, and without this
   a holed region emits floating balls (found by `test_strut_cell`'s first run).
3. **The run path reads the job's type** (`run_job.cpp`, `job.cpp`, `lattice_density_field.cpp`):
   the six generator calls, the certification posture, the three grading-law topologies, the
   receipts' cell reports, the uniform-lattice band, the Fit pre-flight, multiscale. K0 listed 24
   `Octet`s in `run_job.cpp`; none remain. Three new parse-time refusals, each naming its reason:
   organic with a non-octet type (it builds no cell), a region density outside the TYPE's band,
   Doubled/Stepped for a type whose R4 verdict is not PASS.
4. **Each type's own numbers in one place** (`lattice.cpp`, `type_measured`): the diameter table,
   the bending / percolation / aesthetic floors and the bending error curve, each beside the run
   that produced it. `lattice_strut_diameter_mm`, `lattice_density_from_strut`,
   `lattice_aesthetic_density_ceiling`, the floors and the adaptive aesthetic floor read it.
   `lattice_type_numbers_measured(topo)` says whether a type has them.
5. **The facts struct for the app** (`topopt/lattice_types.hpp`), **the print-tests loader**
   (`topopt/lattice_print_tests.hpp`, K4) and **the sample block** (`topopt-cli lattice-sample`,
   `topopt/lattice_sample.hpp`). See the BRIDGE CONTRACT below.
6. **The measurement harness** `core/tests/harness/lattice_types_probe.cpp` (`law`, `bend`,
   `perc`, `step`): every per-type number in this round comes out of it.
7. **The R3 note is on every receipt that names SC or BCC** (`lattice_type_directional_note`,
   one source; the facts read it too). run_info's `lattice`, `lattice_export`, `grading` and
   `multiscale` blocks, the per-variant lattice receipt and its two forecasts, and the sample
   block's receipt add `"directional_note"` right after the topology. Every other type writes no
   key, so octet's receipts are byte-identical (02-core-spec §2.5).
8. **Diagrid's link radius follows each type's own geometry** (`crossing_node_gap`,
   `diagrid_skin_connectivity.txt`). Near a plane of nodes a face's landings bunch around the
   nodes that send a strut across it, and octet's 0.72-cell radius is 1.8 % over octet's gap
   between those nodes (0.7071 cell). FCC's, BCC's and SC's are a full cell apart, so on a face
   just off a node plane their skins broke into 9-25 islands (FCC from 0.75 cell, BCC at
   0.20-0.45 and 0.70-0.95, SC everywhere). The radius now scales by gap / 0.7071 when the gap is
   larger (sqrt 2 for those three). Octet, Kelvin, Rhombic and Diamond have octet's gap and are
   byte-identical (hashed against Diamond's gate build); FCC's skin changes, and it is live, so
   this is a change to a pushed type: the gate on SC's commit covers it. `test_lattice_types`
   holds every live type to one skin piece on such a face (RED without the scaling: FCC 12
   pieces, BCC 16).

9. **The sheets (K2): Gyroid and Schwarz-D** (02-core-spec §3), from the K2 work merged in
   at `13ef314c`, live at `ccf0e03b`:
   - `LatticeTopology` gains `Gyroid` and `SchwarzD`; the planned-ids list is gone.
   - **Rows re-measured on the production wall** (`topopt/tpms.hpp`, the gradient-normalised
     band |f|/|grad f| <= t/2, R7), by the strut rows' periodic homogenisation
     (`tpms_probe rows`): VALID rows only, each resolution-checked against a finer grid
     (vpc96 against vpc128 up to rho 0.35, vpc48 against vpc64 from 0.40; every drift under
     2.4 %), the first unresolved row kept as `resolved = false`. Bands: gyroid
     0.15010-0.60069, Schwarz-D 0.20038-0.60012 (`<sheet>_rows_vpc{48,96}.*`).
   - **The wall law** (`<sheet>_wall_law.*`): the field parameter t bisected on the converged
     solid fraction, and the TRUE normal wall measured on 4,000 points of the sheet (uniform
     to 1-3 % over the sheet; it runs below t as the wall thickens, -16 % at rho 0.60). The
     true wall is the sheet's "diameter" everywhere core reads one: printability
     (wall >= bead, R6) reads it unchanged, and `lattice_sheet_wall_param_mm` turns it into
     the field's parameter for the generator.
   - **The generator** `generate_tpms` (`tpms_gen.hpp`): dual contouring of the field's
     distance estimate (`lattice_dc.hpp`), clipped by the same boundary the struts use (eroded
     by one DC cell, as the strut clip erodes by the radius), streamed, deterministic. DC cell
     = a third of the thinnest wall laid (-0.4 % volume against the exact solid fraction).
     The run's export lays it for a sheet job; Rim is the strut generator's rim pass alone.
   - **At the parse** (R5, R8): Doubled, Stepped, swept, fit and stepped cells are refused for
     a sheet with the R5 reason; Diagrid, stated or the default, with the R8 reason (a sheet
     job states `"skin": "rim"` or `"none"`); organic as for every non-octet type. One cell and
     one grid for the whole part, so two sheet regions that touch always share cell size and
     phase.
   - **The harness** `core/tests/harness/tpms_probe.cpp`: `law`, `rows`, `perc`, `bend`, `tris`,
     and `mesh` (go-live item 7 on an emitted sheet: its pieces, and which touch or sit inside
     the solid body the run writes beside it).
   - **Each sheet's numbers** in `type_measured` (bending 10 / 9, percolation 0.5, aesthetic
     2), facts with `family: "sheet"` and the measured triangle cost, and the sample block.
10. **The C2b bend can run matrix-free** (`TOPOPT_BEND_MATFREE=1`, `07ffbfda`): the sheets'
    floors lie at 9-10 cells, where the resolved block is ~20-25M dof and its assembled K
    peaked at a 39.5 GB footprint and was killed on a 16 GB machine. `fea_solve_cg_matfree`
    solves the same reduced system to the same criterion; it reproduced both sheets' 3-cell
    runs to every printed digit (643.4300, 745.4677). Unset, the probe is unchanged.

## Findings that reach past this round (measured; nothing about them is changed here)

1. **The density law is measured on the CONVERGED solid fraction, not on vpc48 voxels.**
   On a lattice-aligned voxel grid the solid fraction of a strut cell is a staircase in r,
   and it does not shrink smoothly with resolution (`law_resolution.txt`): rhombic at
   r/L 0.045 reads 0.059 at vpc48 and 0.0785 at vpc256 (-24 %); FCC at r/L 0.0667 reads
   0.0951 against 0.1026. So octet's B3 method (bisect r on the vpc48 voxels) sizes a strut
   to wherever a step falls. The tensor rows are resolution-checked AS A FUNCTION OF
   DENSITY (vpc48 vs vpc64 at matched rho), so the strut that realises a density is the
   one whose true solid fraction is that density. Each type's table is therefore bisected
   on `strut_cell_solid_fraction` (2^20 Halton points, deterministic, converged to ~0.2 %
   against 2^22), and the B3 table is reported beside it. Within the band the two differ by
   at most: FCC 2.7 %, Kelvin 3.9 %, rhombic 5.0 %, diamond 4.9 %, BCC 4.9 %, SC 4.0 %
   (`<type>_law.txt`, column "B3 gap"). **Octet's shipped table is the B3 table and is
   unchanged (R9).** FCC's B3 table equals it to four digits, which confirms octet's law
   was measured on the legs-only cell.
2. **FIXED 2026-11-02 (ruling (b)).** **The printed struts are lighter than the certified ones, for every type including
   octet.** The generator emits an 8-gon prism with circumradius r (area 2*sqrt(2)/pi =
   0.900 of the circle) and an icosahedral node of circumradius r; the tensor rows were
   measured on round capsules of radius r. At the same r the production solid is 6-10 %
   lighter (`<type>_law.txt`, column "as-built gap"; e.g. FCC -9.4 % at rho 0.05, -6.9 % at
   0.60). For a stretch-dominated strut that is roughly the same fraction less stiffness
   than certified. It is a property of PR 201's emitter, shared by octet, and changing it
   would move octet's bytes and the app's preview, so it is reported, not touched. A
   prism fix exists (scale the 8-gon to equal area: r x 1.0539) if the maintainer wants
   it, as its own change with its own R9 break.
3. **Q2, octet's legs-only tensor** (`octet_legs_only_report.txt`, measure only): the full
   octet is SOFTER along the cell axes than the legs-only tensor says (E100 -10.6 / -13.6 /
   -18.2 % at rho 0.25 / 0.35 / 0.45) and STIFFER along the diagonal and in shear (E111
   +13 to +16 %, C44 +15 to +19 %). So the shipped certificate over-states octet's axial
   stiffness by 12-22 % and under-states its diagonal and shear stiffness. The maintainer
   rules; nothing changed.
4. **The bending floor is far above 5 for the bending-dominated types**, as
   tensor-library-nine's T4 predicted: at 6 cells across Kelvin is still +4.6 %, rhombic
   +5.5 %, diamond +7.1 %, BCC +5.8 % (PR 235's C2b cantilever, vpc12, the same method as
   octet's). FCC crosses between 4 and 5 (5, octet's own number), SC between 3 and 4.
5. **Analyze mode records no recertified margin under aesthetic intent**, for octet too
   (byte-identical to the reference binary): `run_info.grading` has `recertified_*` only
   under structural. The `run` and `lattice-variant` paths certify the composite in both
   modes. Pre-existing; noted because "the certificate runs in both modes" is only true on
   those paths.
6. **RULED 2026-11-02: Structural only.** **BCC's and SC's R11 aesthetic ceiling lies BELOW their certifiable band** (BCC 0.1791 vs
   0.2105; SC 0.0831 vs 0.0866). R11 is octet's rule per type: a strut no wider than a fifth of
   its cell. The thinnest strut either type certifies is already wider than that (BCC 0.219,
   SC 0.204 of the cell), so by R11 no certifiable BCC or SC "prints open". Core's runs do not
   read the ceiling; the app's Aesthetic cap does, and min(band top, ceiling) is below the band
   bottom for these two. The bridge contract says what the app should do; whether R11 should
   read differently for 3- and 8-strut cells is the maintainer's ruling.
7. **FIXED 2026-11-02 (cover rule, volume check, certificate from what shipped).** **A graded run lattices ONE cell per masked solve voxel when the cell is smaller than the
   voxel**, octet included (`bcc_stand_percolation.txt`, measured on the M2 stand). `cell_latticed`
   (`run_job.cpp`) activates a cell iff it holds a masked voxel's CENTRE. The stand solves on
   3.41 mm voxels and the swept ladder picks 2 mm cells, so each masked voxel activates exactly one
   cell: the receipts say latticed cells = latticed voxels (92 = 92 on BCC's rung 0.52, 112 = 112 on
   octet's rung 0.38), and about 80 % of every pocket voxel is left empty. Two consequences. (a) The
   certificate (the posture) reads every masked voxel at its graded density over the whole voxel, so
   in those voxels the exported lattice holds about a fifth of the material it counts. (b) In a pocket
   one voxel thick the lone cells reach no wall and float: BCC's rung 0.52 has 12 such pieces, octet's
   own stand run 2 in the same place, and SC's rung 0.38 has 3 there (its receipt says 154 = 154;
   two of them have exactly the bounding boxes of octet's two; `sc_stand_percolation.txt`). FCC's run left two lone cells in that pocket too; they count as
   held only because its solid companion comes within 0.05 mm of a node. Kelvin's, Rhombic's and
   Diamond's runs latticed nothing there. The generators emit exactly the cells they are given. A fix belongs in
   the activation (every cell that overlaps a masked voxel, or a cell never finer than the solve
   voxel) and moves octet's bytes (R9), so nothing is changed here: the maintainer rules.


8. **A sheet costs an order of magnitude more triangles than a strut lattice.** On the stand's rung 0.52, on one fixed 4 mm cell, Gyroid laid 33 cells in 527,072
   triangles and Schwarz-D 33 in 634,768, where octet laid 78 in 80,316: 15,972 and 19,235
   triangles a cell against octet's 1,030 (15.5x and 18.7x; `gyroid_stand_certificate.txt`).
   The cost is the wall resolution: a DC cell a third of the thinnest wall, and per interior
   cell 19.44 (gyroid) / 24.00 (Schwarz-D) x (cell / DC cell)^2 triangles
   (`sheet_triangle_cost.txt`). The sample blocks are 1.39M and 2.32M triangles (69 and 116 MB
   STL; not committed, their receipts are). The app's budget reads `sheet_triangles_coeff`.
9. **Fine sheet cells do not print.** With the 0.42 mm bead a gyroid wall reaches one bead
   only from rho 0.42 at a 3 mm cell and 0.32 at 4 mm, and no density in the band does below
   2.03 mm (4.84 beads); Schwarz-D needs 0.51 / 0.39 and 2.52 mm (6.01 beads)
   (`sheet_printability.txt`, which core's own inverse reproduces). So the fixed-cell runs
   raise the density to suit (the stand's 4 mm gyroid runs start at 0.319, the 1-bead density),
   and with the bending floors of 10 / 9 cells a 4 mm sheet needs members 36-40 mm across.
   Justino Netto 2024 saw holes at overhangs with 1-bead PLA gyroid walls (R6, Q3): the print
   test decides whether the floor should be two beads.

## FCC — LIVE

Go-live checklist (02-core-spec §4), each with its evidence in
`docs/handoffs/evidence/2026-11-01-lattice-types-k1/`:

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell`: FCC's table equals `tensor_library_nine_probe.cpp`'s `make_lattice("fcc")` element for element (S 2, 12 struts, 4 nodes, phase 0); the production voxeliser reproduces the probe's `build_cell` exactly |
| 2 | Generates on a block and on the M2 stand; octet byte-identical; deterministic | PASS | `test_lattice_types` (ownership on a holed region, two runs same bytes, clipped + Diagrid run same bytes); the M2 stand `run` at res 64 laid and certified FCC on all four rungs (`lattice_margin` 1782 / 1717 / 1678 / 1640, accepted); octet: `r9_octet_fcc_commit.txt` (below) |
| 3 | Own density law, diameter table, printability floor | PASS | `fcc_law.{csv,txt}` (converged solid fraction; B3 beside it); `lattice_cell_printability_floor_mm` / `lattice_min_density_for_strut` read it (no octet table is read: `test_strut_diameter_per_type` 3b) |
| 4 | Own bending, percolation and aesthetic floors, with conditions | PASS | bending **5** (`fcc_bend.txt`: +54.0 / +8.9 / +4.2 / +2.6 / **+1.8** / +1.3 % at 1-6 cells; C2b cantilever, S 5 mm, vpc12, 6 cells long, cell rho 0.1991); percolation **0.75** (`fcc_perc.txt`: spanning at every placement 0 / .25 / .5 / .75 and rho 0.095 / 0.343 / 0.591 from 0.75 cells; 0.5 fails at the .25 placement); aesthetic hard floor **2** (+8.9 % and percolates; no finish relaxation, since octet's skinned 1-cell measurement is octet's) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `fcc_step.txt`: S\|S/2 block 1 component, 0 dangling of 2,208 ends; S\|2S/3 interface 1 component, 0 of 1,152; octet control `octet_step.txt` the same |
| 6 | Certificate end to end, both modes; receipts name the type | PASS | M2 stand `run` Structural (4 rungs) and Aesthetic (2 rungs latticed: margins 1678 / 1639), every receipt `"topology": "fcc"` (`run_info.grading`, `.lattice`, `.lattice_export`, each `*_lattice.report.json`); the analyze path too (`fcc_stand_certificate.txt`: FCC's band 0.095-0.591 and floors read, recertified margin 66.19 against octet's 239.65 on the same job) |
| 7 | Percolation on the emitted mesh | PASS | 3x3x3 block, Doubled block and Stepped interface each one solid (`test_lattice_types`); on the M2 stand (`stand_percolation.txt`, `lattice-variant` of the FCC run's own design, rung 0.38): 48 pockets, **0 floating** (every piece reaches a cut, the solid companion or the shell); octet control on the same rung: 82 pockets, 2 the same test cannot place |
| 8 | Bridge-facing functions in the contract | PASS | BRIDGE CONTRACT below; `lattice_type_facts("fcc")` asserted field by field |

Numbers FCC now carries (all its own): band 0.09505-0.59093 (PR 246's rows, unchanged);
cells per member 5; percolation 0.75; aesthetic floor 2; aesthetic ceiling 0.2126 (strut =
20 % of the cell through FCC's law; octet's is 0.2189); smallest printable cell 2.620 x the bead at the band top;
464 triangles per cell; strut strength not measured (R10, refused in words). Print status:
not print-tested.

**FCC changed after it went live**: its Diagrid skin (`9118402c`, What changed item 8). On a face
just off a node plane (from 0.75 cell) the skin broke into islands (12 pieces in
`test_lattice_types`'s case); it is now one piece. The change is in the Diagrid link radius only,
so no-skin and Rim output are unchanged.
SC's gate, on the commit that carries the change, covers it (`ctest_sc.txt`, octet identical).

**Print it** (40 mm cube, 8 mm cells, band-middle density 0.343, 2.13 mm struts, 1.5 mm plate,
70,932 triangles; deterministic, `fcc_sample_40mm.stl` beside this handoff's evidence):

```bash
core/build/topopt-cli lattice-sample --topology fcc --out fcc_sample.stl
```

## Kelvin — LIVE

The same harness, conditions and checks as FCC; evidence `kelvin_*` beside FCC's.

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 4, 24 struts, 12 nodes) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand `run` laid and certified Kelvin on all four Structural rungs (12-16 cells each: the 8-cell floor keeps cells coarse) and three Aesthetic ones (`kelvin_stand_certificate.txt`); octet `r9_octet_kelvin_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` (the job builder writes the model path absolute) |
| 3 | Own law, diameter table, printability floor | PASS | `kelvin_law.{csv,txt}` (B3 within 3.9 %) |
| 4 | Own floors, with conditions | PASS | bending **8** (`kelvin_bend*.txt`: +62.3 / +32.9 / +18.1 / +11.0 / +7.1 / +4.6 / +3.0 / **+1.9** % at 1-8 cells, C2b vpc12, cell rho 0.1944); percolation **0.75**; aesthetic hard floor **2** (+32.9 % at 2 cells, percolates) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `kelvin_step.txt`: S\|S/2 1 component, 0 dangling of 3,936 ends; S\|2S/3 1 component, 0 of 1,992 |
| 6 | Certificate, both modes; receipts name it | PASS | every receipt `"kelvin"`; analyze Structural recertified margin 99.66, accepted, on Kelvin's band 0.094-0.505 and floor 8 |
| 7 | Percolation on the emitted mesh | PASS | block, Doubled and Stepped one solid (`test_lattice_types`); M2 stand rung 0.38: 14 pockets, **0 floating** (`kelvin_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("kelvin")` |

Numbers: band 0.09375-0.50521; cells per member 8; percolation 0.75; aesthetic floor 2; aesthetic
ceiling 0.2065; smallest printable cell 2.793 x the bead; 1,008 triangles per cell; strut strength
not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.300, 2.00 mm struts, 1.5 mm plate, 141,612 triangles;
`kelvin_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology kelvin --out kelvin_sample.stl
```

## Rhombic dodecahedron — LIVE (Doubled refused, measured; Stepped allowed)

The same harness, conditions and checks as FCC; evidence `rhombic_*`. The one difference from FCC
and Kelvin is the size-step verdict: across a cell-size halving its struts do not meet, so core
refuses Doubled for it by name, everywhere a job can ask for it (`cell_mode` swept or fit,
`stepped_cells`). Stepped (S | 2S/3) joins and is allowed.

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 4, 32 struts, 12 nodes) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand's own jobs use the swept (Doubled) ladder, which core now refuses for rhombic at parse time (`rhombic_stand_swept_refused.txt`), so the stand ran on one fixed 4 mm cell (`make_stand_jobs.py rhombic <dir> --fixed 4`): it laid and certified rhombic on two Structural rungs (0.52: 33 cells; 0.38: 4) and the same two Aesthetic ones. The other two rungs carry no lattice for reasons core gives for any type: 0.26's widest member is 20.5 mm, under the 40 mm a 10-cell floor needs at 4 mm, and 0.68 holds a sealed 595 mm³ cavity (the void-reaches-exterior check) (`rhombic_stand_certificate.txt`); octet `r9_octet_rhombic_commit.txt`: the one differing leaf is `/model`, as before |
| 3 | Own law, diameter table, printability floor | PASS | `rhombic_law.{csv,txt}` (B3 within 5.0 %; the vpc48 staircase is why the law is bisected on the converged solid fraction, Finding 1) |
| 4 | Own floors, with conditions | PASS | bending **10** (`rhombic_bend*.txt`: +119.6 / +32.0 / +16.3 / +10.4 / +7.3 / +5.5 / +4.3 / +3.4 / +2.8 / **+2.3** % at 1-10 cells, C2b vpc12, cell rho 0.2963; +1.7 % at 12); percolation **0.75**; aesthetic hard floor **2** (+32.0 % at 2 cells, percolates) |
| 5 | Size-step verdict | **Doubled REFUSED**, Stepped allowed | `rhombic_step.txt`: S\|S/2 comes out as **2 components** (0 dangling of 4,608 ends: each side is whole, the two never touch); S\|2S/3 1 component, 0 of 2,240. `lattice_type_doubled("rhombic")` carries the reason, and `test_lattice_types` holds the generator to it both ways |
| 6 | Certificate, both modes; receipts name it | PASS | every receipt `"rhombic"`; analyze Structural recertified margin 98.43, accepted, on rhombic's band 0.172-0.513 and floor 10 |
| 7 | Percolation on the emitted mesh | PASS | block and Stepped one solid (`test_lattice_types`); M2 stand rung 0.38: 2 pieces, both with a cut end into the solid, **0 floating** (`rhombic_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("rhombic")`: `doubled.allowed` false with the reason, `stepped.allowed` true |

Numbers: band 0.17245-0.51331; cells per member 10; percolation 0.75; aesthetic floor 2; aesthetic
ceiling 0.3181; smallest printable cell 3.650 x the bead; 1,264 triangles per cell; strut strength
not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.343, 1.68 mm struts, 1.5 mm plate, 161,312 triangles;
`rhombic_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology rhombic --out rhombic_sample.stl
```

## Diamond — LIVE

The same harness, conditions and checks as FCC; evidence `diamond_*`. Diamond's cell corners are
reached by no strut of the cell they cap, which is why node balls are decided among the cells that
hold one of the node's struts (What changed, 2).

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 4, 16 struts, 8 nodes) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand's own jobs (the swept ladder, which Diamond allows) laid and certified Diamond on three Structural rungs (0.68, 0.52: 16 cells; 0.26: 17) and the same three Aesthetic ones (18-112 cells); rung 0.38 carries no lattice in either mode because the void-reaches-exterior check, on by default, found one sealed cavity (39.7 / 79.3 mm^3), core's standing refusal, not a Diamond fault; `lattice-variant` of rung 0.52 reproduced its recorded margin exactly and was ACCEPTED (`diamond_stand_certificate.txt`); octet `r9_octet_diamond_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` (the job builder writes the model path absolute) |
| 3 | Own law, diameter table, printability floor | PASS | `diamond_law.{csv,txt}` (B3 within 4.9 %) |
| 4 | Own floors, with conditions | PASS | bending **10** (`diamond_bend*.txt`: +907.9 / +98.2 / +37.4 / +19.0 / +11.1 / +7.1 / +4.8 / +3.4 / +2.42 / **+1.77** % at 1-10 cells, C2b vpc12, cell rho 0.2685; 9 cells misses the 2.4 % band by 0.02); percolation **0.75**; aesthetic hard floor **2** (+98.2 % at 2 cells, percolates) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `diamond_step.txt`: S\|S/2 1 component, 0 dangling of 2,304 ends; S\|2S/3 1 component, 0 of 1,120 |
| 6 | Certificate, both modes; receipts name it | PASS | every receipt `"diamond"`; analyze Structural recertified margin 184.53, accepted, on Diamond's band 0.157-0.592 and floor 10 |
| 7 | Percolation on the emitted mesh | PASS | block, Doubled and Stepped one solid (`test_lattice_types`); M2 stand rung 0.52: 15 pockets, **0 floating** (every piece reaches a cut, the solid companion or the shell) (`diamond_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("diamond")` |

Numbers: band 0.15712-0.59201; cells per member 10; percolation 0.75; aesthetic floor 2; aesthetic
ceiling 0.1790; smallest printable cell 2.395 x the bead; 672 triangles per cell; strut strength
not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.375, 2.47 mm struts, 1.5 mm plate, 87,252 triangles; `diamond_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology diamond --out diamond_sample.stl
```

## BCC — LIVE (strongly directional, R3)

The same harness, conditions and checks as FCC; evidence `bcc_*`. BCC is strongly directional
(R3): `lattice_type_facts("bcc").directional` is true with the note "best when the load runs
along the cell axes". Two things found while putting it and SC live are fixed in the commits
after it, so they reach the branch with SC's push, gated there: every receipt that names BCC
carries that note (`af9b60a2`), and its Diagrid skin no longer breaks into islands on a face just
off a node plane (`9118402c`, `diagrid_skin_connectivity.txt`: 16-25 pieces before, 1 after).

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 2, 8 struts, 2 nodes) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand's own jobs (the swept ladder, which BCC allows) laid and certified BCC on three Structural rungs (0.68: 112 cells; 0.52: 92; 0.26: 18) and the same three Aesthetic ones; rung 0.38 carries no lattice in either mode because the void-reaches-exterior check, on by default, found one sealed cavity (79.3 mm^3, the one Diamond's Aesthetic run hit), core's standing refusal, not a BCC fault; `lattice-variant` of rung 0.52 reproduced its recorded margin exactly and was ACCEPTED (1765 -> 1772) (`bcc_stand_certificate.txt`); octet `r9_octet_bcc_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` |
| 3 | Own law, diameter table, printability floor | PASS | `bcc_law.{csv,txt}` (B3 within 4.9 %) |
| 4 | Own floors, with conditions | PASS | bending **10** (`bcc_bend*.txt`: +220.1 / +49.7 / +22.6 / +13.0 / +8.4 / +5.8 / +4.2 / +3.2 / +2.48 / **+1.98** % at 1-10 cells, +1.32 % at 12, C2b vpc12 with the cell axes along the member, cell rho 0.2778; 9 cells misses the 2.4 % band by 0.08); percolation **0.75**; aesthetic hard floor **2** (+49.7 % at 2 cells, percolates) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `bcc_step.txt`: S\|S/2 1 component, 0 dangling of 1,152 ends; S\|2S/3 1 component, 0 of 560 |
| 6 | Certificate, both modes; receipts name it | PASS | every receipt `"bcc"`; analyze Structural recertified margin 79.40, accepted, on BCC's band 0.2105-0.5929 and floor 10 (`bcc_stand_certificate.txt`) |
| 7 | Percolation on the emitted mesh | PASS for the generator; the stand shows core's Finding 7 | block, Doubled and Stepped one solid (`test_lattice_types`); M2 stand rung 0.52: 64 pockets, **12 floating** (356 of 1,381 primitives). Every one is 1, 2 or 4 whole 2 mm cells (24 in all) that the run's graded activation lattices alone: it activates the cell holding each masked voxel's centre, and the solve voxel is 3.41 mm, so each pocket voxel gets one cell; in a pocket one voxel thick those cells stop 0.24 mm short of the wall. Octet's own stand run floats the same way in the same place (2 pieces); FCC's left two lone cells there that touch its solid companion only by 0.05 mm (`bcc_stand_percolation.txt`; Finding 7) |
| 8 | Bridge contract | PASS | `lattice_type_facts("bcc")`, `directional` true |

Numbers: band 0.21050-0.59288; cells per member 10; percolation 0.75; aesthetic floor 2; aesthetic
ceiling 0.1791 (below the band: Finding 6); smallest printable cell 2.392 x the bead; 296
triangles per cell; strut strength not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.402, 2.58 mm struts, 1.5 mm plate, 38,832 triangles; `bcc_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology bcc --out bcc_sample.stl
```

## Simple cubic — LIVE (strongly directional, R3; its bending floor is on-axis only)

The same harness, conditions and checks as FCC; evidence `sc_*`. SC is strongly directional (R3):
its facts and every receipt that names it carry "best when the load runs along the cell axes"
(`af9b60a2`). Its bending floor, **4** cells, was measured with the cell axes ALONG the member
(C2b's orientation) and says nothing about an off-axis member. Its Diagrid skin links because the
link radius now scales to each type's own gap between the nodes that cross a face (`9118402c`;
before it, SC's skin was 9 separate anchors on every face).

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 2, 3 struts, 1 node) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand's own jobs (the swept ladder, which SC allows) laid and certified SC on all four rungs in both modes (Structural 672 / 464 / 154 / 167 cells, margins 1643 / 1624 / 1671 / 1632; Aesthetic 1249 / 811 / 476 / 474 cells, margins 1656 / 1653 / 1664 / 1626; all accepted); `lattice-variant` of rung 0.38 reproduced its recorded margin exactly and was ACCEPTED (1686 -> 1671) (`sc_stand_certificate.txt`); octet `r9_octet_sc_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` |
| 3 | Own law, diameter table, printability floor | PASS | `sc_law.{csv,txt}` (B3 within 4.0 %) |
| 4 | Own floors, with conditions | PASS | bending **4**, on-axis (`sc_bend*.txt`: -3.72 / +12.49 / +6.03 / **+2.08** % at 1-4 cells, -0.12 at 5, -1.48 at 6, C2b vpc12, cell rho 0.2593); percolation **0.75**; aesthetic hard floor **2** (+12.5 % at 2 cells, percolates) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `sc_step.txt`: S\|S/2 1 component, 0 dangling of 708 ends; S\|2S/3 1 component, 0 of 396 |
| 6 | Certificate, both modes; receipts name it | PASS | all nine run receipts `"sc"`, each with the directional note; analyze Structural recertified margin 63.91, accepted, on SC's band 0.0866-0.4964 and floor 4 (`sc_stand_certificate.txt`) |
| 7 | Percolation on the emitted mesh | PASS for the generator; the stand shows core's Finding 7 | block, Doubled and Stepped one solid (`test_lattice_types`); M2 stand rung 0.38: 107 pockets, **3 floating** (115 of 2,415 primitives). Each is 2 or 4 whole 2 mm cells (8 in all) that the graded activation lattices alone, in the pocket one solve voxel thick where octet's own run floats 2 (two of SC's have exactly octet's bounding boxes); they stop 0.13-0.17 mm short of the wall (`sc_stand_percolation.txt`; Finding 7) |
| 8 | Bridge contract | PASS | `lattice_type_facts("sc")`, `directional` true |

Numbers: band 0.08659-0.49638; cells per member 4 (on-axis); percolation 0.75; aesthetic floor 2;
aesthetic ceiling 0.0831 (below the band: Finding 6); smallest printable cell 1.771 x the bead;
116 triangles per cell; strut strength not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.291, 3.23 mm struts, 1.5 mm plate, 21,612 triangles; `sc_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology sc --out sc_sample.stl
```

## Gyroid — LIVE (sheet, K2)

The sheet harness (`tpms_probe.cpp`) on the production wall; evidence `gyroid_*`, `sheet_*`.
Its stand runs use a fixed 4 mm cell (`make_stand_jobs.py --fixed 4`): a sheet refuses the
committed jobs' swept ladder (R5), as rhombic's Doubled verdict did.

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | the rows were re-measured on `tpms.hpp`'s production wall, the one `generate_tpms` contours (`gyroid_rows_vpc{48,96}.*`); `test_tpms` §1 holds the field, its gradient and the wall distance |
| 2 | Generates on a block and on the M2 stand; octet byte-identical; deterministic | PASS | `test_tpms` §2 (a clipped, holed, graded block: closed and manifold, two runs one hash, inside the part); the M2 stand on a fixed 4 mm cell laid and certified Gyroid on two Structural rungs (0.52: 33 cells, margin 1766; 0.38: 4, margin 1686) and the same two Aesthetic ones, all accepted; 0.68 holds the sealed 595 mm³ cavity (core's void-reaches-exterior refusal, as for Rhombic on this cell) and 0.26's widest member (20.5 mm) is under the 40 mm a 10-cell floor needs; `lattice-variant` of rungs 0.38 and 0.52 reproduced their recorded margins exactly and was ACCEPTED both times (`gyroid_stand_certificate.txt`); octet `r9_octet_gyroid_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` |
| 3 | Own density law, wall table, printability floor | PASS | `gyroid_wall_law.{csv,txt}` (the TRUE wall, rho 0.05-0.60); printability is wall >= bead (`sheet_printability.txt`, R6); no octet table is read (`test_strut_diameter_per_type`) |
| 4 | Own floors, with conditions | PASS | bending **10** (`gyroid_bend.txt` + `gyroid_bend_wide.txt`: +227.08 / +43.56 / +20.84 / +12.39 / +8.25 / +5.90 / +4.43 / +3.45 / +2.76 / **+2.24** % at 1-10 cells; C2b, S 5 mm, vpc24, 6 cells long, cell rho 0.4051; from 7 cells matrix-free); percolation **0.5** (`gyroid_perc.txt`: spans at every placement and rho 0.15 / 0.35 / 0.60 from 0.5 cells, the smallest measured); aesthetic hard floor **2** (+43.56 %, percolates) |
| 5 | Size-step: refusal with a reason | PASS: Doubled and Stepped refused (R5) | "A sheet lattice grades by wall thickness at one cell size per region (R5): a change of cell size leaves its sheets unjoined, and no measured method joins them yet." `test_tpms` §4 (Stepped refused at the parse) |
| 6 | Certificate, both modes; receipts name it | PASS | analyze certified Structural (margin 352.9, accepted, at rho 0.319: core raised the density to the 1-bead wall at 4 mm) and ran Aesthetic (rho 0.319-0.519); every run report says `"topology": "gyroid"` and carries no directional note (`gyroid_stand_certificate.txt`) |
| 7 | Percolation on the emitted mesh | PASS | the sample block's lattice is one piece (`test_tpms` §5, with the cell-line cut as its control: that cut leaves a stray corner cap); on the stand's emitted lattice STL (rungs 0.38 and 0.52) 0 pieces float: each pocket's sheet is one piece, cut where it meets the solid, and the 12-72-triangle caps cut off at cell corners lie wholly inside the solid body (0.135-4.6 mm in), so they print as solid; no edge is open, and the non-manifold edges are all in the solid body the run writes beside the lattice (SC's run has the same body) (`gyroid_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("gyroid")`, `family` "sheet" (BRIDGE CONTRACT, Sheets) |

Numbers: band 0.15010-0.60069; cells per member 10; percolation 0.5; aesthetic floor 2;
aesthetic ceiling = the band top (a wall has no strut-per-cell reading; Q1's default);
smallest printable cell 4.841 x the bead (the true wall at the band top is 0.2066 of the cell);
19.44 x (cell / DC cell)^2 triangles per cell (11,347 for an 8 mm cell at the band middle); sheet strength not measured (R10, refused in words). Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.375, 0.993 mm wall, 1.5 mm plate, 1,385,948
triangles, about 69 MB; the sheet is shifted an eighth of a cell so no corner of the cube cuts
off a cap; receipt `gyroid_sample_40mm.stl.json`, the STL is not committed):

```bash
core/build/topopt-cli lattice-sample --topology gyroid --out gyroid_sample.stl
```

## Schwarz-D — LIVE (sheet, K2)

The same harness, conditions and checks as Gyroid; evidence `schwarz_d_*`, `sheet_*`; stand
on the same fixed 4 mm cell, with the binary of Gyroid's gate (one commit carries both).

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | rows re-measured on the production wall (`schwarz_d_rows_vpc{48,96}.*`); `test_tpms` §1 |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_tpms` §2; the stand on the same fixed 4 mm cell laid and certified Schwarz-D on the same two rungs in both modes (0.52: 33 cells, margin 1765; 0.38: 4, margin 1686), all accepted; 0.68 and 0.26 carry none for Gyroid's reasons (the 9-cell floor needs 36 mm); `lattice-variant` of rungs 0.38 and 0.52 reproduced their margins exactly and was ACCEPTED both times (`schwarz_d_stand_certificate.txt`); octet: Gyroid's gate (the same commit) |
| 3 | Own law, wall table, printability floor | PASS | `schwarz_d_wall_law.{csv,txt}`; `sheet_printability.txt` |
| 4 | Own floors, with conditions | PASS | bending **9** (`schwarz_d_bend.txt` + `schwarz_d_bend_wide.txt`: +65.60 / +20.48 / +11.53 / +7.71 / +5.56 / +4.20 / +3.26 / +2.59 / **+2.09** % at 1-9 cells; cell rho 0.4074); percolation **0.5**; aesthetic hard floor **2** (+20.48 %, percolates) |
| 5 | Size-step: refusal with a reason | PASS: refused (R5) | as Gyroid |
| 6 | Certificate, both modes; receipts name it | PASS | analyze certified Structural (margin 467.1, accepted, at rho 0.393, the 1-bead wall at 4 mm) and ran Aesthetic (rho 0.393-0.600); receipts say `"topology": "schwarz_d"`, no directional note |
| 7 | Percolation on the emitted mesh | PASS | the sample block's lattice is one piece (`test_tpms` §5); 0 pieces float on rungs 0.38 and 0.52; the corner caps (12-36 triangles) lie inside the solid body (0.135-4.6 mm in) (`schwarz_d_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("schwarz_d")` |

Numbers: band 0.20038-0.60012; cells per member 9; percolation 0.5; aesthetic floor 2;
aesthetic ceiling = the band top; smallest printable cell 6.008 x the bead (the true wall at
the band top is 0.1665 of the cell); 24.00 x (cell / DC cell)^2 triangles per cell (18,865 at an 8 mm cell, band middle); sheet
strength not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.400, 0.856 mm wall, 1.5 mm plate, 2,319,684
triangles, about 116 MB; receipt `schwarz_d_sample_40mm.stl.json`):

```bash
core/build/topopt-cli lattice-sample --topology schwarz_d --out schwarz_d_sample.stl
```

<!-- PER TYPE -->

## BRIDGE CONTRACT (02-core-spec §5) — what the app calls, and what each answer means

Everything below is in core today. The app keeps a type hidden until its own preview is
built (A2); nothing here forces a type onto the screen.

### Which types exist, and which are live
| call | header | answer |
|---|---|---|
| `lattice_type_ids()` | `lattice_types.hpp` | the picker's order: `octet` first (M4), then `sc`, `bcc`, `fcc`, `diamond`, `kelvin`, `rhombic`, `gyroid`, `schwarz_d` |
| `lattice_gen_topology_names()` | `lattice_gen.hpp` | the GENERATABLE ids; grows by one per type that goes live |
| `lattice_certifiable_topology_names()` | `lattice.hpp` | the CERTIFIABLE ids (unchanged by this round for struts; the two sheets join, 9 in all) |
| `lattice_type_readiness(id, gen, cert)` + `lattice_type_readiness_plain(r)` | `lattice.hpp` | `Live` = offer it; anything else = grey it with core's plain words |

### One plain struct per type: `LatticeTypeFacts lattice_type_facts(id)` (`lattice_types.hpp`)
| field | meaning |
|---|---|
| `id`, `display_name`, `family` | core id; Q5's default name; `"strut"` or `"sheet"` |
| `readiness`, `readiness_plain` | as above |
| `numbers_measured` | true only when every number below is THIS type's own measurement; when false they are NaN, never octet's (R1) |
| `rho_min`, `rho_max` | the certifiable band |
| `cells_per_member_min` | bending accuracy floor (cells across a member) |
| `percolation_cells_per_member_min` | below it the struts do not hold together |
| `aesthetic_hard_floor_cells` | the aesthetic floor; no "with a finish" relaxation for the new types |
| `printable_cell_per_bead` | smallest printable cell = this × bead width (at the band top) |
| `aesthetic_density_ceiling` | R11 "prints open": strut diameter = 20 % of the cell, through the type's own law. **It can lie below `rho_min`** (BCC: 0.1791 < 0.2105; SC: 0.0831 < 0.0866; Finding 6): then no certifiable density prints open by R11 and an Aesthetic cap of min(`rho_max`, ceiling) is empty, so the app must not offer that cap as a range for such a type |
| `outline`, `rim`, `diagrid` | `{allowed, reason}` (R8) |
| `structural`, `aesthetic` | `{allowed, reason}` per intent (Finding 6, ruled 2026-11-02): `aesthetic` is refused for BCC and SC with core's one plain line; the app greys the type under Aesthetic with that line and offers it under Structural |
| `uniform`, `doubled`, `stepped` | `{allowed, reason}` (R4 measured; R5 for sheets) |
| `directional`, `directional_note` | R3 (SC, BCC): show the note on the picker and the receipt. Core's receipts carry the same words under `"directional_note"` (What changed item 7); for every other type the key is absent |
| `triangles_per_cell` | the per-cell emitted cost of the infinite tiling (8-gon prism 32, node 20) |
| `strut_strength_measured`, `strut_strength_note` | R10: false + "Strut strength is not measured for this type." for every new type |
| `cell_denominator` | S of the canonical cell (struts) |

Print status is maintainer data, joined by id:
`load_lattice_print_tests_file(path)` + `lattice_print_status(tests, id)` (`lattice_print_tests.hpp`):
`{listed, print_tested, date, note}`. **An id with no row reads as not print-tested.** The
loader refuses a malformed file by name; it accepts every core topology id plus `gyroid`
and `schwarz_d`.

### Struts: the geometry the preview draws (R12, M5)
| call | answer |
|---|---|
| `lattice_strut_cell(topo)` (`strut_cell.hpp`) | `{S, struts, nodes}`: integer coordinates in units of L/S, phase 0 at the cell's min corner. Canonical: a strut belongs to the cell holding its midpoint (half-open), a node to the cell holding it. |
| `strut_cell_closed_struts(cell)`, `strut_cell_closed_nodes(cell)` | every translate inside the CLOSED cell, for a renderer that draws cell by cell |
| `lattice_strut_diameter_mm(topo, rho, cell)` | the strut diameter core builds (the prism's circumradius is half of it) |
| `lattice_density_from_strut(topo, cell, radius)` | the other direction |
| `lattice_gen_topology_from_id(id)` | refuses an id core cannot build, by name |

The generator's ownership rule (so the preview places exactly what the run builds):
a strut is emitted by the cell whose half-open box holds its midpoint when that cell is
active; otherwise by the lexicographically smallest ACTIVE cell (i, then j, then k) that
shares it. A node ball is emitted the same way, but only among the cells that hold one of
its struts — a node no active cell's strut reaches is not emitted (diamond's cell corners
are the case that needs this).

### Sheets (`family: "sheet"`): what differs from a strut type
| call / key | answer |
|---|---|
| `tpms_eval`, `tpms_wall_distance`, `tpms_in_wall` (`tpms.hpp`) | the field the preview draws: period = the cell, phase 0 at the cell grid's anchor (the same anchor the app sends), the wall = |f|/|grad f| <= t/2 |
| `lattice_strut_diameter_mm(sheet, rho, cell)` | the TRUE wall thickness (what printability reads: wall >= bead) |
| `lattice_sheet_wall_param_mm(sheet, wall, cell)` | the field's t for that true wall (what `tpms_in_wall` takes) |
| `lattice_density_from_strut(sheet, cell, wall / 2)` | the density of that wall (the table; off it, the sheet's own solid fraction) |
| `sheet_triangles_coeff` | triangles per interior cell = coeff x (cell / DC cell)^2, DC cell = a third of the thinnest wall laid; `triangles_per_cell` is that at the band middle with an 8 mm cell |
| `doubled`, `stepped` | refused with the R5 reason; the job refuses `swept`, `fit`, `stepped` and stepped cells. Only `fixed` and `auto` lay a sheet, one cell for the part |
| `diagrid` | refused with the R8 reason; a sheet job must state `"skin": "rim"` or `"none"` (the default Diagrid is refused) |
| `aesthetic_density_ceiling` | the band top (a wall has no strut-per-cell "prints open" reading) |
| the sample block | shifted an eighth of a cell from the run's phase, so no corner of the cube cuts off a cap; the run keeps phase 0 at the grid anchor |
| R6 (wall >= one bead) | `sheet_printability.txt`: the density at which each cell size reaches one and two beads |
| the sample receipt (`<file.stl>.json`) | `strut_diameter_mm` is the true wall; `struts` and `nodes` are 0 |

### Every existing per-topology call accepts the new ids
`lattice_derive_cell_for_member`, `lattice_rho_min/max`, `lattice_cells_per_member_min`,
`lattice_percolation_cells_per_member_min`, `aesthetic_cells_per_member_hard_floor`,
`aesthetic_cells_per_member_floor`, `lattice_cell_printability_floor_mm`,
`lattice_min_printable_cell_mm`, `lattice_min_density_for_strut`,
`lattice_aesthetic_density_ceiling`, `stepped_size_menu`, `lattice_prints_open` — each
answers from the type's own measurement for a live type and refuses (never borrows) for
one that is not.

### The job (unchanged keys)
`lattice.topology` / `grading.topology` take any live id (they must agree, as before).
New refusals, each naming the reason: `"intent": "aesthetic"` with BCC or SC (Finding 6); `algorithm: "organic"` with a non-octet type; a
region `relative_density` outside the TYPE's band; Doubled/Stepped for a type whose R4
verdict is not PASS. Multiscale refuses every type but octet (its material model needs
octet's upper rows), with core's existing reason. Receipts name the type:
`run_info.grading.topology`, `lattice_topology`, `lattice_export_topology`. For SC and BCC each of
those blocks, the per-variant lattice receipt and the sample block's receipt also carry
`"directional_note"`, right after the topology; no other type writes the key.

### The volume check on every lattice receipt (Finding 7, 2026-11-02)
Each per-variant lattice receipt has `volume_check`: `certified_mm3`, `exported_mm3`, `gap`
(exported / certified - 1 over the judged pockets), `worst_gap` / `highest_gap` (the lightest and
heaviest judged pocket), `high_side` (plain: "file +N % over certified"), `refused`,
`judged_from_mm3` (one cell's volume), `voxels_lowered_to_file`, `voxels_held_at_band_floor`,
`law_certified_mm3` and `law_gap` (what the law alone would have certified), the small pockets not
judged, and the eight lightest judged pockets. A rung it refuses writes no lattice file and is skipped
by the ladder with core's plain reason ("the certificate counts ..."), as any refused rung is. The
run's lattice block carries `volume_check: {limit, refused_variants, worst_gap, certified_mm3,
exported_mm3}`. The app needs nothing new: the margin it shows is the rebuilt certificate's.

### The sample block
`topopt-cli lattice-sample --topology <id> [--cell 8] [--rho <band middle>] [--size 40]
[--plate 1.5] [--bead <mm>] --out <file.stl>` writes the STL and `<file.stl>.json`.
`topopt-cli --version` now ends with `lattice_sample=1`, so a worker can tell without a
trial run (brief item g).

### Since step (c) (2026-11-03): what the app reads differently for octet
Nothing new to call; the same calls answer from the full cell's law.

| call / field | before (c) | after (c) |
|---|---|---|
| `lattice_type_facts("octet").rho_min` / `rho_max` (and `lattice_rho_min/max`) | 0.0505 / 0.8999 | **0.0496 / 0.9003** |
| `printable_cell_per_bead` (finest printable cell = this x bead) | 2.6071 | **2.4821** |
| `aesthetic_density_ceiling` (strut = a fifth of the cell) | 0.2189 | **0.3788**: the same geometry, so the same picture; only the density number moves |
| `lattice_cell_printability_floor_mm(octet, 0.45)` (Auto's light floor) | 4.9314 mm | **7.0266 mm** |
| `lattice_min_printable_cell_mm(octet, 0.45, cap)` | 1.1732 mm uncapped, 2.25 mm at the cap | **1.1169 mm** uncapped, 2.25 mm at the cap |
| `lattice_prints_open(topo, cell, bead)` | octet's density at a bead-wide strut <= 0.20 | **bead <= 0.1898 x cell, every type** (no density read; `topo` kept in the signature) |
| `stepped_size_menu(topo, ...)` | per type's density | follows `lattice_prints_open`: octet unchanged, Rhombic gains, SC loses its 2 mm tile and 10 mm size |
| `lattice_cubic_tensor(octet, rho, ...)` | the legs-only rows (FCC's) | the full cell's 18 rows; FCC keeps the legs-only ones |

Plans: a `stepped_cells` entry sized on the old law can now build a strut under the bead and is
refused by core's existing check, naming the cell; a plan that sends no `rho` can be left with no
printable voxel at a small cell and is refused for having no density (handoff item 8). A plan the
app sizes on this core (`lattice_min_density_for_strut`) passes.

The app's sources read all of these from core. Six app TESTS pin octet's old numbers and will move
when this core is linked (app side, not touched here): `LatticeAestheticCeilingFromCoreTests`
(0.218871), `LatticeE1PrintableFloorTests`, `LatticeCapOneSourceTests`, `LatticeWizardTests`,
`LatticeStatedDensityDeliveryProbe`, `LatticeStageRepairEvidence`.

## Octet stays byte-identical (R9) — how it was proved

- **Reference binary**: `topopt-cli` built from a `git archive` of the base `da6cbd9f`, copied to a
  directory and `chmod a-w` before any run (K0's warning: rebuilding under a measurement voided
  its evidence twice). The new binary is frozen the same way.
- **The M2 stand, both paths, both modes** (`r9_octet_fcc_commit.txt`, by `r9_compare.py`): analyze
  Structural and Aesthetic (res 128) and `run` Structural (res 64, four rungs, both exported lattice
  STLs) — every file byte-identical except the leaves that name the binary or the clock
  (`fingerprint`, `build_time`, `created_wall_ms`, `*_ms`, `*_s`, `gen_fraction`, the output path
  inside `*_alpha.meta`). The comparison script was proved able to fail: octet against FCC goes RED
  with 33 real differences.
- **The named test binaries, base vs HEAD** (`identity_<type>.txt`; the reviewer has not yet said
  which 17 make "the 17-test", so this is the superset of every lattice / grading / cell-plan /
  stepped / job / analyze / orientation binary, 21 of them, stdout and stderr with the `[mg] S7`,
  `[mg-safe]` and `[loose] flood fill` lines dropped). See each type's line below for the count and
  what the differing ones differ in.

### Gate per type (one full ctest + cli_demo + the identity diff before each push)

| type | ctest | cli_demo | identity diff (21 binaries) |
|---|---|---|---|
| FCC | 165 / 165 passed, 4,347 s (`ctest_fcc.txt`) | passed, 1,994 s | 18 identical; 3 differ only in: `test_lattice_gen` 29 -> 30 checks (its enum tripwire checks one name per generatable type, and `fcc` is one more), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build directory's path inside two output lines (`identity_fcc.txt`) |
| Kelvin | 163 / 165 in the gate's archive copy; the two that failed (`app_core_capability_mirror`, `smooth_brush`) read `../app` and `../docs`, which a `git archive` of `core/` does not carry, and both pass re-run in that same build with the trees linked (`ctest_kelvin.txt`); the pipeline now links them | passed, 1,965 s | 19 identical; `test_lattice_gen` (one more tripwire name) and `test_lattice_void_exterior` (build path) as before (`identity_kelvin.txt`) |
| Rhombic | 165 / 165 passed, 4,174 s (`ctest_rhombic.txt`) | passed, 1,881 s | 18 identical; `test_lattice_gen` 29 -> 32 checks (one tripwire name each for fcc, kelvin, rhombic), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build path (`identity_rhombic.txt`) |
| Diamond | 165 / 165 passed, 4,210 s (`ctest_diamond.txt`) | passed, 1,903 s | 18 identical; `test_lattice_gen` 29 -> 33 checks (one tripwire name each for fcc, kelvin, rhombic, diamond), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build path (`identity_diamond.txt`) |
| BCC | 165 / 165 passed, 4,178 s (`ctest_bcc.txt`) | passed, 1,869 s | 18 identical; `test_lattice_gen` 29 -> 34 checks (one tripwire name each for fcc, kelvin, rhombic, diamond, bcc), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build path (`identity_bcc.txt`) |
| SC | 165 / 165 passed, 4,151 s (`ctest_sc.txt`; the commit also carries `af9b60a2` and `9118402c`) | passed, 1,866 s | 18 identical; `test_lattice_gen` 29 -> 35 checks (one tripwire name each for fcc, kelvin, rhombic, diamond, bcc, sc), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build path (`identity_sc.txt`) |
| Gyroid + Schwarz-D (one commit, `ccf0e03b`) | 165 / 166 passed, 4,141 s; the one failure, `lattice_certification`, held the certifiable count at 7 and the sheets make 9: fixed in `472b5632` (test only) and re-run in the same build, passed (`ctest_gyroid.txt`) | passed, 1,849 s | 17 identical; `test_lattice_gen` 29 -> 37 checks (one tripwire name each for the six strut types and the two sheets), `test_lattice_certification` the two lines of that fix, `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build path (`identity_gyroid.txt`) |

Tests added for the round: `test_strut_cell` (237 checks), `test_lattice_types` (85 at FCC). Edited, each
because it was built to flip when a type goes live: `test_strut_diameter_per_type` (FCC leaves the
"must refuse" loops, which now skip every type with its own law; section 3's certifiable-but-no-law
example moves from FCC to Kelvin; new section 3b pins FCC's law), `test_job` (FCC moves from
"known but not live" to "live parses on both keys"). Each later type moved the same way. Since SC
(the last strut type) no certifiable type is left without a law or a generator, so both tests now
hold the converse: every certifiable type has its own law and parses (`7ae8eea7`). At SC's gate
`test_lattice_types` has 195 checks (every live type, the Diagrid skin on a face just off a node
plane, and the R3 note on the receipts).

K2: `test_tpms` (34 checks: the field and its wall distance, the generator on a clipped, holed,
graded block, Stepped refused at the parse, the sample block one piece with the cell-line cut as its
control); `test_lattice_types` 208 (each sheet's facts, floors, R5/R8 reasons and off-table inverse);
`test_job` 302 (a sheet job states `"skin": "rim"`); `test_strut_diameter_per_type` 191 (the sheets
have their own law); `test_lattice_certification` (9 certifiable, `472b5632`).

<!-- TESTS -->
