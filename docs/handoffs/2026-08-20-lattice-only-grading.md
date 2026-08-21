# Lattice-only grading — a grading law that means something

**Base commit: `2a96fc69`** (Merge PR #343, "Claude/lattice struts rendering f1a219").
PR 343 was red on arrival — `depthPrepassShaderSource` used `ShellClip` and
`shell_is_latticed`, which are declared only in `viewerShaderSource`, and every
`*ShaderSource` is its own `makeLibrary` call, so the prepass library failed to compile
and took ten GPU tests with it. The maintainer fixed it (`2df03dd8`, hoisting the MSL
into `shellClipMSL` and interpolating it into both); CI went green and it was merged.
Everything below sits on that.

Scope: **the LATTICE-ONLY path** — `mode: "analyze"`, a part latticed with NO topology
optimisation, which is what RUN SIM drives. The TO+lattice path is `minimize_plastic`,
a different function that never reaches the new code.

---

## SECTION 0 — the answers, one line each

**What the density distribution WAS and IS.** Before: 19.07 % of latticed voxels at
`rho_min` (12,561 of 65,871 — every one put there by the band clamp), exactly ONE voxel
at `rho_max`, 45 % in the bottom two bins. After, on his part: **100 % at `rho_min`**
(28,344 of 28,344) — because his part's peak utilisation is 0.000463 and the band floor
is ~100x more material than the load asks for.

**Which allowable, and is the knockdown in it (R9).** The **in-plane** allowable,
`yield / margin_stop` = 55 / 1.5 = **36.6667 MPa**, and the **z knockdown is NOT in it**.
The demand field is von Mises — an in-plane measure — and the gate's in-plane margin is
`yield / von Mises`, so utilisation 1.0 means exactly "in-plane margin == margin_stop".
The knockdown belongs to the interlayer mode, priced from `max_interlayer`, a different
field; folding an unsourced constant into every density would mix two failure modes.
Excluding it does not weaken certification — the interlayer check runs unchanged. The
receipt records `allowable_basis` and `z_knockdown_in_allowable: false` explicitly.

**The self-weight stress on his part (R7).** Solid, under gravity alone: peak
**0.00231 MPa** (median 0.000465, p99 0.00165) = **0.0063 % of allowable**. The same
wall latticed at the band floor carries it in the STRUTS at **0.204 MPa = 0.555 % of
allowable**, a ~180x margin. Self-weight never binds; the printability floor does.
Positive control: the applied body force matched the part's own weight to 1.3e-12.

**What `minimize_plastic` ON and OFF produce (R6).** On his part: **identical** —
28,344 latticed, 100 % at floor, same strut diameter. The switch IS reaching the law
(the receipt shows `utilisation_target` 1.0 vs 0.5), but it cannot express itself when
utilisation is 4.6e-4 and both targets clamp to the floor. **That is the §3(d) finding,
and its cause is the part, not the wiring.**

**What GRADED would cost, with the two gate measurements.** Gate (i), the printable
spacing window at a 0.45 mm nozzle: **1.173–4.931 mm** (4.203x). PASSES. Gate (ii), the
overhang fraction: **REFUTED BY EXPERIMENT** — the maintainer printed a traced coupon
with a 41.78 mm longest unsupported run, supports off, and it came out clean. See
`evidence/2026-08-20-lattice-only-grading/r4b_PRINT_RESULT.md`.

---

## THE METHOD

### §0 — the law

`core/src/simp/grading.cpp`, `rho_of()`. One arithmetic, two denominators:

    ABSOLUTE : frac = (demand / allowable) / utilisation_target     [new, opt-in]
    PEAK     : frac = demand / demand_max                           [default, unchanged]
    rho      = rho_max * frac^gamma, then the SAME band clamp

Armed by `GradingLawParams::demand_allowable_mpa > 0`. **0.0 is the default and is the
peak-relative law byte-for-byte**, which is what makes §5(a) structural rather than a
promise: `run_job`'s `minimize_plastic` path never sets the field.

**Why the old law is wrong, measured.** Dividing by the part's own peak makes the grade
INVARIANT TO LOAD MAGNITUDE. Scaling his declared load 2161.5x (peak von Mises 0.017 →
36.67 MPa) produced a **byte-identical** lattice — all twenty bins equal, verified by
`diff`. The two laws coincide EXACTLY at peak utilisation 1.0, which is the same
statement said forwards: the old law is the new one under the assumption that every part
is loaded to precisely its allowable.

**Positive control (the arm that proves the law works).** Re-run at peak utilisation
1.0, the new law reproduces the old distribution exactly — 31.92 / 13.19 / 10.38 / …,
65,871 latticed, 19.07 % at floor. Agreement where they must agree; divergence in
proportion to how far below the allowable a part sits.

**§0(b) — over the allowable.** Clamped at 1.0 and **counted** in
`over_allowable_voxels`, reported on the receipt. Not refused: refusing would make the
grading law the gate, and the gate is `analyze_fixed_design`, which already prices an
over-allowable part and rejects it on margin. But it can never read as "dense and fine".

### §1(c) — the sub-floor predicate, checked deliberately (R5)

**Unchanged, and that is the finding.** The predicate is `region peak / PART peak` — a
ratio of two peaks OF THE SAME FIELD. It never read the density normalisation, so moving
that normalisation leaves it bit-identical. Checked in code, not assumed.

**But it inherits the same defect.** Being a ratio it is scale-free: a region at 5 % of
part peak is at 5 % whether the part carries 22 N or 48 kN. It cannot distinguish "quiet"
from "the whole part is quiet" — on his part every region is unloaded in absolute terms
and this predicate cannot say so, because something is always at 100 % of the peak.

### §2 — unloaded walls, absolutely

So §2 adds an **absolute** test alongside it (never replacing it): a region also
qualifies when its own peak sits below **1 % of the allowable**
(`kUnloadedUtilisationMax`). **The threshold is measured, not picked** — self-weight at
the band floor is 0.555 % of allowable, so 1 % clears the measured demand with ~2x
headroom at the lightest lattice the band permits. The printability floor is untouched:
self-weight relaxes the STRUCTURAL requirement, never the MANUFACTURING one.

On his part **all 28,344 latticed voxels qualify as unloaded** — the entire part is
certified on self-weight alone, and `unloaded_voxels` says so on the receipt.

### §3 — the goal is the existing checkbox

`utilisation_target` is the utilisation at which the lattice reaches `rho_max`.
ON = 1.0 (work the whole allowable, least plastic). OFF = **0.5**
(`kSturdyUtilisationTarget` — reach full density at half the allowable, ~2x the material
for the same field). A number, not a mood. Driven by `job.loads.minimize_plastic`, the
control the user already sets; no second switch.

### R1 / R4 — what the receipt now carries

The analyze receipt did **not** report `clamped_lo_voxels` / `clamped_hi_voxels` at all
before this task — a clamp could decide the posture with nothing in the record. It does
now, on every graded receipt, plus a **fixed-bin density histogram** (20 bins across the
band), `density_at_floor_voxels`, `max/median_utilisation` and the allowable's basis.
Deterministic by construction: one pass in voxel order, a full sort for the median, no
sampling (bar §1b).

---

## BARS

| bar | status |
|---|---|
| R1 distribution before/after on his part | **done** — 19.07 % → 100 % at floor, plus the scaled positive control |
| R2 core and app agree on demand | ✗ **NOT DONE** — see below |
| R3 determinism, same job twice | **done** — grading blocks identical, `fields.bin` SHA-256 match |
| R4 clamps still counted | **done** — and newly present on the analyze path at all |
| R5 sub-floor predicate's new behaviour | **done** — unchanged, checked, and stated why |
| R6 `minimize_plastic` ON vs OFF | **done** — identical on his part, with the cause |
| R7 self-weight number | **done** — 0.00231 MPa solid, 0.204 MPa in struts at the floor |
| R8 TO+lattice byte-identical | **structural** — the field is set only on the analyze path |
| R9 which allowable, knockdown in or out | **done** — in-plane `yield/margin_stop`, knockdown OUT, recorded |
| R10 no weakened assertions | **done** — additive only; no assertion removed or loosened |
| R11 cost measured on Release | build is `CMAKE_BUILD_TYPE=Release`; no wall-clock claim is made |
| R12 no placeholders, no root scratch | **done** — `unloaded_voxels` wired rather than left declared |

---

## ★ WHAT IS NOT DONE, PLAINLY

* **§1(e) / R2 — the app demand mirror is NOT bridged.** `LatticePreviewOccupancy
  .demand(like:field:)` still divides by `field.peak()?.valueMPa`, i.e. it still runs
  the PEAK-RELATIVE law. **Core and the preview now disagree by construction**, which is
  precisely the drift R2 exists to prevent, and it is the highest-priority follow-up.
  Core exposes what is needed: the allowable is `yield / margin_stop`, and
  `SimAnalysisResult` already carries `marginRequired`.
* **§4(a) — STEPPED is not shipped.** The dyadic ladder exists and is FEA-driven, but no
  user-facing Lattice Settings option was added.
* **No new unit tests** were written for the utilisation law. The existing suite was run
  as a regression check.

---

## ★ THE FINDING THE MAINTAINER SHOULD READ FIRST

**The absolute law makes his part WORSE, and that is the correct answer.**

His stand is ~2000x stronger than it needs to be: worst-case margin 3242 against a
required 1.5, peak utilisation 0.046 %. Under the old law a stress concentration set the
scale and everything else was graded relative to it, which produced a spread that LOOKED
like a response to load and was not — the same spread appears at 22 N and at 48 kN.
Under the new law the honest answer is that the load cannot drive this lattice at all:
every voxel wants ~0.0005 relative density, the band floor is 0.0505, so everything
clamps to the floor and 57 % fewer voxels can be latticed at all (28,344 vs 65,871,
because uniform floor density forces coarser cells through the printability floor).

So "5 % no matter where I click" was **right**, and it is right for a reason the
receipt can now state: this part is at 0.05 % of what the material can take. What
should change is not the number but what governs it — on a part like this the lattice is
set by the printability floor, self-weight and the goal, and the law now says so instead
of implying a load response that was never there.

**The lever that would actually help him is a lower band floor**, not a different
normalisation: `lattice_rho_min` = 0.0505 is 100x what his load needs.

---

## PLAIN LANGUAGE

The old rule set the lattice by comparing each spot to the single most stressed spot in
the whole part. That sounds sensible and is not, for two reasons. The busiest spot is
usually a corner or a bolt hole carrying several times what the rest of the part sees, so
dividing by it squashes everything else toward the minimum — which is why tapping around
the model kept showing 5 %. And because it only ever compares the part to itself, making
the load a thousand times bigger changes nothing at all. We checked: at 2161 times the
load, the lattice came out identical, down to the last strut.

The new rule compares each spot to what the plastic can actually take. Now "30 %" means
this region is at thirty percent of the material's strength — a real statement, the same
on Monday as on Friday, and the same on two different parts.

On his stand the honest answer turns out to be uncomfortable: the part is about two
thousand times stronger than it needs to be, so every spot is at roughly a twentieth of
one percent of what the plastic can take. The lattice therefore drops to its minimum
everywhere. That is not the new rule failing; it is the new rule finally saying out loud
what the old one was hiding. What actually decides this lattice is how thin a strut the
printer can draw, the weight of the lattice itself, and whether he asked for "as little
plastic as possible" — not the load. We measured the self-weight too: a wall at the
lightest lattice we allow carries its own weight at about half a percent of the material's
strength, roughly a 180-fold margin, so that never decides anything either.

The thing that would genuinely give him a lighter part is lowering the minimum density
the lattice is allowed to use. Today that floor is about a hundred times more material
than his load calls for, and no change to the comparison rule can get around it.

One honest gap: the on-screen preview still uses the OLD rule, so what the app draws and
what the core builds now disagree. That needs fixing next, and it is the first item in
the follow-up list.

---

# AMENDMENT — TWO GRADING INTENTS

PR 344's law is right and stays. It answers "is this strong enough", and on a part that
needs no lattice the answer is "yes, everywhere" — which is why his went 100 % to the
floor. The maintainer then stated the actual use case: **the lattice is usually there to
be SEEN**, and he still wants it to grade with the stresses. That is a different
question — "where is this part working hardest" — and it wants a RELATIVE grade.

So the intent is now explicit, with two values. One line each, as asked:

* **The density histogram in aesthetic mode on his part, two ranges.** Over
  [0.20, 0.60]: `0 0 0 47 18 9 6 5 3 2 2 2 6` percent across the band, **0.00 % at the
  floor**, 91,575 latticed. Over [0.10, 0.35]: confined to the narrower range, mean
  density 0.1548 against band B's 0.2783 — **1.8x apart, so the range parameter is
  demonstrably live**. `100 % at floor` does not recur.
* **Whether `minimize_plastic` ON and OFF differ there, and by how much.** They do:
  mean density **+42 %** and derived mass **+63 %** over [0.20, 0.60]; **+48 %** and
  **+60 %** over [0.10, 0.35]. It is a band POSITION in aesthetic mode — an exponent on
  the normalised field, so both ends of the range are preserved and only the mass
  between them moves.
* **Which percentile, and how many clamped above it.** The **95th** — the max IS the
  outlier the old law tripped on, and 95 discards more than a stress concentration
  occupies while still being driven by loaded material. On his part p95 = 0.00830279 MPa
  and **5,546 voxels** sit above it; they clamp to the top of the range and are counted
  in `above_percentile_voxels`.
* **The CLI invocation that drives it.**
  `topopt-cli analyze jobs/aes_bandB_on.json --out amend_aes_bandB_on`, with
  `grading.intent`, `grading.aesthetic_rho_min/max` and the existing
  `loads.minimize_plastic`. No new control anywhere; `git diff --stat` on `app/` is the
  mirror and nothing else.
* **Structural mode is unchanged.** Every PR-344 receipt field compares equal; the only
  added key is `"intent"`.

★ **A DEFECT THIS SURFACED, NOT FIXED:** `intent: aesthetic` over the FULL band in
SWEPT cell mode fails `plan_cell_sizes: level assignment is not an aligned octree`. It
needs a field that BOTH reaches the density floor AND spans nearly the whole band —
[0.10, 0.90] and [0.0505, 0.35] both pass, [0.0505, 0.8999] fails. The old law's low
tail CLAMPED to `rho_min`, making blocks uniform by accident; the aesthetic grade
removes that plateau. It lives in `cell_plan.cpp`, shared with the TO+lattice path, so
fixing it here would risk §6(c)'s byte-identity. **The default aesthetic range is the
full band, so this is reachable by default in swept mode and must be fixed before
aesthetic reaches the UI.**

## PLAIN LANGUAGE (amendment)

There are two different questions you can ask a stress field, and we were only answering
one. "Is this strong enough?" compares the part to what the plastic can take — and on a
part that is two thousand times stronger than it needs to be, the answer is "yes,
everywhere", so the lattice sensibly drops to its minimum. That is correct, and useless
if what you wanted was to SEE the stresses.

The other question is "where is this part working hardest?", and that only ever compares
the part to itself. The old law asked that question badly: it divided by the single
busiest voxel, which is usually a corner carrying several times what anything else sees,
so everything else got squashed flat. Divide by the 95th percentile instead — ignore the
loudest one in twenty — and the same comparison produces a real, visible pattern. On his
part nothing sits on the floor any more, and the density spreads properly across
whatever range you hand it.

The "use less plastic" checkbox still works, and now means something in both cases. When
the lattice is structural it decides how hard to work the material. When it is
decorative it decides how heavy the same pattern is drawn — the shape does not change,
just how much plastic expresses it. On his part that is a 42–48 % swing in average
density.
