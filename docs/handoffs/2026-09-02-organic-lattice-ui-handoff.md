# Organic lattice in the Lattice Stage UI — handoff (in progress)

> ## ★ 2026-09-03 (late) — shape fit in the sample; "no outline, ONLY lattice"
>
> **Asked (maintainer):** the sample cube had no "Fit to shape", "otherwise they would
> look like a cube"; and "ensure that the shape to fit does not include an outline and
> is ONLY lattice".
>
> **Shape fit in the sample — a MIRROR, named as one.** Core applies organic shape fit
> inline in the CLI (`core/src/cli/run_job.cpp` ~4160–4290), not in a function the
> bridge can call, and this PR makes no core change. `OrganicShapeFit.swift` reproduces
> the rule on the preview's separation field: two-pass chamfer distance to the region
> boundary (grid faces count), then either the shape-fit-ONLY ramp
> `cell_min + (cell_max−cell_min)·dist/dmax` (stress map unread) or the cap
> `min(spacing, max(2·dist·voxel, cell_min))`. The member-width term of core's cap
> (`member_width / n★`) needs the run's per-voxel member width, which the preview does
> not have — only the boundary cap is applied, and the code says so. Pinned by
> `OrganicShapeFitTests` (4 tests, hand-computed on a 5³ block). ★ Honest end state: ONE
> core function shared by run_job and the bridge; until then any change to core's rule
> must be mirrored here or the sample lies. `LatticeOrganicInput` carries
> `shapeFit/shapeFitOnly`; the wizard already forces shape fit on under organic.
>
> **"No outline, only lattice" is THREE job keys, and the app wrote none of them.**
> (1) `lattice.outer_finish` — core's DEFAULT is `"shell"`, a solid shell = an outline
> (job.hpp:271); an organic job now writes `"skin"` (bare) unless the user picked
> Covered. (2) `lattice.skin: "diagrid"` — the only value that makes a non-shell
> outer_finish schema-legal (job.cpp ~1492); on the organic path core never hands the
> skin spec to the generator (`generate_organic_lattice(*organic, w, &boundary, …)`,
> run_job.cpp ~2111), so the key unlocks the bare surface and draws nothing.
> (3) `grading.organic_boundary_finish: "clean"` — core defaults to `"skin"`, a net over
> the bare surface (the printed PR 353 cube had it), and the sheet had no control for it.
> `LatticeWizardModel.selectOrganic()` now carries the organic rule (shape fit on, finish
> clean, inherited swept/fixed window → Auto) for the chip AND the on-appear repair of an
> older project; `LatticeSettings.jobOuterFinishResolved/jobSkinResolved` write (1)+(2)
> on both spec paths; non-organic jobs are byte-identical (pinned).
>
> **Fidelity trap found on the way — mirrored, measured small.** run_job sets
> `anchor_at_region_boundary = (outer_finish != "skin")`, and the dangling-end trim
> (organic_lattice.cpp ~1066) cuts an un-anchored end that left the region back to its
> last connector — a BARE run's faces are fuzzier than a preview that assumes anchors.
> The bridge now takes `anchor_at_boundary`; the sample passes `boundary == .covered`,
> the part preview the same. Measured on the 20 mm corner (Debug, Mac, six bakes,
> `evidence/2026-09-02-organic-on-device/sample_shape_fit_2026-09-03/README.md`):
> traced fit bare 211 mm³ vs fit covered 208 mm³ (≤1.5 %); grown fit bare 88 = fit
> covered 88 mm³ (no effect).
>
> **What the sample shows now (simulator, Debug dylib `883494cf71a9c504`, core
> `ca56654d2805`).** Traced: "162 curves, 811 connectors, 3.00–4.43 mm spacing ·
> shape-fit: 11039 voxels shrunk (min ratio 0.50, depth 16) · traced, shape-fit, bare
> (no outline; ends trimmed)" — reads as a cube, struts only, no shell/net
> (`traced_shape_fit_bare.png`). Grown: "2819 curves … grown, shape-fit, bare" — does
> NOT read as a cube: a sparse frame, plate-like ribbons near the top, a few long struts
> at the bottom (`grown_shape_fit_bare.png`). The probe says why: shape fit thins the
> GROWN sample by 34 % (134 → 88 mm³) and the grower is bottom-heavy either way
> (no-fit: 81 % of occupied voxels in the bottom third; fit: 50/40/10 %). Traced without
> fit was 225 mm³. That is core's grower on this field with these picks, rendered as-is;
> grown is the user's opt-in (Aug 5 ruling), not a fix — reported, not gated.
>
> **Core-side observations (report, not touched):** the grown branch's summary carries
> the TRACED connector count (811 on both paths — `lat.connectors.size()` after
> `grow_organic_lattice`), the known growth-receipt gap; shape fit is CLI-inline (above).
>
> **Tests:** targeted 49/0 (Debug SwiftPM: OrganicShapeFit, OrganicSampleCube incl. the
> covered/shape-fit picks, LatticeWizardOrganicChip incl. clean finish + bare surface +
> Covered + octet byte-identical + saved-project repair, OrganicRunReceipt, LatticePage).
> Full app suite (Debug, SwiftPM, `swift test`): 2302 tests, 30 skipped, 0 failures, 3655 s.

> ## ★ 2026-09-03 (evening) — the sample is LIVE: the PR 353 cube re-traced with the user's settings
>
> **What was wrong (maintainer):** the sample looked like ribbons, not beams — the bake
> voxel floor (0.35 mm) against r ≈ 0.26–0.39 mm struts; and it was a fixed artifact
> where it should be a base that follows every setting.
>
> **What it is now.** `OrganicSampleCube` solves the bundled `PR353_cube40.stl` with
> the app's OWN FEA (`TopOptKit.analyzeSolidLoadCase`, the printed job's load: anchor
> face 0, −200 N on face 1, PLA, 64³) once per launch, then re-traces a **20 mm corner**
> of that field through the preview bridge — which calls the production
> `trace_organic_lattice` / `grow_organic_lattice` (bridge.cpp) — every time an organic
> pick changes (`.task(id: Picks)`, off the main thread). Picks: Traced/Grown (+ layer
> height), the window = the printed job's 3–6 mm × spacing scale (Fit ⇒ one separation:
> the user's certified pick, else the middle), density band, Thicker's strut diameter,
> overhang (traced only). Bake voxel = r_min/2 (0.105 mm at the 0.42 bead) — the
> sample-only rule the maintainer confirmed; the part preview keeps its own rule (he
> wants that realistic by another route: analytic capsule march pre-run, the run's
> welded STL post-run — proposed, not built). The 20 mm cut keeps strut-to-spacing;
> the label says so. Bridge extension (app-side, `TopOptBridge`): `strut_diameter_mm`,
> `grow`, `layer_height_mm` now cross to `OrganicParams`; grown goes to
> `grow_organic_lattice`. `LatticeSDFScene` gained `organicBakeVoxelMM` (nil ⇒ old rule).
>
> **Measured on the simulator (Debug dylib `4f0c31195798cc73`, core `ca56654d2805`):**
> FEA + first trace 16 s wall (peak 100 % CPU, sheet live); traced: "148 curves, 694
> connectors, 3.00–6.00 mm spacing · voxel 0.10 mm" — individual beams with free tips,
> no ribbons (17:32 screenshot); tap Grown → re-trace 14 s → "2134 curves, 694
> connectors …" — the layer-ordered columnar look with free tips (17:34). The banner
> carries the census; "Sample" is the first tab under organic.
>
> **The certification pop-up (maintainer item 4).** When a run's receipt carries
> `fitting_separations_mm`, the workspace stores them on the project
> (`organicFittingSeparationsMM`) and, under a Structural stage, shows a confirmation
> dialog — "After running certification, only 2 mm, 3 mm, 5 mm are available for use.
> Please select which you'd prefer — you can always change this in the settings" —
> with a button per size; the pick lands in `organicPickedSeparationMM` (+ Fit). Settings
> shows the factored sizes as pills under Cell size with "Let core pick". The pick
> travels as `organic_separation_mm` only when core's schema accepts it (probe-gated
> like every organic key; today it does not, and the pane says so). Nothing fires until
> core writes the key — wired and unit-tested, not device-driven.
>
> **Closing suite (Debug, SwiftPM): 2296 tests, 30 skipped, 0 failures, 3602 s.**
>
> Tests: `OrganicSampleCubeTests` (picks mapping, grown needs a layer height and drops
> the overhang, bake voxel ≤ r_min/2 under the cap, hashable picks, the two fields'
> round trip and byte-identity, the gated emission). Render fixture unchanged
> (`testThePrintedCubeIsHitAtItsOwnRadius` still on the bundled printed spans).

> ## ★ 2026-09-03 (latest) — the sample IS the PR 353 cube; the thin-strut fixture measured
>
> **The sample.** The wizard's organic sample is now CUBE_FINAL — PR 353 round 4, the
> job the printed cube came from (`evidence/2026-08-21-organic-lattice/cube/final_organic.json`:
> TRACED, aesthetic, swept 3–6 mm, 40 mm, 64³, axial −200 N). Its spans were regenerated
> from that job with `emit_organic_spans` (Release core `ca56654d2805`, 76.7 s):
> `evidence/2026-08-21-organic-lattice/cube/final_organic_replay_2026-09-03/` — **12,434
> spans, 20,233.09 mm, ONE component, strut diameter 0.42 mm (file radii 0.263–0.391),
> 748 support legs, free tips kept**. Only the traced set exists (the printed one); no
> grown set was generated, so the Traced | Grown segment does not switch the sample.
> Bundled as `TopOptFlows/OrganicSample/` (SwiftPM resources; the folder must not be
> named `Resources` — a shallow iOS bundle with that top-level folder fails CodeSign,
> "bundle format unrecognized"). Rendered through the SAME path a run's spans take
> (`OrganicSpanIndex` bake + the march via `LatticeSDFScene`, `latticeLayer` on the
> wizard's `MetalMeshView`, box at body alpha 0), at the radius in the file, 40 mm, no
> rescale. Label: "The PR 353 test cube, as printed. Your part will differ." + the
> measurement; first tab "Sample" under organic. The bake (12,434 spans → 150³) runs
> off the main thread once per launch — synchronously it pinned the app at 100 % CPU
> with the sheet frozen mid-animation (measured, fixed).
>
> **On device (Debug dylib `b8094ef35d7bb700`, band 4 mm, 09:05):** the sheet opens on
> "Sample" with the banner "Baking the printed cube — 12,434 struts through the run's
> own preview path…" and stays live (the bake is off-thread); ~4 min later the cube
> renders through the march with the banner reading "The PR 353 test cube, as printed.
> Your part will differ. 12434 struts, 20233 mm indexed — matches the run's receipt."
> WHAT IT SHOWS: at the app's 0.35 mm voxel floor (`fs = max(0.35, longest/384)`) with
> file radii 0.26–0.39 mm, neighbouring struts merge into sheets where the print shows
> separate fine struts — the same bake-resolution question as the thin-strut rule (the
> 12 M cap alone would allow ~0.19 mm here). Reported, not changed. The 2 mm sample
> index (band 2 mm, ~8× fewer stamps) ships in dylib `8841c7597f87598e`: measured on the
> simulator (Debug) the bake ran **22 s** wall (app CPU >50 % then back to 0.1 %) from
> the Settings tap to the cube on screen, sheet live throughout; the banner then reads
> "12434 struts, 20233 mm indexed — matches the run's receipt." (09:08 screenshot). The
> merged-sheet look at the 0.35 mm voxel floor is unchanged by the band (it is the
> voxel, not the band).
>
> **Measured (f):** the bundled receipt says span_count 12434 / span_length_mm
> 20233.09307; the bake indexes 12434 spans / 20233.1 mm — `mismatch()` nil. Pinned by
> `testThePrintedCubeIsHitAtItsOwnRadius` (which also marches it: see below).
>
> **Overhang under Grown:** confirmed hidden — the row shows "Grown organic holds a
> fixed 30° overhang; the limit is not adjustable there" in place of the scrub
> (`LatticeSetupWizard.swift` ~734).
>
> **Closing suite for this round (Debug, SwiftPM): 2289 tests, 30 skipped, 0 failures,
> 3742 s.** The thin-strut app-bake case runs as a strict expected failure inside
> `OrganicRenderMarchTests` and prints its numbers; nothing else is red.
>
> **The thin-strut fixture (reviewer §2), 3000 rays each, exact shader replica:**
>
> | case | voxel | epsO | reached | hit | through | missed |
> |---|---|---|---|---|---|---|
> | run-2 spans, own radii (0.43–2.05) | 0.521 | 0.130 | 1605 | 1605 | 0 | 0 |
> | PR 353 cube, printed radius (0.26–0.39) | 0.350 | 0.088 | 2592 | 2592 | 0 | 0 |
> | run-2 re-baked at r = 0.225, APP BAKE | 0.521 | 0.130 | 1536 | 1422 | **9** | **105** |
> | candidate (a): voxel = r_min | 0.225 | 0.056 | 1525 | 1525 | 0 | 0 |
> | candidate (b): epsO = ½ diagonal | 0.521 | 0.451 | 1546 | 1546 | 0 | 0 |
>
> The reviewer's arithmetic is confirmed: at the schema floor on the M2's voxel, 7.4 %
> of rays that reach a capsule find no surface (114 of 1536). The printed cube at its
> own radius is whole. Both candidate BAKE rules close the holes: (a) costs
> 890×268×215 = 51 M voxels (the app caps at 12 M and would coarsen back); (b) costs
> surfaces read up to 0.45 mm fat. Not chosen — the maintainer's call. The app-bake
> thin case is a STRICT `XCTExpectFailure` in `OrganicRenderMarchTests` (prints its
> numbers; flips to a failure the day a rule lands without updating it); the two
> candidates print theirs. The pass-through criterion now counts a real crossing only
> (chord > 2·epsO, hit > epsO past the exit); tangent grazes (chord ≈ 0, hit within
> epsO of the touch) are tallied separately — the closing suite of the previous round
> had caught two such grazes as "holes" with "largest chord skipped 0.0 mm".

> ## ★ 2026-09-03 (later) — names confirmed, substitution closed, SHA answered
>
> **The core SHA.** `ca56654d2805` is a COMMIT on this branch
> (`claude/topopt-lattice-preview-holes-5ab466`): `ca56654d2805e8d8…`, 2026-09-02
> 19:59:24 −0400, "Handoff: organic lattice UI — what landed". It is not on origin
> because the branch has never been pushed; it is not a content hash. `b27e5af`
> (2026-09-02 07:08, "Contiguity follow-up: the verdict, the resi…") **is an
> ancestor** of it (`git merge-base --is-ancestor` → yes), so the vendored core
> includes b27e5af. `build_core.sh` stamps `git -C core rev-parse --short=12 HEAD`,
> i.e. the worktree HEAD at re-vendor time — the core/ tree of that commit.
>
> **D1 capability, as named:** `organicStructuralCertificationWired` is now the
> schema probe for grading key `organic_structural_certification` with value
> `"beam_network"` — a whole-job `jobSchemaError` probe (the bridge's key probe only
> sends `true`), the same route `latticeSchemaAccepts` already uses. No new
> mechanism. False on core `ca56654d2805`; flips the day core accepts the key.
>
> **D2 receipt keys, as named** (all `grading.organic.*`): `fitting_separations_mm`,
> `fit_survival_bar`, `selected_window_mm` (auto), `selected_separation_mm` (fit),
> `structural_verdict` ("certified" | "refused" | "not_run"), `structural_margin`,
> `structural_stress_{p50,p95,p99,max}_mpa`, `structural_worst_strut`,
> `structural_governing_load_case`, `structural_knockdown_used`. The proposed
> `structural_certified` bool is dropped; the confirmation is
> `structural_verdict == "certified"`. Read verbatim into `OrganicRunReceipt`;
> `spacingLine` shows "core chose window/separation … · from … that fit · achieved …
> · structural: verdict (margin)". Pinned by `testTheConfirmedD2KeysAreReadVerbatim`.
>
> **The substitution is closed.** "Fit → auto when no region" is gone from both
> `runSpec` paths: a chosen Fit travels as core's `fit`, always. Where no region is
> declared the wizard's Fit pill is DISABLED with its reason, and the lattice-stage
> run button refuses in words ("organic Fit needs a declared lattice region — pick
> Auto or declare one"). Offer, never substitute. Pinned:
> `testOrganicCellModesAreAutoAndFitOnlyOnBothPaths` (Fit stays Fit with and without
> a region).
>
> **D2 is ahead of core — said in the pane:** "core's organic Auto/Fit is still being
> wired. Today an organic Fit runs core's existing fit path (one cell per region,
> job.cpp), and the receipt does not yet report the fitting set." Core's organic
> auto/fit semantics are a pending core item (`job.cpp:1937` runs the octet fit path
> for `cell_mode: fit` on an organic job today).
>
> **On-device (Debug dylib `1c5c0e3e442be106`, 06:17, core `ca56654d2805`), project set
> organic + Fit by file, regions declared:** the run button stays live ("2 regions ·
> no optimization" — Fit with a region is not refused); the pane shows the Fit pill
> lit, its caption, and the "core's organic Auto/Fit is still being wired" note; no
> sizes anywhere (06:18 screenshots). The Fit-without-region refusal is a computed
> property (`organicFitWithoutRegion`) exercised by construction; not driven on device
> because the M2 always declares its two regions.
>
> **Full app suite for this round (Debug, SwiftPM): 2286 tests, 30 skipped, 2 failures,
> both named — two assertions of ONE test, `OrganicSpanIndexTests.
> testTheIndexFindsEveryCapsuleAQueryTouches` (index 2.98 vs brute 2.05; 2.69 vs 2.54
> on random points). Diagnosis: a segment is stamped into the cells its CAPSULE
> (endpoints ± r) covers and a query reads one cell, so `distance` is EXACT inside
> any capsule and an UPPER BOUND outside; the test claimed exactness "everywhere
> the index has cells" and passed three full runs only by the luck of 500 random
> points (this is also the shape of the first run's two unnamed failures).
> Re-pinned to the true contract, stricter where it matters: never nearer than
> brute force; exact inside a capsule; and whenever looser, the nearest segment's
> stamped cell range must exclude the query cell (a real stamping bug still
> fails). 5 consecutive runs green. The preview bake does not depend on the
> outside case (`bakeField` stamps its own `r + bandMM` reach).
>
> **The index re-pin's condition (reviewer): the render cannot have holes — proved at
> the march.** (1) The step IS clamped to the bake's band: the march steps
> `clamp(F2 * stepScale, 0.05 * voxel, 0.7 * cellHere)` (`UnifiedShading.swift:707`)
> with `F2 = max(dOrg, dClip)`; `dOrg` is the baked field, whose empty voxels are
> filled with `bandMM` and whose stamped voxels are mins (`OrganicSpanIndex.bakeField`,
> reach `r + band`), so `dOrg ≤ band` everywhere and the step ≤ 0.95 × band
> (`stepScale = 0.95`, `LatticeSDFMetal.swift:2262`). What the GPU marches is that
> baked field, a LOWER bound at voxel centres — not the index's `distance`. The only
> over-estimate is the linear sampler between centres (`LatticeSDFMetal.swift:1169`),
> ≤ ½ voxel diagonal. (2) RENDER-LEVEL TEST `OrganicRenderMarchTests`: an exact CPU
> replica of the shader's sampling, epsilon and step, marched through the run-2
> spans baked with the app's own parameters (386×117×94, voxel 0.521 mm, band 4.0 mm)
> against analytic ray–capsule intersections, 3000 rays (1500 random + 1500 grazing).
> Measured: rays reaching a capsule 1621 — hit before leaving it 1621, passed through
> 0, missed 0, smallest chord hit 0.066 mm; first capsules OUTSIDE the span index's
> stamp at the sampled cell: 1370, all hit; hits claiming a surface where none is
> (true distance > eps + ½ diagonal): 0. Fixture: `evidence/…/run2_replay_gate_off_SPANS.txt`.
>
> **The graded:false gap, generalised:**
> `testEveryPathThatYieldsAnOrganicSpecWritesTheAlgorithm` sweeps both `runSpec`
> overloads × {sim, uniform} × {auto, fit, fixed, swept} × generatable on/off × with/
> without a declared region, and FAILS if any organic spec's job lacks
> `algorithm: organic`, carries a size, or has a cell mode other than auto/fit — and
> if any organic path returns nil where the same octet settings build a spec.

> ## ★ 2026-09-03 — maintainer decisions D1/D2 applied (app only; `git status core/` clean)
>
> **Core SHA the device builds linked:** `ca56654d2805` (12-char, from
> `CoreFingerprint.generated.swift`, written by `build_core.sh` at the 2026-09-02
> 20:40 re-vendor; the xcframework's mtime is 20:40:19). Device dylibs of this
> session: `f49df957ac923314`, `982516d3e5017957`, `a1a498bc36f5cb39`,
> `f84512590c1a71e5`, `564db78a1220c5b7` — all Debug, all against that core. The
> Mac replays used the Release CLI in `build/` from the same worktree; whether
> `growth_ran=false` and the missing `census_components[]` are skew or defects is
> for core to say with that SHA in hand.
>
> **§1 evidence committed:** `evidence/2026-09-02-organic-on-device/` — run-2 and
> run-3 job bytes, the gate-off replay job, both receipts, and the exact
> `topopt-cli lattice-variant` command (README). The shell guard did NOT fire on
> run-2 bytes without shape fit (neither on device nor on the gate-off replay,
> which exported 1240 spans clean); it fired only on run 3 with
> `organic_shape_fit: true`.
>
> **D1 — Organic under Structural (UI enablement, emission gated).** The chip is
> selectable under Structural with the same controls as Aesthetic. Core still
> refuses the job at runtime (`refuse_organic_structural`), and that is not a
> schema key, so `gradingSchemaAccepts` cannot see it: the app carries its own
> statement `TopOptKit.organicStructuralCertificationWired` (FALSE today; to be
> bound to core's capability signal — coordination with the core agent pending)
> and the gate's words `organicStructuralGateMessage`. While false: the organic
> pane shows the message under Structural, and the lattice-stage run button is
> DISABLED with the same message (`canLatticeThis` / `latticeThisSummary`), so the
> UI never writes a job core refuses. No core edit.
>
> **D2 — organic cell modes are AUTO and FIT.** The organic "Cell size" segment is
> `["Auto", "Fit"]`; the candidate list, the size pills and the scrub are gone (no
> "fits" computed in the app). AUTO → core's `cell_mode: auto`, no window; FIT →
> core's `cell_mode: fit` where a region is declared (core refuses `fit` with
> none) and Auto otherwise — never a fixed cell. Enforced on BOTH builder paths in
> `runSpec` (graded/sim and uniform) and in `LatticeAutoPosture` (F2), so no octet
> window or size reaches an organic job by any path; pinned by
> `testOrganicCellModesAreAutoAndFitOnlyOnBothPaths` and the posture test. The
> receipt now carries the window/separation core chose
> (`requested_spacing_*`, `achieved_spacing_*` → `spacingLine`) and reads
> `structural_certified` when core writes it (key name to coordinate) — displayed
> on the preview label, never inferred. What "the fitting set" looks like in the
> receipt is core's addition; the reader will show it when the key exists.
>
> **On-device proof (Debug dylib `77a13857ba095c55`, 04:08, core `ca56654d2805`),
> project set to `stageMode: structural` + `algorithm: organic` by file:**
> - the lattice stage stays live under Structural; the run button is DISABLED and
>   reads core's words: "organic structural certification is not yet wired — core
>   refuses an organic lattice under a Structural intent today. Run it under
>   Aesthetic, or wait for the core task." (04:12 screenshot);
> - the organic pane shows the same caption above "Cell size", with every control
>   enabled; the segment is `Auto | Fit`, no sizes, no pills (04:10 and 04:12);
> - the mode sheet's "Traced (organic) lattices need this mode" row is rewritten to
>   D1's wording (post-dates the on-device build; compiled by the next build).
>
> **A gap D2's test caught, fixed:** on the UNIFORM-density path (`Density: Auto /
> Thicker` set `.uniform`) `runSpec` built `graded: false`, and `gradingDictionary()`
> returns nil for a non-graded spec — an organic job on that path carried NO grading
> block, hence no `algorithm`, and core would have run the default lattice in
> silence. An organic job now always builds `graded: true`. And the sim path's fit
> fallback (fit → FIXED for the octet) ran after the first organic rule, letting
> `cell_mm: 6.0` through; the organic rule is applied again after it. Pinned by
> `testOrganicCellModesAreAutoAndFitOnlyOnBothPaths` (fixed → auto, swept → auto,
> fit-without-region → auto, no size, both paths).
>
> **Full app suite for this round (Debug, SwiftPM): 2284 tests, 30 skipped, 1 failure,
> named — `StrutLineWidthTests.testNoLatticeLineWidthSiteReadsAWallBead`, the audit of
> `strutLineWidthMM` call sites (14 → 13: the organic candidate-size site is gone by
> D2). Re-pinned per the test's own instruction; 12/12 after. The two earlier-round
> failures did not reproduce in any of the three full runs since.
>
> ### §3 — census beside its counters (null is NOT "did not run")
> From the two replay receipts (same job bytes; Release CLI, core `ca56654d2805`):
>
> | stage | census TRACED | counters TRACED | census GROWN | counters GROWN |
> |---|---|---|---|---|
> | base_cut | null | base_trim_found false, cut 0, clipped 0 | null | same |
> | support_prune | 783.28 | legs 7343, cuts 607, cleanup_pruned 8492 | 85.71 | legs 1834, cuts 462, cleanup 2311 |
> | stranded_drop | 783.28 | comps 8, spans 356 | 85.71 | comps 17, spans 377 |
> | ground_tie | **null** | legs 8, rounds 5, ties 314 **← disagree** | **null** | legs 22, rounds 4, ties 2044 **← disagree** |
> | branch_support | **null** | seeds 537, trunks 231, merges 35 **← disagree** | **null** | seeds 286, trunks 136, merges 54 **← disagree** |
> | dangling | 783.28 | trimmed 17, rounds 1 | 85.71 | trimmed 17, rounds 1 |
> | fill_mat | **null** | struts 415, cells 1485 **← disagree** | **null** | struts 24, cells 1121 **← disagree** |
> | finish | **null** | filleted 72, net_skin 0 **← disagree** | **null** | filleted 2 **← disagree** |
>
> Four stages carry `null` beside nonzero counters in both receipts, so the
> census `null` cannot be read as "stage did not run" until core confirms the
> sentinel. `census_components[]` is absent altogether.

> ## ★ STATE AT 2026-09-03 — REVERTED: no core change in this PR
> On 2026-09-02 the maintainer said organic should be available under Structural;
> the agent read that as a core instruction and retired two core gates on disk
> (`run_job.cpp refuse_organic_structural`, `job.cpp` shape-fit intent check). The
> reviewer ruled that a deleted assertion is forbidden regardless of who asked:
> core has NO INSTRUMENT to certify organic geometry under a structural intent (the
> certificate reads density against the OCTET tensor; nothing has measured a tensor
> for traced geometry). **Reverted** — `git status core/` is clean at commit
> `94313e30`. The UI keeps the committed behaviour: the Organic chip is offered in
> both intents, DISABLED under Structural with the reason shown, never hidden,
> never silently switched; it never writes a job core refuses. Making organic
> certifiable under Structural is a CORE task (resolved beam-network certification
> over the GRID/SKIN/SEG span export) — out of scope here.
>
> Also per the reviewer: the traced path's refusals are the traced path behaving as
> known (trace-then-repair cannot be made clean by adding passes —
> `organic_lattice.cpp:2477-2479`; traced 40 mm cube 8,793 legs vs GROWN 0). Fix (a)
> "re-run support after cleanup" is DECLINED. `support_converged = true` in the
> receipt describes the state BEFORE cleanup changed it and is not a printability
> claim. The next measurements are the GROWN path on the same job bytes and the
> M2's own separation cliff (§14 below when written).
>
> UI fixes on disk (uncommitted until the suite names its failures):
> - **The octet window no longer rides into organic — at its real source, measured
>   twice.** The on-disk project said `cellSizeMode: auto` (window 4–8); the job
>   carried `swept 5.5–6`. First fix (a guard in `runSpec`, commit e7e8fc45) passed
>   its unit test and STILL shipped the window on device (Debug dylib
>   `f84512590c1a71e5`, 01:17: job `cell_mode: swept, 5.5–6`) — because the on-device
>   request runs `LatticeAutoPosture.applied` BEFORE `runSpec`, and that posture had
>   already rewritten Auto into the octet's per-member swept window. The posture now
>   leaves an organic Auto alone (`LatticeAutoPosture.swift`, one line). Proof on
>   device (Debug dylib `564db78a1220c5b7`, 01:29, container `DC305934…`, new write):
>   `grading = {intent aesthetic, algorithm organic, organic_shape_fit true, topology
>   octet, cell_mode auto}` — no window. Tests:
>   `testTheAutoPostureLeavesAnOrganicAutoAlone` (octet control still derives) and
>   `testOrganicAutoDoesNotInheritTheOctetsDerivedWindow`. The wizard row additionally
>   resets an inherited swept/fit mode to Auto out loud and lights nothing for one.
>   Note the value judgement is NOT made: core's `auto` is "a single uniform cell"
>   per the plan's own comment; what organic should do with Auto is the maintainer's
>   default to pick — the UI only stopped sending a window nobody chose.
> - **Section 6(i) struck from the UI** (addendum A): the "up to 4 mm stayed one
>   lattice / 5 mm left 40 % dust / 6 mm 85 %" captions were gc2's inline tracer, not
>   `trace_organic_lattice`; both captions are now neutral. No cell-size verdicts or
>   thresholds remain in the organic pane.
> - **The receipt's four fields are carried, not judged:** `OrganicRunReceipt`
>   gains `growthJoinRefusedSpan` and a one-line `contiguityLine` (survival · pieces
>   (largest %) · joins refused); the scene exposes it as `organicReceiptSummary` and
>   the preview label appends it. Pinned in `OrganicRunReceiptTests`.
>
> ### E. The census — every organic run in this handoff (Release core `build/topopt-cli`, 2026-09-02/03)
> `length_census_mm` per stage (mm). **`census_components[]` is NOT in the receipt
> this core build writes** — every stage's component count is absent, not null;
> the length census is what exists. `null` = stage did not run.
>
> | stage | TRACED, run-2 bytes, gate off | GROWN, run-2 bytes + `organic_growth` |
> |---|---|---|
> | grown (initial curves) | 6016.08 | 15646.75 |
> | emitted | 7683.25 | 16073.25 |
> | node_merge | 7211.25 | 13533.31 |
> | base_cut | null | null |
> | support_prune | 783.28 | 85.71 |
> | stranded_drop | 783.28 | 85.71 |
> | ground_tie | null (yet `ground_tie_legs_added` = 8) | null |
> | branch_support | null | null |
> | dangling | 783.28 | 85.71 |
> | stranded_drop_2 | 783.28 | 85.71 |
> | fill_mat | null | null |
> | finish | null | null |
> | written | 783.28 | 85.71 |
>
> Traced receipt: survival 0.130, 1240 spans, 5 pieces, largest 45.2 %, stranded
> 429.3 mm, legs 7343, cuts 607, `unsupported_cells_remaining` 17 (the run-2
> refusal). Grown receipt (report only — addendum B withdraws "switch to grown";
> traced ships): survival 0.0055, 103 spans, 6 pieces, largest 37.7 %, stranded
> 53.4 mm, legs 1834, cuts 462, `unsupported_cells_remaining` 0; the support prune
> took 13,533 → 85.7 mm. **Receipt defect to report:** `growth_ran` reads `false`
> although the grown branch ran (the "grown" census row is 2.6× the traced one and
> `oo.lat = jg.organic_growth ? grow… : trace…` is unambiguous) — on the
> lattice-variant path `R.oc.growth_ran` reaches the receipt unset. The separation
> sweep (3.0–6.0) was started under the earlier instruction and STOPPED at its first
> point when the addendum withdrew it; no sweep numbers exist.
>
> **The organic SAMPLE preview is NOT built.** The wizard's sample is still
> `LatticeSamplePatch` (an octet patch); it has no organic branch, so what he saw
> is not an organic lattice. Plan: generate the 40 mm cube's spans with the recipe's
> bending load (`scratchpad/cube/job.json` is written: `cube40.stl`, force
> `[200, 0, −100]`, `emit_organic_spans`, res 64), bundle the `_SPANS.txt` as a
> `TopOptFlows` resource (Package.swift has no `resources:` yet), and add an
> organic branch to `stageMesh` that draws capsules from `OrganicSpanIndex` — no
> tube/capsule mesh helper exists in the app yet. The run itself was blocked:
> `cd <scratchpad>/cube && ../../build/topopt-cli lattice-variant job.json --out out`.
>
> **The real-part preview from a run's spans IS wired** (`organicSpans` →
> `bakeField` → capsule-min field; label names the span count) but has never been
> exercised on device because no on-device organic run has yet completed (three
> endings, §9). The Mac replay proves core's side (§10).

**Branch:** `claude/topopt-lattice-preview-holes-5ab466` (merged `origin/main` @ PR 353 at `de96877d`)
**Last green commit:** `dbcb356e` (settings, keys, gates, wizard row — 7/7 tests)
**§2 now compiles and its 15 tests are green** (OrganicSpanIndex ×4, OrganicRunReceipt ×2,
LatticeSchemaProbe ×1, LatticeOrganicSettings ×7 + the settings tests). Read §4 for what is
still unverified.

## 1. Landed and tested (dbcb356e)
- `LatticeSettings` + `LatticeSpec`: the seven `organic_*` keys, core's defaults, CodingKeys,
  decode AND encode (unconditional). `gradingDictionary()` writes a key only if (1) algorithm is
  organic, (2) `gradingSchemaAccepts` (this core: all seven true), (3) moved off core's default.
  `organic_growth` never without `layerHeightMM > 0` (§2A); overhang never under growth (§2C).
- `runSpec(layerHeightMM:)` threaded from `project.printParams` at all three callers.
- Wizard model mirrors the seven in/out. `LatticeOrganicSettingsTests` ×7.

## 2. Landed, NOT yet compiled (after dbcb356e)
- **Core**: `lattice.emit_organic_spans` (job.hpp/job.cpp), span ledger collected for weld OR
  spans (§2B), `_SPANS.txt` written post-emission (`GRID` + `SEG`, no `SKIN` — nothing in scope
  states a designed rim), **refuse-on-empty via `JobError`**, receipt `span_count / span_length_mm
  / span_path` under `grading`. `test_job.cpp`: S1 schema test.
- **App**: `OrganicSpanIndex` (parse, uniform 4 mm index, `distance`, `bakeField`) + tests;
  `OrganicRunReceipt` (§5 fields, null-tolerant census, `mismatch(...)`, `contiguityReport`) +
  tests; `TopOptKit.latticeSchemaAccepts(key:)` + controls test; `LatticeVariantAlternative.spanText`
  and `RelatticeResult.spanText` fetched beside the mesh; both job builders set
  `emit_organic_spans` when organic; `LatticeSDFScene(organicSpans:organicReceipt:)` bakes the
  organic field from spans FIRST (trace only when none) and exposes `organicSpanSource` +
  `organicReceiptMismatch`; preview label appends the source and SHOUTS a mismatch; workspace
  stashes spans+receipt from on-device (`RelatticeRun`) and remote (`openLatticePage`) runs, folds
  them into the bake key, and rebakes on run change.
- **Wizard UI (his 2026-09-02 spec)**: "Organic" chip at the TYPE level (sets
  `cellTransition = .organicGrade`; tapping a lattice type leaves organic); a separate organic
  "In the part" pane: Traced/Grown (Grown disabled WITH reason), Cell size Auto·grade / Fit·one
  size / Pick a size (list from `regionMemberMM` ÷ k, printability-filtered), Density
  Auto / Sim / Thicker (+ strut width), FIXED finish "grade to fit the outline"
  (`organic_shape_fit` forced on select and on load), overhang (hidden under growth), spacing
  scale with the §6 note as ADVISORY.

## 3. Open questions put to the maintainer (unanswered)
1. Structural-mode cell list: hard filter to the measured-lattice band, or advisory (§6/§8)?
   Grown list its own set?
2. "No finish on the faces": `organic_boundary_finish = "clean"` (drops the net-skin, clipped
   ends become cantilevers) or keep core's `skin`? Currently: NOT written (core default).
3. Remove the "Organic Grade" pill from Grade style now that Organic is a Type-level chip?
   Currently: still there.

## 4. Not done / caveats
- **The lattice-key probe reads the VENDORED xcframework.** `latticeSchemaAccepts("emit_organic_spans")`
  printed `false` in the test run because `app/TopOptKit/vendor` was built before the core change;
  `build_core.sh` was re-run afterwards. Until the app is rebuilt against it the job builders will
  NOT ask for the span file — by design, that is the probe doing its job. Re-run
  `LatticeSchemaProbeTests` after `build_core.sh` and expect `true`.
- ctest (Release) #1: every test passed except `cli_demo` (= `test_cli`, a validation binary that
  shells out per case), which sat at 0% CPU for 30 min after 36 CPU-min and was killed. Its solo
  rerun is in flight; its source does not reference lattice/welded/organic (see grep in the
  session), so the span export is not in its path. `job_schema` (with S1) passes.
- Compile + tests of §2; ctest Release #2 (with S1); `build_core.sh` re-run (chained);
  device verification (an organic on-device run → label shows "N struts from the run's
  emitted spans", no MISMATCH).
- **Persistence gap**: `spanText` is NOT in `LatticeAlternativeDTO` (OutcomeStore) — a reopened
  project loses the run's spans and the preview falls back to the trace (and says so). Persist
  the file to the sidecar dir and store a path rather than the text.
- Step 3 (in-shader capsule-min over the index) — deferred; the baked field is the enabler,
  the shader path is the fidelity upgrade. Blocker 1 in the task doc is stale on this tree.
- §7: multi-component grown is REPORTED (`contiguityReport`), never judged.
- Organic Grade pill + `LatticePage.algorithmCard` (dead) untouched pending Q3.

## On-device, 2026-09-02 evening — what the simulator actually showed

Measured on `A030C20C…` (iPad Pro 13", 1032×1376 pt), build hash `60f9dc2dbd24fb7c`,
project `102117B9` ("M2 verticalStand", Ready) with `lattice.algorithm` set to
`"organic"` by hand (backup: scratchpad `project.json.BACKUP2`, sha `d6d1d335…`).

1. **The Organic chip is real and the state round-trips.** With the project saying
   organic, the wizard opens with Organic selected (filled chip, its "on" caption).
   The "chip won't select" lead from earlier tonight was a HARNESS SCALE error:
   the screenshot is ~1500 px wide for 1032 pt, so pt = px × 0.688, not ÷2 — every
   tap landed at 73 % of its target (a control chip missed the same way). Fixed in
   memory; no code was wrong.
2. **The organic run died at core's validation** (screenshot 21:07): `organic
   requires "intent": "aesthetic", stated explicitly (this job says nothing)`. The
   app never wrote `grading.intent`. Fixed: `LatticeSpec.stageMode` mirrors the
   stage's Structural/Aesthetic choice and the organic block emits `intent` from
   it (`"aesthetic"` runs; `"structural"` travels as the stage's own word so core's
   refusal stays faithful; a non-organic job still emits no `intent` — bar U1).
   Test: `LatticeWizardOrganicChipTests` (positive, structural, and no-key controls).
3. **Core makes organic AESTHETIC-ONLY** (`run_job.cpp refuse_organic_structural`:
   one cubic tensor per topology, none measured for traced struts). So Q1 is not
   an app choice: under a Structural stage the Organic chip is now DISABLED with
   that reason as its caption. His item (1) "Structural shows only true lattices"
   cannot arise inside Organic — it must be his call whether Structural+Organic
   should instead flip the stage to Aesthetic.
4. **"In the part" was showing BOTH sections** (screenshot 21:12): the octet Cell
   size / Density / Finish rows above the organic block. Fixed: under Organic the
   stage's three rows are dropped and `organicRow` carries them.
5. The results screen's Lattice entry is BLOCKED for on-device runs (same "re-run
   on a Mac worker" refusal as Smooth) and the blocked Smooth caption pushes the
   Lattice chip OFF-SCREEN to the right on portrait 13" (Smooth's VStack is up to
   260 pt wide). Not touched tonight — the lattice stage is reached from the
   workspace's top-right "Lattice" chip → "Settings"; noted for QA.
6. Two iPads were booted; `screenshot`/`tap` without `udid` go to the OTHER one.
   Always pass `udid`.

7. **After the rebuild (dylib `f49df957ac923314`, 21:30) the captured job document**
   (`lattice_job.json`, copied while it existed) carries
   `grading: {algorithm: organic, intent: aesthetic, topology: octet, cell_mode: swept,
   cell_min 5.5 / cell_max 6, min_extrudable_width_mm 0.45}` and
   `lattice.emit_organic_spans: true`, `loads.layer_height_mm: 0.2`. The run passed
   core's validation (it died there at 21:07; at 21:34 it was 2:26 into the solve).
   NOT in the job: `organic_shape_fit` — the wizard forces it in the model, but
   `project.json` still has the 20:56 mtime after Save & Exit, so persistence of the
   forced pick is an OPEN question (check the project store's write path).
8. `LatticeWizardOrganicChipTests` first SKIPPED silently: the guard used
   `latticeSchemaAccepts` (the lattice-block probe) on a GRADING key. A skip reads
   as green in a filtered run — read the "skipped" count, not the exit code.
9. **Three on-device organic runs, three different endings — all core's own words:**
   - run #1 (21:07, no `intent`): refused at validation — fixed in the app.
   - run #2 (21:37, `intent` present, no shape-fit because Save & Exit had not
     persisted): passed validation, solved, refused at the PRINTABILITY gate —
     "17 raster cells (0.627 mm³, 2 regions) would be extruded into open air at
     0.2 mm; 7343 support legs added, 607 spans cut; these defeated both. Set
     `require_no_midair_start: false` or change geometry." The app exposes NO such
     key — whether to offer "export anyway" is HIS call.
   - run #3 (21:49, persisted picks incl. `organic_shape_fit: true`): passed the
     printability gate (!) and was refused at the EXPORT guard — "5 of 237,996
     lattice vertices lie OUTSIDE the solid shell, worst by 0.0318 mm at
     (25.947, −48.942, 14.680), interior strut pass, allowance 0.0001 mm." A core
     clip-vs-shell escape on the shape-fit path — the strut-clip family, not the
     Organic algorithm, and not touched tonight.
10. **Core's span export works on his real part.** The SAME job bytes as run #2,
    replayed on the Mac with `topopt-cli lattice-variant` and the gate off:
    `variant_024_lattice_SPANS.txt` = 1240 SEG lines, 783.28 mm recomputed from the
    file, radii 0.430–2.052 mm; `run_info.json grading.organic.span_count = 1240`,
    `span_length_mm = 783.27785`, `length_survival = 0.130`, `tensor_out_of_regime =
    true`. Receipt and file agree — the §10 check, done by hand on real data.
11. **The receipt read the wrong level.** `OrganicRunReceipt(info:)` read
    `grading.span_count`; core writes `grading.organic.span_count` (every organic
    field is nested). On a real run the receipt was EMPTY and the "PREVIEW DOES NOT
    MATCH THE RUN" guard could never fire. Fixed (nested first, flat fallback) and
    pinned with the replay's numbers; the original test had built a flat dictionary
    and so passed against the broken reader.
12. Restored his `project.json` from the session backup (`BACKUP2`, sha `d6d1d335…`)
    into the current data container after the runs; the app was relaunched to the
    project list.
14. **CORE TASK, REPORTED NOT FIXED (reviewer §4b): the 0.0318 mm shell escape under
    shape fit is a real traced-path bug.** Measurement site: the per-element observer in
    `run_job.cpp` (~2136–2190) records `max_out` per pass into `oc.max_protrusion_mm`
    with `worst_protrusion_pass` ("interior strut" here — organic feeds the same
    observer as octet); the guard at `run_job.cpp:5597` refuses when
    `max_protrusion_mm > protrusion_allowance_mm` (0.0001 mm on an ordinary run).
    On run 3 (organic, `organic_shape_fit: true`): 5 of 237,996 vertices out, worst
    0.0318 mm at (25.947, −48.942, 14.680). Where organic ENDS are clipped to the shell
    before emission was not traced; open whether the shape-fit pull moves an end past
    the clip or a capsule cap is unclipped.
15. **Reviewer §3 — components, reported not changed.** `kOrganicStrandedKeepFraction
    = 0.02` kept 5 pieces on a 2-region part (receipt: `emitted_components 5`, largest
    45.2 % of 783.28 mm, `emitted_stranded_length_mm 429.3`, 8 components / 115.1 mm
    dropped). An endpoint-exact union over the SPANS file (no capsule overlap) splits
    finer — 30 pieces: 335.0 / 184.7 / 132.8 / 50.3 / 13.3 mm then 25 pieces under
    13 mm — so the receipt's 5 are welded-overlap components, not shared-endpoint
    ones. Keep-by-fraction vs keep-by-attachment is the maintainer's decision.
13. OPEN (QA): the organic pane showed "Cell size · Auto·grade" lit while both captured
    jobs carried the OCTET's window — `cell_mode: swept, cell_min 5.5, cell_max 6` —
    inherited from the project's earlier octet settings. `organicCellIndex` reads
    `model.cellSizeMode == .auto` for index 0; the display and the emitted
    `cell_mode` need one source of truth under Organic (what should "Auto·grade"
    write — `cell_mode: auto`? — is a mapping question for the spec's item 1).
