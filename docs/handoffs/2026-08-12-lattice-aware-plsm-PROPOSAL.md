# PROPOSAL — making the level set LATTICE-AWARE, with the lattice in the objective rather than downstream

★ **A design proposal, not a change.** No code is written and
`git diff main -- core/src core/include app/` stays empty. It answers a direct
question: *can the optimiser itself make space for a lattice, with or without one
requested, rather than having the lattice stamped in afterwards?*

★ **The short answer is yes, the literature has a mechanism for exactly this, and
this repository already contains most of the machinery — but NOT the one you would
reach for first.** The homogenisation route is blocked here for a reason that is
measurable in one line. §2.

---

## 1. THE FOUR FAMILIES IN THE LITERATURE

**(A) Coating / shell-infill.** Clausen, Aage & Sigmund (2015) design a solid
shell and a porous interior as one problem, separating "base structure" from
"coating" and deriving the shell from the gradient of a filtered density field.
Wu, Clausen & Sigmund (2017) extend it to shell-infill composites for AM.
★ Gives you a skin for free, which matters here because `obl_cad_rms_mm` is
measured against CAD faces and a porous skin would wreck it.

**(B) ★ LOCAL VOLUME CONSTRAINTS.** Wu, Aage, Westermann & Sigmund,
*Infill Optimization for Additive Manufacturing — Approaching Bone-like Porous
Structures* (IEEE TVCG 2018, arXiv 1608.04366). **Upper bound on the material
volume in the neighbourhood of EVERY voxel**, the per-voxel constraints aggregated
by their p-norm into one global constraint so the optimisation stays cheap. The
result is trabecular-bone-like porous infill that is *"lightweight and robust with
respect to material deficiency and force variations"*.
★★ **This is literally "the optimiser must leave room everywhere". It is the
mechanism the question is asking for.**

**(C) Homogenisation + de-homogenisation.** Allaire, Geoffroy-Donders & Pantz
(*Comput. Math. Appl.* 78, 2019, 2197–2229; and the 3-D companion in *J. Comput.
Phys.* 401, 2020, 108994). Optimise a *homogenised* cell — density, aspect,
ORIENTATION — as a cheap parametric problem, then project the optimal
microstructure at a chosen length scale. Their 2-D novelty is a conformal
treatment of orientation that **preserves the angles between cell members** while
the cell is modulated and oriented across the domain. ★ This is the family the
lattice track's own Phase-0 no-go already named as *"the only honest structural
route (Road B = M8 homogenization)"*.

**(D) Concurrent multiscale with level sets.** An active line — sandwich
structures with periodic lattice infill via multiscale level sets; velocity-field
level set coupled with SIMP for coated structures with bi-material lattice infill
(Hu et al., *IJNME* 2025); parametric level sets used for feature evolution in
concurrent lattice optimisation so that assembly holes and cooling channels stay
explicit. ★ Their recurring difficulty is **connectivity between adjacent cells**,
handled by sigmoid/hybrid transition strategies.

## 2. ★★ WHY THE OBVIOUS ROUTE (C) IS BLOCKED HERE, IN ONE LINE

`core/src/cli/run_job.cpp:3105`:

```cpp
if (options.multiscale_lattice) gp.prescribed_relative_density = &dens;
```

Multiscale reads the design density **by magnitude**. The classic lattice law does
not — every one of `grade_lattice`'s reads is the MASK `density[e] > iso`, and the
relative density that sets strut radii comes from the von Mises demand field.

★ **A level set has no magnitude to give it.** Measured on this task's own arms:

| arm | voxels with 0.02 < ρ < 0.98 |
|---|---|
| V0_none | 9,213 of 468,224 — **1.97%** |
| V1_perim1 | 4,293 of 468,224 — **0.92%** |

**98–99% of a PLSM design is exactly 0 or exactly 1**, by construction. Prescribing
lattice density from it asks for fraction 1.0 in the solid and 0.0 in the void:
multiscale becomes a no-op that costs a homogenised tensor solve. **PLSM and
multiscale are two answers to the same question** — macro holes resolved
explicitly, versus sub-voxel lattice homogenised — and running both changes
nothing.

## 3. ★★ THE MECHANISM I PROPOSE, AND WHY IT FITS A LEVEL SET UNUSUALLY WELL

**Family (B), a local volume constraint, with its bound set to the LATTICE's own
relative density.**

    for every voxel v:   mean over a ball of radius R of rho  <=  alpha

aggregated by p-norm into a single constraint. Read it as: *no neighbourhood
anywhere may be more than α full*, i.e. **every region of the part is guaranteed
latticeable at density α.**

★★ **AND IT ANSWERS THE "WITH OR WITHOUT A LATTICE" REQUIREMENT WITH ONE
NUMBER.** α = 1.0 is no constraint at all and reproduces today's behaviour
exactly; α = the requested lattice density makes the run lattice-aware. It is a
continuous dial between the two modes, not a second code path. **A no-lattice job
is the α = 1 special case of the lattice job**, which is the property the question
actually asks for.

★★★ **AND HERE IS THE PART THAT IS SPECIFIC TO A LEVEL SET, AND IS THE REASON I
THINK THIS IS WORTH DOING.** On SIMP, a local volume constraint produces
INTERMEDIATE density — grey infill that then needs interpretation. **On a level
set it cannot**, because ρ is 0 or 1. The only way a level set can satisfy "no
neighbourhood more than α full" is to **carve actual, explicitly-resolved pores at
the constraint's length scale.**

**So the optimiser generates a real porous structure, as geometry, with no
homogenisation, no de-homogenisation, and no graded density field.** The
lattice-vs-structure distinction collapses: there is one field, it is printable as
it stands, and the pores are placed by the objective rather than stamped by a
generator. That side-steps family (D)'s connectivity problem entirely — there are
no cells to connect, because there are no cells.

### why this repository is unusually ready for it

| what it needs | what already exists |
|---|---|
| a neighbourhood average and its adjoint | ★ `core/tests/harness/plsm_filter.hpp` — the Helmholtz filter built for `plsm-restriction-operator`. `(I − r²∇²)ρ̃ = ρ` IS a neighbourhood average, it is **self-adjoint** so the gradient is the same solve, per-axis radii (R5), and it costs a measured **12% of a run**. It lost as a restriction operator and is currently unused. **This is the same operator the constraint needs.** |
| a length scale below which the design cannot wiggle | the RBF knot lattice. φ = Σ αᵢψᵢ cannot express features below the knot spacing, so **the basis already bounds the minimum pore size** — the lattice scale is a first-class design parameter rather than a filter artefact. |
| strut-thickness regularisation | `--perimeter C`, already measured: at the matched volume it takes internal surface +20.3% → +7.1% at margin parity. |
| a drainability check | `plsm_topology.hpp` + `sealed_void.py`, both written this week. |
| a homogenised tensor if we ever want route (C) | shipped in PR #257. |

## 4. THE PLAN, PHASED, WITH A KILL CRITERION AT EACH STEP

**Phase 0 — the cheap refutation first (½ day).** Before any constraint is
written: take the best current arm and ask the lattice pipeline whether it can
already do this. Run `lattice-variant` on `V1_perim1` at the target density and
record the refusal reasons. ★ **KILL IF** it lattices cleanly — then the macro
optimiser needs no lattice awareness and this whole proposal is unnecessary.
*Prior: it will NOT lattice cleanly. Production §5 records a PLSM design refused
for 337 mm³ of sealed void, where SIMP's design at the same rung was accepted
first time; `sealed_void.py` measures 7,974 mm³ still sealed in V1_perim1.*

**Phase 1 — the constraint, unconstrained-equivalent first (1 day).** Implement
the p-norm-aggregated local volume constraint over the existing Helmholtz filter.
★ **The first test is that α = 1.0 is BYTE-IDENTICAL to today**, the C0 inertness
control this project already uses. Anything else means the constraint is not
inert when off, and the with/without-lattice claim is false at the first step.

**Phase 2 — one arm, α = the lattice density, at the MATCHED volume (½ day).**
Rung 0.7973, everything else as V1_perim1. Report the full instrument set:
`n_cut`, carved, `obl_cad_rms_mm`, certified margin, sealed void, and pore size
against the printer's 4.50 mm wall-stack fill limit. ★ **KILL IF** the margin
falls below SIMP's 3254.34 — that is the bar four mechanisms have already failed
(filter r=2, filter r=3, the robust triple, the stress seed) and there is no
reason to exempt this one.

**Phase 3 — the constraint machinery (1 day, only if Phase 2 survives).** The MMA
here handles ONE constraint and the volume is held by bisection on the offset, not
by MMA. A second constraint needs either an augmented-Lagrangian term on the local
violation (cheap, approximate) or extending `plsm_mma_update` to m = 2 (correct,
more work). ★ Start with the Lagrangian; the p-norm aggregation is already an
approximation, so exactness in the multiplier buys little.

**Phase 4 — the skin (1 day).** A local volume constraint will happily make the
outer surface porous, which destroys `obl_cad_rms_mm` and every CAD-accuracy claim
this project has. Family (A)'s coating idea is the fix: exempt a shell of depth d
from the constraint, reusing the CAD-derived frozen machinery already built for
`--frozen-cad` (100.0000% mask agreement with core's own predicate).

**Phase 5 — only then, route (C).** If a graded field is ever wanted, the
homogenised tensor exists. But note it would require **abandoning the level set's
binary field**, which is the representation the last five tasks have been about.
That is a strategic decision, not an increment.

## 5. THE RISKS, NAMED

1. ★★ **Resolution.** An explicitly-resolved pore needs voxels. At 1.705 mm this
   grid gives ~3–6 voxels per 5–10 mm cell, and the lattice track's own Phase 0
   found a resolved printable lattice needs **44–276× the LAN memory ceiling**.
   **This proposal only works in the coarse-pore regime** — pores of a few voxels,
   not a printable strut lattice. If the target cell is 5 mm it is marginal; if it
   is 1 mm it is impossible and route (C) is the only option.
2. **It fights the surface objective.** Forcing porosity everywhere ADDS interface
   by construction. The last month has been spent removing interface. These are
   opposed objectives and the trade must be priced, not assumed.
3. ★ **The margin may not bind, which cuts both ways.** At rung 0.7973 all four
   arms certified within 0.2%, so there is headroom to spend. But a margin that
   cannot move also cannot confirm safety, and a lighter rung may bring it back.
4. **p-norm aggregation is approximate.** It bounds a soft-max, not the true max;
   local violations survive. Wu et al. accept this; so should we, and report the
   true max alongside.

## 6. IN PLAIN LANGUAGE

Today the lattice is stamped in after the shape is decided, so the shape has no
idea it is coming. **The fix in the literature is to give the optimiser a rule
that says "you may never fill any small region completely"** — so it is forced to
leave room everywhere, and what it leaves room for is the lattice. Wu and
colleagues showed that rule produces structures that look like the inside of a
bone, and are light and unusually tolerant of damage.

★ **The nice accident is that this rule behaves differently on our method than on
the old one, and in our favour.** The old method would respond by making the
material half-dense — a grey smear somebody has to interpret afterwards. Ours
cannot do that: it only knows solid and empty. **So it responds by actually
carving the holes** — real geometry, printable as it stands, placed where the
structure wants them rather than on a grid we imposed.

**And it is one number.** Set it to "completely full is fine" and you get exactly
today's behaviour, bit for bit. Set it to the lattice's density and the run is
lattice-aware from the first iteration. There is no second mode to maintain.

**The honest catch is size.** The holes have to be big enough for our grid to
draw — a few voxels across. That is fine for a coarse internal lattice and
hopeless for a fine printed one, and the project has already measured exactly how
hopeless: a fully resolved printable lattice needs tens to hundreds of times more
memory than the machine has. So this buys the coarse case, not the general one,
and I would rather say that now than after a week of work.
