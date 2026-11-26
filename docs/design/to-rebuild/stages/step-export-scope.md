# Scope: an editable STEP for engineers (solid and latticed parts)

Status 2026-11-25: DRAFT, research only. His word: "Yes. Definitely do scope it. And also, look into the issues/solutions of doing so with a latticed part too." Nothing is built until he approves this scope. Finished after stage 3.

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

Tools for that route (checked 2026-11-25): QuadriFlow (quad remeshing; BSD-style licence; builds on Instant Meshes, BSD-style, with about four times fewer singular points), OpenSubdiv (subdivision surfaces and their patches; Apache-2.0 variant). QuadWild is out (GPL-3, needs the commercial Gurobi solver). A 2024 paper takes the same QuadriFlow route from quad mesh to splines for trimmed CAD surfaces (arXiv 2410.14318). The open step: turning the subdivision surface into NURBS patches that close at extraordinary points (where 3 or 5 patches meet) within CAD tolerance. Known answers to read before the prototype: Peters 2000, "Patching Catmull-Clark meshes" (SIGGRAPH; G1 bicubic patches, NURBS-compatible), and Loop & Schaefer 2008, "Approximating Catmull-Clark subdivision surfaces with bicubic patches" (ACM TOG 27(1)); Rhino's SubD-to-NURBS conversion is the working example. DOIs to pin down when the scope is finished.

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

Lattice export is LatticeReview's area: any build is joint.

## Sources

Shapr3D import help (support.shapr3d.com/hc/en-us/articles/7874501645724) and STEP article (shapr3d.com/blog/what-is-a-step-file-and-how-to-use-it-in-shapr3d); QuadriFlow (stanford.edu/~jingweih/papers/quadriflow); arXiv 2410.14318; NIST, ISO 10303-108 construction history (nvlpubs.nist.gov/nistpubs/Legacy/IR/nistir7433.pdf); nTop export article (support.ntop.com/hc/en-us/articles/7323484481555); nTop July 2022 notes (ntop.com/resources/blog/whats-new-july-2022); PTC CS303867; Creo STEP docs (support.ptc.com, About_STEP_Files); Onshape formats (cad.onshape.com/help/Content/translation.htm); HOOPS STEP reader (docs.techsoft3d.com); arXiv 2405.07946; par.nsf.gov/servlets/purl/10208239; US 12,450,828 B2; J. Comput. Des. Eng. 12(9):162 (2025).
