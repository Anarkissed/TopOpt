# Scope: an editable STEP for engineers (solid and latticed parts)

Status 2026-11-26 (night): DRAFT, research and writing only. His word: "Yes. Definitely do scope it. And also, look into the issues/solutions of doing so with a latticed part too." His yes to draft it during tonight's waits: 2026-11-26 ~03:50. Nothing is built until he approves this scope.

## In plain words (for him)

- **What you would get:** next to the print file, a CAD file that opens in Shapr3D (and SolidWorks, Fusion, Onshape) as a real solid. You can add a hole, cut a slot or shell it like a part you drew yourself.
- **Why it is hard:** a CAD solid is a jigsaw of smooth curved patches that must meet perfectly. Our shape is one smooth organic surface with many holes, and cutting it into neat patches automatically is the hard part. The big tools only manage it reliably on simple shapes.
- **What helps us:** your drawn faces (bolt holes, flats) are copied exactly from your own file. Only the organic part needs patches, and our new surface is a smooth mathematical shape, so the patches can be fitted to it exactly.
- **Shapr3D:** it can't edit a mesh (an STL only comes in as a reference body), so the file must be a true solid.
- **Latticed parts:** a lattice is far too many struts for a usable CAD file. Best bet: the CAD file holds the solid parts and each lattice zone as a plain solid; you edit the zone, and the app re-makes the lattice inside it.
- **The plan:** first a rough but valid solid of one part made of flat faces (cheap: it proves Shapr3D takes our files). Then the smooth version of the same part. Only then a button in the app. Each step has a stop point.

## What "editable in every major CAD program" needs

A STEP solid is a B-rep: smooth patches (planes, cylinders, NURBS) bounded by edges and corners, stitched closed within the CAD kernel's tolerance (about 0.001 mm). A CAD program lets you cut, drill, fillet or shell only a body that closes by ITS kernel's rules. The four kernel families to pass:

| kernel | programs |
|---|---|
| Parasolid | SolidWorks, NX, Onshape, Solid Edge |
| ShapeManager | Fusion, Inventor |
| CGM | CATIA |
| OCCT | FreeCAD (and our own core) |

HIS CAD program is **Shapr3D** (Parasolid; no scripting), so Shapr3D is the first program every prototype file must open and edit in.

"Editable" means direct edits on a solid; no feature history can be made for an optimised shape.

## Solid parts (the optimised shape)

What blocks it: an automatic patch layout on an organic, many-holed surface (the hard part; nTop: quad mesh to CAD body "works reliably only on fairly simple models"); patches that close within tolerance; exact seams with the drawn faces; patch count (file size, speed).

What we have: the drawn faces stay his exact STEP faces (trimmed only); the optimised shape is one smooth cubic B-spline function (stage 3); OCCT in core can build NURBS faces, sew, fix, check (BRepCheck) and write STEP.

Candidate route (to be prototyped on ONE part): quad remesh of the function's surface, then a subdivision surface, then bicubic NURBS patches (the Rhino / Fusion route), sewn to the trimmed drawn faces, checked valid in OCCT, opened in FreeCAD by me and in his CAD program by him.

Tools for that route (checked 2026-11-25): QuadriFlow (quad remeshing; BSD-style licence; builds on Instant Meshes, BSD-style, with about four times fewer singular points), OpenSubdiv (subdivision surfaces and their patches; Apache-2.0 variant). QuadWild is out (GPL-3, needs the commercial Gurobi solver). A 2024 paper takes the same QuadriFlow route from quad mesh to splines for trimmed CAD surfaces (arXiv 2410.14318). The open step: turning the subdivision surface into NURBS patches that close at extraordinary points (where 3 or 5 patches meet) within CAD tolerance. Known answers to read before the prototype: Peters 2000, "Patching Catmull-Clark meshes" (SIGGRAPH '00, `10.1145/344779.344908`; free copy at cise.ufl.edu/research/SurfLab/papers/00pccm.pdf; large, smoothly joining bicubic NURBS patches from a refined Catmull-Clark mesh), and Loop & Schaefer 2008, "Approximating Catmull-Clark subdivision surfaces with bicubic patches" (ACM TOG 27(1):8, `10.1145/1330511.1330519`; free copy at people.engr.tamu.edu/schaefer/research/acc.pdf). Rhino's SubD-to-NURBS conversion is the working example.

### Step 0, before the prototype: a faceted solid (added 2026-11-26)

The cheapest end-to-end check: the same split (step 2 below), but the cut surface goes in as flat triangles (the stage 3 file simplified to about 10,000-20,000 faces; it is smooth, so it simplifies well), sewn to his trimmed drawn faces with OCCT into one solid and written as STEP. Pass: valid in OCCT, one solid in FreeCAD, and in Shapr3D a hole, a cut and a fillet on a drawn face all work. It proves the seams, the sewing and what Shapr3D accepts before any patch work; it may even serve an engineer who only needs to add holes. Fails if Shapr3D refuses or crawls on that many faces: then fewer, larger faces; if still no, stop and report.

### Step 0 result, the stand (2026-11-26, his yes ~14:10)

Prototype tool `agent-scratch/tosurface/tools/step0c.cpp` (not in the repo; OCCT 7.9.3): the print file's triangles as planar faces sharing their edges exactly, ShapeFix_Shell / ShapeFix_Solid, coplanar faces merged (ShapeUpgrade_UnifySameDomain), BRepCheck, STEP AP214 in mm, read back.
- The stand at res 64 (stage 3 build d0c5b557) as it is: ONE valid solid, volume 88,294.2 mm3 = the file's, read back valid; but 54,111 faces, 144 MB, 84 s, 2.4 GB peak. Too heavy to hand over.
- Simplified first (quadric edge collapse to 12,000 triangles, cap 0.05 mm): ONE valid solid, 10,046 faces, 25 MB, volume 88,387.9 mm3 (+0.1 %), read back valid; 10 s, 0.8 GB. Pictures front and back match the print file (facets visible on the round parts, as expected). `stage-3-pics/stand_step0_front_back.png`, `stand_step0_back.png`. Sent to him for Shapr3D.
- Tried and dropped: giving the triangles on his curved faces his exact surfaces (so bores come back as true cylinders): the solid came out invalid, more faces, volume +2.5 %. True faces belong to the prototype (trimmed B-rep faces), not to step 0.
- HIS RESULT (2026-11-26 ~14:35, screenshots): it opens in Shapr3D and edits work, but "the sheer number of faces makes it very difficult to edit this object well" (Shapr3D offsets, extrudes and shells BY FACE); his example: each countersink is one face in his file, dozens here. Step 0 proved the export path; the face count is the problem.
- Tried: letting near-identical flats merge (0.002-0.005 mm, 0.0005-0.001 rad): 10,046 -> 9,649 / 9,518 faces and the solid invalid before the write. Dropped: the faces are on the round surfaces.
- Next, proposed to him (needs his yes): step A, his faces back exactly (his solid cut by the design's surface in OCCT, so every drawn face, countersinks included, is ONE face as he drew it; only the new surfaces stay faceted); then step B, smooth patches for the new surfaces (the prototype above).

### Step A (his yes 2026-11-26 ~14:45): the Boolean route, STOPPED at its stop rule

Tool `agent-scratch/tosurface/tools/stepA.cpp`: print-file triangles on his faces (0.015 mm) pushed out by a small step, the new surfaces simplified, his exact solid cut by that faceted solid (BRepAlgoAPI_Common).
- Try 1 (the stand at 64 before the keep-layer fix, push 0.05 mm): 4,871 faces, 89 of them his exact curved faces; but 2 solids and +12 % volume: his whole left wing came through (the cut misread inside and outside) and the caps were sliced where the design reaches past his faces into the design box. The caps turned out to be a stage 3 bug (keep layers two-sided), fixed in b92e3bd0.
- Try 2 (the fixed stand at 64, push 0.05 mm): a 4-face zero-volume result, BOPAlgo_AlertBadPositioning.
- Try 3 (push 0.3 mm; fuzzy 0.001 mm at push 0.05; fuzzy 0.01 at 0.3): nothing usable; AcquiredSelfIntersection (16-336), TooSmallEdge (680), BuilderFailed. Pushing the facets out makes the design self-intersect in tight places (the socket's T-slots, the countersink rims), and 30,000 facets lying 0.05-0.3 mm from his faces is what OCCT's Booleans handle worst.
- Also learned: the stand's file keeps real design-box material outside his part (about 9 % of its corners, more than 2 mm out, as stage 1 alone's file), so any route must use "his part plus the design box", not his part alone.
- Next route, proposed to him: no Boolean. Build the solid face by face: each of his faces the design keeps WHOLE copied as it is from his STEP; each face it keeps IN PART rebuilt on his exact surface, bounded by the seam where the design cuts it; the new surfaces as facets; all sewn into one solid (tolerance about 0.02 mm, the import's own). The seams then carry a small tolerance, which Shapr3D (Parasolid) must accept: step A's new risk.

### Step A, the face-by-face route (his "Try it out", 2026-11-26 ~23:30): STOPPED at its stop rule

Tool `agent-scratch/tosurface/tools/stepB.cpp`: each connected piece of the print file lying on one of his faces rebuilt as ONE face on his exact surface, bounded by its own seam loops; the new surfaces planar facets (simplified, seams kept); every edge built once and shared (no sewing). The fixed stand at 64 (b92e3bd0): 19,556 of 60,204 triangles lie on his faces, in 298 pieces with 375 loops; the new surfaces simplify to 11,720 facets (the 0.05 mm cap stops there).
- Try 1: 10,416 faces (199 curved: his), but invalid, volume 2x: the loops of pieces whose surface normal points into the part ran clockwise on his surface, so those faces were everything outside them.
- Try 2: each piece oriented by its triangles (124 reversed): 187 of the 298 rebuilt faces still invalid (137 cylinders, 41 tori, 9 planes).
- Try 3: seam tolerances 0.02 mm plus a whole-solid repair: the first invalid face reads BRepCheck_BadOrientationOfSubshape (a cylinder); the repair split the result into 24 shells. 2.0 GB peak.
- What it says: his periodic surfaces (bores, fillets) bounded by straight chords need their seam handled explicitly (a piece wrapping 360 degrees has no seam edge of its own), and the orientation must come from his face's own wires, not from mine reversed.
- What it would NOT fix: on the stand, the new surfaces (the bosses' walls) are still about 10,000 facets after simplification; only step B (smooth patches) or exact offsets of his faces (the stand's keep layers ARE his faces moved 5 mm) bring those down.
- Next, if he wants it: (a) copy his faces the design keeps WHOLE straight from his STEP, with his exact edges (no rebuild at all: the cylinders' seam problem disappears for every bore left intact), rebuild only the partly kept faces; (b) the keep layers as exact offsets of his faces (OCCT BRepOffsetAPI_MakeOffsetShape), which on this stand would make the bosses single faces too.

### Step C, his faces copied and re-trimmed (his "Yes, build them" 2026-11-27 ~01:10, after the research report): STOPPED after 7 runs

Tool `agent-scratch/tosurface/tools/stepC.cpp`, the report's ranks 1 and 2 in their cheapest form: his faces kept WHOLE copied from his STEP; his CUT faces that are planes rebuilt on his exact plane from the seam chords (exact on a plane); everything else facets; his faces joined to the rest by sewing (0.02-0.05 mm, edge cutting), no vertex-moving repair. The fixed stand at 64:
- His 162 faces: 84 whole (copied), 13 cut planes (rebuilt in 36 pieces), 34 cut curved (facets for now), 31 gone. So his countersinks and bores the design leaves alone come back as his own faces.
- Run 2: ONE shell, 16 free edges totalling 0.6 mm, volume +0.1 %; not a solid.
- Runs 3-5: the faulty faces are the rebuilt bottom and top planes (wire not closed) and 0.001-0.08 mm2 sliver facets beside them; invalid already before the coplanar merge, so sewing's handling of edges under its tolerance is the suspect.
- Run 6: edges under 0.05 mm collapsed onto their own corners first (2,857 of them): 4 free edges left (0.1 mm), but the volume read +11 % and OCCT's UnifySameDomain crashed (segfault inside IntUnifyFaces).
- Run 7: the last 4 gaps (0.03 mm each) sit at two mirror spots where HIS file has a cluster of near-zero faces (0.00-0.04 mm2 cylinders, tori, planes): skipping faces under 0.1 mm2 did not close them.
- What it says: sewing is a shortcut that fails exactly at the tiny features (his slivers, our slivers); the report's rank 2 does not sew: his face's border is built as pieces of curves ON his surface, shared with the neighbours. That is the next step if he wants it.
- **PAUSED by his word, 2026-11-27 ~01:50.** Nothing more on the STEP export until he asks.

### Step D, shared topology with no sewing (his word ~02:00: "continue after reading the literature, if it gives a good plan"): STOPPED after 3 runs

Plan from the papers (`agent-scratch/tosurface/stepA_lit_plan.md`: Benkő, Martin & Várady 2001 pp. 847-848; Bénière et al. 2013 pp. 1387-1389; Mesh2Brep 2025): topology from the labelled mesh, every B-rep edge built once and used by both faces, so the shell closes by construction. Tool `agent-scratch/tosurface/tools/stepD.cpp`: his whole faces copied with his surfaces, their edges split into pieces ON his exact curves (his own pcurves) wherever facets touch; his cut planes rebuilt on his plane; facets elsewhere; no sewing, no ShapeFix, no UnifySameDomain. The fixed stand at 64:
- 87 of his faces copied, 35 rebuilt plane pieces, 11,545 facets; 2,401 pieces of his edges on 175 of his edges; largest facet-to-his-curve gap 0.0095 mm (under the 0.01 mm stop line); 3.5 s, 109 MB.
- Run 1: 21 edges used once, 2 used three times; the solid step then aborted (open shell).
- Run 2: the open edges are short straight edges that lie on his edges but got no piece: corners at the ends of his CLOSED edges (circles) took one end's parameter by projection, so the last piece before the corner was never built.
- Run 3: corners at his edges' exact end parameters (both ends on a closed edge): 17 edges used once, 2 used three times. Stopped at the 3-run rule.
- What is left is bookkeeping, not geometry: a few chains along his edges still miss a piece (and two edges are claimed twice). The approach itself holds: the shell is 99.9 % closed with no tolerance search, and his faces and curves are exact.

### Step D DONE (his "Follow this to the end", 2026-11-27 ~06:50): a VALID solid with his own faces

The same tool, finished (`agent-scratch/tosurface/tools/stepD.cpp`, prototype, not in the repo). The fixed stand at 64 -> `stand_064_his_faces.step` (32 MB; zipped 5.9 MB), sent to him:
- 78 of his faces copied exactly (countersinks, bores, flats the design keeps whole), 39 of his cut flat faces rebuilt on his exact planes, 11,593 facets for the new surfaces; 11,710 faces.
- ONE valid solid in OCCT (BRepCheck: no invalid face, wire, edge, vertex or shell), no sewing, no ShapeFix, no UnifySameDomain, no SameParameter pass; read back from the STEP: one valid solid. Volume 86,381.2 mm3 against the print file's 86,450.6 (-0.08 %). Largest tolerance anywhere 0.0108 mm (at the 0.01 mm steps his file has and the print cannot resolve). Pictures front and back match the print file (`stage-3-pics/stand_step_his_faces_front.png`, `_back.png`). 8 s, 1.5 GB.
- What it took, after the three earlier runs: (1) a mesh edge is on his edge only if both its ends and its middle are, and a corner snaps to his corner only within 0.002 mm; (2) a face of his is copied only if the mesh gives a full chain along every edge it shares with something not copied (else it steps down, repeated until stable; 7 faces), and not at all if it has an edge under 0.1 mm (9 faces: his file's 0.03 mm edges and 0.00 mm2 slivers); (3) the print's own slivers collapse first (edges under 0.005 mm, onto their own corners: 661), and corners snapping makes coincide are merged (9); (4) every corner of a rebuilt plane goes exactly onto his plane, or onto the line of two (Mesh2Brep's snapping; largest move 0.014 mm); (5) a piece of his edge gets NO 2D curve on a plane (OCCT computes it) and his own 2D curve on a curved face (it keeps the face's turn on wrap-around surfaces; projected pieces broke the countersinks' loops); his edges' 2D curves on planes count along the edge differently from their 3D curves (reused, they put pieces 6.5 mm off); (6) OCCT's SameParameter pass is NOT used: it "fixed" those pieces by raising tolerances to 6.46 mm; (7) edges meeting his plane only within a 0.01 mm step carry their measured gap as tolerance (28).
- Still to do for an editable file: the 11,593 facets (the bosses) need smooth patches (step B); his CUT curved faces (37) are facets until their seams are traced on his surfaces.
- Waiting on him: does Shapr3D open it, and do his own faces (a countersink, a flat) offset and extrude as single faces?

### Prototype plan (one part, for his approval before any build)

1. Input: one finished stage 3 version of Top Motor Mount (drawn faces exact, cut walls from the function).
2. Split the file into its DRAWN faces (on his STEP's own faces: reuse those B-rep faces, trimmed) and its CUT surface (the optimiser's).
3. Quad-remesh the cut surface only (QuadriFlow), make it a subdivision surface, and turn that into bicubic NURBS patches (OpenSubdiv for the regular patches; Peters 2000 for the points where 3 or 5 patches meet).
4. Fit each patch to the function's exact zero surface (we can evaluate it anywhere), not to the triangles.
5. Sew drawn and cut faces into one shell with OCCT (BRepBuilderAPI_Sewing, ShapeFix_Shape), check it (BRepCheck_Analyzer: one closed, valid solid), write STEP AP214 (STEPControl_Writer). All of OCCT is already in core.
6. Pass marks, in this order: OCCT says valid; FreeCAD opens it as one solid and can fillet an edge and cut a hole (I can do this myself); then he opens it in Shapr3D and tries the same two edits. Report: face count, file size, largest gap, time.

What it will tell us: whether the patch layout holds on a real optimised shape, and what Shapr3D (Parasolid) accepts. What it will not: other CAD programs (each needs its own test), lattices (below).

## Latticed parts

Findings (2026-11-25):
- A lattice as a true B-rep is huge and fragile: nTop reports a lattice cube whose STEP opened in SolidWorks at over 600 MB against under 30 kB native; Creo does not carry its own gyroid / diamond lattices into STEP, IGES or Parasolid at all; IntraLattice users hit "No B-Rep data" in SpaceClaim.
- nTop recommends Parasolid over STEP into SolidWorks and NX; Parasolid programs handle mesh bodies almost like B-rep bodies.
- STEP AP242 can carry TESSELLATED_SOLID (a mesh inside a STEP); Creo reads and writes it; Onshape treats meshes as view-only. SolidWorks / Fusion handling of an AP242 tessellated solid: not found, to test.
- TPMS (gyroid) lattices are implicit by nature; CAD is B-rep: the core mismatch (arXiv 2405.07946).

Options to discuss:
1. **Solid as B-rep, lattice as its zone.** The STEP holds the editable solid and each lattice ZONE as a closed body (its envelope), named with its lattice settings; the engineer edits the solid or the zone, and the app re-fills the zone for printing. Small files; the lattice is design intent, not geometry.
2. **Solid as B-rep, lattice as a mesh body** in the same STEP (AP242 tessellated) or beside it (3MF / STL in the same coordinates). Reference only in most programs.
3. **Lattice as full B-rep** for small strut lattices only (each strut a cylinder, each node a blend), with a size gate and a plain line when refused.

4. **One cell, instanced** (his idea, 2026-11-25). STEP cannot carry a pattern FEATURE: the standards for feature history exist on paper (ISO 10303-108 and its relatives, NIST test translators) but mainstream CAD does not import them. STEP CAN carry an ASSEMBLY: the cell as one part, placed once per cell by a transform. Every major CAD program keeps those placements pointing at the one part, so editing the cell updates every copy: the CAD program's instancing does the work, not its pattern tool. Small file (one cell plus a list of placements). Limits: only the full, identical interior cells can be copies; graded cells, cells cut by a wall, skins and rims are each unique and come as their own bodies (or as the zone of option 1); the copies are separate bodies, so printing an edited lattice means a union in CAD (slow at thousands) or printing from our app; an edited cell must still meet its neighbours at the same faces. ~~A per-CAD-program script for a truly parametric pattern~~: SCRATCHED by him 2026-11-25 ("an extra script is completely impossible" in Shapr3D, and most users could not run one). The instancing itself needs no script; whether Shapr3D keeps STEP instances linked is to test. What Shapr3D documents: a STEP's assembly comes in as nested folders of separate parts (no constrained assembly), and nothing says repeated parts stay linked, so this option may not work for him.

Lattice export is LatticeReview's area: any build is joint. Recommended for discussion: option 1 (the zone as an editable solid, the app re-fills it); option 2 is reference-only in Shapr3D (its mesh bodies can't be edited: support.shapr3d.com/hc/en-us/articles/7874501863708).

## Keep / new / throw out

- **Keep:** OCCT in core (STEP read, tessellation, sewing, checks, STEP write are already linked); `StepModel` (his faces); stage 3's exact cut by the drawn part (the seams); the function phi (what the patches fit).
- **New:** one module (`export_step`): split, step 0's faceted solid, then remesh + patches + fit. New open-source pieces only in the prototype: QuadriFlow, OpenSubdiv (licences above).
- **Throw out:** nothing; today's export paths are untouched.

## Where it can fail, and the stop rule

- Step 0: Shapr3D refusing or crawling on a many-faced solid (see above).
- Prototype: the patch layout tangling at thin walls, close holes and the seams with his flats; patches that miss by more than the kernel's tolerance. Stop rule: if Top Motor Mount and the stand both fail to give one valid solid after the documented fixes, stop and report with pictures. No open-ended tuning.
- Each CAD kernel re-checks with its own tolerances: Shapr3D first (his), FreeCAD (OCCT) as the automatic check; others only on request.

## Cost (whole path, rough; step 0 narrows it)

- Step 0: about 1-2 days of one builder, then his look in Shapr3D.
- Prototype (smooth patches, one part): about 1-3 weeks; the patch layout is the unknown.
- The app action (engineer view only, with an (i); made on the Mac): about 3-5 days, with #362.
- Whole path to the button: about 2-5 weeks, after stage 3 closes.

## Asked of him (held until he writes)

1. Step 0 alone (valid but faceted): worth doing, or only the smooth version?
2. Latticed parts: is option 1 (an editable zone, the lattice re-made by the app) what an engineer would want?
3. Which part first: Top Motor Mount or the stand?

## Sources

Shapr3D import help (support.shapr3d.com/hc/en-us/articles/7874501645724), STL and mesh files (support.shapr3d.com/hc/en-us/articles/7874501863708) and STEP article (shapr3d.com/blog/what-is-a-step-file-and-how-to-use-it-in-shapr3d); QuadriFlow (stanford.edu/~jingweih/papers/quadriflow); arXiv 2410.14318; NIST, ISO 10303-108 construction history (nvlpubs.nist.gov/nistpubs/Legacy/IR/nistir7433.pdf); nTop export article (support.ntop.com/hc/en-us/articles/7323484481555); nTop July 2022 notes (ntop.com/resources/blog/whats-new-july-2022); PTC CS303867; Creo STEP docs (support.ptc.com, About_STEP_Files); Onshape formats (cad.onshape.com/help/Content/translation.htm); HOOPS STEP reader (docs.techsoft3d.com); arXiv 2405.07946; par.nsf.gov/servlets/purl/10208239; US 12,450,828 B2; J. Comput. Des. Eng. 12(9):162 (2025).
