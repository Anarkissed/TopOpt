# 2026-07-26 — Which width governs the f^1.5 knockdown: ENVELOPE or MEMBER? (MEASUREMENT)

**Track:** diagnostic / measurement. **NO production code, NO default changed.**
Follow-up to [2026-07-26-knockdown-check.md](2026-07-26-knockdown-check.md) (handoff
191). One new standalone measurement harness
([`core/tests/harness/knockdown_member_probe.cpp`](../../core/tests/harness/knockdown_member_probe.cpp),
the sanctioned `lattice_probe.cpp` / `knockdown_probe.cpp` pattern — grids built
programmatically, standalone build, NOT wired into CTest), this report, and its
evidence directory. No `core/src`, no `/app/`, no fixture, no `materials.json`,
no benchmark, no ROADMAP box, no DECISIONS/ARCHITECTURE edit.

---

## Why this comes before any fix

191 found the accept gate's f^1.5 infill knockdown is **size-dependent**: solid
slicer wall loops make f^1.5 **conservative** on narrow cross-sections and
**non-conservative** on wide ones, with a crossover near **W\* ≈ 98 mm** at 30 %
infill / 5 loops, and a true margin as low as **~1.0** at 200 mm. **But 191
modelled a SOLID RECTANGULAR BAR of width W and swept W across ENVELOPE-scale
values.** A topology-optimized part is not a solid bar — it is a set of thin
**ribs/members** (this project's min-feature floor puts members near **9.4 mm**)
with voids between them, and an FDM slicer wraps wall loops around **each rib's
local cross-section**, not the overall envelope. If the governing width is the
member, the wall fraction φ_wall = 4t(W−t)/W² is large and 191's alarm largely
evaporates for optimized parts; if it is the envelope, there is a real
correctness problem. **This report measures which.**

---

## TL;DR — the answer, with the sign stated

**The governing width is the MEMBER, and at member scale 191's alarm evaporates —
the gate is CONSERVATIVE (too cautious), not dangerous, for topology-optimized
parts. In bending — the maintainer's actual load case — it is more conservative
still.**

1. **Production applies f^1.5 with NO width term at all** — the knockdown is a
   pure function of infill fraction ([`minimize_plastic.cpp:69`](../../core/src/simp/minimize_plastic.cpp)),
   sees no geometry, and the wall-loop physics is not represented in production.
   Wall loops are a **slicer** concept (`PrintParams.wallLoops`, UI metadata) that
   never reaches the engine. So "which width governs" is really *which width
   decides whether f^1.5 is conservative* — set by where the slicer lays
   perimeters: **around each rib/member's local cross-section, not the envelope**
   (§3).
2. **At MEMBER widths (5–15 mm, directly resolved), any real wall count flips
   f^1.5 hard CONSERVATIVE.** A 10 mm member (≈ the 9.4 mm min-feature member) at
   the default 5 wall loops has true margin **2.65 (60 %) – 18.5 (15 %)** where the
   gate certifies 1.5; at 3 loops, **2.19 – 12.8**. The *worst* realistic member
   (10 mm, 60 % infill, only 3 loops) is **margin 2.19 in tension** — still 1.5×
   the certified value. Only the **wall-less bare core** (not a real printed
   member) dips to ~1.0 (191's regime).
3. **My direct member-scale measurements VALIDATE 191's own Voigt model** (e.g.
   10 mm / 5 loops / 30 %: measured E/Es = 0.732, 191 Part-B measured 0.732;
   10 mm / 5 loops / 15 %: measured 0.718 vs 191's model 0.711). So 191's physics
   is right; only its *choice of width* (envelope) was wrong for an optimized part.
4. **BENDING makes it MORE conservative, not less** (§2). On the SAME 10 mm walled
   member, the solid perimeter walls sit at the outer fiber where bending weights
   them by distance², so the effective stiffness ratio rises: 3 loops / 15 %,
   r_axial = 0.49 → **r_bend = 0.71**, lifting true margin **12.6 → 18.4**; 5 loops,
   17.8 → **23.1**. Sign both times: **walled member = conservative; bending
   amplifies it. Bare core = non-conservative; bending marginally worsens it.**
5. **Reconciliation (§A4): this NARROWS 191, does not overturn it.** 191's
   non-conservative regime is real but confined to **envelope-scale solid
   cross-sections** (W ≳ its crossover 59–98 mm at 30 %) — solid bosses, thick
   pads, near-solid parts. The thin optimized ribs that make up an optimized part
   (~9.4 mm, 6–10× below that crossover) are deep in the conservative regime. The
   number that decides it: **member width ~9.4 mm vs 191's crossover ~59–98 mm**,
   equivalently **true margin ≥ ~2.2 at member scale vs ~1.0 at 200 mm**. Because
   the gate applies one f^1.5 to the whole part regardless of local width, it is
   simultaneously **over-cautious for the ribs and (per 191) still optimistic for
   any envelope-scale solid region** — so the honest correction is size/width-aware,
   not a uniform re-tune.

**Verdict: for a genuinely topology-optimized part, f^1.5 is safe-to-cautious, and
191's alarm applies only to solid/near-solid envelope-scale regions. The decision
(leave it cautious, or make the knockdown width-aware so it stops over-penalizing
thin ribs while still covering thick regions) is the maintainer's — not made
here.**

---

## 3 — WHICH WIDTH DOES THE SLICER ACTUALLY SEE? (traced from the repo)

This is the load-bearing question, and the repo answers most of it directly.

**(a) The production knockdown takes NO width input at all.** The gate's
knockdown is a **pure function of infill fraction**, with no width, thickness,
wall-loop-count, or geometry term anywhere in its signature or body
([`minimize_plastic.cpp:66-73`](../../core/src/simp/minimize_plastic.cpp)):

```cpp
constexpr double kKnockdownExponent = 1.5;                    // :66
double infill_margin_knockdown(double infill_percent) {       // :69
  const double f = infill_percent / 100.0;
  if (f >= 1.0) return 1.0;
  if (f <= 0.0) return kKnockdownFloor;
  return std::max(std::pow(f, kKnockdownExponent), kKnockdownFloor);  // :73
}
```

Computed once at `:394` and applied at the accept gate `:~1103`
(`margin_effective = margin.worst_case * infill_knockdown; margin_ok =
margin_effective >= options.margin_stop`). So **production applies f^1.5 blind to
width** — it sees neither the ~200 mm envelope nor the ~9.4 mm member. The Swift
mirror `ResultsModel.swift:284 infillKnockdown(percent:)` is likewise a pure
function of percent. The wall-loop physics is **not represented in production at
all**; it exists only in the measurement harnesses.

**(b) Wall loops are a SLICER concept and never reach the engine.**
`PrintParams.wallLoops` exists purely as slicer UI/preset metadata
(`PrintParamsSheet.swift`, presets); a grep intersecting `wallLoops` with any
FEA/margin/gate/knockdown term returns nothing, and `wallLoops` never appears in
`RunModel`, `RemoteRunner`, `AppModel`'s run request, or `TopOptBridge.hpp`. Only
`infillPercent` crosses the bridge into the core. The engine exports geometry;
an **external slicer** (Cura/Prusa/…) lays the perimeters downstream.

**(c) So which width does the physics care about?** Because the knockdown has no
width term, "which width governs" is really *which width determines whether f^1.5
is actually conservative*, and that is set by **where the slicer lays
perimeters**. An FDM slicer wraps wall loops around the boundary contour of **each
solid island on each layer**. In a topology-optimized part those islands are the
individual **ribs/members** (governed by the min-feature filter,
`production.cpp:130 min_feature_mm = 2.5`, giving ~9.4 mm members on a 200 mm part
per [089](089-lattice-tooling-research.md) / [2026-07-26-lattice-phase0](2026-07-26-lattice-phase0.md)).
191's envelope-wrapping model (φ_wall = 4t(W−t)/W² with W = the whole part width)
is the **wrong width for an optimized part**: it is correct only for a part that
is a single solid block of width W — a solid bar. **The governing width is the
local member/solid-region width, not the envelope.**

**What is NOT settled by the repo, and what would settle it.** TopOpt does not
slice, so the repo cannot show the *actual* perimeter placement on an exported
part. The definitive test is external: **slice an exported optimized STL and read
the G-code / preview** — confirm perimeters wrap each rib's cross-section and
measure the wall fraction they produce at ~9.4 mm members. I did not assume the
convenient answer; I state it as: *the physics of FDM slicing wraps the member,
and the min-feature width is ~9.4 mm, but a slicer trace is the primary evidence
and is out of this harness's reach.* The measurement below then shows what the
knockdown error IS at member widths, whichever way that trace lands.

---

## METHOD + SELF-CHECK (bar A1)

**Instruments.** Two, both displacement-controlled and measured relative to the
bounding box (so E/Es is exactly the knockdown the gate claims to model).
* **AXIAL** — VERBATIM the instrument 191 (and `lattice_probe.cpp`) validated:
  end planes Dirichlet at 0 and δ, three transverse DOFs pinned, lateral faces
  free → recovers E; end reaction Σ(Ku) via `fea_assembled_apply`.
* **BENDING (new)** — its pure-bending analog. Beam axis z, bending about y;
  prescribe u_z = κ(x−x_c)z on both z end faces (z=0 face all-zero, z=L face
  linear in x), leave u_x,u_y free, pin the x/y rigid modes; reaction moment
  M = Σ(x−x_c)·F_z over the loaded face, E_bend = M/(I·κ), I = W_y W_x³/12. The
  composite knockdown is taken **relative to a matched solid-beam bending solve**
  so any trilinear-hex bias cancels in the ratio.

**SELF-CHECK A (axial), first-hand:** a fully-solid 16³ block recovers
**E_app = 3500.0000 MPa = E_solid to 4 digits on all three axes (ratio
1.000000)** — the instrument is sound (`axial_stdout.txt`).

**SELF-CHECK B (bending), first-hand:** a fully-solid slender beam recovers
**E_bend = 3500 MPa to within 0.1–0.4 %** (ratio 1.001 at W=10 mm, 1.004 at
W=5 mm), and E_bend is **independent of beam length** (identical at Kz = 2, 4, 6
cells) — confirming the instrument measures pure curvature (no shear-locking
contamination) and validating the length-independent-bending assumption. The
composite knockdown is normalized by the matched solid so even this <0.4 % bias
cancels. (`Bself_bending.csv`.)

**Specimen.** Same construction as 191: solid where within the z-caps (top/bottom
shell layers, 5·0.20 mm), within the x/y side-wall thickness (wall loops,
loops·0.45 mm), or the gyroid |field| < calibrated level (infill core at fraction
f). The load/beam axis is z, so the side walls run the full length as continuous
columns (axial) / outer flanges farthest from the neutral axis (bending). The
axial member sweep runs at **vpc=16** (191's member resolution, h=0.31 mm); the
bending sweep at **vpc=12** (bending is wall-dominated and normalized to the
matched solid, so its resolution bias cancels). Every row carries its width,
wall-loop count, infill, and loading mode (bar A2).

---

## 1 — MEMBER-SCALE CROSSOVER (axial / tension) — `M_axial.csv`

Directly-resolved wall-and-core specimens at **member widths W ∈ {5,10,15} mm**
(K = 1,2,3 cells), wall loops {0,3,5}, three infills. `asm/meas` = f^1.5 / E_meas
is the gate error with sign; `margin@1.5` = 1.5·E_meas/f^1.5 is the true margin
of a part the gate certifies at exactly 1.5.

| W mm | loops | φ_wall | infill | E_meas/Es | f^1.5 | asm/meas | sign | **margin@1.5** |
|---|---|---|---|---|---|---|---|---|
| 5 | 0 | 0.00 | 0.15 | 0.0805 | 0.0581 | 0.72 | CONS | 2.08 |
| 5 | **3** | 0.75 | 0.15 | 0.8010 | 0.0581 | 0.07 | CONS | **20.68** |
| 5 | **5** | 0.98 | 0.15 | 0.9900 | 0.0581 | 0.06 | CONS | **25.56** |
| 5 | 0 | 0.00 | 0.30 | 0.1403 | 0.1643 | 1.17 | NON-CONS | 1.28 |
| 5 | **3** | 0.75 | 0.30 | 0.8130 | 0.1643 | 0.20 | CONS | **7.42** |
| 5 | **5** | 0.98 | 0.30 | 0.9900 | 0.1643 | 0.17 | CONS | **9.04** |
| 5 | 0 | 0.00 | 0.60 | 0.4260 | 0.4648 | 1.09 | NON-CONS | 1.37 |
| 5 | **3** | 0.75 | 0.60 | 0.8850 | 0.4648 | 0.53 | CONS | **2.86** |
| 5 | **5** | 0.98 | 0.60 | 0.9970 | 0.4648 | 0.47 | CONS | **3.22** |
| 10 | 0 | 0.00 | 0.15 | 0.0622 | 0.0581 | 0.93 | CONS | 1.61 |
| 10 | **3** | 0.44 | 0.15 | 0.4941 | 0.0581 | 0.12 | CONS | **12.76** |
| 10 | **5** | 0.68 | 0.15 | 0.7182 | 0.0581 | 0.08 | CONS | **18.54** |
| 10 | 0 | 0.00 | 0.30 | 0.1085 | 0.1643 | 1.51 | NON-CONS | **0.99** |
| 10 | **3** | 0.44 | 0.30 | 0.5210 | 0.1643 | 0.32 | CONS | **4.76** |
| 10 | **5** | 0.68 | 0.30 | 0.7321 | 0.1643 | 0.22 | CONS | **6.68** |
| 10 | 0 | 0.00 | 0.60 | 0.3716 | 0.4648 | 1.25 | NON-CONS | 1.20 |
| 10 | **3** | 0.44 | 0.60 | 0.6791 | 0.4648 | 0.68 | CONS | **2.19** |
| 10 | **5** | 0.68 | 0.60 | 0.8225 | 0.4648 | 0.57 | CONS | **2.65** |
| 15 | 0 | 0.00 | 0.15 | 0.0601 | 0.0581 | 0.97 | CONS | 1.55 |
| 15 | **3** | 0.31 | 0.15 | 0.3622 | 0.0581 | 0.16 | CONS | **9.35** |

**Reading it.** Every **wall-less bare core** (loops = 0) reproduces 191's Part-A
result — non-conservative at ≥ 30 % infill (margin down to **0.99** at 10 mm / 30 %,
the one sub-1.0 point, and it has NO walls). Add the **3 or 5 wall loops the slicer
wraps around every real printed member** and every single point flips **hard
conservative**: the worst *walled* member in the whole table (10 mm, 60 % infill,
only 3 loops) still has true margin **2.19** — 1.5× the certified value — and the
default 5 loops never drops below **2.65**. φ_wall shrinks with width (0.98 → 0.68
at 5→10 mm for 5 loops; 0.75 → 0.44 → 0.31 at 5→10→15 mm for 3 loops), so the
margin falls monotonically with width exactly as 191 predicted — but at the member
widths a topology-optimized part actually contains, it is far from the danger zone.
(K=3 / 15 mm walled tension at 5 loops was already directly measured by 191 Part B,
E_meas/Es = 0.5633; the 15 mm / 3-loop point here is new. The remaining 15 mm rows
were dropped for cost — BLOCKED-STOP below.)

*Direct validation of 191's extrapolation:* my measured E_meas/Es at 10 mm / 5
loops equals 191's Voigt-model value to ~1 % (**0.732** measured vs 191 Part-B
**0.732** at 30 %; **0.718** vs model **0.711** at 15 %). 191's composition physics
is correct; only its **width choice** was wrong for an optimized part.

---

## 2 — BENDING vs TENSION on the same member — `BendAxial.csv`

The SAME prismatic 10 mm wall+core member cross-section (no end caps), measured in
TENSION (axial cube) and BENDING (6-cell beam), each normalized to a **matched
solid** solve of the same grid (so trilinear-hex bias cancels). `r` = stiffness
relative to solid; `margin@1.5` = 1.5·r/f^1.5. 191 measured axial only; this is new.

| loops | φ_wall | infill | r_axial | **margin (ax)** | r_bend | **margin (bend)** | bend/ax margin |
|---|---|---|---|---|---|---|---|
| 0 | 0.00 | 0.15 | 0.064 | 1.65 | 0.054 | 1.40 | 0.85 |
| **3** | 0.44 | 0.15 | 0.488 | 12.59 | **0.714** | **18.43** | 1.46 |
| **5** | 0.66 | 0.15 | 0.691 | 17.83 | **0.895** | **23.10** | 1.30 |
| 0 | 0.00 | 0.30 | 0.081 | 0.74 | 0.070 | 0.64 | 0.86 |
| **3** | 0.44 | 0.30 | 0.501 | 4.57 | **0.722** | **6.59** | 1.44 |
| **5** | 0.66 | 0.30 | 0.697 | 6.36 | **0.897** | **8.18** | 1.29 |
| 0 | 0.00 | 0.60 | 0.347 | 1.12 | 0.296 | 0.96 | 0.85 |
| **3** | 0.44 | 0.60 | 0.665 | 2.15 | **0.812** | **2.62** | 1.22 |
| **5** | 0.66 | 0.60 | 0.804 | 2.59 | **0.934** | **3.02** | 1.16 |

**The sign, both loading modes:**
* **Walled member (loops ≥ 3 — a real printed member): CONSERVATIVE, and bending
  AMPLIFIES it.** In bending the solid perimeter walls sit at the outer fiber, where
  the second moment weights them by distance², so the effective stiffness ratio
  rises above its axial (area-weighted) value in *every* walled case: r_bend/r_axial
  = **1.16–1.46×**. The true margin rises with it (e.g. 3 loops / 15 %: 12.6 → 18.4).
  Bending is **more conservative than tension**, not less.
* **Bare core (loops = 0 — NOT a real member): NON-CONSERVATIVE, and bending
  marginally WORSENS it.** A pure gyroid is slightly less effective in bending than
  tension (r_bend < r_axial, margin 0.85× of axial), so the wall-less limit — 191's
  envelope case — is marginally *more* non-conservative in bending (e.g. 30 %:
  margin 0.74 → 0.64). This is the only direction bending hurts, and it applies to
  the case that does not describe a printed member.

Because the maintainer's parts are **brackets loaded in bending**, the real-world
knockdown error at member scale is governed by the top block: **even more
conservative than the tension numbers in §1.**

---

## A3 — THE DECISION NUMBER, at member scale

**For a part the gate certifies at margin exactly 1.5, the true margin at the WORST
realistic member-scale point (10 mm member, 60 % infill, minimum 3 wall loops):**

| | tension | bending |
|---|---|---|
| **worst walled member** (10 mm, 60 %, 3 loops) | **2.15–2.19** | **2.62** |
| default 5 loops, same point | 2.59–2.65 | 3.02 |
| wall-less bare core, same point (NOT a printed member) | 1.12–1.20 | 0.96 |

**A real optimized member the gate passes at 1.5 truly carries margin ≈ 2.2 in
tension and ≈ 2.6 in bending** — the gate is *conservative* by ~1.5–1.7× at member
scale, in both loading modes. The only way to reach the failure boundary at member
scale is to strip the walls entirely (loops = 0), which no slicer does. Contrast
191's worst ENVELOPE-scale point (200 mm, 30 %, 3 loops): true margin **0.98**. The
decision number is the **width**: ~9.4 mm member → margin ≥ 2.2; ~200 mm solid
cross-section → margin ~1.0.

---

## A4 — RECONCILE WITH 191

**This NARROWS 191. It does not overturn it, and its measurement is not wrong.**

* **What 191 got right, confirmed here.** 191's composition physics (solid walls
  carry load in parallel / as flanges; Voigt rule-of-mixtures) is **correct** — my
  direct member-scale measurements reproduce its model to ~1 % (10 mm / 5 loops:
  0.732 vs 0.732). Its size-dependence is real: margin falls monotonically with
  width in my data too.
* **What changes.** 191 swept its width **W as the ENVELOPE** (up to 200 mm) and
  concluded the maintainer's ~200 mm parts sit past the crossover, margin → ~1.0.
  But an optimized part is not a solid 200 mm bar; it is thin ribs, and the slicer
  wraps wall loops around **each rib** (§3). The width that decides conservatism is
  therefore the **member width (~9.4 mm)**, not the envelope. At member scale every
  real (walled) member is deep in 191's own **conservative** regime.
* **The specific number that decides it.** 191's crossover **W\* ≈ 59 mm (3 loops)
  / 98 mm (5 loops) at 30 % infill** (191 `C_size_crossover.csv`). The min-feature
  **member is ~9.4 mm — 6–10× below W\***. Equivalently, on the true-margin axis:
  191's worst 200 mm point is **0.98–1.13**; my worst *walled member* point
  (10 mm, 60 %, 3 loops) is **2.19** in tension and higher in bending. **9.4 mm vs
  59–98 mm** (or **≥2.2 vs ~1.0**) is the number that decides it.
* **Why NOT overturned.** The gate applies one f^1.5 to the **whole part**
  regardless of local width. Any **envelope-scale solid cross-section** in a part —
  a mounting boss, a thick pad, a near-solid region wider than W\* — still sits in
  191's non-conservative zone. 191's alarm is therefore **valid and unsoftened for
  solid/near-solid regions**; it is simply **not the common case** for the thin
  ribs that dominate an optimized part. The honest fix is width/size-aware (stop
  over-penalizing ribs while still covering thick regions), not a uniform re-tune —
  and, per §3, production currently has **no width term to make aware**.
* **Bending strengthens the narrowing.** 191 measured axial only. The maintainer's
  brackets bend, and bending is *more* conservative on a walled member (§2), so the
  real-world margin at member scale is larger than even the tension numbers above.

---

## HONESTY CAVEATS (what would change these numbers)

1. **Stiffness, not strength** (same caveat as 191). The gate applies f^1.5 to a
   *strength* margin; this measures a *stiffness* knockdown (what a linear FEA
   resolves). The signs are robust — in a wall+core section the solid walls carry a
   disproportionate share of **both** stiffness and peak stress, and in bending the
   outer-fiber walls (highest stress) are solid — so if anything the strength margin
   at member scale is **even more** favorable than the stiffness margin shown. But
   §A3 is a sign-robust estimate, not a strength certificate; printed coupons pulled
   to yield are the physical anchor only the maintainer can generate.
2. **Which width the slicer lays perimeters around is asserted from FDM slicing
   physics, not proven from the repo** (§3) — TopOpt does not slice. A slicer trace
   of an exported optimized STL is the primary evidence and is out of this harness's
   reach. If a slicer were configured with 0–1 perimeters, or a "member" were itself
   envelope-scale solid, the rescue shrinks toward 191's bare-core / envelope limit.
3. **Idealized walls** (as 191): perfectly solid perimeters, gyroid core = slicer
   gyroid, isotropic material, load aligned with the walls. Real inter-bead / inter-
   layer voids and weak z-bonding make a real wall softer than modeled — which would
   *reduce* the member-scale conservatism margin, though not near the danger zone.
4. **Bare-core rows are not real members.** Every sub-1.0 margin in the tables is a
   loops = 0 specimen. A printed member always has ≥ a few perimeters, so those rows
   bound the *wall-less limit* (191's envelope case), not any printable member.
5. **Bending resolution.** The bending sweep runs at vpc = 12 (vs 16 axial) and is
   normalized to a matched solid-beam bending solve, so its <0.4 % trilinear-hex
   bias cancels; bending is wall-dominated, which the coarser core barely affects.

---

## BLOCKED-STOP

A member-scale wall-and-core specimen **is** runnable — the whole point — and the
answer is resolved at W = 5, 10 mm (both fully swept) with a 15 mm confirmation.
What is **not** cheap is the **dilute low-infill porous core at K=3 (48³) and the
K=3 bending beam (36×36×72)**: those grids are not multigrid-coarsenable, so CG
runs 1000–2000 Jacobi iterations at **~7–21 min per solve** (e.g. the 15 mm /
3-loop / 15 % point took 1289 s). The full 15 mm axial column and all 15 mm bending
were therefore dropped after establishing the trend — **not attempted to
completion, and reported here rather than hidden**. They are not needed: 191's Part
B already directly resolved 15 mm walled tension (0.5633), and its Voigt model —
validated to ~1 % against my 5/10 mm points — carries the composition from 15 mm to
200 mm with no new physics. The smallest specimen that *would* add the missing
15 mm bending column is that 36×36×72 dilute beam at ~15 min/solve × 6 rows ≈ 1.5 h;
reported as cost, not run.

---

## COMPLIANCE

* **NO FIX.** The knockdown (`minimize_plastic.cpp:69`, exponent `:66`), the gate
  (`:~1103`), and every default are untouched. This report adds a measurement and
  a decision; it changes no production behaviour.
* **FORBIDDEN — clean.** No `fixtures/`, benchmark, `materials.json`,
  `ARCHITECTURE.md`, `DECISIONS.md`, ROADMAP box, `/app/`, or production default
  was modified. Additive only: this handoff, `evidence/2026-07-26-knockdown-member-scale/`,
  and the standalone harness `knockdown_member_probe.cpp` (not wired into CTest).
* **Reproduce:** from `core/`, build `libtopopt.a`, then
  `c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3
  tests/harness/knockdown_member_probe.cpp build/libtopopt.a -o
  build/knockdown_member_probe`; run with `TOPOPT_MEMBER_CSV_DIR` set to the
  evidence dir. `TOPOPT_MEMBER_ONLY ∈ {selfcheck, axial, bend}` runs a subset.
* **Every number is first-hand.** `evidence/2026-07-26-knockdown-member-scale/`.
