# 084 — Savings-ladder rung collapse: diagnosis + fix

Status: **ROOT CAUSE NAMED, FIXED, GATED.** The savings ladder collapsed to a single
rung. The cause is the **`margin_floor_multiple` "ladder floor"** (M7.anchor-integrity
FIX 2, PR #64) that the bridge turned on for the loadcase path. It is **not** design-box
specific — it regressed the no-box ladder too; the box path only made it more visible.
Fix: the bridge no longer sets the floor, reverting `margin_floor_multiple` to its
`+infinity` default (walk to the lightest safe rung). Core library untouched → Gate-V2
byte-identical. New regression gate `ladder_rung_count` asserts the rung COUNT.

Territory: `/core/` (a new test + its CMake entry only — **no core source changed**) and
the sanctioned `app/TopOptBridge/bridge.cpp`. No ROADMAP box checked.

---

## STEP 1 — Ladder semantics (this resolves the contradiction in 080 and 082)

Read from `core/src/simp/minimize_plastic.cpp:364-606` and `core/include/topopt/pipeline.hpp:85-109`.

**a. Walk order / rung 0.** The ladder is validated **strictly descending** in volume
fraction (`minimize_plastic.cpp:118`). Rung 0 is the **heaviest** (highest vf, most
material — the production ladder is `{0.68, 0.52, 0.38, 0.26}`). The walk goes
**heaviest → lightest**. Because more material = stiffer = stronger, the worst-case stress
**margin is HIGHEST at rung 0 and decreases monotonically as the walk proceeds** (confirmed
empirically in STEP 2: e.g. 4.115 → 2.643 → 0.618).

**b. The two tests around the loop** (`minimize_plastic.cpp:567-605`):

- **ACCEPT gate** (line 567-568): `variant.accepted = margin.worst_case * infill_knockdown
  >= margin_stop`. A rung passes if it is *strong enough*. The first rung that FAILS is the
  rejected terminal rung → `stopped_on_margin`, `break` (line 601-604). **This gate is the
  real safety floor**: it stops the walk when the part would become too weak.

- **FLOOR test** (line 596-600), evaluated only *after* a rung is accepted:
  ```cpp
  if (margin.worst_case * infill_knockdown >= margin_floor_multiple * margin_stop) {
    result.stopped_on_floor = true;
    break;
  }
  ```
  This is a **STOP test**: `margin >= floor_multiple * margin_stop ⇒ HALT`. It is a
  *higher* threshold than the accept gate (`floor_multiple >= 1`).

**c. Runtime values (default app loadcase run).** From `bridge.cpp`: `margin_stop = 1.5`
(`pipeline.hpp:88`), `infill_knockdown = 1.0` (default 100% infill →
`infill_margin_knockdown` returns exactly 1.0). The floor multiple **was**
`kAnchorMarginFloorMultiple = 2.0`, so the floor threshold was `2.0 * 1.5 = 3.0`. The core
**default** for `margin_floor_multiple` is `+infinity` = disabled (`pipeline.hpp:109`); the
bridge overrode it to 2.0 at `bridge.cpp:732` (old line), inside `if (load_case.minimize_plastic)`
and **outside** the `has_design_box` guard — i.e. on **both** paths.

**d. Which reading is right — and is the logic backwards? BOTH prior handoffs read the
code CORRECTLY; the LOGIC is backwards for a savings ladder.**

- 080 STEP-3 and 082 both said "HIGH margin ⇒ STOP." That is **exactly what the code does**
  — the reading is not wrong.
- But for a *savings* ladder it is **backwards**. The ladder walks heaviest→lightest and
  margin peaks at rung 0, so a threshold that halts on *high* margin fires at **rung 0** for
  any comfortably-strong part — truncating the ladder from the **strong (heavy) end** and
  deleting exactly the lighter, higher-savings rungs the product exists to offer. The
  product contract is explicit that the recommendation is *the lightest safe rung*
  (`pipeline.hpp:31-33`, `bridge.cpp:135-141` `reduction_ladder`, and the device history:
  −74% was RECOMMENDED). The "floor" halts material removal *precisely when the part is
  safest to keep removing* — the exact inversion the task flagged.
- The name is a misnomer: `margin_stop` is the genuine floor (a lower bound on strength the
  walk descends toward). `margin_floor_multiple` behaves as an **early-halt ceiling on the
  strong end**, not a floor.

So rung 1 is **NEVER ATTEMPTED**, not rejected: the loop `break`s on `stopped_on_floor`
after accepting rung 0. The lighter rungs are never optimized.

---

## STEP 2 — Instrumented decisive comparison

Harness drove `minimize_plastic` directly on the 080/082 thin L-bracket (part mass 0.833 g),
logging per rung: target vf, achieved vf, worst-case margin, accept/reject, stop reason.
Four configs — **{no-box, box} × {floor=2.0, floor=OFF(+inf)}** — across a load sweep.
`floor=OFF` is provably identical to the **pre-PR-#64** behavior (082 asserts the equivalence;
`margin_floor_multiple=+inf` makes the RHS `+inf`, the test false for every finite margin).

Rung counts (full per-rung margins in the raw log below):

| tip load | no-box floor=2.0 | no-box floor=OFF | box floor=2.0 | box floor=OFF | stop reason (floor on) |
|---:|:---:|:---:|:---:|:---:|:---|
| 60 N | 1 | 1 | 1 | 1 | too weak at rung 0 (both) |
| 30 N | 2 | 2 | 2 | 2 | too weak (floor never fires; margin<3) |
| **12 N** | **1** | **3** | **1** | **4** | **STOPPED_ON_FLOOR at rung 0** |
| **5 N**  | **1** | **3** | **1** | **4** | **STOPPED_ON_FLOOR at rung 0** |
| **2 N**  | **1** | **4** | **1** | **4** | **STOPPED_ON_FLOOR at rung 0** |

Reading:

- **The collapse is the FLOOR, and it is NOT box-specific.** In the comfortably-strong
  regime (≤12 N) the floor collapses **both** the no-box and the box ladder to 1 rung;
  turning it off restores 3–4 rungs on **both**. The box makes parts a touch stiffer
  (part-relative rescale + frozen pad) so it crosses margin 3.0 slightly more readily, but
  the mechanism is identical on the no-box path.
- **The no-box path DID regress** (task's "ONE RULE" alarm). At 5 N the production no-box
  ladder went from 3 rungs (pre-#64) to **1**. The device saw "box = 1 rung" only because
  it was compared against **no-box HISTORICAL** runs that predate the floor (task's own
  note: the 4-rung baselines were taken before 082/#64). The regression commit is
  **`fbccc6c` (PR #64, `claude/anchor-integrity-ladder-floor`)**, parent `2c82fb6`.
- **Gate-V2 does not cover rung count** — it runs the locked simp/OC benchmark with default
  options (floor `+inf`), so it stayed green through the collapse. `designbox_reduction`
  *does* assert equal no-box/box rung counts, but only at −30 N, where margin < 3.0 and the
  floor never fires (see the 30 N row) — so it never exercised the collapse regime. Both
  facts are findings in their own right: **no existing gate asserted the production rung
  count in the regime that broke.** The new `ladder_rung_count` closes that.

Raw log (`core/tests/validation/diag_ladder_collapse.cpp`, since removed):

```
===== tip load = 12.0 N  (part_mass=0.8333 g) =====
  no-box  floor=2.0   rungs=1  -> STOPPED_ON_FLOOR
      rung0 tgt_vf=0.68 achieved=0.680 margin=4.115 accepted=Y [>=floor]
  no-box  floor=OFF   rungs=3  -> stopped_on_margin(too weak)
      rung0 margin=4.115 Y | rung1 margin=2.643 Y | rung2 margin=0.618 N [<stop]
  box     floor=2.0   rungs=1  -> STOPPED_ON_FLOOR
      rung0 achieved=0.631 margin=4.646 Y [>=floor]
  box     floor=OFF   rungs=4  -> stopped_on_margin
      rung0 4.646 Y | rung1 2.914 Y | rung2 3.746 Y | rung3 1.434 N [<stop]
===== tip load = 5.0 N =====
  no-box floor=2.0 rungs=1 (STOPPED_ON_FLOOR, rung0 margin=9.875)
  no-box floor=OFF rungs=3 ;  box floor=2.0 rungs=1 ;  box floor=OFF rungs=4
```

---

## STEP 3 — Named root cause

**The `margin_floor_multiple` "ladder floor" (M7.anchor-integrity FIX 2), enabled by the
bridge at 2.0 on both loadcase paths, truncates the savings ladder from the strong end.**
Because margin peaks at the heaviest rung, the floor halts the walk at rung 0 for any part
comfortably above `2·margin_stop = 3.0`, hiding the lighter high-savings rungs and the
recommendation the ladder exists to produce. This is **not intended safety behavior
correctly halting** (the STEP-3 "defer to product" branch): the genuine strength floor is
`margin_stop` (the accept gate), which already stops the walk before the part gets unsafe.
The floor is a second, higher, *inverted* threshold that defeats the ladder's purpose. The
anchor-integrity concern that motivated it (a lightly-loaded part stripped too thin, its
anchor carved away) is addressed by **FIX 1 (the frozen structural pad)**, which is intact
and unaffected by this change.

**Product note (flagged, not silently overridden):** if the maintainer wants to avoid
*recommending* an aggressive strip on a lightly-loaded part, that belongs at the
recommendation-**selection** layer (which rung to highlight), never as a walk terminator
that deletes the other rungs from the results screen. The margin numbers above (e.g. rung 0
at margin 5–28 while lighter safe rungs still clear margin_stop 1.5) show the floor was
leaving large, safe savings on the table.

---

## STEP 4 — Fix (minimal) + regression gate

**Fix — `app/TopOptBridge/bridge.cpp`:** removed `opts.margin_floor_multiple =
kAnchorMarginFloorMultiple;` and the `kAnchorMarginFloorMultiple` constant. The option now
keeps its core default `+infinity` (disabled) on every path, so the ladder walks to the
lightest safe rung. Explanatory WITHDRAWN comment left in place. **No core source changed**
— the floor *mechanism* stays in the core API at its harmless disabled default (byte-identical
to Gate-V2's usage); only the production turn-on is removed. This restores no-box production
to its pre-#64 behavior and fixes the box path with the same one change.

**Regression gate — `core/tests/validation/test_ladder_rung_count.cpp` (`ladder_rung_count`):**
a comfortably-strong part (light 5 N tip load) under production-shaped options (mirroring the
FIXED bridge — floor left at `+inf`) must yield **≥ 3 rungs** on **both** the no-box and box
paths, and — to keep the guard non-vacuous — re-enabling the floor (`margin_floor_multiple=2.0`)
must collapse the **same** part to strictly fewer rungs. This fails loudly if a future change
re-introduces a ladder-truncating floor.

```
[ladder] production: no_box_rungs=3  box_rungs=4  |  floor-on: no_box=1  box=1
ladder_rung_count: all 4 checks passed
```

`designbox_reduction`'s helper still sets `margin_floor_multiple=2.0`, which no longer
matches production; it stays green because its −30 N fixture never crosses the floor, and
its assertion (box rung count == no-box rung count) remains valid. Left untouched to avoid
churn; noted here.

---

## Evidence

- **Relevant gates (Release, Eigen via `/opt/homebrew`), raw:**
  ```
  gate_v2 ............... Passed 52.58 sec     (byte-identical — no core source changed)
  minimize_plastic ..... Passed 17.63 sec
  anchor_integrity ..... Passed  3.33 sec      (no-box FIX-1 pad intact)
  designbox_reduction .. Passed  1.09 sec
  ladder_rung_count .... Passed  2.20 sec      (NEW)
  designbox_anchor_pad . Passed  3.27 sec      (box FIX-1 pad intact)
  100% tests passed, 0 tests failed out of 6
  ```
- The STEP-2 four-way table + raw per-rung log above.
- Regression commit for the floor: `fbccc6c` (PR #64), parent `2c82fb6`.

## Not done / honest notes

- **App re-vendor required.** `bridge.cpp` changed; the app must be re-vendored via
  `app/scripts/build_core.sh` (macOS Xcode/lipo/xcframework flow) before the Swift/app
  suite reflects it. Not run here — no Swift source changed except the bridge, compiled
  from the vendored core.
- **Unrelated worktree changes present, NOT mine and NOT touched:**
  `app/TopOptFlows/ResultsModel.swift` and `ViewerMesh.swift` carry pre-existing "083"
  smooth-shading display edits. Left alone; flagged so they are not attributed to this fix.
- **Core `margin_floor_multiple` option left in place** (disabled default). Deleting it from
  the API or repurposing it as a recommendation-only cap is a maintainer decision; the
  diagnosis above is the input to that call.
- No ROADMAP box checked.
