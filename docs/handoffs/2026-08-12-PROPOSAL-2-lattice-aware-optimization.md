# PROPOSAL 2 — the lattice as a MATERIAL the optimiser can choose, not a finish applied afterwards

★ **This supersedes `2026-08-12-lattice-aware-plsm-PROPOSAL.md`**, which answered
a different question. That document proposed a local volume constraint producing
uniform porous infill everywhere. **That is not what is wanted and it is not what
this proposes.** The earlier file stays for the literature survey in its §1 and
for the one-line blocker in its §2, both of which still hold. Its §3 mechanism is
withdrawn.

★ **A proposal, not a change.** `git diff main -- core/src core/include app/` is
empty and stays empty.

---

## 0. THE REQUIREMENT, RESTATED IN THE TERMS I WILL USE

Two cases, one mechanism:

**(a) DECLARED.** *"The user wants a lattice at this wall."* The optimiser must
solve with that wall's real properties — lattice stiffness, lattice mass — and
reallocate the freed weight elsewhere, during the run.

**(b) DERIVED.** *"This wall must be kept. The cheapest way to keep it is to
lattice it."* The optimiser must be able to decide that a non-designable region
should be lattice rather than solid, reserve it, and take the weight from
somewhere else.

★ Both reduce to the same missing capability: **a region whose material model is
the lattice's, inside the mass budget, that the optimiser plans around.**

---

## 1. ★★ HALF OF THIS IS ALREADY BUILT, AND THE HALF THAT IS MISSING IS SPECIFIC

From `2026-08-04-protect-freeze-vs-solidity`:

> `MaskValue` constrains the OPTIMIZER; solid-vs-lattice is decided downstream by
> `LatticeBoundary` + `lattice_certification_mask` from density + clearances +
> include/exclude roles. `run_job.cpp` never reads the design mask for geometry or
> the cert mask. **So include-over-frozen ALREADY latticed and exclude-over-frozen
> ALREADY kept solid** — no new tag, flag or mask was needed.

★ **You can already mark a wall "keep" and have it come out latticed.** The two
concepts were deliberately separated and the plumbing exists.

★★ **WHAT IS MISSING IS THE FEEDBACK.** A frozen region is, to the optimiser
today:

| | today | what it should be |
|---|---|---|
| stiffness in the FEA | **full solid** | homogenised lattice tensor at density *f* |
| mass | **full solid** | *f* × solid |
| volume budget | **outside it** | **inside it** |
| sensitivity | zero | zero (unchanged — it is still not a design variable) |

**So if that wall is going to be latticed downstream, the optimiser spent the
entire run solving against the wrong material model for it, and never received the
freed mass to spend elsewhere.** That is the whole defect, and it is four fields.

## 2. THE PRIZE, ON THE ACTUAL PART

| | |
|---|---|
| part | 110,904 voxels |
| printed at rung 0.7973 | 88,423 |
| ★ **frozen — the optimiser may not touch it** | **40,216 = 45.5% of printed mass** |
| frozen mass | **247.3 g** of 543.7 g |
| optimisable mass | 296.4 g |

| if the frozen region were latticed | mass saved | of total |
|---|---|---|
| at density 0.5 | 123.6 g | 22.7% |
| at density 0.4 | 148.4 g | 27.3% |
| ★ **at density 0.3** | ★ **173.1 g** | ★ **31.8%** |
| at density 0.2 | 197.8 g | 36.4% |

★ **For scale: the volume-convention error that reframed four tasks was 80 g.
This is more than twice that, sitting in a region the optimiser is currently
forbidden to reason about.**

## 3. ★ WHY IT MUST BE IN THE LOOP — measured here, not argued

**The frozen wall is load-bearing, and the optimiser already leans on it.**
`frozen_buttress_probe` (task `2026-08-04-protect-freeze-vs-solidity`, item 9)
measured that a frozen region's zero sensitivity does **not** starve its
neighbours — the adjoint still carries its compliance contribution into adjacent
voxels:

| vf | config | wall peak vM |
|---|---|---|
| 0.15 | wall FROZEN | 7.98 |
| 0.15 | wall ACTIVE | **11.70** |
| 0.08 | wall FROZEN | 7.98 |
| 0.08 | wall ACTIVE | **20.56** |

and at vf 0.08 the optimiser places **94% of everything it places within 5 mm of
the wall**.

★★ **So latticing that wall removes stiffness exactly where the structure is
leaning hardest, and the optimiser must respond by re-placing material nearby —
using the 173 g it just freed.** That is a genuinely coupled decision. Doing it
downstream gets it wrong in both directions at once: the structure was built
against a stiffness that will not exist, and the weight budget it could have spent
was never offered.

★ **This is the measurement that justifies the whole proposal.** Without the
buttressing result, "lattice it afterwards" would be defensible.

## 4. ★ THE PRECEDENT THAT SETS THE DISCIPLINE

Per-region material manipulation has been tried on this part and it broke its own
pre-registered budget. From `subfloor-per-region-blocked`:

> Committed before any code: aggregate cap **3.0%** of the printed set,
> certified-margin bound **0.10%**. Measured after: a **single** region at
> **2.889% exposure — INSIDE the cap** — moved the composite margin **+0.1801%,
> 1.8× the bound.** Pre-stated rule: report it, don't retune.

That mechanism (`region_ids` in `GradingLawParams`) is implemented, unit-tested,
and shipped **OFF** for exactly that reason.

★ **Two things carry forward.** First, **per-region changes on this part move the
margin more than estimated** — budget accordingly. Second, **the pre-registration
discipline is the reason we know that**, and this proposal must use it: bounds
committed before any arm runs, and a miss reported rather than retuned.

## 5. THE MECHANISM

★ **The key realisation: this is a small combinatorial problem over a handful of
regions, not a continuous topology optimisation.** There are not thousands of
design variables — there are a few declared or frozen regions and a few candidate
densities. That is what makes it tractable without any of the multiscale
machinery.

### 5.1 the one real code change — a region material model

Add, per region, a `RegionMaterial { kind: Solid | Lattice(f, topology), }`.
Where it is `Lattice(f)`:

- **FEA**: use the homogenised tensor at density *f*. ★ Shipped in PR #257 —
  `fea_solve_cg_lattice_matfree`, the combined-block three-block operator, with
  the cubic tensor. **This exists and is production-wired.**
- **Mass and budget**: count *f* × solid, and move the region **inside** the
  volume budget so the saving is available to the rest of the domain.
- **Sensitivity**: still zero. ★ The region is not a design variable — the
  optimiser plans *around* it, which is exactly the asked-for behaviour and is
  much weaker than making it designable.
- **Knockdown**: `knockdown_spec_for` already builds the width-aware composite;
  it must see the region's lattice, not the solid envelope. ★ `lattice-phase0`'s
  M5 recorded the failure mode to avoid: *"default `infill_percent=100` →
  knockdown 1.0 → gate certifies the SOLID envelope margin, but the lattice is
  5–12× more compliant"*. **Named there, and this is where it must be fixed.**

### 5.2 how case (b) decides — by measurement, not heuristic

For each candidate region × each candidate density, run the certified analysis.
With ~5 regions × ~4 densities that is **~20 certified runs — hours, not an
algorithm** — and the output is a table of (mass saved, margin delta) per
assignment. Choose the assignment that maximises mass saved subject to the margin
bound.

★ **The assignment is then evidence rather than a guess, which is the whole
difference from "optimise then infill."**

### 5.3 the loop

    assign regions -> optimise the remainder at the higher rung the freed mass
    allows -> certify -> if the margin bound is missed, step the densest region
    up one level and repeat

Two or three passes. Not a coupled optimisation, and it converges because each
pass either meets the bound or removes one candidate.

## 6. PHASES, EACH WITH A KILL CRITERION

**Phase 0 — refute it cheaply first (½ day).** Run `lattice-variant` on
`V1_perim1` with the frozen wall in the include role, at density 0.3, and certify.
★ **KILL IF** the margin holds with no reallocation at all — then the coupling in
§3 does not bite on this part and the loop is unnecessary. *Prior: it will not,
because the buttressing measurement says the wall carries load and the design was
built assuming it was solid.*

**Phase 1 — pre-register the bounds (1 hour, before any code).** Per §4: the
certified-margin bound and the mass-saving target, written to
`evidence/…/r0_preregistration.md` and committed **before** the first arm.

**Phase 2 — the material model, inert first (1–2 days).** Implement
`RegionMaterial`. ★ **The first test is that `Lattice(f=1.0)` is BYTE-IDENTICAL to
Solid** — the C0 inertness control this project uses everywhere. If it is not, the
model is wrong before any result can be trusted.

**Phase 3 — the assignment table (½ day of machine time).** §5.2. Report every
cell, including the ones that fail.

**Phase 4 — the loop, two passes (1 day).** §5.3. ★ **KILL IF** the certified
margin misses the pre-registered bound and the only fix is retuning the bound.

**Phase 5 — the drainability gate.** A latticed frozen region must still let
powder out, and PLSM designs already fail this: production's lattice step refused
one over 337 mm³ of sealed void. Use the **manufacturing** definition
(`sealed_void.py`, frozen counted as solid), not `plsm_topology.hpp`'s
`in_region`, which scores a pocket walled in by a bolt boss as drainable.

## 7. THE RISKS, NAMED

1. ★★ **The homogenised tensor must be valid at the region's cell count.**
   `lattice-phase0` M3 found scale separation passes for TPMS at 1–3 cells but a
   9.4 mm member at a 5 mm cell is **~1.9 cells across — marginal**. A frozen wall
   10 mm thick at a 5 mm cell is 2 cells. **The homogenisation assumption is at
   its limit exactly where this proposal wants to use it**, and that must be
   checked per region rather than assumed.
2. ★ **The margin will move more than estimated.** §4, measured: 1.8× a
   pre-registered bound from a single 2.9% region.
3. **`f^1.5` is wrong and non-conservative.** `lattice-phase0` M2 measured the
   Gibson-Ashby gap at 23–52% with a fitted exponent near 2.0, **over-predicting
   stiffness**. The width-aware composite knockdown exists precisely for this and
   must be the path used.
4. **Case (a) and case (b) have different failure modes.** (a) is a user
   instruction and can only be wrong about *how much* weight is freed. (b) is the
   algorithm making a structural decision, and a wrong one silently produces a
   part that certifies against a stiffness it does not have. **(b) needs the
   drainability gate and the certified re-run; (a) does not.**

## 8. IN PLAIN LANGUAGE

Right now the lattice is decided after the shape is finished, so the shape never
knew it was coming. Worse, **almost half the metal in this part — 247 grams of
544 — sits in regions the optimiser is forbidden to touch at all.** It cannot make
them lighter and it cannot spend their weight elsewhere.

**Turning those regions into lattice instead of solid is worth about 173 grams,
roughly a third of the part.** For comparison, the measurement error I spent
yesterday correcting was 80 grams.

★ **But it is not free, and this project has already measured why.** Those kept
walls are carrying load — when one is present, the optimiser puts 94% of a tight
material budget right next to it. Lattice the wall and you take stiffness out of
exactly the place the structure is leaning. **Which is the argument for doing it
inside the optimisation instead of after: the optimiser needs to know, so it can
put the freed weight back where the wall stopped helping.**

The good news is that most of the parts exist. The ability to mark a wall "keep"
and have it come out latticed is already there. The lattice's stiffness maths is
already there and production-wired. **What is missing is telling the optimiser the
truth about those regions** — four fields: stiffness, mass, budget, and knockdown.

★ **And one warning from our own history.** The last time regions were given
different densities here, a single small region moved the certified strength
**1.8× further than the budget written down in advance** — and the honest response
at the time was to report it and ship the feature switched off. The same
discipline applies: **write the limits down before running anything, and if it
misses, say so rather than moving the line.**
