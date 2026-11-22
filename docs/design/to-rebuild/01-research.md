# TO rebuild: research

Status 2026-11-21: paper register, then sections 3a to 3e as a FIRST DRAFT. The rankings are proposals for the plan (Phase 4), not decisions. Reading depth is stated per paper in "What was read".

## Paper register (every DOI in the brief checked against Crossref on 2026-11-21)

Corrections to the brief:

1. **Weak bead bonding, Computers & Structures 2023.** The brief's DOI `10.1016/j.compstruc.2023.107070` is a different paper (girder displacement by deep learning). The right one is Jewett & Carstensen, vol. 289, `10.1016/j.compstruc.2023.107158`.
2. **Dunning & Kim 2013, `10.1002/nme.4384`.** The DOI is real but it is "A new hole insertion method for level set based structural topology optimization". The finding quoted in the brief (RBF support of 2 to 4 knot separations) is not that paper's subject. The likely intended source is Dunning 2018, "Minimum length-scale constraints for parameterized implicit function based topology optimization", `10.1007/s00158-017-1883-1`. Both are kept; the claim is to be confirmed in the text.
3. **Wei et al. 2018 (88-line PLSM code).** Authors are Wei, Li, Li, Wang (brief: Wei, Li, Dai, Guo). DOI correct.
4. **Oh et al. 2019.** Authors are Oh, Jung, Kim, Lee, Kang. DOI correct.
5. **RDBLS code paper 2024.** Authors are Wang, Xie, Huang, Zhang, Zhou. DOI correct.
6. Added by the reviewer's ruling: Taylor 2008, "The theory of critical distances", `10.1016/j.engfracmech.2007.04.007`. DOI correct.

All other DOIs and the four arXiv ids (1909.10607, 2004.05448, 1903.01548, 2008.07487) resolve to the paper named.

| authors, year | title | journal | DOI | access |
|---|---|---|---|---|
| Aage, Andreassen, Lazarov, Sigmund 2017 | Giga-voxel computational morphogenesis for structural design | Nature 550:84-86 | `10.1038/nature23911` | free copy |
| Allaire, Jouve, Toader 2004 | Structural optimization using sensitivity analysis and a level-set method | Journal of Computational Phy 194:363-393 | `10.1016/j.jcp.2003.09.032` | free copy |
| Allaire, Jouve, Michailidis 2016 | Thickness control in structural optimization via a level set method | Struct Multidisc Optim 53:1349-1382 | `10.1007/s00158-016-1453-y` | free copy |
| Allaire, Dapogny, Estevez, Faure, Michailidis 2017 | Structural optimization under overhang constraints imposed by additive manufactu | Journal of Computational Phy 351:295-328 | `10.1016/j.jcp.2017.09.041` | free copy |
| Alzahrani, Choi, Rosen 2015 | Design of truss-like cellular structures using relative density mapping method | Materials & Design 85:349-360 | `10.1016/j.matdes.2015.06.180` | free copy |
| Andreasen, Elingaard, Aage 2020 | Level set topology and shape optimization by density methods using cut elements  | Struct Multidisc Optim 62:685-707 | `10.1007/s00158-020-02527-1` | free copy |
| Cheng, Bai, To 2019 | Functionally graded lattice structure topology optimization for the design of ad | Computer Methods in Applied  344:334-359 | `10.1016/j.cma.2018.10.010` | free copy |
| Christiansen, Nobel-Jørgensen, Aage, Sigmund, Bærentzen 2013 | Topology optimization using an explicit interface representation | Struct Multidisc Optim 49:387-399 | `10.1007/s00158-013-0983-9` | PAYWALLED |
| Christiansen, Bærentzen, Nobel-Jørgensen, Aage, Sigmund 2015 | Combined shape and topology optimization of 3D structures | Computers & Graphics 46:25-35 | `10.1016/j.cag.2014.09.021` | free copy |
| Deng, To 2021 | Projection-Based Implicit Modeling Method (PIMM) for Functionally Graded Lattice | JOM 73:2012-2021 | `10.1007/s11837-021-04659-1` | free copy |
| Dunning, Alicia Kim 2012 | A new hole insertion method for level set based structural topology optimization | Numerical Meth Engineering 93:118-134 | `10.1002/nme.4384` | free copy |
| Dunning 2018 | Minimum length-scale constraints for parameterized implicit function based topology optimization | Struct Multidisc Optim 58:155-169 | `10.1007/s00158-017-1883-1` | free copy |
| Gaynor, Guest 2016 | Topology optimization considering overhang constraints: Eliminating sacrificial  | Struct Multidisc Optim 54:1157-1172 | `10.1007/s00158-016-1551-x` | PAYWALLED |
| Groen, Sigmund 2017 | Homogenization‐based topology optimization for high‐resolution manufacturable mi | Numerical Meth Engineering 113:1148-1163 | `10.1002/nme.5575` | free copy |
| Groen, Stutz, Aage, Bærentzen, Sigmund 2020 | De-homogenization of optimal multi-scale 3D topologies | Computer Methods in Applied  364:112979 | `10.1016/j.cma.2020.112979` | free copy |
| Groen, Thomsen, Sigmund 2021 | Multi-scale topology optimization for stiffness and de-homogenization using impl | Struct Multidisc Optim 63:2919-2934 | `10.1007/s00158-021-02874-7` | free copy |
| Guo, Zhang, Zhong 2014 | Doing Topology Optimization Explicitly and Geometrically—A New Moving Morphable  | Journal of Applied Mechanics 81: | `10.1115/1.4027609` | free copy |
| Haber, Jog, Bendsøe 1996 | A new approach to variable-topology shape design using a constraint on perimeter | Structural Optimization 11:1-12 | `10.1007/BF01279647` | PAYWALLED |
| Holmberg, Torstenfelt, Klarbring 2013 | Stress constrained topology optimization | Struct Multidisc Optim 48:33-47 | `10.1007/s00158-012-0880-7` | free copy |
| Jewett, Carstensen 2023 | Topology optimization for material extrusion-based additive manufacturing processes with weak bead bonding | Computers & Structures 289:107158 | `10.1016/j.compstruc.2023.107158` | free copy |
| Krish 2011 | A practical generative design method | Computer-Aided Design 43:88-100 | `10.1016/j.cad.2010.09.009` | PAYWALLED |
| Langelaar 2016 | An additive manufacturing filter for topology optimization of print-ready design | Struct Multidisc Optim 55:871-883 | `10.1007/s00158-016-1522-2` | free copy |
| Langelaar 2016 | Topology optimization of 3D self-supporting structures for additive manufacturin | Additive Manufacturing 12:60-70 | `10.1016/j.addma.2016.06.010` | free copy |
| Lazarov, Sigmund 2010 | Filters in topology optimization based on Helmholtz‐type differential equations | Numerical Meth Engineering 86:765-781 | `10.1002/nme.3072` | PAYWALLED |
| Le, Norato, Bruns, Ha, Tortorelli 2009 | Stress-based topology optimization for continua | Struct Multidisc Optim 41:605-620 | `10.1007/s00158-009-0440-y` | PAYWALLED |
| Matejka, Glueck, Bradner, Hashemi, Grossman 2018 | Dream Lens | Proceedings of the 2018 CHI  :1-12 | `10.1145/3173574.3173943` | PAYWALLED |
| Norato, Bell, Tortorelli 2015 | A geometry projection method for continuum-based topology optimization with disc | Computer Methods in Applied  293:306-327 | `10.1016/j.cma.2015.05.005` | PAYWALLED |
| Noël, Schmidt, Messe, Evans, Maute 2020 | Adaptive level set topology optimization using hierarchical B-splines | Struct Multidisc Optim 62:1669-1699 | `10.1007/s00158-020-02584-6` | free copy |
| Oh, Jung, Kim, Lee, Kang 2019 | Deep Generative Design: Integration of Topology Optimization and Generative Mode | Journal of Mechanical Design 141: | `10.1115/1.4044229` | free copy |
| Panesar, Abdi, Hickman, Ashcroft 2018 | Strategies for functionally graded lattice structures derived using topology opt | Additive Manufacturing 19:81-94 | `10.1016/j.addma.2017.11.008` | free copy |
| Rodrigues, Guedes, Bendsøe 2002 | Hierarchical optimization of material and structure | Structural and Multidiscipli 24:1-10 | `10.1007/s00158-002-0209-z` | PAYWALLED |
| Sigmund 2007 | Morphology-based black and white filters for topology optimization | Struct Multidisc Optim 33:401-424 | `10.1007/s00158-006-0087-x` | PAYWALLED |
| Taubin 1995 | A signal processing approach to fair surface design | Proceedings of the 22nd annu :351-358 | `10.1145/218380.218473` | PAYWALLED |
| Taylor 2008 | The theory of critical distances | Engineering Fracture Mechani 75:1696-1705 | `10.1016/j.engfracmech.2007.04.007` | free copy |
| Wang, Lazarov, Sigmund 2010 | On projection methods, convergence and robust formulations in topology optimizat | Struct Multidisc Optim 43:767-784 | `10.1007/s00158-010-0602-y` | PAYWALLED |
| Wang, Xie, Lin, Zhou 2022 | A reaction diffusion-based B-spline level set (RDBLS) method for structural topo | Computer Methods in Applied  398:115252 | `10.1016/j.cma.2022.115252` | PAYWALLED |
| Wang, Xie, Huang, Zhang, Zhou 2024 | MATLAB codes of the parametrized level set method for structural topology optimi | Struct Multidisc Optim 67: | `10.1007/s00158-024-03909-5` | PAYWALLED |
| Wei, Li, Li, Wang 2018 | An 88-line MATLAB code for the parameterized level set method based topology opt | Struct Multidisc Optim 58:831-849 | `10.1007/s00158-018-1904-8` | PAYWALLED |
| Wein, Dunning, Norato 2020 | A review on feature-mapping methods for structural optimization | Struct Multidisc Optim 62:1597-1638 | `10.1007/s00158-020-02649-6` | free copy |
| Wu, Clausen, Sigmund 2017 | Minimum compliance topology optimization of shell–infill composites for additive | Computer Methods in Applied  326:358-375 | `10.1016/j.cma.2017.08.018` | free copy |
| Wu, Aage, Westermann, Sigmund 2018 | Infill Optimization for Additive Manufacturing—Approaching Bone-Like Porous Stru | IEEE Trans. Visual. Comput.  24:1127-1140 | `10.1109/TVCG.2017.2655523` | free copy |
| Yamada, Izui, Nishiwaki, Takezawa 2010 | A topology optimization method based on the level set method incorporating a fic | Computer Methods in Applied  199:2876-2891 | `10.1016/j.cma.2010.05.013` | free copy |
| van Dijk, Maute, Langelaar, van Keulen 2013 | Level-set methods for structural topology optimization: a review | Struct Multidisc Optim 48:437-472 | `10.1007/s00158-013-0912-y` | PAYWALLED |
| Swierstra, Gupta, Langelaar 2020 | Automated and Accurate Geometry Extraction and Shape Optimization of 3D Topology Optimization Results | arXiv | `arXiv:2004.05448` | free copy |

"Free copy" means an author or repository copy is listed by OpenAlex; not yet opened. "PAYWALLED" means none is listed; an author copy may still exist.


## What was read (2026-11-21)

Read from the text (abstract, conclusions and the passages each statement below rests on; not every page): Haber 1996, Sigmund 2007, Wang-Lazarov-Sigmund 2011, Lazarov & Sigmund 2011, van Dijk 2013, Wei 2018, Dunning & Kim 2013, Dunning 2018, Noël 2020, Andreasen 2020, Swierstra 2020, Christiansen 2014 and 2015, Norato 2015, Wein 2020, Guo 2014, Allaire 2004, Taubin 1995, Le 2010, Langelaar 2017 (the filter paper), Gaynor & Guest 2016, Krish 2011, Matejka 2018, Oh 2019, Rodrigues 2002, Deng & To 2021 (PIMM), Groen & Sigmund 2018, Groen 2020, Wu 2018.

NOT read, no copy in hand (statements about these below are marked "(not read)" and rest on the abstract or on how other papers cite them):

- Not obtainable: Wang 2022 (RDBLS) and its 2024 code paper.
- Free copies exist but the repositories refuse automated download (a bot check I do not work around): Holmberg 2013, Yamada 2010, Allaire 2016 (thickness), Allaire 2017 (overhang), Aage 2017, Langelaar 2016 (Additive Manufacturing), Jewett & Carstensen 2023, Taylor 2008, Cheng 2019, Wu 2017, Groen 2021, Alzahrani 2015, Panesar 2018. Links are in `agent-scratch/toreview/research/oa_check.txt`.

One more correction to the brief: the statement "an RBF support of 2 to 4 knot separations balances stability and efficiency" is in NEITHER Dunning paper (Dunning 2018 uses third-order B-splines and never discusses RBF support). The nearest source read is van Dijk 2013, section 2.1, which says it in words, without numbers: local support moves the boundary at most one element per change, mid-range support gives faster and smoother evolution, global support couples everything and makes steps hard to size. So the number is unsourced; this project must measure it (3a, candidate 2).

## 3a. Smoothness

### What the literature says

Roughness has two separate causes, and the papers treat them with different tools.

1. **The design problem itself wants endless fine detail.** Without a restriction, more and smaller holes always help, so the answer depends on the grid (Haber 1996). Cures: a BOUND on perimeter, which sets the number of holes and their size (Haber 1996); filters with a radius (Sigmund 2007; Lazarov & Sigmund 2011 give the same filter as a diffusion equation with one length); the robust eroded / middle / dilated triple, the only one of these that guarantees a smallest size on BOTH solid and void, at the price of three solves per step (Wang 2011). Andreasen 2020 shows the same filter, projection and robust triple work unchanged on a level set with a crisp boundary. Yamada 2010 (not read) puts one coefficient on a diffusion term to set complexity.
2. **The way the shape is stored and drawn.** The smoothness of the level-set function is set by the basis (van Dijk 2013, section 2). Cubic B-splines "promote the development of smooth designs and suppress small features" and "limit the need for filtering", though without a guaranteed size (Noël 2020). Dunning 2018 gets guaranteed sizes on a B-spline level set with explicit constraints. The slope of the function has to be kept in a band, by re-normalising (Wei 2018) or by bounds on the coefficients (Swierstra 2020 derive the bound: steepest slope is about 2.21 times the largest weight for unit-spaced Gaussians).
3. **Every paper that reports a smooth final part takes the surface from the smooth function itself, never from voxels.** Swierstra 2020 fit a Gaussian RBF level set (support 7 elements across) to a finished voxel result, then run a shape optimisation on it with a refined analysis at the boundary; result "highly smooth and accurate", cost on average more than the first optimisation. Christiansen 2014 / 2015 carry an explicit surface mesh through the whole optimisation (3D in the 2015 paper). Andreasen 2020 and Noël 2020 cut the elements at the true boundary so the analysis also sees no stair-steps.
4. **A "designed" look** (straight members, constant widths, round ends) comes from optimising shapes, not voxels: bars of fixed width projected onto a fixed grid (Norato 2015), moving components (Guo 2014), surveyed in Wein 2020, whose stated motive is "better control over the geometry".
5. Smoothing a finished mesh (Taubin 1995) is a low-pass filter that knows nothing of loads or protected faces.

### What this project already tried

| attempt | result |
|---|---|
| Smoothing the voxel surface afterwards: Taubin (PR 299), SDF / RBF refit (PR 303), curvature flow (PR 314), closing (PR 315) | all failed their targets (Taubin took off 5.5 % of the stair height while moving the surface 0.673 mm); curvature flow survives inside the finish and today removes 16 % of the stair-step on the stand |
| Fitting an analytic level set (PR 324) | carved roughness 24 % |
| Robust triple | the only mechanism measured to GAIN margin and REMOVE surface: light rung margin +19.3 % over control, surface -11.7 %; blocked on sealed void (14.85 %) because the drain rule was not in the loop; NOT in today's tree (ledger A) |
| Coarser knots | halved the margin. Wider reach at the same knot count, and C4, were never run |
| Perimeter as a penalty | cost 8.3 points of margin at the light rung |
| Helmholtz filter | margin fell 83 % at the light rung; cause never established |
| Level set against the old optimiser | 27.6 % weaker at the light rung, never explained, no owner |
| Export step alone, on a PERFECT shape (ledger C-1) | sloped and curved walls ripple by up to 0.2 mm, once per voxel, before any design roughness is added |
| Today (ledger D) | stand res 128: median 0.16 mm off a smooth patch, 98 % of patches over the 0.05 mm target; Top Motor Mount: median 0.01, worst 0.57 mm |

Code facts that explain the numbers (ledger A, B-01, section J):

- The optimiser already holds a smooth function (the RBF field). The export THROWS IT AWAY: it writes each voxel's fill fraction (64 samples, so steps of 1/64), runs marching cubes on that, then tries to smooth the result. Point 3 above is exactly what is not done.
- The basis the app runs is a cut-off Gaussian with a crease at the edge of every knot's reach (B-01).
- CAD faces are snapped back only for planes and cylinders, with a tolerance of one voxel, against a target of 0.02 mm.

### Candidates, ranked

| # | candidate | source | size | why here | main risk |
|---|---|---|---|---|---|
| 1 | Take the surface from the level-set function itself, at any fineness, and join it to the protected and CAD regions with the exact cutter already in the export | point 3; PR 324 | M | removes the largest loss; no new maths | the shape that is certified (fill fractions) and the shape that is exported must agree: the existing file re-check measures it |
| 2 | A basis with no crease and a wider reach: Wendland C2 (in the tree), C4, cubic B-splines; reach 2, 3, 4 knot spacings | van Dijk 2013; Noël 2020; B-01 | S | cheap, and candidate 1 inherits whatever ripple the basis has | wider reach = more work per step and slower fine detail |
| 3 | Keep the slope of the function in a band (coefficient bounds or re-normalising) | Swierstra 2020; Wei 2018 | S | makes the zero surface well defined; needed for 1 | none known |
| 4 | Robust triple on the level set, with the drain rule in the loop | Wang 2011; Andreasen 2020 | M | the only guaranteed smallest wall AND smallest hole (also serves "2 lines / 0.9 mm") | three solves per step when the solve is already 65 to 77 % of a run |
| 5 | A BOUND on perimeter or on curvature, computed from the function | Haber 1996; Yamada 2010 | M | this is "reward smooth walls" inside the optimiser; the literature uses a bound, the project tried a penalty | margin cost; must be shown at three strengths |
| 6 | A last shape pass on the real surface with a real analysis, fairness in the objective | Swierstra 2020; Christiansen 2015 | L | the only step where stress and smoothness trade off on the final shape | cost: as much again as the optimisation |
| 7 | Straight-member style: fit bars and plates to the result, then optimise them | Norato 2015; Guo 2014; Wein 2020 | L | the "designed" look; a second style for 3e | joints and plates in 3D; a research-grade stage |
| 8 | Snap to more CAD shapes (cones, fillets) and to 0.02 mm | cad_project today | S-M | CAD faces flat within 0.02 mm is a target of its own | fold-overs near edges (guard exists) |

Helmholtz is not ranked: it is a filter on the design (cause 1), not a surface smoother, and its collapse here is unexplained. A reading to test before reuse: the filter is solved with a no-flux edge on the design region (Lazarov 2011, eq. 12), and on parts that are three-quarters frozen its radius may be wiping out the few thin paths left at a light rung. That is a hypothesis.

### The measurement that decides

Every candidate, at three settings or more, on all reference parts, in one table: worst and RMS distance from a fitted smooth patch (3 mm), ripple in the 1 to 10 mm band, CAD faces within 0.02 mm, thinnest wall, margin under every scenario, mass, sealed voids, Release run time, one slicer picture. Candidate 2 first (same job, basis and reach changed, nothing else) because it is the cheapest and 1 depends on it.

## 3b. Generative ("lightest part that is strong enough")

### What the literature says

- **Minimise mass under a stress limit directly.** Le 2010 make it work with five ingredients: a filter for a smallest size, a stiffness rule that pushes to solid or void, a relaxed stress for part-filled elements (so material can vanish without a false stress peak), ONE aggregated stress number per region (p-norm, P = 6 in their example) and a running normalisation so that number tracks the true peak. Holmberg 2013 (not read) does the same with clustered constraints. PIMM uses a p-norm with p = 10.
- **A peak stress at a sharp corner does not converge; a stress read over a material length does.** Taylor 2008 (not read; reviewer's addition) is the standard source. This project measured the same thing (ledger F-2): the single-voxel peak climbs without limit as the grid refines, the mean of the hottest 0.5 cm3 holds within 15 to 30 %.
- **Print rules inside the loop.** Langelaar 2017: a layer-by-layer filter along the build direction, an element may exist only if the elements under it (45 degrees) exist; cheap, exact sensitivities. Gaynor & Guest 2016: the same aim by projection, with the angle as an input, together with a smallest size. Allaire 2017 (not read) does it on a level set. Jewett & Carstensen 2023 (not read): weak bonding between beads.
- **"Generative" means several outcomes to choose from.** Krish 2011: generate many, filter by constraint envelopes, the designer picks. Matejka 2018: once there are hundreds, the problem is browsing, filtering and comparing them. Oh 2019 get variety from a neural network on 2D wheels; nothing in it transfers to certified 3D parts, so here variety has to come from changing inputs.

### What this project has today

- `strengthen_versions` (R-01) already searches for the lightest design at a margin target, but by trial: up to 6 half-resolution runs and 3 full ones per version, three versions. It optimises stiffness and checks strength afterwards.
- The reduction ladder walks 68 / 52 / 38 / 26 % and stops at the first failure. On Top Motor Mount that is 50 minutes for 6 g (section K).
- A stress-constrained optimiser with its adjoint exists and is unused (S-01), in the SIMP loop only.
- The margin does not converge with resolution (F), so "150 to 200 %" has no fixed meaning until V-01 is done.
- Weight is reported as solid volume while the margin is cut by infill to the power 1.5 (M-07): the two sides of his rule are measured on different parts.

### Candidates, ranked

1. **A strength number that converges** (stress over a fixed material length, per Taylor 2008; ledger F-2, V-01). Precondition for everything below.
2. **Weight as printed grams, with infill as a lever** (M-07; goes through the reviewer to LatticeReview).
3. **Minimise printed mass subject to the strength number, in the level-set loop**, with Le 2010's ingredients; one run in place of up to 27. Cost: one extra (adjoint) solve per scenario per step. The existing bracket (R-01) stays as the baseline and the fallback.
4. **Print rules in the loop**: overhang along his build direction (Langelaar's filter adapted to the fill fractions), smallest wall of two lines through candidate 4 of 3a, drainable voids.
5. **Several certified outcomes per press**: margin target (150 / 175 / 200 %), build direction, style (smooth / straight members), infill. Each returned with weight, margin, time and a picture (3e).

### Inputs: what the app collects and what is missing

Collected (RemoteRunner job builder): part and material; loads grouped into scenarios; anchors; protected faces with depths; keep regions and keep-clears (clearances, cuts); design box; build direction; layer height, wall line widths, wall loops, infill %; resolution; redesign mode; lattice selections.

Missing for his rule: a strength RANGE (today one number); a weight target or "stop when savings fall under x"; an overhang limit; a stiffness / deflection limit (a part can be strong enough and still too floppy; nothing asks); which faces are cosmetic; how many outcomes he wants. Each is a question for him in Phase 4, not a decision here.

### The measurement that decides

Candidate 3 against today's bracket on all reference parts: printed grams at the same converged margin, under every scenario, with the print checks, and Release run time; three margin targets.

## 3c. Optimise and lattice TOGETHER

### What the literature says

- Structure and material can be optimised together, an outer problem for where material goes and an inner one for what it is like at each point (Rodrigues 2002).
- Two routes. **Priced by a law**: the lattice is treated as a material whose stiffness and strength depend on its density (Cheng 2019, not read, adds a stress limit; Groen & Sigmund 2018 and Groen 2020 then draw the real lattice from the coarse answer at about a thousandth of the cost of a fine run). **Priced by the real geometry**: PIMM (Deng & To 2021) adds a second RBF field for lattice density and projects the actual lattice onto the analysis grid, no law needed; their 3D example needs 200 x 200 x 60 elements and a GPU, and it removes sharp corners under a stress limit.
- Porous regions can be forced without a lattice library: an upper bound on local material volume gives bone-like infill that is robust to load changes (Wu 2018). A skin plus infill can be optimised as one (Wu 2017, not read).

### What this project has

- PR 334 "Mode 2": a second field (beta) and a joint optimiser step, in the tree but unreachable, wired to the SIMP loop and priced with the OLD lattice laws (ledger A, M-06, S-07). Its numbers: net mass -31.4 % and -47.0 %, margin -78 %, missing its 0.95x bar.
- The old homogenised lattice law over-predicts stiffness by 23 to 52 % when a member is only a few cells wide (lattice-phase0 M2). Any planner must use a knocked-down law, never the textbook one.
- `multiscale` (PR 293): dead for the app (R-09).
- The new lattice engine owns the laws and the frame-of-beams strength check (LatticeReview). The rule that a void inside a lattice must reach the outside exists as a check, not in a loop.

### Candidates, ranked

1. **A second field on the same knots, priced by the new engine's own laws** (PIMM's layout, the law route's pricing). PIMM's real-geometry pricing is out at his resolutions: a 0.9 mm strut is one or two voxels. His placement enters as a prior the optimiser may overrule at a price ("guidance, not bible"), never as a fixed mask.
2. **Skin plus lattice as one design** (Wu 2017) where he asks for a skin.
3. **A local-volume bound** (Wu 2018) as the fallback where no law is trusted.
4. Drawing an oriented lattice from the coarse answer (Groen 2020): later; the new engine lays out cells itself.

Needed from LatticeReview through the reviewer: stiffness and allowable stress as functions of density for each cell type, with their valid range, and the cost of one frame-of-beams check.

### The measurement that decides

Printed grams at the same certified margin: TOGETHER against THEN against solid, on all reference parts, with the lattice print checks and the drain rule, and how far the result moved from his placement (a picture).

## 3d. Optimise THEN lattice

### What the literature says

Alzahrani 2015 (not read): map the optimiser's density to strut size cell by cell. Panesar 2018 (not read): several ways to derive a graded lattice from a result; graded beats uniform. Both are after-the-fact mappings and neither re-optimises the solid around the lattice.

### What this needs here

1. **Carry his selections onto the new shape.** Selections are made on the drawn part; the optimised part has different faces. Rule to test: lattice region = his selected volume intersected with what the optimiser kept.
2. **Grade from the final analysis** (stress or strain energy is already written per voxel) through the new engine's grading.
3. **A seamless join**: skin or fillet at the solid-to-lattice boundary, merged with the exact cutter; no shared-edge defects (the X-05 class).
4. **Re-certify the whole part** with the lattice law, and thicken where it fails (the loop Organic cut 2 already runs).

### The measurement that decides

Margin before and after latticing, grams saved, print checks, and a clean single solid, on all reference parts with his real selections.

## 3e. One button

| goal \ lattice | none | THEN | TOGETHER |
|---|---|---|---|
| Minimise plastic (start from his part) | today's route, rebuilt | optimise, lattice his areas, re-certify | lattice placed by the optimiser, his areas as guidance |
| Generative (lightest that is strong enough) | 3b | 3b, then lattice | 3b with the second field |

Every cell returns the same thing: a small set of certified versions, each with printed grams, margin under every scenario, print time, and a picture; refusals say in one plain line why. Comparison follows Matejka 2018: sort and filter by weight, margin and time, two versions side by side. How many versions, and which inputs vary, are his to choose (3b, inputs).

## Where "not possible" could come back

Listed now so the bar is applied when it happens: candidate 1 of 3a (certified shape and exported shape disagree); candidate 4 of 3a and candidate 3 of 3b (run time); candidate 1 of 3c (no usable law at low density). Each needs the named papers answered, a build, all reference parts, three settings and the failing target stated.
