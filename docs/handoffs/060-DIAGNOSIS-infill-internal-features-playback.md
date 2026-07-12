# Diagnosis 060 — infill/solid FEA assumption, internal periodic features, playback-slices & missing flex

**Track:** diagnostic (READ-ONLY). No source/test/ROADMAP/DECISIONS/fixture file
was modified. No code changed, no PR opened, no box checked. The only file
written is this report.

**Scope:** four questions the prior diagnosis (059) did not cover. main is
clean/current; all M7 merged. Findings are grounded in first-hand reads of the
core (`fea/`, `simp/`, `settings/`) and app (`TopOptFlows/`, `TopOptBridge/`,
`TopOptKit/`), cross-checked by four parallel探索 agents.

---

## TL;DR

| # | Question | Verdict | Confidence |
|---|----------|---------|------------|
| 1 | Does FEA model every printed voxel as **solid**, with infill only a post-hoc recommendation? | **YES — confirmed. The margin shown to users is a SOLID-part margin. It does NOT account for infill.** A real print at (e.g.) 15 % infill is far weaker than the margin implies. **Safety-relevant.** | **High** |
| 2 | Are the internal repeating fins checkerboarding, an MC artifact, or real? | **Most likely mesh-dependence** from a filter radius fixed in *voxels* (2.5) that does not scale to physical size — thin members proliferate at 128³. Not classic checkerboarding (the filter suppresses that), not primarily an MC-on-gray artifact. | Medium-High |
| 3 | Why does playback show **slices** instead of a morph? | The "slices" is the **reveal-scrub fallback** used **when the selected variant has no keyframes** (empty `keyframeMeshes`). The full keyframe pipeline is statically correct on every path, so the emptiness is a **runtime** phenomenon. | High (mechanism) / Medium (why empty) |
| 4 | Why is the **flex animation** absent? | The Flex control is gated by `hasFlex`, which is false **when the selected variant's `displacementField` is empty**. Same shape as #3. | High (mechanism) / Medium (why empty) |
| 3+4 | Shared root? | **Yes.** Both are "the selected variant reached the UI with its heavy per-variant arrays empty." This plausibly extends to the **059 crash** — all three live on the untested 128³ large-nested-vector marshaling/streaming path — so #1(crash), #3, #4 may be **one regression**. Needs runtime confirmation. | Medium |

---

## Item 1 — INFILL / SOLID ASSUMPTION (safety-relevant) — CONFIRMED

**Plain answer: The FEA/SIMP solver models kept material at the material's full
solid Young's modulus. "Infill %" is only ever an *output* of a heuristic rule
keyed off the stress margin; it never re-enters the FEA. The stress margin the
user sees is the margin for a part printed SOLID. It does NOT account for
infill, so at a typical FDM infill the real part is materially weaker than the
margin implies.**

### Where the modulus enters element stiffness

- Element stiffness is built from the **material's Young's modulus** (solid),
  either uniformly or per-voxel:
  - [`hex8_stiffness(youngs_modulus, …)`](core/src/fea/hex_element.cpp:89) builds
    the unit element; the isotropic Hex8 is exactly linear in E.
  - [`assemble_reduced`](core/src/fea/assembly.cpp:243) uses
    `hex8_stiffness(graded ? 1.0 : youngs_modulus, …)` and, on the graded path,
    scales each solid voxel's element by `elem_youngs[…]`
    ([assembly.cpp:255-261](core/src/fea/assembly.cpp:255)).
- The SIMP material law is the classic **E(ρ) = ρ^p · E₀** with p = 3:
  [`simp_youngs`](core/src/simp/simp.cpp:79) and the per-voxel fill at
  [simp.cpp:142-144](core/src/simp/simp.cpp:142), where `params.youngs_modulus`
  = `material.youngs_modulus_mpa` (the **solid** modulus), set at
  [minimize_plastic.cpp:108](core/src/simp/minimize_plastic.cpp:108).
- Here **ρ is the topology design density (material present/absent)**, NOT print
  infill. With Heaviside projection (β → 32,
  [simp.cpp:115-121](core/src/simp/simp.cpp:115)) kept voxels converge to ρ ≈ 1,
  i.e. E ≈ E₀.
- **The reported stress uses the full solid modulus:**
  [`hex8_stress(params.youngs_modulus, …)`](core/src/simp/minimize_plastic.cpp:210)
  over the printed voxels (ρ > kIso = 0.5). `max_von_mises` from this feeds the
  margin.

### Infill/wall are downstream-only (grep classification)

- **Zero** occurrences of `infill`/`wall` in `core/src/fea/`, `core/src/simp/`,
  `core/src/materials/`. They appear **only** in the settings rule engine and
  report emitter: [settings.cpp:313-522](core/src/settings/settings.cpp:313),
  [report.cpp:69-72](core/src/settings/report.cpp:69), and the struct fields in
  [settings.hpp:26-65](core/include/topopt/settings.hpp:26).
- The header states it outright: *"heuristic rules over a stress margin, **NOT
  simulated infill** (ARCHITECTURE.md §2)"*
  ([settings.hpp:14-15](core/include/topopt/settings.hpp:14)), matching
  [ARCHITECTURE.md:21-22, 35-36](docs/ARCHITECTURE.md:21).

### The margin → infill direction is one-way

[`recommend_settings`](core/src/settings/settings.cpp:451) takes
`worst_case_stress_margin` as an **input** and returns `infill_percent` from a
band lookup + size modifier + clamp. It is called at
[minimize_plastic.cpp:264](core/src/simp/minimize_plastic.cpp:264) with
`margin.worst_case` — which was computed at solid modulus. **There is no code
path where infill % or wall count feeds back into the modulus used by the
solver.** (`z_knockdown` at [materials.hpp:14](core/include/topopt/materials.hpp:14)
is a *layer-adhesion anisotropy* factor applied to the interlayer margin only —
not infill.)

### Magnitude of the gap

Real FDM infill stiffness scales roughly with infill fraction (sub-linear for
sparse patterns; walls dominate bending). As a rule of thumb, **15 % infill ≈
0.1–0.2× the solid stiffness/strength of the infilled interior** (perimeters
recover some, but not all). So a part the tool reports at, say, a 20× solid
margin, printed at the *recommended* 15 % infill, can have a **real margin
several-fold lower** than displayed. Combined with 059's finding that a light
load already yields a ~20× margin that walks the reduction ladder to its
lightest rung (0.26 VF), the compounding is: *topology stripped to 26 % on a
solid-part margin, then printed sparse-infill.* The topology reduction **is**
modeled (void voxels contribute no stiffness); the **infill within the surviving
shape is not.**

### Safety statement (as requested)

**The stress margin shown to the user does NOT account for infill.** It is a
faithful margin for the optimized shape printed at 100 % solid. Any user reading
the margin as "how strong my printed part will be" is over-optimistic by the
infill knockdown factor (order 2–10× depending on infill %/pattern/walls). This
is an intentional architecture choice (ARCHITECTURE §2), but it is **not
surfaced in a way that makes the solid assumption obvious**, and the reduction
ladder actively exploits the solid margin. **Confidence: High** (pure static
trace; no runtime needed).

**Proposed fixes (words, ranked):**
1. **Communicate the assumption at the point of the number.** Label the margin
   as "solid-print margin" and show the recommended infill's estimated knockdown
   next to it (even a coarse `margin × f(infill)` estimate). Cheapest, highest
   safety value.
2. **Gate the reduction ladder on an infill-adjusted margin.** Feed
   `margin.worst_case × k(infill_percent, pattern)` into the `margin_stop`
   acceptance ([minimize_plastic.cpp:270](core/src/simp/minimize_plastic.cpp:270))
   so the tool doesn't strip to 26 % on a margin the print won't deliver.
3. **(Heavy, explicitly out of scope per ARCHITECTURE §2)** homogenized-infill
   modulus in FEA. Not recommended given the product's stated non-goals.

---

## Item 2 — INTERNAL REPEATING FINS/RIDGES

**Most likely mechanism: mesh-dependence driven by a density-filter radius
expressed as a FIXED VOXEL COUNT that does not scale with physical part size.**

### Evidence

- The filter radius is set once, in **voxel units**, and is **not** a function
  of grid resolution or part dimension:
  [`enable_projection`](app/TopOptKit/Sources/TopOptBridge/bridge.cpp:114) sets
  `opts.simp.filter_radius = 2.5;` (default is 1.5,
  [simp.hpp:239](core/include/topopt/simp.hpp:239), comment: *"voxel units"*).
- It is consumed as a voxel radius:
  [`make_density_filter`](core/src/simp/simp.cpp:193) scans a
  `ceil(radius)` = 3-voxel neighborhood ([simp.cpp:218](core/src/simp/simp.cpp:218))
  and weights `radius − dist` in voxels ([simp.cpp:239](core/src/simp/simp.cpp:239)).
  Applied on the OC path via `filter_sensitivity`
  ([simp.cpp:310, 320](core/src/simp/simp.cpp:310)) and the masked path
  ([simp.cpp:1015](core/src/simp/simp.cpp:1015)).
- **No physical scaling anywhere** — no `spacing`/`mm` term touches the radius.
  So the **minimum member thickness is fixed at ~2.5–3 voxels regardless of
  resolution**. At 20³ that's ~12 % of the part; at 128³ it's ~2 %. Finer grids
  therefore resolve many more, much thinner members — the textbook
  *mesh-dependence* of density-based topopt, which reads as regular, repeating
  fins/ribs.

### Why the other two candidates are less likely

- **Classic checkerboarding (a):** a density filter with radius ≥ ~1.5 voxels
  suppresses 1-element checkerboarding at *any* grid size. With radius 2.5 the
  1-element instability is filtered, so pure checkerboarding is largely ruled
  out. (The visual "fins" are coarser than a 1-voxel checker.)
- **MC-on-gray artifact (b):** marching cubes runs at `kIso = 0.5`
  ([minimize_plastic.cpp:162](core/src/simp/minimize_plastic.cpp:162),
  [mesh.cpp:413](core/src/mesh/mesh.cpp:413)). The β → 32 Heaviside continuation
  drives densities toward 0/1, so few voxels sit near 0.5 at convergence; MC
  terracing is a secondary contributor at most, not the primary cause.
- **Real structure (c):** regular ribs *can* be a legitimate optimum for
  plate-bending BCs, so this cannot be excluded from code alone. The
  discriminator is runtime: **if feature count grows with resolution (20 → 64 →
  128) while feature thickness stays ~constant in voxels, it is mesh-dependence,
  not physics.**

**No deliberate periodicity constraint exists** (`grep period` finds only a
cylinder-topology comment).

**Proposed fixes (words, ranked):**
1. **Make the filter radius physical.** Derive it from a target minimum feature
   size in mm (e.g. `rmin_voxels = min_feature_mm / grid.spacing`) so the length
   scale is resolution-independent. This is the standard cure for
   mesh-dependence and directly removes the "more/thinner fins at 128³" effect.
2. **Confirm the mechanism first (runtime):** run the same part at 20/64/128 and
   check whether member count scales with resolution. Cheap, decisive.
3. If ribs are partly real, still cap minimum feature size physically so the
   result is manufacturable and stable across resolutions.

**Confidence: Medium-High** that a fixed-voxel radius is the origin; **the exact
visual (fins vs. terracing) needs one runtime resolution-sweep to confirm.**

---

## Item 3 — PLAYBACK "REVERTED TO SLICES"

**Mechanism (definitive from code): the "slices" is the reveal-scrub fallback,
selected precisely when the viewed variant has no keyframes.**

- The morph-vs-slice branch:
  [ResultsScreen.swift:151-153](app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift:151)
  ```swift
  private var showHistory: Bool { !model.stressOn && !flexActive && model.hasHistory }
  private var viewerMesh: ViewerMesh? { showHistory ? model.playbackMesh : model.selectedMesh }
  private var viewerReveal: Float { (showHistory || flexActive) ? 1 : Float(model.playT) }
  ```
  The code comment names it: *"reveal-scrub fallback for meshes without history"*
  ([ResultsScreen.swift:146](app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift:146)).
- **Morph** = `playbackMesh`, swapping keyframe meshes as `playT` scrubs
  ([ResultsModel.swift:481-484](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:481)).
- **Slices** = `selectedMesh` with `reveal = playT`; the fragment shader discards
  fragments above a model-Y plane
  ([MetalMeshView.swift:67-70](app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift:67)) —
  a bottom-to-top sweep that reads as layers/slices.
- The switch is `hasHistory`:
  [ResultsModel.swift:463](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:463)
  `!(selectedVariant?.keyframeMeshes.isEmpty ?? true)`. **Empty `keyframeMeshes`
  ⇒ `hasHistory` false ⇒ reveal/slices.**

### The keyframe pipeline is statically correct on every path

I traced it end-to-end and found no static break:
- Core captures ~12 keyframes per rung (all three `simp_optimize` overloads
  invoke the callback:
  [simp.cpp:758-762 / 789-791](core/src/simp/simp.cpp:758),
  [1090-1098 / 1126-1128](core/src/simp/simp.cpp:1090),
  [1686-1704](core/src/simp/simp.cpp:1686)); wired in
  [minimize_plastic.cpp:153-163](core/src/simp/minimize_plastic.cpp:153) with
  `keyframe_count = 12` set on **both** bridge entry points
  ([bridge.cpp:422](app/TopOptKit/Sources/TopOptBridge/bridge.cpp:422) and the
  load-case path [bridge.cpp:561](app/TopOptKit/Sources/TopOptBridge/bridge.cpp:561)).
- Bridge flattens them ([bridge.cpp:158-173](app/TopOptKit/Sources/TopOptBridge/bridge.cpp:158))
  on **both** the final ([`to_optimize_result`](app/TopOptKit/Sources/TopOptBridge/bridge.cpp:190))
  and streaming ([`set_variant_stream`](app/TopOptKit/Sources/TopOptBridge/bridge.cpp:205))
  paths — both call the same `to_optimize_variant`.
- Swift reconstructs them ([`reconstructKeyframes`](app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:413),
  called from `convertOutcome` at [TopOptKit.swift:458](app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:458)),
  used identically for streamed variants (`variantTrampoline` →
  `convertOutcome`, [TopOptKit.swift:305-308](app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:305)).
- Persisted round-trip is present ([OutcomeStore.swift:74, 106](app/TopOptKit/Sources/TopOptFlows/OutcomeStore.swift:74)).

**So there is no static wiring bug that empties keyframes.** The app view code
is byte-identical to the M7.viz.3 commit — `git log 3c5f78e..HEAD` shows only
**core + docs** changes since (M7.mma.2 + ROADMAP), **no `app/` changes** — so
this is not a regression introduced by PRs #47–#52 in the Swift layer.

### Why keyframes are nonetheless empty at runtime (candidates, ranked)

1. **Shared root with the 059 crash (most likely).** 059 pinned an
   EXC_BAD_ACCESS at 128³ reading a `vector<Vec3>` of *size 0 / invalid pointer*
   in `to_optimize_variant`; the heavy nested vectors on that path are exactly
   the **keyframe meshes** and the **displacement field**. A milder form of the
   same large-payload marshaling failure at 128³ would deliver a variant whose
   heavy arrays are truncated/empty rather than crashing — producing empty
   `keyframeMeshes` (this item) and empty `displacementField` (item 4).
2. **`finish()` masks a failed final result as success.**
   [RunModel.swift:487-491](app/TopOptKit/Sources/TopOptFlows/RunModel.swift:487):
   on a solver error mid-run, if any streamed accepted variant exists the app
   sets `phase = .succeeded` and shows the **streamed** outcome. So a 128³ crash
   of the *final* `to_optimize_result` looks like "succeeded with results,"
   quietly presenting streamed variants — consistent with "results present but
   degraded." (Streamed variants *should* also carry keyframes, so this alone
   isn't sufficient; it's the delivery mechanism that pairs with #1.)
3. **Stale linked core binary.** The app links the prebuilt
   `vendor/TopOptCore.xcframework` (dated Jul 11 07:00), not source. It post-dates
   M7.disp/keyframes, so it *should* include the wiring — but this is worth
   confirming, since a stale core would silently drop the arrays. `simp.cpp` and
   `minimize_plastic.cpp` are on disk newer than the built `.a`, so a rebuild is
   overdue regardless.

**Cannot be decided from code alone.** Runtime confirmation: log
`selectedVariant.keyframeMeshes.count` and whether the run entered
`finish()`'s `.failure → .succeeded` branch, at 128³ vs a small grid.

**Proposed fixes (words, ranked):**
1. Fix the underlying 128³ large-nested-vector marshaling defect (059) — likely
   resolves #3 and #4 together.
2. Make the fallback honest: when `hasHistory` is false because data was
   *expected but missing* (a 128³ run that should have keyframes), surface a
   "history unavailable" state rather than silently showing a Y-reveal that
   looks like a different feature.
3. Don't let `finish()` present a crashed final as a clean success without
   flagging that results are partial/streamed.

---

## Item 4 — MISSING FLEX / DEFLECTION ANIMATION

**Mechanism (definitive from code): the Flex control is gated by `hasFlex`,
which is false when the selected variant's `displacementField` is empty — the
same failure shape as #3.**

- Visibility gate: [ResultsScreen.swift:351](app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift:351)
  `if model.hasFlex { … Flex button … }`.
- [`hasFlex`](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:398):
  `guard let f = selectedDisplacementField else { return false }; return !f.isEmpty`,
  where `selectedDisplacementField` wraps `selectedVariant.displacementField`
  ([ResultsModel.swift:388-394](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:388)).
- The animation itself is **fully wired** (M7.viz.3): vertex-shader
  displacement `in.position + u.flex.x * disp[vid]`
  ([MetalMeshView.swift:56](app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift:56)),
  `FlexAnimation`/ticker in ResultsModel/ResultsScreen. Nothing downstream
  removed it (no `app/` changes since M7.viz.3).

### `displacementField` is populated & persisted on every path

- Core sets it unconditionally per accepted variant
  ([minimize_plastic.cpp:222-228](core/src/simp/minimize_plastic.cpp:222)).
- Bridge copies it ([bridge.cpp:156-157](app/TopOptKit/Sources/TopOptBridge/bridge.cpp:156)),
  Swift reads it ([TopOptKit.swift:457](app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:457)),
  and it's persisted (optional-for-legacy) at
  [OutcomeStore.swift:37, 73, 105](app/TopOptKit/Sources/TopOptFlows/OutcomeStore.swift:37).

So, as with #3, **there is no static reason the field is empty.** If it is empty
at runtime, it is the *same* large-payload delivery failure at 128³.

### #3 and #4 share a root cause — and likely with #1

- **#3 ↔ #4: yes, one root.** Both fire exactly when the viewed variant arrives
  with its heavy per-variant arrays empty (`keyframeMeshes` → slices;
  `displacementField` → no flex). They are two symptoms of one condition.
- **#1 ↔ (#3,#4): plausibly one regression.** The 128³ path that 059 fingered
  for the crash marshals precisely these heavy nested vectors. A crash and an
  empty-array delivery are two outcomes of the same untested large-payload
  boundary code (streaming `variantTrampoline`/`partialPtr.pointee`, and the
  by-value `OptimizeResult` return). This is a **hypothesis consistent with the
  static evidence, not proven by it.**

**Proposed fixes (words, ranked):**
1. Same as #3 fix 1 — resolve the 128³ marshaling defect; flex returns with the
   displacement field.
2. Runtime confirmation: log `selectedVariant.displacementField.count` at 128³
   vs a small grid; confirm whether it correlates with the crash path.
3. If the field is present but large-and-slow, that's a separate perf concern,
   not visibility — but rule it out before assuming emptiness.

---

## What needs runtime confirmation (cannot be settled from code)

1. **#3/#4 emptiness:** at 128³, log `keyframeMeshes.count` and
   `displacementField.count` on the variant the UI selects, and whether
   `finish()` took the `.failure → .succeeded` streamed branch
   ([RunModel.swift:487](app/TopOptKit/Sources/TopOptFlows/RunModel.swift:487)).
   If both are 0 on the crash path but non-zero at resolution 20/32, #1/#3/#4 are
   one regression.
2. **#2 mechanism:** resolution sweep (20 → 64 → 128) of the same part; measure
   whether member count scales with resolution (mesh-dependence) vs. stays fixed
   (real ribs).
3. **Stale core binary:** rebuild `vendor/TopOptCore.xcframework` from current
   `core/` and re-run; confirms the linked binary isn't silently older than the
   keyframe/displacement wiring.
4. **#1 is the exception — it needs no runtime:** the solid-modulus margin and
   the one-way margin→infill direction are proven by static trace.

## One-line answers

- **#1:** Yes — FEA is solid-modulus; the margin does **not** account for infill;
  optimistic by the infill knockdown (order 2–10×). Safety-relevant.
- **#2:** Fixed-*voxel* filter radius (2.5, [bridge.cpp:114](app/TopOptKit/Sources/TopOptBridge/bridge.cpp:114))
  → mesh-dependent thin-member proliferation at 128³; not checkerboarding.
- **#3:** Reveal-scrub fallback fires because `keyframeMeshes` is empty at
  runtime; pipeline is statically correct → runtime data loss on the 128³ path.
- **#4:** `hasFlex` false because `displacementField` is empty at runtime; same
  root as #3, plausibly the same 128³ large-payload failure as the 059 crash.
