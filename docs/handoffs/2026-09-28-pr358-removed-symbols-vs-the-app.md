# PR #358: every identifier it removed from a core header, grepped against the app

Prompted by the cross-branch break: `5846c476` removed `OrganicGenStats::filleted_spans`
(with `fillet_unresolved`, `fillet_max_radius_mm`) and #354's bridge still read the
first, so #354 + #358 stopped compiling. #354 is fixing its side; the fields are NOT
restored.

The process asked for, adopted here and from now on: before removing or renaming
anything in a core header,

    git grep -n <name> origin/claude/topopt-holes-quilting-298212 -- app/

and list every hit. This is that list for all of #358.

## MAINTAINER DECISIONS (2026-09-28) — both app-side, core unchanged

- **Item 1: option (b).** The app stops writing `organic_overhang_fillet` and drops
  the toggle. **CORE STAYS STRICT — no accept-and-ignore bridge**, so the key remains
  refused and nothing here is added back.
- **Item 2:** the app reads `"unsupported_spans"` and drops the three fillet receipt
  keys.
- #354 is doing both. No core change follows from this audit.

## THE RULE, AS EXTENDED (2026-09-28)

Before removing or renaming anything a consumer can see:

    # symbols
    git grep -n <name> origin/claude/topopt-holes-quilting-298212 -- app/
    # job keys you stop PARSING and receipt keys you stop EMITTING — by QUOTED name
    git grep -n '"<key>"' origin/claude/topopt-holes-quilting-298212 -- app/

and list every hit in the handoff, plus any MEANING CHANGES (see the last section).

The quoted-key half is not redundant with the symbol half: a JSON key can exist only
as a string literal on both sides and never as a C++ identifier, so a symbol grep
would not see it at all. That is precisely how item 1 — a run-time job refusal —
slipped past a cross-branch build that compiled cleanly.

### Quoted-key audit for #358

Keys this PR stopped parsing (`core/src/cli/job.cpp`) or stopped emitting
(`core/src/simp/observability.cpp`), each grepped by quoted name against the app:

| quoted key | stopped | app hits |
|---|---|---|
| `organic_overhang_fillet` | parsed | **6** — item 1 |
| `filleted_spans` | emitted | **1** — item 2 |
| `fillet_skipped_spans` | emitted | **2** — item 2 |
| `overhang_fillet_on` | emitted | **2** — item 2 |
| `fillet_max_radius_mm` | emitted | — |
| `fillet_unresolved` | emitted | — |

Same four as the symbol audit, reached independently. Nothing new, which is the
result you want from a second instrument on the same question.

## Method
Identifiers removed from `core/include/` across `origin/main..HEAD` and not re-added:
14 of them. Each grepped against the app branch. 10 have no app hits and need nothing.

## ★ TWO THAT NEED THE APP'S ATTENTION

### 1. `organic_overhang_fillet` — A JOB KEY THE APP STILL WRITES. A RUN-TIME REFUSAL.
`LatticeSettings.swift:980`

    // ★ absent ⇒ true in core; write only the OFF state (maintainer, 2026-09-05)
    if !organicOverhangFillet { put("organic_overhang_fillet", false) }

with NO `gradingSchemaAccepts` guard. Core no longer lists the key, and unknown keys
are REFUSED, so:

  **a user who turns the overhang flare OFF gets their job refused by core.**

Severity notes:
  - it is intermittent by design: the ON state writes nothing and runs fine, so this
    only fires for users who turn the setting off;
  - A CROSS-BRANCH BUILD CANNOT CATCH IT. It is a JSON key, not a symbol — the two
    branches compile together perfectly and the job fails at run time. Only the grep
    above finds it.
  - 12 app hits in total (bridge.cpp, LatticeSDFMetal.swift, LatticeSettings.swift and
    the wizard); the rest are comments and the UI toggle behind it.

The fix is a decision, not a cleanup, so core has NOT made it unilaterally:
  (a) core accepts the key and ignores it, as ruling F did for `organic_scale`
      ("core may keep parsing the key; it will not arrive"). Every shipped app job
      keeps running, and the outcome matches the user's intent anyway — they asked for
      no flare and there is no flare; OR
  (b) the app stops writing it and drops the toggle, since the repair it controls no
      longer exists.
Core prefers (b) as the honest end state, with (a) as a bridge if any shipped build
writes the key. Note that under EITHER, a user who leaves the toggle ON believes they
have a flare and does not — which is the app's half and is not fixed by this key.

### 2. Receipt keys the app reads that core no longer emits
`OrganicRunReceipt.swift:273-274`

    overhangFilletOn = b("overhang_fillet_on"); filletedSpans = i("filleted_spans")
    filletSkippedSpans = i("fillet_skipped_spans")

None of `overhang_fillet_on`, `filleted_spans`, `fillet_skipped_spans` is emitted by
core any more. They will read false/0 — a SILENT ZERO, which is the exact defect class
this PR spent its time removing (see `organic_unsupported_spans`, which reported 0 on
every run and is 1728 on the stand).

They are not merely stale: the overhang fillet was REMOVED for depositing lumps up to
nine times the strut, and `unsupported_spans` is the measurement that REPLACED it.
The app should read `unsupported_spans` and drop the three above. `OrganicMainWiring
Tests.swift:123` pins `"fillet_skipped_spans": 239` and will need the same change.

## The other twelve — no app hits, nothing to do
`fillet_max_radius_mm`, `fillet_unresolved`, `organic_fillet_radius`,
`organic_fillet_skipped_spans`, `organic_fillet_unresolved`, `organic_filleted`,
`organic_overhang_fillet_on`, `kOrganicFilletAngleDeg`, `kOrganicFilletMaxRadiusRatio`,
`kOrganicFilletSegments`, `organic_shape_fit_candidates`,
`organic_shape_fit_voxels_shrunk`, `organic_shape_fit_min_ratio`.

`filleted_spans` and `overhang_fillet` DO have app hits and are covered above;
`overhang_fillet`'s 23 hits are mostly `bridge.cpp`'s `has_overhang_fillet` SFINAE
detector, which is written to tolerate the member's absence and therefore needs
nothing.

## One that looked alarming and is not
`organic_shape_fit_on` greps to 5 app files. #358 removed only the SHADOWED DUPLICATE
in `LatticeExportOutcome`; the live `RunInfo::organic_shape_fit_on` survives and still
emits `"shape_fit_on"`, which is what `OrganicRunReceipt.swift:275` reads. The other
hits are `organic_shape_fit_only`, a job key untouched by this PR. No action.

## MEANING CHANGES — names that stayed, behaviour that did not

Required in every handoff from 2026-09-28. These compile and grep clean on BOTH
sides and still move numbers, so no grep of any kind will find them. If the app (or
a test, or a quoted figure in a doc) pins a number derived from one of these, it
will move.

| what | was | is | measured effect |
|---|---|---|---|
| `voxel_signed_distance_mm` | measured to voxel CENTRES | measures to the SURFACE (minus h/2) | the field's zero moves half a voxel (0.85 mm on the stand) and its gradient near the wall goes 2 -> 1 |
| `node_merge` | deleted every span shorter than half its radius | keeps member spans; run-collapse resamples | **+11.7 % lattice material** on the stand; spans 16,546 -> 23,998 |
| beam weld input | members up to 28.94 mm against an 0.8 mm reach | subdivided before welding | welded nodes 4,270 -> 14,202; **margin 146.3 -> 210.1 (+43.6 %)** |
| bead calibration | solved against a volume that does not exist | solved on the union | **+44 % mass** (29,234 -> 41,959 mm3) |
| `octet_aesthetic_density_ceiling()` | forward density law, 0.211733 | diameter-table preimage, 0.218871 | 0.2117 sent through the diameter table builds strut/cell 0.196, under the ruled 0.20 |
| organic synthetic stress | per-voxel ramp between 0.25*thr and thr | whole wall, decided by its p99, threshold inclusive | a straddling wall goes 478/480 -> 480/480 voxels synthetic |
| the wetted join | not applied | applied, anchored on the latticed set | carved volume **+22.8 %** on the stand |
| `organic_unsupported_spans` | never written; read 0 on every run | written | **0 -> 1728** on the stand |

The last row is the reverse of a removal and worth the same care: a receipt key whose
VALUE starts being correct will move an app-side number that has been reading a
default, and no grep shows that either.

## MEANING CHANGES, addendum (2026-09-29) — #354's audit items

Same rule, later commits. Nothing here removes or renames anything, so the greps
above all come back clean; these move numbers or fix what a receipt asserts.

| what | was | is | measured effect |
|---|---|---|---|
| `organic_probe.json` `recommendation.fit.margin` / `auto.margin` | `0` whether or not a certificate ran | JSON `null` where none ran, with `certified` beside it | #354's Recommended pill read "· 0.00" on every aesthetic run; it must now read the absence |
| `organic_probe.json` `predicted.reason` under aesthetic intent | "N segments exceed the probe's 600000 cap" (false — a stand run has 39,849) | "aesthetic intent: nothing reads a certificate" | the reason a reader acts on changes; nothing else moves |
| the probe's dead-wall SPACING | graded from the synthetic field, i.e. the window's coarsest end | the window's MIDDLE, via `synthesised_whole`, as ruling H gives the run | a recommended cell can move on any part with a flagged dead wall. Invisible on a degenerate window (`cell_min == cell_max`) |
| the probe's dead-wall DOMAIN | `cand` | that candidate's pre-rim posture mask | **no effect, measured.** For organic every candidate voxel is masked (three `params.organic_geometry` branches in grading.cpp), so the two sets are identical on every organic run. Written for the contract, not for a number |
| `unsupported_spans_seen`'s documented meaning | "could not be held up, so not printed" | "over open air; printed as drawn and counted" | comment only; the count was always of printed spans |

### New receipt keys (additive, report-only)

| file | key | why |
|---|---|---|
| `run_info.json` | `grading.organic.synthetic_stress_by_region[].synthesised_whole`, `.stress_p99` | ruling H's verdict per wall and the measurement behind it. It existed only on a `[synthetic]` stderr line, which is why the run's dead set and the probe's could be compared only by parsing two logs |
| `organic_probe.json` | `candidates[].regions[].synthesised_whole`, `.stress_p99` | the same two for the probe |
| `organic_probe.json` | `candidates[].dead_threshold` | the threshold those verdicts were measured against, so a disagreement is locatable and not merely visible |

No key changes shape or type, and nothing the app already reads changes meaning. The
numbers BEHIND `organic_probe.json`'s recommendation can move (row 3 above).

### The gap these did NOT close

The run's synthesis domain is `lattice_certification_mask(boundary, ...) ∩
gf.posture.mask`, not the posture mask. The probe has no certification mask — it runs
before the variant's shell boundary is built — so it is still the broader set. Nothing
the `cli_organic_dead_parity` fixture can be configured into separated the two (cell
3–10 mm, uniform and swept windows, `min_extrudable_width_mm` 0.45–3 mm, three rho
bands, a manual clearance keep-out, all three outer finishes: `cand` == posture ==
the run's mask in every one). So this is UNMEASURED, not closed, and it is the
remaining way a dead verdict could differ — on a part whose cell-overlap proof or
shell clip rejects posture voxels. Closing it means building a certification mask per
candidate, which is a real cost and its own measurement.

## MEANING CHANGES, addendum 2 (2026-09-30) — #354's variant-work items

Neither item removes or renames anything, and neither changes a job or receipt key's
name, shape or type, so every grep in this handoff still comes back clean. Both change
which jobs are ACCEPTED — but NOT in the same direction, and the first draft of this
section blurred that (reviewer, 2026-09-30):

- **Only item 1 can refuse a job that was previously accepted**, and only a
  hand-authored one (see the app-impact note below).
- **Item 2 makes wrongly refused jobs RUN.** It could refuse a job only if that job's
  plan had been packed against the wrong wall to begin with, and the app packs by
  include order (`LatticeSteppedCellWire.wire`), so there is no such job.

| what | was | is | effect |
|---|---|---|---|
| a face lattice region's stated `frame_u` / `frame_w` | the "axes must lie IN the face plane" check ran before `normal` was parsed, so it tested against `Vec3{0,0,0}` and could never fire | parsed after `origin`/`normal`, against the UNIT normal | an out-of-plane frame is now REFUSED AT PARSE TIME instead of being accepted and then refused mid-run by `clearance.cpp`'s `frame_conflict`. A job the app could previously submit and watch fail after a solve now fails on submission, with the reason |
| the stepped plan's prism per region | `lattice.regions[region_id - 1]` — an index over ALL regions | `job_include_region(regions, region_id)` — a position among INCLUDE regions, which is what the id means | on a job with an exclude declared BEFORE an include, the plan took the exclude's `slot_origin` / `normal` / `depth_mm`. Measured: the identical include and the identical one-cell plan are ACCEPTED with the include alone and REFUSED with an exclude first. Ordering-dependent, so a plan the app packed correctly could be refused for a reason naming the wrong wall |

### The frame check: what a job that was passing may now be refused for

The in-plane test is also now taken against the NORMALISED normal, and the direction
of that effect is the opposite of what I first wrote here (reviewer, 2026-09-30).
`u · n = |n| (u · n̂)`, so the raw test `|u · n| < 1e-6` accepts `|u · n̂| < 1e-6/|n|`:

| `\|n\|` | raw admits | so the raw test was |
|---|---|---|
| 1000 | 1e-9 rad | 1000x STRICTER — refuses a frame that is in plane |
| 1 | 1e-6 rad | the intended bound |
| 1e-3 | 1e-3 rad | 1000x LOOSER — the dangerous case |

A SHORT normal is the loose one, not a long one. Both directions are now pinned by a
test that goes red with the raw dot product restored (`test_job` cases (g) and (h));
every other frame case returns the same verdict under both rules.

APP IMPACT: NONE. The app does not state an arbitrary frame — it builds `frame_u` /
`frame_w` from the UNIT normal by cross products (`LatticeSettings.swift` ~326-333,
`LatticeRegionMask.basis`), so its axes are in plane to ~1e-16 at any `|normal|`, under
either rule. The refusal is reachable only by a hand-authored or third-party job.

### The stepped id: the rule, stated once

Every 1-based region id crossing the bridge — the per-voxel `region_ids`,
`SteppedCell::region_id`, `SteppedRegionCell::region_id`,
`SyntheticStressRegionReport::region_id` — is a position among the job's **include**
regions in declaration order, never an index into `lattice.regions`. Swept the file:
`region_id - 1` appeared at exactly one site, the one fixed here. The doubled path
beside it (`run_job.cpp`, the `base_of` loop) already walked the regions and counted
includes in lockstep, which is the correct pattern and is why only the stepped branch
was wrong.

Resolving that id is now `job_include_region()` in `job.hpp`, so the decision has a
test (`test_job`'s "a stepped cell names the include, not the nth region") instead of
sitting inline in `run_job.cpp`.

★ AND A CORRECTION TO THE DIAGNOSIS I gave with the previous two commits (reviewer,
2026-09-30). I wrote that "nothing links `run_job.cpp`". That is false: it is compiled
into `libtopopt`, and `test_job_loadcase_copy` calls `production_loadcase_from_job`
(run_job.cpp:7788) out of it, as do two harness probes. What hides these decisions is
the three ANONYMOUS NAMESPACES at :67-7774, :7934-8739 and :10673-10933 -- nothing in
them has external linkage, so no test can name them whatever it links.

The remedy is unchanged: lift a decision into a testable place when you touch it. But
the cheaper route for a large function that is NOT a job-schema fact is to move it out
of the anonymous namespace and declare it in an internal header WITHOUT moving the
body -- the precedent `production_loadcase_from_job` already sets. A job-schema fact
like `job_include_region` still belongs in `job.hpp`. No inventory or refactor is
proposed here.

## The probe's certification-mask gap: SPENT, and it measures as a no-op (2026-09-30)

The gap left open on 2026-09-29 is closed by construction: the run's synthesis domain
is now one function, `lattice_synthesis_domain()` in `lattice_boundary.hpp`
(`lattice_certification_mask(boundary, …) ∩ posture`), and the run and the organic
size probe both call it. The probe builds its own boundary per candidate because the
cell-overlap proof is a function of the cell.

**Cost, measured on the maintainer's stand** (`.m2_organic_aes_synth3`, resolution 128,
organic aesthetic, one candidate window 4.5–5.5 mm):

| | |
|---|---|
| grid | **468,224 voxels** — resolution 128 on the stand's bbox, not a 128³ cube (2.1M) |
| boundary + domain, per candidate | **0.1455 s** |
| the probe's own per-candidate total | 3.8 s |
| **added** | **3.8 %** — under the 10 % bar |

**Effect, on the same run: NONE.** `|posture| = 62,465` and `|domain| = 62,465`. The
domain is `posture ∩ cert` by construction, so ⊆ posture; equal counts therefore mean
the sets are EQUAL, and the probe's inputs are unchanged voxel for voxel. Same on the
`cli_organic_dead_parity` fixture, where a `loads.clearances` keep-out shrinks the
CANDIDATE set too and so moves both terms together.

**So no meaning-changes row, and that is the finding.** This is the SECOND time this
gap has measured as a no-op: the `cand` → posture move was the first
(`params.organic_geometry` masks every candidate). On both parts available, all four
sets — `cand`, the posture, the certification mask and the run's `mask` — coincide.
What is bought is the CONTRACT, not a number: the probe can no longer drift from the
run by using a different set, and there is now one definition to change instead of
five inline lines plus a call site that forgot them.

What would separate the sets is the shell base rejecting posture voxels at convex
edges (the isosurface chamfers the voxel-cube union — see `lattice_boundary_for`'s
note, measured at h/√3 = 0.984 mm on a 1.705 mm voxel). Neither part exercises it.
`test_lattice_clip_shell`'s "the synthesis domain is cert ∩ posture" builds a synthetic
grid with a keep-out where the sets DO differ (printed 512, certified 408), and goes
red on 5 checks when the intersection is dropped — that is where the guarantee lives,
not in either part's numbers.

### Open item carried forward: a convex-edge fixture

The certification-mask term of `lattice_synthesis_domain()` is guarded by
`test_lattice_clip_shell`'s synthetic keep-out grid (printed 512, certified 408), and
that is where the maintainer has decided the guarantee should live for now (reviewer,
2026-09-30: "No convex-edge fixture now"). What no fixture exercises is the term that
could separate the sets on a REAL part: the shell base rejecting posture voxels at a
CONVEX EDGE, where the marching-cubes isosurface chamfers the voxel-cube union
(measured h/√3 = 0.984 mm on a 1.705 mm voxel — `lattice_boundary_for`'s note, and
evidence/2026-08-08-strut-clip-matches-shell/s1b_surface_gap.csv).

**Open item:** a real part with a convex edge INSIDE a lattice region, to be built only
if a probe/run mismatch ever appears. Until then the probe and the run cannot differ,
because they call the same function — which is the point of that change, since its
measured effect on every part available was nil.

## MEANING CHANGES, addendum 3 (2026-10-01) — lattice types round 1

Nothing removed or renamed in core's public surface except one rename, listed first.

| what | was | is | app impact |
|---|---|---|---|
| `lattice_relative_density(topo, …)` (free function, added and renamed within this round) | that name | `lattice_density_from_strut(topo, …)` | **none** — it never existed outside this round. `SimpParams::lattice_relative_density`, the pre-existing field it collided with, is untouched. Grepped PR 354: no hits for either name as a function |
| a job stating `lattice.topology` and `grading.topology` as DIFFERENT types | accepted; sizing read one, generation the other | **REFUSED at parse time**, naming both values | **none.** The app writes both from one setting — `RemoteRunner.swift:758`, `RelatticeRunner.swift:107` and `LatticeSettings.swift:850` all send `lat.topologyID`. Confirmed by grep, not taken on trust |
| the refusal text for an unknown/not-ready topology | `lattice "topology" must be "octet" (got "X")` | names the type AND which half is missing: not a topology at all / certifiable but not generatable / generatable but not certifiable / neither | **none** — grepped PR 354 for the old message text: no matches. The app should now read `lattice_type_readiness_plain()` instead of wording its own |
| `run_info.json` `fingerprint` / `build_time` on `lattice-variant` and graded `analyze` | `"unknown"` and `""` on every run | the binary's real SHA and build time | **none found** — `git grep` over PR 354's `app/` for `run_info.*fingerprint` / `fingerprint.*run_info` returns nothing; the app checks versions via `--version` and the worker's advertised fingerprint |

## MEANING CHANGES, addendum 4 (2026-10-07) — the plan validator's containment rule

From #354's core brief of 2026-10-02 (R2, R2x, R2b) and the reviewer's ruling of
2026-10-05. ONE containment rule now applies to every face, axis-aligned or tilted: the
cell's CENTRE must lie in the region's prism, its FAR side must not pass the depth
(cube's true projection interval), and its NEAR side MAY stand in front of the face plane.

| what | was | is | app impact |
|---|---|---|---|
| a cell in the deepest layer of a region whose normal has a NEGATIVE component | REFUSED, "lies from 12 to 15 mm … outside its 12 mm prism" — the check projected the cell's minimum corner, which on such a face is its deepest point, so every layer read one cell too deep | ACCEPTED | **intended, and it unblocks the app.** 1,467 cells on the stand's -y wall alone were refused this way, every one false, and the check runs after SOLVE 1 so each refusal cost a solve |
| a cell lying wholly in FRONT of the face plane, outside the prism and outside the part | ACCEPTED and LAID — 612 lattice triangles sitting on the part's face, every vertex at y 11.55–12.45 (R2x) | **REFUSED**, naming the interval, the centre and which clause bound | **intended.** This is a false ACCEPTANCE being closed: core was emitting geometry outside the part. A plan that relied on it was already producing a wrong part |
| a TILTED facet's cell whose near side starts in front of the plane but whose centre is inside | accepted (the one-corner read happened to allow it) | ACCEPTED — explicitly, by rule | **none, and deliberately so.** The app starts a facet's span in front of the plane BY DESIGN so the cube covers the slant (`LatticeOctreeBake.swift:187-202`); a near-side bound would have refused the stand's 90 face-23 facet cells. Guarded by a 45° test that goes RED if a near-side bound is reintroduced |
| the depth refusal's wording | reported `s0` and `s0 + size` | reports the projection interval, the centre, and that the centre must be inside while the near side may stand in front | **none** — grepped PR 354's `app/` for the old sentence: no matches |

Net: jobs whose regions have positive axis normals and whose cells sit inside the prism
are unchanged. Jobs with negative-normal walls or tilted facets change verdict — which is
the point of the brief. `test_stepped_plan.cpp` had never set `normal` or `depth_mm`, so
this check was wholly untested before this commit.

## MEANING CHANGES, addendum 5 (2026-10-07) — an empty lattice is a refusal

From #354's core brief of 2026-10-06 (D10/E3) and the reviewer's ruling of 2026-10-07.

| what | was | is | app impact |
|---|---|---|---|
| a job whose grade latticed voxels that the outline beam then cleared ENTIRELY, under `doubled` | **ACCEPTED** — "over 0 voxels", `verdict: ACCEPTED`, `interior_volume_mm3` 0, a finished part with no lattice in it | **REFUSED**, naming what the grade latticed, what the beam cleared, the beam's reach and the band that set it | **the app must expect a refusal where it used to get a file.** This is a false ACCEPTANCE being closed: #354 hit it on 3418E167 converted to Doubled. A refusal costs a solve; this was costing a print |
| the same case under `stepped` | refused, but blamed "0 latticed voxels carrying 0 distinct region ids … 0 region(s) had no measurable member width" and recommended `"algorithm": "doubled"` | refused with the SAME sentence as doubled, naming the beam | **better diagnosis, same verdict.** The old sentence pointed at region ids, which were not the cause, and recommended the path that accepted nothing |
| any refusal recommending an algorithm | `use "algorithm": "doubled"` | no algorithm is recommended anywhere on this path | **none** — grepped PR 354's `app/` for the old sentence: no matches |

Note on scope: the beam cannot be the cause under `organic`, because `shape_grade` is
refused at parse time for organic (job.cpp:2115), so organic has no post-BEAM empty mask
to reach. The check is unconditional regardless, so anything else that empties the mask is
caught by the same sentence instead of by nothing.

Unchanged: a job whose lattice survives the beam. The control fixture
(`empty_after_beam_control.json`, a 10 mm band, under the 25 mm bleed threshold) keeps 440
of its 750 voxels and is still accepted — and the test requires that count to be non-zero,
so a future change that emptied every lattice could not pass as "it refuses correctly".

## MEANING CHANGES, addendum 6 (2026-10-07) — the in-plane slot origin, as sent

From #354's core brief of 2026-10-02 (R1), the maintainer's ruling (b) and the reviewer's
ruling of 2026-10-05. A new OPTIONAL key on a face lattice region's geometry:
`slot_origin_mm`.

| what | was | is | app impact |
|---|---|---|---|
| a job stating `lattice.regions[].geometry.slot_origin_mm` | **REFUSED** as an unknown key | accepted; that point is the grid alignment, depth, overlap, grouping and laying all measure from | **this is the key R1 asked for.** The app can stop having its anchor search refused: on every project the non-base cells were off core's grid by one constant in-plane vector per region (570B38E2 region 1: x = 1.6647, z = 0.5443 mod 2.578) |
| a job NOT stating it | the region `origin` is the slot origin | unchanged — the derived origin still stands | **none.** Proved by a control fixture: the identical plan without the key is still refused, so nothing moved for existing jobs |
| a stated slot origin with a component along the region normal | n/a (the key did not exist) | **REFUSED at parse time**, naming the region, the key and how far out of plane it stands | **intended.** An anchor shift is in-plane by definition; a normal component would move the plane the prism's depth is measured from and change every containment verdict in silence |

Tested against the UNIT normal, for the reason recorded for `frame_u`: the raw test
`|d·n| < eps` accepts `|d·n̂| < eps/|n|`, so a SHORT normal is the loose and dangerous
case, not a long one.

### ★ CORRECTED 2026-10-09 (K2): the slot origin is a grid PHASE, not a plane point

The row above requiring `slot_origin_mm` to lie in the face plane is **withdrawn**. The
reviewer corrected the ruling it implemented (2026-10-05 -> 2026-10-08): the requirement is
wrong for a **tilted facet**, whose grid in the app is world-aligned, so the point the app
packed from legitimately stands off the plane. Forcing it on would make the app re-anchor
tilted ladders, which changes the preview the maintainer approved. #354 measured the cost of
the old rule: on 102117B9, 22 of the 23 regions with cells are tilted, and on 68BF7B74 face
23's three facets stand 13.26, 0.58 and 0.10 mm off their planes — all parse refusals.

| what | was (b6e011d5) | is (K2) | app impact |
|---|---|---|---|
| a `slot_origin_mm` with a component along the region normal | **REFUSED at parse**, naming the region and the distance | **accepted** — it is the grid phase | **the refusal is gone.** Tilted facets can send the grid they packed on |
| what DEPTH is measured from | the slot origin, so moving the phase along the normal silently moved the prism | the region's own plane (`SteppedPlanRegion::plane_origin`) | **intended, and it is the property that makes the split safe:** the phase sets alignment, overlap and grouping; it cannot shift the prism |

Measured on the rebuilt fixture: with the slot origin one base cell inward, cells at y 0..3
and 0..1.5 of a 12 mm prism are inside when measured from the plane, and project to centres
of **-1.5 and -2.25** when measured from the slot origin — which is why core refused them
before K2. One fixture distinguishes the two readings.

Note for the R6 work that follows: with the slot origin on the wire, the stricter
base-cell alignment R6 asks for can land without refusing the app's current plans — which
is why this key goes in first.

## MEANING CHANGES, addendum 7 (2026-10-07) — who owns shared space, and exact overlap

From #354's core brief of 2026-10-02 (R3, R5, R7's note) and the reviewer's ruling 4 of
2026-10-07.

| what | was | is | app impact |
|---|---|---|---|
| a voxel inside TWO include prisms | given to the FIRST matching region in DECLARATION ORDER, however far its face | given to the region whose FACE PLANE is nearest; an exact tie to the lower region id | **core now matches the app's own rule.** Where prisms overlap, the cell/density/void id a voxel is graded at changes, and so does the emitted geometry. Jobs with overlapping prisms change |
| the same job with its regions declared in the opposite order | a DIFFERENT part (measured: STL `7f602f83…` vs `4c5809b0…`, and one run derived a cell for one region where the other derived two) | **byte-identical** (`9c5e8280…`) | **intended.** The order the app writes regions in is not geometry |
| two cells that merely TOUCH, in regions whose ladders do not nest | REFUSED as overlapping — 1,458 false collisions on 570B38E2, every one false | accepted | **unblocks the app** (R5) |
| two cells at the same offset in DIFFERENT regions, far apart in space | REFUSED as overlapping (the hash key had no region id) | accepted (R3) | **unblocks the app** |
| two cells occupying the EXACT SAME BOX in different regions | **ACCEPTED** — offsets were measured from each region's own slot origin, so their hash keys differed | REFUSED, naming both cells, both regions, the overlap extent and which region owns each centre | **a false ACCEPTANCE closed.** R3's key defect ran both ways, and this direction ships a wrong part |
| two cells half a cell apart where a region's menu holds only its base | **ACCEPTED** — the hash tile equalled the cell, so one-slot-wide cells rounded apart | REFUSED | **a second false ACCEPTANCE closed** |
| a cross-region overlap at a mitre, each cell's centre owned by its own region | refused (as any cross-region overlap was, when detected at all) | **ACCEPTED** as a straddled seam; only the owner's lattice is laid in the shared space | **intended** — the app keeps such cells whole, and the stand has 1,367 real overlapping pairs that are NOT seams and stay refused |

**Where no prisms overlap, nothing changes — by construction, not merely by test.** A point
lies in at most one prism, so "first match" and "nearest face plane" name the same region;
a point in no prism returned 0 before and returns 0 now. The change can only reach a point
inside two or more prisms. The suite's existing receipt and STL pins are the empirical
check on top of that (135/135).

Containment itself is NOT a second implementation: `stepped_region_owner` calls
`point_in_clearance_region`, the predicate core already resolved per-voxel membership
with, so there is one containment test and only the tie-break is new. The function is
exported so #354's R7 can call it through the bridge instead of keeping a Swift copy:

    int stepped_region_owner(const Vec3& p, const std::vector<ClearanceGeometry>& includes);
    // 1-based index into `includes`, or 0 for NO OWNER.

## MEANING CHANGES, addendum 8 (2026-10-07) — R6: what is accepted is what is laid

From #354's core brief of 2026-10-02 (R6, R6b, R6c, R6d) and the reviewer's ruling 3 of
2026-10-07.

| what | was | is | app impact |
|---|---|---|---|
| a DOUBLED cell not on its own size's grid from the slot origin | ACCEPTED, then LAID somewhere else — up to half its size away, with no receipt recording the move | **REFUSED**, naming the offset and that a halving octree can place it nowhere else | **intended.** R6 (a base cell 1 mm off) and R6b (an S/2 cell on the S/4 tile) are refused. A halving octree cannot produce such a cell, so a plan containing one did not come from one |
| a base-size cell, either menu | exempt from the alignment check entirely | checked like any other cell | **intended.** A base cell is a whole slot and belongs on the base grid. This is also what made the moves invisible: the app's base cells sit off core's grid by R1's anchor, which is why `slot_origin_mm` landed first |
| an ANY-STEP k-tile cell at a whole tile that is not a multiple of k tiles | accepted, then MOVED — measured at 1 mm (R6), 2.41667 mm (R6c, landing ON TOP of its neighbour) and 2.9 mm (R6d) | accepted and laid **where sent** | **intended, and it is why any-step packs were coming out wrong.** R6c's lattice covered x 18–20.42 twice and left x 25.25–27.67 bare |
| core's own packed-slot fixture, sampled on the cells as LAID | 7,344 covered once, 3,240 uncovered, 3,240 covered twice | 13,824 / 0 / 0 | n/a — a core test. `test_packed_slot_covers_exactly_once` is untouched (it checks the SENT plan, still a valid property); a new test beside it samples the grouped cells |

Controls keep their STLs, checked against the hashes #354 recorded:
`R6_control_on_grid` 1ccf1bdf90a8…, `R6b_control_half_at_21` e630030f9ccf…,
`R6d_control_first_slot` 5cae340a5661… — byte-identical. And `R6d_anystep_second_slot`'s
STL no longer equals `R6d_ref_at_25_4`'s, which is the brief's own after-the-fix test.

**★ WITHDRAWN 2026-10-09: the 2.0x figure below was a proxy, and his real plan is 1.00x.**
Measured on 570B38E2's actual Default Grade plan (4,198 cells, 2 regions): grouped by
(region, size) **4 passes**, grouped by (region, size, phase) **4 passes** — ratio **1.00x**,
and the run itself reported 4 passes, which cross-checks the arithmetic. Each (region, size)
in his plan has exactly one phase, so phase bucketing costs nothing there. The 37-cell plan
below was generated by me and is not representative; it stands only as the worst case I could
construct.

**The cost, measured.** A group is an emission pass, and the phase join multiplies them.
On a 37-cell any-step plan with three sizes at mixed phases: passes **3 → 6 (2.0×)**, wall
time **1.6 s → 1.6–1.7 s (flat)**. On R6c and R6d: **unchanged (1.0×)**. The reviewer's gate
was "stop if either grows more than 2×"; 2.0× does not exceed it and the wall clock did not
move, because each pass carries proportionally fewer cells. CAVEAT, stated because it
bounds the result: his three project plans are not available in this worktree, so the
37-cell plan is a generated proxy for the gate, not the gate itself.

## MEANING CHANGES, addendum 9 (2026-10-08) — one floor for "the smallest cell that prints"

From #354's printability brief of 2026-10-06 (E1, D1, D2, D11).

Core answered one question with three numbers. On octet at a 0.45 mm bead, measured:
`w/phi(rho_min)` = **4.931378498** mm (the light floor), `w/phi(min(rho_max, cap))` = **2.25**
mm (what `grade_lattice` applies), `w/phi(rho_max)` = **1.173173434** mm (what four other
paths computed inline). One run printed two of them under one key name.

| what | was | is | app impact |
|---|---|---|---|
| `lattice_min_printable_cell_mm(topo, w, max_relative_density)` | did not exist in core; the app composed it in the bridge (PR #354 1db8bba7) from `lattice_rho_max` + `lattice_strut_diameter_mm` | **exported**, with the app's exact name and signature | **the bridge can delete its copy and read core.** A cap of 0 or non-finite means NOT SENT, matching the app's semantics |
| the smallest printable cell on the Fit, Fixed, Swept, region-report, pre-flight, frozen-lattice and swept-frontier paths | the UNCAPPED floor (finer than the job can print) | the floor at the job's cap | **a job with a cap gets different numbers, and they are the ones grade_lattice applies.** `fit.min_printable_cell_mm` and the per-region receipt no longer disagree |
| `lattice_derive_cell_for_member`, `lattice_min_density_for_strut`, `cell_plan_finest_printable_cell_mm`, `lattice_region_validity` | no cap parameter | a TRAILING, DEFAULTED cap parameter | **none until the app passes one.** All four are called from `bridge.cpp`/Swift; grepped before changing |
| the swept plan's per-cell predicate | asked whether the BAND's densest density prints | asks whether the densest density **the job allows** prints | **intended** — it admitted rungs whose struts the job can never reach |
| Fit's derived density when nothing in the band prints at that cell | `lattice_rho_max` — a density the job may forbid | the densest the job allows | **intended** (found by sweeping, not from the brief's list) |
| `fallback_irrecoverable_by_cell` on uniform and swept | counted against the LIGHT floor: at N* = 5 "beyond rescue" below **24.66 mm** | counted against the dense floor, like Fit: below **11.25 mm** at the cap | **the refusal sentence and the forecast's remedies change.** A 16 mm member was called irrecoverable on uniform while Fit could reach it. Measured on a fixture: 8 of 13,500 rejected voxels are irrecoverable where the light floor called all 13,500 |

NOT DONE, and not mistakable for done: nothing in `core/src` assigns
`frozen_lattice_min_extrudable_width_mm`, so nothing assigns the new
`frozen_lattice_max_relative_density` either — that options block is filled by the caller.
The field is threaded through `lattice_region_validity` and `minimize_plastic`, but the
frozen-lattice floors stay uncapped until the app sets it.

Also recorded, because two of my own assumptions were wrong about it: the diameter law is
**clamped above rho 0.60**, the measured table's last row, so a cap anywhere from 0.60 to the
band top 0.899880 is **completely inert**. Monotonicity in the cap is therefore non-strict,
and the flat top is pinned by its own check so a future row reports itself.

## MEANING CHANGES, addendum 10 (2026-10-09) — D5: the density that came with the cell

From #354's printability brief (D5) and the reviewer's ruling of 2026-10-08.

| what | was | is | app impact |
|---|---|---|---|
| a plan cell's own `rho` | checked against NOTHING in the validator — it never read `cell.rho`; the schema admits any (0, 1] | the strut it builds at **its own size** must clear the bead, or the cell is refused by name with the number | **a plan pairing a size with too light a density is refused.** Measured: rho 0.10 at a 3 mm cell builds a 0.4002 mm strut against a 0.45 mm bead |
| a plan cell's `rho` above the job's `max_relative_density` | accepted, then clamped downstream | **REFUSED**, quoting the cap | **intended.** The density sizes the strut, so clamping silently prints a cell lighter than the plan asked for |
| the plan's BASE cell | no floor at all — "the base is always on its own menu" | subject to the same tile floor and bead as every other size | **a region whose base is below the floor is refused, and the refusal NAMES the base and the floor** rather than reporting an empty menu and leaving the cause to be inferred |
| the doubled tile floor | `stepped_min_tile_mm`, or else **the bead** — and a doubled job cannot carry that key at all, so it was just over the bead (0.45 mm) | `max(lattice_min_printable_cell_mm(topo, w, cap), stated)` — **2.25 mm at the job's cap** | **a capped job's plan is held to the real floor.** Uncapped jobs get 1.173 mm, so all eight of the brief's existing jobs are unaffected |
| a cell that sends no `rho` | unaffected | unaffected — not judged on a density it did not send | **none** (every job before ruling C) |

NOT SHIPPED, and not from indecision: "apply to a doubled plan the same bound the app applies
to Default Grade". `prints_open` still hangs on `intent == "aesthetic"`, which a doubled job
never carries. I searched the app for that bound (`printsOpen`, `minTile`, `ladderSizes`,
`stepped_size_menu`, the 0.20 ratio) and found nothing, so I have asked rather than guess a
design rule. Under the standing rule the app's design is the source of truth, and this is the
app's.

One existing fixture's DATA changed, not its assertions: `test_group_keeps_each_cells_own_rho`
paired 3 mm cells with rho from 0.10, which the new check correctly refuses (0.4002 mm strut,
0.45 mm bead). Those values were chosen to be DISTINGUISHABLE — each a function of the cell's
position, so a mispairing cannot look right — and that property is untouched at 0.20..0.21,
which also print (0.5694 mm). The measurement is recorded at the fixture.

## MEANING CHANGES, addendum 11 (2026-10-09) — K1: the plan's base travels on the wire

From #354's plan map and the reviewer's rulings of 2026-10-08 and 2026-10-09 (the second
correcting the first).

| what | was | is | app impact |
|---|---|---|---|
| an ANY-STEP plan's base per region | core's own FEA-derived cell (`R.stepped.cells`), so every app plan was validated against a number the app never used | the SENT base | **this is what refused every Aesthetic Stepped plan.** #354 predicted "not on that region's menu" on every project, and I reproduced it |
| `lattice.regions[].geometry.plan_base_cell_mm` | did not exist | **REQUIRED** on every region the plan places cells in; a planned region without it is refused by name, with its cell count | **new key.** Production sends no plans yet, so nothing breaks |
| a DOUBLED plan's base | the region's largest sent cell | the same sent key | **none in effect for halves** — a halving ladder's inference happened to be benign — but it is no longer a guess |

**Why not infer it.** An intermediate cut of K1 took the region's largest sent cell, which is
what doubled already did. It is a silent substitute: a region need not contain a base-size
cell. Measured on 3418E167's real Aesthetic Stepped plan — region 1 sends only 3.5 mm and
4.6667 mm cells while the app's base is **7 mm**. The inference guessed 4.6667, and:
- the menu at 4.6667 admits ONE size under prints-open, so the 3.5 mm cells were refused;
- and three quarters of a rounded 4.6667 is **3.500025**, not the 3.5 the plan sends, so even
  the right ratio missed by 25 µm.

**The prints-open finding, corrected.** I first reported prints-open as blocking his plan at
the 3.5 mm cells. That was the wrong-base artefact. With base 7 sent, region 1's menu is
**{7, 3.5}** and 3.5 passes; what is refused is **4.6667** (683 cells), which needs divisor 3
— dropped because at base 7 a 2.333 mm tile cannot hold a bead-wide strut and stay open.
Region 2 at base 12 keeps its thirds and its cells (6 and 3) pass, so the rule is
base-dependent. The maintainer's decision on which rule is physically right now has its
evidence.

### The fingerprint defect, for the record

Not the worktree (`git -C core rev-parse` resolves fine there), and not only the
dispatch order. `analyze_job` (run_job.cpp:9341) and `lattice_variant_job` (:10263)
each built their receipt with `build_run_info(job, options, RunObservability{})` — a
**default-constructed** observability — so they would have reported "unknown" even if
`main()` had populated its own `obs` before dispatching. Fixed by having the
executable state its identity once (`set_build_identity`, called before any dispatch)
and both receipt paths read it.

★ `analyze` is affected **only when a `grading` block is present**: its write site sits
inside `if (job.grading.present)` (:9157), and that guard's own comment says no
run_info is written otherwise. My first version of the test used an ungraded analyze
job, wrote no run_info, and failed for the wrong reason — mapping a write site to its
function is not the same as reaching it. `preflight` writes no run_info at all and is
unaffected.
