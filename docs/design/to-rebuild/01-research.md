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


## What was read (2026-11-21, updated 2026-11-22)

Read from the text (abstract, conclusions and the passages each statement below rests on; not every page): Haber 1996, Sigmund 2007, Wang-Lazarov-Sigmund 2011, Lazarov & Sigmund 2011, van Dijk 2013, Wei 2018, Dunning & Kim 2013, Dunning 2018, Noël 2020, Andreasen 2020, Swierstra 2020, Christiansen 2014 and 2015, Norato 2015, Wein 2020, Guo 2014, Allaire 2004, Taubin 1995, Le 2010, Langelaar 2017 (the filter paper), Gaynor & Guest 2016, Krish 2011, Matejka 2018, Oh 2019, Rodrigues 2002, Deng & To 2021 (PIMM), Groen & Sigmund 2018, Groen 2020, Wu 2018.

Read 2026-11-22 from the maintainer's copies in `papers/` (same depth: abstract, conclusions and the passages each statement rests on): Holmberg 2013, Yamada 2010, Allaire 2016 (thickness), Allaire 2017 (overhang), Aage 2017, Langelaar 2016 (Additive Manufacturing), Jewett & Carstensen 2023, Taylor 2008, Cheng 2019, Wu 2017, Groen 2021, Alzahrani 2015, Panesar 2018. No statement in 3a to 3e changed direction; the lines that rested on abstracts are now rewritten from the text, and three papers the sections did not yet use are placed under "Added from the second reading" at the end.

NOT read, no copy in hand: Wang 2022 (RDBLS) and its 2024 code paper. Nothing in the ranking rests on them.

One more correction to the brief: the statement "an RBF support of 2 to 4 knot separations balances stability and efficiency" is in NEITHER Dunning paper (Dunning 2018 uses third-order B-splines and never discusses RBF support). The nearest source read is van Dijk 2013, section 2.1, which says it in words, without numbers: local support moves the boundary at most one element per change, mid-range support gives faster and smoother evolution, global support couples everything and makes steps hard to size. So the number is unsourced; this project must measure it (3a, candidate 2).

## 3a. Smoothness

### What the literature says

Roughness has two separate causes, and the papers treat them with different tools.

1. **The design problem itself wants endless fine detail.** Without a restriction, more and smaller holes always help, so the answer depends on the grid (Haber 1996). Cures: a BOUND on perimeter, which sets the number of holes and their size (Haber 1996); filters with a radius (Sigmund 2007; Lazarov & Sigmund 2011 give the same filter as a diffusion equation with one length); the robust eroded / middle / dilated triple, the only one of these that guarantees a smallest size on BOTH solid and void, at the price of three solves per step (Wang 2011). Andreasen 2020 shows the same filter, projection and robust triple work unchanged on a level set with a crisp boundary. Yamada 2010 add a fictitious interface energy, tau times the squared gradient of the level-set function, and update by a reaction-diffusion equation; the one coefficient tau sets how complex the answer is, and the results depend little on the grid or the starting shape. It is a penalty weight, not a bound in millimetres.
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

- **Minimise mass under a stress limit directly.** Le 2010 make it work with five ingredients: a filter for a smallest size, a stiffness rule that pushes to solid or void, a relaxed stress for part-filled elements (so material can vanish without a false stress peak), ONE aggregated stress number per region (p-norm, P = 6 in their example) and a running normalisation so that number tracks the true peak. Holmberg 2013 split the stress points into a few clusters by stress level, one p-norm (p = 8) per cluster, re-sorted during the run; more clusters means tighter control of the true peak at more cost. Their examples are 2D. They conclude that optimising for stiffness and then fixing stress concentrations by a local shape pass is not sufficient; the stress limit belongs in the optimiser from the start. PIMM uses a p-norm with p = 10.
- **A peak stress at a sharp corner does not converge; a stress read over a material length does.** Taylor 2008 (reviewer's addition) is the standard source: a material length L = (1/pi)(Kc / strength)^2; failure is predicted from the elastic stress at a distance L/2 from the notch (point method) or averaged over a line 2L (line method); for polymers the comparison stress is higher than the plain strength, still a constant. So the length is a material property that needs fracture toughness, which `materials.json` does not carry; a maintainer data question, not a number for me to invent. This project measured the same thing (ledger F-2): the single-voxel peak climbs without limit as the grid refines, the mean of the hottest 0.5 cm3 holds within 15 to 30 %.
- **Print rules inside the loop.** Langelaar 2017: a layer-by-layer filter along the build direction, an element may exist only if the elements under it (45 degrees) exist; cheap, exact sensitivities. Gaynor & Guest 2016: the same aim by projection, with the angle as an input, together with a smallest size. Langelaar 2016 is the same filter in 3D, at negligible cost next to the solve; in a suitable orientation the printable design matched the unrestricted one. Allaire 2017 on a level set: a limit on the boundary's angle alone fails, the boundary grows a saw-tooth of small drips that each pass the angle test; they replace it with a model of the part's own weight layer by layer, which costs extra solves. Jewett & Carstensen 2023: beads of a fixed radius with a weaker material between them, giving both the shape and a tool path; 2D only, so not usable here as it stands.
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
- Two routes. **Priced by a law**: the lattice is treated as a material whose stiffness and strength depend on its density (Cheng 2019 fit stiffness and an anisotropic yield rule to the density of one cubic cell, check both on printed samples, then minimise weight under a stress limit, 3D, with the test beam yielding at the predicted load; Groen & Sigmund 2018 and Groen 2020 then draw the real lattice from the coarse answer at about a thousandth of the cost of a fine run). **Priced by the real geometry**: PIMM (Deng & To 2021) adds a second RBF field for lattice density and projects the actual lattice onto the analysis grid, no law needed; their 3D example needs 200 x 200 x 60 elements and a GPU, and it removes sharp corners under a stress limit.
- Porous regions can be forced without a lattice library: an upper bound on local material volume gives bone-like infill that is robust to load changes (Wu 2018). A skin plus infill can be optimised as one (Wu 2017): two sets of variables, a shell of prescribed thickness and an infill held under a local volume bound, with the robust triple for the smallest size; examples are 2D, the 3D extension is described as straightforward.

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

Alzahrani 2015: map the optimiser's density to strut size cell by cell. Panesar 2018: several ways to derive a lattice from a result; those that use the result are 40 to 50 % stiffer per gram than a uniform lattice, the graded one holds up best when the load varies, and the triangle count and slicing time grow steeply with the amount of lattice. Both are after-the-fact mappings and neither re-optimises the solid around the lattice.

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

## Added from the second reading (2026-11-22)

- **Allaire 2016, thickness on a level set.** Smallest and largest thickness as limits computed from the signed distance to the shape. The authors report that results depend strongly on the starting shape and on how the limit is applied, because the limit can block a change of topology, and that it needs a fine mesh. Bearing on 3a and rule "walls at least 2 lines": a wall-thickness limit inside the optimiser is a real option, but the robust triple (candidate 4) gives the same guarantee without those two weaknesses, so the ranking stands.
- **Aage 2017, a billion voxels.** Detail such as curved spars and thin walls appears only at very high resolution (1.1 billion voxels, 1 to 5 days on 8,000 processors). Bearing on 3e: resolution is a design choice with a cost, not something a phone or a Mac buys; this supports deriving the part resolution from the smallest feature asked for.
- **Groen 2021, coarse answer drawn as a fine lattice.** A coarse run with oriented cells, then the real geometry drawn by an implicit modeller; within about 5 % of the fine-run stiffness at about a thousandth of the cost, on a workstation. It confirms the "priced by a law" route in 3c for stiffness; it has no strength limit, so on its own it does not meet his margin rule.

## Added 2026-11-25: the material length for the strength reading (stage 2), from published values

The maintainer's word (2026-11-25): use published values; his own rig is not ready.

Read (free copies, saved text searched for the numbers): Ahmed and Susmel, "A material length scale-based methodology to assess static strength of notched additively manufactured polylactide (PLA)", Fatigue Fract Eng Mater Struct 41 (2018) 2071-2098, `10.1111/ffe.12746` (eprints.whiterose.ac.uk/123322); Susmel, review chapter on notched additively manufactured ABS and PLA (2022; eprints.whiterose.ac.uk/194145).

- The length: L = (1/pi) (K_Ic / strength)^2, with strength = the plain material's tensile strength for these (brittle-acting) printed polymers. The stress is read at L/2 from the surface (point method), averaged over a line 2L long (line method), or over a half-disc of radius L (area method).
- Printed PLA (100 % infill, any raster angle): tensile strength 42.9 MPa, E 3,479 MPa, K_Ic 3.7 MPa m^0.5 (thick specimens; thinner ones gave 3.5). The formula gives 2.4 mm; the authors could not trust the toughness test and calibrated L = 4.6 mm from sharp-notch tests. Point and area methods then predicted every notched test (tension and bending, blunt to sharp, three raster angles) within about 20 %.
- Printed ABS: tensile strength 23 MPa, K_Ic 2.6 MPa m^0.5, L = 4.1 mm.
- PETG: filament as received 2.11 to 2.54 MPa m^0.5 (Guessasma et al., Polymers 11 (2019) 1220); no printed value found. With 45 MPa: about 0.8 mm. PC, PA12, PP, HIPS, the filled grades, resins: no printed value found yet.

What it means here:
1. The length is millimetres, not tenths: 2 to 5 mm for PLA and ABS. That is the size of the walls this optimiser makes. A peak read on one voxel (0.5 to 2 mm) is not what breaks a printed part; the stress over a few millimetres is. This is why the per-voxel peak is both too harsh and unsteady.
2. Tests E agree in kind: read over a fixed 1.8 to 3.6 mm, the plate's number moves 6 to 8 % across resolutions and the ring's 2 to 8 %, against 12 to 24 % for the per-voxel peak.
3. Open, for discussion with the maintainer before any of it is built: the published method predicts BREAKING against tensile strength; this app certifies against YIELD with a safety factor. And the layer direction has its own, lower strength and toughness (no published L across layers found). A cautious first form: read over a size tied to the line width and never larger than the published L for the material, with the knockdowns as today.

### Second search, 2026-11-25 evening: the published lengths disagree, and most materials have none

- Printed ABS again: Cicero, Martinez-Mata, Arrieta et al., "Analysis of notch effect in 3D-printed ABS fracture specimens containing U-notches", Materials 13 (2020) 4716, `10.3390/ma13214716` (read from PubMed Central, tables 1 to 3). Strong prints (tensile strength 52 to 61 MPa, toughness 3.5 to 4.1 MPa m^0.5, three raster angles, 33 notched bending tests). The formula gives 1.4 to 1.5 mm; the length that best FITS the tests is 0.46 to 0.92 mm (averaged over a line) and 0.28 to 0.44 mm (read at a point). The authors say the fitted and formula values differ "significantly" because the material is not fully brittle. Susmel's 4.1 mm was for a weak print (23 MPa).
- So for one material the published length runs from 0.3 to 4.1 mm depending on the print and the method. The table (`material_length.hpp`) takes the lowest value that matches how we read (averaged over a size): ABS 0.46 mm, PLA 2.4 mm, PETG 0.7 mm (filament data). With his half rule: 0.23, 1.2 and 0.35 mm.
- No printed value found for PC, PA12, PP, HIPS, ASA, the filled grades or the resins (searched: fracture toughness and critical distance, each material, printed specimens). A printed short-fibre polyamide study reports toughness "slightly higher" than neat polyamide without a number in reach.
- What this does to the proposal: at half of 0.46 mm the reading is smaller than a voxel on every job, so for ABS the new number IS today's peak (with cut voxels at their real stiffness). The steadiness measured in tests E came from 1.8 mm and up. The honest position: the published data support a length of the order of a millimetre for printed plastics but do not pin it per material; his rig has to. Until then the choice between "cautious and unsteady" (small length) and "steady and less proven" (about 1 to 2 mm for every material) is his.


### The maintainer's source: CNC Kitchen (Stefan Hermann), read 2026-11-25

Four articles read: comparing PLA, PETG and ASA (2020-02-03); Prusament PC Blend (2021-06-12); Essentium PCTG (2021-05-29); carbon-fibre nylon PA6 against PA12 (2025-08-17). His own caveat: none of it on calibrated equipment; specimens per value mostly not stated.

- No fracture toughness or critical distance anywhere, so nothing here sets the length directly.
- Layer strength, standing against lying (his hooks and mini-specimens): PLA 55 %, PETG 46 %, ASA 29 % (34 % in a warm enclosure), PC Blend 50 to 63 %, PCTG 75 %. Our `materials.json` (the maintainer's data, not edited): PLA 0.55, PETG 0.70, ASA 0.60, PC 0.60. PETG and ASA are well above what he measured.
- Notched impact (Izod), lying: PLA 5, PETG 8.6, ASA 18, PCTG 24, PC Blend 27 kJ/m2. STANDING: PC Blend about 2, PCTG 1.5 kJ/m2. So across the layers the notched toughness is 13 to 16 times lower than in the plane, while the strength is only 1.3 to 2 times lower. By the length's own formula that makes the length across layers roughly a fifth of the in-plane one. This bears on the decision "same length across layers".
- Carbon-fibre nylon: PA6 loses 44 % of its strength and two thirds of its stiffness once it has taken up moisture; PA12 loses 10 to 15 %. A dry-strength number for a nylon is not the strength of the part in use.
- A cross-check only, NOT a published value: a rough toughness from his impact energy and bending stiffness, K about sqrt(E x G), gives PLA 4.1 MPa m^0.5, beside the published 3.7. The same sum gives PETG 4.0, ASA 6.4, PC 7.7. Impact energy overstates the true fracture energy, so these are upper guides at best.

### Decided by the maintainer, 2026-11-25

"Let's go with the lowest published value for each." So: PLA 2.4 mm, ABS 0.46 mm, PETG 0.7 mm, halved by his earlier rule (1.2, 0.23, 0.35 mm). Open: the nine materials with no published value.

### PA12, the material of every reference part of his (B6, 2026-11-26 04:30)

Read from PubMed Central (the tables verbatim):

- Zolfagharian, Khosravani and Kaynak, "Fracture resistance analysis of 3D-printed polymers", Polymers 12 (2020) 302, `10.3390/polym12020302`. Nylon 12 FILAMENT printed on a Fortus 450mc (100 % infill, raster 0 degrees) against PA12 POWDER by Multi Jet Fusion. Table 1: fracture toughness K_c 0.92 MPa m^0.5 (printed filament) and 0.58 (MJF); tensile strength 44.79 and 34.91 MPa; modulus 493 and 780 MPa. The paper puts K_c in the table "instead of" the plane-strain toughness and does not state how it was measured; its printed yield stresses (3.61 and 7.21 MPa) look wrong. Treat as indicative.
- Stoia, Marsavina and Linul, "Mode I fracture toughness of polyamide and Alumide samples obtained by selective laser sintering", Polymers 12 (2020) 640, `10.3390/polym12030640`. Laser-sintered PA2200 (EOS), bending specimens to ASTM D5045, five per orientation: K_Ic 2.18 to 2.90 at 0 degrees (mean 2.69), 1.80 to 2.28 at 45 degrees (mean 2.03), 1.91 to 2.74 at 90 degrees (mean 2.35) MPa m^0.5. No tensile data in the paper.
- Not opened (paywalled or embargoed): Crespo et al. 2019, "Failure of polyamide 12 notched samples manufactured by selective laser sintering" (uses the theory of critical distances directly; should hold a length for sintered PA12); Avanzini et al., Engineering Fracture Mechanics 2024 (MJF PA12, strain-energy criterion). Titles for the maintainer if he wants them.

The length by the formula, L = (1/pi)(K / tensile strength)^2:

| source | toughness, strength | L |
|---|---|---|
| printed nylon 12 filament (the only FILAMENT-printed value found) | 0.92, 44.8 MPa | 0.13 mm |
| MJF PA12 | 0.58, 34.9 MPa | 0.09 mm |
| laser-sintered PA2200, lowest orientation (strength 48 MPa from the maker's sheet, not from the paper) | 2.03, 48 MPa | 0.57 mm |
| laser-sintered PA2200, highest orientation | 2.69, 48 MPa | 1.00 mm |

What it means: by "the lowest published value for each" PA12's length is 0.13 mm, and half of it 0.07 mm: far under a voxel at any resolution he runs. So for his parts the reading stays one voxel whichever way the table is filled. PA12 is NOT added to `material_length.hpp` tonight, on purpose: a published length makes the code switch on real stiffness for cut voxels, and real stiffness with a one-voxel reading is the pairing the reviewer's bar found unsafe (6 to 18 % low on the plate). Whether a material whose length is under a voxel gets the middle stiffness (E x fill^2, the one pairing that passed) or keeps today's solve is part of the ruling already asked of the reviewer. Held for the maintainer in the morning.

## Added 2026-11-26: keeping every fixed face joined to the part (desk research for the morning question; nothing built)

The problem, seen on two made sample parts (stage 1 file): when a part is held in more places than it needs, the optimiser cuts the spare support off (the beam's second end; the bracket's thin tab), and the app either refuses the version (the Carriage Arms rule) or the export bridges it back with a bar. The optimiser is never told a fixed face has to stay joined.

What the literature offers, in the order of how much it would change:

1. A connectivity rule inside the optimiser. Coola, Aage and Sigmund, "A practical review on promoting connectivity in topology optimization" (arXiv 2501.09402, 2025, for Structural and Multidisciplinary Optimization) compares five such rules on one problem. The best known is the "virtual temperature" method: a second, cheap, heat-like solve in which material conducts and air does not; an island (or a cut-off support) shows up hot, and a limit on the hottest point keeps everything joined. Cost: one extra scalar solve per step (far cheaper than the strength solve) and one more limit for the optimiser to honour. Opened: the review's abstract and summary only.
2. "Fail-safe" optimisation: the part must still carry its loads with a piece missing (Zhou and Fleury, "Fail-safe topology optimization", Struct Multidisc Optim 2016, DOI 10.1007/s00158-016-1507-1; MIT, "Volumetric topology optimization under redundancy constraints"). Turned to our case: add a load case per fixed face in which that face is left out, or in which it alone holds the part. Then every support does real work and the optimiser keeps it joined by itself, and the result means something to the user ("it still holds with one bolt out"). Cost: one more strength solve per fixed face per step, so it is only affordable for a few fixed faces, and it makes parts heavier. I did not find a paper that does exactly this for supports; the fail-safe papers remove material, not supports.
3. What the app does today: refuse the version after the fact (cheap, loses the lightest versions), or bridge it back at export (keeps the version, with a bar the optimiser never checked).

A cheaper engineering route that needs no paper, to weigh beside these: have the rule that refuses the version ALSO stop the removal step that would cut the support off (the level-set update is rolled back where it would separate a fixed face's pad from the body). It keeps the versions, costs a flood fill per step, and adds no new physics; its risk is a thin thread left hanging on, which the minimum-width rule of stage 3 would then have to thicken.

For the discussion with him: (1) is the general answer and fits the plan's stage on the optimiser; (2) is the only one that makes the kept support worth having; the cheap route gets most of the benefit soonest. No lean taken before he has seen the pictures.

## Added 2026-11-26: PA6 (the maintainer plans to print it), for the stage 2 reading length

Looked for a published toughness of FILAMENT-PRINTED nylon 6. Found little, and none I would put in the table:

- Toughness: one paper on printed engineering plastics gives about 3.0 MPa m^0.5 for "pure PA" and 1.72 for glass-filled PA (Yang et al., "Study on the Fracture Toughness of 3D Printed Engineering Plastics", J. Materials Engineering and Performance; a correction was issued, and a published Comment disputes its values, Springer 10.1007/s11665-025-11260-z). The summary read does not say the PA is PA6. Not opened in full.
- Strength, printed: Stratasys FDM Nylon 6, conditioned: 67.6 MPa flat (XZ), 36.5 MPa across the layers (ZX). Vendor PA6-CF: 115 MPa dry, 55 MPa wet in the layer plane: nylon loses about half its strength when it has taken up moisture.
- By the formula L = (1/pi)(K / strength)^2 with 3.0 and 67.6: 0.63 mm; after his half rule 0.31 mm. Under a voxel on most of his jobs, as with PA12.
- A lead not opened: Cicero, Ibanez-Gutierrez and others (Univ. of Cantabria) apply the theory of critical distances to MOULDED PA6 with 0 to 50 % short glass fibre, with and without moisture, 125 specimens; their papers should hold a calibrated length for plain PA6. Moulded, not printed.

What it means for him: there is no good printed-PA6 number yet; the one found comes from a disputed paper. PA6 is NOT added to `material_length.hpp`; a PA6 job keeps the one-voxel reading. Two things matter more for PA6 than this length: moisture (dry or conditioned strength differ by half) and the across-layer strength (about half the in-plane value). If he prints a few PA6 test bars when the rig is ready, that beats anything published.

## Reading stress at the true surface on a voxel grid (desk research 2026-11-27, for stage 4 and the one-judge ruling)

Asked because of the measurements of 2026-11-27 (stage 2 file, last sections; ledger A-06, A-07, A-08). Marks: [R] the full text was opened and read; [A] abstract, catalogue record or citation only; [M] from memory, NOT checked; PW = paywalled. Nothing here has been run by us; every figure is the source's.

**Cut-cell and immersed methods**
- [R] Nadal, Ródenas, Albelda, Tur, Tarancón, Fuenmayor 2013, "Efficient finite element methodology based on Cartesian grids", Abstract and Applied Analysis, doi:10.1155/2013/953786 (open). Says low accuracy along the boundary is the known drawback of such grids. Their fix: a patch fit (SPR-CD) with the boundary's tractions and internal equilibrium imposed. On a thick cylinder, four-node elements: raw stress error falls as O(h), recovered as about O(h^2); peak boundary stress from the recovered field "usually very accurate". 2D, exact integration in the cut elements (not fill x E).
- [A] Nadal, Bordas, Ródenas, Tarancón, Tur 2010, "Accurate stress recovery for the 2D fixed-grid FEM", Civil-Comp Proceedings 93, paper 256, doi:10.4203/ccp.93.256.
- [A, PW] Zhang, Aragón 2022, Int J Numer Meth Eng, doi:10.1002/nme.6825: cut elements with small physical parts OVER-estimate stress; patch recovery fixes it. (Our E x fill^3 over-read on the loaded ring is this family of failure.)
- [A, PW] Parvizian, Düster, Rank 2007, "Finite cell method", Comput Mech 41:121-133, doi:10.1007/s00466-007-0173-y; Schillinger, Ruess 2015, Arch Comput Methods Eng 22:391-455, doi:10.1007/s11831-014-9115-y. O(h) stress for linear elements in the energy norm; no pointwise boundary figure found.
- [M] Burman, Claus, Hansbo, Larson, Massing 2015, "CutFEM: discretizing geometry and partial differential equations", Int J Numer Meth Eng 104:472-501 (DOI unverified). Without a stabilising term small cut fractions make stresses unstable.

**Stress in topology optimisation**
- [R, pages 1-8] da Silva, Beck, Sigmund 2019, CMAME 354:397-421, doi:10.1016/j.cma.2019.05.046, summarising [A] their CMAME 344:512-537, doi:10.1016/j.cma.2018.10.020: stresses at jagged edges are over-estimated and oscillate or are under-estimated, by the relaxation; they keep a smooth intermediate layer at least one element thick, a relaxed stress interpolation, and CHECK on a body-fitted re-mesh.
- [A, PW] Svärd 2015, "Interior value extrapolation", Struct Multidisc Optim 51:613-629, doi:10.1007/s00158-014-1171-2: boundary stresses extrapolated from interior values. This is the carry we measured; its accuracy figures were not reachable.

**Voxel models of bone (the same problem, well documented)**
- [A, PW] Guldberg, Hollister, Charras 1998, J Biomech Eng 120:289-295, doi:10.1115/1.2798314: bending needs at least 3 to 4 voxels through the section. (Our A-06 table says more than that for 10 %.)
- [A, PW] Charras, Guldberg 2000, J Biomech 33:255-259 (DOI unverified): refining a voxel mesh does NOT reduce the local maximum error; boundary-specific filtering does.
- [A, PW] Camacho, Hopper, Lin, Myers 1997, J Biomech 30:1067-1070, doi:10.1016/S0021-9290(97)00073-0: smoothing the surface lowers the surface stress error.

**Small notches**
- No published "elements per notch radius" rule found; one industry example converged at about 12 elements per radius [A]. Our 20 to 37 % low under 3 voxels of radius is consistent.
- [A, book] Taylor 2007, The Theory of Critical Distances, Elsevier, ISBN 978-0-08-044478-9: failure at a notch is predicted from the stress a material-specific distance L / 2 IN from the notch, not at the surface. Where that distance is a voxel or more, the sub-voxel surface peak stops mattering. THIS IS STAGE 2's SIZE FORM (the stress read over the material's own length): the research already in this file, arrived at again from the notch side. It says the answer to A-08 for plastics may be the size form, not a sharper surface reading; it needs L for the material (PLA published; PA6 to find or test).

**What the evidence supports for a solver that stays on its grid, in order**
1. Never a power above 1 on the cut voxels FOR THE STRESS READING (real stiffness, or a relaxed interpolation with a layer at least a voxel thick). Free. Agrees with our measurements.
2. Boundary-aware patch recovery (fit over full voxels with zero traction imposed on the true free surface): the only method found VALIDATED on non-fitted grids, and only in 2D with exactly integrated cut elements. A small least-squares fit per surface patch.
3. The straight-line carry (Svärd): what we measured; within 9 % on gentle faces, fails under 3 voxels of radius.
4. At notches: the size form (critical distance), where the material's length is a voxel or more; otherwise flag it, or re-analyse the flagged spot finer.
Not found: any validation in 3D on voxels with fill-scaled stiffness. If we build (2) we validate it ourselves on the ring, the beam and the ellipse.

Paywalled items for the maintainer to fetch if wanted (title and DOI above): Zhang and Aragón 2022; Svärd 2015; Guldberg, Hollister, Charras 1998; Charras and Guldberg 2000; da Silva, Beck, Sigmund 2019 (CMAME 344).

## The twelve papers the maintainer fetched on 2026-11-27, READ IN FULL (three readers, in place in `agent-scratch/toreview/papers`; nothing copied; a reader's own inference is marked "(reader)"; I read Taylor 2006 pages 1 to 3 myself)

**A. Reading stress at the surface of a voxel model**
- Svärd 2015 (doi:10.1007/s00158-014-1171-2): "interior value extrapolation" is our carry. 2D, FIRST PRINCIPAL stress at element centres; the normal from the centre of gravity of the material in a disc; a STRAIGHT LINE fitted over 1.75 to 3.5 elements behind the edge (the first 1.75 are skipped); evaluated at the boundary element's centre, not the true surface. Table 1, 14 handbook notches (radius 4 to 10 units) x 30 angles, mean / scatter of the error: element size 1: -26 % / 20 %; 1/2: -15 % / 14 %; 1/3: -9.5 % / 11 %; 1/6: -3.3 % / 7 %. The conventional reading: -23 % down to -8 % with a scatter of 20 % that never shrinks. So the published method reads LOW by the same amounts we measured, and needs a notch radius of tens of elements for 5 %. Soft (grey) boundaries read about 20 % high. His designs are held to 5 elements of member and 1 of inner radius. Loaded boundaries: not treated. A curvature-shaped carry: not in the literature read; ours has no published check.
- Guldberg, Hollister, Charras 1998 (doi:10.1115/1.2798314): a voxel cantilever. Section-average von Mises error by elements across: about 45 % at 2, 15 to 20 % at 3 to 4, 8 % at 5, under 4 % from 7; low at low resolution (stiffening). They recommend at least 3 to 4 across in bending. Boundary values OSCILLATE around the exact; averaging 3 neighbouring boundary elements smooths them.
- Charras, Guldberg 2000: the boundary filter is a plain mean of a boundary element with the boundary elements sharing 2 nodes, boundary only. Maximum von Mises error at element centres: unfiltered about 75 to 95 % (does not fall with refinement), filtered about 45 % at 10 across and 30 % at 20 to 25; it helps only above 5 across. A filter over the whole model does not work.
- Sharma, Maute 2018 (doi:10.1007/s00158-017-1833-y): with exactly integrated cut elements, stress in small slivers still over-reads; converges to the body-fitted answer only with a ghost penalty on the solve AND a stabilised smoothing of the stress; plain averaging does not converge. In 3D on coarse meshes interior points miss surface peaks. Loaded cut faces: not treated.
- da Silva, Beck, Sigmund 2019 (doi:10.1016/j.cma.2018.10.020): on 0/1 voxels a plate with a hole reads 3.0 (exact 3) on a coarse mesh and 3.5 to 4.1 on a FINE one, oscillating with a period of one element: refinement makes a staircase worse. Their cure is a grey layer one element wide with a relaxed stress law calibrated for SIMP p = 3; body-fitted checks then within 5 % (fine) to 12 % (coarse). It would have to be calibrated again for any other law.

**B. Changing the solve**
- Kabel, Merkert, Schneider 2015: the "laminate" composite voxel is proven for TWO SOLID phases and for average properties (about 10 x smaller error); a void phase is not treated (it breaks the method's condition; a residual stiffness would be needed), and against pore-like contrast above about 50 the plain volume-fraction rule (our E x fill) did BETTER. The voxel becomes anisotropic (the single reference element matrix is lost); their solver ran 5 to 36 x slower. No local-stress figure. DROPPED as a lead for material against air.
- Simo, Rifai 1990: enhanced strains condensed per element; exact bending deflection with one element through the thickness when undistorted; no locking to nu 0.4999. For identical cubes the condensed matrix is one matrix times E (reader), so the regular-grid solver keeps its shape. The paper works 2D only (the 3D modes come from elsewhere) and does not validate SURFACE stress: that would have to be read from the enhanced strain at the face and measured by us.
- Dong 2001: structural stress = membrane + bending from equilibrium across the thickness; for solids he integrates the stresses over the section (the nodal-force form is given for shells); the same value for element sizes from 0.16 t to 2 t; not checked against exact answers; needs an identifiable thickness direction; non-monotonic profiles need elements under t / 2.
- Cormier et al. 1999: sub-modelling at area ratios of 2000:1 and more; DISPLACEMENT boundary values at nodes with CUBIC SPLINES between; global errors of 1.2 to 100 % at the peak brought to 2.0 % mean, 2.6 % worst, at about 100 x less computing; needs three global grids and the check that the sub-model's answer is the same from the medium and the fine global grid (a two-grid check would have passed an answer 40 % low). 2D only.

**C. What strength to compare with (the theory of critical distances)**
- Taylor 2006 (the review he found in place of the book; a full substitute): Point Method = the stress at L / 2 from the hot spot; Line Method = the average over 2 L; L = (1 / pi)(Kc / sigma_u)^2. In brittle polymers the strength to use is an inherent strength sigma_0 ABOVE the tensile strength, so mild notches (Kt below sigma_0 / sigma_u) do no harm; features much smaller than L lose their notch effect.
- Susmel, Taylor 2008: the stress is the MAXIMUM PRINCIPAL stress (under mixed loading, the normal stress on the plane where it is largest), compared with sigma_0, and L is defined with sigma_0. PMMA: sigma_0 = 113.9 MPa against a tensile strength of 67 (1.7 x), L = 0.108 mm. Within about 20 % on notches of radius 0.2 to 1.2 mm; at a blunt 4 mm notch (Kt 1.4) up to 43 % on the UNSAFE side: for Kt below about 2 use the plain maximum-principal-stress check. Neither paper gives a size for a volume average (the "1.54 L" figure is not in them), nor a rule for members thinner than L, nor a mesh size.
- Dul, Fambri, Pegoretti 2021 (doi:10.1007/s11665-021-05635-1): a high-temperature polyamide (grade not stated as PA6), neat and with 15 % carbon fibre, printed at 0.4 mm nozzle, tested DRY. Neat: flat 71 MPa yield, upright 26 MPa (0.36 of flat); apparent toughness 5.6 flat, 1.8 upright (not valid K_Ic). L from these (reader's arithmetic): about 1.9 mm flat, 1.5 mm upright; low trust (not PA6, dry, invalid toughness, very ductile).

**WHAT IT MEANS FOR STAGE 2 (mine; for the reviewer)**
1. The size form reads VON MISES over a BALL; the theory it rests on reads MAXIMUM PRINCIPAL stress at a point L / 2 in or along a line 2 L, against an inherent strength that comes paired with L. The ball and von Mises are not what was validated: to be reconciled (measure the ball against the Point Method on the known shapes, and decide the stress quantity).
2. Members under L thick (most of ours with PLA's 2.4 to 4.6 mm): the theory is silent; the consistent reading is that the notch effect fades and the NET-SECTION stress (with bending) against the tensile strength governs; take the worse of the two checks.
3. The surface carry is the published method (Svärd) with the same low reading; our true-surface target and the curvature shape go beyond it and are unverified outside our own tests. Add an average ALONG the surface over a few points (Charras, Guldberg) against the staircase oscillation.
4. Thin members in bending: the literature's floor is 3 to 5 elements for a section AVERAGE, not a surface value; A-06 stands. The two leads that could lower it are the enhanced-strain cube and section-force stress; the laminate voxel is not one.
5. Loaded cut faces: no paper read treats them. The straight line there is our own measured best.
6. Upright printing in nylon keeps about a third of the flat strength in this one paper: the across-layer check matters more for nylon than for PLA.

## Graded voxels as an add-on: the fourteen papers the maintainer fetched (2026-11-27 evening), READ by one reader in place (pages read: nine in full, five nearly; "(reader)" = its inference). A SIDE PIECE; research only; nothing built.

**The two-way loop (non-intrusive global-local coupling), as the papers give it**
- Gosselet, Blanchard, Allix, Guguin 2018 (doi:10.1186/s40323-018-0097-4): global solve with an extra interface load p; fine box solved with the global displacement on its boundary; residual r = -(fine reaction + p - coarse reaction of the zone), where the coarse reaction needs NO solve (the coarse operator applied over the zone); p += r. Converges if the coarse model of the zone is STIFFER than the fine one (sufficient). Interface conjugate gradients converge without that condition. The coarse zone may be made stiffer on purpose: the converged answer does not change. Non-matching interface: displacements down by T, reactions up by T transposed. Linear example (a holed blade, fine softer), to 1e-5: plain 11 iterations, CG 6, Aitken 7, SR1 8.
- Gendre, Allix, Gosselet, Comte 2009 (doi:10.1007/s00466-009-0372-9): one-way sub-modelling was 10 % off in displacement and 5 % in stress; the loop to 0.1 %: 7 iterations plain, 3 with SR1 (2D); 3D (500 000 global unknowns): 7 plain, 2 with SR1. Converges for local softening; if it converges it reaches the full model's answer.
- Whitcomb 1991 (doi:10.1016/0045-7949(91)90334-I): a hole: 6 iterations to 1e-7; one-way Kt 2.12 against 2.79 iterated (the zoom alone 24 % LOW). Local STIFFENING: 11 iterations at 2 x, 122 at 2.75 x, diverges at 3 x; with relaxation 0.5: 8 to 20.
- Duval, Passieux, Salaün, Guinard 2016 (review): "as soon as the local model is stiffer than the zone it replaces, the algorithm diverges" without help; Aitken and quasi-Newton cure it (a deliberately stiffer patch: plain diverged, Aitken about 100, quasi-Newton 17). A thicker patch converges faster (1 to 10 coarse layers: plain 700 to 90, quasi-Newton 18 to 12). Six patches at once: quasi-Newton 13, Aitken 17. Patches may re-define supports and loads.
- Liu, Sun, Fan 2014: non-matching interfaces with T and its transpose (energy-preserving); 3 to 5 iterations with Aitken to 0.1 %, 9 to 12 without; stress error then 0.03 to 0.05 %.

**The same idea inside multigrid (FAC, local defect correction)**
- McCormick, Thomas 1986 and McCormick 1984: composite-grid cycle = coarse solve of the restricted composite residual, correction, local fine solve; no overlap needed; proven convergent for symmetric positive definite problems with a Galerkin coarse operator; BOTH solves may be inexact and it still converges (Theorem 4); measured factors 0.04 to 0.47; refinement ratio 2.
- Hackbusch 1984; Anthonissen, Mattheij, ten Thije Boonkkamp 2003: local defect correction with a small overlap converges at O(H^2) per iteration (factors 1e-3 to 1e-6; "one iteration is enough in practice"), O(H) with none; proven for Poisson with the same operator in the patch.

**Second group**: a published adaptive (hanging-node) multigrid topology optimiser coarsens VOID regions rather than refining raisers (2 to 6 x faster; Herrero-Pérez 2023); 3D adaptive stress-constrained optimisation used 3.5 million elements against 102 million uniform, with no stress-accuracy comparison (Salazar de Troya, Tortorelli 2020); the sparse narrow-band optimiser stores 4 x 4 x 8 blocks, Galerkin coarse levels, 128 bytes a node, 2.5 to 3.1 x faster than dense (Liu et al. 2018); the incompatible-modes element: one-element cantilever 9.0 (plain) against 100.0 (exact and incompatible) (Taylor, Beresford, Wilson 1976).

**What it means for an add-on driver beside our solver (mine, from the reader's synthesis)**
1. Our measured case (the coarse grid about 20 % too STIFF) is the favourable one: the papers' sufficient condition holds, and softening examples settle in about 6 iterations plain, 3 to 8 accelerated. Plan on 3 to 8 global solves a box, warm-started.
2. Use acceleration from the first version (Aitken is the simplest; interface CG is unconditional). Where exact fills soften cut voxels the box can locally be the stiffer one: the cure the papers give is to make the coarse voxels under the box full on purpose (the answer is unchanged).
3. No overlap; box faces on coarse voxel faces, 2 to 3 coarse voxels from the feature; displacements down by trilinear interpolation, reactions up by its transpose; the coarse reaction is one operator application over the box's voxels.
4. The one-way zoom alone is the loop's first pass and reads LOW: 5 to 24 % in the papers' examples.
5. NOT covered by any of them: voxel models with cut or all-or-nothing voxels; trilinear voxels at h : h/2 on a matrix-free multigrid solver; a box face that cuts a thin wall, a support or a loaded face; inexact solves in this loop; topology-optimisation sensitivities through it. All to be measured.

