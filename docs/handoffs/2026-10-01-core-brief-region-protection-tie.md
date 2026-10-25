# Core brief: tie region-id protections to their lattice slab, and the in-plane collar (measure only)

2026-10-01, from PR #354's app agent to #358. The maintainer's round-3 ruling (a): "Then write a
core brief with two items. 1. Extend core's depth tie to region-id protections, so a mismatch
refuses instead of passing. It must land AFTER this app fix, or the stand starts refusing. 2. The
in-plane collar: measure only."

**Nothing in core is changed by the app.** Every number below was counted by core's own code: the
CLI's forecast counters and the load case's freeze receipt. Nothing was estimated. The scripts,
inputs and tables are in `docs/handoffs/evidence/2026-10-01-region-protection-tie/`.

## In plain words

- **The app now sends one depth for a protected, latticed region**: the depth its lattice slab
  reaches (depth + expand). That is app commit **87f792d9**. Before it, his stand's region 101 was
  frozen to 20 mm while its slab reached 24.15 mm. The optimizer emptied up to 25 voxels
  (about 1 cm³) of that last 4.15 mm, and core never complained, because its depth tie only
  checks FACE protections.
- **Item 1** asks core to check REGION protections the same way, so a future mismatch is refused
  instead of silently thinning the part. It must land after the app fix. One subtlety needs a
  decision in core: an equal number of millimetres is not an equal set of voxels (see "Equal mm
  are not equal voxels").
- **Item 2** is measured, not designed. On the stand, the expand's in-plane collar has 413
  voxels. A few are outside region 101's own freeze (37 before the fix, 6 after), but none is
  outside every freeze, and the optimizer emptied none of them, before or after.

## The measurement (what both items rest on)

**The design.** His stand (68BF7B74, "M2 verticalStand"), optimized from the stage document's own
loads with mode `minimize_plastic` on CLI aecef72c. It produced 4 accepted rungs: 0.68, 0.52,
0.38 and 0.26. Grid: h = 3.41055860526872 mm (res 64), 39.67 mm³ per voxel. **This is a rebuilt
run, not his retained result.** His `results.plist` holds one variant, at volume fraction 0.2199,
with no protections. The counts are evidence about the mechanism, not about his exact print.

**The method.** Each count is one `topopt-cli lattice-variant` job with `lattice.forecast_only`,
on the real `design.bin`. Only `lattice.regions` varies, used as set algebra:
- a `kind:"region"` lattice region resolves to exactly the voxels the protection freezes, so
  `region_voxels` equals the load-case receipt's `voxels_frozen`;
- a `lattice_part` job counts the original part;
- **emptied = part count − variant count.**

**Positive controls, all exact.**
- region 101 at 20 mm gives 3376 voxels, at 24.15 mm 3780, face 15 4820 and face 2 4203. Each
  equals the run's own receipt.
- The whole-part counterfactual equals `design.bin`'s own count of density ≥ 0.5 at all 8
  rung/design pairs, and the part total, 13287, equals preflight's allowed count.
- An independent recount (`band_check.py`) matches every number.
- Re-running the unchanged optimize job gives a byte-identical `design.bin`, so the after run
  differs in the protection depth alone.

**Region 101's emitted slab**: three face-23 facet prisms, 24.15 mm deep, expanded outline.

| set (part-solid voxels) | count | emptied, rungs 0.68 / 0.52 / 0.38 / 0.26 BEFORE (protected to 20 mm) | AFTER (re-optimized, protected to 24.15 mm) |
|---|---|---|---|
| the whole slab | 3812 | 0 / 9 / 22 / 25 | 0 / 0 / 0 / 0 |
| the slab cut at 20 mm | 3291 | 0 / 0 / 0 / 0 | — |
| **the last 4.15 mm** (20 < depth ≤ 24.15) | **521** | **0 / 9 / 22 / 25** | **0 / 0 / 0 / 0** |
| outside region 101's own freeze | 436 before, 68 after | 0 / 9 / 22 / 25 | 0 / 0 / 0 / 0 |
| outside EVERY freeze (pad, faces 15 and 2, region 101) | 40 before, 0 after | 0 / 9 / 22 / 25 | — |

Nothing was emptied inside any frozen mask at any rung.

**The after run.**
- Its receipt reads `face-protection region=101 voxels_frozen=3780 depth=7 requested=24.15mm
  effective=23.87mm status=ok`.
- The freeze grows by 404 voxels, 36 of them outside the slab, so the design changes slightly
  beyond the band: the printed fraction at rung 0.26 goes 0.9658 → 0.9683.

## Item 1: tie region-id protections to their slab (must land AFTER app 87f792d9)

**Today.** The tie (`core/src/cli/job.cpp` ~2439-2468) compares each face-kind lattice region's
`face_id` with `loads.face_protection_face_ids` only. Region protections (`region_id` entries,
parsed at job.cpp ~763-794 and frozen in `loadcase.cpp` ~639-660 through `region_depth_layers` +
`mask_step_region`) are never compared. A job protecting region 101 to 20 mm while latticing its
member face 23 to 24.15 mm is accepted, and the run leaves the last 4.15 mm of that slab
unprotected. That is the failure the tie exists to prevent: core's own comment calls it "void the
optimizer removed".

**The ask.** For each `face_protection_region_ids[i]`, compare its depth with every face-kind
lattice region whose `face_id` is a member of that region, and refuse a difference with both
numbers. Please make the message parseable by the app's existing reader
(`LatticeVariantProtectionTie`, LatticeVariantSession.swift), the way the face tie's message is:

> region R is BOTH protected and a lattice region, at two different depths: the protection is X mm
> and the lattice region is Y mm. …

The app will then say it in the maintainer's words, as it does for faces.

**Three traps, found while measuring. Core's call:**
1. **Face-id spaces.** `loads.face_regions[].add` lists the faces as the app stored them, while a
   prism's `face_id` is the RUN face id (`resolvedRunFaceID` resolves surface edits). On his
   projects they coincide. Resolve membership the way `resolve_face_regions` does for the freeze,
   not by comparing raw lists.
2. **A face that is both a direct face of a group and a member of that group's region.** The app
   emits it once, under the FACE (`LatticeRegionEmission.swift` ~431, `!direct.contains(f)`), at
   the face's depth. A naive region tie would compare it with the region's depth and refuse a
   legitimate job. Core refuses `region_id` on face-kind lattice regions (job.cpp ~1359-1362), so
   no provenance key exists to tell the two apart. Either add one, or skip a member face that is
   also a face protection. Not present in his projects.
3. **Equal mm are not equal voxels.** The slab is continuous: a voxel belongs when its centre
   depth is ≤ X. The freeze is `region_depth_layers` = round(X/h) layers, holding voxels whose
   centre is within (N − ½)·h. At X = 24.15 mm and h = 3.41 mm that is 7 layers, 22.17 mm. So
   even after the app fix, **68 slab voxels** (centres 22.17–24.15 mm deep) are outside region
   101's own freeze. On the stand they are held only because face 2, face 15 and the pad are
   protected too. On a part without such neighbours the optimizer could still empty the last
   ~2 mm of a tilted slab. Possible remedies, core's to choose:
   - freeze ceil-based layers so that (N − ½)·h ≥ X;
   - test freeze membership against the slab the way `kind:"region"` lattice membership does.

   Whatever is chosen should hold for face protections too (`mask_step_face`, same rounding).

**Sequencing.**
- Land after app commit 87f792d9. From it on, the stage job sends the slab's depth for a
  protected, latticed region; before it, the stand's stage job would be refused.
- **Retained runs made before the app fix** still carry the old region depth: their loads are
  copied byte for byte into a variant's job. Once the region tie lands, such a variant job is
  refused until he re-optimizes. That is ruling 3's behaviour for faces. No project in his store
  has re-lattice artifacts today, so this is a general note, not the stand's.
- **The app follow-up:** teach `variantJobCoreRefusal` the region message once core's text exists.
  The app does not guess its wording.

## Item 2: the in-plane collar (measure only, no design change)

**What the collar is.** An expand grows a wall's outline outward in plane (`LatticeSlabExpand`,
`inPlaneOffsetMM`) as well as its depth. The collar is the part of the slab outside the face's own
(unexpanded) outline. The protection holds only what lies within (N − ½)·h of the face's own
triangles, a 3D distance (`mask_step_face` / `mask_step_region`). So the collar is held near the
surface and less toward the slab's floor.

**On the stand,** only region 101 has an in-plane expand (4.15 mm):

| collar, part-solid voxels | count | emptied, 0.68 / 0.52 / 0.38 / 0.26, before | after |
|---|---|---|---|
| the collar | **413** | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| outside region 101's own freeze | **37** at 20 mm, **6** at 24.15 mm | 0 | 0 |
| outside EVERY freeze | **0** before and after | — | — |

**Answer:** some collar voxels are outside region 101's own freeze, but none is outside every
freeze, and the optimizer emptied **none**, before or after. Full coverage comes from face 2's
protection, which is specific to this part.

**Limit.** The unexpanded outline comes from a Python inverse of the app's `offsetRing`
(`outline_u.py`: exact round trip ≤ 3.3e-9 mm, area within 0.3 % of core's). The collar/outline
split depends on it; the totals and the emptied counts do not.

**Suggestion, not a design:** a receipt line for collar voxels outside every freeze would let a
part that lacks the neighbouring protection say so. Nothing changes until the maintainer rules.

## Files

`docs/handoffs/evidence/2026-10-01-region-protection-tie/`:
- `README.txt` and the job generators (`make_jobs*.py`), which define the sets;
- `run1.sh` / `run1a.sh`, which run one forecast job (about 2 s);
- `opt_run.sh`, the before/after optimize;
- `tabulate.py`, `table.json`, `table_before.txt`, `table_after.txt`;
- the two optimize receipts;
- `band_check.py`, the independent recount;
- `outline_u.py` / `outline_unexpanded.json`, the collar split.

The scripts name the scratchpad paths they ran in. Their inputs are the stand's model, the stage
document (`dump/sync-68BF7B74…json`) and the optimize run's `design.bin`.
