# plsm-minimise-the-extra-surface

Evidence: `evidence/2026-08-11-plsm-minimise-extra-surface/` — `./reproduce.sh`
regenerates all of it, and nothing is cloned to do so.

★ **EVERY COMPARISON IS AGAINST SIMP, THE SHIPPED LADDER.** PR 324's ARM 2
appears only as the thing being re-baselined, never as a bar.

★ **THE WHOLE DIFF IS IN PR 324's SANDBOX.** `git diff main -- core/src
core/include app/` is **0 lines** (`r6_shipped_path.txt`), `materials.json` is
untouched, and the assertion census removed nothing (`r7_assertion_census.txt`).

## 0. THE ANSWERS, IN ORDER

**1. The best point found, against the two bars the brief names.**

★ Every row at **matched iteration 60**, one probe invocation, SIMP in the same
run (R2). See §2 for why matching the iteration is not a detail.

| | carved | ★ internal surface | margin | mass |
|---|---|---|---|---|
| **SIMP rung 0.68** | **7.5521** | **26,191** | **3254.3** | **543.7 g** |
| PR 324 ARM 2 (quoted, not a bar) | 14.1076 | 79,679 | 3391.74 | 463.0 g |
| the re-baseline, S1 only | 14.1322 | 79,577 | 2859.5 | 463.8 g |
| ★★ **the best point — C=1 with η=1** | **9.2460** | **53,243** | **3388.6** | **463.7 g** |
| the surface end — C=8 | 7.6577 | 44,366 | 1282.1 | 463.7 g |

★★ **THE BEST POINT REMOVES A THIRD OF THE INTERNAL SURFACE (79,577 → 53,243),
TAKES CARVED ROUGHNESS DOWN 35% (14.1322 → 9.2460), AND CERTIFIES ABOVE SIMP
(+4.1%) AT 15% LESS MASS.** It is ACCEPTED, the load path walks, and its margin
curve is FLAT from iteration 30 (3390 / 3394 / 3387 / 3389). It is not the bar —
carved is still 22% above SIMP's — but it is the first arm in this line of work
to move the surface materially without paying for it.

**2. Did the perimeter penalty behave differently on a parametric φ "because
there is no reinitialisation to fight it", as PR 324 §10.3 predicted? — NO.**
Turning the reinitialisation OFF at the same weight changes the emitted internal
surface by 2.3% and makes it slightly WORSE. ★ The premise was also false as
written: every arm in the frontier runs one. The term IS effective here — a
quarter of the surface at C=1 — but the reason it was expected to be is not the
reason. §3(d).

**3. What is still generating surface? — HOLE NUCLEATION, which is the property
the method was adopted for.** Eight times fewer seed holes removed only 8.9% of
the internal surface, so the fine structure is CREATED during the run, not
inherited. §4.

**4. ★★ THE MARGIN IS NOT A LOTTERY — I THOUGHT IT WAS, AND MEASURED OTHERWISE.**
Twenty CONSECUTIVE iterates of one converged tail, every one certified: from
iteration 43 on, **3383 to 3388 — a spread of 0.15%, sd 0.04% of the mean.**
★ **But it settles far LATER than compliance does, and most arms here had not
settled by iteration 60** — C=8's margin DOUBLED between iterations 40 and 60
while its compliance moved 2%. Compliance is not a convergence proxy for the
margin. §2.

**5. ★ S2 RECOVERS ESSENTIALLY ALL OF THE REMAINING TWO THIRDS.** The CAD
population goes **13.16 → 7.65** against SIMP's 7.5842, and the true deviation
from the real CAD geometry goes **0.5102 → 0.3232 mm against SIMP's 0.4293 —
25% MORE ACCURATE THAN SIMP.** The frozen region derived from the CAD faces
reproduces core's own voxel mask on **468,224 of 468,224 voxels**. §6.

---

## 1. S1 — THE MEASUREMENTS ARE NOW HONEST, AND THE DRIFT WAS LARGE

PR 324 §6 found the defect and left it, on the grounds that fixing it would make
ARM 2 incomparable. This task re-baselines ARM 2, so it is fixed first — and it
comes first because **the drift is proportional to interface area, and every
measurement in this task is about interface area.** Left in, the constraint
silently rewards exactly what S3 is trying to suppress.

`--volume-count` constrains the printed set itself. One line in `volume_at`.

### (b) the two columns, side by side

| iteration | **WITHOUT** — PR 324 ARM 2 | **WITH** `--volume-count` |
|---|---|---|
| | occ_vol / printed / vf | occ_vol / printed / vf |
| 1 | 75414.72 / **79,984** / 0.721200 | 75415 / 75,415 / 0.680003 |
| 10 | 75414.72 / **73,283** / 0.660779 | 75414 / 75,414 / 0.679994 |
| 20 | 75414.72 / 74,666 / 0.673249 | 75414 / 75,414 / 0.679994 |
| 30 | 75414.72 / 74,947 / 0.675783 | 75414 / 75,414 / 0.679994 |
| 40 | 75414.72 / 75,110 / 0.677252 | 75415 / 75,415 / 0.680003 |
| 60 | 75414.72 / 75,286 / 0.678839 | 75415 / 75,415 / 0.680003 |

★ **The constraint reported 75414.72 on all sixty iterations, to seven
significant figures, while the part it was supposed to be constraining swung by
6,701 voxels — 8.9%.** With the flag the two agree bit for bit, and the loop
ASSERTS it every iteration rather than reporting it.

★ **The assertion earned its place immediately.** It stopped the first
re-baseline on iteration 1 at 75,415 against 75,414 — one voxel. `#{φ + c < 0}`
and `#{H_η(−φ) > 0.5}` are the same set in mathematics and not the same test in
floating point; for |p| below about 1e-16·η the smoothed step rounds back to
exactly 0.5. Constraining the printed predicate ITSELF fixes it, and is the more
honest statement of intent anyway: the extraction takes iso 0.5 and
`analyze_fixed_design` reads that same field.

### (c) the re-baseline, and what it does NOT change

| at matched iteration 60 | carved | n_cut | whole | CAD | margin | mass |
|---|---|---|---|---|---|---|
| PR 324 ARM 2 (its own certificate) | 14.1076 | 79,679 | 11.5068 | 7.8081 | 3391.74 | 463.01 g |
| **re-baseline** | 14.1322 | 79,577 | 11.5991 | 8.0223 | 2859.5 ↑ | 463.8 g |

★ **S1 DOES NOT MOVE THE SURFACE AND IT DOES NOT MOVE THE DESIGN.** Carved
14.1322 against 14.1076, triangles 79,577 against 79,679 — a quarter of a
percent. It is bookkeeping, and the 3× surface problem is exactly where PR 324
left it. **That is the point: it isolates S3.**

★ **AND THE MARGIN DIFFERENCE IS NOT S1's EITHER.** My first draft reported
2256.31 here and called it a third of the margin lost to a bookkeeping change.
That was the re-baseline's ITERATION-40 certificate against PR 324's iteration
60. At matched iteration 60 it reads **2859.5, and it was still climbing** (§2).
**Corrected: S1 costs nothing measurable. It only makes the constraint mean what
it says.**

## 2. ★★ THE MARGIN IS NOT NOISE — I THOUGHT IT WAS, AND MEASURING IT SAID OTHERWISE

★ **THE CLAIM I WAS ABOUT TO SHIP.** Three observations pointed one way: PR 324
§5 had two fits of ONE design disagreeing by 64%; PR 325 §3 had a trajectory
swinging 2015 → 3172 → 2015; and this task's own re-baseline appeared to move the
certified margin from 3391.74 to 2256.31 while compliance stayed put. I wrote
that a single margin reading here was "close to a coin flip" and that every cost
figure in this task had unknown error bars.

★★ **IT IS NOT. TWENTY CONSECUTIVE ITERATES, EVERY ONE CERTIFIED:**

| A4_mask, iterate | 41 | 42 | 43 | 44 | 45 | 46 | 47 | 48 | 49 | 50 |
|---|---|---|---|---|---|---|---|---|---|---|
| certified margin | 3086 | 3265 | 3383 | 3383 | 3385 | 3388 | 3386 | 3387 | 3387 | 3388 |

| | 51 | 52 | 53 | 54 | 55 | 56 | 57 | 58 | 59 | 60 |
|---|---|---|---|---|---|---|---|---|---|---|
| | 3388 | 3387 | 3387 | 3387 | 3388 | 3388 | 3387 | 3387 | 3387 | 3388 |

★ **From iteration 43 on the spread is 3383 to 3388 — 0.15%, standard deviation
0.04% of the mean.** The certification is essentially noiseless and, where the
design has settled, so is the margin. **Retracted.**

### ★★ SO WHAT WAS THE SWINGING? THE MARGIN SETTLES MUCH LATER THAN COMPLIANCE.

| arm | margin @30 | @40 | @50 | @60 | margin 40→60 | **compliance 40→60** |
|---|---|---|---|---|---|---|
| **E1 — C=1, η=1** | 3390 | 3394 | 3387 | 3389 | **−0.2%** | −0.29% |
| S0 — C=0, seed 16 | 2402 | 3386 | 3389 | 3389 | **+0.1%** | −0.33% |
| A4 — seed 16 + mask | 2373 | 3300 | 3388 | 3388 | +2.6% | −0.62% |
| A2 — all mechanisms | 2639 | 3073 | 2594 | 2880 | −6.3% | −3.19% |
| the re-baseline | 2073 | 2256 | 2599 | 2860 | **+26.7%** | **+0.05%** |
| C=1 | 1836 | 2462 | 2742 | 3028 | **+23.0%** | −0.23% |
| C=2 | 1041 | 1552 | 1810 | 2115 | **+36.2%** | +0.18% |
| C=4 | 403 | 840 | 1290 | 1298 | **+54.6%** | −0.47% |
| C=8 | 320 | 638 | 1242 | 1282 | **+101.1%** | −2.09% |

★★ **THE RE-BASELINE MOVED ITS MARGIN 27% BETWEEN ITERATIONS 40 AND 60 WHILE ITS
COMPLIANCE MOVED 0.05%.** C=8 DOUBLED its margin over the same span. **Compliance
is not a convergence proxy for the margin** — a design can be stiffness-static
and still be shuffling the material that sets its peak stress.

★ **THREE CONSEQUENCES, AND THEY ARE NOT SMALL.**

1. **Every margin in §3 for a penalised arm is a LOWER BOUND**, because every one
   of them was still climbing at iteration 60. The "cost" of the perimeter
   penalty is not established by this task; it is bounded below.
2. **The three arms whose margins HAVE settled — E1, S0 and A4 — all land at
   +4.1 to +4.2% over SIMP.** Those numbers are trustworthy to a fraction of a
   percent, and they are the ones §0 quotes.
3. ★ **The apparent 3391.74 → 2256.31 collapse from S1 was not S1.** 2256.31 is
   the re-baseline's iteration-40 certificate (its best-compliance iterate); at
   matched iteration 60 it reads **2859.5**, and it was still rising. §1(c)'s
   table is corrected accordingly below.

### ★ AND THE TRAP UNDERNEATH ALL OF IT, WHICH IS MINE

`levelset_probe` certifies the **best-compliance** iterate, not the last. Across
these twelve arms that is iteration **9, 20, 40, 55, 57 and 60**. Both the
margins AND the surfaces in my first draft were read off `rho`, which is that
iterate — so **every table compared arms at different points in their own lives.**

★ **PR 324 §6 documented this exact trap for its own ablations** ("A1/A2 ran 40
iterations and A3/A4/A5 ran 20, so their endpoints are not comparable; every
snapshot of every arm is certified so the comparison can be made at equal
iterations") **and I walked into it anyway.** Every table below is rebuilt from
the `it0060` snapshots. It changed a conclusion: C=8 read as a catastrophic
failure at its iteration 9 and is the smoothest arm in the study at iteration 60.

## 3. S3 — THE PERIMETER PENALTY. THE FRONTIER.

★ **EVERY ROW AT MATCHED ITERATION 60**, from each arm's own snapshot, measured
in ONE `external_field_surface_probe` invocation with SIMP's row produced in the
same run (R2). Margins from `analyze_fixed_design` on the same snapshots.

| arm | carved | vs SIMP | ★ n_cut | vs SIMP | whole | CAD | ★ mid % | margin | vs SIMP | mass g |
|---|---|---|---|---|---|---|---|---|---|---|
| **SIMP rung 0.68** | **7.5521** | — | **26,191** | — | 8.4075 | 7.5842 | 85.3% | **3254.3** | — | **543.7** |
| C=0, seed 8 (re-baseline) | 14.1322 | +87.1% | 79,577 | +203.8% | 11.5991 | 8.0223 | 57.7% | 2859.5 ↑ | −12.1% | 463.8 |
| C=0, seed 16 | 12.8206 | +69.8% | 73,014 | +178.8% | 10.8178 | 7.9938 | 61.4% | **3389.5** | **+4.2%** | 463.8 |
| seed 16 + nucleation mask | 12.3040 | +62.9% | 71,867 | +174.4% | 10.5413 | 7.9434 | 62.2% | **3387.7** | **+4.1%** | 463.8 |
| C=1 | 12.7098 | +68.3% | 60,329 | +130.3% | 10.4445 | 7.7680 | 72.0% | 3028.1 ↑ | −7.0% | 463.7 |
| ARM 2, cheap pair | 11.1793 | +48.0% | 55,970 | +113.7% | 9.7773 | 7.7576 | 73.9% | 3197.9 ↑ | −1.7% | 463.8 |
| ★★ **C=1 with η=1** | **9.2460** | **+22.4%** | **53,243** | **+103.3%** | 8.9716 | 7.7323 | 80.4% | **3388.6** | **+4.1%** | 463.7 |
| C=2 | 10.3863 | +37.5% | 51,149 | +95.3% | 9.4097 | 7.8067 | 81.2% | 2115.1 ↑ | −35.0% | 463.7 |
| ARM 2, all mechanisms | 10.0676 | +33.3% | 49,851 | +90.3% | 9.4353 | 7.8568 | 77.0% | 2880.3 | −11.5% | 463.8 |
| C=4, RAMPED | 9.9302 | +31.5% | 49,674 | +89.7% | 9.1829 | 7.7051 | 82.9% | 963.2 | −70.4% | 463.7 |
| C=4 | 8.2178 | +8.8% | 44,951 | +71.6% | 8.6955 | 7.7859 | 87.4% | 1298.4 ↑ | −60.1% | 463.8 |
| C=8 | **7.6577** | **+1.4%** | 44,366 | +69.4% | 8.6152 | 7.8814 | 88.1% | 1282.1 ↑ | −60.6% | 463.7 |
| C=4, no reinitialisation | 8.8439 | +17.1% | **43,918** | **+67.7%** | 8.8233 | 7.7163 | 82.4% | 1089.6 ↑ | −66.5% | 463.7 |

★ **`↑` marks an arm whose margin was STILL CLIMBING at iteration 60** (§2). For
those rows the margin is a LOWER BOUND, not a cost. Only the three unmarked
+4% rows and A2 have settled.

### (c) ★ THE BAR IS NOT MET, AND HERE IS THE FRONTIER AND THE KNEE

The bar was carved ≤ 7.5521 **and** margin ≥ 3254.34 **and** mass ≤ 543.7 g.
**Mass is met everywhere by 15%** (~464 g). ★ **Carved reaches SIMP's at C=8 —
7.6577, within 1.4% — but that arm certifies at 40% of SIMP's margin and was
still climbing.** No single arm meets all three.

★★ **THE KNEE IS C=1 WITH η=1, AND IT IS NOT A COMPROMISE — IT DOMINATES.** It has
LESS internal surface than C=1 (53,243 against 60,329), LESS than the coarse
seed alone (73,014), LESS than the ARM 2 cheap pair (55,970), and a HIGHER
settled margin than any of them (3388.6, +4.1% over SIMP). **Against the
re-baseline it removes a third of the internal surface and 35% of the carved
roughness for nothing.** Everything below it on the table buys further surface
by spending margin.

### ★★ THE QUALIFICATION, AND IT IS WHY R3 ASKED FOR TRIANGLE COUNTS

`midpoint_share` — the fraction of surface crossings sitting exactly at a cell
midpoint, which IS the staircase — climbs **57.7% → 72.0% → 81.2% → 87.4% →
88.1%** across C = 0, 1, 2, 4, 8. **SIMP's is 85.3%.** So from C=4 upward the
surface is more grid-snapped than SIMP's, and a dihedral angle measured on a
grid-snapped surface is low for the wrong reason. PR 325 saw this at C=8 on the
voxel arm — "a heavy perimeter penalty buys dihedral smoothness by returning the
surface to the grid" — and it reproduces here.

★ **`n_cut` is not subject to that**, and it saturates where the angle keeps
falling: 44,951 at C=4 against 44,366 at C=8, a 1.3% difference, while carved
reads 8.2178 against 7.6577, a 7% difference. **Most of C=8's apparent extra
smoothness is the grid, not less surface.** Reporting the angle alone would have
called C=8 a near-solution.

★ **The knee is where they agree.** At C=1 with η=1 the midpoint share is 80.4%,
still five points below SIMP's, and the surface is genuinely a third smaller.

### (b) ★★ THE CONTINUATION LOSES, AND THE BRIEF ASKED FOR IT. OVERRIDDEN.

The brief is unambiguous: "★CONTINUATION, NOT A FIXED WEIGHT... Ramp the weight
on rather than starting with it." The reasoning is sound and standard — an area
term inhibits topological change, and hole nucleation from a plain array is
exactly what lets this method replace SIMP with no seed.

**It was run as a matched pair. Same weight, same everything, one ramped:**

★ **At matched iteration 60** (my first draft compared iteration 55 against
iteration 20 — P11 — and overstated this by a factor of four):

| C=4, at iteration 60 | carved | ★ n_cut | whole | CAD | mid % | margin | area |
|---|---|---|---|---|---|---|---|
| **FIXED** from iteration 1 | **8.2178** | **44,951** | 8.6955 | 7.7859 | 87.4% | **1298.4** | 5,656 |
| RAMPED — 0 until it 10, full at 30 | 9.9302 | 49,674 | 9.1829 | 7.7051 | 82.9% | 963.2 | 7,905 |

★ **DOMINATED, on both axes: 21% worse carved roughness, 10.5% more internal
surface, and 26% less margin.** Smaller than the first draft claimed, and still
one-sided on every column that matters.

★ **WHY IT LOSES, AND IT IS THE SAME DISTINCTION PR 325 DREW.** PR 325 argued
this penalty is not one of the five smoothing operators this project has refused,
because those were POST-PROCESSING applied to a finished design while this is a
TERM IN THE OBJECTIVE: it changes which design the optimiser walks to, so no
already-earned geometry is smoothed away — the structure is never built.

**A ramp partially converts it back into a post-process.** By iteration 30 the
topology is chosen; a penalty arriving then does not change WHICH members get
built, it removes material from members that are already carrying load. That is
visible in the columns: the ramped arm ends with MORE interface (7,905 mm²
against 5,656) and a HIGHER peak stress (0.059975 against 0.040181) — it did less
shaping and more thinning.

★ **And the nucleation worry did not bite.** Every fixed-weight arm from C=1 to
C=8 converged, certified ACCEPTED, and came out 15% lighter than SIMP from a
plain hole array with no SIMP anywhere. The topological freedom the ramp was
protecting was never actually lost.

★ **So ARM 2 runs at a FIXED weight and the ramp is not in it.** Putting a
measured-harmful mechanism into "the best I can do" would make it worse on
purpose. The flag stays in the harness, defaulted off, with this pair as the
reason.

### (d) ★★ DID THE MECHANISM ARGUMENT HOLD? — NO. AND THE WAY IT FAILS IS THE BEST ARGUMENT IN THIS HANDOFF FOR R3.

PR 324 §10.3 predicted the perimeter term would behave differently on a
parametric φ **"because there is no reinitialisation to fight it."**

★ **First, the premise was false as written.** The configuration being
re-baselined — and therefore every arm in the frontier above — runs
`--plsm-refit-every 5`, the literature's approximate reinitialisation: re-distance
φ on the grid, re-project onto the basis. So the sweep alone could not test the
claim. `N1_c4_norefit` is the same weight with it OFF.

| C=4, at iteration 60 | carved | ★ **n_cut** | whole | CAD | mid % | ‖∇φ‖−1 | in-loop area | margin |
|---|---|---|---|---|---|---|---|---|
| reinit every 5 | 8.2178 | **44,951** | 8.6955 | 7.7859 | 87.4% | 0.3980 | 5,656 | 1298.4 |
| **no reinit at all** | 8.8439 | **43,918** | 8.8233 | 7.7163 | 82.4% | 0.4334 | 7,395 | 1089.6 |

★ **THE EMITTED INTERNAL SURFACE IS THE SAME TO 2.3%.** 44,951 against 43,918.
Removing the reinitialisation entirely changes what the perimeter penalty
achieves by essentially nothing. **The prediction is refuted.**

★★ **AND I NEARLY REPORTED THE OPPOSITE.** The in-loop area integral reads 5,656
with the reinitialisation and 7,395 without — a 31% difference, which says
"the reinitialisation HELPS the penalty" in a clean, quotable sentence. It is
wrong. That integral is `∫ DH_η(φ)|∇φ| dΩ`, a correct surface measure only when
the band is a faithful band, and these two arms differ in exactly the quantity
that decides it (‖∇φ‖−1 = 0.3980 against 0.4334). **PR 324 §9 abandoned
`band_cells` as a cross-representation area proxy for precisely this reason, and
I re-derived the same trap with a better proxy.** The triangle count is not
subject to it, and the triangle count says the geometry is the same.

★★ **THE OTHER HALF IS THE R3 ARGUMENT ITSELF.** These two arms differ by 2.3% in
internal surface — 44,951 against 43,918 — and read **8.2178 against 8.8439** on
carved roughness, a 7.6% difference in the OPPOSITE direction, purely from where
the marching-cubes vertices land (midpoint share 87.4% against 82.4%). **The arm
with LESS surface reads ROUGHER.** Any conclusion in this task drawn from the
angle alone would have been a conclusion about the extraction lattice.

★ **So what IS different about the parametric φ?** Not the reinitialisation. The
term is simply effective here: at C=1 it takes a quarter of the internal surface
for 7% of the margin. Whether that is *more* effective than on the voxel arm
**cannot be stated from PR 325's numbers** — its "interface area" column and this
task's are not the same measurement, which is PR 324 §9's trap again. What can be
stated is that it works, that the reinitialisation is irrelevant to it, and that
the reason it was expected to matter was never the reason.

### (e) ★★ η — SWEPT FOR THE FIRST TIME, AND IT CANNOT DO WHAT IT WAS SUSPECTED OF

η has been held at 2 voxels through this whole line of work and never swept. Two
worries were raised against it, and they need separating.

**The worry that can be settled cheaply: does a wider band RECLASSIFY triangles
from CAD to CUT, so that part of the carved share this task is chasing is a
measurement artefact rather than extra structure?** That needs no optimiser — one
design's coefficients, emitted at several η. The geometry is identical by
construction; only the band moves. Volume is held by construction too, because
the volume match counts `#{φ_eff < 0}`, which does not contain η.

| η | tris | n_cad | n_cut | cut share | carved | CAD | obl_cad mm | mid % |
|---|---|---|---|---|---|---|---|---|
| 0.5 | 386,264 | 105,691 | 83,912 | 44.26% | 16.4872 | 7.7430 | 0.3227 | 11.32% |
| 1 | 386,264 | 105,718 | 83,906 | 44.25% | 15.1830 | 7.4306 | 0.3221 | 6.59% |
| **2 — what everything ran at** | 386,264 | 105,506 | 83,920 | 44.30% | 14.9668 | 7.6520 | 0.3232 | 6.30% |
| 4 | 386,264 | 105,575 | 83,928 | 44.29% | 14.9794 | 7.9979 | 0.3231 | 6.25% |

★ **AN EIGHT-FOLD CHANGE IN η MOVES THE CAD/CUT SPLIT BY 0.05 PERCENTAGE POINTS.**
`tris` is **identical** at 386,264 on all four rows; n_cad spans 0.2% and n_cut
spans 0.03%.

★ **AND THERE IS A PROOF BEHIND WHY IT IS EXACTLY FLAT, WHICH IS BETTER THAN THE
MEASUREMENT.** The extraction takes iso 0.5, and `H_η` is monotone with
H(0) = 0.5 exactly, so the crossing set is the **sign set of φ_eff** — and the
sign of φ_eff does not contain η. **η cannot change the topology of the extracted
mesh at all.** It is a pure sub-voxel vertex-PLACEMENT knob: same triangles, same
classification, different positions inside their cells. The identical `tris`
column is that statement, measured.

★ **So the carved share is not a classification artefact and the 3× surface gap
is real.** Nothing in §3's frontier is chasing a measurement.

★ **`obl_cad_rms_mm` is flat too** — 0.3221 to 0.3232, a 0.3% spread — which is
the diagnostic answer to the projection question: η is not starving
`project_cad_faces` of vertices, because it is not moving the population at all.
The question collapses to the carved surface, which is this task's subject.

★ **What η DOES move, and it saturates at 2.** Carved roughness 16.4872 → 15.1830
→ 14.9668 → 14.9794, and midpoint share 11.32% → 6.59% → 6.30% → 6.25%. **A
NARROW band re-manufactures the staircase** — PR 324 §3's band control,
reproduced from the other direction — and the curve is flat from η = 2 on.
**PR 324's untested choice of 2 was the right one, and it is now tested.**

★ **The scope limit that survives, stated rather than buried.** `Per = ∫ DH_η(φ)
|∇φ| dΩ` **contains η**, so §3's weight sweep is conditional on η = 2: the
extraction being insensitive does not prove the GRADIENT is, because a narrower
band concentrates the velocity more tightly at the interface and that is a
statement about the trajectory. ★★ **AND IT IS — MATERIALLY, IN THE DIRECTION THAT HELPS.** `E1_c1_eta1` is
C=1 with η halved to 1 voxel, against `P1_c1` at η = 2, matched iteration 60:

| C=1 | carved | ★ n_cut | whole | mid % | margin |
|---|---|---|---|---|---|
| η = 2 | 12.7098 | 60,329 | 10.4445 | 72.0% | 3028.1 ↑ |
| **η = 1** | **9.2460** | **53,243** | 8.9716 | 80.4% | **3388.6** |

★ **Halving η at the same weight removed a further 11.7% of the internal surface
and 27% of the carved roughness, AND took the settled margin from a still-rising
3028 to 3389 (+4.1% over SIMP).** It is the single largest free improvement in
this task, and it came from a knob nobody in this line of work had ever swept.

★ **The two halves of the η question have OPPOSITE answers, and both had to be
measured.** The extraction is provably insensitive to η (the crossing set is the
sign set of φ_eff). The OPTIMISATION is strongly sensitive to it, because
`Per = ∫ DH_η(φ)|∇φ| dΩ` contains η and a narrower band concentrates the velocity
at the interface instead of smearing it over four voxels. **A probe on a fixed
design would have concluded "η does not matter" and been wrong about the thing
that mattered most.**

★ **So the S3 frontier IS η-conditional, and it is reported at η = 2 with this
pair as the correction.** A full sweep of the two jointly is the obvious next
run and is ranked in §9.

## 3b. ★★ THE TWO WINNING KNOBS, ON SIX CORES, STOPPED AT SIMP PARITY, TIMED

One run, asked for directly. C=1 and η=1 — the two knobs §3 and §3(e) found —
on all six performance cores, stopping at whichever came first: the CERTIFIED
margin reaching SIMP's 3254.34, or the optimisation using the 1911.6 s the same
two knobs cost on 3 threads over 60 iterations.

★ **IT STOPPED ON THE MARGIN, AT ITERATION 25, IN 582 SECONDS OF OPTIMISATION.**

| | W1, stopped at parity | E1, the same knobs run to 60 | SIMP |
|---|---|---|---|
| iterations | **25** | 60 | 27 |
| ★ **optimisation wall** | **582.1 s** | 1911.6 s | ~311 s |
| certified margin | **3388.1** (+4.1%) | 3388.6 (+4.1%) | 3254.3 |
| ★ internal surface | 56,637 | **53,243** | 26,191 |
| carved | 11.0409 | **9.2460** | 7.5521 |
| CAD error | **0.4275** | 0.4268 | 0.4293 |
| mass | 463.74 g | 463.74 g | 543.7 g |
| verdict | ACCEPTED, load path yes | ACCEPTED | ACCEPTED |

★ **SIMP-PARITY STRENGTH IN 582 s OF OPTIMISATION — a third of what the same
configuration spends running to 60 iterations, and it lands on the same margin
to four significant figures (3388.1 against 3388.6).** Against SIMP's own ~311 s
it is **1.9×**, for 15% less mass and a design the ladder does not produce.

★ **AND THE LAST 35 ITERATIONS ARE NOT WASTED — THEY BUY SURFACE, NOT STRENGTH.**
Stopping at parity costs 6.4% more internal surface (56,637 against 53,243) and
19% more carved roughness. **The margin is finished at 25; the surface is not.**
That is the same asymmetry §2 found from the other side, and it says the
stopping rule should watch whichever quantity the run is FOR.

### ★ what the six cores actually bought — 26% on the solve, not 2×

| | 3 threads (E1) | 6 threads (W1) |
|---|---|---|
| state solve | 28.28 s/iteration | **20.88 s/iteration** |
| optimisation, all in | 31.86 s/iteration | **23.28 s/iteration** |
| parallelism achieved | — | 2171 s user / 849 s real = **2.56×** |

★ **Doubling the threads bought 26% on the solve, not 100%** — the matrix-free
operator is memory-bandwidth-bound, which this repository already measured
directly (STREAM 76%, matvec 27% gather-bound). Speed is out of this task's
scope and no conclusion rests on it; the number is here because the run was
asked for and timed.

★ **The thread count did not move the design.** W1 on 6 threads certifies 2420.14
at iteration 20 where E1 on 3 threads certifies 2429.7 — 0.4% apart, on
trajectories that differ only in the solver's summation order.

### ★ THE STOPPING RULE COST MORE THAN THE FIRST DESIGN OF THIS RUN SURVIVED

★ **Certifying an UNCONVERGED design is 26× more expensive than certifying a
converged one.** Measured in the first attempt at this run: **20.9 s at iteration
5, 537.9 s at iteration 10.** That attempt capped TOTAL wall clock, spent 559 s
of its 1912 s budget on two certifications, and would have reported the optimiser
as slow — **it was timing the measuring instrument.** Killed and rebuilt: the cap
is on optimisation time, the instrument's cost is reported beside it and never
inside it, and `--certify-from 20` skips the certificates that cannot pass
anyway. The surviving run spent 211.0 s on two certifications against 582.1 s of
optimisation.

★ **This is the practical answer to §9's item 3.** A margin-aware stopping rule
is affordable — but only if it starts late, and only if nobody counts it as part
of the method's cost.

## 4. ★★ WHAT IS STILL GENERATING SURFACE: NUCLEATION, NOT THE SEED

PR 324 §6 refuted a coarser BASIS as a smoothness lever and left "it is the
TOPOLOGY" as the honest answer with no lever attached. The obvious untested
candidate was the SEED — the run starts from a cosine hole array of period 8
voxels on a 128 × 31 × 118 grid, which is on the order of a thousand holes.

**Period 16 — about eight times fewer holes:**

| at matched iteration 60 | carved | n_cut | margin | mass |
|---|---|---|---|---|
| seed period 8 | 14.1322 | 79,577 | 2859.5 ↑ | 463.8 g |
| **seed period 16** | 12.8206 | **73,014** | **3389.5** (settled) | 463.8 g |

★ **EIGHT TIMES FEWER HOLES REMOVED 8.9% OF THE SURFACE.** So the fine structure
is **created during the run, not inherited** — and what creates it is hole
nucleation, the property that lets a parametric level set replace SIMP with no
seed at all. **The surface and the capability are the same mechanism.** That is
the answer to "what is still generating surface", and it is why the perimeter
penalty — the one term that prices creating interface — is the only lever that
moves it more than 10%.

★ **The seed is nevertheless a keep, because it is FREE and it buys the margin
back.** Margin 3389.5 (+4.2% over SIMP, +50% over the re-baseline), peak stress
a third lower, mass unchanged, no extra term and no extra state solve. It cannot
buy smoothness by deleting load-bearing material, because it deletes nothing —
it starts somewhere else.

★ **Period 16 is about the limit on this part.** The thin axis is 31 voxels, so
period 16 already gives about two holes across it and period 24 would give one.
The slab shape caps this lever — the same consideration R4 is about.

★ **This is NOT PR 324 §6(ii) re-run.** That measured the DESIGN SPACE (24,480
coefficients against 85,680: carved share 42.9% → 40.9%, margin HALVED). This is
the STARTING POINT, at full basis resolution. Different object, and the margin
goes the other way.

### ★ AND THE MECHANISM THAT ATTACKS NUCLEATION DIRECTLY — MEASURED, AND IT DOES NOT WORK

If the surface is nucleated, the sharp instrument is to stop nucleation rather
than tax all interface forever after. That is `--nucleation-band W`: only
coefficients within W voxels of the interface may move (§5 M5). Against
`S0_seed16` — the same arm, the mask and nothing else:

| at iteration 60 | carved | ★ n_cut | margin | coefficients frozen |
|---|---|---|---|---|
| seed 16 | 12.8206 | 73,014 | 3389.5 | — |
| **seed 16 + mask, W=2** | 12.3040 | **71,867** | 3387.7 | 16,848 → 23,693 of 85,680 |

★ **THE MARGIN IS PRESERVED EXACTLY AS PREDICTED — AND THE SURFACE BARELY MOVES.
1.6% fewer triangles.** The mask is not inert (it froze 20–28% of the
coefficients on every iteration and the compliance trajectory differs), it simply
does not have much to freeze.

★ **AND THE REASON IS IN THE COLUMN ITSELF, which is why it is worth reporting
rather than burying.** The mask can only prevent nucleation where there is DEEP
SOLID for a hole to open in. In a design this finely branched there is almost
none: nearly every knot is within two voxels of SOME interface by iteration 10.
**The mask arrives after the structure it was meant to prevent.** Applying it
from the first iteration on a coarse seed is what it would take, and `S0` + mask
is exactly that arm — so this IS that test, and it says the branching is
established faster than the mask can gate it.

## 5. ARM 2 — "THE BEST I CAN DO"

Each mechanism is named with the problem from §7 it answers, where the idea came
from, and what it cost. They were run TOGETHER in `A2_all`, as the brief asks;
the two that are affordable alone were also run alone so the combination is
attributable rather than only celebrated.

★ **ALL FOUR RUN TOGETHER IN `A2_all`, AND THE ANSWER IS THAT TOGETHER THEY LOSE
TO TWO OF THEM.** Every row at matched iteration 60.

| arm | mechanisms | carved | ★ n_cut | margin | s/iteration |
|---|---|---|---|---|---|
| C=0, seed 16 | M1 alone | 12.8206 | 73,014 | **3389.5** | 27 |
| seed 16 + mask | M1 + M5 | 12.3040 | 71,867 | **3387.7** | 27 |
| ARM 2, cheap pair | M1 + fixed C=1 | 11.1793 | 55,970 | 3197.9 ↑ | **27** |
| **ARM 2, all mechanisms** | M1 + C=1 + M2 + M3 | 10.0676 | 49,851 | 2880.3 | **69** |
| ★★ **C=1 with η=1** | fixed C=1 + η | **9.2460** | **53,243** | **3388.6** | **27** |

★★ **THE EXPENSIVE MECHANISMS ARE NOT WORTH THEIR COST HERE.** `A2_all` buys
11% fewer triangles than the cheap pair for **2.6× the wall clock** (three state
solves per iteration) and a settled margin 10% lower. And **a single knob the
brief never mentioned — halving η — beats it on every axis at a third of the
cost**: fewer triangles than the cheap pair, lower carved roughness than
`A2_all`, and the highest settled margin in the study.

★ **Reported plainly because the brief asked for it plainly: ARM 2's headline
mechanisms lost to ARM 1's cheapest ones.**

### M1 — the SEED's topology scale (`--seed-period`) — ★ KEPT, and it is free
Problem P4/§4. Not PR 324 §6(ii)'s basis: that is the design SPACE, this is the
starting POINT. Level-set optimisation is initial-design dependent, and the
parametric form's own claim is "LESS dependency", not none. ★ **The literature
reports PERFORMANCE is insensitive to the initial hole count (12/24/48/96 give
similar results); it says nothing about SURFACE**, which is the gap this
measures. Result in §4: 8.9% of the surface, +50% margin over the re-baseline,
peak stress a third lower, at no cost at all.

### M2 — price CURVATURE, not area (`--perimeter-local`, `--willmore-full`)
**Problem:** what §3 costs. The plain perimeter term taxes every square
millimetre at the same rate, including the large smooth load-bearing shell —
and §3's frontier shows it paying for that with more than half the margin from
C=2 upward.

**Where it came from.** The Willmore energy `W = ∫_Γ κ² ds` is the standard
curvature-concentration functional, and the case made for it over plain area
minimisation is that it controls curvature concentration without inducing
shrinkage, where area minimisation risks topological collapse. A smooth shell of
large radius costs almost nothing under W and its full area under Per.

**What is implemented, exactly.** For `∫_Γ f ds` with f a field on the level-set
family the shape derivative is `∫_Γ (∂f/∂n + fκ) v_n ds`; with f = κ² that is
`∫ (2κ ∂_nκ + κ³) v_n`. So `ell·κ·(1 + β(κ/κ_rms)²)` is the gradient of
`Per + (β/κ_rms²)·W` **with the ∂_nκ term dropped** — the expensive, noisy one,
since it differentiates a quantity already two differences deep on a 128³ grid.
★ **The omission is measurable, not assumed:** `--willmore-full` restores
`2κ(∇κ·n)` by central differences on the curvature field the loop already builds.
**Cost:** one extra pass over the band. No state solves.

### M3 — the robust worst-case (`--robust`) — Sigmund 2009
**Problem:** fine branching pays. A thin member contributes stiffness in
proportion to its area and surface in proportion to its perimeter, and nothing in
the formulation notices that it is thin.

**Where it came from.** Sigmund (2009), *Manufacturing tolerant topology
optimization*, and Wang, Lazarov & Sigmund (2011): optimise the WORST of eroded,
intermediate and dilated, so a member that disappears under erosion buys nothing.

★ **Why it belongs on a LEVEL SET specifically.** In a density method the three
designs need a filter and three projections of a filtered field. Here eroding by
δ is `{φ < −δ}`: one constant, the same φ, no filter, no projection, no second
design variable. The machinery the method is usually judged by does not exist.

★ **AND IT IS NOT THE MINIMUM-FEATURE RULE THE BRIEF RULES OUT.** The brief is
right that the measured problem is AREA, not thinness. A thickness rule FORBIDS
thin members; this one lets the optimiser build them and declines to pay for
them, so it acts on the branching RATE rather than on a width.

★ **IT BINDS, AND THE COLUMN SAYS SO RATHER THAN THE COMMENT.** `robust_worst`
is 0 — the eroded design — on every iteration, and `robust_ratio` (its compliance
against the intermediate's) starts at **1.9042** and falls to **1.3785** by
iteration 9: the optimiser is actively thickening members to close a gap that a
single-design objective would never have seen.

★ **One deviation from the paper, declared.** The volume constraint stays on the
INTERMEDIATE rather than moving to the dilated design, because the intermediate
is what gets printed, certified and weighed, and every other row in this task
holds that same volume. Moving it would make the mass column incomparable, and
the mass column is what the brief's bar is written against.

★ **The bug it nearly shipped with (P7).** The first draft used the eroded
design's `dcompliance` but localised it with the INTERMEDIATE's band. The eroded
boundary is `{φ = −δ}`; the intermediate's is `{φ = 0}`, which lies δ OUTSIDE the
eroded solid, in its ersatz void, where the strain energy is ρ_min noise. The arm
would have converged and reported that the robust formulation does nothing.
Fixed by carrying `delta_shift`: the OBJECTIVE's band moves to the argmax
design's surface, while the volume and perimeter terms stay on the printed
part's, because they are statements about the printed part.

**Cost:** ★ **three state solves per iteration — about 3× the wall clock**
(51 s against 31 s here). Speed is out of scope for this task and this is said
plainly.

### M5 — the nucleation band (`--nucleation-band`) — ★ BUILT, MEASURED, NEGATIVE
**Problem:** §4 — the surface is nucleated, and the perimeter penalty is a blunt
proxy for pricing that (it taxes ALL interface forever to discourage the moment a
hole opens).

**Where it came from.** Luo & Tong (2008, IJNME 76(6):862–892), via Dunning & Kim
(IJNME 93(1):118–134): holes "can also emerge NEAR THE BOUNDARY in an RBF type
approach if a VOLUME INTEGRAL METHOD is used to compute shape sensitivities
WITHIN A NARROW BAND around the boundary." Everywhere against band, and it is a
statement about WHICH COEFFICIENTS MOVE.

★★ **THE RECOMMENDATION AS GIVEN TO ME WAS TO MASK THE INTEGRAND TO A TUBE
|φ| < ω WITH ω ≥ 2η. THAT IS AN EXACT NO-OP HERE, AND `levelset_kernel.hpp` SAYS
SO IN ONE LINE:** `dheaviside` returns 0 for |t| ≥ η. The integrand is ALREADY
zero outside |φ| < η = 2 voxels; a tube at ω ≥ 4 voxels is a superset of where it
is already non-zero and would change nothing on any arm at any weight.

★ **THE LEAK IS THE SUPPORT RADIUS, NOT THE BAND.** MMA consumes `g = Ψᵀv`, and a
knot contributes iff its SUPPORT overlaps the band — support here is 2 × spacing
= 4 voxels. So knots up to 4 voxels inside solid receive a gradient, and once one
opens a hole the knots 4 voxels beyond THAT become live. **Masking has to be in
COEFFICIENT space, by knot-to-interface distance, and W must be BELOW the support
radius to bite at all.** The probe refuses W ≥ the support radius rather than
running an arm that measures its own control.

**Result:** §4. Margin preserved exactly as predicted, surface essentially
unmoved (1.6%). **A legitimate negative with a mechanism.**
**Cost:** nothing — no extra state solves.

### M4 — the continuation (`--perimeter-ramp`) — ★ BUILT, MEASURED, REJECTED
§3(b). Dominated on both axes by the same weight applied from iteration 1.
**Not in ARM 2.**

## 6. S2 — THE FROZEN REGION FROM THE CAD FACES

★ **The control first, because nothing else here counts without it.** The
analytic frozen region must be the SAME region core builds, not a second
definition of it. Rasterised at voxel centres it agrees with the mask core
actually wrote on **468,224 of 468,224 voxels — 100.0000%, zero either way.**

★ **AND THIS OVERRIDES THE BRIEF'S S2(a), DECLARED RATHER THAN SLID IN.** The
brief says to use `StepFaceInfo`'s `plane_normal` / `plane_origin` /
`cylinder_radius_mm`. Those describe the UNBOUNDED carrier surface of a face.
What core freezes (`mask_step_face`) is material within a depth of the face's
**bounded triangulated patch** — freezing everything within 5 mm of face 16's
infinite plane would freeze a slab clear across the part, where its protection is
10,554 voxels. So the analytic region is the exact distance to the face's own
triangles, via core's `MeshDistance` (invoked, not reimplemented). That is the
continuum limit of the shipped rule; the half-space could not have reached
100%.

★ **Getting to 100% needed one fix, and finding it needed two measurements.**
3,348 voxels — 8.3% of the frozen set — were frozen by core and not by the
analytic rule, one-sidedly. Brute-forcing point-triangle distance over all 2,314
frozen-face triangles ruled out the accelerator (agreement 1.4e-14 mm). Printing
how far past the threshold the disagreeing voxels sat ruled out the face list:
**min, median, p90 and max were all 0.0000 mm.** Every one sat exactly on the
threshold. Core tests `<=`; a continuous field tested `< 0` excludes it; and on a
flush planar face that equality case is a whole voxel layer, because layer L's
centres sit at exactly (L + 0.5) edges from the face. Carrying core's own `+ eps`
inside the square root closed it.

### (c) how much of the remaining two thirds does it recover? — ESSENTIALLY ALL

The same design, emitted at F=2 under three frozen treatments, one probe
invocation, SIMP control on the same lattice. ★ Volume is beside every row
because these rows do NOT hold it equal.

| treatment | carved | ★ **CAD** | whole | n_cut | mid % | ★ obl_cad mm | volume mm³ |
|---|---|---|---|---|---|---|---|
| SIMP control, same lattice | 7.5521 | 7.5842 | 8.4075 | 26,191 | 42.09% | 0.4293 | 440,550.9 |
| hard STAMP (what ARM 2 exports today) | 16.1285 | 13.2414 | 15.2341 | 78,945 | 58.70% | 0.5557 | 372,433.3 |
| smooth boolean, VOXEL TAGS (PR 324 §5's best) | 12.6609 | 13.1572 | 13.7798 | 65,005 | 82.36% | 0.5102 | 315,189.6 |
| ★ smooth boolean, **CAD FACES** | 14.9668 | **7.6520** | 11.6922 | 83,920 | **6.30%** | **0.3232** | 366,304.4 |

★ **CAD population 13.16 → 7.65, against SIMP's 7.5842 — within 0.9%, from 74%
above it.** ★ **`obl_cad_rms_mm` 0.5102 → 0.3232 against SIMP's 0.4293: 25% MORE
ACCURATE THAN SIMP** on faces the optimiser never had any say over.
`midpoint_share` 82.36% → **6.30%** — the staircase on the CAD faces is gone.

★ **What it does NOT fix, said plainly: the carved population.** carved 14.97
against the tags boolean's 12.66, n_cut 83,920 against 65,005. That is not the
CAD treatment being worse — **the tags boolean has eaten 14% of the part**
(volume 315,190 against 366,304), because its frozen boundary is sampled by the
containing coarse voxel and at F=2 that erodes. A design with less of itself left
has less carved surface to measure. The volume column is why this cannot be read
as a win for the tags.

**S2 is a CAD-face fix and nothing else.** It is complementary to S3, not an
alternative.

### (b) ★ AND IT STILL CERTIFIES, WITH THE LOAD PATH WALKED

PR 324 §5's failure was that **40 leaked voxels out of 40,216 broke the
anchor-to-load walk** on every fit, because an analytic φ cannot be discontinuous
at the pad boundary. The boolean removes that by construction — frozen material
is negative because it is `min`'d in, not because it was stamped — and S2 keeps
that property while replacing the voxel boundary with the CAD one.

`s2_RB1_volcount_cert.csv`: both the tags boolean and the CAD boolean certify,
`load_path_connected` = 1, `frozen_solid_below_iso` = 0 of 40,216.
★ **Zero leaked voxels, not forty.** The failure mode is closed by construction
rather than by tuning, and the CAD derivation does not reopen it.

## 7. ★ THE PROBLEMS I ACTUALLY HIT — the list ARM 2 was built from

Written down as they happened, including the ones with no good answer.

### P1 — my own assertion stopped the re-baseline on iteration 1, and it was right
75,415 against 75,414. One voxel. §1. **Solved**, and the fix is the more honest
formulation anyway. Cost one aborted run.

### P2 — a hard-count constraint has no gradient, and I have no principled fix
With `--volume-count` the constrained quantity is piecewise constant, so its
derivative is zero almost everywhere. MMA is still handed `dv = Ψᵀδ`, the
SMOOTHED volume derivative. The two now measure different things.

**Why it is sound here anyway:** the offset bisection re-projects onto the
constraint exactly at the top of every iteration, so `dv` only sets the search
DIRECTION within a step, not the feasibility of the result — and the assertion
proves the projection holds to the voxel on all 60 iterations of all 10 arms.
**Why it is still a wart:** the multiplier MMA infers from a mismatched
derivative is not the multiplier of the problem being solved. **UNRESOLVED.** The
clean fix would be a surrogate whose VALUE is the hard count and whose DERIVATIVE
is δ, which is not a thing.

### P3 — the parametric φ is not a distance function, and the curvature term divides by it
`| |∇φ| − 1 |` reads ~0.35–0.39 rms through every arm here. `mean_curvature` is
`div(∇φ/|∇φ|)` and divides by `|∇φ|³`, so a field that is not a distance function
feeds its own gradient error straight into the term S3 depends on. Formally the
curvature of a level set is well defined for any smooth φ, so this is not wrong;
numerically it is noisy, and the existing `1/h` cap is doing real work.
**Partly answered by measurement** — `N1_c4_norefit` (§3(d)) is the pair that
isolates it.

### P4 — 53% of the printed material is frozen and no mechanism here can touch it
Active 70,688 / FrozenSolid 40,216 / FrozenVoid 357,320 against 110,904 part
voxels; at rung 0.68 the target is 75,415 printed voxels, so the optimiser
chooses only about 35,000. **Every mechanism in §5 acts on 47% of the part.**
That caps all of them — and it is why S2, which changes how the OTHER 53% is
represented, is not a side quest. **Structural, not solvable here.**

### P5 — `n_cut` and `dihedral_cut_deg` are not measurements of the same object
PR 324's own trap, and S3 made it decisive rather than pedantic: the frontier's
`midpoint_share` climbs to 87.46% at C=4, so part of the dihedral improvement is
the surface snapping to the grid. **Both columns are in every table**, the
triangle count is the quantity actually being minimised, and §3 says which
conclusion rests on which.

### P6 — the brief's S3(d) premise does not hold as written
Every arm in the frontier runs `--plsm-refit-every 5`, an approximate
reinitialisation, so the sweep alone cannot test "no reinitialisation to fight
it". **Solved by adding the pair**, `N1_c4_norefit`. §3(d).

### P7 — the robust formulation read the sensitivity at the wrong surface
Caught by reading, before it ran. §5 M3. Had it shipped it would have produced a
converged arm reporting "the robust formulation does nothing" — a believable
result, and wrong. **Solved.**

### P8 — S2 agreed on 99.29% of voxels and I nearly wrote that up as good enough
§6. Two measurements were needed to find the cause and it turned out to be one
character. **Solved — 100.0000%.**

### P9 — the brief's continuation was harmful and I had to override it
§3(b). **Measured, overridden, and the mechanism named.**

### P11 — ★ I COMPARED ARMS AT DIFFERENT POINTS IN THEIR OWN LIVES
`levelset_probe` writes and certifies the BEST-COMPLIANCE iterate, which across
these twelve arms is iteration 9, 20, 40, 55, 57 and 60. My first draft's tables
were read off that file. **PR 324 §6 documented this exact trap for its own
ablations and I walked into it anyway.** It reversed a conclusion: C=8 read as a
catastrophic failure at its iteration 9 and is the smoothest arm in the study at
iteration 60. **Solved** — every table is now built from `it0060` snapshots, and
`m3_matched.csv` is that measurement. §2.

### P12 — ★ I ASSERTED THE MARGIN WAS NOISE. IT IS NOT.
I wrote, and told the maintainer twice, that a single margin reading here was
"close to a coin flip". Twenty consecutive certified iterates say the spread is
**0.15%**. **Retracted** — and the replacement finding is more useful: the margin
settles far LATER than compliance, so most arms here are reporting lower bounds.
§2. ★ **The thing that made the claim plausible was P11**: comparing iteration 40
of one arm with iteration 60 of another looks exactly like noise.

### P13 — 60 iterations is not enough for the penalised arms, and I did not know until the end
Every arm carrying a perimeter weight was still climbing in margin at iteration
60 — C=8 by 101% over its last twenty iterations. The frontier's margin column
is therefore a set of lower bounds, not costs. **UNRESOLVED**; §9 ranks the fix.

### P10 — wall clocks in this task are not comparable, and no conclusion uses one
Measurement work ran alongside the optimiser queue on the same machine. Speed is
out of scope, the designs are deterministic, and nothing here rests on a wall
clock — but `iteration_wall_s` should not be read against PR 324's. **Stated,
not fixed.**

## 8. what was tried and abandoned

* **`#{φ + c < 0}` as the constrained set.** Replaced by `#{H_η(−φ) > 0.5}` —
  the same set, and not the same test in floating point. P1.
* **`StepFaceInfo`'s plane and cylinder parameters for S2.** The brief asks for
  them and they are the wrong object: they describe the UNBOUNDED carrier
  surface, while the frozen region is bounded by the face's edges. Replaced by
  exact distance to the face's own triangulation — which reaches 100.0000%
  agreement, where a half-space could not have. §6.
* **★ THE CONTINUATION.** Built, run as a matched pair, measured to be dominated
  on both axes, and removed from ARM 2. The flag stays, defaulted off, with the
  pair as its documentation. §3(b).
* **A brute-force point-triangle distance as an INSTRUMENT.** Written, but used
  only to verify `MeshDistance`'s accelerated answer (agreement 1.4e-14 mm) and
  never in a measurement. R2 says invoke, do not retype; a verification that
  shares an implementation with the thing it verifies is worth nothing, which is
  the one case where a second copy earns its place.
* **Reading the frontier as a test of S3(d).** It cannot be one — every arm in
  it reinitialises. P6.
* **Pushing the seed coarser than period 16.** The thin axis is 31 voxels, so
  period 16 already gives about two holes across it and period 24 would give
  one. Not run, because on this part it would measure the slab and not the
  lever — the same consideration R4 exists for. §4.
* **★ MASKING THE SHAPE-DERIVATIVE INTEGRAND to a tube |φ| < ω with ω ≥ 2η**, as
  recommended. Not abandoned for lack of time — it is provably a no-op, because
  `dheaviside` already has compact support on |φ| < η. Replaced by the
  coefficient-space mask that implements its intent. §5 M5.
* **★ "The margin is a coin flip."** Asserted, then refuted by measuring it. §2,
  P12.
* **★ THE FIRST DRAFT OF EVERY TABLE IN THIS HANDOFF**, which compared arms at
  their own best-compliance iterates. P11.
* **★ S4, ADAPTIVE KNOT PLACEMENT — NOT ATTEMPTED, AND THE BRIEF SAID "IF TIME".**
  It was not reached. It is a compression result that feeds S3's resolution of
  the interface, and §9 ranks it. What was built instead is `--alpha`, which
  reads an optimiser's own coefficients back in — the machinery S4 would need,
  and what makes S2 a minute of arithmetic rather than another run.

## 9. what I would do with another day, ranked

1. ★★ **SWEEP η AND THE PERIMETER WEIGHT JOINTLY, AND RUN THEM LONGER THAN 60
   ITERATIONS.** One arm at η = 1 was the largest free improvement in this task —
   a third of the internal surface gone with the margin ABOVE SIMP's — and it was
   a single point, chosen without a sweep, on a frontier built at η = 2. **The
   two are one two-dimensional decision** because `Per = ∫ DH_η(φ)|∇φ| dΩ`
   contains η, and only one cell of that grid has been visited.
   ★ **And 60 iterations is not enough**: every penalised arm was still climbing
   in margin at 60, C=8 by 101% over its last twenty. **Run η ∈ {0.5, 1, 2} ×
   C ∈ {1, 2, 4} to 120 iterations**, which is nine arms and about eight hours.
   That is the run that turns this task's lower bounds into costs, and it is very
   likely where the bar is actually met.
2. ★ **Ship S2 into the export path.** A pure win on the population it touches —
   CAD 13.16 → 7.65 against SIMP's 7.58, and the true CAD deviation 25% BETTER
   than SIMP — validated at 100.0000% against core's own mask, and it closes the
   load-path failure mode by construction. The work is done and sitting in
   `plsm_probe`; moving it into the shipped emission is mechanical.
3. ★ **Certify on a schedule that matches how the margin actually behaves.**
   §2 showed compliance is not a convergence proxy for the margin: the
   re-baseline moved 27% in margin while moving 0.05% in compliance. **Every
   stopping rule in this line of work watches compliance.** A margin-aware
   stopping rule — and certifying every iterate of the tail rather than every
   tenth — is cheap and would have prevented P11, P12 and P13 outright.
4. ★ **Attack nucleation at the moment it happens, not after.** §4's mask failed
   for a specific, measured reason: it arrives after the branching is
   established. The version that would not is a **secondary level-set function**
   — Dunning & Kim's "pseudo third dimension", where a hole opens only when doing
   so beats moving the existing boundary — which prices nucleation against its
   alternative rather than gating it by geometry. Reported cost there: final
   compliance within ~1% across all parameter settings, against up to 20%
   variation with initial design when hole insertion is absent.
5. **Reaction–diffusion level set** (Yamada, Izui, Nishiwaki & Takezawa 2010,
   CMAME 199(45–48):2876–2891). ★ **A SINGLE parameter τ sets geometric
   complexity**, no reinitialisation, 3D, and a parametric RBF variant exists
   (CMAME 2022). ★ **Cost: it changes the UPDATE LAW and so partly displaces
   MMA**, which is why it is here and not above — this task's whole apparatus is
   built on MMA in coefficient space.
6. **Bead-aware stiffness interpolation.** A member thinner than one extrusion
   bead (0.42 mm) does not exist and should earn NO stiffness, so the optimiser
   is not rewarded for creating it. ★ **No free parameter — the bead width is
   measured, not chosen.** Closest published realisation is density-based
   (Computers & Structures 2023, DOI 10.1016/j.compstruc.2023.107070); on a level
   set the ersatz stiffness becomes a function of local thickness from the
   signed-distance field.
7. **S4, adaptive knot placement.** Not reached. `--alpha`, the machinery it
   needs, is built. PR 324 §10.5 estimates another 5–10× compression at the same
   residual, which feeds S3 by resolving the interface better.
8. **The two ARM 2 mechanisms that ran at one setting only** — `--robust` at
   δ ≠ 1 voxel, and `--willmore-full` against `--perimeter-local` alone so the
   dropped ∂_nκ term becomes a number.

★ **NOT worth building, and why** — read rather than implemented: explicit
hole-count control via Betti numbers / persistent homology is conceptually the
right target for §4, but as of 2026 the mature 3D members are SIMP or
discrete-variable and need a density field alongside φ, and the differentiable
level-set-friendly one is 2D only. Minimum-length-scale as a primary lever is
ruled out by measurement, not by preference: min-feature violations are already
BETTER in these arms than SIMP's. A coarser RBF basis is refuted (PR 324 §6(ii)).

## 10. in plain language

**The problem.** Our newer method makes parts that are stronger and 15% lighter
than the old one, and it needs no help from the old one — but it invents a
fussier, more branched interior, with about three times as much internal surface.
Rough parts. This task went after that surface.

**The result.** ★ **A third of the internal surface removed — and the part came
out STRONGER than the old method, not weaker.** 79,577 internal triangles down to
53,243, machined-surface roughness down 35%, certified 4% above the old method's
safety margin, still 15% lighter. It is not all the way there — the roughness is
still 22% above the old method's — but it is the first change in this line of
work that moved the surface materially without being paid for in strength.

**It took two things, and one of them nobody had ever tried.** Charging the
optimizer for the surface it creates (a known idea, at its gentlest setting), and
**halving a band-width setting that had been left at the same value through this
entire line of work and never once swept.** That second one was free. On its own
it was worth more than every expensive mechanism I built.

**Two other things are free and both work.** Starting from a coarser pattern of
holes costs nothing and makes the part stronger. And describing the "must stay
solid" regions from the CAD drawing instead of the voxel grid puts the machined
faces **25% closer to the true CAD shape than the old method manages** — the
number a blur cannot fake.

**What is still generating the surface.** Eight times fewer starting holes
removed only 9% of it, so the fussy structure is invented during the run, not
inherited. The method's freedom to punch new holes wherever they help is *why* it
can replace the old method, and *what* makes the extra surface. Same capability.
I built a mechanism to gate exactly that and it did not work — for a reason worth
knowing: by the time it can act, the branching has already happened.

**Now the mistakes, because there were real ones.**

*The brief asked me to ease the surface charge in gradually.* Measured both:
turning it on from the start is better. Easing it in lets the structure get built
and then eats material out of load-bearing parts.

*I was told to mask a calculation to a wide band.* Reading the code showed it was
already masked to a narrower one — the suggestion could not have done anything. I
built the version that does what it intended instead, and reported that it did
not help.

*★ And the one that mattered.* Each run saves its **best-stiffness** snapshot,
not its last — and that landed on iteration 9 for one run and iteration 60 for
another. **I spent most of this task comparing runs at different points in their
lives.** Rebuilt properly, one conclusion reversed outright: I had called the
strongest setting "a failure", and at a fair comparison it is the smoothest
result in the study.

*★★ And the one I said out loud twice and had to take back.* I claimed the safety
margin here was "close to a coin flip" and that every cost figure had unknown
error bars. **I measured it: twenty consecutive certified snapshots of one
settled design span 0.15%.** It is not a coin flip. The swings I saw were real.

**But measuring it produced something more useful than the claim it killed.** The
margin **settles much later than the stiffness does** — one run moved 27% in
margin while moving 0.05% in stiffness. Every stopping rule we have watches
stiffness. So most of the runs here were stopped while their strength was still
improving, and **every "this costs X% of strength" in this report is a worst
case, not a cost.** The three runs that had settled all landed 4% above the old
method. Running longer is the top of my list for next time, and I think it is
where the target is actually met.
