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
