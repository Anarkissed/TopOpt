# Octet-truss generation cost — Phase 0 (harness only, read-only)

**Date:** 2026-07-26
**Scope:** octet truss only. Measurement harness in `core/tests/harness/`; grids
and geometry built programmatically (the sanctioned probe pattern). No production
code, fixtures, CMake, or defaults were touched.
**Status:** MEASURED. The swept-solid hypothesis is confirmed and streaming is a
structural win. One honest limit surfaced (O5 / BLOCKED-STOP) — a *clean
watertight manifold* is not achievable streaming-safe — but it does not block the
printing path. Details below.

---

## Headline (the ceiling verdict, named before measuring, now resolved)

PR 184 measured **18–24 M triangles, 0.5–1.2 GB STL** by extracting the octet as
an *isosurface of an occupancy field via marching cubes*. My pre-measurement
estimate for octet meshed as **swept solids** at 8 mm was **~230 k triangles**.

Measured, ~200 cm³ region, 8 mm cell, 100 % latticed:

| source | triangles @ 8 mm | vs PR 184 |
|---|---|---|
| PR 184 (marching cubes) | 18–24 M | 1× |
| **this harness (swept solids)** | **316 000** | **57–76× fewer** |
| my estimate | ~230 k | — |

**My estimate was far closer.** The true number (316 k) is ~1.4× my estimate; the
struts alone are 282 240 tris (≈ my 230 k ballpark) and the balance is the 33 760
tris of node-joint icosahedra. PR 184's figure is **two orders of magnitude
higher** than the swept-solid reality. The premise of this task holds: meshing
octet struts as capped prisms is dramatically cheaper than isosurfacing a field.

---

## What was built

`core/tests/harness/octet_gen_probe.cpp` — standalone, **not** wired into CTest.
It constructs an octet lattice over a programmatic ~200 cm³ region (a cube of edge
∛200000 ≈ 58.5 mm, `cells = round(edge / L)` per axis) and meshes each **strut as
a capped n-gon prism** (a swept solid) and each **node as an icosahedron joint** —
no isosurface, no field, no marching cubes.

- **Unit cell:** the full octet — **36 struts** (24 tetrahedron legs from each cube
  face-centre to the 4 corners of its face + 12 octahedron edges among the 6
  face-centres) and **14 nodes** (8 corners + 6 face-centres).
- **Per primitive:** capped 8-gon prism = **32 triangles** (16 wall + 16 cap);
  icosahedron node = **20 triangles**.
- **Dedup is cell-local** (integer half-lattice node keys + a min-side face
  ownership rule), so a strut/node shared between cells is emitted exactly once
  **without a global set** — this is what makes streaming O(1) in region size.
- **Two sinks:** an in-memory `TriangleMesh` (for topology checks and lib3mf) and
  a **streaming binary-STL writer** that flushes each cell's triangles and frees
  them.

Build/run (paths resolved in the scripts):
```bash
evidence/2026-07-26-octet-generation-cost/build_octet_probe.sh   # compiles + links lib3mf
evidence/2026-07-26-octet-generation-cost/run_octet_probe.sh     # runs the full matrix -> octet_cost.csv
```
Host: Apple M2 Pro (6 P-cores + 4 E-cores), 16 GB, macOS 26.5.1, Apple clang 21.
`getrusage(ru_maxrss)` is bytes on macOS; one process per case so the monotonic
high-water mark is that case's own peak.

---

## B2 — instrument self-check FIRST

One capped 8-gon prism, r = 1.0 mm, L = 10 mm:

- mesh signed volume = **28.284271 mm³**
- analytic n-gon prism = **28.284271 mm³** → **rel err 1.3 × 10⁻¹⁶** (machine precision)
- ideal round cylinder = 31.415927 mm³ → the 8-gon under-fills the true cylinder by **9.97 %** (tessellation deficit, expected; raise n-gon segments to close it)
- one prism is a **closed 2-manifold** (boundary = 0, non-manifold = 0)

**The generator is correct to > 3 digits.** Every count below is trustworthy.

---

## O1 — triangles + memory vs cell size (~200 cm³, 100 %, uniform)

| cell L | cells | triangles | strut / node tris | peak RSS (in-mem) | peak RSS (stream) | wall (gen) | STL bytes | 3MF bytes |
|---|---|---|---|---|---|---|---|---|
| 12 mm | 5³ = 125 | 118 920 | 105 600 / 13 320 | 22.9 MB | **2.7 MB** | 4 ms | 5.95 MB | — |
| 8 mm | 7³ = 343 | 316 000 | 282 240 / 33 760 | 48.5 MB | **2.7 MB** | 10 ms | 15.80 MB | 7.06 MB |
| 6 mm | 10³ = 1000 | 899 020 | 806 400 / 92 620 | 160.5 MB | **2.7 MB** | 40 ms | 44.95 MB | — |
| 4 mm | 15³ = 3375 | 2 976 320 | 2 678 400 / 297 920 | 591 MB | **2.7 MB** | 140 ms | 148.82 MB | — |

Triangle count scales as ~1/L³ (cell count). Even the finest realistic cell
(4 mm) is **~3 M triangles / 149 MB** — well inside PR 184's *lower* bound was
already 6× this, and its upper bound 8×. STL binary size is exactly
`84 + 50 × tris`. 3MF (below) is ~45 % of STL.

---

## O2 — region fraction (L = 4 mm, 15³ grid so fractions resolve)

The discrete grid cannot hit an arbitrary target exactly, so the *achieved*
fraction is reported. (At 8 mm the 7³ grid is too coarse — 50 % and 20 % both
round to 5³ cells — hence the finer grid here.)

| target | achieved | latticed cells | triangles | tris / cell | STL |
|---|---|---|---|---|---|
| 100 % | 100 % | 3375 | 2 976 320 | 881.9 | 148.8 MB |
| 50 % | 39.4 % | 1331 | 1 190 352 | 894.3 | 59.5 MB |
| 20 % | 21.6 % | 729 | 659 576 | 904.8 | 33.0 MB |

**Confirmed: cost scales linearly with latticed volume** (~890 tris/cell, flat).
The slight rise at low fraction is the boundary rule — cells on the lattice/solid
interface own their max-side struts, so a smaller region has proportionally more
boundary. Latticing the core and leaving a solid rim is a direct, predictable
saving.

---

## O3 — STREAMING (the memory objection)

Streaming generates cell-by-cell, writes each cell's triangles to the binary STL,
and frees them. Binary STL's header carries the triangle count **before** the
triangles; handled by **count-first-via-seek-back**: write a zero placeholder
count, stream all facets, then `seekp(80)` and patch the real count at close.
(This is why streaming needs a seekable file, not a pipe.)

Peak RSS, 100 % uniform, across the whole cell-size band and one extreme case:

| cell L | triangles | STL output | peak RSS streaming |
|---|---|---|---|
| 12 mm | 118 920 | 5.95 MB | 2.69 MB |
| 8 mm | 316 000 | 15.80 MB | 2.67 MB |
| 6 mm | 899 020 | 44.95 MB | 2.66 MB |
| 4 mm | 2 976 320 | 148.82 MB | 2.69 MB |
| **2 mm** | **21 107 496** | **1055 MB** | **2.69 MB** |

**Peak RSS is FLAT at ~2.7 MB while output spans 6 MB → 1.06 GB (176×).** The
L = 4 mm case is **591 MB in-memory vs 2.7 MB streaming — a 220× reduction.**

> **The memory objection is structurally dead, not merely reduced.** Peak RAM is
> independent of output size. Even at PR 184's own 18–24 M-triangle scale (the
> 2 mm / 21 M-tri row), generation streams at < 3 MB.

Caveat named honestly: **3MF export is *not* streaming-safe.** lib3mf builds the
whole mesh object in memory before serializing, so writing 3MF at L = 8 mm peaked
at **87.9 MB vs 48.5 MB** for the in-memory STL path (and cannot be bounded).
STL is the memory-safe export; 3MF forfeits the streaming win.

---

## O4 — graded vs uniform

Strut radius graded by a smootherstep "stress" field (±40 % about the uniform
r = 0.10·L), vs constant radius. Same region, same tessellation:

| cell L | uniform tris | graded tris | uniform diam | graded diam (min–max) |
|---|---|---|---|---|
| 8 mm | 316 000 | **316 000** | 1.60 mm | 0.96 – 2.24 mm |
| 4 mm | 2 976 320 | **2 976 320** | 0.80 mm | 0.48 – 1.12 mm |

**Triangle count is identical.** Grading moves vertices, not counts, under a
fixed angular tessellation (8-gon). **Grading — the whole point of generating
geometry rather than using a slicer modifier — is free in mesh cost.**

Caveat: this holds *because* the angular segment count is fixed. If segments were
scaled to strut radius to hold facet edge-length constant, graded and uniform
would diverge. That adaptive choice was **not** made here; if it is ever wanted,
this row must be re-measured.

---

## O5 — watertightness at the shell  ⚠ (the real limit — see BLOCKED-STOP)

2×2×2 octet block, L = 8 mm, 8940 triangles, welded by coordinate (exactly what
an STL reader does on re-import):

- boundary edges = **0**
- **non-manifold edges = 2238** (edges shared by > 2 faces)
- connected components = 78
- `check_watertight` = **FAIL**
- self-intersection scan around one interior node: **18 216 intersecting triangle
  pairs** of 5.71 M tested (3380 local triangles)

Each prism and each node, welded in isolation, is a closed 2-manifold (B2). But
the **union is a self-intersecting, non-manifold soup**: struts and node spheres
interpenetrate at every joint. The edge-manifold check alone cannot see
interpenetration — the intersection scan is what proves it.

**A lattice that meshes cheaply but is not a clean solid has not, by itself,
solved the export.** What "solid" means depends on the consumer:

- **For FDM printing:** slicers (Bambu Studio / OrcaSlicer / Cura / PrusaSlicer)
  union overlapping *positive* solids at slice time via the fill rule. A
  self-intersecting overlap soup **slices correctly** — this is the normal way
  lattice STLs are printed. Emitting the lattice soup **and the part shell** as
  solids in one file and letting the slicer union them is **streaming-safe and
  needs no boolean.** (Owed: a real print, see O6.)
- **For a clean watertight B-rep / mesh-boolean with the shell / mesh-FEA:** a
  true 2-manifold requires a **global boolean union** or a **field-based remesh**.
  Both need the whole mesh (or the whole field) resident — which reintroduces the
  PR-184-scale memory cost and **defeats streaming.**

---

## O6 — printability, stated not assumed

Octet strut angle from vertical (z), one cell (angle 0 = self-supporting, 90 =
horizontal bridge):

| angle from vertical | struts | share |
|---|---|---|
| 45° | 24 | 67 % |
| 90° | 12 | 33 % |

- **There are no vertical struts.** The lattice is entirely 45° legs and
  horizontal members.
- 45° is the *borderline* FDM self-support limit; **33 % are 90° horizontal
  bridges** that categorically need support or bridging.
- Minimum strut diameter at the lowest graded density: **0.96 mm** (8 mm cell) /
  **0.48 mm** (4 mm cell) — the 0.48 mm case is below a 0.4 mm nozzle's reliable
  two-perimeter wall.

> **This is not a printability verdict.** These are geometry numbers. Whether a
> graded octet actually prints self-supported on a given FDM machine **owes a real
> print test** and cannot be concluded from angles alone.

---

## Bars

- **B1** — every row of `octet_cost.csv` carries cell size, target + achieved
  region fraction, graded/uniform, triangle count (+ strut/node split), peak RSS,
  wall time, STL bytes, 3MF bytes, min/max strut diameter. ✔
- **B2** — one unit strut vs analytic prism volume: rel err 1.3 × 10⁻¹⁶. ✔
- **B3 — determinism:**
  - streaming STL: **byte-identical** across two runs ✔
  - in-memory STL: **byte-identical** across two runs ✔
  - streaming vs in-memory STL: differ **only in the 80-byte header text**;
    all 15.8 M geometry bytes are **identical** (the streaming writer is a
    byte-exact drop-in for the production writer). ✔
  - **3MF: NOT byte-reproducible** — lib3mf embeds a nondeterministic UUID/
    timestamp, so two runs differ (though geometrically identical). Flagged, not
    a generator defect.
- **B4 — largest case within 8 GB peak RSS on the 6-P-core Mac:** with streaming,
  peak is flat at ~2.7 MB, so **8 GB is never the binding constraint** — the limit
  is disk and time. Largest measured: **L = 2 mm, 21.1 M triangles, 1.06 GB STL,
  wall 1.40 s at 2.7 MB peak.** (The in-memory path, by contrast, caps near
  8 GB / ~197 B-per-triangle ≈ 40 M triangles — but there is no reason to use it
  for export.)

---

## BLOCKED-STOP resolution

The task named two things that would genuinely close this:

1. **Can octet generation be made streaming-safe?** → **YES.** Peak RAM is flat at
   ~2.7 MB independent of output size, proven from 6 MB to 1 GB of output (O3).
   Header count handled by seek-back.
2. **Can the union with the part shell be made watertight without a full
   in-memory boolean?** → **NO, not as a clean 2-manifold.** The swept-solid union
   is inherently self-intersecting at nodes (O5); a true watertight manifold needs
   a global boolean or field remesh, which is not streaming-safe.

**But (2) is not a hard stop for the feature.** FDM printing does not require a
watertight manifold — slicers union overlapping positive solids directly, at zero
extra memory. The streaming path (lattice soup + shell → one file → slicer union)
is viable and cheap. The manifold requirement only bites if a *downstream consumer
other than the slicer* demands clean topology.

**Measured close:** cheap + streaming octet generation is real and validated. The
single open question is not memory or triangle count — it is whether the target
export must be a clean manifold. If "hand it to the slicer" is acceptable, this is
done. If a watertight B-rep is required, the boolean/remesh cost (and its loss of
streaming) is the price, and that is a Phase-1 decision, not a Phase-0 blocker.

---

## Recommendation for Phase 1 (not acted on here)

- Emit the lattice as a **streamed overlap soup + the solid shell**, targeting the
  slicer-union print path; verify with an actual sliced preview and a print.
- Decide explicitly whether any consumer needs a clean manifold. If yes, scope the
  boolean/remesh separately and accept it is not streaming-safe.
- If facet-size-consistent grading is wanted, re-measure O4 with radius-scaled
  angular segments.
- The 0.48 mm min diameter at 4 mm / low graded density is below a 0.4 mm nozzle's
  practical wall — clamp graded r to a printable floor.

## Forbidden-scope confirmation

Touched only `core/tests/harness/`, `docs/handoffs/`, and
`evidence/2026-07-26-octet-generation-cost/`. No `core/src/`, no `/app/`, no
`fixtures/`, no CMake, no `materials.json`, no `ARCHITECTURE.md`/`DECISIONS.md`/
ROADMAP, no production default. The harness is standalone and not wired into
CTest. lib3mf is linked from the sibling `lib3mf-macos-build` worktree's vcpkg
tree (handoff 2026-07-24-3mf-enable); if absent, the probe still builds STL-only.

## Evidence

`evidence/2026-07-26-octet-generation-cost/`
- `octet_gen_probe` source lives at `core/tests/harness/octet_gen_probe.cpp`
- `build_octet_probe.sh`, `run_octet_probe.sh` — build + full matrix
- `octet_cost.csv` — every measured row (B1)
- `full_run.txt` — complete transcript
- `o_selfcheck.txt` (B2), `o5_watertight.txt` (O5), `o6_angles.txt` (O6)
- `b3_determinism.txt` — determinism results
- `files/octet_L8_f100_uniform.3mf` — a real 3MF export (7.06 MB, 316 k tris);
  the 15.8 MB STL sample is reproducible from the script and not committed.
