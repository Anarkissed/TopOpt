# 2026-07-23 — Gate honesty micro: the connectivity belt + rejection speaks

**Track:** core only. **Territory:** `core/include/topopt/{voxel,pipeline,report}.hpp`,
`core/src/voxel/voxelize.cpp`, `core/src/simp/minimize_plastic.cpp`,
`core/src/settings/report.cpp`, `core/src/cli/run_job.cpp` + four tests. **NO app,
NO bridge, NO solver, NO optimizer.** Nothing in the change reads or writes a design
variable; the belt is a read-only pass over a converged density field.

**Naming:** first handoff on the date-slug convention. Cites its predecessors by
their old numbers.

**Gates (all green):** `ctest` **64/64**, 268 s (`evidence/ctest-full.out`). The
byte-identity gates — `production_parity`, `clearance_parity`,
`face_protection_parity`, `cli_demo` (golden `expected_values.json`) — all pass
untouched.

---

## 0. The two items, and what they turned out to be

| item | asked for | what shipped | surprise |
|---|---|---|---|
| 1 connectivity belt | flood-fill anchor→load before certifying; no path → reject with "load path not connected", recorded in `rejected_variants` | `load_path_connected()` (voxel.hpp) + the gate wiring | **The belt fires on five existing fixtures.** Every one is a genuine severed design that the gate was certifying and exporting. Details in §2. |
| 2 rejection speaks | `rejection_reason` never empty | three published constants, every `rejected_variants` entry carries one, validator enforces it | The rejection that used to carry `""` — the too-weak terminal rung — now says `margin below required`. |

The belt was assumed to be inert on the existing suite ("byte-identity: connected
variants are untouched"). Connected variants ARE untouched — but a third of the
suite's optimizer fixtures do not produce connected variants. That is the finding,
and it is the same failure handoff 131 chased: **no stress reads as an enormous
margin**, and nothing was checking the geometry.

---

## 1. What shipped

### 1.1 The primitive — `load_path_connected` (voxel.hpp / voxelize.cpp)

```cpp
bool load_path_connected(const VoxelGrid& grid,
                         const std::vector<double>& density, double iso = 0.5);
```

True iff **every `Load`-tagged voxel is reachable from some `Fixture`-tagged voxel
by a walk over PRINTED voxels** (non-`Empty` tag AND `density > iso` — the same set
the mesh, the mass and the stress field use). Read-only, `O(voxel_count)`,
deterministic (a reachable-set membership test: no traversal order changes the
answer). Throws on a size mismatch like every sibling field consumer.

Three decisions worth their own line:

* **26-connectivity (node sharing), not 6.** Two hex8 elements touching at a single
  corner still share that node and still transmit force, so face-only adjacency
  would reject designs that the very FEA which produced the margin considers
  connected. The belt must never contradict our own physics. It catches TOTAL
  severance; thinness is min-feature's job.
* **Vacuously true with no `Load` or no `Fixture` voxels.** A self-weight run tags
  no load faces, so there is no load path to certify. This is what keeps every
  self-weight fixture — including the `cli_demo` golden — byte-identical.
* **A `Load` voxel that is not printed is unreachable, hence false.** The load face
  was carved away; that is the same failure seen from the other end.

### 1.2 The gate wiring (minimize_plastic.cpp)

The verdict is measured once, right after the rung's density converges, and governs
two things:

1. **The accept gate.** `accepted = load_path_ok && margin_effective >= margin_stop`.
   The margin test is unchanged and still evaluated in its own right.
2. **The warm seed.** A disconnected rung never seeds the next one — handoff 131's
   rule (2), for the same reason: seeding from a severed field propagates the
   severance and buries the evidence of where it started.

**Which rejection stops the ladder** is decided by the **margin test alone** —
exactly the pre-belt condition on exactly the pre-belt numbers:

* too weak → **STOP** (strength is monotone in the ladder direction), whether or not
  the rung was also severed;
* severed only → **CONTINUE**, mirroring an infeasible rung (131 rule (3)).

That second rule is not a preference, it is measured. On the 8×3×8 L-bracket
(`test_warm_start_integration`'s fixture, production options):

```
rung 0 vf=0.68  SEVERED   margin 9.83   <- rejected
rung 1 vf=0.52  connected margin 6.33   <- accepted
rung 2 vf=0.38  connected margin 4.66   <- accepted
rung 3 vf=0.26  SEVERED   margin 2.27   <- rejected
```

Severance is **not monotone** in the ladder direction — each rung is optimized
independently, so it is a failure of one carve. Stopping at rung 0 would have
returned the user nothing while two good variants existed.

Keying the stop on the margin alone also matters for a rung that fails BOTH tests:
it still ends the walk (see §4.1 — an earlier draft that let connectivity suppress
the margin stop walked into rungs the ladder had never reached, one of which throws
`fea_solve_cg: CG did not reach the requested tolerance`).

### 1.3 Rejection speaks

Three constants in `pipeline.hpp`, one definition each, shared by the driver, the
CLI console lines and the tests:

| constant | string | meaning |
|---|---|---|
| `kMarginBelowRequiredReason` | `margin below required` | the ordinary strength verdict; the rung WAS analysed and `margin_effective` vs `margin_required` are the detail |
| `kLoadPathNotConnectedReason` | `load path not connected` | the belt; the rung WAS analysed, so the numbers are measurements — **of a severed structure**, which is exactly why they look excellent |
| `kRungInfeasibleReason` | `rung infeasible (load path lost)` | handoff 131; the rung never reached the gate, so every number on the line is a ZERO PLACEHOLDER |

`""` now means one thing only: **accepted**. Enforced three ways — the driver sets a
reason on every rejection, `validate_job_report_json` rejects a `rejected_variants`
entry whose `rejection_reason` is present and empty (absent is still fine, so
pre-131 documents validate), and `report.hpp` states the contract with what each
reason says about the STATUS of the numbers beside it.

`min-feature` is listed in the task as a possible reason "as applicable". It is not
applicable: `min_feature_violations` is report-only and gates nothing (voxel.hpp,
M5.2b). Making it reject would be a new acceptance rule, not a honesty fix, so it
was not invented here.

### 1.4 Loud disconnection (run_job.cpp)

One stderr line per belt-rejected rung, mirroring 131's loud-infeasibility loop:
the rung, its vf, the reason, and its measured margin explicitly labelled as
describing a severed structure. Not covered by an automated test — neither is 131's
sibling warning; both are one `fprintf` off a field the driver-level tests do assert.

---

## 2. What the belt found in the existing suite

Five tests changed behaviour. **Every one is a true positive.** No fixture was
retuned to make the belt quiet.

### 2.1 `test_ladder_rung_count` / `test_warm_start_integration` — the L-bracket

The 8×3×8 t=2 L-bracket under production options. At rung 0 (vf 0.68) the optimizer
carves the column feeding the frozen Load face down to sub-threshold grey and the
load face floats free of the arm:

```
printed map, rows k=7..0, cols i=0..7   (#=full across j, +=partial, 0=none, .=outside part)
k=7 | # # . . . . . .        margin 9.83, margin_stop 1.5  -> ACCEPTED before the belt
k=6 | # # . . . . . .        v3: mesh_components_raw = 2, load_fixture_islands = 1
...                          i=6 is EMPTY; i=7 (the Load face) is a floating slab
k=1 | + + # + + + 0 #
k=0 | + + + + + + 0 #
```

`load_fixture_islands = 1` means the V3 suite **already saw this** — handoff 064's
FIX 3 diagnostic recorded "the cleanup dropped a disconnected frozen region" — and
nothing acted on it. The belt is the action.

**Root cause of the severance itself:** both tests' headers say their options mirror
production "…MMA, the anchor pad", and neither sets `design_mask`. Production freezes
`kProductionAnchorPadDepthVoxels = 3` part-solid layers behind each anchor/load face
(M7.anchor-integrity FIX 1) precisely so the optimizer cannot get the frozen Load
face for free. Adding that pad to the fixture was measured and makes all four rungs
connected and accepted (4/4 rungs, `mesh_components_raw = 1`, `load_fixture_islands = 0`)
— but it also perturbs the box path and the warm-start iteration baselines the
handoff-110 numbers were measured on, so **the fixtures were left alone** and the
finding is recorded here instead. See §5 (follow-up 1).

`test_ladder_rung_count` needed **no change** once the stop rule keyed on the margin:
it counts evaluated rungs, and those are unchanged (no-box 4, box 4).
`test_warm_start_integration`'s blanket "every evaluated rung is accepted" became
`gate_verdicts_sound` — accepted ⇒ margin ≥ stop, not accepted ⇒ a stated reason —
plus a non-vacuity check that each configuration accepts at least one rung.

### 2.2 `test_minimize_plastic` scenario J — the cantilever tip load

`margin_stop = 0`, i.e. the strength gate accepts anything: exactly the regime where
"no stress = safe" cannot be caught by a margin. At vf 0.30 the three columns in
front of the tip empty out (max ρ 0.464 / 0.467 / 0.425) and the frozen Load face at
i=19 floats free. Reported margin **111.7**. Accepted and exported before the belt.

Now asserted directly as `J.belt`, including that the ladder still walks past it and
that every other rung is accepted.

### 2.3 `test_rung_infeasible` — 131's own documented blind spot, closed

Group 3's rung 2 is "born dead": its target is below `density_min`, so the whole
design region starts on the floor and no ratio to its own starting compliance can
ever fire. 131 states this as a limitation and leaves it. It was **accepted and
exported**. The belt does not care how a design got severed — only that it is —
so that rung is now rejected with the connectivity reason while remaining, as 131
documented, undetected by the infeasibility predicate. `report.rejected` now holds
two entries with two different reasons.

Group 1's "healthy run" guard also fires the belt: its second rung is vf 0.03, a
target so light the printed design has nothing left between anchor and load. The
guard was narrowed to what it is actually about — nothing is rejected **as
infeasible** — and the armed-vs-disarmed byte-identity claim is unaffected (the belt
is on in both).

### 2.4 `test_designbox_reduction` — passes unmodified

Baseline and post-belt rung counts are identical (no-box 2, box 2). Worth recording
anyway: on that fixture **every rung is severed**, including rung 0, which the box
path previously accepted at 35.7 % savings. Post-belt the no-box path accepts 0
rungs and the box path 1.

---

## 3. Byte-identity on connected cases

* `cli_demo` — the maintainer-authored demo job with its golden
  `expected_values.json`. Self-weight, so the belt is vacuous by construction:
  **unchanged**.
* `production_parity`, `clearance_parity`, `face_protection_parity` — all green.
* `test_warm_start_integration` cold total iterations: **326 before, 326 after**
  (pre-belt baseline captured by stashing the change and rebuilding). The belt does
  not touch the optimizer.
* `warmA` went 171 → 206 iterations. This is the ONE intended non-identity: with
  inheritance on, a disconnected rung no longer seeds the next, so the next rung
  starts from the last *connected* design instead of a severed one.
* Scenario J rungs 0 and 1 are bit-identical; only the verdict on rung 2 changed.

---

## 4. What was tried and rejected

### 4.1 Stopping the ladder on a connectivity rejection (first draft)

Measured and withdrawn twice over:

1. On the L-bracket it returns **zero variants** for a part with two good ones
   (§1.2's table).
2. Because a severed rung's rejection then pre-empted the margin stop, runs walked
   into rungs the ladder had never reached — and on `test_savings_part_relative`'s
   box fixture rung 3's optimize throws `fea_solve_cg: CG did not reach the
   requested tolerance within max_iterations`, aborting the whole run. Verified
   against the pre-belt build that this throw is **pre-existing and unrelated to the
   belt** (that fixture stops at rung 0 on the margin either way, with margin 0.5984);
   keying the stop on the margin alone restores that and the test passes unmodified.

### 4.2 Retuning the fixtures to make the belt quiet

Adding the production anchor pad works (§2.1) but changes what three tests measure.
Recorded as a follow-up instead.

### 4.3 Skipping the analysis of a severed rung

Consistent with 131's rule (1) and cheaper, but it would replace the measured margin
with a zero placeholder — and "margin 111.7 on a structure that carries nothing",
printed next to the reason, is the most legible evidence in the whole change. The
reason string carries the status of the numbers instead (report.hpp).

---

## 5. Follow-ups (none blocking)

1. **The fixtures that omit the production anchor pad.**
   `test_ladder_rung_count`, `test_warm_start_integration` and
   `test_designbox_reduction` all claim production-shaped options and all omit
   `design_mask`. They are therefore measuring an optimizer that gets its Load face
   for free. Adding `anchor_pad()` to each (and re-baselining 110's iteration
   numbers) would make three gates test the configuration they say they test.
2. **`fea_solve_cg` throwing out of the ladder.** A rung whose solve cannot converge
   destroys a run that may already hold accepted variants. Reachable today past an
   infeasible rung (131 already continues the walk). A rung that fails to solve
   should be a rejected rung with a stated reason, not an exception — the same
   principle as this change, one level down.
3. **The belt is a gate, not a fix.** It rejects severed designs; it does not stop
   the optimizer producing them. The production anchor pad is the known preventative,
   and §2.1 shows it works on the small fixtures. Whether a thin part at production
   resolution still severes WITH the pad is unmeasured here.

---

## 6. Evidence

`docs/handoffs/evidence/2026-07-23-gate-honesty-connectivity-rejection/`

| file | what it shows |
|---|---|
| `ctest-full.out` | 64/64, 268 s |
| `test_voxel.out` | the synthetic belt fixtures: an 8×1×1 anchor→load bar, one sub-iso voxel anywhere along it severs it; iso boundary; carved load / carved anchor; both vacuous cases; corner-touch connected vs gapped severed; size-mismatch throw |
| `test_report.out` | empty `rejection_reason` on a rejected line is a schema violation; all three reasons validate; absent field still validates (pre-131); round trip |
| `test_minimize_plastic.out` | `[J.belt]` — the belt firing on a real optimizer output at margin 111.7 |
| `test_rung_infeasible.out` | `[belt]` — 131's undetectable born-dead rung rejected anyway; `[one rule]` — the healthy run's vf-0.03 rung |
| `test_warm_start_integration.out` | `accepted: cold=2 warmA=2 warmB=3 warmAB=3 (of 4 rungs)` beside the iteration counts |
| `test_ladder_rung_count.out`, `test_designbox_reduction.out` | unmodified tests, green |
