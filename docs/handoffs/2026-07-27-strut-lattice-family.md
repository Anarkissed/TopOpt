# Strut lattice family — a segment-table generator (Phase 0, measurement only)

**Date:** 2026-07-27
**Status:** measurement / evidence only. **No production wiring, no UI, no core
changes** (bar S5). Standalone harness, not built into CTest.
**Evidence:** `evidence/2026-07-27-strut-lattice-family/`
**Predecessors:** PR-201 (`octet-truss-cost-phase-0`, the swept-solid octet
generator this generalises) and its print-test sibling
(`2026-07-27-octet-print-test`).

## Thesis (from the task)

> PR-201's generator lays capped prisms along line SEGMENTS. Any lattice
> expressible as a per-unit-cell segment list is therefore a TABLE ENTRY, not new
> machinery.

That is exactly what this is. PR-201's octet-specific `ref_struts()` is replaced
by a **table of per-unit-cell segment lists**; the strut/node/weld/stream
machinery is byte-for-byte the same. Ten lattices ship as table entries:

**sc, bcc, ★bccz, fcc, fccz, octet, diamond, kelvin (truncated octahedron),
rhombic dodecahedron, re-entrant/auxetic.**

Octet is included as a **table entry too**, purely as a cross-check: driven
through the generic table machinery it reproduces PR-201's committed octet
numbers to the byte (see below). Weaire-Phelan was attempted and **does not fit**
the per-cell segment model — verdict at the end.

## The one piece of new machinery: canonical-cell ownership

Every lattice is `(S, canonical struts, canonical nodes)`. `S` is an integer
denominator so node coordinates are integers in units of `L/S` and all arithmetic
is exact (sc/bcc/fcc: S=2; diamond/kelvin/rhombic/reentrant: S=4).

A strut is **canonical to the cell whose half-open box `[0,S)³` contains its
midpoint** — so every strut of the infinite tiling belongs to exactly one cell.
That single rule replaces PR-201's hand-written `owns_leg` / node-owner logic and
generalises to *any* topology:

- **Dedup with no global set.** Each primitive is emitted by its owner cell only.
  Peak RSS is independent of block size → the streaming bar (S3) holds by
  construction, not by luck.
- **Clean 40 mm blocks.** The generator sweeps cells `[0,n]` inclusive and keeps a
  primitive only when it lies **entirely inside** `[0,W]³`. Cell 0 supplies the
  low-face in-plane struts, the `+`ghost cell `n` supplies the high-face ones
  (their endpoints sit on `z=W`, inside the closed box); boundary straddlers are
  cut — the natural termination of a lattice block. Nothing pokes past 40 mm
  except the strut *radius* at boundary nodes (identical to PR-201's octet block).

`emit_strut` (capped 8-gon prism, 32 tris), `emit_node` (icosahedron, 20 tris),
`weld`, `StreamStlWriter`, and the self-intersection scan are copied unchanged
from `octet_gen_probe.cpp`.

## Octet cross-check (the driver is faithful)

Driven as a generic table entry, octet reproduces PR-201 **exactly**:

| quantity (7³ @ 8 mm) | PR-201 `octet_cost.csv` | this generic driver |
|---|---|---|
| triangles | 316000 | **316000** |
| strut / node tris | 282240 / 33760 | **282240 / 33760** |
| struts / nodes | 8820 / 1688 | **8820 / 1688** |
| STL bytes | 15800084 | **15800084** |
| streaming peak RSS | 2.67 MB | **2.69 MB** |

The 40 mm octet block is also 118920 tris / 5946084 STL bytes — the same size as
PR-201's `octet_uniform_40mm.stl`. (Not byte-identical: the STL header string
differs and triangles emit in a different order. Geometry is equivalent.)

## The family, at an 8 mm cell over PR-201's reference region (7³ ≈ 200 cm³)

Streaming numbers (the directly-comparable O3 path). Full data in
`reference_region.csv`, `angles.txt`, `density.txt`.

| lattice | struts /cell | triangles | peak RSS (stream) | wall (stream) | STL bytes | angle-from-vertical | 90° horiz | ρ ≈ K·(r/L)² |
|---|---:|---:|---:|---:|---:|---|---:|---:|
| sc | 3 | 53 248 | 2.69 MB | 8 ms | 2 662 484 | 0°×1, 90°×2 | **67 %** | 8.49 |
| bcc | 8 | 104 908 | 2.70 MB | 11 ms | 5 245 484 | 54.7°×8 | 0 % | 19.60 |
| ★bccz | 9 | 119 244 | 2.69 MB | 10 ms | 5 962 284 | 0°×1, 54.7°×8 | 0 % | 22.42 |
| fcc | 12 | 184 288 | 2.66 MB | 19 ms | 9 214 484 | 45°×8, 90°×4 | 33 % | 24.00 |
| fccz | 13 | 198 624 | 2.70 MB | 19 ms | 9 931 284 | 0°×1, 45°×8, 90°×4 | 31 % | 26.83 |
| octet | 24 | 316 000 | 2.69 MB | 37 ms | 15 800 084 | 45°×16, 90°×8 | 33 % | 48.00 |
| diamond | 16 | 236 816 | 2.72 MB | 21 ms | 11 840 884 | 54.7°×16 | 0 % | 19.60 |
| kelvin | 24 | 376 320 | 2.69 MB | 36 ms | 18 816 084 | 45°×16, 90°×8 | 33 % | 24.00 |
| rhombic | 32 | 439 852 | 2.70 MB | 45 ms | 21 992 684 | 54.7°×32 | 0 % | 39.19 |
| reentrant | 17 | 227 632 | 2.69 MB | 20 ms | 11 381 684 | 0°×1, 50°×16 | 0 % | 36.77 |

Peak RSS is flat at ≈2.7 MB across a 30× triangle spread — the swept-solid + stream
approach carries the whole family, not just octet.

## The four required reports

### 1. Triangle count / peak RSS / wall / file size — table above and `reference_region.csv`

All at 8 mm over PR-201's 7³ reference region, streaming and in-memory rows both
recorded, so they are directly comparable to `octet_cost.csv`.

### 2. Strut angle from vertical + horizontal-90° count — the printability signal

Full histograms in `angles.txt`. The families separate cleanly:

- **All-diagonal (no verticals, no horizontals):** bcc, diamond (54.7°), rhombic
  (54.7°). Every strut sits above the 45° self-support line — *no* 90° bridges,
  but also *no* self-supporting columns. Aesthetically the "pure truss" look.
- **Octet-class (no verticals, 33 % horizontal):** fcc, octet, **kelvin**. This is
  precisely PR-201's octet signal — *no vertical struts, one third horizontal
  90° bridges* — and octet **printed anyway**. Kelvin and fcc carry the identical
  angle profile, so the octet print result is direct evidence for them.
- **sc:** the worst case — 67 % horizontal, only 33 % vertical. Two of every three
  struts are 90° bridges.
- **★The Z-variants quantify what a vertical strut buys.** bcc has **0 %**
  vertical struts; bccz adds exactly the columns bcc lacks — 1 of 9 struts at 0°
  (11 %), for +14 % relative density (K 19.60→22.42) and −13 % more triangles.
  fcc→fccz is the same trade: +1 vertical (8 %), K 24.0→26.83. That is the whole
  reason the Z-families exist, now measured: a small density/geometry cost to buy
  self-supporting columns that the base cell has none of.
- **reentrant:** 1 vertical + 16 inclined at 50°, 0 horizontal — self-supporting
  by angle, with the concave-wall geometry that gives it its auxetic character.

*None of these is a printability verdict.* The physical FDM prints are owed to the
maintainer, exactly as for octet. The angle table says which are *likely* to need
support (anything with 90° bridges: sc, fcc, fccz, octet, kelvin) and which are
borderline-but-proven (the octet-class, given the octet print).

### 3. Relative density at a given strut radius — the grading mapping

`density.txt`. For round/n-gon struts in the low-density limit,
**ρ ≈ K·(r/L)²**, where `K = (n-gon area at r=1)·(total canonical strut length per
cell / L)`. The measured mesh density (sum of per-prism volumes over one cell)
matches the analytic ρ to machine precision (rel err ≤ 1.5e-15) for all ten, so
the mapping is exact in that limit and directly invertible for grading:
**r(ρ) = L·√(ρ/K)**. K spans 8.5 (sc, sparsest) → 48 (octet, densest), i.e. at a
fixed r/L octet is ≈5.7× denser than sc — the knob the maintainer grades along.
(Node blobs and strut overlap add a small positive correction the low-density
limit omits; it shrinks as r/L falls, which is the grading regime.)

### 4. Union with a part shell — same as octet

`union_character.txt`. Welded by coordinate, every block is a **self-intersecting
soup**: individually-closed prisms and node icosahedra that **interpenetrate**
(boundary/non-manifold edges, many components, hundreds–thousands of intersecting
triangle pairs at each interior node). This is byte-for-byte the octet situation
from PR-201 — the union step is owed, and the slicer accepts the soup as-is (the
octet print test already sliced and printed exactly this kind of soup). So **yes:
all nine new topologies union with a part shell the same way octet does.**

## Bars

| bar | result | evidence |
|---|---|---|
| **S1** one-cell mesh vs analytic strut volume, ≥3 digits | **PASS** all 10 (rel err ≤ 5e-15) | `s1_selfcheck.txt` |
| **S2** same inputs twice → byte-identical | **PASS** all 10 (md5 match) | `s2_determinism.txt` |
| **S3** peak RSS flat in output size | **PASS** all 10 (≈2.7 MB across 3→11 cells, tris ~n³) | `s3_streamscan.txt` |
| **S4** one 40 mm block each as STL + 3MF | **DONE** 10 × (STL + 3MF), valid 3MF zips | `files/*_40mm.{stl,3mf}` |
| **S5** no production wiring / UI / core changes | **HELD** standalone harness only | this dir; `git show --stat` |

## Weaire-Phelan — attempted, does not fit (not forced)

`weaire_phelan.txt`. WP (the A15 / Pm-3n foam) *is* periodic in a single cubic
cell, so it looks like another table row — but its strut skeleton is the **Voronoi
tessellation of the 8-seed A15 point set** (2a + 6c Wyckoff). The edges are
4-valent Plateau borders at positions outside the corner/edge/face/body-centre
node dictionary the other nine share. Producing that edge list needs the
**seed-Voronoi step the task puts out of scope** ("Voronoi … needs seed generation
and robust thickening"); the only alternative is hand-transcribing an arbitrary
straight-edge approximation of relaxed, slightly-curved borders. Either way it is
new machinery, not a table entry.

**Verdict:** attempted; does not fit the current per-cell segment model. It
belongs with the out-of-scope Voronoi generator, alongside the TPMS sheets
(isosurface generator). Said plainly, as the task asked.

## Reproduce

```bash
cd evidence/2026-07-27-strut-lattice-family
bash run_strut_lattice.sh      # builds + regenerates every txt/csv and the 10 blocks
```

`build_strut_lattice.sh` compiles `strut_lattice_gen.cpp` against the OCCT/Eigen-
free core sources (`mesh.cpp`, `stl.cpp`, lib3mf-gated `threemf.cpp`) and links
lib3mf from this worktree's vcpkg tree (2.5.0#1, == CI). Without lib3mf it still
builds and writes STL only.

## What is NOT claimed

- **No printability verdict.** Angles flag risk; the FDM prints are owed, as for
  octet. The 40 mm blocks exist so the maintainer can slice and print them.
- **No mechanics.** "Auxetic", "stiff", "compliant" are not measured here — this
  is geometry and generation cost only. Relative density is the only physical
  quantity, and only in the low-density limit.
- **No union.** The blocks are interpenetrating soup by design; the boolean union
  (or slicer tolerance) is owed, same as octet.
- **Out of scope, unchanged:** Voronoi (incl. Weaire-Phelan) and the TPMS sheets.
