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
