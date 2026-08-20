# Two coupons. The GRADED one is the test; the octet one is its calibration.

## 1. `graded_flow_coupon.stl` — ★ THE TEST

A **flowing, traced lattice built from the maintainer's own stress field.** This is
the geometry whose printability is actually in dispute.

| | |
|---|---|
| size | 40.7 x 40.6 x 41.6 mm |
| curves | 342, across **all three** principal families |
| connectors | 1,298 (cross-family ties) |
| base anchors | 342 — every curve reaches the slab |
| strut diameter | 0.80 mm |
| spacing `d_sep` | 3.00 mm (Jobard & Lefer 1997) |
| triangles | 185,276 |

Pipeline, all through core's own seams: `load_job_file` ->
`production_loadcase_from_job` -> `build_production_loadcase` ->
`analyze_fixed_design` -> cyclic-Jacobi eigen-decomposition -> RK4 trace ->
Jobard & Lefer spacing -> swept prisms.

**The load case is verified**: peak von Mises reproduces the production `analyze`
run at 0.01696337555 MPa. **The sweep is verified**: `--selftest` re-emits one
octet cell's element list through these primitives and compares against core's
`generate_lattice` triangle stream — byte-identical, 50 elements, 1432 triangles.
It refuses to write a coupon if that check fails.

### The number this coupon is really about

| unsupported horizontal run | mm |
|---|---|
| median | 3.41 |
| p90 | 7.67 |
| p99 | 22.17 |
| **longest** | **41.78** |

(An UPPER bound — it ignores support a crossing curve may give from below.)

69.9 % of traced arc lies beyond 45 degrees from vertical, consistent with the
65.13 % measured across the whole part.

### ★ TWO THINGS THIS COUPON ALREADY TAUGHT US, BEFORE ANY PLASTIC

1. **A single family is loose noodles.** Curves of one family never cross each
   other. The first build gave 26 disconnected strands, most starting in mid air.
   Flowing lattices are only a body once all three families and their connectors
   are present.
2. **Jobard & Lefer separation must be applied PER FAMILY.** Applied globally it
   also pushes DIFFERENT families apart, so they can never come within connector
   range: measured 6 connectors and 75 components. Per family it is 1,298
   connectors and 17 components. That is a real design constraint for any graded
   implementation and it is not obvious from the 1997 paper, which places one
   family.

Both are scoping findings that cost no print time.

### Honest caveats

* At `d_sep` 3.0 mm and 0.80 mm struts this is roughly **1.6 % relative density** —
  far below the certifiable band floor (5.05 %). That makes it a HARD printability
  case (sparser = longer unsupported runs), which is what we want, but it is not a
  density-representative lattice.
* 17 components, not 1. All are anchored to the slab, so the object stands and
  prints; it is not yet a single connected body. A production graded lattice would
  need that closed.

## 1b. ★ THE "FLOATING REGIONS" REPORT — DIAGNOSED

The slicer was right to complain, and it was NOT floating material.

**Measured on the soup file: 2,725 separate closed shells.** The shipped generator
emits a lattice as an INTERPENETRATING TRIANGLE SOUP — every strut is its own closed
prism, every node its own icosahedron, overlapping but never welded. A slicer that
analyses the MESH rather than the unioned solid sees 2,725 bodies and flags every
one that does not touch the plate.

**The material itself is connected.** A conservative rasterised flood-fill from the
base slab (0.15 mm voxels, 270x270x280) reaches every occupied voxel: **0 floating
voxels**.

Two wrong turns on the way to that, both worth recording:

1. My first guess was that the base anchors ENDED at the slab's top surface, a
   zero-overlap "kissing" contact. Wrong — and the fix (running them to z = 0) was
   applied anyway, since penetrating is correct regardless.
2. The first rasteriser tested distance-to-SEGMENT <= r, i.e. a CAPSULE, while
   `emit_strut` emits a FLAT-CAPPED PRISM. The phantom rounded caps reached r past
   each real endpoint and bridged gaps that were not there. **Caught by deliberately
   re-introducing the anchor defect and confirming the checker still said "clean" —
   a false negative on the exact bug it existed to detect.** The raster now uses flat
   caps and the n-gon INRADIUS, so it under-states material: if it says connected, it
   is connected.

### So there are two files

| file | size | shells | use |
|---|---|---|---|
| `graded_flow_coupon.stl` | 8.8 MB | 2,725 | EXACT production geometry (swept prisms + icosahedral nodes). Try this first — most slicers union an overlapping soup happily, and this is the format the shipped lattice already prints in. |
| `graded_flow_coupon_WELDED.stl` | 69 MB | **1, watertight** | Marching cubes over the same occupancy raster. One body, no warnings possible. Faceted at 0.15 mm; strut layout, diameters and spacing identical. Use if the soup upsets your slicer. |

### ★ A REAL FINDING FELL OUT OF THIS

Welding revealed **6 SEALED CAVITIES** — air pockets fully enclosed where struts
cross (8 to 328 triangles each, against an outer surface of 1,451,500). They are
harmless to print and are filled solid in the welded file. But a traced lattice
SEALING VOIDS is a genuine drainability problem, which this codebase already tracks
for the octet path, and it is a cost item for graded that no amount of angle
analysis would have surfaced.

## 2. `bridge_span_coupon.stl` — the calibration

Octet cells sweeping **span x diameter**, so the plate reports *what span is safe at
what strut diameter*. That is the yardstick the graded coupon's runs get measured
against. Row D is a positive control at his own run's cells and radii — geometry
already printed successfully. **If row D fails, fix the profile before reading
anything else.**

Note: it sweeps to 22.63 mm, which covers the graded coupon's p99 (22.17 mm) but
NOT its single longest run (41.78 mm). If everything passes, that outlier is the
one open question.

## 2b. The octet coupon is welded too — SAME diagnosis, DIFFERENT fix

Measured on the soup: **483 shells, of which 462 never touch the plate.** Same cause
as the graded coupon.

★ **THE FIX HAD TO DIFFER.** This plate holds **21 INTENTIONALLY SEPARATE specimens**,
so `keep_largest_component` over the whole plate — the fix used on the graded coupon,
which is one object — would have **deleted 20 of the 21**. Each specimen is therefore
rasterised and welded on its OWN, then concatenated: 21 watertight bodies, every one
sitting on the plate.

Two things this pass had to guard, both of which bit:

* **A thin strut can break up in the raster**, and `keep_largest_component` would then
  delete it silently — the specimen would print missing exactly the struts under test.
  Guarded by VOLUME, not by component count: a sealed cavity is an inward surface, so
  dropping it RAISES volume, while a lost strut LOWERS it. Measured: two specimens had
  extra components, at **+0.207 %** and **+1.183 %** volume — cavities only, nothing
  lost. The tool refuses to write if volume drops more than 1 %.
* **Vertex offsets on concatenation.** `TriangleMesh` is vertices + INDEX TRIPLES;
  appending triangles without rebasing their indices left every index pointing into
  another mesh's vertex array and segfaulted the writer. Fixed and noted because it
  fails loudly only by luck.

The raster pitch is tied to each specimen's THINNEST strut (so it never breaks up) and
capped by a memory budget — a 0.42 mm strut in a 32 mm cell wants a ~500^3 grid, a
gigabyte of doubles, so it coarsens until it fits and prints the pitch it used.

### Files — the welded plate is split by row

| file | size | contents |
|---|---|---|
| `bridge_span_coupon.stl` | 2.5 MB | the soup, 483 shells — production's exact format |
| `bridge_span_coupon_WELDED.stl` | 166 MB | all 21 welded bodies |
| `..._WELDED_rowD.stl` | 38 MB | ★ **the CONTROL — print this first** |
| `..._WELDED_rowA.stl` | 66 MB | d 0.42 mm, spans 1.41-22.63 mm |
| `..._WELDED_rowB.stl` | 42 MB | d 0.84 mm |
| `..._WELDED_rowC.stl` | 21 MB | d 1.68 mm |

Welded files are faceted at the raster pitch; strut layout, diameters and spans are
unchanged. They are large because thin struts meshed finely cost triangles — the soup
is 60x smaller and is what production actually emits, so try it first.

## Printing both

* PLA, same profile as the part, extrusion width **0.42 mm**
* **supports OFF** — the entire point
* do not let the slicer "repair" the mesh: it is an interpenetrating triangle soup
  by design, exactly as the shipped generator emits a lattice. Not watertight, does
  not need to be.

## What the result decides

* **Graded prints cleanly** -> the overhang constraint is not the gate. My 65 %
  figure is irrelevant to buildability, and the whole self-supporting-cell cost
  (4-16x anisotropy, tetragonal tensor, certification extension) leaves the scope.
  Graded is then gated on cost and on certification, not on printability.
* **Graded sags or fails at the long runs** -> the gate is a SPAN limit in mm, from
  coupon 2. Graded would then need spacing chosen so no run exceeds it — a real but
  bounded constraint, and a far cheaper fix than redesigning the cell.
* **Either way the octet is unaffected**: its spans on his part are 1.41-5.66 mm.
