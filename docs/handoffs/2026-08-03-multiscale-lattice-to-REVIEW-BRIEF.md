# Review brief — multiscale lattice TO (`claude/multiscale-lattice-to-11d898`)

**Decision needed before this goes further. The feature is built and correct, and
the measurement says it makes the thing it was built for WORSE.**

## What was asked

The two-step pipeline is structurally broken: `minimize_plastic` optimizes assuming
solid material (SIMP, penalty 3.0), the lattice pass then can't fill members thinner
than the cells-per-member floor, and 99–100 % of every lattice region fell back to
solid on the maintainer's real run (`M2_verticalStand`, 128³: **0 / 82 / 472**
latticed voxels of ~10,500). The task: make the optimizer place the lattice while it
grows the shape — replace ρᵖ·E₀ with the measured homogenized tensor C(ρ) inside the
lattice region, behind a named production constant, library-default OFF.

## What was built (all in `core/`, ~1,100 lines)

C(ρ) promoted to production reading its rows from core rather than a transcript;
the SIMP loop's material law and its exact three-block sensitivities; the
feasible-set projection with its volume charge reported not absorbed; the
cells-per-member floor measured live per iteration; and the `/*lattice=*/nullptr`
gap closed so the per-rung certification solves the composite object. Four
loop-vs-export coherence bugs were found and fixed on the way (grading re-deriving ρ
from stress; the printed set defined at ρ>0.5, which deletes real lattice material;
the band clamp latticing voxels the design made solid; the re-certification reading
the design at the wrong threshold).

**Verified:** dC/dρ vs central differences **9.6e-9**; dc/dρ through the whole loop
**3.1e-7** (better than the classic path's 1.0e-6 on the same fixture); three-block
identity **1.2e-14**; multigrid engages 40/40 on the composite operator; CG **0.75×**
and net wall **1.14×** per design iteration; GenEO's cubic fingerprint proven to
refresh in a loop and still discriminate; determinism at loop, run and pipeline level.

## What the measurement says

**Positive control** — same fixture, same ladder, one key different, region fully
reachable, ceiling says 10,002 of 10,040 voxels *could* be latticed:

| config | latticed | margin |
|---|---:|---:|
| two-step | **19.0 %** | 2600–2717 |
| multiscale | **0.8 %** | 121–212 |

Member thickness in cells against the floor of 5 — `[1,2): 2813, [2,3): 1787,
[3,4): 1297, [4,5): 81, [6,7): 2397` — **71 % below the floor**.

**Mechanism.** Multiscale legalizes intermediate density, so the optimizer spreads
material into thin diffuse webs; thin is exactly what the floor forbids. SIMP's ρ³,
by consolidating material into chunky members, yields *more* latticeable geometry.
Compounding it, the measured octet tensor is superlinear (C11 ~ ρ^1.61 overall, local
exponent **2.8** near ρ=0.9 against SIMP's 3.0), so the optimizer still concentrates
toward solid where load concentrates.

**The task anticipated this.** Item 4 asked for the floor as a *live constraint*,
with a reporting fallback if intractable. It is genuinely intractable as written
(a distance transform of a thresholded field — non-differentiable), the fallback was
shipped, and the data now shows the fallback is not enough: the floor is the binding
constraint and the formulation works against it.

## UPDATE — decisions 2 and 3 were answered before this was committed

**Decision 3 CONFIRMED, and it is the headline.** `region reachability: active=932
frozen_solid=10070 (of 11002)` — **91.5 % of the maintainer's declared lattice region
is pinned solid by their own face-protection collar** and can never become lattice in
any formulation. The motivating 0 / 82 / 472 was substantially a job-level conflict.
A warning now fires at arming. Corollary worth chasing separately: the two-step
latticed 472 voxels of that frozen region, i.e. it hollows out protected material.

**Decision 2 WORKS.** Length-scale control derived from the floor
(`min_feature = floor_cells x cell / 2`) took the control fixture from **0.8 % to
59.5 %** latticed — **3.1x better than the two-step's 19.0 %**, with the
member-thickness histogram moving out of the 1-3-cell buckets into [6,7) and the
below-floor population falling 71 % -> 18 %. It is armed automatically whenever
multiscale is armed, never a separate knob, because multiscale without it is strictly
worse than the pipeline it replaces. Cost: margins drop to 87-96 from 2600-2717 —
still ~58x the required 1.5, but the two are not interchangeable.

**Decision 1 therefore:** the job flag has a reason to exist and ships with the lever.
Still gated on M1 / M4 / ctest, which were running when this was committed.

## Decisions (as originally posed)

1. **Ship or withhold?** The path is default-OFF and byte-identical when off, so
   landing it costs nothing and banks the model, the sensitivities, the coherence
   fixes and the instrumentation. But it currently ships a job flag that makes
   results worse if anyone arms it. Land disarmed with the negative result recorded,
   land with the flag removed, or hold the branch?

2. **Try the one untested lever?** Length-scale control — tie the density filter
   radius to the floor (r ≈ n\*·cell/2 in voxels) so sub-floor members are
   *inexpressible* rather than penalised. Standard TO practice, a reparametrization
   rather than a constraint. Not reachable from a job today (`min_feature_mm` comes
   from `configure_production_options`). Cost: a small change plus two runs on the
   control fixture. This is the difference between "negative result" and "solved".

3. **A separate, possibly larger finding — UNCONFIRMED.** On the maintainer's own
   job, rungs 0.52 and 0.38 produced *zero* lattice candidates. The run log shows
   `face-protection face=16 voxels_frozen=10554` against a declared lattice region of
   `11002` voxels — nearly the same set — and every `include` region is a 4 mm-deep
   face slab against a floor demanding a 23.0 mm member (5 cells × the 4.6026 mm
   printability floor forced by a 0.42 mm nozzle). If that holds, the original
   0 / 82 / 472 was substantially a **job-level conflict** — lattice declared on
   faces a protection collar freezes solid — and not the optimizer's doing. A
   reachability diagnostic and warning are implemented; the probe that would confirm
   it has not run (its job document hit a schema error). Worth confirming, because it
   changes what the user should be told and is a UX fix, not a solver fix.

## Not yet measured

M1 byte-identity (mechanism is structural: every new parameter defaults to the
literal the old code used), the full gate table, M3 on the maintainer's part, and a
full ctest. Two acceptance runs were lost to an unrelated session on the same host
issuing `pkill -f "topopt-cli run"`; runs are now shielded under a different binary
name.
