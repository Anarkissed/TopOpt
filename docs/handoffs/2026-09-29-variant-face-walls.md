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
- **(e)** Tapping a face on a variant says: "You can’t pick faces on an optimized result — the walls
  you marked on the part carry over." (House style since ruling 5; round 1 had "can't" and
  "optimised".)
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

**Round 2 (2026-09-30).** The nine open items below were ruled, plus a tenth. Seven commits and
the #358 sync followed; see "Round 2" at the end.

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

Open, and needing his ruling (**all nine ruled 2026-09-30; see "Round 2" at the end**):
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
   store in these runs, so it was not dumped. The other six were. **CORRECTED in round 2:** the
   cause is not a missing `results.plist`, which four listed projects also lack. Its `project.json`
   no longer decodes; see ruling 7.

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


## Round 2 (2026-09-30): the nine open items ruled, plus one

The maintainer ruled on the nine items above and added a tenth (project 102117B9). Each ruling is
its own commit, in his order, and the six stage projects were hashed after each:

| commit | ruling |
|---|---|
| **03f7aadc** | 1. outline order, fixed at the source |
| **5e4f9f8f** | 2. protection follows the slab |
| **3fdff70c** | 3. old retained runs: said before any tap, one tap to Optimize again |
| **42d935b6** | 4. one "has an include wall"; gates; the one tap; Auto's stale line |
| **6e4931ca** | 5. the tap refusal in the house style |
| **3c3dfa59** | 6. speed, measured in Release: no cache needed |
| — | 7. project 102117B9: found, reported, not fixed |
| **7793ee0f** | the #358 sync (90d9f874), one-way |
| **f201f7de** | after the sync: the parse-time frame canary; a core-source pin re-anchored |

### In plain words

- **The stage's job bytes no longer depend on the hash seed.** The same project now gives the
  same job every time, in every process. Core's output is byte-identical to before on the stand.
  Three projects' hashes moved once, by loop rotation only.
- **An expand on a protected, latticed face is no longer refused.** The protection now goes as
  deep as the slab the wall emits: depth + expand, and a negative expand shrinks both. Only jobs
  core used to refuse change.
- **An old result whose run froze a wall at a different depth is said before you tap anything**,
  in these words (the test's case): "This result was optimized with a 5 mm protected skin under
  Face 1, but the wall is 20 mm deep. Optimize again with this wall, or set the wall to 5 mm." "Optimize again" is
  one tap on the banner. It goes through the usual "Replace your results?" confirmation.
- **Nothing set to lattice is refused everywhere, in the same words, and one tap takes you to the
  walls.** That covers:
  - the stage's Lattice (for an exclude-only project too, which it used to let through);
  - Optimize, which used to lattice every variant whole;
  - a variant's two buttons and its forecast drawer;
  - Settings' Check-sizes lines.

  The tap takes you to the Lattice stage with Selections open. It never makes a wall for you.
- **Under Auto, a stale Check-sizes answer now says so**: "Sizes need re-checking — tap to check
  sizes." The line itself runs Check sizes.
- **The tap refusal on a variant**: "You can’t pick faces on an optimized result — the walls you
  marked on the part carry over."
- **Speed:** the two calls ruling 6 asked about take 1.84 ms in Release on his stand. That is under
  the 8 ms bar, so no cache was added.
- **Project 102117B9 is missing from the app's project list.** Its file no longer decodes: a
  wall-thickness entry saved before `startMM` existed. Found and proven, not fixed.

### Ruling 1: one order for one outline, at the source

**What.** `LatticeFaceOutline.loopsWithNeighbours` is the only production builder of outline
loops. It used to take its boundary edges, its adjacency lists and each loop's seed in hash order
(a `Dictionary`'s keys and `Set(border).first`). Now:
- the edges come in triangle-scan order;
- each loop is rotated to start at its smallest world vertex, and its neighbours are rotated with
  it;
- the loops are sorted by that rotated sequence;
- the walk's winding is kept.

Core's even-odd test reads directed pairs, and a rotation keeps every pair. The variant-only
re-sort (`RelatticeJobBuilder.canonicalOutline`) is gone: there is one definition.

**Proof of done: without `SWIFT_DETERMINISTIC_HASHING`.**
- At fba04bd0, two no-env dump processes DIFFERED on 68BF7B74, 92A8016E and 570B38E2.
- After the fix, two no-env processes and a deterministic one agree on all six projects.
- Five in-process repeats (`TOPOPT_JOB_REPEAT=5`) are identical.

**Core's output is byte-identical** (topopt-cli at aecef72c; old-order document vs new-order
document):

| case | forecast | full run: STL (before / after / after again) | receipt regions | positive control: one vertex moved 5 mm |
|---|---|---|---|---|
| stand, as saved | identical (cc40b78c…, 9700 voxels / 3132 latticed) | not run | — | — |
| stand, organic | identical (b98e7e83…, 9700 / 9700) | 4bc797b0… = 4bc797b0… = 4bc797b0… | identical | forecast 9700 → 9643 voxels, STL f0c0e97c…: **moved** |
| 570B38E2, doubled | identical (2c32fa71…, 8002 / 288) | 80405dc6… = 80405dc6… = 80405dc6… | identical | forecast 8002 → 7924 moved; STL **did not move**: only 148 voxels are latticed, so the STL cannot see this change. The forecast is the sensitive check here |
| 92A8016E, octet | core refuses both, with the same message (grading + a design box on `lattice_variant`) | — | — | — |

**Meaning changes.**
- **One-time hash change**, loop rotation only; a python check shows everything else is
  byte-identical:
  - stand 297527188edbe40a → c4b03acf387d178f (5 loops rotated);
  - 92A8016E fc032b16b1bce281 → 225865c83c64cb23;
  - 570B38E2 7269596833201a0e → 43a0828a8bbb1e1d;
  - 3418E167, AA4C7953 and 887AC498 are unchanged.

  The stand's organic stage document moved 0dac7a1407e14232 → 81827b81b9ef7194, order only.
- **The variant document's loops now start where the stage's do.** The re-sort used to pick its own
  start.
- **Deleted test:** `testTheVariantDocumentIsStableAcrossCalls`. It is replaced by
  `testOneOutlineOrderForTheStageAndTheVariant` and by `LatticeFaceOutlineOrderTests` (4 tests):
  - the start does not depend on triangle order;
  - each neighbour stays on its edge;
  - the outer loop comes first;
  - a pinch vertex chains one way.
- **Honest limit.** The in-process repeat tests did NOT catch the fix when it was reverted: hash
  order within one process is often stable. The two-process no-env dumps are the control that
  carries the proof.

### Ruling 2: protection follows the slab

**What.**
- `faceProtectionSpecs(emission:)` reads the depth the wall's prism emits
  (`LatticeRegionEmission.Result.slabDepthMM(runFaceID:)`: depth + expand). That is one value, not
  a second calculation.
- `makeRunRequest` builds ONE emission and passes it to both the protections and the lattice spec.
- A protected face that is not latticed keeps its dragged depth.

**Before and after, through core's parser.** On a stand copy, face 15 was given a +1 mm expand:
- before: refused, "the protection is 12.000000 mm and the lattice region is 13.000000 mm";
- after: accepted, with the protection at 13 mm.

Only jobs core refused change; all six stage hashes are unchanged. The expand item is out of the
core brief: core's tie was right, and the app was sending two depths for one slab.

**Region 101: two depths for one slab, which core accepts (reported, not changed).** A face
REGION's protection is unchanged. On his stand, region 101 is protected by region id at 20 mm
and latticed as three face-23 facets at 24.15 mm (20 + its 4.15 mm expand). Core's tie
(job.cpp:2439-2467) compares only FACE-id protections with face-kind regions, so it does not see
this. The job is accepted, and the deepest 4.15 mm of that slab is not frozen: core's own comment
calls that "void the optimizer removed". Making region protections follow the slab would change
the stand's stage bytes (the R2b control moved its hash to 43a02161a5bab447), and ruling 2 allows
only refused jobs to change. **Needs his ruling:** should a region's protection follow its slab
too? Should core's tie also check region protections? That would be a core brief.

**Report only: is the in-plane part of an expand protected?** Partly. Core's protection
(`mask_step_face`, face_tag.cpp:162-205) freezes part-SOLID voxels whose centre lies within
(N − ½)·h of the face's OWN triangles, measured as 3D distance. N is the protection depth in
layers. The in-plane collar the expand adds beyond the face's edge is therefore protected only
inside a rounded profile:
- at the surface, out to about the full slab depth;
- at depth z, out to √(D² − z²), where D = (N − ½)·h;
- near the slab's floor, not at all.

A collar voxel at in-plane distance e beyond the edge is unprotected below z ≈ √(D² − e²). On the
stand (face 15: 13 mm slab, 1 mm collar) that leaves only the floor corner. Protection never frees
void; it pins existing part material only.

**RED:**
- the old depths back: 4 red;
- regions following the expand: 1 red, and the stand hash moves to 43a02161a5bab447;
- the bolt keeping its dragged depth undone: 1 red;
- the source pin: 1 red.

### Ruling 3: old retained runs

**Run, not read.** The stand's variant job was given an old run's protections: bare ids [15, 2] at
the global 5 mm. topopt-cli refused it with "face 15 is BOTH protected and a lattice region, at two
different depths: the protection is 5.000000 mm and the lattice region is 12.000000 mm". `face_id`
is kept and the tie is not dodged.

**Where it is said.** The app asks core's OWN parser (`TopOptKit.jobSchemaError`, the same core the
worker runs) on the one document `relatticeJobJSON` builds. It asks where the page already asks
about the variant's job: a worker and a retained design. The answer shows:
- on the page banner, before any tap, as "Can’t lattice this variant" with the sentence, and one
  tap, **Optimize again**. That is the Optimize path itself, "Replace your results?" included, and
  it is offered only while Optimize is open;
- on "Lattice this variant", disabled, with the sentence as its sub-line;
- in the forecast drawer;
- in Check sizes;
- in the run's toast.

A document core refuses is never sent as a forecast.

**The sentence.** "This result was optimized with a [X] mm protected skin under [wall], but the
wall is [Y] mm deep. Optimize again with this wall, or set the wall to [X] mm."
- The numbers are core's, read from its message (`LatticeVariantProtectionTie`); nothing is
  re-derived.
- The wall is named as its Selections row names it.
- **One change from the ruled text:** a wall with an in-plane expand is told to set its depth to
  X − expand, because its slab reaches depth + expand (ruling 2). With no expand this is X, as
  ruled. The test sets the wall to 3 mm with a 2 mm expand against a 5 mm skin, and core accepts.
- Any other core refusal is said in core's own words.

**RED:**
- a parser that misses core's message: 5 red;
- the remedy ignoring the expand: 1 red;
- the forecast sent despite a refusal: 1 red.

### Ruling 4: gates and the one tap

**One definition.** `LatticeJobIncludeGate.hasIncludeWall` is the only place the question "does
this region list lattice anything?" is asked. The following all call it:
- the stage, a variant, Optimize (the workspace's and the page's);
- the wizard;
- the preview's clip and body alpha;
- the job builder's Fit fallback.

A pin finds the predicate written exactly once.

**The stage (item 4).** "Lattice" used to ask only whether ANY region was emitted. An exclude-only
project therefore got an enabled button saying "nothing set to lattice". It now greys, with that
same reason.

**Optimize (item 5).** With lattice on and no include wall, `canOptimize` refuses before the run
starts, and its sub-line says "nothing set to lattice". The page's Optimize and "Optimize from
scratch" say the same, because every start path reads that gate. Lattice off is no refusal: the run
is topology only.

**Changed for one real project:** 3418E167 "M2 verticalStand THICK" has lattice on and no walls.
Its Optimize is now greyed; before, it would have latticed every variant whole. Turn lattice off
there, or mark a wall.

**One tap (item 6).**
- Wherever "nothing set to lattice" shows, the control stays greyed, with the same words and a
  chevron (›).
- Its tap goes to where walls are marked: the Lattice stage, with Selections open
  (`goToWallMarking`).
- It is navigation only: no wall, no role, no save (pinned).
- From a variant's page, the page closes as its own Close does.
- Every other refusal carries no tap.

The surfaces are:
- the stage's Lattice and Optimize;
- "Lattice this variant" and "Optimize from scratch";
- the forecast drawer;
- the wizard's three Check-sizes lines (the re-check line, the check-refused note and the
  none-checked line).

**Auto (item 8).** Under Auto, the preview's window and the organic floor are read only from a
CURRENT answer, so a stale one stopped steering without a word. The wizard now shows "Sizes need
re-checking — tap to check sizes." under Auto, and the line is the tap:
- it runs the one Check-sizes submission, now shared with the button (`runCheckSizes`);
- while running, it says "Checking…";
- where Check sizes cannot act, it says why, and a missing wall is again one tap from the walls.

**The look.** DS tokens only. The bottom bar's two capsules are now one view
(`StageActionCapsuleLabel`), and the wizard's notes are `note`/`tapNote`, so the screenshots render
the app's own views: `evidence/2026-09-30-ruling4-gates/`, from `LatticeIncludeGateEvidenceGen`
with `TOPOPT_INCLUDE_GATE_EVIDENCE=1`.
- `bottom_bar_before_after.png`: before, after on Topology, after on the Lattice stage, and the
  include-wall control.
- `page_variant_nothing_set_to_lattice.png`: both buttons and the drawer.
- `page_variant_include_wall_control.png`: unchanged.
- `wizard_recheck_lines.png`: Manual (unchanged), Auto, running, the wall refusal, and another
  reason.

The live device frame is his.

**Decisions I made, for him to overrule:**
- **No dead tap.** On the Lattice stage with Selections already open he is already where walls are
  marked, so the line stays plain there.
- **The wizard leaves by its one exit**, Save & Exit, which saves. It has no other way out.
- **Toasts cannot carry a tap.** The run's toast "Can’t lattice this variant: nothing set to
  lattice." is only a backstop behind a greyed button.
- **Other words, same fact, left as they were:** the wizard's "Needs a lattice region" and the Fit
  pane's "Add at least one lattice region first — …". Should they become "nothing set to lattice"
  with the tap?
- **New words to approve:** "Sizes need re-checking — tap to check sizes." The Manual line beside
  the button still says "— tap Check sizes."

**RED:**
- the stage's old any-region gate: 3 red;
- Optimize ungated: 6 red;
- the tap never offered: 6 red;
- the Auto line removed: 1 red;
- a second definition of the predicate: 1 red.

### Ruling 5: the house style

"You can’t pick faces on an optimized result — the walls you marked on the part carry over." It
uses a curly ’ and "optimized". The test pins the sentence, no straight apostrophe, and no
"optimised". RED: the old sentence back turns 3 assertions red.

### Ruling 6: speed

`LatticePagePassTimingProbe`, Release, Mac14,12, his stand (stepped, 5 regions). 5 warm-ups, then
50 timed passes, run twice:

| call, per page pass | median (run 1 / run 2) |
|---|---|
| one emission | 0.92 / 0.93 ms |
| **the ruling's two calls** | **1.84 / 1.84 ms** (p90 1.96 / 1.95) |
| the variant pass now (one emission, gate, spec, document, core's parser) | 1.56 / 1.55 ms |
| canOptimize (include gate + `makeRunRequest`) | 1.96 / 1.91 ms |
| body alpha | 0.92 / 0.93 ms |
| the page rendered offscreen (every section, plus layout and raster; an upper bound) | 22.3 / 22.0 ms |
| the whole pass | 27.5 / 27.3 ms |
| negative control: the whole pass with lattice OFF | 17.4 / 16.6 ms |

- Positive control: Debug gives 17 ms per emission and 34 ms for the two.
- `_ = page.body` alone measured 0.01 ms, because its sections are built lazily. It timed nothing,
  which is why the page is rendered instead.
- **1.84 ms is under 8 ms, so no cache.** Whether the page visibly stutters is his call on the
  iPad, which is slower than this Mac.

### Ruling 7: project 102117B9 (M2 verticalStand)

**It is a real project, and the app does not list it.** Item 9 above said it "has no
`results.plist`". **That was wrong.** Four listed projects (3418E167, 887AC498, 92A8016E and
AA4C7953) have none either. The store lists a project only if its `project.json` decodes, and a
failed decode is dropped silently: `ProjectStore.snapshot(id:)` uses `try?`, and
`loadAllSnapshots` passes over the nil.

**Why it fails, run and not read.** The app's own decoder on a copy of his file:
- as saved: `keyNotFound 'startMM'` at `lattice.wallThickness.faces.f:820422E9-…:2`;
- the same copy with `"startMM": 0` added: decodes, as "M2 verticalStand".

**How it happened.**
- His file was saved at 2026-09-21 22:43:31 by a build from 604736ae. There,
  `LatticeFaceWallThickness` wrote only `{endMM, profile}`.
- bc3cf67f (22:56 the same night) made `startMM` a stored field. It kept synthesized decoding, and
  synthesized decoding does not use the `= 0` default. Every build since then fails on this file.
- Its sibling `LatticeWallCurvesPoint` has a hand-written decoder for exactly this case.
- The control: the stand (68BF7B74) is listed, and all three of its entries carry `startMM`.

**What the app shows.** The Home grid is `recentProjects`, seeded from `loadAllSnapshots`, so he
does not see it either. The folder is intact on disk; the simulator's `project.json` is
byte-identical to the snapshot. The project is authored work, not a stub:
- the stand's model;
- an anchor on face 18;
- a 10 lb load on four regions;
- include walls on faces 2 (12 mm) and 15 (11 mm);
- organic, Structural, simulation on;
- a drawn Manual grade on face 2.

**Not fixed, per the ruling.** Two changes for a ruling:
- a tolerant decoder for `startMM` (absent means 0), as `LatticeWallCurvesPoint` has;
- the store saying when a project fails to decode, instead of dropping it.

### The #358 sync (90d9f874)

**Merged one-way by SHA** as 7793ee0f. It brings six linear #358 commits, 8414af47 … 90d9f874:
core, core tests and one doc. There are no merges, no app files and nothing from Flexible; the
Flexible branch contains 90d9f874 only because it merged #358. Then `build_core.sh` ran, and the
app's `CoreFingerprint` is 7793ee0fab7f. The CLI was rebuilt with `--target topopt_cli`.

**Stop conditions: neither fired.**
- **Stage hashes: all six unchanged**, so no capability probe flipped. See the table below.
- **No size verdict moved.** The stand's c1 documents ran on the pre-sync CLI (aecef72c, kept as
  a copy) and the post-sync CLI (7793ee0f). Each Check sizes was stopped at
  `organic_probe.json`, as the app does:
  - variant probe and stage probe: 18 candidates each, with the same approvals, predicted
    verdicts, rooting and components;
  - recommendation: Fit 5.654 mm, Auto 3.576–6 mm, band 3.41–6 mm, and the printability,
    resolution, member and extent floors, all identical;
  - both forecasts: identical (9675 region voxels, with 1649 and 9675 latticed).

  Traced lengths moved on two candidates (for example 77,714 → 82,815 mm), which the ruling
  allows.
- **Limit:** his stand's probe runs on Aesthetic, so no strength check runs (0/18 checked, 0
  structurally approved) and rooting is 1.0 on every candidate. The comparison's teeth are the
  18 aesthetic approvals and the recommendation. A structural verdict was not exercised.

**The sync reaches the app (positive control).** 12ff5880 moved the in-plane frame check to
parse time:
- the stand's stage job with face 15's `frame_u` along the normal parsed clean on the pre-sync
  CLI, ran the load case, and failed only at run time with core's frame-mismatch error;
- on the post-sync CLI it is refused at parse time: "frame axes must lie IN the face plane
  (u . n = 1.000000 …)";
- the untilted control runs on both.

In process, `testTheLinkedCoreRefusesAnOutOfPlaneFrameAtParseTime` pins the same thing through
the app's own parser. The app's frames, built from the unit normal, pass.

**One app pin moved with core.**
`OrganicForecastTests.testGreenAndTheStructuralPickNeedACertificateThatRan` pins core's
certificate branch, and 154ce24f moved the skip into `organic_probe_certificate_skip`. The pin
now reads the helper and the new branch, with the same invariant:
- None only with a structural question, a network, and no more segments than the 600,000 cap;
- `cert_ok` is set once, from the certificate's margin, inside the branch that runs it.

Each form is red on the other core. Committed as **f201f7de**, with the canary.

**Tests after the sync.** Targeted (Check sizes, the forecast, every test that asks core's
parser, and the stepped-cell tests): 201 tests, 0 failures. The iOS build succeeded against the
new xcframework.

**#358's FYI, as it lands here.** Stepped and any-step plans resolve region ids by include
order now. A project whose region list has an exclude wall before an include wall will RUN such a
plan instead of being refused. None of the six stage projects has an exclude wall, so none of them
changes.

### Tests (round 2)

| test | what it pins | RED control |
|---|---|---|
| `LatticeFaceOutlineOrderTests` (4), `testOneOutlineOrderForTheStageAndTheVariant` | ruling 1 | R1a/R1b/R1d (the hash order back) |
| `LatticeProtectionFollowsSlabTests` (6), `testTheExpandDeepensTheProtectionWithTheSlab` | ruling 2 | R2a, R2b, R2c, R2e |
| `LatticeOldRetainedRunTests` (7) | ruling 3, through core's parser | R3a, R3c, R3d |
| `LatticeIncludeGateTests` (7) | ruling 4 | R4a–R4e |
| `testVariantAuthoringTurnsFaceTappingOffWithAReason` | ruling 5 | the old sentence |
| `LatticePagePassTimingProbe` | ruling 6 (env-gated) | Debug and lattice-off |

Pins updated in the same commits to the new code shapes, never loosened:
- ruling 1: `LatticeVariantTests` (`VariantFacePrismFixture.canonical` gives way to plain equality);
- ruling 2: `LatticeSlabExpandTests` (the expand now deepens the protection: [20] becomes [25]) and
  the `LatticeRunSpecSharedTests` call site;
- ruling 3: `LatticeVariantFaceWallsTests`, `LatticeVariantTests` and
  `OrganicSyntheticStressTests` (`relatticeJobJSON` takes the pass's emission);
- ruling 4: `LatticeVariantTests` (the stage's refusal), `OrganicForecastRouteTests` (the
  re-check line) and `LatticeOldRetainedRunTests` (the page call site gained `onMarkWalls`);
- the sync: `OrganicForecastTests` (core's certificate branch, re-anchored).

Every control was restored byte-identical from a snapshot. The ruling-4 commit was amended once, before any push,
to re-anchor the ruling-3 pin its call-site change broke. Its "159 tests, 0 failures" comes from
the rerun after that fix.

**Per commit:**
- targeted runs: ruling 1, 219 tests (1 skipped); ruling 2, 153; ruling 3, 104; ruling 4, 159;
  ruling 5, 21. 0 failures in each;
- iOS app build succeeded after each source commit, with the changed objects' timestamps checked;
- the stage hashes after every commit are below.

### Hashes: the stage job, round 2

No-env dumps, taken without `SWIFT_DETERMINISTIC_HASHING`, on a fresh copy of the Projects folder
each run:

| project | C1 (ruling 1) | C2 | C3 | C4 | C5 | C6 | sync |
|---|---|---|---|---|---|---|---|
| **M2 stand 68BF7B74** | c4b03acf387d178f | = | = | = | = | = | = |
| **octet 92A8016E** | 225865c83c64cb23 | = | = | = | = | = | = |
| 570B38E2 (doubled) | 43a0828a8bbb1e1d | = | = | = | = | = | = |
| 3418E167 | c264e572ab70049c | = | = | = | = | = | = |
| AA4C7953 | 3e6f162cb36212a9 | = | = | = | = | = | = |
| 887AC498 | b457718dfc23ab42 | = | = | = | = | = | = |

### The suite (round 2)

At **f201f7de**, after every ruling and the sync: **2625 tests, 40 skipped, 12 failed assertions
in 7 test cases, exactly the known 7:**
- `AppModelTests`, the three 3MF tests;
- `LatticeCellGradingTests.testGradingChangesTheRenderedLattice`;
- `LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds`;
- `OrganicSampleCubeTests.testThickerIsLiveAndNeverRetraces`;
- `OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology`.

**Against 044dd9ab** (2596 tests, 36 skipped), the difference is 29 tests, all new this round:
- `LatticeFaceOutlineOrderTests`, 4;
- `LatticeProtectionFollowsSlabTests`, 6;
- `LatticeOldRetainedRunTests`, 7;
- `LatticeIncludeGateTests`, 7;
- the sync canary, 1;
- `LatticeIncludeGateEvidenceGen`, 3, skipped without its env;
- `LatticePagePassTimingProbe`, 1, skipped without its env.

The 4 new skips are those env-gated ones.

The run took 3 h 17 min (11848 s), because two other sessions' builds and test runs held the load
average at 50–134 for most of it. The wall-clock test `LatticeSDFProfileTests.testRaymarchCostOnMaintainerBracket`
passed anyway.
