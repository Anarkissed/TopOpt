# Role-combination matrix (H1a) — geometry, runs, receipts

Fixture: the committed `plate_bore.stl` (24 × 16 × 4 mm plate, central bore r = 3),
self-weight job at resolution 32, one rung (vf 0.6), 8 iterations, uniform octet
lattice cell 3 mm / strut r 0.45 mm (ρ ≈ 0.41, in-band). Every receipt is in
`receipts/`; the jobs are in `jobs/`; rerun with `reproduce.sh`.

## The three roles are three different instructions

| role | instruction | job carrier | in the certification | in the exported file |
|---|---|---|---|---|
| clearance | NO material | `loads.clearances` (existing, unchanged) | voxels are void (optimizer honoured FrozenVoid); printed bore-wall voxels stay solid, struts CLIPPED out of the keep-out, collar dresses the bore | nothing inside the keep-out; collar tori on the bore |
| include | material stays, LATTICED | `lattice.regions[role=include]` | only voxels inside the include union carry the octet tensor | struts only inside the include union; the REST of the part is a solid companion body |
| exclude | material stays, SOLID | `lattice.regions[role=exclude]` | voxels certified SOLID (never checked against the lattice band, never counted as lattice — H1c) | a closed solid companion body; struts of partial cells weld into it |

## Precedence (stated before implementation, tested per pair)

1. **clearance beats include and exclude** — no material means nothing to lattice.
   The keep-out is tested FIRST in `lattice_certification_mask`, struts are
   clipped out of it (roles never clip — solid welds to solid), and the solid
   companion never emits inside a keep-out (bore dressing is the collar's job,
   unchanged). Unit-tested: `test_lattice_boundary` §8; run-tested:
   `clearance_roles_loadcase.json`.
2. **exclude beats include** — the subtractive instruction wins, mirroring the
   existing clearance rasterizer precedence style (one precedence system, not a
   second one): solid is the conservative, always-certifiable state.
   Unit-tested (overlap voxel stays solid); run-tested below (the overlap run
   keeps MORE solid than include alone).
3. **include over optimizer void is a NO-OP** — lattice-include cannot conjure
   material. Counted and reported (`include_void_voxels`), never an error.

## The matrix (from the receipts)

Printed voxels in the accepted variant: 1836 (constant across runs — the roles
never change the OPTIMIZED design, only what the lattice does with it).

| run | regions | lattice_voxels | solid_region_voxels | include_void_voxels | conservation |
|---|---|---:|---:|---:|---|
| `uniform.json` | none | 1836 | (key absent — legacy receipt, byte-identical to parent) | (absent) | all printed voxels latticed |
| `exclude.json` | exclude bolt r3 @(8,0) | 1692 | 144 | 0 | 1692 + 144 = 1836 |
| `include.json` | include slab x∈[−12,2] | 1074 | 762 | 1434 | 1074 + 762 = 1836 |
| `include_exclude.json` | include slab + exclude bolt r2.5 @(−6,0) inside it | 900 | 936 | 1434 | 900 + 936 = 1836; exclude-in-include converted 174 voxels lattice→solid |
| `clearance_roles_loadcase.json` | all three roles (manual bolt clearance inside the exclude+include overlap) | see receipt | see receipt | see receipt | loadcase mode; the clearance keep-out subtracts before either role is consulted |

Reading the pairs off the table:
* include ∧ exclude → solid (900 < 1074; solid grew by exactly the overlap).
* include ∧ void → no-op, counted (1434 include-region voxels carry no material:
  the bore interior + the slab extent outside the part).
* exclude alone → solid (144 voxels), certified solid (`lattice_voxels` shrank by
  exactly 144), exported solid (`solid_region_triangles` > 0 in the receipt).
* clearance ∧ {include, exclude} → the loadcase receipt: the keep-out region
  contains no struts AND no companion body (clearance semantics intact).

## One predicate (H1b)

Include/exclude enter `LatticeBoundary` itself (activation via
`cell_may_overlap`'s Lipschitz proofs + membership in `lattice_certification_mask`
via the SAME `point_in_clearance_region` the keep-outs/rasterizer use). The
generator and the certification mask consume the one object;
`test_lattice_boundary` §8 asserts every masked voxel's owning cell is
generator-active and that a cell provably inside an exclude (or provably outside
every include) emits nothing.
