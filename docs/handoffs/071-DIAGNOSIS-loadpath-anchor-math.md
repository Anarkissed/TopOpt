# Diagnosis 071 — Load→anchor load-path: the math & the data it needs

**Track:** diagnostic (READ-ONLY). No source/test/ROADMAP/fixture file was modified.
No code changed, no PR opened, no box checked. The only file written is this report.
Worktree `.claude/worktrees/loadpath-anchor-math-diagnosis-789c89`.

**Question:** for the **second mode** of the redesigned load-path viz — trace curves
showing how force flows from each **LOAD** location, through the body, to the
**ANCHOR** locations (the actual route to ground) — determine (1) the correct math,
(2) what data it needs and whether that data exists or needs a new `/core/` field,
(3) how anchors are targeted, (4) whether it is an app task or app+core, and cost.

This is DIFFERENT from the stress-point mode (which follows the principal-stress
direction to the peak-stress hot-spot). Load→anchor answers "what path does force
take to reach the supports."

---

## TL;DR

| # | Finding | Confidence |
|---|---------|-----------|
| 1 | **Recommended math = streamlines of the stress-flux field `F(x) = σ(x)·d̂`** (σ = Cauchy stress tensor, d̂ = the load's unit direction). In equilibrium `∇·σ = 0`, so `∇·F = 0` in the interior and the field's only source/sink are the applied load (source) and the reactions at the anchors (sink) — so its streamlines **provably leave the load and arrive at the anchors**. That termination guarantee is exactly what a bare principal-stress trajectory lacks, and it is what makes this "route to ground" rather than "follow the biggest stress." | High |
| 2 | **The full per-voxel stress tensor is the one field this needs, and it is ALREADY computed in `/core/` and then thrown away.** `minimize_plastic.cpp` fills `std::vector<std::array<double,6>> stress` (Voigt `[xx,yy,zz,xy,yz,zx]`, true shear) from `hex8_stress(...).sigma`, uses it for interlayer tension + von Mises, and discards it — only the von Mises **scalar** is retained/exposed. Exposing the tensor is a **small, well-scoped core+bridge task** that mirrors the existing `von_mises_field` plumbing 1:1. | High |
| 3 | **A no-core v1 is possible** by reconstructing σ app-side: `σ = C : ε(u)` from the displacement field viz.4 already differentiates, with the material's `C` (E, ν, z-knockdown are known app-side). Same flux math, no `/core/` change — cost is finite-difference gradient accuracy + having to replicate core's constitutive matrix. | High |
| 4 | **Anchors are fully known app-side** (declared `.anchor` selection groups → B-rep faces → `ViewerMesh.faceCentroid`/`faceNormal`, in the same model frame as the grid/stress/displacement). They are **not currently plumbed into `ResultsScreen`** — the constructor takes only the outcome + material/load scalars — but the data sits in `ProjectModel`, in scope at the results presentation site. Termination test: rasterize anchor faces to a voxel set, stop when a trace enters it. | High |
| 5 | **Cost = precompute-once per variant, not per-frame** (identical to viz.4 glyphs / the stress-point polyline): integrate a handful of streamlines when the overlay turns on or the variant changes, cache the polylines, animate a traveling dash over them per frame. Integration is a few hundred RK4 steps × a few paths — trivial. | High |

**Bottom line:** the correct-and-cheap approach is **flux streamlines of `σ·d̂`**, and
the right data source is **the tensor core already computes and discards**. Best plan
= a tiny core+bridge field task (expose the tensor) + an app streamline integrator
that reuses the stress-point mode's machinery. A **no-core v1** (app reconstructs σ
from displacement) is available if core work must be deferred.

---

## 1 — The math: which approach is physically correct for "route to ground"

The brief lists three candidate families. Evaluated against what the solver produces:

### (A) Principal-stress trajectories / stress-flow lines — *what the stress-point mode does*
Integrate a streamline tangent to a principal-stress **direction** field. This is the
classic structural "flow of forces" picture (strut-and-tie / Michell layouts derive
from principal directions), and it is what viz.4 + the stress-point mode already build:
[`LoadPath.swift`](../../app/TopOptKit/Sources/TopOptFlows/LoadPath.swift) derives one
dominant principal-stress axis per voxel from `ε = ½(∇u+∇uᵀ)` and colours it by von
Mises.

**Why it is not sufficient for load→anchor on its own:** a principal-stress trajectory
is a field line of an **eigenvector** field. It has no built-in reason to terminate at
a support — in 3D it can spiral, run into a free surface, or become undefined at
*isotropic points* (where two principal values coincide and the direction degenerates).
There are also three families (major/intermediate/minor); "route to ground" generally
uses **compression struts** (most-negative principal) and **tension ties** (most-positive)
and force can hand off between them. So to make (A) reach an anchor you must **steer** it
(bias the direction choice toward the anchor) — a heuristic, not a physical guarantee.
Good enough for a cheap v1; not the physically honest "load path to ground."

### (B) Force-flux / load-path density (U\* field, stiffness-based transfer)
The U\* method (Hoshino–Ueda) builds a scalar field whose gradient traces load paths
that *do* connect the load to the supports by construction. But U\* requires an **extra
analysis per load point** (a fictitious constraint/adjoint at each interior point using
the global stiffness). Nothing in the current pipeline produces it, and it is **not
cheaply derivable** from the discarded fields. Physically strong, but the most expensive
option and a poor fit for "cheapest derivable from what the solver already computes."

### (C) Streamlines of the internal force-flux from the stress tensor — **RECOMMENDED**
Define the vector field

```
F(x) = σ(x) · d̂
```

where `σ` is the per-voxel Cauchy stress tensor and `d̂` is the **applied load's unit
direction** (per path: the direction of that specific load group). `F` is the traction
transmitted across a plane whose normal is d̂ — i.e. the flux of the applied force
through the material.

The physics that makes this the correct "route to ground":

- **Equilibrium ⇒ solenoidal.** With no body force, `∇·σ = 0` (each row of σ is a
  divergence-free momentum-flux field). Hence `∇·F = d̂·(∇·σ) = 0` in the interior.
- **Sources/sinks are exactly the external tractions.** A divergence-free field's
  streamlines cannot start or stop in the interior — they can only begin/end where the
  field has a source or sink, which is where external tractions act: **+ at the load,
  − at the reactions (anchors).** So streamlines of `F` **leave the loaded region and
  arrive at the anchors** — the termination guarantee (A) lacks.
- **Self-weight case:** if the run fell back to self-weight (a real failure mode per
  [Diagnosis 064](064-DIAGNOSIS-anchor-eaten-and-zero-stress.md)), the body force is
  non-zero and F is no longer perfectly solenoidal — the streamlines then diffuse rather
  than converge cleanly. That is *correct* behaviour (distributed load has no single
  path) and also a useful tell. For the normal traction path it converges.

Colour/annotation falls out of the same tensor: the sign of the normal component
`n·σ·n` along the path distinguishes **compression struts** (−) from **tension ties**
(+), which is the structural story the mode wants to tell.

**Recommendation:** implement **(C)** — flux streamlines of `σ·d̂` — seeded at each load
and integrated until they reach an anchor voxel. It is the physically correct
"route to ground," and (finding 2) it is the cheapest correct option because the tensor
it needs is already computed by the solver. Keep **(A)-with-anchor-bias** as the no-tensor
fallback (it reuses the stress-point integrator verbatim).

---

## 2 — Data: available vs missing

### Available to the app RIGHT NOW
| Field | Type | Size | Source |
|---|---|---|---|
| von Mises scalar | [`StressField`](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:49) | `nx·ny·nz` floats | `OptimizeVariant.vonMisesField` |
| Nodal displacement | [`DisplacementField`](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:109) | `3·(nx+1)(ny+1)(nz+1)` floats | `OptimizeVariant.displacementField` |
| Principal-stress **directions** | derived (viz.4) | ~260 glyphs | `LoadPathField.build` from displacement→strain→eigenvectors |
| Grid geometry | `gridOrigin`, `spacing`, `nx/ny/nz` | — | `OptimizeOutcome` |
| Material constitutive constants | `Material` (E, ν, z-knockdown) | — | materials.json, already used app-side (`AppModel.yieldStrengthMPa(for:)`) |
| Anchor face centroids/normals | `ViewerMesh.faceCentroid`/`faceNormal` + `SelectionModel` + `ForceModel` | — | `ProjectModel` (see §3) |

### MISSING for the recommended (flux) approach
**The full per-voxel Cauchy stress tensor field.** 6 components per voxel, Voigt order
`[σxx, σyy, σzz, σxy, σyz, σzx]` with true (not doubled) shear — the layout of
`Hex8Stress.sigma` ([`fea.hpp:69-74`](../../core/include/topopt/fea.hpp:69)).

**It is already computed in core and discarded.** In the stress-recovery block of
`minimize_plastic`:

- [`minimize_plastic.cpp:323`](../../core/src/simp/minimize_plastic.cpp:323) allocates
  `std::vector<std::array<double,6>> stress(G.voxel_count())`.
- [`:342-344`](../../core/src/simp/minimize_plastic.cpp:342) fills it per printed voxel
  from `hex8_stress(...).sigma`.
- [`:345`](../../core/src/simp/minimize_plastic.cpp:345) derives the von Mises scalar
  from that same tensor and stores **only the scalar** on the variant
  (`variant.von_mises_field`).
- [`:348`](../../core/src/simp/minimize_plastic.cpp:348) uses the tensor once more for
  `max_interlayer_tension`, then the `stress` array **goes out of scope**.

So the tensor costs *nothing new to compute* — it is thrown away at the end of a block
that already has it in hand.

### Exposing the tensor — the exact, well-scoped core+bridge task
Mirror the `von_mises_field` plumbing 1:1 (name the tensor `stress_tensor_field`):

1. **core** — add to `VariantResult`
   ([`pipeline.hpp:287`](../../core/include/topopt/pipeline.hpp:287), beside
   `von_mises_field`): `std::vector<double> stress_tensor_field;` (size
   `6 * grid.voxel_count()`, Voigt, zero off the printed set — same gating as
   `von_mises_field`). Fill it from the already-existing `stress` array at
   [`minimize_plastic.cpp:344`](../../core/src/simp/minimize_plastic.cpp:344) instead of
   discarding it (one `.assign`/flatten). Empty for a cancelled rung.
2. **bridge** — copy it into a new `OptimizeVariant.stress_tensor_field`, mirroring
   [`bridge.cpp:202`](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:202)
   (`ov.von_mises_field.assign(...)`).
3. **app (TopOptKit)** — add `stressTensorField: [Float]` to `OptimizeVariant`
   ([`TopOptKit.swift:95`](../../app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:95)) and
   map it in `convertOutcome`
   ([`TopOptKit.swift:494`](../../app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:494),
   `Array(v.stress_tensor_field)`), then wrap it in a `StressTensorField` value type
   analogous to `StressField` (nearest-voxel `tensor(at:)` → a `simd_float3x3`).

**Size:** 6× the von Mises field. Example 60×40×40 grid ≈ 96k voxels → ~576k floats
≈ 2.3 MB per accepted variant, streamed exactly like `vonMisesField`/`displacementField`.
Modest; the displacement field is already the same order of magnitude.

### No-core alternative: reconstruct σ app-side
The app can build the tensor without a core change:
`σ = C : ε(u)`, where `ε(u)` is the strain viz.4 already computes
([`LoadPath.strainTensor`](../../app/TopOptKit/Sources/TopOptFlows/LoadPath.swift:252))
and `C` is the material constitutive matrix from `Material` (E, ν, and the transverse-
isotropic z-knockdown — all app-side). This yields the same `F = σ·d̂` flux math with
**no `/core/` work**, at the cost of two caveats: (i) the finite-difference displacement
gradient is a discrete estimate, not the element-integrated tensor core produces, and
(ii) the app must replicate core's constitutive matrix exactly (including the z-knockdown
transverse-isotropy at [`hex_element.cpp:133-158`](../../core/src/fea/hex_element.cpp:133))
to match. The core-exposed tensor removes both.

**Three data tiers, then:**
1. **Existing directions** (viz.4) — cheapest, no new data, but direction-field only (approach A).
2. **App-reconstructed tensor** `σ=C:ε(u)` — no core change, enables flux math (C), FD + constitutive caveats.
3. **Core-exposed tensor** — exact, tiny core+bridge task, removes both caveats. **Recommended.**

---

## 3 — Anchor targeting

### How the app knows anchors
Anchors are selection groups the user declared `.anchor`
([`ForceModel.makeAnchor`](../../app/TopOptKit/Sources/TopOptFlows/ForceModel.swift:163)).
Each group is a set of B-rep face IDs
([`SelectionGroup.faces`](../../app/TopOptKit/Sources/TopOptFlows/SelectionModel.swift:47)),
and the viewer mesh resolves each face to geometry:
- **`ViewerMesh.faceCentroid(faceID)`**
  ([`ViewerMesh.swift:274`](../../app/TopOptKit/Sources/TopOptFlows/ViewerMesh.swift:274))
  — model-space centroid of a B-rep face (already feeds arrow/overlay placement).
- **`ViewerMesh.faceNormal(faceID)`**
  ([`ViewerMesh.swift:246`](../../app/TopOptKit/Sources/TopOptFlows/ViewerMesh.swift:246))
  — outward normal (seed a start point just inside the surface).

The same pattern `ProjectModel.loadCase()` uses to hand anchors/loads to the solver
([`ProjectModel.swift:143-161`](../../app/TopOptKit/Sources/TopOptFlows/ProjectModel.swift:143))
— so the load **seed points** (load-group face centroids + their force directions d̂) and
the anchor **target set** come from the same source, in the same model frame.

**Frame check:** `faceCentroid` is model-space; the outcome grid (`gridOrigin`, `spacing`),
the stress field's `value(at:)`, the displacement field, and viz.4's glyph positions are
all in that same model mm frame. Anchor centroids are therefore directly comparable to the
grid — no transform needed. (The renderer applies a view matrix on top, but the underlying
data is one consistent model frame.)

### The plumbing gap
`ResultsScreen`'s constructor takes only `projectName, outcome, material…, appliedLoadKg,
loadUnit, infill…` ([`ResultsScreen.swift:51-68`](../../app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift:51))
— **no selection/anchor/imported-mesh data.** But it is presented from
[`WorkspacePlaceholder.swift:138`](../../app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift:138),
where `project` (`ProjectModel`: `selection`, `force`, `viewerMesh`) is in scope. So the
load→anchor mode needs a **small plumbing addition**: pass the load seed points (centroid +
d̂ per load group) and the anchor target set (anchor face IDs or their voxelised set) into
`ResultsScreen`/`ResultsModel`. No new geometry computation — it is all already derivable
there.

### How a trace "arrives"
Build an **anchor voxel set** once: rasterize each anchor face's triangles into grid
voxel indices (or flag every voxel within ~1 spacing of an anchor `faceCentroid`). A
streamline **arrives** when it steps into an anchor voxel; stop and mark it a completed
load→anchor path. Guard rails: stop also if the trace leaves the printed material
(`StressField.value(at:) ≤ 0`, the same printed-gate viz.4 uses at
[`LoadPath.swift:210`](../../app/TopOptKit/Sources/TopOptFlows/LoadPath.swift:210)) or
exceeds a max length (prevents a spiral from running forever — relevant only for the
approach-A fallback; the flux field converges by construction).

*Optional core assist:* the bridge already tags **Fixture voxels**
(per [Diagnosis 064](064-DIAGNOSIS-anchor-eaten-and-zero-stress.md), `bridge.cpp`), so core
could alternatively expose the Fixture voxel mask as the exact anchor set. Not required —
the app can reconstruct it from the face geometry it already holds — but it would be the
most faithful target and removes any app/core rasterization mismatch.

---

## 4 — Feasibility & cost, and the ranking

### App task or app+core?
- **Recommended (flux streamlines + core-exposed tensor):** **app + a small core field
  task.** The core/bridge task is well-scoped (expose a field that is already computed;
  1:1 with `von_mises_field`). Everything else — the integrator, anchor set, rendering —
  is app-side.
- **No-core v1 (flux streamlines + app-reconstructed σ):** **app only.** Reuses viz.4's
  strain machinery + a constitutive multiply + the new integrator.
- **Cheapest fallback (principal-direction + anchor bias):** **app only.** Reuses the
  stress-point integrator verbatim, retargeted from the hot-spot to the anchor set.

### Per-frame or precompute?
**Precompute-once per variant**, exactly like the existing overlays:
- The streamlines are static polylines (like viz.4 glyphs / the stress-point polyline).
  Integrate them when the overlay turns on or the selected variant changes, and **cache**
  them — mirror the existing `loadPathSegmentCache`/`loadPathCache` invalidation in
  [`ResultsModel.apply`](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:542).
- Per frame, only the traveling-dash animation runs over the cached polylines — identical
  to the current load-path/stress-point render path.
- Integration cost is negligible: a few load seeds × (optionally a small seed fan) ×
  a few hundred RK4 steps, each step a nearest-voxel tensor lookup + a 3×3 matrix-vector
  product. Sub-millisecond; dwarfed by the mesh upload.

### Ranking by (correctness × cheapness)
1. **Flux streamlines `σ·d̂`, tensor exposed from core (Tier 3 data + approach C).**
   Physically correct route-to-ground (sinks at anchors), exact tensor is *free* to
   expose, precompute-once. **Best overall** — the small core task buys both correctness
   and the removal of viz.4's isotropy/FD caveats. **Recommended.**
2. **Flux streamlines `σ·d̂`, tensor reconstructed app-side (Tier 2 + approach C).**
   Same correct math, **no core change** — the strong v1 if core work must wait. Caveats:
   FD-gradient accuracy + must replicate core's constitutive matrix (z-knockdown).
3. **Principal-direction trajectory + anchor-seeking bias (Tier 1 + approach A).**
   Cheapest, zero new data (reuses the stress-point mode as-is), but "route to ground" is
   heuristic — a bare principal trajectory has no termination guarantee, so the bias is a
   presentation choice, not physics. Acceptable as a first visual; be honest on-screen
   that it is steered.
4. **U\* / load-path-density (approach B).** Physically strong but needs extra per-load
   analyses using the global stiffness — not derivable from the retained fields, most
   expensive. **Not recommended** given (C) achieves route-to-ground far more cheaply.

---

## Recommended spec for the implementation task

- **Math:** streamlines of `F(x) = σ(x)·d̂`, seeded at each load group's face centroid in
  its force direction d̂, integrated (RK4, step ≈ ½ voxel) until the trace enters the
  anchor voxel set or leaves the printed material. Colour/annotate by `sign(n·σ·n)` for
  compression-vs-tension. One polyline per (load seed → anchor) path.
- **Data:** expose the **per-voxel stress tensor** from core (`stress_tensor_field`,
  6·voxel_count, Voigt `[xx,yy,zz,xy,yz,zx]`) — it is already computed at
  `minimize_plastic.cpp:344` and discarded; plumb it 1:1 with `von_mises_field` through
  `VariantResult` → bridge → `OptimizeVariant` → a `StressTensorField` app value type.
  *(No-core v1: reconstruct `σ = C:ε(u)` app-side from the displacement field + material
  constants, stated caveats.)*
- **Anchors:** pass the load seeds (centroid + d̂) and anchor target set (anchor face IDs
  or voxelised anchors) from `ProjectModel` into `ResultsScreen`/`ResultsModel` (the data
  is in scope at `WorkspacePlaceholder.swift:138`; only plumbing is missing). Arrival =
  trace enters an anchor voxel.
- **Cost:** precompute-once per variant, cache the polylines (mirror
  `loadPathSegmentCache`); per-frame cost is only the traveling-dash animation. Integration
  is sub-millisecond.
- **Split:** one small **core+bridge field task** (expose the tensor) + one **app task**
  (integrator + anchor plumbing + render). The app task can ship a no-core v1 first
  (Tier 2) and swap to the exact tensor when the core field lands.

## What could NOT be determined from code alone
- Whether, for a given part, approach-A trajectories happen to reach the anchors without
  bias (geometry-dependent; needs the actual solved field). This is *why* (C) is
  recommended — it does not depend on luck.
- The exact anchor-voxel arrival tolerance (≈1 voxel is the natural default; tune on a real
  part such as the l-bracket, as the redesign prototype
  [Handoff 070](070-loadpath-redesign-prototype.md) did for feel).
