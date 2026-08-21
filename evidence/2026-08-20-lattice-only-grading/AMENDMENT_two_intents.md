# Amendment — two grading intents. Evidence for R13–R21.

Base for the amendment: PR 344 as merged (`22c173b0` on `2a96fc69`).
All runs: `M2_verticalStand.step`, lattice-only, his declared load case, from the CLI.

## The CLI invocation that drives it

    topopt-cli analyze jobs/aes_bandB_on.json --out amend_aes_bandB_on

with, in the job's `grading` block:

    "intent": "aesthetic",            // "structural" | "aesthetic"; absent => aesthetic
    "aesthetic_rho_min": 0.20,        // omit both for the certifiable band
    "aesthetic_rho_max": 0.60,
    "aesthetic_percentile": 0.95      // optional; omit for core's constant

and `loads.minimize_plastic` — the maintainer's existing checkbox — selecting the band
position. No new control was added anywhere.

## R13 — aesthetic produces a VISIBLE grade, on two ranges

**`100 % at floor` does not recur: it is 0.00 % in every aesthetic run.**

| run | intent | latticed | % at floor | mean rho | rel. mass |
|---|---|---|---|---|---|
| `structural_on` | structural | 28,344 | **100.00 %** | 0.0717 | 2.03e3 |
| `aes_bandB_on`  | aesthetic [0.20, 0.60] | 91,575 | **0.00 %** | 0.2783 | 2.55e4 |
| `aes_bandB_off` | aesthetic [0.20, 0.60] | 104,761 | **0.00 %** | 0.3958 | 4.15e4 |
| `aes_bandC_on`  | aesthetic [0.10, 0.35] | 84,660 | **0.00 %** | 0.1548 | 1.31e4 |
| `aes_bandC_off` | aesthetic [0.10, 0.35] | 91,648 | **0.00 %** | 0.2294 | 2.10e4 |

Density histograms (percent of latticed, 20 bins across the certifiable band):

    structural_on   100  0  0  0  0  0  0  0  0  0 ...        (everything on the floor)
    aes_bandB_on      0  0  0 47 18  9  6  5  3  2  2  2  6   (a real distribution)
    aes_bandB_off     0  0  0  5  6  8 17 14 13 11  9  7  9   (the same pattern, denser)
    aes_bandC_on / _off likewise, over the narrower range

**The range parameter is demonstrably live**: band B and band C differ in mean density
by 1.8x at the same switch setting, and each run's histogram is confined to its own
range.

## R14 — `minimize_plastic` ON vs OFF DIFFER in aesthetic mode

| range | mean rho ON → OFF | rel. mass ON → OFF |
|---|---|---|
| [0.20, 0.60] | 0.2783 → 0.3958 (**+42 %**) | 2.55e4 → 4.15e4 (**+63 %**) |
| [0.10, 0.35] | 0.1548 → 0.2294 (**+48 %**) | 1.31e4 → 2.10e4 (**+60 %**) |

The PR 344 failure — ON and OFF producing identical parts — does **not** recur. It is a
band POSITION here: an exponent on the normalised field, so both ends of the range are
preserved exactly and only the mass between them moves. Same field, same shape,
different weight.

(Mass is derived from the fixed-bin histogram using bin CENTRES — exact to within half
a bin, `(hi-lo)/40` = 0.021 — and stated as a proxy rather than quoted as a measurement.)

## R16 — deterministic percentile

Same job twice: grading blocks identical, `fields.bin` SHA-256 match. The percentile is
a FULL SORT of the candidate demands in voxel order, never a sampled estimate.

## R17 — clamps reported for both intents

| run | `clamped_lo` | `clamped_hi` | `above_percentile` |
|---|---|---|---|
| structural_on | 28,344 | 0 | n/a |
| aes_bandB_on | 0 | 0 | **5,546** |
| aes_bandC_off | 0 | 0 | **5,546** |

`above_percentile_voxels` is the tail the percentile deliberately discards — it clamps
to the top of the range and is counted rather than silently absorbed.

## R18 — structural is byte-identical to PR 344 as merged

Every PR-344 receipt field compares **equal**; the only added key is `"intent"`.
28,344 latticed, 100 % at floor, same histogram, same strut diameters.

## R19 — the meaning string

> "This lattice follows the stress pattern for appearance. Its density is not a strength
> requirement; the certificate is what checks strength."

**21 words.** Reported on the receipt as `density_meaning`; the law does not place it.
Empty in structural mode, which keeps its strength claim.

## R20 — no new UI

`git diff --stat` on `app/` is exactly three files: `bridge.cpp`,
`TopOptBridge.hpp`, `LatticePreviewOccupancy.swift` — the mirror and nothing else.

## R21 — assertion census vs the merge base

**0 assertion-bearing lines removed, 15 added.** Read whole, not through a filter.

## ★ A DEFECT THIS AMENDMENT SURFACED — `plan_cell_sizes`, swept mode

`intent: aesthetic` over the **full certifiable band** [0.0505, 0.8999] in SWEPT cell
mode fails:

    topopt-cli: plan_cell_sizes: level assignment is not an aligned octree

It is **bounded**, and neither half of the cause is sufficient alone:

| range | width | touches `rho_min` | result |
|---|---|---|---|
| [0.20, 0.60] | 0.40 | no | OK |
| [0.10, 0.35] | 0.25 | no | OK |
| [0.10, 0.90] | 0.80 | no | **OK** |
| [0.0505, 0.35] | 0.30 | **yes** | **OK** |
| [0.0505, 0.8999] | 0.849 | **yes** | **FAILS** |

So it needs a field that BOTH reaches the density floor AND spans nearly the whole
band — the combination that maximises the spread of required cell levels inside one
aligned octree block.

**Why it never fired before.** Under the old peak-relative law the low tail was CLAMPED
to exactly `rho_min`, so large contiguous regions shared one density, one strut and one
level, and blocks were uniform by accident. The aesthetic grade removes that plateau: it
maps onto the range continuously and never clamps low, so neighbouring base cells inside
an aligned block can want levels that the balancing pass does not reconcile.

**Not fixed here.** It is in `cell_plan.cpp`, shared with the TO+lattice path, and
touching it would put §6(c)'s byte-identity at risk for a defect that predates this
amendment. It is reported, bounded, and reproducible with the job files in `jobs/`.
The default aesthetic range is the full band, so **this is reachable by default in
swept mode** and should be fixed before aesthetic ships to the UI.

## R15 — core and the app agree, to the digit, on BOTH intents

`LatticePreviewOccupancy.demand(...)` no longer normalises anything itself. It samples
the field onto the preview grid and hands those samples to
`topoptbridge::grading_demand_fraction_into`, which calls **core's own**
`topopt::grading_demand_fraction` — the same inline function `grade_lattice` calls.

Demonstrated, not asserted (`mirror_agree.cpp`, `r15_core_app_agree.txt`): his run's
von Mises field, **468,224 samples**, fed to both paths.

| case | reference | max abs difference |
|---|---|---|
| STRUCTURAL, `minimize_plastic` ON | 36.66666667 MPa | **0.000e+00** |
| STRUCTURAL, `minimize_plastic` OFF | 36.66666667 MPa | **0.000e+00** |
| AESTHETIC, p95 | 0.008367483504 MPa | **0.000e+00** |
| AESTHETIC, p80 | 0.004898220766 MPa | **0.000e+00** |

**Bit-identical on every sample, both intents.**

★ A first version of this probe reported 1.4e-11 and 3.0e-8 and called it drift. It was
not: the bridge stores `float32` and the probe compared it against a `float64`, so it
was measuring the STORE, not the law. It now narrows core's value the same way the
bridge does and requires BIT equality. Recorded because a precision-mismatched
comparison that cries drift is exactly as useless as one that hides it.

Swift package: `xcodebuild build -scheme TopOptKit-Package -destination platform=macOS`
— **BUILD SUCCEEDED** against the rebuilt xcframework (fingerprint `22c173b05c6b`).

---

## ★ THE ADAPTIVE CELLS-PER-MEMBER FLOOR (aesthetic only)

**The 5 is an ACCURACY threshold, not a buildability one.** `lattice.hpp` says so:
it "protects the CERTIFICATE… but the part still prints". The buildability floor is
`lattice_percolation_cells_per_member_min` = **1**.

The error curve behind the 5 is already measured (handoff
2026-07-28-graded-cell-size-phase0, C2b — bending, as deployed):

| cells | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| stiffness error | +48.5 % | +8.5 % | +4.1 % | +2.59 % | +1.78 % |

5 is where it crosses a 2.4 % band. **That band is a choice, not physics.**

So in AESTHETIC intent the floor becomes a function of what the material actually
carries: the smallest measured cell count whose `error x utilisation` stays inside a
stated budget (1 % of allowable, `kAestheticHomogenisationErrorBudget`).

**Hard-floored at 2, not 1.** The percolation figure of 1.0 was measured at rho ~= 0.199,
AXIAL, octet only, and its own declaration says it "must not be quoted
unconditionally". 2 is the lowest point measured under the BENDING case the accuracy
floor itself uses.

### Measured on his part — [0.20, 0.60], aesthetic

| | adaptive OFF | adaptive ON | delta |
|---|---|---|---|
| latticed voxels | 91,575 | **96,891** | **+5,316 (+5.8 %)** |
| solid fallback | 19,329 | 14,013 | −5,316 |
| cells dropped unprintable | 11,350 | 9,312 | −2,038 |
| min cells/member | 5.116 | 2.558 | −2.558 |
| floor in force | 5.000 | **2** | |
| below accuracy floor | — | **4,113 voxels** | counted, out of regime |

★ **WHY IT LATTICES MORE, WHICH IS COUNTER-INTUITIVE.** The floor is an UPPER BOUND on
cell size (`S <= W / N*`). LOWERING it permits COARSER cells, which makes struts FATTER
and therefore MORE printable — 2,038 fewer cells dropped as unprintable. The binding
constraint on his part was never the accuracy floor; it was printability, and relaxing
the accuracy floor is what let the planner reach a printable cell.

### ★ TWO MISTAKES ON THE WAY, BOTH WORTH RECORDING

1. **The first wiring was a NO-OP.** I relaxed the floor in `grade_lattice`'s own
   checks but not in `plan_cell_sizes`, which is what actually CHOOSES the cell.
   Measured +0 voxels. A feature that changes nothing reads exactly like a feature
   that works until you diff the numbers — and the second run's output was STALE
   (the run had failed), which made "+0" look like a real comparison. Both caught by
   checking the completion marker, not the file.
2. **The tail assertion then fired**, correctly: the thinnest member was below the
   fixed floor. It now checks against the floor that GOVERNED — the accuracy floor
   without the rule, the computed floor with it — which is a restatement, not a
   weakening. A NEW assertion was added beside it: if material sits below the accuracy
   floor and none was counted out of regime, that throws.

Regression: 5/5 targeted core tests. Assertion census vs the merge base: **0 removed.**
