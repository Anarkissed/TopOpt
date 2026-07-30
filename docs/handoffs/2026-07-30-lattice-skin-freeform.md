# Lattice skin on arbitrary curved surfaces — freeform skin + outer finish

**Date:** 2026-07-30 · **Scope:** core/ only · **Evidence:** `evidence/2026-07-30-lattice-skin-freeform/`

## The gap this closes

PR 250's diagrid skin and rim tori dress ANALYTIC faces only. On a real
optimized part the outer boundary is the voxel solid set — no analytic faces —
so its own E2E receipt read `"skin_struts": 0, "rim_elements": 0`: clip and
anchor balls, but no visible skin. This task makes the skin ride the ARBITRARY
voxel-derived surface, and adds a three-way outer finish so the lattice can be
seen from outside.

## What was built

* **Freeform skin** (`lattice_gen.cpp`, armed by `LatticeSkinSpec.freeform`,
  default OFF = byte-identical). Landings attributed to no analytic face
  (`face == -1`, the voxel base) — exactly the landings PR 250 left bare — are
  linked by the SAME mutual-kNN / degree-8 / midpoint-ownership /
  27-neighbourhood-recompute discipline as the analytic diagrid. Three
  additions were forced by measurement, not taste:
  - **Landing dedup.** Clipping an octet corner spills a bundle of
    near-coincident landings; left distinct they exhaust each other's
    kSkinDegree rank budget and the cluster links only to itself — measured
    **15.4% isolated landings** on the curved fixture. Freeform landings
    within `min(2·min(r_a,r_b), 0.3·cell)` collapse to one skin knot
    (greedy, deterministic, freeform-only — analytic faces keep PR 250 bytes).
    After dedup: **0.00% isolated, largest component 100%**.
  - **Asymmetric surface band.** A chord is REJECTED whole (counted, never
    silently bent) when its sampled deviation from the local offset surface
    leaves the band: outward past `max(r_skin, 0.15·cell)` (bulging across a
    concavity — the tube has left the part) or inward past `0.35·cell`
    (tunnelling under a ridge, where nearest-surface projection is no longer
    trustworthy). The tunnel side is generous on purpose: voxel-staircase
    deviations (~half a voxel) on real parts must pass.
  - **Projected station polyline + certified clip.** Accepted chords are
    walked as stations projected onto the composite offset surface
    `{sd == r_skin}` (fixed-budget Newton on the exact SDF — deterministic),
    then every station segment is clipped through the certified Lipschitz
    refinement with the voxel term relaxed by an EXPLICIT sag budget
    (`kSkinSagBudgetMm = 0.045`, strictly under the 0.05 bar): a skin edge
    riding the voxel surface's own offset has f == 0 against the exact voxel
    term — the same degeneracy face exclusion solves for analytic faces, which
    the voxel base cannot offer. Plane and keep-out terms stay EXACT, so kept
    spans still prove zero keep-out intrusion. Station spacing is set so the
    level-set sag stays under half the budget (concave rounding radius of an
    offset at depth d is ≥ d — a distance-function property).

* **Outer finish** (`JobLattice.outer_finish`): `shell` (DEFAULT — solid shell
  exactly as now, byte-identical), `skin` (no shell: the freeform skin IS the
  outer surface — open, see-through), `shell+skin` (shell retained, skin laid
  on it — decorative, closed). A non-shell finish requires `skin: "diagrid"`
  and arms the freeform skin. run_job gates the shell push, and the receipt /
  run_info / stream line carry `outer_finish`, the chord accounting
  (accepted / rejected-band / rejected-projection / clipped-away) and
  `shell_enclosed_volume_mm3` — all keys CONDITIONAL on a non-default finish,
  so a `shell` run's receipt and run_info are byte-identical to PR 250's.

* **The `skin` finish is refused by the receipt, deliberately.** The composite
  posture assumes every latticed voxel carries at least the periodic-octet
  stiffness; the solid shell is what backstopped that assumption at clipped
  boundary cells. The gate itself is FINISH-BLIND (the posture never credited
  the shell — margins are numerically identical across finishes, see E8), so
  an "accepted" receipt for a shell-less export would describe a model the
  file does not honour. `lattice_accepted` is forced false UPSTREAM of the
  gate (like the density-band fast-fail), with a plain `finish_note`; the
  gate's verdict logic and tolerance are untouched.

## Bars — MET / MISSED, with the numbers

Probe fixture (`core/tests/harness/lattice_skin_freeform_probe.cpp`): a CURVED
voxel part (0.5 mm voxels, ~64×48×40 mm, NO analytic base faces): two
overlapping spheres (reentrant crease), a dimple bowl (concavity), a 1.0 mm
slit (deterministic bulge case), a declared 6.000 mm bolt keep-out. Uniform
r = 0.5 mm; graded = 0.3→0.9 mm across the height; skin clamp from a stated
0.8 mm width. "off" = PR 250's boundary finish (freeform disarmed). Real E2E =
PR 250's exact cube job (the one whose receipt said `skin_struts: 0`) plus a
curved cylinder model (r 9 × h 28 mm), all three finishes × two cell sizes.

| Bar | Verdict | Measured |
|---|---|---|
| E1 default byte-identical | **MET** | Stash-rebuild: no-lattice `report.json`+`fields.bin` identical; default-finish cube job **16/16 files byte-identical** (all variant STLs, lattice STLs, receipts, report, fields — `e1_compare.txt`, `e1_checksums.txt`), and ALSO byte-identical to PR 250's committed `out_lattice/`. Full ctest **80/80** green (79 pre-existing + the new `lattice_skin_freeform`). `run_info.json`/`iterations.csv` excluded (timestamp/timing fields only; verified identical modulo `created_wall_ms`/`gen_seconds`/`gen_fraction`) |
| E2 skin appears on a real part | **MET** | Same cube job: `skin_struts` **0 → 6,320** on the vf 0.26 receipt (run total 5,142 accepted chords). Curved, not just flat: **76.7 / 64.4 / 70.0%** of accepted chords sit on surface normals >10° off every axis (probe, 8/4/2 mm). Cylinder (curved model, not a cube), vf 0.26 receipt, `skin` finish: **30,781** skin struts at 2.5 mm cells, **20,285** at 4.0 mm (band-rejected 133 / 24, projection-rejected 8 / 4) |
| E3 skin connected | **MET** | Bar stated before measuring: largest CC ≥ 95% of skin nodes, isolated ≤ 1%. Measured (probe on): **100.0 / 99.83 / 99.83%** CC, **0.00 / 0.17 / 0.17%** isolated at 8/4/2 mm; GRADED **100.0 / 99.80%**, isolated **0.00 / 0.20%** (8/4 mm) — the graded-sparsity risk did not materialise; no supplementary nodes were needed. Chord lengths (min/median/p99/max, mm): 8 mm 1.00/4.12/5.66/5.68; 4 mm 1.00/2.34/2.84/2.84; 2 mm 0.62/1.18/1.42/1.44; graded 4 mm 0.70/2.34/2.87/2.88 |
| E4 nothing leaves the part | **MET** | Max vertex overshoot vs the full predicate: **0.0343 / 0.0265 / 0.0166 mm** (8/4/2 mm), graded **0.0350 / 0.0350** — all under the 0.045 budget, budget under the 0.05 bar (bounded by construction via the certified clip, then measured). Rejections counted: band 0/8/0 (probe; the slit case is pinned at 29 rejections in the unit test at 2.5 mm — at 8 mm and 2 mm the slit's cross-gap pairs fall outside link range), projection 0/15/38; cube E2E: band 45, projection 249 of ~5,400 candidate chords |
| E5 protected regions untouched | **MET** | **0** vertices inside the declared keep-out and min radius **3.000** = declared to 3 dp, every probe config (unit fixture: **2.500** exact). Keep-out terms are never relaxed — kept spans PROVE zero intrusion |
| E6 streaming survives | **MET** | Peak RSS **10.60 / 10.73 / 10.58 MB** (off) → **10.88 / 10.85 / 10.57 MB** (on) at 8/4/2 mm while the STL grows **30.9 → 63.0 → 252.7 MB** (on) — flat in output size. Baseline includes the fixture's 983k-voxel grid+density (~7 MB), constant across cell sizes. No global landing set; dedup/rank stay hood-local |
| E7 generation time | **MET** (measured) | Apple M2 Pro, one sitting, one process at a time, nothing else running. Before (off) → after (on): 8 mm **9.61 → 9.67 s**, 4 mm **23.25 → 23.94 s**, 2 mm **56.24 → 55.15 s**. The freeform skin adds ≤ 3% (within run-to-run noise at 2 mm); the wall is PR 250's deliberate 27-neighbourhood deterministic recompute, now against the exact voxel SDF — the CPU-for-memory trade the task named, measured |
| E8 certification consequence of dropping the shell | **MET** (measured + gated) | Margins are NUMERICALLY IDENTICAL per finish — vf 0.26: 7.436 / 7.436 / 7.436; 0.38: 6.275; 0.52: 4.082; 0.68: 14.001 (`e8_e9_summary.txt`) — because the gate is finish-blind: the posture never credited the shell, so removing it does not change the solve, it invalidates the model's claim to describe the export. Said plainly and gated: `skin` receipts carry `finish_certified: false`, `lattice_accepted: false`, and a `finish_note`; `shell`/`shell+skin` remain accepted. No uncertifiable finish can produce an "accepted" receipt |
| E9 mass accounting | **MET** | Cube job, summed over 4 variants, soup basis (analytic per-primitive sums, overlaps NOT deducted — stated in receipt/run_info): interior **615.0** mm³ everywhere; skin **184.0** (shell — collar edges only) vs **1,909.9** (skin & shell+skin); rim **0** (no plane–bore pair on a voxel base — the PR 250 caveat, unchanged); shell_enclosed **2,575.6** mm³ (divergence theorem, shell+skin receipts; 0 for `skin`) |
| E10 determinism | **MET** | Probe: byte-identical rerun at ALL 8 configs (`E10_BYTE_IDENTICAL=1`). Cube: `skin`/`shell+skin` outputs byte-identical across two runs from DIFFERENT builds (deterministic files; `run_info` differs only in `created_wall_ms`/`gen_seconds`/`gen_fraction`). Cylinder: rerun byte-identical at ALL 6 finish×cell configs (deterministic files; `run_cylinder_matrix.sh` output) |

## The E1 near-miss worth knowing about

Mid-task, the stash-rebuild caught a real E1 violation: the vf 0.68 cube
variant DOES emit collar skin edges on the default path (its voxel wall clears
the bore wall, so landings attribute to the analytic bore face), and an early
version applied the new sag budget to those edges unconditionally
(412 → 380 skin struts). The budget is now armed ONLY with the freeform skin
(`skin.freeform`), and the final build reproduces PR 250's committed artifacts
to the byte. Lesson re-learned: "no skin on the default voxel path" is false
at high volume fractions — only the checksum knows.

## Blocked-stop paths — none taken

* The chord-inside-solid test IS robust on concave regions without any global
  surface structure: band test + projection + certified clip are all local and
  the whole pipeline stayed cell-local (E6 flat).
* The `skin` finish export is the same interpenetrating soup of CLOSED
  primitives PR 201 printed: welded, the unit fixture's skin-finish output has
  **0 boundary edges** (every primitive closed) — the union basis a slicer
  accepts. The known slicer caveat is unchanged from the octet study: classic
  walls, not Arachne.
* Landing density supported a connected skin on the graded fixture (99.8% CC)
  with NO supplementary nodes; the failure mode was rank saturation at corner
  clusters, cured by dedup, not by adding nodes.

## Honest caveats

* **The 0.045 mm sag budget is real overshoot allowance** against the VOXEL
  surface only (measured max 0.035 mm). Keep-outs and planes are never
  relaxed. PR 250's analytic-face skin kept 0.000000; the freeform surface
  cannot have that without the degenerate f == 0 grind.
* **`skin` finish margins are informational.** They describe the same
  shell-blind composite as a `shell` run. The receipt says so and refuses
  acceptance; a certifiable shell-less finish needs strut-level
  de-homogenization (Phase 2) or a boundary-cell knockdown — future work.
* **File size: the freeform skin is expensive in triangles.** Each chord is a
  station polyline of capped prisms (~10–13 segments), so `skin`/`shell+skin`
  exports run ~1.8× the off STL at 2 mm (139.9 → 252.7 MB) and ~6× the
  shell-finish lattice file on the cube job (2.0 → 11.6 MB). Levers:
  `skin: "rim"`, `kSkinDegree`, and a future collinear-run merge pass.
* **`uncertified_spans_dropped` is large on voxel bases** (8.6M at 2 mm,
  ≈ 0.86 mm of centreline per 0.1 µm sliver — present with freeform OFF too):
  interior struts grazing the eroded voxel surface grind the certified
  refinement to its floor. Conservative (dropped, never kept) and inherited
  from PR 250's discipline — first time measured at this scale; it is also
  the dominant CPU cost. A cheap improvement would be a grazing-aware early
  exit; listed under next steps.
* **shell+skin is decorative and partially hidden**: the skin rides the voxel
  surface offset while the shell is the smoothed marching-cubes surface, so
  the skin protrudes through the shell in convex regions and tucks under it
  elsewhere. Volumes overlap on the soup basis (stated).
* **The cylinder E2E's load faces** use pseudo-face ids from STL import
  (anchor = bottom cap, load = top cap by cluster order; the loadcase log
  confirms 331 voxels tagged); its 80 N load is far below capacity, so its
  margins serialize as JSON null (unbounded — the existing convention). The
  structural story of that job is demo-grade — its purpose is real optimized
  curved geometry through all three finishes at two cell sizes.

## Files

* `core/include/topopt/lattice_gen.hpp/.cpp` — `LatticeSkinSpec.freeform`,
  freeform chord pipeline (band → projection → certified emission), landing
  dedup, chord verdict observer + stats; analytic paths byte-identical when
  disarmed (golden tests unchanged).
* `core/include/topopt/lattice_boundary.hpp`, `core/src/mesh/lattice_boundary.cpp`
  — `clip_segment(..., base_relax = 0.0)` (voxel-term-only relaxation),
  `signed_distance_relaxed_base`, shared certified refinement
  (`certified_clip_spans`) — exact same arithmetic on the default path.
* `core/include/topopt/job.hpp`, `core/src/cli/job.cpp` —
  `lattice.outer_finish` (`shell`|`skin`|`shell+skin`, default `shell`;
  non-shell requires diagrid).
* `core/src/cli/run_job.cpp` — shell push gated by finish; freeform armed by
  finish; receipt: conditional finish fields, `describes` per finish,
  `finish_certified`/`finish_note`, upstream refusal of `skin` acceptance;
  run_info + stream line consistent.
* `core/include/topopt/observability.hpp`, `core/src/simp/observability.cpp` —
  conditional `lattice_export` finish keys.
* NEW `core/tests/unit/test_lattice_skin_freeform.cpp` (ctest
  `lattice_skin_freeform`, 13 checks), NEW
  `core/tests/harness/lattice_skin_freeform_probe.cpp` (evidence probe).

## Next steps

* **Slab-window memoization of `cut_cell_struts`** — the 27× deterministic
  recompute is ~all of generation time on voxel bases; a 3-slab cache is
  byte-neutral and O(cells-per-slab) memory, but shifts the B8 story — decide
  deliberately.
* **Collinear-run merging** of freeform polyline segments (file size ÷ ~3 on
  flat stretches).
* **Certifiable shell-less finish**: boundary-cell posture knockdown or
  Phase-2 de-homogenization so `skin` mode can earn acceptance instead of
  being refused.
* **Print validation** of the freeform skin (the 1.5× width TRIPWIRE from
  PR 250 still stands) and of the `skin` finish's sliceability beyond the
  welded-topology check.
* App UI for `outer_finish` (separate app task).

## Plain language: what this does and what comes next

Until now, the woven surface net that ties off the cut ends of a lattice could
only be laid on simple, mathematically described surfaces — flat faces and
drilled holes. But a real optimized part is a curvy, organic shape described
only by tiny cubes, so real parts got no net at all: the lattice was hidden
under a solid outer wall, and the wall was doing the tidying-up.

This change teaches the net to lie on ANY surface. The knots of the net are
the exact points where the lattice bars were cut off at the part's skin, and
the net's threads are laid point-to-point ALONG the curved surface, hugging
it, never poking out more than a twentieth of a millimetre and never entering
a bolt hole by even a hair. Threads that would have to leave the part (across
a dip) or burrow under a ridge are refused and counted, not fudged. On the
same real test part that previously got zero net, the net now appears —
thousands of threads — and it is one connected web over 99.8% of its knots,
even when the lattice is graded thick-to-thin.

You can also now choose what the OUTSIDE of the part looks like: the solid
wall as before (the default — output provably unchanged, byte for byte), the
bare net (see-through, the lattice visible), or wall plus net (decorative).
One honest warning comes with the see-through option: the safety check that
certifies parts silently assumed the solid wall was there to complete the
boundary bricks, so a see-through part CANNOT yet be certified — the report
says so in plain words and refuses to stamp it "accepted" rather than
pretending. Making the see-through finish certifiable, making the net cheaper
in file size, and test-printing it are the natural next steps.
