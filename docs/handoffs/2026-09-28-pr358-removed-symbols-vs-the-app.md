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
