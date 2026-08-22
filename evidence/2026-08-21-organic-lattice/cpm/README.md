# Can the cells-per-member floor go below 2?

Harness: `evidence/2026-07-28-graded-cell-size-phase0/graded_cell_size_probe.cpp`,
new section **C2c** plus two new knobs on `build_member`:
`TOPOPT_GCS_MEMBER_PHASE` (where the member's surface falls within a cell) and
`TOPOPT_GCS_SKIN` / `TOPOPT_GCS_SKIN_T` (a skin on the cut faces).

Positive control: C2b reproduces its published rows (2c +8.92 vs +8.5, 3c +4.15 vs
+4.1, 4c +2.58 vs +2.59).

## 1. Fractional cells-per-member is not a compromise, it is the worst case

Cell-aligned, macro mesh 2 elements across:

    1.00  +10.6%     1.75 +186.2%     3.00  +15.1%
    1.25  +46.0%     2.00   +8.9%     4.00  +18.8%
    1.50  +73.6%     2.50  +29.9%

The error is NOT monotone in cells-per-member. It spikes between whole cells because a
fractional width slices cells, so the member's surface cuts struts at MID-SPAN. A cut
strut is mass that carries no bending load. 1.5 is ~8x worse than either 1 or 2.

★ So a fractional floor is not blocked by missing data. It is a bad idea, and that is
why the measured table has only integers.

## 2. WHERE the cut falls matters more than HOW MANY cells

Same density (rho = 0.1991), same everything, only the lattice phase moves:

    cells   aligned   best-over-phase   WORST-over-phase
     1.00    +10.6%          +3.8%           +1917%
     1.50    +73.6%         +70.4%           +1844%
     2.00     +8.9%         -34.6%            +226%
     3.00    +15.1%         -37.5%            +102%
     4.00    +18.8%         -37.9%             +66%

At 1 cell across, a quarter-cell shift makes the member **18x softer at identical
density** (K 4.11 -> 0.226). The published curve is measured ALIGNED, i.e. best case,
so it understates the deployed error at every count. The one monotone quantity is
worst-over-phase — which is what a floor is actually answering, and it says >= 2.

★ Also worth checking before anyone quotes the curve again: production meshes the
homogenized lattice on the DESIGN GRID, not at one element per cell. The cube runs a
3.102 mm cell on a 0.625 mm voxel = **4.96 elements per cell**, where aligned 1-cell
reads -1.9% rather than the published +54%. A share of the published 1-cell penalty is
macro discretisation, not scale separation.

## 3. A skin on the cut faces removes the danger and costs too much to be the answer

a = 1 cell across:

    skin            phase 0.0              phase 0.25           density
    none            +10.6%                 +1917%               1.0x
    net  t=1r       -77.7%                 -67.5%               1.6x
    net  t=2r       -87.0%                 -84.5%               2.7x
    solid t=2r      -93.3%                 -93.4%               3.9x

★ THE PHASE SENSITIVITY DISAPPEARS: a ~1900-point spread becomes ~10 points. And the
sign flips — the homogenized model goes from over-predicting stiffness by 20x (the
part is far WEAKER than its certificate: dangerous) to under-predicting it (safe).

★ BUT IT IS NOT A GO FOR THE PURPOSE. The reason to want fewer cells per member is
bigger cells and less plastic; the lightest skin measured costs 1.6x the density,
which spends the saving and more. And the certificate becomes 67-87% conservative,
because the homogenized tensor does not know the skin is there.

## Verdict

* 1 cell/member BARE: **NO**. +1917% worst case over phase.
* 1.5 cells/member: **NO**, and now measured rather than assumed.
* 1 cell/member WITH A SKIN: safe, but 1.6-2.7x the density and a certificate that
  under-predicts by 67-87%. It does not deliver what the smaller floor was wanted for.
* **The cheap lever is PHASE, not the floor.** Aligned and bare, 1 cell across is
  +10.6% and 2 cells is +8.9%. Alignment costs no material at all.

## Limits of this measurement

One topology (octet), one density (rho ~ 0.199), one cell size (S = 5 mm), one bending
mode, one macro mesh refinement per row. The net skin here is a uniform grid on the
node pitch over the whole face — a real net-skin ties only the ACTUAL cut ends and
would be lighter than 1.6x. Before any constant moves, reproduce at a second density
and with a tie-the-cut-ends skin.

---

# 4. Does the relaxed floor change anything? (added after the gate was built)

★ THREE FIXTURES PROVED NOTHING BEFORE ONE PROVED SOMETHING, and the failures are
worth recording because each looked like a valid test:

* 40 mm CUBE — a solid block. `min_member_width_mm` is absent: nothing bounds the cell,
  so the floor relaxes 5 -> 1 and no output changes.
* 40 x 40 x 6 mm SLAB — thicker than the EDT measurement cap, so member width again
  reports no bound. Same non-result.
* 40 x 40 x 3 mm SLAB at res 128 — too thin to lattice AT ALL. Everything fell back to
  solid, there were no candidate voxels, and the adaptive rule returned the accuracy
  floor (5) because the loop it runs over was empty.

The floor only does work when `member_width / floor` is the TIGHTEST bound on the cell.
That needs a member width that is finite AND measured AND small enough to bind — which
synthetic slabs miss on one side or the other. The maintainer's own part sits in the
middle. Searching every receipt in the tree for a finite `min_member_width_mm` found it
in one line.

## M2_verticalStand, `jobs/adaptive_on.json`, ONLY the floor changed

                                floor 2 (before)   floor 1 (now)
    min cells ALLOWED                          2               1
    min cells ACHIEVED                     2.558           1.705
    thinnest member reached mm              6.821           3.411
    ★ latticed voxels                      96,891          98,536
    ★ fell back to SOLID                   14,013          12,368
    below accuracy floor voxels             4,113           5,713
    cell size mm                                4               4

★ 1,645 VOXELS THAT WERE SOLID PLASTIC ARE NOW LATTICED. The cap is
`member_width / floor`: at floor 2 a 6.821 mm member admits only a 3.41 mm cell, below
the 4 mm the ladder wanted, so those cells went solid. At floor 1 the cap is 6.82 mm and
the same member takes the 4 mm cell. The lattice reaches members HALF AS THIN.

★ AND THE COST IS ON THE RECEIPT: `below_accuracy_floor_voxels` rises 4,113 -> 5,713.
More material is knowingly outside the homogenised model's regime. That is the trade the
maintainer asked for, and it is counted rather than hidden.

# 5. The second density (added with the same amendment)

Every finding above was measured at rho = 0.199. Repeated at rho = 0.454:

    a (cells)   bare aligned   bare 1/4-phase   skin aligned   skin 1/4-phase
      1.0            -8.1 %         +193.8 %        -69.2 %         -67.9 %
      1.5           +31.0 %         +181.8 %        -58.6 %         -54.0 %
      2.0            +8.6 %          +56.3 %        -50.4 %         -50.3 %
      3.0           +14.7 %          +39.7 %        -34.4 %         -34.7 %

All three findings reproduce: fractional is worse than either neighbour (1.5 at +31.0 %
between -8.1 % and +8.6 %); bare 1-cell is phase-sensitive; a skin collapses the spread
(1.3 points) and flips the sign to conservative.

★ THE MAGNITUDE IS DENSITY-DEPENDENT and the floor does not model that: the bare 1-cell
phase penalty is +1917 % at rho 0.199 but +194 % at rho 0.454. Fatter struts are harder
to sever. A floor that varied with density would be better founded than one that does
not, and nothing here does.

★ HONEST NOTE ON THE SWEEP: a third arm was requested at target vf 0.15 and came back at
rho 0.1991 — identical to the first. The octet calibration did not reach that target, so
this is TWO densities, not three.
