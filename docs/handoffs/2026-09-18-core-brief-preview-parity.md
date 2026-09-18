# CORE BRIEF — the run's STL must be EXACTLY the preview (Octet truss + Organic, Aesthetic + Structural)

App side, 2026-09-18. Maintainer's ruling: "I want the core algorithm to push out STLs
that look EXACTLY like what the preview shows." Everything below is what the preview
does, quoted from the app's code with the numbers it uses, so the run can lay down the
same geometry. Where the two already share a function it is said; where they diverge
it is named and a decision is asked for (§4).

Reference part: his M2 verticalStand, bead 0.45 mm, two face regions (12 mm and
10.31 mm walls), band [0.073, 0.90], γ = 1, Fine 128 (voxel ≈ 1.67 mm).

──────────────────────────────────────────────────────────────────────────────────
## 1. OCTET TRUSS — what the preview builds, step by step
──────────────────────────────────────────────────────────────────────────────────

### 1.1 Regions and the base cell (per include face-prism region)
- Wall width along the region normal: the MEASURED width field (`LatticeMeasuredRegionWidth
  .wallWidthAlongNormalMM`), p50 for Stepped/Default Grade, p05 for Fit; falls back to the
  member-thickness field, then the declared depth.
- Base cell = core's own derivation `lattice_region_derivation(topology, memberWidthMM = w,
  min_extrudable_width_mm = bead, cells_per_member_floor)` — the floor is the stage's
  (`cellsPerMemberFloor`, single-cell members lowers it to 1) — then WHOLE CELLS THROUGH
  THE WALL: `effDepth = min(depth, w); n = max(1, round(effDepth / cell)); cell = effDepth / n`.
  A user-stated cell (per face) replaces the derivation (cap-only, no floor division).
- His part: 12.00 mm (front wall) and 10.31 mm (back wall).

### 1.2 Where cells sit
- Slots start AT THE FACE PLANE and go into the part: slot k spans [plane + k·S, plane + (k+1)·S)
  along the normal (for a −normal face, the mirror). In-plane the slot grid is anchored by a
  SEARCH: 8 offsets per in-plane axis within one base cell (64 combos for a wall), scored by
  the base-cell VOLUME that fits whole; ties broken by the next rung's fitting volume.
  (`LatticeOctreeBake`, `keptVolume`; the DIAG line prints `anchor=(x,y,z)`.)
- Two regions on one axis get their own tilings (the face plane of each is a cell boundary).

### 1.3 The size ladder / menu
- Floor for any tile: `floorMM = max(4 × bead, voxel, 0.5)` (`printableFloorBeads = 4`; 1.8 mm
  at 0.45).
- DEFAULT GRADE ("doubled"): halves only — S, S/2, S/4 … while ≥ floor AND (Aesthetic) the
  bead-wide strut in that tile is ≤ 20 % dense (`finestRungMaxDensity = 0.20`, by core's octet
  law). 12 → 6 → 3; 10.31 → 5.16 → 2.58.
- STEPPED ("stepped"): every k·(S/n), n ≤ 6, whose tile S/n is ≥ floor and (Aesthetic) prints
  ≤ 20 %; under STRUCTURAL the floor alone (`stepped_min_tile_mm` = 4 × bead). Already in
  core (PR #358) and cross-checked: 12 → 12 9.6 9 8 7.2 6 4.8 4 3 2.4 (aesthetic), + 10 and 2
  (structural).
- Texel pitch = the finest tile of all regions; a texel belongs to the cell its MIDDLE is in.

### 1.4 Placement (the octree; `place` / `packSlot`)
- A cell of size S at slot `lo` STANDS iff all 8 corners (pulled in by
  `eps = min(0.05·S, 0.2)`) are (a) ≥ `band` inside the face outline, where
  `band = beam + bleed` (§1.5), and (b) inside material, tested `min(0.6·voxel, 0.45·S)` in
  from the corner (the voxel occupancy is eroded ~0.6 mm at every surface), and (c) the
  CENTRE RULE: with a shape band B > 0 a cell of size S needs its centre
  `dCentre ≥ B·(S − f)/(S0 − f)` in from the outline (f = finest tile, S0 = base); the finest
  is never held back, the base keeps its centre a full band in.
- A base slot that fails: Default Grade recurses into its halves; Stepped PACKS it (largest
  menu size first, any multiple of its own tile inside the slot, depth from the face inward,
  no overlaps) then fills what is left with the finest tile.
- Nothing is ever CUT: a finest tile the outline crosses is painted only where it is inside
  the outline (`edge`), and the solid outline is drawn over it. No cell is cut by a neighbour.
- The app SENDS the result as `lattice.stepped_cells` (core parses it since PR #358) — for a
  Stepped run the placement question is closed: lay down the list. For Default Grade the same
  list could be sent under `"doubled"` if core wants it; say so.

### 1.5 The solid outline (only when the shape grade is on)
- ONE thin beam swept round the face outline, width `beam = max(2 × bead, trim + 0.5 × voxel)`,
  `trim = clamp(0.35 × voxel, 0.10, 0.35)` (≈ 1.21 mm on his part); as deep as the wall at
  each outline vertex; drawn as a MESH ribbon (a true parallel offset of the outline, corners
  never self-overlapping). Cells keep clear of it (§1.4a).
- BLEED: for band B ≥ 25 mm the solid grows inward by `(B − 15)/2` mm (5 mm at 25, 7.5 at 30);
  below 25 nothing. Cells keep clear of beam + bleed.
- Struts of the cells beside the beam are clipped at beam/2 from the outline
  (`dRegion = max(dRegion, 0.5·beam − dOutline)`), so they END INSIDE the solid.
- Without the shape grade there is NO outline beam; the finish dressing (§1.8) is the edge.

### 1.6 Density per cell (relative density ρ the strut is sized at)
- Demand d ∈ [0,1] per texel from the FEA of the SOLID part (§1.11); `ρ = lo + (hi − lo)·d^γ`
  with the project's band (lo, hi) and γ (his: 0.073, 0.90, 1).
- AESTHETIC CEILING (octet only, Allow quilt off): the SIMULATED map is RESCALED so d = 1
  lands on `ceiling = ρ(strut/cell = 0.20) ≈ 0.219` (core's law inverted at a 4 mm cell):
  `d ← d × demandCap`, `demandCap = ((ceiling − lo)/(hi − lo))^(1/γ)` (0.177 on his band).
  A STATED (manual) density is CLIPPED at the ceiling instead; Allow quilt lifts the clip.
  ★ THIS CAP IS APPLIED UNDER BOTH STAGE MODES TODAY (see §4-D).
- THE BAND'S QUILT (shape grade on, band B > 0): for a texel at outline distance t·B
  (t ∈ [0,1]): `ρ ← max(ρ, ρ + (q − ρ)·(1 − t)·share)`, `q = min(drawnHi, quiltRowDensity(S))`
  (≈ 0.60 for the octet: where core's table saturates), `share = 1` for the finest tile,
  `0.35` for any coarser cell (`coarseCellBandRaise`). Only the finest tile quilts.
- PRINTABILITY FLOOR per cell: `ρ ≥ printabilityDensityFloor(bead, S)` = the density at which
  core's law gives a bead-wide strut (17 % at 2.58 mm, 13 % at 3, < 7 % at 12).
- `drawnHi = max(hi, quiltTop)`; ρ is clamped to it.

### 1.7 Strut radius
- `r = octet_strut_diameter_mm(ρ, S) / 2` — CORE'S MEASURED LAW, sampled at 32 points per
  bake and interpolated in the shader; no closed form. Identical to the run by construction.
- The octet cell's 14 nodes (8 corners + 6 face centres), struts corner↔face-centre.

### 1.8 Finish (Rim / Skin / Covered / None) as DRAWN
- Rim (level 1): struts within `dressingBand = max(skinMM, 2 × bead, 0.2)` of an EDGE
  (|dPart| ≈ 0 ∧ |dRegion| ≈ 0, both bounding surfaces close) are fattened by
  `× (1 + 0.6·edge)` (1.6× at full strength) — a radius multiplier on the struts already
  there, not new geometry.
- Skin (level 2): the same multiplier over the WHOLE latticed boundary (|dClip| within the
  band), plus the edges.
- Covered: a solid outer wall `skinMM = wall ring (printer's own)` — the region is eroded by
  it and the lattice runs inside; the lattice is not on show.
- None: nothing.
- ★ WITH THE SHAPE GRADE ON, NO DRESSING AT ALL on the Stepped/Default path: the outline beam
  IS the rim (`dressing = 0` where the band exists).
- Single-cell members: the JOB resolves the skin to "diagrid" when the finish is None/Rim
  (`jobSkinResolved`); the preview does NOT draw that diagrid (§4-E).

### 1.9 Clipping to the part
- Every strut is clipped by: the part SDF eroded by `trim` (§1.5) ∧ the part's exact bounding
  box ∧ the declared region (already carrying the Covered skin). The 0.75-voxel "surface
  inset" (clamp 0.60–1.80 mm) is a DEPTH BIAS for the picture only — it moves no geometry.
- Cells are never cut by the region: whole cells only (§1.4); at the region's far cap the
  struts end at the cap.

### 1.10 Demand source (the map ρ is graded from)
- Sim: the app's own FEA of the SOLID part (`analyzeSolidLoadCase`, the run's loads/anchors),
  sampled onto the preview grid, turned into a fraction by CORE's `grading_demand_fraction_into
  (intent, allowableMPa, percentile, utilisationTarget)`.
- Uniform: one stated density (clipped at the ceiling unless Allow quilt).
- Per region: SAVED, NOT YET RUN (core has no per-sector density override) — the preview
  draws the cell-derived density.

### 1.11 Aesthetic vs Structural (octet)
- `intent = 0` (Structural, allowable > 0): demand = stress / material allowable.
  `intent = 1` (Aesthetic, or no allowable): demand = stress / a percentile of the part's own
  field. Same core function, same denominators as the run.
- Structural: Stepped menu bounded by the printability floor alone (§1.3);
  `structural_certification: "beam_network"` sent; `stepped_min_tile_mm` sent.
- Structural cells-per-member floor (the stage's `cellsPerMemberFloor`) shapes the base cell.

──────────────────────────────────────────────────────────────────────────────────
## 2. ORGANIC (traced / grown) — already core's functions; the divergences
──────────────────────────────────────────────────────────────────────────────────

### 2.1 The preview IS core (nothing preview-only in the tracer)
- One bridge call, `organic_preview_field` → `grow_organic_lattice` if (growth ∧ layer height)
  else `trace_organic_lattice`, then `generate_organic_lattice(lat, sink, &boundary, 8, …)` —
  the same branch and the same `8` run_job passes. `OrganicParams` set exactly:
  build_dir, min_extrudable_width_mm = bead, overhang_angle_deg (0 when growing),
  rho_min/rho_max = the band (rho_min raised to `kOrganicVdiDensityFloor`),
  strut_diameter_mm = the stated width (0 ⇒ per-voxel bead field), layer_hint_mm,
  anchor_at_region_boundary, transfer_ties, tie_swirl, overhang fillet on the lattice.
- App-side inputs, mirroring run_job: candidate = region voxels (centre at (i+0.5)·h) that
  are material; spacing window graded by von Mises p05→p95 over the candidates
  (`sep = hi − (hi − lo)·t`), Fit = one spacing; shape fit = `OrganicShapeFit` with
  `cellsAcrossMember = 2`, cap = min(2·dist-to-boundary, member/2), floor = 0.5·sep;
  per-voxel bead from core's `organic_strut_diameter_mm(spacing, ρ)` (1024-point table,
  floored at the bead) unless a width is stated; `anchor_at_boundary` re-derived as run_job
  does (backed fraction > 0.5); synthetic stresses (Aesthetic only) via the per-region job
  keys core already has (`synthetic_stress`, `synthetic_foci`, dead fraction 0.02, floor
  0.005 MPa).
- Drawing: each emitted span as a CAPSULE at core's own per-span radius (no minimum but
  1e-4), sphere-swept, with a "wetted join" flare of `1.0 × r` where it enters solid
  (a bead at the wall, function of distance-to-solid only) and an `embed = r` run into the
  solid; clipped by part ∧ bbox ∧ region (NO trim erosion on capsules). Covered: the region
  eroded by the wall ring.
- Rim: `organic_solid_rim_mm` = the typed number, else the floor `max(1.535 × bead, solve
  voxel)`, drawn as a CONTINUOUS in-plane erosion of the region (not voxel-quantised).

### 2.2 Where the run and the preview DIFFER today
- (a) ★ THE RIM BAND: the preview COUNTS the rim voxels and keeps them as candidates, so the
  curves run THROUGH the band INTO the solid and are welded there (the wetted join). Core's
  `apply_organic_solid_rim` still DELETES the band (`mask[e] = 0`), so the run cuts every
  strut back at the rim's inner face. THIS IS THE ONE GEOMETRIC DIVERGENCE IN-SOURCE. Fix in
  core: keep the band as candidate; the rim is a solid the struts enter, and the emission
  welds/flare-fillets them there exactly as the fillet pass does at any other solid.
- (b) `organic_scale` is a JOB key but the PART preview never applies it (only the wizard's
  20 mm sample cube scales its 3–6 mm window). Decision §4-F.
- (c) "Preview: show print repairs" OFF shows the TRACED curves (pre node-merge / free-end
  tie / support prune / stranded drop); the file always has the repairs. Not a parity item —
  the ON picture is the file. Nothing to do.
- (d) Depth stagger is a preview-only EXPERIMENT (deforms core's spans by
  0.27·cell·(cos, sin)(2.39996·layer)); never in the job. Ignore.
- (e) The capsule's wet flare (1.0 × r) is the picture of the file's fillet flares: parity
  requires `organic_overhang_fillet` ON in the job (it is, by default) and core's flare at a
  solid join to be ≈ one radius. Confirm the run's join flare magnitude.
- (f) The sample cube bakes at 64³ and a finer voxel; irrelevant to the run (capsules are
  analytic and the tracer's grid is the tensor's).

──────────────────────────────────────────────────────────────────────────────────
## 3. How to PROVE parity (what core should emit)
──────────────────────────────────────────────────────────────────────────────────
- Octet: the receipt already has the any-step histogram; add per cell (or per size) the ρ
  used and the strut radius, and the outline beam width/depth and bleed. The app's DIAG line
  (`octree pitch=… kept=[…] band=… solidBand=…`) and `densityCeiling … demandCap=…` are the
  numbers to match: same sizes, same counts, same beam, same cap.
- Organic: same inputs ⇒ same functions ⇒ same spans. Have the receipt print the inputs it
  used (window lo/hi, bead, anchor_at_boundary, ties, swirl, fillet, rim, grow/layer,
  synthetic regions) and the span census (count, total length, radius min/p50/max) so the
  app's own `organic trace …` banner can be diffed. After (a) lands the rim census must
  match too.
- One test each: a run's STL against the preview's capsule list / cell list on the same
  job — Hausdorff distance under one bead.

──────────────────────────────────────────────────────────────────────────────────
## 4. THE MAINTAINER'S RULINGS (2026-09-18) — what core does for each
──────────────────────────────────────────────────────────────────────────────────
- A. DEFAULT GRADE CELLS — RULED: the app sends its placed cell list for "doubled" too.
  Core accepts `lattice.stepped_cells` alongside `algorithm: "doubled"` (halves-only
  menu: S, S/2, S/4 … validated the same way) and lays it down; the dyadic planner is
  not consulted when the list is present. One code path for both.
- B. THE SOLID OUTLINE BEAM (§1.5) — core's call: reuse the solid-rim machinery or a
  new "face outline beam" pass. Either way the geometry is §1.5: width
  max(2 × bead, trim + 0.5 × voxel), a true parallel offset of the outline, as deep as the
  wall, plus the ≥ 25 mm bleed rule. Only when the shape grade is on.
- C. QUILT BAND AND COARSE-CELL RAISE (§1.6) — RULED: the app sends ρ PER CELL with the
  cell list. Add `"rho"` to each `stepped_cells` entry (the density the strut is sized
  at, after the band raise, the printability floor and the ceiling); core sizes the
  strut from it with its own law (§1.7) and adds no band term of its own.
- D. THE DENSITY CAP — RULED: THE CAP STAYS, UNDER BOTH MODES, AND IT IS THE USER'S
  SWITCH. The job already carries it: with Allow quilt OFF the app caps the density
  band's top (`max relative density`) at the aesthetic ceiling (≈ 0.219), so run and
  preview agree today. What core must add: when a STRUCTURAL certification fails because
  the density it needs is above the band's top AND that top is the aesthetic ceiling, the
  failure message says so and names the fix — "turn on Allow quilt" — not a bare margin
  number. The app surfaces core's reason verbatim. The user's choice until certification
  needs it.
- E. THE DIAGRID SKIN UNDER SINGLE-CELL MEMBERS — RULED: it is a structural need (a
  one-cell-wide member's struts are severed at the face caps with no node to end on; the
  skin re-ties them — the reason core lets the floor reach one cell only with a finish
  written). Core KEEPS adding the diagrid skin when the finish is None/Rim. The app now
  says so in the preview's settings. No core change.
- F. `organic_scale` — RULED: the app stops writing it for part jobs (the wizard's sample
  cube keeps it for its own window). Core may keep parsing the key; it will not arrive.
- G. THE ORGANIC RIM BAND (§2.2a) — RULED: core keeps the band as CANDIDATE and welds the
  struts into the solid, instead of deleting it. This is the one geometric fix.

## 5. Pointers (app)
`LatticeOctreeBake.swift` (§1.2–1.6), `LatticeOutlineRibbon.swift` (§1.5),
`LatticeSDFMetal.swift` `makeUnifiedUniforms` / `LatticeSDFScene.init` (§1.6, §1.8–1.9, §2),
`UnifiedShading.swift` `lsdf_march`, `cap_*` (§1.8–1.9, §2.1), `LatticeType.swift` (§1.7),
`OrganicShapeFit.swift`, `OrganicSolidRim.swift`, `OrganicSampleCube.swift` (§2),
`docs/handoffs/2026-09-17-core-brief-any-step-stepped-and-beam-certification.md` (Stepped).
