# R0 — PRE-REGISTRATION, lattice-as-a-material

**Written and committed BEFORE the first arm runs (§5a).** Nothing below is
retuned afterwards. If a bound is missed, the miss is REPORTED and the task
STOPS at that point (§5b, BLOCKED-STOP). `subfloor-per-region-blocked` is the
precedent: a 3.0% aggregate cap and a 0.10% margin bound were committed before
any code, a single region inside the cap moved the composite margin 1.8x the
bound, and it was reported rather than retuned. That is why we know it.

Commit of record: this file's own commit. Nothing in `evidence/2026-08-13-…`
other than this file exists at that commit.

---

## 0. The subject, fixed here so no arm can pick a friendlier one

| | |
|---|---|
| part | `evidence/2026-08-09-reference-implementation-bakeoff/M2_verticalStand.step` |
| resolution | 128 → grid 128 x 31 x 118 = 468,224 voxels, spacing 1.705279303 mm |
| load case | anchor face 18; one load group, 22 faces, Fz = −22.241134643554688 N |
| protections | face 16, depth 5.0 mm |
| slicer | infill 35%, wall_loops 5, inner 0.45 mm, outer 0.42 mm |
| material | PLA (E 3500 MPa, ν 0.33, ρ 1.24 g/cm³, yield 55 MPa, z_knockdown 0.55) |
| mask | part solid 110,904 voxels; Active 70,688 / FrozenSolid 40,216 / FrozenVoid 357,320 |
| topology | octet (the only topology `lattice_material_model_trustworthy` passes) |
| lattice cell | 2.0 mm (his `grading.cell_mm`), min extrudable width 0.45 mm |
| **shipped rung** | **0.68** |
| **light rung** | **0.26**, falling back to **0.38** if 0.26 will not converge in the time (§4b) |
| threads | **3**, strictly serial — he needs his Mac |

The frozen set is **40,216 voxels = 45.5% of printed mass = 247.3 g of 543.7 g**.
At relative density 0.30 that envelope weighs **173.1 g**, so the GROSS prize is
**74.2 g / 31.8% of the part** — and gross is not the number that decides this
(R4).

---

## 1. The bounds

### B1 — the shipped gate, unmodified. HARD.
Every assignment reported as passing must come back `accepted == true` from
`analyze_fixed_design` under the `KnockdownSpec` that `knockdown_spec_for`
builds from the production options. No second gate, no softened tolerance, no
re-analysis at a looser `cg_tolerance`. A non-convergent certification solve is
a REJECTED rung (`kRungNonConvergentReason`), never a softened one.

### B2 — the certified-margin bound. **0.95x.**
The best assignment's `margin_effective`, at each rung, must be at least
**95.0%** of the SAME-RUNG solid-frozen baseline's `margin_effective`, both read
at their own settling iteration (B6).

*Why 0.95 and not 0.999:* this is not a per-region sub-floor tweak. It removes
the stiffness of 45.5% of the printed mass and hands the freed budget back to
the optimiser, so a margin move of a few percent is the EXPECTED behaviour, not
the failure. 5.0% is chosen as roughly a quarter of the largest margin swing
this part has been measured to make for a real formulation change (PR 327: one
arm's margin fell 19.4% from its peak by iteration 120). A give-up bigger than
5% means the buttressing loss (§3) is not being bought back and the mechanism
is not doing what it claims.

### B3 — the minimum NET mass saving. **≥ 8.0% of the baseline printed mass at the shipped rung.**
NET, not gross (R4): mass of the best assignment's design AFTER the §4(c) loop
has re-optimised the remainder and put material back, against the SAME-RUNG
solid-frozen baseline's mass. At 543.7 g that is **≥ 43.5 g**.

*Why 8.0%:* the gross at f = 0.30 is 31.8%. Requiring the loop to keep at least
a quarter of what latticing frees is the line between "a real mass feature" and
"a re-arrangement that pays for itself in material it puts straight back". Below
that the honest answer is that the frozen region should stay solid.

### B4 — the cells-per-member floor. **`lattice_cells_per_member_min(octet)` = 5.0.**
A region whose measured local member width, divided by the cell size the
assignment uses, is **below 5.0** is REFUSED — reported as refused, never
approved with a caveat. Reported PER REGION either way (R5), with the law's
validity range beside it, never in aggregate.

The percolation floor (`lattice_percolation_cells_per_member_min` = 1.0) is
reported alongside so a region between the two is named BUILDABLE AND
UNCERTIFIABLE rather than collapsed into "un-latticeable".

### B5 — the load path. HARD.
`load_path_connected` must hold on every assignment reported as passing. (It is
already a term of `accepted`; it is stated separately because PR 324 measured
that 40 leaked frozen voxels out of 40,216 were enough to break this walk, and a
density field over the frozen set is exactly the machinery that could leak them.)

### B6 — the margin as a CURVE. HARD (R4).
Every optimised arm reports `margin_effective` per certified iteration together
with its SETTLING ITERATION, defined before any arm runs as:

> the first iteration i such that for all j in [i, i + 20], |m_j − m_i| ≤ 0.5%
> of m_i, where m is `margin_effective` on the certification stride.

An arm whose margin has not settled by its iteration cap is reported **NOT
SETTLED** and may not be named "best". No point margins are reported anywhere.

### B7 — drainability. HARD.
`lattice_void_escape` must report `sealed() == false` on every assignment
reported as passing, with FROZEN MATERIAL THAT IS NOT LATTICED COUNTED AS SOLID
(it blocks) and the escape network 6-connected (§6a).

### B8 — C0 inertness. HARD, and it runs FIRST (R1).
`Lattice(f = 1.0)` must be BYTE-IDENTICAL to Solid, verified by a stash-rebuild
checksum of the converged design, not by construction. If it is not, the
material model is wrong and no result after it can be trusted — BLOCKED-STOP.

---

## 2. What is measured, and in what order

| step | what | gate |
|---|---|---|
| R1 | C0 inertness, stash-rebuild checksum | B8 |
| M0 | the ρ→stiffness law: its fit, its validity range in cells-per-member, and what happens outside it | §1(b,d) |
| M1 | the frozen set decomposed into regions; strain energy per region from a solve already being run; QUIET vs LOAD-BEARING and what fraction of the 247.3 g sits in each | §2 |
| M2 | Mode 1 assignment table: region x density x rung, EVERY cell including the failures | §4(a,b), B1–B5, B7 |
| M3 | the §4(c) loop: assign → re-optimise → certify → step up. NET saving per pass, both rungs | B2, B3, B6 |
| M4 | Mode 2 (β optimised) against Mode 1's best | R2 |
| M5 | cost: does doubling the coefficient block land on the 0.5% side of the ledger (PR 324) | §3(e) |

Mode 2 is OFF by default until Mode 1 is measured (R2). Mode 1 is OFF by default
until B1–B7 are met (R2).

## 3. The stop rule

If any of B1–B8 is missed, the miss is written into the handoff with its number,
the arm that produced it, and the reproduction command; the bound is NOT moved;
and the task stops at that step. Per-region changes on this part have already
been measured to move the certified margin 1.8x further than estimated.
