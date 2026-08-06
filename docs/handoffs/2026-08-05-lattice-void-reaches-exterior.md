# The void space inside any lattice must reach the exterior

Task: `lattice-void-reaches-exterior`
Evidence: `evidence/2026-08-05-lattice-void-reaches-exterior/`
Built on: handoff `2026-08-03-preflight-feasibility-and-divergence` (the belt's own
walk, `walk_load_path`) — consumed as a *reference point*, deliberately NOT reused.
Sibling task `lattice-cell-fit-mode` owns cell selection; this one owns the
connectivity check. No file overlap.

---

## 0. THE HEADLINE, BEFORE ANY METHOD

**The rule is built, it is OFF by default, and on his own job it refuses
nothing.**

`lattice.require_lattice_void_reaches_exterior` (absent ⇒ false ⇒ byte-identical)
flood-fills the void from outside the part inward the moment the lattice
occupancy is final and BEFORE a single triangle is written. A lattice cell whose
pore space cannot reach the exterior refuses the variant, naming how many cells,
where (bounding box in mm), which declared include region, and how much volume is
trapped. It refuses; it never opens a cavity, because opening one would change
geometry he did not ask to change.

Four things came back:

* **★ HIS OWN JOB PASSES, at every rung.** His captured job document —
  M2_verticalStand, his 8 include + 1 exclude regions, converted to the uniform
  8 mm cell the brief describes — comes back **open on every rung**, with the
  lattice's own escape network **touching all six faces of the design grid at
  escape depth 0**. His include regions are 4 mm-deep face slabs drawn ON the
  part's outer surface and bolt cylinders that punch straight through it; they
  are the "lattices that start from the outside going in" case he said works
  fine, and the rule agrees. §6.
* **The check DOES fire, and it took construction to make it fire.** Not one of
  the seven real lattice fixtures this repo owns is refused, and neither is
  his own job at either resolution. That is not
  evidence the fixtures are clean until a case exists that IS refused — so §5
  builds one (a lattice-filled cavity buried in the middle of the l-bracket's
  foot), asserts that today's build **exports and CERTIFIES it with no complaint
  whatsoever**, and then asserts the armed check refuses it. Both directions are
  in ctest.
* **★ THE CONNECTIVITY IS 6, AND THE PROJECT'S OTHER WALK IS 26 — ON PURPOSE.**
  The existing load-path belt walks SOLID at 26-connectivity because two hex8
  elements touching at a corner really do share a node. The void walk takes the
  opposite answer: an edge or corner contact shares ZERO AREA, so nothing flows
  through it. The two must be complementary or a void path and a solid path could
  cross the same diagonal. §4 measures the difference on a constructed part: a
  corner-touch staircase that a 26-connected fill calls OPEN, this check calls
  SEALED. That test is in ctest, with the 26-connected fill computed alongside it
  as the negative control.
* **It costs nothing.** 0.1–27 ms per run — 27 ms on his 128³ job, against a
  3441 s run, i.e. 0.0008 % of it. The fill
  is O(voxel_count) and reports its own visit count and its own wall clock,
  separately, and neither is folded into `gen_seconds`. §8.

And the thing to carry away about SCOPE, because it bounds what the rule is worth:
**this is a statement about the design field, not about the exported mesh.** With
`outer_finish: "shell"` the exported file carries the marching-cubes surface of
the printed set closed over the whole part. Whether that surface is a physical
barrier over a boundary lattice cell is a mesh-level question that the freeform
`"skin"` / `"shell+skin"` finish exists to answer, and this check does not decide
it. §9 says so in the receipt, in those words.

---

## 1. WHAT SHIPPED

### The rule, and the correction it needed

His rule as stated — *"if it's not visible from the outside: do not make it"* —
taken literally bans all interior lattice, which is the opposite of the pockets
inside topology-optimised tendrils he actually wants. The rule enforced here, as
agreed:

> **THE VOID SPACE INSIDE ANY LATTICE MUST CONNECT TO THE EXTERIOR.**
> No sealed lattice-filled cavities.

Structurally the same thing; it permits the pockets; and it is the standard
additive-manufacturing enclosed-void constraint. The differentiable form of that
constraint (the Virtual Temperature Method — fill the void with a virtual
high-conductivity material and bound the maximum temperature) belongs in the
OPTIMIZER, where a gradient is needed. **VTM was not built and is not proposed
here.** At the lattice stage the occupancy is already decided and DISCRETE, so a
flood fill is not an approximation of the constraint — it *is* the constraint,
evaluated exactly.

### The new code

| what | where |
| --- | --- |
| the walk + the refusal text | `core/include/topopt/lattice_void.hpp`, `core/src/mesh/lattice_void.cpp:46` / `:344` |
| the job key | `core/include/topopt/job.hpp:228`, parsed `core/src/cli/job.cpp:1004` (and added to the strict key list at `:827`) |
| where it runs | `core/src/cli/run_job.cpp:2326` — immediately after `mask` is FINAL and before any export |
| the refusal, re-lattice path | `core/src/cli/run_job.cpp:4762` (throws — that entry point exists to make one object) |
| the refusal, ladder path | `core/src/cli/run_job.cpp:5888` (skips the rung, keeps the others) |
| the per-variant receipt block | `core/src/cli/run_job.cpp` — `lattice_cert_report_json`, `"void_escape"` |
| `run_info.lattice_export.void_escape` | `core/src/simp/observability.cpp:949`, filled `core/src/cli/run_job.cpp:6130` |
| unit test (the walk) | `core/tests/unit/test_lattice_void.cpp` — ctest `lattice_void` |
| validation test (the wiring) | `core/tests/validation/test_lattice_void_exterior.cpp` — ctest `lattice_void_exterior` |

### The three-way classification the walk decides on

Every voxel of the design grid is exactly one of:

* **LATTICED** — `lattice_certification_mask[e] != 0`. Its material is the strut
  lattice, so it carries pore space and **conducts**.
* **SOLID** — printed (`density >= iso`) but not latticed. Fully dense: it
  **blocks**.
* **VOID** — not printed. It **conducts**.

The **escape network** is LATTICED ∪ VOID. The exterior is everything outside the
design grid, so every escape-network voxel lying on one of the grid's six
boundary planes is a seed. A latticed voxel the fill reaches is OPEN; one it does
not reach is SEALED, and the cell that owns it is a sealed lattice cell.

The mask is `lattice_certification_mask` — **the** object the exported file and
the certified posture are both derived from — so the check decides on the same
set they do rather than on a reconstruction of it. It runs at the point where
that mask is final: after the graded intersection and after the design box's
whole-cell clearing, before the radius field, before the generator.

**A latticed voxel conducts because the octet cell's pore space is connected
within the cell and opens on all six cell faces.** That is what "open-cell
lattice" means and it is the same periodic-octet assumption the homogenized
certificate already rests on. It is written into the header rather than assumed
silently: a topology whose pore space does NOT open on every face would need this
classification revisited with it.

---

## 2. S1 — THE CHECK, AND WHAT IT SAYS WHEN IT REFUSES

Default **false**. Armed, a refusal reads (verbatim, from `after.log` in the
evidence directory):

```
[lattice] vf=1.00 NO LATTICE EMITTED — the void space inside this lattice does
not reach the exterior. 6 of 6 lattice cells (432 of 432 latticed voxels) sit
in 1 SEALED cavity/cavities holding 843.750 mm^3 of trapped space with no
path out of the part. Nothing can ever be emptied from them — powder, resin or
support placed there stays there. Cavity 1: 432 latticed voxels in 6 cells,
843.750 mm^3, bounding box (-12.500, -7.500, 2.500) to (2.500, 7.500, 6.250)
mm, declared include region 1. NOTHING WAS AUTO-CORRECTED: opening a cavity
would change geometry that was not asked to change. Either place the lattice
so it reaches the surface, add a drain path, or clear
lattice.require_lattice_void_reaches_exterior.
```

It names **how many cells**, **where** (voxel and mm bounding box, plus the
declared include region the user drew), and **the trapped volume**. Several
cavities are listed individually, largest first, with lattice-bearing pockets
always ahead of lattice-free ones so the display cap can never drop a refusal
reason in favour of an observation; `pockets_total` is never truncated.

**The refusal happens before the generator runs.** `lattice_one_variant` returns
at `run_job.cpp:2360` — no STL, no 3MF, no receipt for that rung, so there is no
half-object for a slicer to open. Asserted, not argued: the validation test
requires `mesh_paths` to contain no `_lattice.` entry.

**Two callers, two behaviours, both deliberate and both copied from the existing
`ungradeable` precedent.** `lattice_variant_job` exists to produce ONE object, so
it throws. The optimize ladder skips that rung, prints the reason, counts it, and
leaves it OUT of the run-level aggregates (which take MINs a rung with no
geometry would drag to zero — the defect handoff
`2026-08-04-variant-volume-fraction-mismatch` diagnosed). The other rungs are
untouched.

**One thing it deliberately does NOT refuse on.** A sealed void pocket that holds
no lattice is a real enclosed void in the design itself, and it is reported
(`sealed_pockets_without_lattice`, `sealed_volume_without_lattice_mm3`) and never
refused. This rule is about lattice; a check that quietly widened its own scope
would be a different check.

---

## 3. S2 — WHERE THE EXISTING GEODESIC CODE IS, AND WHY IT IS NOT SHARED

### Where it lives

The pre-flight's reachability walk is **`walk_load_path`**, declared at
`core/include/topopt/voxel.hpp:408` and implemented at
`core/src/voxel/voxelize.cpp:609`. `load_path_connected`
(`voxelize.cpp:720`) is a one-line wrapper over it — the header states outright
that "there is ONE flood fill in the project and this is it". His run_info fields
come from there: `preflight_connected`,
`preflight_narrowest_separator_voxels` (3840),
`preflight_narrowest_separator_mm2` (11166.6336) and `preflight_geodesic_levels`
(12) are copied at `core/src/cli/run_job.cpp:167–171` and serialized at
`core/src/simp/observability.cpp:683–686`.

### Can this check share it? **No — and it must not.**

Three independent reasons, in order of how load-bearing they are:

1. **THE ADJACENCY IS DIFFERENT, AND SHARING WOULD RELAX IT IN THE PERMISSIVE
   DIRECTION.** `walk_load_path` is 26-connected, and `voxel.hpp:342` says
   exactly why: "two hex8 elements that touch at a single CORNER still share that
   node and still pass force through it. Restricting to face adjacency would
   reject designs the very FEA that produced the margin considers connected."
   That reasoning is correct for SOLID and inverts for VOID. Reusing the walk
   would make a corner-touch staircase count as a drain path — see §4, where a
   26-connected fill calls a sealed cavity open. This is the single reason the
   code is not shared, and it is a correctness reason, not a taste one.
2. **THE SET, THE SEEDS AND THE TARGETS ARE ALL DIFFERENT.** The belt walks the
   PRINTED set from `Fixture`-tagged voxels to `Load`-tagged voxels and is
   vacuous when either tag is absent. This walk covers the COMPLEMENT (void ∪
   latticed), seeds from the grid's boundary planes, and has no target set at
   all — every latticed voxel is a target. Parameterising `walk_load_path` over
   set / seeds / targets / adjacency would leave a function whose body is a
   generic BFS and two call sites that share nothing but the loop, and would put
   the belt's 26-connectivity one default argument away from being applied to
   void.
3. **THE MARGINALITY METRIC DOES NOT TRANSFER, and pretending it did would put a
   misleading number in the receipt.** The belt can call its narrowest BFS level
   set a *separator* because its seed is a small anchor set, so each level really
   is a cut. This fill's seed is the ENTIRE BOUNDARY SHELL of the grid, so its
   level sets are shells around the whole part and their sizes are not an
   aperture. **No narrowest-separator figure is reported here**, deliberately;
   `escape_depth_voxels` (how far under the surface the drain path runs) is
   reported instead, and it is exactly what it says.

What IS shared: the grid indexing convention, `VoxelGrid`, and the vacuity
discipline (`decidable == false` when there is no lattice to judge, verdict not
invented). The new walk is ~160 lines including the pocket accounting.

**No second implementation disagrees with the first.** They answer different
questions on different sets, so there is no verdict to compare and nothing to
reconcile. The blocked-stop about a disagreeing second implementation does not
apply.

### The COUSIN, kept distinct

The brief names the isolated-**fragment** check — SOLID pieces attached to
nothing — as "specified but not yet wired, see the cell-size-adaptation handoff
§M8a". **I could not find a handoff section by that name in this repo**
(`grep -rn "M8a" docs/` returns nothing), so I am not going to claim to have read
it. What DOES exist, and is the nearest machinery:

* `V3Report::mesh_components` / `mesh_components_raw` (`voxel.hpp:256–257`,
  computed `voxelize.cpp:816`) — gate 2 counts components of the CLEANED MESH and
  requires 1;
* `V3Report::load_fixture_islands` (`voxel.hpp:270`, set `voxelize.cpp:813`) —
  how many non-largest components the cleanup dropped that genuinely bound frozen
  Load/Fixture material.

Both are mesh-level and post-cleanup; neither is a voxel-level fragment census.
**Opposite polarity, same machinery** to this check: that one walks the printed
set and asks which components carry no anchor; this one walks the complement and
asks which components reach no exterior. Sharing infrastructure between them
would be cheap *if* the fragment check is ever written — it is the same
component-labelling loop with the class predicate and the "is this component
attached?" test swapped — but **it is not implemented here**, and this check says
nothing about a floating solid fragment. That is asserted, not assumed: section E
of `test_lattice_void.cpp` puts a solid fragment floating free in void and
requires the report to stay silent about it.

---

## 4. R4 — THE CONNECTIVITY, AND WHY GETTING IT WRONG WOULD MAKE THE CHECK
WORTHLESS

**6-connected. Face adjacency only.**

Two voxels that meet along an edge or at a corner share **zero area**. There is
no aperture there; nothing flows through a measure-zero contact. A "diagonal
escape path" is a staircase of corner touches through a wall that is solid
everywhere a fluid could actually pass — physically a sealed cavity that a
26-connected fill would call open.

The two adjacencies also have to be **complementary** for the pair to be
topologically coherent. In 3-D digital topology a set and its complement must
take (26, 6) or (6, 26), or both a solid path and a void path can cross the SAME
diagonal — i.e. the void "escapes" straight through a wall the load path is
simultaneously walking along. Solid is 26 here, so void is 6.

6-connectivity also reaches a **subset** of what 18- or 26-connectivity would
reach, so this check can only ever refuse MORE, never less. Wrong in the
permissive direction is the failure mode that would make it worthless; this is
wrong (if at all) in the conservative one.

**This is measured, not asserted.** `test_lattice_void.cpp` section C builds a
20 mm cube whose buried 6×6×6 lattice block's only path to the outside is the
staircase (13,13,13) → (19,19,19), each step touching the last at a single
corner, and requires:

| fill | latticed voxels reached | verdict |
| --- | --- | --- |
| this check (6-connected) | 0 of 216 | **SEALED** |
| 26-connected control, same grid, computed in the test | 216 of 216 | open |

Section C2 does the same for an EDGE-only contact (18-connectivity's case) and
gets the same disagreement. Without the 26-connected control both sections would
also pass against an implementation that simply refused everything.

The receipt states the adjacency it used, in words, so a reader never has to
guess whether a corner touch counted.

**On exactness (blocked-stop 1).** The walk is exact on the voxel field it is
given: it is a reachable-set membership test, order-independent, no tolerance, no
sampling. It is decided at exactly the resolution the lattice occupancy is
decided at — the same grid, the same mask, the same iso — so there is no
discretisation gap between "what was checked" and "what will be emitted". What is
NOT resolution-independent is the ANSWER, because the answer is a property of the
discretised part: a marginal cavity whose wall is one or two voxels thick can
change verdict with resolution. §7 measures that on a deliberately marginal case
and states it plainly rather than filing it as a caveat.

---

## 5. S3, R2 — THE FAILING CASE FIRST, WITH THE "BEFORE" PASTED

`evidence/…/s1_sealed_cavity_before_after.sh` (output `.txt`).

**The part.** The demo l-bracket at resolution 48, `ladder [1.0]` so the
optimizer keeps the whole part — a fully solid design is the cleanest way to
build a cavity that is genuinely walled in. Its foot is a slab x = −30..30,
y = −20..20, z = 0..8.33 mm with two small bores near y = 0. **One** lattice
include region: a face slab centred at (−5, 0), 16 × 16 mm in plan, spanning
z = 3..6 — the middle of the foot's thickness, clear of both bores. Include
semantics do the rest: only material inside the include union is latticed, the
rest of the printed part stays SOLID.

**THE BEFORE — this is what ships today:**

```
  WROTE  variant_100_lattice.stl  1749084 bytes
  variant_100_lattice.report.json: lattice_accepted=True lattice_voxels=432
                                   lattice_margin_worst_case=2542.281254
```

A 1.7 MB latticed STL, full of struts, **certified accepted**, with no complaint
anywhere in any document. That is the defect, asserted rather than described.

**THE AFTER** — the refusal quoted in §2, and:

```
  no latticed STL was written — the refusal happens BEFORE the generator runs
  run_info.lattice_export.void_escape: sealed=True sealed_variants=1 cells=6
      voxels=432 volume_mm3=843.75 bfs_visits=57048 wall_seconds=0.000878083
```

**THE OPEN CONTROL** — the SAME slab with `half_w` widened 8 → 40 mm so it runs
out through the part's y faces. One number changes, and it is the one that
decides whether the pore space reaches the outside:

```
  variant_100_lattice.report.json: sealed=False latticed_voxels=1644 reached=1644
      escape_depth_voxels=0 escape_faces=['-x','+x','-y','+y','-z','+z']
      reachable_void_volume_mm3=113789.0625
  WROTE  variant_100_lattice.stl  2396084 bytes
```

The rule permits what he actually wants. Both directions are also in ctest
(`lattice_void_exterior`, at resolution 32 for speed — the construction was
verified sealed at 32, 40, 48, 56, 64 and 72 before being fixed there, §7).

---

## 6. S3 — THE MEASURED TABLE

`evidence/…/s3_fixture_table.txt` (script `.py`). Every lattice-shaped job this
repo owns, run with the rule ARMED.

| fixture | verdict | sealed cells | sealed mm³ | latticed cells | reached | depth | escape faces | bfs visits | check s | run s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| uniform whole-part lattice (l-bracket, 4-rung ladder) | pass | 0 | 0.0 | 335 | 42659 | 0 | −x,+x,−y,+y,−z,+z | 335904 | 0.0045 | 260.0 |
| graded SWEPT lattice (l-bracket, dyadic cell ladder) | pass | 0 | 0.0 | 290 | 2532 | 0 | −x,−y,+y,−z,+z | 284292 | 0.0041 | 256.8 |
| freeform SKIN outer finish (no solid shell) | pass | 0 | 0.0 | 335 | 42659 | 0 | −x,+x,−y,+y,−z,+z | 335904 | 0.0069 | 287.3 |
| self-weight mesh job, uniform lattice (plate_bore.stl) | pass | 0 | 0.0 | 80 | 1836 | 0 | −x,+x,−y,+y,−z,+z | 6048 | 0.0001 | 1.6 |
| … + EXCLUDE bolt region (kept solid) | pass | 0 | 0.0 | 78 | 1692 | 0 | −x,+x,−y,+y,−z,+z | 5874 | 0.0001 | 1.6 |
| … + INCLUDE slab region (only it is latticed) | pass | 0 | 0.0 | 50 | 1074 | 0 | −x,+x,−y,+y,−z,+z | 5131 | 0.0001 | 1.6 |
| maintainer's WallMount part, uniform 8 mm cell | pass | 0 | 0.0 | 445 | 3276 | 0 | −x,+x,−y,+y,−z,+z | 37538 | 0.0005 | 25.4 |
| **★ CONTROL, SEALED** — cavity buried in the l-bracket foot | **REFUSE** | **6** | **843.8** | 6 | 0 | −1 | — | 57048 | 0.0009 | 2.9 |
| **★ CONTROL, OPEN** — the same cavity, run out to the y faces | pass | 0 | 0.0 | 24 | 1644 | 0 | −x,+x,−y,+y,−z,+z | 64378 | 0.0009 | 3.9 |

Reading it: `depth` is the geodesic distance in 6-connected escape steps from the
grid's boundary planes to the nearest reached latticed voxel — 0 means the
lattice itself lies on a boundary plane. `faces` names the grid faces the open
lattice's escape network touches. `check s` is the fill's own wall time summed
over the run's rungs and is NOT part of `gen_seconds`.

**Nothing real is refused. The two constructed controls both go the way they had
to**, and the script exits non-zero if either does not — a table where nothing
refuses would otherwise be evidence only that the check was never tested.

### His own run

`evidence/…/s3_maintainer_run.txt` and `_128.txt` (script `.py`).

**WHAT THIS IS, EXACTLY.** The brief names his overnight run by DESIGN
FINGERPRINT (`b3abcf880554`, resolution 128, uniform, 8 mm cell, seven include
regions). **That run's `design.bin` is not in this repo**, and the rule is
evaluated on a DESIGN — so the literal run cannot be re-decided here, and I am
not going to pretend otherwise. What this repo owns is his job DOCUMENT, captured
verbatim during `2026-08-04-protect-freeze-vs-solidity`: `M2_verticalStand.step`,
resolution 128, his anchor / load / face-protection selections and his lattice
role regions — **8 include + 1 exclude in the captured copy; the brief says
seven, and the difference is which capture, stated rather than smoothed over.**
That document was re-run here with the grading block replaced by the uniform 8 mm
cell the brief describes, and the rule armed.

| resolution | verdict | latticed cells | voxels reached | sealed | escape depth | escape faces | enclosed voids holding NO lattice | check cost | run wall |
| ---: | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| 64 | **pass** | 1082 | 6276 | 0 | 0 | −x,+x,−y,+y,−z,+z | 1 | 0.0041 s / 240 011 pushes | 418 s |
| **128** (his own) | **pass** | 1146 | 41862 | 0 | 0 | −x,+x,−y,+y,−z,+z | 25 | 0.0270 s / 1 770 303 pushes | 3441 s |

Per rung at 128 — every one of them open, none even partially:

| rung | latticed voxels | reached | sealed | cells | escape depth |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0.68 | 10607 | 10607 | 0 | 289 | 0 |
| 0.52 | 10486 | 10486 | 0 | 289 | 0 |
| 0.38 | 10405 | 10405 | 0 | 284 | 0 |
| 0.26 | 10364 | 10364 | 0 | 284 | 0 |

**Escape depth 0 on every rung** means the latticed material itself lies on the
design grid's boundary planes: the lattice reaches the part's surface directly.
His include regions are 4 mm-deep face slabs drawn ON the outer faces and bolt
cylinders (Ø 60–169 mm) that punch through the part. Those are the "lattices that
start from the outside going in" case he said works fine.

**Two deviations, both stated:**
* the grading block is dropped for the uniform cell — that is what the brief
  asks for, and it also side-steps the cells-per-member floor that leaves his
  graded job with almost nothing latticed (his own forecast, printed by the run:
  *8 of 8 include regions are thinner than the 40.000 mm the floor requires*);
* an iteration cap was written into the job document and **is not honoured** —
  see R7.

**25 enclosed voids holding no lattice** were found at resolution 128 and are
REPORTED, not refused. They are pre-existing enclosed voids in his design itself,
which this rule is not about; if he wants them refused too, that is a decision to
make deliberately and it is one line.

---

## 7. THE RESOLUTION SENSITIVITY, STATED RATHER THAN FILED

`evidence/…/res_sensitivity.txt`.

The first sealed fixture I built was a bolt cylinder (r = 3 mm, y = −12..12) at
(15, ·, 5) in the same foot. Swept across resolution it does **not** hold a
verdict:

| resolution | spacing (mm) | verdict |
| --- | --- | --- |
| 32 | 1.8750 | open (depth 3) |
| 40 | 1.5000 | open (depth 3) |
| 48 | 1.2500 | open (depth 7) |
| 56 | 1.0714 | open (depth 4) |
| **64** | **0.9375** | **SEALED — 3 cells, 750 voxels, 617.98 mm³** |
| 72 | 0.8333 | open (depth 6) |

That is not the check being unstable; it is the CAVITY being marginal. The foot
is 8.33 mm thick and the cylinder's 6 mm diameter leaves ~1 mm of wall above and
below, so whether a one-voxel drain survives voxelisation is genuinely a function
of the grid.

The shipped fixture (§5) was chosen *because* it is not marginal — a slab with
≥ 2 voxels of solid on every side at every resolution tested — and both of its
rows ARE asserted by the script:

| resolution | shipped slab, buried | shipped slab, OPEN twin |
| ---: | --- | --- |
| 32 | **SEALED** — 9 cells, 533.9 mm³ | pass, depth 0, all six faces |
| 40 | **SEALED** — 9 cells, 816.8 mm³ | pass, depth 0, all six faces |
| 48 | **SEALED** — 6 cells, 843.8 mm³ | pass, depth 0, all six faces |
| 56 | **SEALED** — 9 cells, 830.2 mm³ | pass, depth 0, all six faces |
| 64 | **SEALED** — 9 cells, 714.4 mm³ | pass, depth 0, all six faces |
| 72 | **SEALED** — 9 cells, 694.4 mm³ | pass, depth 0, all six faces |

(The sealed *volume* moves a little with the grid because the trapped pocket is
the union of whole voxels; the *verdict* does not move at all, which is the
property the fixture was chosen for.)

**What a user should take from this:** the answer is a property of the design at
the resolution it was solved at, which is also the resolution the certificate was
computed at. A cavity whose wall is one voxel thick is a cavity you should not be
relying on either way.

---

## 8. R5 — COST, BOTH FIGURES, SEPARATELY

The fill reports its own **iteration count** (`bfs_visits` — voxels pushed onto a
frontier, across both passes) and its own **wall clock** (`wall_seconds`), in the
per-variant receipt and in `run_info`. Neither is folded into `gen_seconds`
(generation) and neither touches the solver's own iteration reporting.

| run | grid | check wall | check "iterations" (voxel pushes) | lattice generation | run wall | check / run |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| l-bracket, uniform whole-part, 4 rungs | 48³-ish | 0.0045 s | 335 904 | 0.052 s | 260.0 s | 0.0017 % |
| l-bracket, graded swept, 4 rungs | same | 0.0041 s | 284 292 | — | 256.8 s | 0.0016 % |
| plate_bore self-weight, 1 rung | 32³-ish | 0.0001 s | 6 048 | — | 1.6 s | 0.006 % |
| the sealed control (refused) | 48³-ish | 0.0009 s | 57 048 | n/a — refused first | 2.9 s | 0.03 % |
| **his job, resolution 128, 4 rungs** | 128³-ish | **0.0270 s** | **1 770 303** | — | **3441 s** | **0.0008 %** |

The fill is O(voxel_count) with two passes: one component-labelling sweep that
produces the verdict, the pockets, the cells, the bounding boxes and the
per-face escape record; and one breadth-first sweep from the boundary planes that
produces `escape_depth_voxels`. `bfs_visits ≤ 2 × voxel_count` is asserted in
`test_lattice_void.cpp` section F.

---

## 9. S4 — A PASS THAT SAYS SO

A silent pass is indistinguishable from a check that did not run, and this
project has shipped that exact failure before: a forecast-only job that reported
itself as a build, and a rim that emitted nothing while succeeding. So when the
check PASSES, both documents still carry the record.

`run_info.lattice_export.void_escape` and the per-variant
`*_lattice.report.json` `"void_escape"` object both carry, on a pass:

* `ran: true`, `decidable`, `sealed: false` — that it ran, that there was
  something to decide, and what it decided;
* `connectivity: 6` and the sentence explaining it — so a reader never has to
  guess whether a corner touch counted;
* `latticed_cells`, `latticed_voxels_reached` and
  `reachable_void_volume_mm3` — **how much** void was reachable;
* `escape_depth_voxels` — **how far in** the drain path runs (0 = the lattice
  itself lies on a boundary plane);
* `escape_faces` — **which way out it found**, by grid face;
* `sealed_pockets_without_lattice` / `sealed_volume_without_lattice_mm3` — the
  enclosed voids that hold no lattice, reported and never refused;
* `bfs_visits` / `wall_seconds` — its own cost;
* `scope_note` — that this is a statement about the DESIGN FIELD, that it is not
  the isolated-fragment check, and that it does not model the exported solid
  shell as a barrier.

With the option OFF **neither document contains the string `void_escape` at all**
— asserted at the document level in `test_lattice_void_exterior.cpp` (V5) and at
the checksum level in R1.

---

## 10. THE BARS

### R1 — byte-identical when off, by stash-rebuild checksum

`evidence/…/r1_byte_identity.txt`. Two SEPARATELY BUILT binaries (base = this
branch stashed and rebuilt; branch = this branch), asserted to differ before a
single artifact is compared — the `topopt_cli` vs `topopt-cli` silent-no-op
target trap has bitten this project more than once, and it bit **this bar on its
first run**: the script stashed, built the base, and then a "pop it back if the
tree is dirty" test was FALSE (stashing leaves the tree clean), so the branch
build compiled the stashed tree and both binaries came out byte-identical. The
sha guard caught it, which is exactly what it is for; the pop is now
unconditional and flag-driven.

| | |
| --- | --- |
| **A** no lattice at all, base vs branch | **IDENTICAL** — report.json, fields.bin, design.bin, 4 solid meshes, run_info (minus the named clock keys), iterations.csv |
| **B** lattice **with a role region**, option OFF, base vs branch | **IDENTICAL** — all of the above plus 4 latticed meshes and 4 lattice receipts |
| **C** same binary, ARMED vs not | geometry, designs, fields and every mesh **IDENTICAL**; the receipts and run_info differ **only** by the `void_escape` block they gain |

C is the half that makes B worth anything: if arming changed nothing, "off is
identical" would be true and useless.

### R2 — failing test first

§5. Two ctest targets: `lattice_void` (70 checks — the walk, with the
26-connected negative control) and `lattice_void_exterior` (28 checks — the
wiring, with the OPEN control). Both assert the pre-task behaviour explicitly
before asserting the fix.

### R3 — full gate table with the option armed

`evidence/…/r3_gate_table.txt`.

L-bracket, 4-rung production ladder, resolution 48, uniform 8 mm lattice with an
include region. Same binary, option OFF then ON:

| rung | margin OFF | margin ON | Δ margin | effective OFF | effective ON | verdict | voxel flips |
| ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 0.68 | 8.398164525 | 8.398164525 | 0.000e+00 | 8.398164525 | 8.398164525 | True→True | **0** |
| 0.52 | 8.334213155 | 8.334213155 | 0.000e+00 | 8.334213155 | 8.334213155 | True→True | **0** |
| 0.38 | 8.058366106 | 8.058366106 | 0.000e+00 | 8.058366106 | 8.058366106 | True→True | **0** |
| 0.26 | 7.503571156 | 7.503571156 | 0.000e+00 | 7.503571156 | 7.503571156 | True→True | **0** |

And the COMPOSITE (latticed) side, which is the one the check could plausibly
have disturbed:

| latticed variant | composite OFF | composite ON | accepted | lattice voxels |
| --- | ---: | ---: | --- | --- |
| variant_026_lattice | 6.027866483 | 6.027866483 | True→True | 960→960 |
| variant_038_lattice | 6.572584231 | 6.572584231 | True→True | 1036→1036 |
| variant_052_lattice | 6.898128923 | 6.898128923 | True→True | 1274→1274 |
| variant_068_lattice | 7.001637930 | 7.001637930 | True→True | 1396→1396 |

**Against a negative-control floor, run first**, because "0 flips" from a
comparator that cannot count is worth nothing:

* **C1 resolution** — one voxel of the run's own design moved across the printed
  iso by 1e-9 (0.999947154531 → 0.499999999000): the comparator reports **exactly
  1 flip**.
* **C2 sensitivity** — rung 0.68 vs rung 0.52 of the same run: **2009 flips**.

### R4 — the check is exact, not heuristic

§4.

### R5 — iterations and wall, always both, separately

§8.

### R6 — never weaken or delete an assertion

`evidence/…/r6_deleted_test_sweep.txt`. The sweep accounts for every removed line
and does a CHECK-message census by text (so a moved assertion is not miscounted
as a lost one):

* distinct `CHECK(` lines on `origin/main`: **3265**; on the branch: **3355**;
  **present on main and absent now: 0**; added: 90.
* Every removed line in `core/` and `app/`, all five of them, and every one is a
  line I edited rather than an assertion: the `reject_unknown_keys` key list in
  `job.cpp` (gained a key), the `lattice_cert_report_json` signature (gained two
  parameters), and its three-line call site.
* No existing test file was touched at all.

### R7 — root cause with file and line

Two defects were found and fixed on the way, both in this task's own evidence
scripts rather than in shipped code, and both are named because they would
otherwise read as passing bars:

1. `r1_byte_identity.sh` — the stash was never popped before the branch build
   (the guard caught it; §10/R1).
2. `r3_gate_table.py` — `report.json` keys rows by the ACHIEVED volume fraction
   while `design.bin` stores the REQUESTED ladder rung, so an equality match
   found no design for any row and every flip count would have read −1. Matched
   on the nearest rung instead.

One production observation, not a defect and not fixed here:
**`simp.max_iterations` is ignored in LOADCASE mode.** `run_job.cpp:5120` applies
it only on the non-loadcase branch, so a loadcase job runs the production
ladder's own termination however small a cap the job document states. That is why
his run in §6 is not iteration-capped, and it is stated rather than left as an
unexplained cost.

### R8 — no unfilled placeholders

None.

---

## 11. BLOCKED-STOPS — NONE WERE HIT

* *the check cannot be made exact at the resolution the lattice is decided on* —
  it is exact, on exactly that grid and that mask (§4). The verdict's dependence
  on resolution is a property of the discretised part, measured and reported
  (§7), not an inexactness in the walk.
* *it refuses one of his existing fixtures for a reason you cannot explain* — it
  refuses none of them (§6).
* *the existing geodesic code cannot be reused AND a second implementation would
  disagree with it* — it cannot be reused (§3), and the two answer different
  questions on different sets, so there is no verdict to disagree about.
* *you find yourself relaxing the connectivity definition to make a case pass* —
  the opposite happened: the connectivity is the strictest of the three options
  and section C is built to fail if it were relaxed.

---

## 12. WHAT THIS DOES NOT DO

* **It does not model the exported solid shell as a barrier.** §0. With
  `outer_finish: "shell"` the file carries the marching-cubes surface of the
  printed set closed over the whole part. This check is a statement about the
  design field the certificate and the file are both derived from. Deciding
  whether that surface must be opened over a boundary lattice cell is the
  `"skin"` / `"shell+skin"` outer finish's question, and it is stated in the
  receipt's `scope_note` rather than left implicit.
* **It does not check solid fragments.** §3.
* **It does not auto-correct.** By design.
* **It is not VTM.** No optimizer constraint, no gradient, nothing differentiable.
  If he later wants the OPTIMIZER to avoid making sealed cavities rather than
  being told about them afterwards, that is the Virtual Temperature Method and it
  is a separate task in `simp/`.
* **It says nothing about whether a drain path is WIDE ENOUGH.** A one-voxel
  channel counts as open. `escape_depth_voxels` says how far in the path runs;
  nothing here says how narrow it is, and §3 explains why the belt's
  narrowest-separator metric could not honestly be transplanted to answer it.

---

## 13. IN PLAIN LANGUAGE — WHAT WAS DONE, AND WHAT IS NEXT

**What you asked for, and what you got.** You said: if it isn't visible from the
outside, don't make it. Taken literally that would have banned every interior
lattice, including the pockets inside optimised tendrils that you actually want.
So the rule we built is the one that means the same thing without banning them:
**the empty space inside any lattice has to connect to the outside of the part.**
No sealed pockets. That is also a real printing constraint — powder, resin or
support inside a sealed pocket can never come out.

**It is off unless you turn it on.** Add
`"require_lattice_void_reaches_exterior": true` to the `lattice` block of a job.
Leave it out and every run is byte-for-byte what it was before — proved by
building two separate binaries and comparing every file, not by arguing it.

**When it fires it refuses and tells you where.** It will not open a cavity for
you: that would mean removing material you never asked to remove. Instead the run
stops that rung and tells you how many lattice cells are sealed, how much volume
is trapped, the box the cavity sits in, and which region you drew it in. The rest
of the ladder still runs and still produces its files.

**★ Would your own overnight run have been refused? No.** Your job — the same
part, your eight include regions and one exclude region, at the uniform 8 mm cell
— comes back **open on every rung**. The lattice's escape network touches all six
sides of the design grid, at escape depth 0, meaning the lattice reaches the
part's surface directly. That is exactly the case you described as working fine:
lattices that start from the outside and go in. Your regions are 4 mm-deep slabs
drawn on the outer faces and bolt cylinders that punch through the part, so
there is nothing buried. One caveat worth being straight about: your literal
overnight run's design file (fingerprint b3abcf880554) is not in this repo, so
what was measured is your job DOCUMENT re-run here, not that exact design. The
verdict was the same at every rung and at more than one resolution, which is
about as much confidence as re-running can give.

**The one thing to be aware of.** This rule looks at the design — the voxel
picture the optimiser and the certificate both work from. It does not look at
whether the outer *skin* of the exported STL closes over the lattice. With the
default "shell" finish, the exported file does put a closed surface around the
whole part. Whether that thin outer surface should be opened up over a lattice
region is a different question, and it is the one the "skin" and "shell+skin"
finishes exist to answer. The receipt says this in plain words so it can't be
misread as a clean bill of health for the printed file.

**What is next, in the order I would do it:**

1. **Arm it on a real job you care about and look at the receipt even when it
   passes.** The pass record tells you which faces the lattice drains through and
   how far in it runs. If a lattice you thought was open reports a depth of 20
   voxels, that is worth knowing before you print it.
2. **Decide whether "open" should also mean "open ENOUGH".** Today a one-voxel
   channel counts as a drain path. It probably should not, but the honest way to
   put a minimum aperture on it is to measure real drain behaviour, not to pick a
   number. That is a separate, measurable task.
3. **The shell question.** If you want the exported file — not just the design —
   to be provably drainable, that is a mesh-level check on the union of shell and
   struts, and it belongs next to the outer-finish code.
4. **The optimiser version (VTM), if and only if you want it.** Right now the
   rule tells you afterwards that a pocket is sealed. Making the optimiser avoid
   creating one in the first place needs the Virtual Temperature Method: fill the
   void with a pretend heat-conducting material and constrain the maximum
   temperature, so a sealed pocket becomes expensive rather than merely reported.
   It is a real piece of work and it belongs in the optimiser, not here.
5. **The cousin check — solid pieces attached to nothing.** Same machinery,
   opposite polarity, and cheap now that this one exists. It was not built here
   because it is a different rule and mixing them would make both harder to trust.
