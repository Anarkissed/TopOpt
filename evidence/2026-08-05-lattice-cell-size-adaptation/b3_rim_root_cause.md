# B3 — why "rim" emitted zero geometry on his run

## The symptom

`run_info.lattice_export` from fingerprint `b3abcf880554`:

```
skin              rim
rim_triangles     0
rim_volume_mm3    0
skin_triangles    0
skin_volume_mm3   0
anchor_nodes      0
interior_volume_mm3  161923.0443     <- non-zero: struts WERE written
```

The interior lattice was emitted; every piece of boundary dressing was not.

## Root cause, with file and line

The rim is emitted **only where two ANALYTIC boundary FACES meet**.
`emit_rim_edge` (`core/src/mesh/lattice_gen.cpp:598-666`) takes two face indices
`fa`, `fb` and reads `B->faces()[fa]`, `B->faces()[fb]`; `emit_rim_torus`
(`core/src/mesh/lattice_gen.cpp:669+`) dresses a PLANE against a BORE. With no
face pairs there is nothing to iterate and both are no-ops.

`faces_` is populated in exactly two places, both in
`core/src/mesh/lattice_boundary.cpp`:

- `add_half_space` — line 122, pushes a `Kind::Plane` face;
- `add_keep_out` — line 160, pushes a `Kind::Bore` face, **and only for
  `ClearanceKind::Bolt`**. A slab keep-out takes the `else` at line 162 and
  records `-1`, commented "slab keep-out: no wall to dress".

Now look at how the boundary is actually built for a run —
`lattice_boundary_for`, `core/src/cli/run_job.cpp:568-586`:

```cpp
LatticeBoundary B;
B.set_voxel_base(&sg, &dens, printed_iso, 2.0 * cell_mm);   // adds NO faces
for (const ClearanceGeometry& g : kos)
  B.add_keep_out(g, /*collar=*/g.kind == ClearanceKind::Bolt);
for (const ClearanceGeometry& g : roles.includes) B.add_include_region(g);
for (const ClearanceGeometry& g : roles.excludes) B.add_exclude_region(g);
```

It **never calls `add_half_space` or `add_box`.** And lattice ROLES are
documented at `core/include/topopt/lattice_boundary.hpp:242-245` to contribute
"NO analytic faces … activation + certification mask only".

So on a voxel-derived variant `faces_` is **empty unless the job declares a BOLT
clearance**. His run declared none (`include_void_by_clearance` is 0, and no bolt
clearance appears in the job), so `faces_` was empty, so there were no face pairs,
so the rim, the skin and the anchor nodes were all structurally unreachable.

`anchor_nodes 0` has the same single cause — anchors are landings attributed to a
boundary face, and there were no faces.

## Why this is not a small fix

"rim" is not broken in its own code; it is a dressing law for **analytic**
boundaries (planes and bores) being asked to dress a **voxel silhouette** that
has no analytic representation. Closing it means one of:

1. **Derive analytic faces from the voxel silhouette** — fit planes to the
   marching-cubes surface (the pseudo-face segmentation at 35 deg that STL/3MF
   import already uses) and feed them in as half-spaces. This reuses machinery
   that exists, but the fitted faces would then also enter `clip_segment` and the
   signed-distance field, which moves the interior strut clipping on **every**
   existing lattice run — a verdict-flip risk and squarely a blocked-stop under
   R3.
2. **Write a voxel-native rim law** — dress the silhouette directly from the EDT
   instead of from face pairs. No effect on analytic paths, but it is a new
   geometry generator with its own percolation and certification story.

Either is a task in its own right. **This one leaves it standing**, per the
amendment's blocked-stop.

## What should happen in the meantime, and why I did not do it here

`skin: "rim"` on a boundary with no analytic faces should **refuse, or warn
loudly**, rather than silently produce nothing — the amendment's own standard
("must either work or refuse"). The check is one line at the top of the export:
`if (skin != "shell" && B.faces().empty()) …`.

I did not land it because it changes behaviour on every existing voxel-derived
`rim`/`skin` run (they would all start refusing), and I had no budget left to
measure that blast radius against the gate table. It is the **first** thing to do
next, and it is small.

## The part of this that matters most for his part

The amendment says the rim "is the only path that can dress a thin face slab, so
it is the path his part actually needs". That is right, and it compounds with B1:
his 4 mm regions cannot hold a certified lattice at any cell (see the Stage A
derivation), so dressing them with a skin/rim is the honest alternative — and
that alternative is currently a silent no-op on his geometry. Until one of the
two options above lands, **a skin is not actually available to him**, and the
handoff must not offer it as though it were.
