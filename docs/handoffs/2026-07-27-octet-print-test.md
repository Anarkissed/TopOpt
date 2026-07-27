# Octet print-test block — generated, exported, and SLICED

Date: 2026-07-27
Evidence: `evidence/2026-07-27-octet-print-test/`
Predecessor: `docs/handoffs/2026-07-26-octet-generation-cost.md` (PR 201), which
settled octet *cost* and refused to guess at two gates — O5 (the output is an
interpenetrating soup) and O6 (no vertical struts). This task takes those two
gates to a real slicer.

**Scope note.** Nothing here touches `core/src/`, `/app/`, `fixtures/`, or any
production default. The generator is a standalone measurement harness
(`octet_block_gen.cpp`), a trimmed sibling of PR 201's cost probe pinned to a
concrete 40 mm block. It reuses that probe's exact strut algorithm and radius
formula, so the graded block reproduces PR 201's measured 0.96–2.24 mm diameter
range byte-for-byte in intent.

---

## TL;DR

- **Two blocks delivered**, each as STL **and** 3MF, in `files/`: a uniform
  40 mm octet block (constant Ø 1.60 mm strut) and a graded one (Ø **0.96–2.24 mm**
  along z — PR 201's exact range, now in a real file).
- **Both slice** to complete G-code on BambuStudio (A1, 0.4 mm nozzle, Generic
  PLA, 0.20 mm layer). Printable `*_sliced.3mf` and the full toolpaths
  (`*.gcode.gz`) are committed under `slice/`.
- **T1 — the slicer did NOT accept the mesh as generated.** Two things happened
  that a clean solid would not have needed: (a) BambuStudio ran an automatic
  `TriangleMesh::repair()` on load, and (b) under its **default Arachne wall
  generator the slice ABORTS** with a negative-extrusion-spacing error caused by
  the self-intersecting strut slivers. It only completes after forcing the
  **classic** wall generator. **The feature needs a boolean-union step** before
  it can be called sliceable-as-is. See `slice/arachne_default_FAILS.txt`.
- **T2 — thinnest surviving strut:** the Ø 0.96 mm graded struts *do* receive
  real outer-wall beads (0.40/0.42 mm) at the bottom of the block, so no whole
  strut is dropped. But the classic generator also lays sub-nozzle **gap-fill
  beads down to ~0.10 mm** (uniform) / **~0.095 mm** (graded) at strut tips and
  grazing slices — widths a 0.4 mm nozzle cannot lay reliably. "Survives as a
  toolpath" ≠ "prints as a bead."
- **T3 — horizontal struts are BRIDGED**, not supported and not dropped. Support
  is off (`enable_support = 0`); the slicer tags the 90° struts as `Bridge` and
  the 45° legs partly as `Overhang wall`, spanning them in mid-air between nodes.
- **T4 — no printability claim.** A sliced result and a printable file exist. The
  physical FDM print is the maintainer's to run and judge. What to watch for is
  listed at the bottom.

---

## Deliverables (`evidence/2026-07-27-octet-print-test/`)

| file | what |
|---|---|
| `files/octet_uniform_40mm.stl` / `.3mf` | uniform block, 40³ mm, 5×5×5 cells @ 8 mm, Ø 1.60 mm |
| `files/octet_graded_40mm.stl` / `.3mf`  | graded block, Ø 0.96–2.24 mm smootherstep along z |
| `octet_block_gen.cpp`, `build_octet_block.sh` | standalone generator + build (reuses core mesh/stl/threemf) |
| `geometry_uniform.txt`, `geometry_graded.txt` | manifold / component / self-intersection / angle report on the real 40 mm blocks |
| `run_slice.sh` | drives BambuStudio headless; writes the classic-wall process override |
| `slice/uniform_sliced.3mf`, `slice/graded_sliced.3mf` | **printable** sliced projects (open in BambuStudio → send) |
| `slice/octet_*_40mm.gcode.gz` | full toolpaths (gzipped; 26 MB each raw) |
| `slice/*_result.json`, `slice/process_octet.json` | slicer result records + the process override used |
| `slice/arachne_default_FAILS.txt` | proof the default (Arachne) wall generator aborts |
| `slice/gcode_analysis.txt`, `analyze_gcode.py` | per-feature / per-width breakdown |
| `determinism.txt` | generator is byte-deterministic; committed == regenerated |

Both blocks are the **bare lattice** — no solid skin, no base plate — exactly the
geometry PR 201 measured, so the slice tests the soup and not a solid shell.
Bounding boxes: uniform 41.60³ mm, graded 42.24 × 42.24 × 41.60 mm (the extra is
the icosahedral node radius protruding past the 40 mm cell grid). "Roughly 40 mm"
as asked.

---

## Geometry report (on the actual 40 mm blocks)

Confirms PR 201's O5/O6 on the delivered files, not just the cost cube:

```
                              UNIFORM        GRADED
raw STL triangles             118,920        118,920
struts / nodes                3300 / 666     3300 / 666
strut diameter (mm)           1.600          0.960 .. 2.240
welded verts                  36,198         49,078
boundary_edges                0              0
non_manifold_edges            41,316         17,732      (edges shared by >2 faces)
connected components          699            897
check_watertight              FAIL           FAIL
self-intersecting tri pairs   18,216         19,104      (one interior node, bounded scan)
```

Strut angle from vertical (per reference cell, identical every cell):
**67 % at 45°** (borderline FDM self-support), **33 % at 90°** (horizontal
bridges). **Zero vertical struts.** This is O6, verbatim, on the shipped block.

The mesh is a *soup*: each prism and node is individually a closed 2-manifold, but
emitted together they weld into thousands of non-manifold junctions and hundreds
of disconnected components, and they interpenetrate where struts meet a node.

---

## Slicing

Slicer: **BambuStudio 02.07.01.62**, driven headless
(`BambuStudio --slice 0 --load-settings … --load-filaments …`). Machine **Bambu
Lab A1, 0.4 mm nozzle**; filament **Generic PLA**; process **0.20 mm Standard**,
2 walls, 20 % sparse infill, supports off — all stock **except** the wall
generator (see T1). Reproduce with `run_slice.sh`.

### Does it load the soup? Mesh validity?

Yes, it loads — and immediately runs `TriangleMesh::repair()` (admesh-derived:
unifies normals, welds vertices, closes small gaps, drops degenerate facets).
Triangle count is **unchanged at 118,920** through repair: BambuStudio does **not**
boolean-union the overlaps away. It resolves the self-intersections at the **2D
layer level** — each layer is the union of the individually-wound primitive
cross-sections under the slicer's fill rule — which is *why* a consistently-wound
soup can still slice. The repair pass is silent about counts (no per-facet stats
in CLI), but it runs on every load; a clean watertight solid would still be
repaired-checked, so its mere presence is not the finding — the **Arachne abort
below is.**

### T1 — accepted as generated? **No.**

Under BambuStudio's **default Arachne** (variable-width) wall generator, the slice
**aborts**:

```
[error] rounded_rectangle_extrusion_spacing negative extrusion : width 0.0429204 height 0.2
[error] found slicing or export error for partplate 1
Flow::spacing() produced negative spacing. Did you set some extrusion width too small?
```

Arachne walks the medial axis of each perimeter and assigns a variable bead
width. Where struts overlap, the soup's outline has ~0.04 mm slivers; Arachne
tries to fit a bead there, the flow spacing goes negative, and the plate fails.
Pinning `outer_wall_line_width` alone does **not** fix it (tested — still aborts).
Forcing **`wall_generator = classic`** (fixed-width offsets, which tolerate the
slivers) is what makes both blocks slice. That override is a workaround, not a
fix. **The honest conclusion: the mesh as generated is not robustly sliceable;
the feature needs a boolean-union (watertight-manifold) step so the default
Arachne path — what most users run — succeeds.**

### Slice results (classic walls)

```
                       UNIFORM         GRADED
return_code            0 (Success)     0 (Success)
slice time (engine)    7.84 s          8.69 s
wall time (load+slice+export)  ~10.6 s ~10.9 s
peak RSS               1.09 GB         1.10 GB
layers (0.20 mm)       208             208
extruding moves        675,234         661,938
G-code size (raw)      26.7 MB         26.2 MB
G-code (gzipped)       3.96 MB         3.80 MB
sliced 3MF             4.72 MB         4.59 MB
est. print time        ~8.4 h          ~8.7 h   (slicer estimate)
filament mass          n/a (CLI)       n/a (CLI)
```

`filament_usage_g = 0` in both result.json is a **headless-CLI reporting gap** —
the Generic-PLA preset does not bind a `filament_id` from the command line, so the
mass/one-line summary is blank. The toolpaths themselves are complete (26 MB of
extrusion moves); only the summary mass is missing. Open the `*_sliced.3mf` in the
BambuStudio GUI to get a real mass/time estimate.

### T2 — thinnest strut that survives at a 0.4 mm nozzle

The graded block puts its thinnest struts (Ø 0.96 mm) at the bottom. The bottom
layers (z = 0.2, 0.4 mm) extrude at **0.40 / 0.42 mm outer- and inner-wall
widths** — i.e. the 0.96 mm struts get genuine perimeter beads; **no whole strut
is dropped.** But the classic generator fills the leftover slivers and strut tips
with **gap-fill beads far below the nozzle**: the graded G-code contains extrusion
widths down to **0.095 mm** (uniform: 0.110 mm). A 0.4 mm nozzle cannot lay a
0.1 mm bead — those moves will under-extrude or smear. So:

- **Ø 0.96 mm → 2.24 mm struts all receive walls (survive as toolpaths).**
- **~0.1 mm gap-fill at tips/grazing slices is below the reliable minimum** for a
  0.4 mm nozzle. This is the sub-nozzle tail 201 warned about, made concrete.

Full width histograms: `slice/gcode_analysis.txt`.

### T3 — what the slicer does with the horizontal struts

**Bridged.** Support is off (`enable_support = 0`; no `Support` feature appears in
either G-code). The slicer tags horizontal (90°) struts as **`Bridge`** and the
45° legs partly as **`Overhang wall`**, extruding them in mid-air anchored on the
two end nodes. Feature move counts:

```
                    UNIFORM    GRADED
Bridge              9,106      1,831
Overhang wall       2,020      2,616
Support             0          0
```

(The graded block bridges less and solid-infills more because its thick top struts
present larger solid cross-sections.) Whether those unsupported mid-air bridges
survive on the plate is precisely what the physical print decides.

### T4 — no printability claim

A sliced result exists and `slice/*_sliced.3mf` are files the maintainer can open
and print. **This is not a printability verdict.** The print is his to run and
judge.

---

## What to look for on the physical print (owed to the maintainer)

1. **Slice under default Arachne in the GUI** and confirm it reproduces the
   negative-spacing abort — that is the load-bearing finding driving the
   boolean-union requirement.
2. **The 0.96 mm struts and their tips** — do the sub-0.1 mm gap-fill beads
   under-extrude, blob, or tear? That sets the real minimum graded diameter.
3. **The horizontal `Bridge` struts** — do the ~5.7 mm mid-air spans sag or fall,
   given there is nothing beneath them inside the lattice?
4. **The 45° `Overhang wall` legs** — surface quality at the borderline limit.
5. **Node blobs** — the interpenetrating icosahedral joints overlap; watch for
   over-extrusion / oozing where several struts meet.

## Recommendation for the feature

Add a **boolean-union / remesh-to-watertight** step to the octet generator's
export path so the output is a single closed manifold. That removes the repair
dependency and — the real payoff — lets the **default Arachne** wall path slice it,
which is what end users run. Until then, octet export ships a soup that only
slices under a non-default wall generator, and its 45°/90° strut geometry still
owes a real FDM print test.
