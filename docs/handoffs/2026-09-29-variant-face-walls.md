# Face walls on a variant: carried as the stage's face prisms

2026-09-29/30, PR #354's branch. App only; core is unchanged (the evidence is in Q1). The
maintainer's ruling this carries out, and his rulings (a)–(g) of 2026-09-30 on the first draft:

> "Don't carry face ids to a variant; the variant has no faces, which is why Z11 exists. The right
> route is to carry each face wall as explicit face-prism geometry."

> (a) "Keep face_id in the variant job's lattice.regions: don't strip it … face_id changes no
> geometry … Keeping it keeps core's depth tie, the error messages and the receipt echoes."

## In plain words

**What works now on a variant.** Check sizes, the forecast and the re-lattice run include your
face walls. Each wall travels as exactly the prism the stage job sends:
- where it sits on the original part;
- the direction it points into the part;
- its size and outline;
- its depth;
- its face id, as provenance.

The variant's job carries the stage's walls, entry for entry. That includes faces, face regions,
curved faces (as their facets), per-wall roles, depths and densities, and the synthetic-stress
flags with each wall's foci count.

His stand's variant job used to carry **0 walls**, and with no walls core latticed the whole
variant. It now carries faces 15 and 2 and region 101's three facets (see "The stand").

**Also new, from rulings (b)–(g):**
- **(b)** A variant's octet Auto job resolves Auto exactly as the stage does: the swept window comes
  from the walls and the bead, and the per-region report is on. It is one spec builder, in its own
  commit. The stage's job bytes did not move.
- **(c)** A variant with no include wall is refused in the stage's words, "nothing set to lattice",
  on the button, the forecast and Check sizes. It is never latticed whole.
- **(d)** A Check-sizes answer stored before this route is kept but no longer used. The wizard says
  "Sizes need re-checking — tap Check sizes."
- **(e)** Tapping a face on a variant says: "You can't pick faces on an optimised result — the walls
  you marked on the part carry over."
- **(g)** A face region the run cannot consume, such as a cut sector, is counted and **named**. The
  stage's preview banner names it, and so do the variant's Check sizes, forecast and re-lattice.

**What still doesn't.**
- **You still can't tap faces on a variant**; it has none. Walls are authored on the part and ride
  along.
- **A wall is judged against the original face plane.** Where the optimizer thinned the part inside
  the prism, the lattice starts at the variant's own surface, and core counts the emptied voxels.
  The extents that Fit and the organic recommendation use are still the declared wall's (see Q3).
- **Core's depth tie now runs on a variant's job** (ruling a). A wall whose depth, or expand,
  differs from the protection the optimize run froze makes core refuse the job, in its own words,
  before any solve. The fix is to set the wall back to the run's depth, or to optimize again.

The numbers are at the end: "The stand", "Hashes", "Tests" and "The suite". Commits:
- **25e8f869**: the route, with rulings (a), (c)–(g);
- **044dd9ab**: ruling (b).

## Step 1: the five answers

### Q1. Does core resolve a face prism with no `face_id` against a variant's voxels?

**Yes, with no core change.** From the source:
- `face_id` is optional provenance. It is parsed only if present, and the default is −1, "not from
  a face" (job.cpp:1333-1342, job.hpp).
- A face region's geometry is built only from origin, normal, half-extents, outline and frame
  (run_job.cpp:991-1003). It is resolved by `resolve_clearance_manual`, an analytic predicate that
  sees no model and no grid (clearance.cpp:224-282). Membership is the slab, the box and an
  even-odd test on the outline (clearance.cpp:133-159).
- `face_id` is used only for:
  - the depth tie against `loads.face_protections`, which is skipped when the id is < 0
    (job.cpp:2419-2438);
  - one error message (run_job.cpp:1012);
  - echoes in receipts and logs (run_job.cpp:4383/4411/5555/5847/10247, observability.cpp:1498).
- `lattice_variant` and the stage's `lattice_part` run the same function; only the source of the
  density differs (run_job.cpp:9521-9533, 9677-9710).
  - It imports the ORIGINAL model and requires `design.bin` on the exact solved grid
    (9584, 9670, 9730-9749). A prism placed in model space therefore indexes the variant's voxels
    directly.
  - It resolves the regions for the forecast (9905-9912) and for the run (10049-10053).
  - It then runs the same `lattice_one_variant` the optimize path runs on every rung with face
    prisms (12130-12138).

**Proved through a fresh `topopt-cli`.** Core aecef72c291a, built 2026-09-29 23:14:25 in the
scratchpad; the main checkout's `core/build/topopt-cli` is from Aug 13 and does not know
`frame_u`.
- Setup: `plate_bore.stl` at resolution 32, optimized to one variant (vf 0.60).
- Region A is an include face prism with **no `face_id`**: normal (0,0,−1), 12 × 7 mm, depth 4,
  outline and frame.

| job | what | result |
|---|---|---|
| J0 | `lattice_part` forecast | region_voxels **800** (P_full) |
| J0f | `lattice_part` run | include_void_by_optimizer **0** (V_full) |
| J1 | `lattice_variant` forecast | include_regions 1, region_voxels **478** (P_var < P_full: positive control) |
| J2 | `lattice_variant` run | include 1, include_void_by_optimizer **322**; STL `37b61b17…` |
| J2b | J2 again | identical (noise floor: deterministic) |
| J3 | J2 + `"face_id": 7` | identical counts and **identical STL hash**: face_id changes no geometry |
| J4 | frame_u / frame_w swapped | **refused** before any forecast: "lattice region 1 (face −1) … do not match the in-plane basis" |
| J5 | triangle outline | region_voxels 236 = **0.49** × P_var (the outline is read) |
| J6 | no regions | include_regions 0, region_voxels **1909** (the whole variant) |
| J7 | normal flipped to +z | region_voxels **0** (the app's inward normal carries the meaning) |

- V_var − V_full = 322 − 0 = **322 = P_full − P_var = 800 − 478**, exactly. The prism voxels the
  optimizer emptied are the ones core counts as void, and none is latticed.
- J6 is the behaviour the stand had before this change. With no include region, core lattices
  every printed voxel of the variant.

### Q2. Exactly which keys does the stage job send per face wall?

Read from `LatticeRegionSpec.wireDictionary` (LatticeSettings.swift) and dumped with
`LatticeJobJSONDump` (the stand's lines are under "The stand" below). A planar face wall looks like
this:

```
{"role": "include" | "exclude", "kind": "face",
 "geometry": {"origin": [...], "normal": [...], "half_u_mm": hu, "half_w_mm": hw,
              "depth_mm": d, "outline_uv": [[[u, w], ...], ...],
              "frame_u": [...], "frame_w": [...]},
 "face_id": <run face id>, "relative_density": rho,
 "synthetic_stress": true, "synthetic_foci": n}
```

- **origin**: the outline centre on the ORIGINAL face plane.
- **normal**: the INWARD normal.
- **half_u_mm / half_w_mm**: the outline's box, grown to hold the outline as sent.
- **depth_mm**: the wall's depth plus its expand, floored at 0.1.
- **outline_uv**: the outline in the slab frame, offset outward by the expand on true edges and
  pushed out across diverging seams.
- **frame_u / frame_w**: only when the linked core takes them.
- **relative_density**: only on an include wall with a stated density.
- **synthetic_stress / synthetic_foci**: only when the wall is flagged and the core takes the keys.
- A cylinder face is sent as `kind: "bolt"`.
- A curved face (the stand's face 23) is sent as one prism per facet. The facets share the face's
  id and key.

### Q3. How are the outline, the frame and the depth carried when the variant's surface differs?

**Unchanged.** They are world-space constants on the ORIGINAL face plane. Core does not re-project
them onto the variant, and tests them at the solved grid's voxel centres.
- **Where the optimizer removed material inside the prism:**
  - Those voxels are not latticed; a lattice voxel must be in the prism AND printed on the variant
    (run_job.cpp:5347-5383; lattice_boundary.cpp:416-447).
  - They are counted in the receipt's `regions.include_void_by_optimizer`, which counts air as
    well.
  - Struts are clipped to the variant's own exported surface.
  - A hole the optimizer punched through the wall inside the prism grows the organic solid rim, or
    the octet's shape-grade beam, as it already does on the optimize path.
- **Where the variant's surface receded from the face plane by δ:** the first δ of the prism is
  void, so the lattice starts at the variant's surface and is depth − δ deep.
- **Where it advanced past the plane:** that material is outside the prism (s < 0) and stays solid.
  A graded run with a design box is refused on the variant path.
- **Still read from the DECLARED wall:** Fit's extent, min(depth, 2hu, 2hw) (run_job.cpp:1135-1140),
  and the organic recommendation's extents. On a thinned variant both describe the original wall.
  Member thickness and stress are read from the variant itself.
- **How often it matters:** a lattice face must be in a protected, anchor or load group, and those
  are frozen solid during the optimize run to the protection depth. So the prism is mostly frozen
  material, and a receded surface appears only where the lattice depth or the expand reaches past
  what was frozen.

### Q4. What must bar Z11 and its test become?

**Z11, as ruled (a), 2026-09-30:**
> Face TAPPING on a variant stays refused. Face walls travel as the stage's full prism, face_id
> included as provenance.

- `variantLatticeJobRegions()` is now `latticeJobRegions()`.
- `RelatticeJobBuilder` sends each region's `wireDictionary` with its face id. The only change is
  the outline's loop order, fixed for byte-stability (see "What changed").
- Core's variant path imports the original part, where the id is real, and J3 shows the id
  changes no geometry. Keeping it keeps core's depth tie, its messages and its receipt echoes.
- The app does not re-implement the tie. `LatticeSlabDepth.mismatches` is marked as a test mirror
  with no run-path caller.

My first draft stripped the id. The test that proves why keeping it matters,
`testCoresDepthTieIsLiveOnAVariantJob`, sends the variant's documents through core's own parser.
The retained run froze face 1 at 20 mm:
- a wall at 20 mm is accepted;
- a wall at 12 mm is refused with core's message, "the protection is 20.000000 mm and the lattice
  region is 12.000000 mm";
- the same refused bytes with `face_id` stripped are **accepted**. The strip would have hidden a
  real disagreement.

Z11's tests: `testVariantEmissionEmitsPrimitivesAndRefusesFaces` is replaced by
`testTheVariantJobCarriesEachFaceWallAsItsPrism`,
`testTheVariantJobCarriesTheStagesRegionsFaceIDsIncluded` and
`testCoresDepthTieIsLiveOnAVariantJob`. See "Tests".

### Q5. Do the synthetic-stress flags and per-wall foci ride along?

**Yes, with no new code.** The variant's regions are the stage's `regions(synthetic:)`, so:
- every include face wall is flagged, with the wall's own foci count, or else the default of 4;
- the facets of one curved face, and the member faces of one region, share one count;
- the gate is the stage's own (organic, Aesthetic, simulation on, synthesis on).

Core numbers the include regions in declaration order, and the variant's order is the stage's. So
region N in the synthetic report is the same wall in the preview, the stage run and the variant
run. The stepped cells' region ids line up for the same reason (see the core brief).

## Step 2: decision

**Build.** Q1 shows core already resolves the geometry with no core change. Two latent core bugs
turned up that did not block this work. They went into a core brief rather than a workaround:
`2026-09-29-core-brief-face-region-frame-and-stepped-index.md`.

**Both are now FIXED in #358's 12ff5880** (maintainer, 2026-09-30): the in-plane frame check fires
at parse time, and stepped plans resolve region ids by include order. Core checked the app's frame
construction and stepped ids and found nothing to change. After this branch syncs with #358, a
stepped or any-step plan with an exclude wall before an include wall runs instead of being
refused.

## What changed

### Commit 1: the route, with rulings (a), (c), (d), (e), (f), (g)

- **The route.** `ProjectModel.variantLatticeJobRegions()` is `latticeJobRegions()`: the variant
  gets the stage's walls with the stage's gates (eligible roles, per-wall role, depth, density,
  expand, face regions, facets, seams, synthetic flags). V1's placed-shapes-only emission is
  deleted.
- **(a)** `RelatticeJobBuilder` sends each region's `wireDictionary` with `face_id`.
  Comments that said otherwise were rewritten (`wireDictionary`, `variantLatticeJobRegions`,
  `relatticeJobJSON`, `LatticeVariantAuthoring`, `LatticeSlabDepth.mismatches`).
- **(c)** `LatticeJobIncludeGate` holds the stage's words ("lattice mode is off", "nothing set to
  lattice"), and the stage's summary now reads them from there. Every place a variant job is built
  or offered checks it:
  - `relatticeJobJSON` refuses to build the document, covering the run, the forecast and Check
    sizes;
  - the "Lattice this variant" button is disabled, with the words as its sub-line;
  - the forecast drawer says "Can’t forecast: nothing set to lattice.";
  - Check sizes refuses, and the wizard says so once;
  - the run raises a toast as a second layer.

  The page reads one emission per pass for this and the left-out line together
  (`latticeVariantJobFacts`), and the wizard reads its cached emission, so no new per-frame
  emission was added.
- **(d)** `OrganicForecast.jobRoute` (route 1) is stamped by Check sizes.
  - `LatticeSettings.currentOrganicForecast` is the only reader of the stored answer, and all ten
    readers were switched. A test fails on any new direct reader.
  - A stale answer is kept on disk and never used.
  - The wizard says "Sizes need re-checking — tap Check sizes." When Check sizes can't act, it says
    why instead.
- **(e)** The tap refusal is his sentence, verbatim.
- **(f/g)** One sentence builder, `LatticeWallsWithoutShape`, serves the stage's preview banner and
  the variant's line.
  - A face region the run cannot consume is counted and named (`skippedRegionNames`).
  - It is not named when its surface is latticed through an ancestor that sits in the same group
    and emitted, i.e. a whole-face parent over its cut children.
  - A region gone from the model is not named either.
  - The names travel with the Check-sizes answer, the re-lattice result and the stored outcome.
  - The banner's old "1 marked face has … and **are** not shown" now reads "is".
  - An empty preview names the drop first. It adds the depth advice only when an include wall was
    emitted: the stage clips an emission with no include wall to nothing.
  - A child is carried by its whole-face parent only when the parent emits WITH THE CHILD'S OWN
    ROLE. An Off parent, or one with another role, gets the child named.
  - A re-lattice result stored by the V1 build keeps a line that is still true of it: "Made before
    face walls reached variants: N face walls were left out." It is read from V1's key and written
    back only for such a result.
- **Stored counts renamed** (`variantFacesWithoutShape`, `facesWithoutShape`). V1's count meant
  "every face wall", so it is never shown with the new words.
- **One order for one outline**, found while testing.
  - The emission's outline loops come out in **hash order**: the same polygon, rotated or
    reordered from one call to the next.
    - Measured: 2 orderings in 20 in-process emissions of one project.
    - With `SWIFT_DETERMINISTIC_HASHING=1`, 1 ordering in 20.
    - The stage dumps of one project also differed between launches.
  - A variant's forecast is keyed on its document's bytes, and `.task(id: forecastJob)`
    re-requests it whenever they change. So a variant carrying face walls would have kept sending
    forecast jobs to the worker.
  - `RelatticeJobBuilder` now writes each outline loop starting from its smallest (u, w) vertex,
    with the loops ordered by that vertex. This covers variant documents only; the geometry is
    unchanged (core reads the outline even-odd), and the stage's bytes are untouched. See open item
    7.

### Commit 2: ruling (b), Auto resolved on the variant job as on the stage

- `ProjectModel.latticeRunSpec(emission:)` is `AppModel.makeRunRequest`'s lattice recipe, moved
  verbatim: the posture, `runSpec`, then the stepped cells.
- `makeRunRequest`, `relatticeJobJSON` and the receipt echo all call it. The echo is now the
  submitted job's own spec, so the per-region rows Auto asks for are kept.
- The strut-width tripwire is re-pinned from 14 to 12 sites, with an audit note: four sites became
  two.

## Rulings (a)–(g), and what is still open

- (a) **RULED: keep `face_id`.** Done; see Q4. The app does not re-implement the tie.
- (b) **RULED: posture on the variant job, separate commit, stage hashes unchanged.** Done;
  commit 2. The stage hashes are below.
- (c) **RULED: refuse with no include wall, in the stage's words.** Done. My earlier sentence that
  the stage's `canLatticeThis` refuses this was wrong: it refuses only an EMPTY region list. An
  exclude-only stage project gets an enabled Lattice button while its sub-line says "nothing set to
  lattice". I left that alone; see open item 3.
- (d) **RULED: invalidate pre-route answers and say sizes need re-checking.** Done.
- (e) **RULED: his sentence.** Done, verbatim. He wrote "can't" with a straight apostrophe and
  "optimised". The app's other strings use ’ and "optimized"; tell me if either should match the
  house style.
- (f) **RULED: the notice wording is accepted.** Unchanged, byte for byte for faces.
- (g) **RULED: count and name dropped cut sectors, stage and variants, same notice.** Done.

Open, and needing his ruling:
1. **An expand on a protected, latticed face wall is refused by core's depth tie on the STAGE
   job.** The region sends depth + expand; the protection sends the depth alone.
   **Verified through core's parser:** face 1 is protected at 20 mm and given a 1 mm expand. The
   stage job is refused with "the protection is 20.000000 mm and the lattice region is 21.000000
   mm"; with no expand it is accepted. Either fix moves the stage's bytes, so nothing was done. It
   is also in the core brief.
2. **Old retained runs** (read from RemoteRunner's protection encoding, not run). A variant whose
   optimize run predates per-face protection depths carries bare ids at the global depth, so each
   protected, latticed wall on it is now refused unless it is at that depth. This is core's tie
   working as ruled, but it is new behaviour on old results.
3. **The stage's exclude-only Lattice button** is enabled while its sub-line says "nothing set to
   lattice" (see (c)).
4. **"Optimize from scratch" with lattice on and no include wall** still lattices every accepted
   variant whole: `LatticeOptimizeSurface` has no include gate. (c) covers the variant job only.
5. **A one-tap fix for "nothing set to lattice" on a variant** (his rule: blockers surface at once
   with a one-tap fix). Walls are marked on the part, so the fix is to go back to the part.
6. **(d) under Auto.** With the simulation on and Auto picked, a stale answer silently stops
   steering the preview window, and the re-check line shows only under Manual, where the Check
   sizes button lives.
7. **The stage job is not byte-stable.** Its outline loops come out in hash order, so the same
   project gives different `outline_uv` loop orders from one call, or one launch, to the next.
   The geometry is the same, and core reads it even-odd. The variant's documents now fix the order.
   Fixing it at the source (the emission) would change the stage's bytes by loop order only.
   Should it be done? Until then, a stage hash is meaningful only under
   `SWIFT_DETERMINISTIC_HASHING=1`, which is how the hashes below were taken.
8. **Cost on the variant page.** The stage emission now builds the variant's job: ~17 ms per call on
   the stand in a DEBUG build, against 0.01 ms for V1's placed-shapes-only emission. The page calls
   it twice per render pass (the forecast job, and the notice/refusal facts). The page already ran
   the stage emission several times per pass for the bake, Fit and the wizard. A Release number, or
   a cache keyed on the emission's inputs, is the follow-up if you see the page stutter.
9. **Project 102117B9** ("M2 verticalStand", organic Structural) is not listed by the project
   store in these runs; it has no `results.plist`. So it was not dumped. The other six were.

## The stand (M2, 68BF7B74): before and after

His project folder was copied, never written; the container was left alone. There is no variant
on the simulator, so the stand's load case (the stage job's `loads`) was optimized through a fresh
`topopt-cli`:
- 4 accepted variants in 256 s: vf 0.68, 0.52, 0.38 and 0.26;
- measured on the lightest, rung 0.26, fingerprint 1647558251906585232.

`VariantWallsStandProbe` built the variant's documents exactly as `relatticeJobJSON` does. They
were then run through the CLI against that `design.bin`. A Check-sizes job was stopped once
`organic_probe.json` was written, as the app does. Two settings were run:
- his project as saved (stepped, Aesthetic);
- with the one stated substitution, algorithm = organic (the flags act only on organic).

| | before (aecef72c) | after (25e8f869) | the stage's own job |
|---|---|---|---|
| walls in the variant job | **0** (V1 counted 3 face walls left out) | **5 face prisms**: faces 15 and 2, region 101's three facets; `face_id`, outline and frame on each | 5 |
| organic flags / foci | none | all 5 flagged, foci [4, 4, 3, 3, 3] | the same |
| core's parser (incl. the depth tie) | accepts | accepts | accepts |
| forecast (organic) | include 0: **the whole variant, 12832 voxels** | include 5: 9675 voxels in the prisms, all latticed; 3903 prism voxels counted as emptied by the optimizer | n/a |
| Check sizes (organic) | 6 sizes, Fit 6.5, band 3.41–0, no look | 18 sizes, Fit 5.65, Auto 3.58–6, band 3.41–6 | 18 sizes, Fit 5.65, Auto 3.58–6 |
| dead set | none (nothing flagged) | **face 15 DEAD** (p99 0.004902); face 2 0.01808; face 23's facets 0.00713, 0.0101, 0.00767 carry load | face 15 DEAD (0.004903); face 2 0.01808; facets 0.00721, 0.0101, 0.00766 |

- **The variant's dead set matches the stage's, verdict for verdict.** The p99s differ slightly
  (face 15: 0.004902 against 0.004903) because the variant's are measured on its own solve. Face 15
  sits just under the 0.005 floor on both.
- The saved (stepped) arm would lattice 0 voxels before and after: stepped cells come from the
  preview, which the probe does not run.
- Ruling (b) moved the stand's stepped variant job from an unposted swept window of 1.17–9.39 mm to
  6–12.075 mm with the region report. That is the stage's grading block, byte for byte. The organic
  documents did not move.
- The stage's own Check sizes gives the same 18 candidates before and after.

## Hashes: the stage job

All dumps were taken with `LatticeJobJSONDump` on a fresh copy of the simulator's Projects folder
each run, under `SWIFT_DETERMINISTIC_HASHING=1` (see open item 7). SHA-256, first 16 hex digits:

| project | before | before2 | after commit 1 | after commit 2 |
|---|---|---|---|---|
| **M2 stand 68BF7B74** | 297527188edbe40a | = | = | = |
| **octet "l bracket 3" 92A8016E** | fc032b16b1bce281 | = | = | = |
| 570B38E2 (doubled) | 7269596833201a0e | = | = | = |
| 3418E167 | c264e572ab70049c | = | = | = |
| AA4C7953 | 3e6f162cb36212a9 | = | = | = |
| 887AC498 | b457718dfc23ab42 | = | = | = |

- **Positive control:** region 101's expand 4.15 → 4.65 mm moves the stand's hash to
  1e874477f24876f1.
- **Negative control:** before = before2. Without deterministic hashing the same control FAILED on
  three projects, because of the outline loop order. That is how open item 7 was found.

## Tests

New or rewritten, each seen failing with its fix undone:

| test | what it pins | RED control (fix undone) |
|---|---|---|
| `testTheVariantJobCarriesEachFaceWallAsItsPrism` | the variant's regions are the stage's | R1: V1's emission |
| `testTheVariantJobCarriesTheStagesRegionsFaceIDsIncluded` | wire = the stage's entry, face_id included; core accepts run, forecast and Check sizes | R1, Ra (strip back) |
| `testCoresDepthTieIsLiveOnAVariantJob` | 20 accepted, 12 refused in core's words, stripped bytes accepted | R1, Ra |
| `testTheVariantDocumentIsStableAcrossCalls` | one outline order in the variant document | Rs (order removed) |
| `testAVariantJobWithNoIncludeWallRefusesInTheStagesWords` | (c), with the stage's words from one home | Rc (the gate never refuses) |
| `testTheRelatticeButtonAndTheForecastCarryTheIncludeRefusal` | (c) on the button and the drawer, and the page wiring | Rc2 (page), Rc3 (branch) |
| `testVariantAuthoringTurnsFaceTappingOffWithAReason` | (e), verbatim | Re |
| `OrganicForecastRouteTests` (4) | (d): kept, never used, the floor ignores it, one gate for every reader | Rd |
| `testTheSyntheticFlagsRideAlongOnTheFaceWalls` | flags and foci on the face walls, in every document | R1 |
| `testTheNoticeAppearsOnlyWhenAFaceWallIsLeftOut` | the line appears and disappears; the V1 line is gone | R1, Rn |
| `testTheSentenceForDroppedWalls` | the one sentence; face-only byte for byte | Rn |
| `testACutSectorIsCountedAndNamedOnTheStageAndTheVariant` | (g) on stage, variant and banner; the parent rule; the role rule; the empty banner | Rg, Rg2, Rg3, Rb |
| `testAV1EraResultKeepsATrueLine`, `testTheRegionNamesTravelWithTheAnswerAndTheResult` | the stored forms | Rn |
| `LatticeRunSpecSharedTests` (5) | (b): the shipped stage recipe in 7 settings, the call site, the variant's Auto-resolved spec (positive control: the old recipe differs), organic/non-Auto unchanged, one builder | Rb1 (no posture): 3 red; Rb2 (the variant's own recipe back): 1 red |

- Fixtures that built undeclared groups now declare them:
  - `OrganicSyntheticStressTests.variantProject`;
  - the V2 test;
  - `LatticeRetentionControlTests`.

  The variant's job applies the stage's eligible-role gate.
- The strut-width tripwire was re-pinned from 14 to 12, with an audit note.
- **Targeted runs:**
  - commit 1: 380 tests, 1 skipped, 0 failures;
  - commit 2: 313 tests, 1 failure, `LatticeCellGradingTests.testGradingChangesTheRenderedLattice`
    (one of the known 7).
- **iOS app build succeeded on both commits.** The changed files' objects were rebuilt; I checked
  their timestamps.

## The suite

- **aecef72c** (the base, for the record): 2578 tests, 35 skipped, 13 failed assertions in 8 test
  cases:
  - the known 7;
  - plus `LatticeSDFProfileTests.testRaymarchCostOnMaintainerBracket`, a wall-clock ratio of 4.09
    against 4.0 while the machine was loaded (a review workflow and another session's suite were
    running). It passed alone afterwards.
- **044dd9ab** (both commits): **2596 tests, 36 skipped, 12 failed assertions in 7 test cases:
  exactly the known 7.**
  - `AppModelTests`, the three 3MF tests;
  - `LatticeCellGradingTests.testGradingChangesTheRenderedLattice`;
  - `LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds`;
  - `OrganicSampleCubeTests.testThickerIsLiveAndNeverRetraces`;
  - `OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology`.

  The raymarch timing test passed this time. 18 new tests take the count from 2578 to 2596; the
  one extra skip is the environment-gated stand probe.

