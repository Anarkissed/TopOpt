# TO rebuild: the plan

Status 2026-11-21: PROPOSAL for the reviewer and the maintainer. Nothing here is built. Ids like V-01 point at the ledger (`00-review.md`); "3a candidate 1" points at the research (`01-research.md`); rule numbers at `03-rules.md`; test letters at `04-tests.md`.

Picture: `plan-pipeline.svg` (today's path against the rebuilt path, with the stage that changes each step).

## 1. What is wrong today, in one paragraph

The optimiser already works on a smooth function, but four things around it are crude. (1) The part comes in as yes/no voxels, so every drawn face is a staircase before anything is optimised, and a load or anchor lands on whatever voxels the grid happens to catch (V-01, V-02, P-04). (2) Strength is judged by the single hottest voxel, a number that changes with the resolution he picks (A-02, section F). (3) The optimiser only knows "be stiff at this weight", at four fixed weights; it knows nothing of strength, wall thickness, overhang or smoothness (P-07, M-05). (4) The print file is rebuilt from voxel fill and then smoothed, which throws the smooth function away (X-01, X-04). Around that sit about 30,000 lines the app never runs (S-08, T-01) and two files of 21,000 and 3,400 lines that hold everything (P-12, P-13).

## 2. The rebuilt path

| step | today | rebuilt |
|---|---|---|
| Part in | yes/no voxels from triangles at 0.1 mm | true distance to the drawn part; drawn faces stay exact |
| Loads, anchors, protection | voxels whose centre is near the face; depths in whole voxels | the drawn face's own area; depths in mm as typed |
| Design | cut-off Gaussian bumps, knot spacing fixed for one part | crease-free basis, spacing from the print profile, slope held in a band |
| What is optimised | stiffness at 4 fixed weights | printed weight, under a strength limit for every scenario, with wall, hole, overhang, drain and smoothness rules |
| Strength number | hottest single voxel x infill factor | stress over a fixed physical size; same answer at any resolution; one number for loop, certificate and file check |
| Surface out | marching cubes on voxel fill, resample, CAD snap, curvature flow, thin-spot patches | the zero surface of the optimiser's own function, joined exactly to the drawn faces |
| Versions | streamed when solved, file checked at the end | each file checked before it is shown; one accept rule |
| Lattice | old engine, after the fact | THEN and TOGETHER, both on the new engine's laws |

## 3. Stages

Each stage leaves the app working, is measured on all reference parts with the Stage 0 table, is reviewed, and is released by #362 before the next one builds on it. A stage's new behaviour sits behind ONE temporary switch until its gate passes; the switch and the old path are deleted in the same stage's close-out (rule 21).

| stage | what he gets | ledger items | size | depends on | who else |
|---|---|---|---|---|---|
| 0. Measure and make room | the "today" table and pictures for every reference part; tests that can see smoothness and strength errors; TO code moved out of `run_job.cpp` into its own files with identical output | Phase 2 remainder, T-02, C-05, P-13 (moves only), F-02 | M | - | #362 and LatticeReview: a short freeze on the moved line ranges |
| 1. True loads and honest results | margins stop jumping with grid alignment; protection depth is the mm he typed; a failed part says why; no version appears and then vanishes | V-01, L-03, pad depth, A-05, R-07, R-08, P-15 | M | 0 | LatticeReview (shared tagging and certificate), #362 (bridge copy I-01, the plain line) |
| 2. A strength number that holds | pass / fail no longer depends on resolution; weight is printed grams; infill is a real lever | A-02, A-01, M-07, R-04, ruling 3 | M-L | 1 | LatticeReview: the certificate is shared |
| 3. Smooth surfaces | G2: surface from the function; drawn faces exact; no stair-steps, no snap creases | X-01, X-04, B-01, P-03, P-04, P-11, P-16, V-02, C-01 to C-03, I-02, F-01 | L | 0 (1 for the final numbers) | - |
| 4. Rules inside the optimiser | smallest wall (two lines) and hole, drain, overhang, a bound on waviness, load paths kept connected; no after-the-fact patches | P-07, P-18, S-06, V-03, V-04, F-05 | L | 3 | - |
| 5. Faster solves | run time | E-05, B-05, B-06, S-05, M-04, P-05, B-03, P-10, X-03, F-04, E-01 | M-L | 0 (independent) | reviewer: the solver is shared with Flexible |
| 6. Generative | G3: lightest part that meets the strength he set, several outcomes | M-05, L-04, R-01, R-03 to R-06, S-01 | L | 2, 4 | #362: job contract |
| 7. Optimise THEN lattice | G4b on the new engine, one clean solid | M-06, A-04 (part), ruling 23:23Z | L | 2, 3 | JOINT with LatticeReview |
| 8. Optimise WITH lattice | G4a: his placement as guidance | S-07, R-09, M-06 | L | 6, 7 | LatticeReview: laws |
| 9. One button | one small job block, one flow, outcomes side by side | J-01, 3e | M | 6 to 8 | #362, UI-Notes build the screens |
| 10. Clean-out | G1: what nothing runs is gone | S-08, S-02 to S-04, M-02, M-03, P-01, P-02, E-02, E-03, T-01, F-03, L-01, L-02, M-01, P-09, R-02, V-05, A-03, mixed precision | M-L | each item after the stage that replaces it | his OK for deletions of data and the harness |

Stage 0 "make room" comes first on purpose: today every stage would edit `run_job.cpp`, and the rule is no two agents in one file.

Stages 3 and 5 do not depend on 1 and 2 and can run beside them if he approves helpers (Phase 5).

### The "best I can do" build

After his OK on the workplan and before helpers start production work: ONE probe tree (never merged) carrying the cheap form of stages 2, 3 and 4 together, measured against today on all reference parts. Its table settles the open choices below. Every mechanism is named and switchable, so each can later be tested alone.

### Open choices each stage settles by measurement (three settings or more, all reference parts)

| stage | choice | settings |
|---|---|---|
| 2 | size the stress is read over | 1, 2 and 4 line widths; against today's peak |
| 3 | basis and reach | Wendland C2 / C4 / cubic B-spline x reach 2 / 3 / 4 knot spacings |
| 3 | knot spacing | 2, 3, 4 line widths |
| 4 | smallest-size method | robust triple against explicit constraints (Dunning 2018) |
| 4 | waviness bound | perimeter bound at three levels against none |
| 5 | smoother | damped Jacobi (today) against Chebyshev; stored dof numbers against a grid stencil |
| 6 | search | strength constraint in the loop against today's bracket, at 150 / 175 / 200 % |

## 4. Every module

Action: keep / clean / rewrite / delete / new. Size S / M / L is amount of work, not time.

### core/src/simp and its headers

| module | action | reason | risk | test | size | stage |
|---|---|---|---|---|---|---|
| plsm.cpp (the loop) | rewrite | one loop with a pluggable objective and constraints; frozen sets as true distances; no silent refit (P-04, P-07, P-11) | every result changes | A, B, F, N, reference table | L | 3, 4, 6 |
| plsm_basis.hpp | rewrite | crease in the shipped basis (B-01); double search and full matrix (B-02); thread churn (B-03) | ripple moves, not vanishes | A, F | M | 3 |
| plsm_frac.hpp | clean | keep the softened count; remove the 1/64-step count and fix the border band (P-16, P-17) | low | A | S | 3 |
| plsm_kernel.hpp | keep | read, sound | - | existing | - | - |
| plsm_topology.hpp | keep, promote | sealed-pocket count becomes a rule the accept step enforces (P-18) | refuses parts that pass today | I | S | 4 |
| plsm_mma.hpp, mma_joint.cpp, three more MMA copies | rewrite as one | five copies; the live one takes exactly one constraint (S-06) | optimiser behaviour | unit test against the textbook problem; N | M | 4 |
| minimize_plastic.cpp | rewrite | one 2,500-line function (P-12); fixed ladders (M-05); SIMP-only branches (M-02); old-lattice couplings (M-06) | the driver is where every rule meets | L, M, N | L | 0 (moves), 6 |
| production.cpp / .hpp | clean | 183 lines of code in 873; four dead switches (P-01, P-02) | low | K | S | 10 |
| analyze.cpp | rewrite | 640-line function, 21 positional arguments (A-03); peak-voxel margin (A-02); lattice branches stay until LatticeReview moves them (A-04) | SHARED certificate: lattice strength check changes too | E, K | M-L | 2 |
| simp.cpp: shared solve pieces (`simp_compliance`, scenarios, design mask) | keep, move, clean | PLSM runs them; sensitivity loop single-threaded (S-05) | low | K, P | S | 0, 5 |
| simp.cpp: the SIMP optimiser, variants, SEMDOT hooks | delete | never runs for him (S-08, S-02, S-04); DECISION 1 | tests that use SIMP as reference go too | M | M | 10 |
| simp.cpp: stress aggregate and adjoint | port, then delete | the maths G3 needs, living in dead code (S-01) | low | N | M | 6 |
| observability.cpp | clean | 1,900 lines of counters; duplicated copy blocks (P-09) | receipts change shape | K | M | 10 |
| gate_diagnosis.cpp | keep, clean | "why it failed and what would pass"; must speak the new strength number and the real infill lever | wrong advice if not updated | E | S | 2 |
| warm_start.cpp, semdot.cpp | delete | SIMP only (M-03, S-04) | none for the app | M | S | 10 |
| lattice_density_field.cpp | replace | prior art for G4a, priced with the old laws (S-07) | - | O | M | 8 |
| pipeline.hpp, simp.hpp, job.hpp | clean | options follow the split; history out of comments (P-01) | low | build | M | 0, 10 |
| grading, cell_plan, lattice_algorithm | not mine | LatticeReview | - | - | - | - |

### core/src/cli

| module | action | reason | risk | test | size | stage |
|---|---|---|---|---|---|---|
| run_job.cpp | split | 21,635 lines; TO run, analyze, strengthen and export move to their own files, lattice parts stay where they are (P-13) | merge clashes with #362 and LatticeReview | M (byte-identical output) | M | 0 |
| new `to_export` | rewrite | nine optional arguments, three self-calls (X-02); file check by writing an STL and re-running everything, up to twice, plus four extra mesh builds (X-03) | - | A, B, J | M | 3 |
| new `to_run` (was `run_job`) | rewrite | one record per version (R-02); file checked before it is shown (R-07); one accept rule (R-08) | event order seen by the app | L | M | 1 |
| new `to_strengthen` | keep, then replace | working baseline for G3 (R-01); coarse search trusts a margin that does not hold (R-04); 25 % mass for a 2 % miss (R-05) | - | N | M | 6 |
| loadcase.cpp | rewrite | 880-line function (L-01); protection written twice (L-02); depth rounded to voxels (L-03); generative can only add (L-04); a second copy lives in bridge.cpp (I-01) | every job's setup | C, D, K | M | 1, 6 |
| job.cpp | clean | 171 keys, 21 in the `plsm` block, the app sends one (J-01) | hand-written jobs break | schema test | M | 9 |
| main.cpp | keep | - | - | - | - | - |

### core/src/mesh

| module | action | reason | risk | test | size | stage |
|---|---|---|---|---|---|---|
| new surface mesher on the function | new | 3a candidate 1 | certified and exported shapes must agree | A, B, E, J | M | 3 |
| mesh.cpp | keep; delete the fill resample | marching cubes and piece cleanup stay; the resample is the stair-step (X-04) | - | A | S | 3 |
| finish.cpp | shrink | the curvature flow and thin-spot patches are a fifth mesh filter and a bulge source (F-01, F-05); keep weld and audits | removing guards before the rules exist: flow goes with stage 3, thin-spot with stage 4 | F, G | M | 3, 4 |
| surface_operator.cpp | delete | `ramp_reconstruction` has no caller (F-02), now; the flow after stage 3 | - | build | S | 0, 3 |
| cad_project.cpp | rewrite small | snapping within a voxel pulls optimised walls onto drawn faces and leaves a crease (C-02, C-03); drawn faces now come exact from the part; keep `measure_flats` / `measure_bores` as tests (C-05) | - | B | M | 3 |
| smooth.cpp | keep | the app's smooth brush (#362's feature) | - | - | - | - |
| feature_edges, mesh_simplify, mesh_distance | keep, clean | one vector header, one closest-point routine in place of four (F-03, F-04) | low | existing | S | 10 |
| old lattice files | not mine | LatticeReview, stage G | - | - | - | - |

### core/src/fea, voxel, io, settings, tests, app

| module | action | reason | risk | test | size | stage |
|---|---|---|---|---|---|---|
| matfree / multigrid hot path | clean | 1,500 iterations per solve where tens are normal; per-element stored dof numbers and copies (B-05); Jacobi smoother (B-06) | shared with Flexible | K, P | M-L | 5 |
| solver settings | rewrite | eleven process-wide setters; results depend on who ran first (E-01) | - | K | M | 5 |
| geneo, recycle | keep | measured earlier (section H) | - | - | - | - |
| algebraic_coarsen | delete | compiled off, asserted off (E-02) | - | build | S | 10 |
| single-precision V-cycle | delete or revive | the switch does nothing on his path (section K); 20 % slower when it last ran | - | P | S | 5 |
| assembly.cpp | keep a small reference solver; rewrite `traction_loads` | production never selects the assembled solvers (E-03); force spread over tagged voxels (V-01) | - | C | M | 1, 10 |
| io/face_tag.cpp | rewrite | the cause of V-01 | changes every margin, the lattice check included | C, D | S | 1 |
| voxel/voxelize.cpp | rewrite the part-in step | yes/no voxels (V-02); feature rule in voxels (V-03); bridges stamped after the optimiser (V-04); three piece counts (V-05) | - | A, G | M | 3, 4 |
| io/step | clean | 0.1 mm triangles before anything starts (I-02) | file size, time | B | S | 3 |
| settings (margin formula, report) | rewrite the formula | strength assumes infill, weight does not (M-07) | his numbers change; say so once, plainly | E | S | 2 |
| tests/unit | new | nothing measures a surface against a known shape or a certificate against a known stress (T-02) | - | A to P | M | 0 |
| tests/harness | delete the unbuilt probes | 79,000 lines of one-off experiments (T-01); DECISION 5 | - | build | M | 10 |
| bridge.cpp, app pages | #362 | one load-case mapping (I-01); the plain lines (A-05, R-07); the one-button contract | - | - | - | 1, 9 |

## 5. Decisions needed from the maintainer

1. **The old optimiser (SIMP).** Recommended: delete it once generative lands (stage 10). It never runs for him and is about 4,000 lines plus its tests. The alternative is keeping it as a test-only reference.
2. **The strength range.** "150 to 200 %": recommended reading is that 150 % is the floor and each run returns versions at 150, 175 and 200 % to choose from. The alternative is one version at the number he sets.
3. **A stiffness limit.** A part can be strong enough and still bend too much. Should the app ask "how much may it move?" Recommended: yes, optional, off by default.
4. **Sealed pockets in a solid (non-lattice) result.** Refuse, or allow? His written rule covers lattices only. Recommended: allow in a solid, report in one line; refuse in a lattice.
5. **The experiment probes** (`core/tests/harness`, 141 files). OK to delete the ones the build no longer uses?
6. **Straight-member "designed" style** (3a candidate 7). Recommended: after stage 9, as a second style, not in this rebuild.
7. **Resolution.** Once feature sizes are in mm, the app could choose the resolution from the print profile and the part size. Keep the picker, or derive it? Recommended: derive, with the picker kept as an override.

## 6. Risks

- **The shared certificate.** Stages 1 and 2 change every margin, including the lattice strength check. Planned with LatticeReview through the reviewer; released with a before / after table on his past parts.
- **Run time.** Stage 4's rules and stage 6's constraint each add solves while the solve is 65 to 77 % of a run. Stage 5 is not optional.
- **His numbers will move.** Parts that passed may fail and the reverse. Each release says which and why in plain words.
- **Clashes in shared files** until stage 0's split lands.

## 7. Size of the whole path

An estimate for the WHOLE path, start to the last release, not a promise:

| stages | delivers | one lane (me alone) | with two helpers |
|---|---|---|---|
| 0 to 3 | true loads, a strength number that holds, smooth surfaces (G2) | about 3 weeks | about 2 weeks |
| 4 to 6 | rules in the optimiser, speed, generative (G3) | about 4 more weeks | about 2.5 more |
| 7 to 10 | both lattice modes, one button, clean-out (G4, G1) | about 4 more weeks | about 2.5 more |
| all | | about 11 weeks | about 7 weeks |

What it rests on: each stage ends in a full release gate by #362 (about 8 hours each, ten of them); one heavy job at a time; the lattice rebuild's pace as the yardstick. What can stretch it: his usage budget, waits for the lock, and any stage whose measurement sends a candidate back.
