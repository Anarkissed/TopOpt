# RUNNING NOTES — results as they land

## measured (design lattice, factor 2 tricubic, one probe invocation)

| arm | cut | vs SIMP | n_cut | vs SIMP | whole | CAD | share | vol mm3 | mfv |
|---|---|---|---|---|---|---|---|---|---|
| SIMP 0.68 | 7.5521 | — | 26191 | — | 8.4075 | 7.5842 | 9.2% | 440550.9 | 5464 |
| RB1_volcount | 14.3779 | +90.4% | 80147 | +206.0% | 11.7983 | 8.1970 | 21.3% | 371578.9 | 7192 |
| S0_seed16 | 12.8206 | +69.8% | 73014 | +178.8% | 10.8178 | 7.9938 | 20.3% | 372278.5 | 5307 |
| P1_c1 | 12.7098 | +68.3% | 60329 | +130.3% | 10.4445 | 7.7680 | 17.9% | 372332.9 | 5137 |

PR 324 ARM 2 (for reference only): 14.1076 / 79679 / 11.5068 / 7.8081 / 42.9% share (its own convention) / 370148.5

## certified (each arm's own summary.txt; CURVES pending)

| arm | margin | vs SIMP | peak vM | mass g | vf | mfv(summary) | verdict |
|---|---|---|---|---|---|---|---|
| SIMP 0.68 | 3254.34 | — | 0.016900 | 543.7 | 0.679951 | 5464 | ACCEPTED |
| PR 324 ARM 2 | 3391.74 | +4.2% | 0.016216 | 463.01 | 0.678839 | 2936 | ACCEPTED |
| RB1_volcount | 2256.31 | -30.7% | 0.024376 | 463.77 | 0.680003 | 2689 | ACCEPTED |
| S0_seed16 | 3389.48 | +4.2% | 0.016227 | 463.80 | 0.680003 | 1193 | ACCEPTED |
| P1_c1 | 3028.05 | -7.0% | 0.018163 | 463.74 | 0.679994 | 926 | ACCEPTED |

## readings so far

1. ★ S1 WORKS AND THE DRIFT WAS LARGE. PR 324: occupancy_volume pinned at
   75414.72 every iteration while printed_voxels went 79,984 -> 73,283 -> ... ->
   75,286, a swing of 6,701 voxels (8.9%). With --volume-count printed_voxels is
   75,414-75,415 on every one of 60 iterations and equals occupancy_volume by
   construction (asserted each iteration).

2. ★ S1 DOES NOT MOVE THE SURFACE. cut 14.38 vs PR 324's 14.11; n_cut 80,147 vs
   79,679. It is a bookkeeping fix, and the 3x surface problem is exactly where
   PR 324 left it. Expected, and worth stating because it isolates S3.

3. ★★ THE ENDPOINT MARGIN IS A LOCAL-STRESS DRAW, AND THE RE-BASELINE PROVES IT.
   Compliance 0.00251003 (RB1) vs 0.00251386 (PR 324) — the same design to four
   significant figures — but final certified margin 2256 vs 3392, and peak vM
   0.024376 vs 0.016216. Two same-compliance designs, margins 50% apart. With
   PR 325's 2015->3172->2015 swing and PR 324's two-fits-disagree-by-64%, the
   endpoint is not the measurement; the CURVE's level is. Hence T2's median.

4. ★★ THE SURFACE IS NUCLEATED, NOT SEEDED. Eight times fewer seed holes
   (period 8 -> 16) removed only 8.9% of the internal surface. So the fine
   structure is CREATED during optimisation, not inherited — which is the
   parametric form's hole-nucleation ability, the very property that lets it
   replace SIMP with no seed. The only term that prices nucleation is the
   perimeter penalty, because creating a hole creates interface before it
   creates any compliance benefit. That is why S3 is the main event and the seed
   is not.

5. ★ BUT THE SEED IS FREE AND IT BUYS THE MARGIN BACK. S0: margin 3389 (+4.2%
   over SIMP, and +50% over RB1), peak vM 33% lower than RB1, mass unchanged,
   surface 8.9% lower. No extra term, no extra solve. A clear keep.
   ★ AND PERIOD 16 IS ABOUT THE LIMIT ON THIS PART: the thin axis is 31 voxels,
   so period 16 already gives about two holes across it and period 24 would give
   one. The slab shape caps this lever, which is the same consideration R4 is
   about.

6. ★ CUT ROUGHNESS AND TRIANGLE COUNT DO NOT MOVE TOGETHER (P5, live). S0 and P1
   sit at essentially the same cut roughness (12.82 vs 12.71) with very
   different surface (73,014 vs 60,329) and very different margin (3389 vs
   3028). n_cut is the quantity being minimised; the angle is a proxy over a
   population that moves underneath it.

7. ★ THE PENALTY IS STRONGER HERE THAN ON THE VOXEL ARMS. PR 325's voxel arm at
   C=2 moved the interface-area integral 22%. Here C=1 moved the emitted
   triangle count 24.7% and the in-loop area integral about 45% at a matched
   iteration (12,666 mm2 at it 21 against RB1's 23,110 at it 20). Consistent
   with the S3(d) prediction, but NOT yet a test of it — every frontier arm runs
   --plsm-refit-every 5. N1_c4_norefit is the pair that tests it.

## still to land
P3_c4, P2_c2, P4_c8, PR_c4_ramp; then N1_c4_norefit and A2_all;
then M1/M2 for all arms, S2, the stopping-rule question, ctest.

## ★★ THE FRONTIER, and the qualification that comes with it

| arm | cut | n_cut | whole | CAD | ★ mid % | ★ obl_cad_rms | margin | vs SIMP |
|---|---|---|---|---|---|---|---|---|
| SIMP 0.68 | 7.5521 | 26191 | 8.4075 | 7.5842 | 85.28% | 0.4293 | 3254.3 | — |
| C=0 seed 8 (RB1) | 14.3779 | 80147 | 11.7983 | 8.1970 | 57.85% | 0.4857 | 2256.3 | -30.7% |
| C=0 seed 16 (S0) | 12.8206 | 73014 | 10.8178 | 7.9938 | 61.38% | 0.4851 | 3389.5 | +4.2% |
| C=1 | 12.7098 | 60329 | 10.4445 | 7.7680 | 71.98% | 0.4293 | 3028.1 | -7.0% |
| C=2 | 10.3182 | 52396 | 9.3982 | 7.8412 | 80.07% | 0.4143 | 1552.4 | -52.3% |
| C=4 | 8.1070 | 45042 | 8.6587 | 7.7758 | 87.46% | 0.4090 | 1368.8 | -57.9% |
| C=8 | 15.3827 | 84980 | 14.7981 | 13.5025 | 30.73% | 0.5340 | 1026.3 | -68.5% |

### ★★ 8. THE PENALTY BUYS PART OF ITS DIHEDRAL NUMBER BY RETURNING THE SURFACE
### TO THE GRID, AND THE TRIANGLE COUNT IS WHY WE KNOW.
midpoint_share goes 57.85% -> 71.98% -> 80.07% -> **87.46%** across C = 0,1,2,4.
SIMP's is 85.28%, and 85% IS the staircase. So at C=4 the surface is MORE
grid-snapped than SIMP's, and a dihedral angle measured on a grid-snapped
surface is low for the wrong reason. PR 325 saw the same thing at C=8 on the
voxel arm ("a heavy perimeter penalty buys dihedral smoothness by returning the
surface to the grid") and it reproduces here, earlier and harder.

★ **`n_cut` IS NOT SUBJECT TO THAT.** 80,147 -> 45,042 is a real reduction in
how much interface exists, wherever its vertices land. THIS IS WHY R3 ASKS FOR
THE TRIANGLE COUNT AND WHY THE ANGLE ALONE WOULD HAVE MISLED. The brief was
right to insist on it.

★ **And `obl_cad_rms_mm` — a true error against the real CAD geometry, the one a
blur cannot fake — IMPROVES**: 0.4857 -> 0.4293 -> 0.4143 -> 0.4090 against
SIMP's 0.4293. Consistent rather than contradictory: this part's CAD faces are
largely planar and axis-aligned, so a surface that flattens onto the grid also
sits closer to them. Both readings are true and the pair is the honest report.

### ★ 9. C=8 IS NOT A FRONTIER POINT, IT IS A FAILURE
cut 15.38, n_cut 84,980, CAD 13.50, midpoint 30.73%, min-feature violations
11,202, triangles 464,764 against SIMP's 284,704, and certified compliance
0.00482 — nearly double. The design has broken up. Monotonicity in the sweep
ends between C=4 and C=8, which is the same shape PR 324 §2 found in the fit
sweep (W8 at 154x worse than W6 at 75x) and the same reason: past a point the
term stops shaping the design and starts destroying it.

### ★ 10. C=1 IS THE KNEE AND THE MARGIN FALLS OFF A CLIFF, IT DOES NOT DECAY
2256 (C=0) / 3028 (C=1) / 1552 (C=2) / 1369 (C=4) / 1026 (C=8). Everything at or
above C=2 is below HALF of SIMP. At C=1 the CAD error is exactly SIMP's
(0.4293), midpoint is still 14 points below SIMP's, n_cut is down 24.7% and the
margin is within 7%.

## ★★ 11. S2 — THE FROZEN REGION FROM THE CAD. The remaining two thirds, recovered.

The SAME design (`RB1_volcount`'s alpha), emitted at F=2 under three frozen
treatments, measured in one probe invocation with a SIMP control on the same
lattice. ★ Volume is beside every row because these rows do NOT hold it equal.

| treatment | cut | ★ **CAD** | whole | n_cut | mid % | ★ obl_cad_rms mm | volume mm3 |
|---|---|---|---|---|---|---|---|
| SIMP control, same lattice | 7.5521 | 7.5842 | 8.4075 | 26191 | 42.09% | 0.4293 | 440550.9 |
| hard STAMP (what ARM 2 exports today) | 16.1285 | 13.2414 | 15.2341 | 78945 | 58.70% | 0.5557 | 372433.3 |
| smooth boolean, VOXEL TAGS (PR 324 §5's best) | 12.6609 | 13.1572 | 13.7798 | 65005 | 82.36% | 0.5102 | 315189.6 |
| ★ smooth boolean, **CAD FACES** | 14.9668 | **7.6520** | 11.6922 | 83920 | **6.30%** | **0.3232** | 366304.4 |

★ **S2(c) ANSWERED: essentially ALL of the remaining two thirds.** PR 324 §5
took the CAD population from a hard stamp to a tags boolean and said the rest
was "the voxel-shaped boundary". The CAD population goes **13.16 -> 7.65**,
against SIMP's 7.5842 — within 0.9% of SIMP, from 74% above it.

★ **AND THE ERROR THAT CANNOT BE FAKED GOES WITH IT.** `obl_cad_rms_mm` is a
true deviation from the real CAD geometry: 0.5557 (stamp) -> 0.5102 (tags) ->
**0.3232 (CAD)**, against SIMP's 0.4293. **25% MORE ACCURATE THAN SIMP** on the
faces the optimiser never had any say over. midpoint_share on the same rows:
58.70% -> 82.36% -> **6.30%**. The staircase on the CAD faces is gone.

★ **WHAT IT DOES NOT FIX, SAID PLAINLY: the CARVED population.** cut 14.97
against the tags boolean's 12.66, and n_cut 83,920 against 65,005. That is not
the CAD treatment being worse — **the tags boolean has EATEN 14% OF THE PART**
(volume 315,190 against 366,304), because its frozen boundary is sampled by the
containing COARSE voxel and at F=2 that erodes. A design with less of itself
left has less carved surface to measure. The volume column is in the table so
this cannot be read as a win for the tags.

★ **The frozen treatment is a CAD-face fix and nothing else.** It does not touch
the carved surface, which is what S3 is for, and the two are complementary
rather than alternatives.

## ★★ 12. eta — ONE FIXED DESIGN, FOUR BAND WIDTHS. The classification does not move.

`RB1_volcount`'s own coefficients, emitted at F=2 under the CAD frozen boolean at
four eta, volume held by construction (the match counts #{phi_eff < 0}, which
does not contain eta):

| eta | tris | n_cad | n_cut | cut share | carved | CAD | obl_cad mm | mid % |
|---|---|---|---|---|---|---|---|---|
| 0.5 | 386,264 | 105,691 | 83,912 | 44.26% | 16.4872 | 7.7430 | 0.3227 | 11.32% |
| 1 | 386,264 | 105,718 | 83,906 | 44.25% | 15.1830 | 7.4306 | 0.3221 | 6.59% |
| **2 (what everything ran at)** | 386,264 | 105,506 | 83,920 | 44.30% | 14.9668 | 7.6520 | 0.3232 | 6.30% |
| 4 | 386,264 | 105,575 | 83,928 | 44.29% | 14.9794 | 7.9979 | 0.3231 | 6.25% |

★ **AN EIGHT-FOLD CHANGE IN eta MOVES THE CAD/CUT SPLIT BY 0.05 PERCENTAGE
POINTS.** n_cad 105,506-105,718 (0.2% spread), n_cut 83,906-83,928 (0.03%),
`tris` **IDENTICAL** at 386,264 on all four rows.

★ **AND THERE IS A PROOF BEHIND THE MEASUREMENT, WHICH IS WHY IT IS EXACTLY
FLAT.** The extraction takes iso 0.5 and `H_eta` is monotone with H(0) = 0.5, so
the crossing set is the SIGN SET of phi_eff — and the sign of phi_eff does not
contain eta. **eta cannot change the topology of the extracted mesh at all.** It
is a pure sub-voxel VERTEX-PLACEMENT knob: same triangles, same classification,
different positions within their cells. The identical `tris` column is that
statement measured.

★ **SO THE CARVED SHARE IS NOT A CLASSIFICATION ARTEFACT and the 3x surface gap
is real.** Nothing in this task's frontier is chasing a measurement.

★ **AND `obl_cad_rms_mm` IS FLAT TOO** — 0.3221 to 0.3232, a 0.3% spread. By the
projection argument that is the diagnostic answer: eta does not reach the CAD
faces, projection is not being starved, and the question collapses to the carved
population, which is this task's subject.

★ **WHAT eta DOES MOVE, AND IT SATURATES BY 2.** Carved roughness 16.4872 (eta
0.5) -> 15.1830 (1) -> 14.9668 (2) -> 14.9794 (4), and midpoint share 11.32% ->
6.59% -> 6.30% -> 6.25%. A narrow band re-manufactures the staircase — PR 324
§3's band control, reproduced from the other direction — and the curve is flat
from eta = 2 on. **PR 324's untested choice of 2 was the right one, and it is
now tested.**

★ **THE SCOPE LIMIT THAT REMAINS, STATED.** The perimeter functional
Per = ∫ DH_eta(phi)|grad phi| dΩ contains eta, so S3's weight sweep is
conditional on eta = 2 — the EXTRACTION being insensitive does not prove the
GRADIENT is. `E1_c1_eta1` tests that at the knee.

## ★★ 13. THE MARGIN LOTTERY, MEASURED ON ONE TRAJECTORY, THREE ITERATIONS APART

`levelset_probe` certifies the BEST-COMPLIANCE iterate, not the last (an explicit
step can overshoot). For `A2_all` that is iteration 57. Its snapshots are every
tenth, so iteration 60 is certified separately. The two are three iterations
apart on a converged trajectory:

| A2_all | compliance | certified margin |
|---|---|---|
| iteration 57 (what the summary reports) | 0.00280873 | **2247.4** |
| iteration 60 (the snapshot) | 0.00281420 | **2880** |

★ **0.2% apart in stiffness, 28% apart in certified margin.** And its whole
snapshot curve runs 607 / 1443 / 1763 / 2639 / 3073 / 2594 / 2880 — the last four,
all past convergence, span 3073 down to 2594 and back to 2880, ±9% between
adjacent snapshots.

★ **This is the cleanest demonstration in the whole line of work that a single
iterate's certified margin is a local-stress draw.** It is not a property of the
method, the penalty or the seed — it is the same design, twice.

★ **CONSEQUENCE FOR EVERY TABLE, INCLUDING THIS TASK'S.** The frontier's margin
column (2256 / 3028 / 1552 / 1369 / 1026) is a column of single draws. The
ORDERING is probably real — the fall from C=1 to C=2 is 49%, far outside the ±9%
seen within one trajectory — but "C=1 costs 7% of margin" is not a number that
survives its own error bar. Reported as a curve, and the plain-language section
says so.
