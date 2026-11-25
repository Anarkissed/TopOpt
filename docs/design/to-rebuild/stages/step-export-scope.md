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

"Editable" means direct edits on a solid; no feature history can be made for an optimised shape.

## Solid parts (the optimised shape)

What blocks it: an automatic patch layout on an organic, many-holed surface (the hard part; nTop: quad mesh to CAD body "works reliably only on fairly simple models"); patches that close within tolerance; exact seams with the drawn faces; patch count (file size, speed).

What we have: the drawn faces stay his exact STEP faces (trimmed only); the optimised shape is one smooth cubic B-spline function (stage 3); OCCT in core can build NURBS faces, sew, fix, check (BRepCheck) and write STEP.

Candidate route (to be prototyped on ONE part): quad remesh of the function's surface, then a subdivision surface, then bicubic NURBS patches (the Rhino / Fusion route), sewn to the trimmed drawn faces, checked valid in OCCT, opened in FreeCAD by me and in his CAD program by him.

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

Lattice export is LatticeReview's area: any build is joint.

## Sources

nTop export article (support.ntop.com/hc/en-us/articles/7323484481555); nTop July 2022 notes (ntop.com/resources/blog/whats-new-july-2022); PTC CS303867; Creo STEP docs (support.ptc.com, About_STEP_Files); Onshape formats (cad.onshape.com/help/Content/translation.htm); HOOPS STEP reader (docs.techsoft3d.com); arXiv 2405.07946; par.nsf.gov/servlets/purl/10208239; US 12,450,828 B2; J. Comput. Des. Eng. 12(9):162 (2025).
