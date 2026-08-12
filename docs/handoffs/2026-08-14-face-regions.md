# 2026-08-14 — face regions: union, split, grid, and a real selection model

Evidence: `evidence/2026-08-14-face-regions/`
Branch base: `9e96beb`

> **"faces tend to be random and not really representative of the structure
> itself — regardless of what file we import."**
> **"select all chamfers and fillets, combine them all, then pattern split
> them… I think we need to be able to actually UNION faces not just group them."**

He is right, and his own `loadcase.json` proves it: one load group carrying
**22 face ids**, and face protections ranging from **16 voxels** (faces 41-47,
seven of them) to **10,554** (face 16). This branch gives a face a second
identity — a REGION — that can be unioned, split and graded, while the CAD face
underneath never moves.

---

## §0 — THE FOUR ANSWERS, ONE LINE EACH

**Did CAD error move with a union and a grid split applied? NO.** On
M2_verticalStand.step at resolution 128, with a 24-face union and a 10×5 grid
split resolved: `triangle_face` unchanged, every analytic surface identical bit
for bit, CAD attribution identical per vertex, worst face flatness
**1.2124389394e-15 mm** and worst bore out-of-roundness **3.59712259979e-14 mm**
— the same digits before and after. (`r2_r3_his_part.txt` §4.)

**The tap count for his 22-face load group: 22 → 9 → 2.** Today 22 taps. With
expand-to-**same-kind** (a connected run of one surface class) **9**. With a
filter and one Combine, **2**. ★ And a correction to the task's own priority:
expand-to-**coplanar** gives **22** — no improvement at all on his part, because
a B-rep already merges coplanar surface into one face. §2(d) called it "the
cheapest win in the whole task"; on a STEP part it is a **no-op**.

**What the fillet/chamfer heuristic matched: 24 of 78 faces**, at a threshold of
0.25× the median face area (41.95 mm²). The naive `kind == "other"` reading —
the one §2 warns against — matched 30, but **missed 13** of the blend faces and
**over-caught 19** faces the blend filter rejects. The correction is not
theoretical; it is 13 and 19 on his own bracket.

**Do unions survive a re-import? YES, and a CAD edit is reported, not absorbed.**
Simulating a feature deletion (one face removed, every id above it shifted down):
the union's filter matched 24 at authoring and 23 after, `drift -1`, carried on
the resolved region and printed by the run. ★ **This is also where the branch's
one real defect was caught** — see §1(d).

---

## §1 — THE TWO LAYERS

    LAYER 1   voxel -> ORIGINAL CAD FACE ID   projection, the CAD/cut classifier,
              (StepModel::triangle_face,      every StepFaceInfo lookup.
               StepModel::faces)              ★ NOTHING IN THIS BRANCH WRITES IT.

    LAYER 2   voxel -> REGION                 roles, depth, split, union.
              (topopt::FaceRegionSpec)        THIS is what the UI manipulates.

A region is not a re-partition. It is a derived selection:

    region  =  (member FACE IDS)  ∩  (an intersection of HALF-SPACES)

### (a) Why layer 1 could not be touched

PR 307's projection puts an exported vertex exactly on its own plane or
cylinder, and PR 326's CAD-derived frozen region reached 0.3232 mm against
SIMP's 0.4293 — the best dimensional-accuracy result this project has. **A union
has no analytic surface**: two planes do not merge into one plane, and a fillet
unioned with a chamfer is neither. Had union renumbered or re-fitted
`triangle_face`, every one of those results would have been destroyed.

That is not hypothetical. `apply_face_overrides` (paint mode) does exactly that
— it MOVES triangles to a fresh pseudo-face id and appends a *fitted*
`StepFaceInfo`. Paint is therefore the one mechanism that must not be reused
here, and it is the reason the region layer exists as a second layer rather than
as more paint.

### (b) Why the cuts test the VOXEL and not the triangle

A tessellation triangle can be arbitrarily large — a flat CAD wall is often two
triangles covering the whole face. Classifying triangles by a half-space would
send both to one side and hand back 48 empty sub-regions out of a 10×5 grid
split. The cut is evaluated at the **voxel centre**, which is what §4 says in the
first place ("voxels of the region on each side become sub-regions").

### (c) Day one is byte-identical, and what "identical" is measured over

Three things in a run's output are properties of WHEN and WHERE the binary ran,
not of what it computed: `created_wall_ms`, the build `fingerprint`, and every
`*_ms` timing (plus `iterations.csv`'s per-row wall clock). They are named,
stripped in one place, and that list is the whole list — everything else is
compared raw. A receipt cannot hold a wall clock.

The comparison is therefore in two parts, and the split is not a convenience:

* **the DESIGN set** — `design.bin`, `fields.bin`, `report.json`, every
  `variant_*.stl`, every `*_alpha.f64` — compared **raw**;
* **the RECEIPTS** — `run_info.json`, `loadcase.json` — compared with the three
  fields above stripped.

★ For **R2** the two receipts SHOULD differ, and do: one job declares `face_ids`,
the other declares `region_ids`, and both receipts say so (`loadcase.json` gains
`region_ids` on the group; `run_info.json` gains a `face_regions` block with each
region's member count, area, filter match and drift). A receipt that did NOT
differ there would be the defect — it would mean the run could not tell the user
which selection it had resolved. **The design must not move; the receipt must.**

### (c1) The materialisation rule

Conceptually there is one region per CAD face on import. **Materially the model
stores nothing until the user unions, filters or splits**: an IDENTITY region —
one member face, no cuts — resolves to exactly what its face resolves to, so it
is emitted as the bare face id it always was. `test_face_region.cpp` asserts the
identity voxel-for-voxel; `r1_r2_byte_identity.txt` asserts the consequence at
the artifact level.

### (d) ★ THE DEFECT THE EVIDENCE CAUGHT, AND REVIEW WOULD NOT HAVE

The first version of `FaceRegionModel.union` stored the filter's whole match list
in the region's explicit `add` array *as well as* the filter. It looked
harmless. §3(c) exists precisely to stop a union being a stale id list, and this
made it one wearing a filter's clothes: on the simulated CAD edit, a 24-face
union came back with **32 members** — the filter found 23, and the frozen 24 ids
now pointed at whatever had inherited their numbers.

**The filter IS the membership.** `add` now carries only what the user tapped in
on top of it, and the same edit returns 23 members with `drift -1`. The fix is
`FaceRegion.swift` and is pinned by `testAFilterDefinedUnionStoresNoIdList`.

---

## §2 — SELECTION

### The correction, measured

★ **"All fillets and chamfers" is not a `kind` filter.** A CHAMFER is a flat
bevel (`Plane`). A FILLET is rounded (`Cylinder`, or a torus that lands in
`Other`). On his part, filtering on `Other`:

| filter | matches | misses | over-catches |
|---|---|---|---|
| blend — small **and** adjacent to ≥2 faces ≥2× larger | **24** | — | — |
| size alone (small, adjacency ignored) | 27 | — | 3 |
| `kind == "other"` — the naive reading | 30 | **13 of the blends** | **19** |
| `kind == "cylinder"` | 12 | — | — |

### The filters that ship

All ANDed; an all-unset filter matches **nothing** (not everything — a region
that silently swallowed the whole part would be the worst possible default).

* **area** (`max_area_mm2` / `min_area_mm2`)
* **adjacency** — ≥ N neighbours at least K× larger (the blend signal)
* **surface kind** — plane / cylinder / other
* **analytic signature** — cylinders of radius r ± tol ("all six bolt bores in
  one tap"; `StepFaceInfo` already carries the radius and the axis)

**Size is in mm², not voxels.** A voxel count depends on the run resolution, so a
voxel-expressed filter would match a different set at 64 than at 128 and a
persisted union would drift for a reason with nothing to do with the CAD. The UI
shows the equivalent voxel count at the current resolution, so the number he
reasons about is still §2(b)'s.

The match count is shown before Combine, and every filter-defined region takes
tap-add / tap-remove corrections — a heuristic that cannot be corrected by hand
is worse than no heuristic.

### §2(d) expand-to-neighbours — shipped, and REFUTED on his part

Both walks ship (`FaceRegionGeometry.expandCoplanar` / `expandSameKind`). On
M2_verticalStand:

```
TODAY            22 taps (one per face)
adjacency groups  1  (his faces DO all touch each other)
expand-coplanar  22 taps   <- no improvement
expand-same-kind  9 taps
filter + Combine  2 taps
```

★ **Coplanar expansion is a no-op on a B-rep, by construction.** OCCT does not
split a planar wall into coplanar pieces; two adjacent planar faces are adjacent
precisely *because* they are not coplanar. Expanding the five largest faces of
his part gives 1 → 1 every time. The walk still earns its place on an
STL/3MF import, where the dihedral segmenter DOES fragment a flat wall — but the
task's "cheapest win in the whole task, ship it even if nothing else does" is
wrong for the file type he actually brings.

**The mechanism that works on his part is the filter.** 22 taps → 2.

---

## §3 — UNION

N faces become ONE region: one id, the union of their voxel sets, one role, one
depth, one row. No analytic surface is synthesised; the members keep their own
ids and their own surfaces.

**Persistence.** ★ A union is stored as its **defining filter plus an explicit
add/remove list**, re-evaluated on every import, with `filter_matched_at_author`
recorded so a change is reported. Never an id list — see §1(d) for what happens
when it is. A split is stored as **geometry**: a point and a normal in model
space, never "region 24, half A".

The run prints one line per region, and names drift when it finds it:

```
[loadcase] region 100 "blends" faces=24 cuts=0 area=214.4mm^2 filter_matched=24 drift=+0
[loadcase] region 100 "blends" faces=23 cuts=0 area=205.1mm^2 filter_matched=23 drift=-1  CHANGED SINCE AUTHORING — check this selection
```

A union is dissolvable back to its members, and dissolving it dissolves anything
split out of it (those cells are pieces of a shape that no longer exists).

**The downstream contract is enumerated in full**, one row per consumer with
file and line, in `evidence/2026-08-14-face-regions/r4_consumers.md` (21 sites).
The short version: anchors, load groups, the structural pad and face protections
gained a region path *beside* the existing face path, which still runs first and
unchanged. Clearances and lattice regions **still read layer 1 only** — see §6.

---

## §4 — SPLIT

A split is a HALF-SPACE TEST, not a line drawn on a face (a line has no clean
meaning on a fillet, and 19.8% of his surface types as `Other`).

**Mode A — manual.** A cut plane through a point, default orientation snapped to
the region's principal axis (PCA of its member vertices). A **Rotate button** —
not a drag — cycles the snap candidates: across the long axis, along it, 45°,
135°.

**Mode B — grid.** N × M in the region's own coordinates:

* **Cylindrical** (every member is a cylinder sharing one axis, within 2° — a
  union of fillets around a bore): **N planes through the axis** at even angles,
  **M planes perpendicular** to it. His worked example exactly. Both families are
  planes, so it is the same primitive, and the axis is already in `StepFaceInfo`.
* **Planar / mixed**: two axes from PCA, cuts perpendicular to each. ★ The UI
  **says so** — "No shared axis — cuts follow the shape's long axis" — because
  "equal" is then equal in the PCA parameter, which is not equal in any intrinsic
  sense.

"Equal" means equal in PARAMETER (angle, or distance), which is what he drew.
The **per-cell voxel count is shown before confirming**, so a sliver is visible
in advance rather than discovered after.

The cells PARTITION exactly — asserted in core on the real voxel grid
(`total == member voxels`, both the PCA and the wrap-around cylindrical case)
and in the app on the sampled areas. Each cell takes its lower boundary
non-strictly and its upper boundary strictly, so a voxel centre exactly on a cut
plane lands in one cell, never two and never none.

Sub-regions are re-splittable, and splits are a revertable stack.

---

## §5 — THE TWO CONSEQUENCES

### (a) The sliver guard, and where its number comes from

★ **The floor is 16 voxels, and it is not a taste.** It is the size of the
smallest face his own CAD handed him: faces 41-47 of M2_verticalStand tag sixteen
voxels each at resolution 128, and he selects them today. The guard refuses to
MANUFACTURE anything smaller than the smallest thing the part itself produced.

It refuses **before anything is done**, twice: in the sheet, from the sampled
preview, and again in `build_production_loadcase` before a single voxel is
tagged, from the real grid. On his largest face:

```
grid parent      face 15, 6081 voxels, frame PCA (no shared axis)
10x5 split       50 cells, voxels 6081 of 6081 (PARTITIONS)
smallest cell    0 voxels  floor 16  -> REFUSED
refusal          smallest cell (1x1) holds 0 voxels, under the floor of 16.
                 This region holds 6081 voxels, so at most 380 cells can clear it.
```

Note that the budget (380) is an **upper bound and not a promise**: face 15 is
not a filled rectangle in its own PCA frame, so corner cells come back empty at
10×5 even though 6081 voxels would "buy" 380 cells. That is exactly why the guard
prices the actual cells instead of trusting the budget.

### (b) The list does not explode

A grid split produces a **collapsible parent with children, collapsed by
default**, showing the child count and the aggregate voxel count. A 5×5 split
adds ONE row; expanding it shows 26. Asserted in `testAGridSplitAddsONERowNotFifty`.

### (c) The small-face policy

Rows below the floor are **dimmed, not hidden**. Hiding them would lose a
selection his CAD does in fact hand him (faces 41-47 are 16 voxels and he uses
them); dimming makes them stop being noise he reads past on every part.

---

## §6 — WHAT THIS UNLOCKS, AND WHAT IS STILL MISSING

★ **A grid split IS a manual grading mechanism, on the protection side.** Each
sector of a split is a region, each region can sit in its own selection group,
and each group carries its own role and its own depth — so ten sectors around a
curved feature can be frozen to ten different depths, hand-authored, with the
optimiser deciding none of it. That plumbing is real and tested:
`ProductionLoadCase::face_protection_region_ids` +
`face_protection_region_depths_mm`, one depth per sector, each converted to voxel
layers against the run's own grid.

★ **What is still missing is the lattice half, and it is a real gap.** Core's
`lattice.regions` are pure GEOMETRY — a bolt cylinder or a bounded face slab —
which then become `ClearanceGeometry` predicates that the fit-cell field, the
multiscale mask and the thinnest-extent law all evaluate pointwise
(`run_job.cpp:621`, `:756`, `:856`). A region is a voxel SET, not a predicate, so
a sector of a grid split cannot become a lattice region today. Concretely, to
finish the graded-lattice route from the UI:

1. a `"kind": "region"` lattice region carrying a `region_id` and a depth;
2. `lattice_role_regions_from_job` returning a voxel mask for it instead of a
   `ClearanceGeometry`, which means `point_in_clearance_region` needs a
   mask-backed sibling in three places;
3. `lattice_region_thinnest_extent_mm` needs a thickness for a voxel set — the
   EDT of the region is the obvious answer and is already computed elsewhere.

Until then, a grid split grades what is FROZEN, not what is LATTICED.

---

## BARS

| bar | verdict | where |
|---|---|---|
| **R1** day-one byte-identity, base vs branch cli | see below | `evidence/…/r1_r2_byte_identity.{sh,txt}` |
| **R2** CAD error + attributed share unchanged to the digit with a union and a grid split | **MET** — flatness 1.2124389394e-15 mm, roundness 3.59712259979e-14 mm, attribution per vertex identical; and the DESIGN artifacts byte-identical between a `face_ids` job and an equivalent `region_ids` job | `r2_r3_his_part.txt` §4, `r1_r2_byte_identity.txt` |
| **R3** demonstrably usable on his own part, tap count reported | **MET** — 22 → 9 → 2 taps, with the coplanar walk honestly refuted | `r2_r3_his_part.txt` §2, §3 |
| **R4** every consumer of a face id enumerated, file + line, what it reads now | **MET** — 21 sites, one gap stated | `r4_consumers.md` |
| **R5** sliver guard refuses with the number, before doing anything | **MET** — app preview and core, both | `r2_r3_his_part.txt` §4, `r1_r2_byte_identity.txt` |
| **R6** persistence: re-import survives; edited STEP reports what changed | **MET** — 24 → 23 members, `drift -1`, reported | `r2_r3_his_part.txt` §5 |
| **R7** no wall of text | **MET** — longest on-screen string **11 words** | `r7_r8_census.txt` |
| **R8** never weaken or delete an assertion | **MET** — every category rose | `r7_r8_census.txt` |
| **R9** no unfilled placeholders, no scratch at the root | **MET** | — |
| **R10** separate commit for any review response | pending review | — |

---

## METHOD

**Core.** `core/include/topopt/face_region.hpp` + `core/src/io/face_region.cpp`
carry the whole layer: `resolve_face_regions`, the filters, `face_areas_mm2`,
`face_adjacency`, `region_frame` (PCA by Jacobi, or the members' shared cylinder
axis), `manual_split_snap_normals`, `grid_split_cells`, `region_member_voxels` /
`cut_voxels` / `grid_split_voxel_counts`, `check_sliver`, and the layer-2
tag/mask primitives. OCCT-free, for the same reason `face_tag.cpp` is: a region
must resolve wherever a mesh is, including the iOS slices.

The job schema gains `loads.face_regions`, `loads.anchor_region_ids`,
`groups[].region_ids`, and a `{"region_id", "depth_mm"}` form of
`face_protections`. `ProductionLoadCase` carries the specs and
`build_production_loadcase` resolves them **once**, so a union read by three
consumers cannot resolve to three different member sets.

**App.** `FaceRegion.swift` (the model: union, split, grid, dissolve, revert,
drift, the sliver verdict), `FaceRegionGeometry.swift` (the same geometry over
`ViewerMesh`), `FaceRegionSheetModel.swift` (every number and verdict the sheet
shows, as a pure value type), `FaceRegionSheet.swift` (layout only). The layer
reaches BOTH the LAN `job.json` and the on-device bridge — a user who unions and
splits and then taps Optimize locally must not get a run that ignored all of it.

**Tests.** `core/tests/unit/test_face_region.cpp` (68 checks, OCCT-free, gates
every CI config) and `app/…/FaceRegionTests.swift` (26 tests). Both drive the
same banded-cube fixture, so the two implementations are checked against one
shape.

**Suites, with their denominators** (`evidence/…/suites.txt`). The app suite is
1457 tests with **8 failures, all of them the same environmental gap**: this
machine's core slice has no lib3mf, so the three `AppModelTests` 3MF-import
cases refuse before they test anything ("3MF import requires lib3mf, which is
not available in this build"). `build_core.sh` says so at configure time. The
honest reading is 1449/1457 HERE and 1457/1457 in CI, and the three 3MF tests
DID NOT RUN. Core registers 120 tests locally against CI's 122 for the same
reason — report N/122, never N/N.

★ **TWO traps this branch walked into, recorded so the next session does not.**

1. `cmake --build build --target topopt-cli` (hyphen) is a SILENT NO-OP: the
   target is `topopt_cli`; the hyphen is the OUTPUT NAME, which make considers
   already up to date. It prints nothing and exits 0. The first R1/R2 evidence
   was produced by a binary three receipt-changes stale, and only `ls -la` on
   the binary's timestamp caught it.

2. The run receipt is assembled from a **hand-copied `echo` block**
   (`run_job.cpp:6501`) that carries a deliberate subset of `ProductionRunSetup`.
   Its own comments warn about this **three times** — including "it was right,
   and I still missed it" from the last person who did — and this branch missed
   it too: `face_region_reports` was populated, the emitter that writes them was
   correct, and `loadcase.json` came out without the block. What caught it was
   grepping the produced artifact, not reading the code.
   **The fix is the one `production_loadcase_from_job` already uses**: decompose
   by structured binding so the language refuses to compile until every member is
   named. It needs a `(void)` line per deliberately-skipped field (`setup.options`
   has been moved from by that point) and is worth doing on its own.

**The instrument.** `core/tests/harness/face_region_probe.cpp` is what produced
§0. It is a probe, not a test — it runs on a real part and prints what it finds,
including the layer-1 checks that would have caught a contamination.

### What did NOT get done

* The **load-path diagnosis** (`loadcase.cpp:901`) still walks a group's FACES
  only. A region-only load group certifies and runs normally but gets no
  load-path verdict. One call to fix; listed in `r4_consumers.md`.
* **Clearances and lattice regions** still read layer 1 only (§6).
* **The manual cut goes through the region's CENTRE, not through a tapped
  point.** §4(a) asks for a plane through the tap point; the mechanism takes any
  point (`splitManual(point:normal:)`, and the persisted cut is a point + a
  normal), so what is missing is only the UI's point-picking. The rotate button,
  the snap candidates and the two-child result all work as specified.
* The app's per-cell preview is an **area sample**, not the run's voxel grid: it
  subdivides each member triangle finely enough that one sample covers about one
  voxel, and the run prices the real thing again and refuses on the same floor.
  It can be a voxel or two out at a cell boundary; it cannot let a bad split
  through.

---

## IN PLAIN LANGUAGE

A CAD file does not describe a part the way you think about it. It describes how
somebody drew it. Your bracket has 78 faces; one of them is 10,554 voxels of
wall and seven of them are sixteen voxels each of chamfer. When you wanted to put
a load on "the top", you had to tap twenty-two of those, one at a time.

This branch gives a face a second name. Underneath, every voxel still remembers
which CAD face it came from — that is what lets us put an exported surface back
exactly on its plane or its bore, and it is the best dimensional result this
project has, so it does not move. On top of that, you can now say "these
twenty-four little faces are ONE thing", give that thing a role and a depth, and
cut it into pieces.

You pick the little faces with a filter, not by tapping. "Fillets and chamfers"
turns out not to mean "curved" — a chamfer is flat — so the filter looks for what
a blend actually is: something small sitting between two bigger things. On your
part that finds 24 faces. The obvious wrong version, "everything the CAD couldn't
classify", finds 30 but misses 13 of the real ones and drags in 19 that aren't.

Then you can split. Give it a number around and a number along, and it cuts the
region into equal pieces in the region's own coordinates — around the axis if
there is one, along the shape's long direction if there isn't (and it tells you
which). It shows you how many voxels land in the smallest piece before you
commit, and it refuses outright if any piece would come out smaller than the
smallest face your CAD gave you in the first place. Fifty pieces from one tap is
a lot of rows, so they fold up under one.

Three honest things. **First**, one of the ideas in the brief doesn't work on
your files: "tap one face, grab the flat ones next to it" does nothing on a STEP
part, because a CAD kernel already merges flat surface into one face. The filter
is what gets you from 22 taps to 2. **Second**, we found a bug in our own work by
measuring rather than by reading it: the first version quietly froze a list of
face numbers inside the union, and when we simulated you editing the CAD, a
24-face selection came back as 32. It now stores the *rule*, re-runs it on every
import, and tells you when the answer changed. **Third**, splitting a region lets
you hand-set how deep each sector is *protected*, but not yet how each sector is
*latticed* — the lattice still wants a shape, not a set of voxels. The three
changes that would finish it are written down.
