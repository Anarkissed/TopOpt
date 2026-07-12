# Diagnosis 059 — load-case crash + near-zero stress + arbitrary removal

**Track:** diagnostic (READ-ONLY). No source/test/ROADMAP/DECISIONS/fixture file
was modified. No code changed, no PR opened, no box checked. The only file
written is this report.

**Repro under investigation:** "I bracket large", ASA (yield 40 MPa), Fine 128,
anchors = back face + screw holes, load = 100 lb on the top face, minimize
plastic. Reproduces on both a reloaded and a freshly-created project (⇒ not a
persistence bug).

---

## TL;DR — cause vs. effect

| # | Symptom | Verdict | Confidence |
|---|---------|---------|-----------|
| 1 | **Crash** (EXC_BAD_ACCESS on `app.topopt.optimize`, in the C++ result conversion) | **A real, independent bug.** Memory-safety / Swift⇄C++ interop issue on the Fine-128 + ladder + streaming + large-payload path that **no test exercises.** Static analysis finds **no dangling in the core objects**, so I cannot pin it to an exact line without runtime instrumentation. | Medium (that it's real & in this path) / Low (exact line) |
| 2 | **Near-zero stress** (~2 MPa = 5% of yield; "barely moved 45→100 lb") | **Downstream effect, most likely CORRECT PHYSICS**, not a dropped load. 100 lb ≈ 445 N distributed over a large part genuinely yields single-digit MPa. The "load never arrives" primary hypothesis is **not supported by the code** (full trace below shows the load is delivered). | High (load is wired) / Medium (physics vs. a magnitude bug) |
| 3 | **Arbitrary material removal** | **Downstream effect of #2.** Low stress ⇒ huge margin (≈20×) ⇒ the reduction ladder accepts its *lightest* rung (0.26 VF) ⇒ ~74% removed. The optimizer is behaving correctly on a lightly-loaded part; the result *looks* incoherent. | High |

**Do #2 and #3 share one root cause?** Yes: low computed von Mises → huge
strength margin → the ladder walks to its lightest rung. **Is #1 the same root
cause?** No — the crash is a separate memory/interop defect; it does not depend
on the load magnitude.

**The most important correction to the working hypothesis:** the brief assumed
the load is being *dropped or zeroed* on the way to the solver. Tracing the
`vector<Vec3>`/force end-to-end shows it is **not** — the user's anchors and the
100 lb force are assembled, cross the bridge, and reach `traction_loads` →
`external_loads` at full magnitude. So the optimizer is **not** "behaving
correctly on an empty problem." It is behaving correctly on a **real but
lightly-stressed** problem. Chasing an empty-vector bug for #2/#3 will likely
dead-end; the real questions are (a) is the crash a lifetime/interop bug, and
(b) is single-digit-MPa physically right for this part (very possibly yes).

---

## Symptom 2 — the load DOES reach the solver (end-to-end trace)

I traced the load case from the UI selection to the core RHS. Every hop carries
the force forward; none empties or rescales it.

1. **UI → force vector (model frame).**
   [`ForceModel.loadForceVectorModel`](../../app/TopOptKit/Sources/TopOptFlows/ForceModel.swift:248)
   For a `.gravity` load: `raw = gravity` (the tapped floor normal, unit),
   `force = normalize(raw) * forceNewtons(kg)`, where
   [`forceNewtons`](../../app/TopOptKit/Sources/TopOptFlows/ForceModel.swift:231)
   `= kg * 9.80665`. 100 lb = 45.36 kgf → **≈ 445 N**. Non-zero, returned
   non-nil (guarded only on `len > 1e-6`, satisfied by a set gravity).

2. **Assembly into the request.**
   [`ProjectModel.loadCase()`](../../app/TopOptKit/Sources/TopOptFlows/ProjectModel.swift:114)
   iterates `selection.groups`; anchor groups → `anchorFaceIDs`, load groups →
   `LoadGroupSpec(faceIDs, force)`. The load group is included whenever
   `force.kind(for:).isLoad` — which is exactly the state the Optimize button
   gates on (`canOptimize` disables the run while any group is `.pending`,
   [ForceModel.swift:301](../../app/TopOptKit/Sources/TopOptFlows/ForceModel.swift:301)).

3. **Into the C++ `BridgeLoadCase`.**
   [`TopOptKit.minimizePlasticLoadCase`](../../app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:381)
   `push_back`s each face id, group size, and `(fx,fy,fz)` into the scalar
   vectors. Non-empty for the repro.

4. **Bridge assembles tractions.**
   [`run_minimize_plastic_loadcase`](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:467)
   loops groups: zero-force groups are skipped (bridge.cpp:481), otherwise it
   tags the group's faces `Load` on a clean anchors-only grid copy and calls
   [`traction_loads`](../../core/src/fea/assembly.cpp:157), appending to
   `external`. `traction_loads` distributes `total_force` over the tagged
   region's exposed faces and — per the core test — the emitted nodal loads
   **sum exactly to the applied force** (assembly.cpp:177-204; asserted in
   `test_minimize_plastic.cpp:824`). No unit conversion is applied, and none is
   needed: external loads are already in N, consistent with E in MPa and lengths
   in mm. (Contrast self-weight, which *does* pre-scale g/cm³→t/mm³ at
   bridge.cpp:417 — that scaling is correctly **absent** on the external path.)

5. **Into the solver RHS.**
   [`minimize_plastic`](../../core/src/simp/minimize_plastic.cpp:94) picks
   `external_loads` when non-empty (else self-weight), and passes it as `loads`
   to `simp_optimize` (minimize_plastic.cpp:166) and the final
   `simp_compliance` (minimize_plastic.cpp:183). Stress is recovered from that
   same solve (minimize_plastic.cpp:187-215).

**Conclusion:** the 100 lb load reaches the solver at full magnitude. The
`vector<Vec3>`/force is not dropped or zeroed on this path.

### Why the stress is nonetheless ~2 MPa (most likely correct)

- Stress ≈ F / A. 445 N over a "large" bracket's load-bearing section (order
  10³ mm²) gives a **nominal sub-MPa**, peaking to ~2 MPa at a concentration —
  exactly what was observed. For ASA (yield 40 MPa) that is a ~20× margin.
- "**Changing 45 → 100 lb barely moved the stress**" is the brief's main
  evidence for a dropped load. But a *dropped* load (self-weight fallback) would
  give **identical** stress at 45 and 100 lb (zero change), not "barely moved."
  A ~2.2× change that both stay deep-blue on a 0–40 MPa scale is exactly what a
  **delivered, linearly-scaling** load looks like far below yield. So this
  evidence actually points **toward** the load reaching, not away.

### The one runtime path that WOULD empty the load (rule it out with a log)

`external` ends up empty only if, for **every** load group, either the force is
zero (bridge.cpp:481) or none of its faces tag a solid voxel (`any == false`,
bridge.cpp:488). Then minimize_plastic silently falls back to self-weight
(minimize_plastic.cpp:94-98) and #2/#3 would follow from that instead. Static
analysis does not show this happening for the repro (the top face is on the
surface, so its voxels are solid and `tag_step_face` tags them), but it is the
one thing worth **confirming at runtime** rather than assuming — see
Instrumentation below. Note `tag_step_face` is called on the same re-imported
`StepModel`, so B-rep face ids are resolution-independent and stay valid at 128.

---

## Symptom 3 — arbitrary removal is the tail of Symptom 2

- Anchor and load surfaces are **not** what's being removed: `effective_mask`
  forces every `Load` and `Fixture` voxel to `FrozenSolid`
  ([simp.cpp:803-819](../../core/src/simp/simp.cpp:803)), so those one-voxel
  slabs are pinned. Only the **Active bulk** between them is a design variable.
- With a ~20× margin, **every** rung of the recommendation ladder
  `{0.68, 0.52, 0.38, 0.26}` ([`reduction_ladder`](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:104))
  clears `margin_stop = 1.5`, so the driver never stops early
  (minimize_plastic.cpp:270-282) and surfaces the **0.26** rung as the
  recommendation. ~74% of the bulk is removed, leaving thin/diffuse structure
  with the pinned surface patches "floating" — reads as "no coherent load path,"
  but it is the optimizer correctly exploiting a lightly-loaded part.
- **This is the real product bug in #2/#3**, if any: the ladder over-removes
  when the load is genuinely small, and there is no floor that keeps a visibly
  coherent structure. That is a *design/recommendation* issue, not a dropped
  load. (Proposed remedies below.)

---

## Symptom 1 — the crash

**Where it surfaces:** the C++ result conversion,
[`to_optimize_variant`](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:120),
reading a `std::vector<topopt::Vec3>` shown as size 0 with an invalid pointer.
The first `vector<Vec3>` read there is the variant mesh's vertices
([bridge.cpp:140-142](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:140),
`vm = v.mesh()` → `v.v3.mesh`); `keyframe_meshes[*].vertices` (bridge.cpp:159)
is the other. (`von_mises_field` / `displacement_field` are `vector<double>`, so
they are not the vector in question.) This conversion is reached two ways:
- the **final** result build,
  [`to_optimize_result`](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:190)
  iterating `mp.evaluated`; and
- the **streaming** callback,
  [`set_variant_stream`](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:205),
  packaging `result.evaluated.back()` into a stack `OptimizeResult one` and
  handing `&one` to Swift's `variantTrampoline`
  ([TopOptKit.swift:305](../../app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:305)).

**What I ruled out (static analysis):**
- **No dangling core object.** In both paths `v` is a live
  `MinimizePlasticVariant`; `mesh()` returns a reference to its own `v3.mesh`
  member (pipeline.hpp:193). For accepted and rejected-but-evaluated rungs
  `v3.mesh` is populated by `check_v3`; for a cancelled rung it is a *valid
  empty* vector (size 0, **valid** pointer), which is not the reported failure
  (size 0, **invalid** pointer ⇒ garbage read, i.e. corruption or a bad address).
- **No lifetime bug in the `&grid` capture** of `set_variant_stream`: `grid` is
  the caller's local in `run_minimize_plastic_loadcase`, alive across the
  synchronous `minimize_plastic` call.
- **No deep recursion / stack overflow** in mesh connectivity: `triangle_components`
  uses iterative union-find ([mesh.cpp:469-495](../../core/src/mesh/mesh.cpp:469)).
- **OOM is not this signature:** a `std::bad_alloc` is caught (bridge.cpp:573)
  and an iOS Jetsam kill is SIGKILL/EXC_RESOURCE, not EXC_BAD_ACCESS.

**Why it shows up here and not in tests:** the only end-to-end exercise of this
bridge path,
[`testMinimizePlasticLoadCaseUsesDeclaredForces`](../../app/TopOptKit/Tests/TopOptKitTests/TopOptKitTests.swift:251),
runs at **resolution 20**, `minimizePlastic: false` (a **single** {0.9} variant,
not the ladder), **no** `onVariant` streaming, and never asserts stress
magnitude. The repro adds all of the untested load: **128³**, the **4-rung
ladder** (multiple accepted variants), **streaming on**, and, per variant, a
displacement field (~51 MB at 129³), a von Mises field (~16 MB), the variant
mesh, and **12 keyframe meshes** — each large payload marshaled across the
Swift⇄C++ boundary on the optimize thread. `enable_projection` + `keyframe_count = 12`
are set unconditionally in the bridge (bridge.cpp:560-561), so they *are* in the
tested path, but never at 128³, never with the ladder, never streamed.

**Leading candidates (ranked):**
1. A **Swift⇄C++ interop lifetime/marshaling defect** handling the large
   streamed/returned `OptimizeResult` (nested `std::vector`s) — e.g. the
   `partialPtr.pointee` view in `variantTrampoline`, or the by-value return of a
   multi-hundred-MB `OptimizeResult`. Fits "surfaces in the conversion, at scale,
   on this path only."
2. An **out-of-bounds heap write at 128³** somewhere in the per-variant analysis
   or flattening that corrupts an adjacent variant's mesh vector, read later in
   `to_optimize_variant`.

I am **not** confident which, and I will not assert a line. Both are confirmable
cheaply (below).

---

## Confidence-ranked findings

1. **(High)** The user's load is delivered to the solver at full magnitude; the
   "dropped/zeroed load" hypothesis for #2/#3 is refuted by the trace.
2. **(High)** #2 and #3 share one root: low computed stress → ~20× margin → the
   ladder recommends its lightest rung → aggressive removal. #3 is the tail of #2.
3. **(High)** The crash (#1) is independent of the load magnitude and lives on
   the untested Fine-128 + ladder + streaming + large-payload path.
4. **(Medium)** The ~2 MPa is most likely correct physics for 445 N over a large
   part; a genuine magnitude/units error is possible but unevidenced.
5. **(Low/Medium)** The crash is a Swift⇄C++ interop lifetime issue rather than a
   core OOB — leaning on "no core dangling found, surfaces only at interop scale."

---

## Proposed fixes (in words — NOT applied this run)

- **Crash (#1), first:** run the repro under **AddressSanitizer** on the macOS
  package with a 128³ STEP + the ladder + a streaming callback; that will name
  the exact bad read/write in one shot. Independently, add a **regression test**
  that runs `minimizePlasticLoadCase` at a higher resolution *with the ladder
  (`minimizePlastic: true`) and a non-nil `onVariant`* — the current test misses
  all three. If ASan implicates the streamed `&one` marshaling, the fix is to
  make the streaming/return path hand Swift owned copies (or shrink what crosses:
  the 12 keyframe meshes per variant at 128³ are the dominant payload and the
  most likely straw). Confirm whether the crash still repros with
  `keyframe_count = 0` to localize.
- **Near-zero stress (#2):** first **confirm it's physics, not a dropped load**,
  with the log below. If the load is arriving (expected), this is not a bug —
  document the expected magnitude and, if desired, add a von-Mises **magnitude**
  assertion to the load-case test (e.g. stress scales ~linearly with force) so a
  future real magnitude/units regression is caught. If the log shows `external`
  empty, fix the specific tag/force path that emptied it (and surface a warning
  rather than silently falling back to self-weight at minimize_plastic.cpp:94).
- **Arbitrary removal (#3):** treat as a recommendation-quality issue, not a
  dropped load. Options: cap how far the ladder walks when the margin is very
  large (don't recommend 0.26 VF at 20× margin), and/or clamp the lightest rung
  so a minimum coherent structure remains. This is a maintainer product call, not
  a mechanical fix.

## Where a targeted log/assertion (added later) would confirm the diagnosis

- **Empty-load check (settles #2 vs. self-weight fallback):** in
  `run_minimize_plastic_loadcase` after the group loop
  ([bridge.cpp:496](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:496)),
  log `external.size()` and `Σ|external.value|`. Non-empty with a summed
  magnitude ≈ 445 N ⇒ load is delivered (physics is the story). Zero ⇒ a real
  tag/force bug to chase.
- **Crash localization:** ASan as above; plus a temporary log of
  `v.v3.mesh.vertices.size()` / `v.keyframe_meshes.size()` at the top of
  `to_optimize_variant` to see whether the object is already garbage on entry
  (corruption upstream) vs. becomes bad mid-read (marshaling).
- **Margin/removal check (confirms #3 is the tail of #2):** log each rung's
  `margin.worst_case` and `requested_volume_fraction` at
  [minimize_plastic.cpp:270](../../core/src/simp/minimize_plastic.cpp:270). A
  ~20× worst-case margin on every rung down to 0.26 confirms the aggressive-ladder
  mechanism.

## What I could NOT determine from the code alone

- The **exact faulting line** of the crash (needs ASan/a debugger; static
  analysis shows no dangling in the core objects).
- Whether #2 is strictly correct physics or masks a real magnitude/units error
  (needs the `external.size()` + summed-force log, and one hand-calc of the
  expected stress for the actual part dimensions).
- Whether the crash depends on `keyframe_count > 0`, streaming, or pure payload
  size (needs the three-way ablation above).
