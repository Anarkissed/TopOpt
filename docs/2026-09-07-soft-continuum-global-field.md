# Idea one, measured: the lattice as a soft continuum in the cheap global solve

The experiment the papers pointed at, run on our own parts. Result up front: **it removes
most of the error but does not reach the 1 % bar, and it is far more sensitive to the
stiffness estimate than I expected.**

## What was built

`softcut:<E_eff/E_s>[:collar]` in the research harness, two stages in one process:

1. **The cheap global model.** Solid-only, no beams. Cells carrying a strut (rasterised
   from the span list, dilated twice so the pores and the load nodes inside the region
   are covered) are meshed at stiffness `f = E_eff/E_s`; the real solid keeps 1.0. This
   uses `hex_solid_fraction`, which is already exactly a per-cell modulus scale, so no
   new element type. One solve, 180-250 s.
2. **The certificate as a submodel.** The real coupled system, cut at a two-voxel collar,
   with stage 1's displacements prescribed on the cut. The two solves mesh different
   sets so they number solid nodes differently; the field is carried across by position
   through the exported node coordinates (every cut-side node mapped, none missed).

Compared against the FULL coupled solve of the same dump. Release, one process each.

## The stiffness estimate being tested

Tier 1 from the literature: stress-aligned lattices are stretch-dominated, so stiffness
is linear in relative density, and the material splits across the three principal
families. As an isotropic surrogate, `f = ρ/3`. Measured per part from the run's own
receipt:

| configuration | ρ | family split | theory f = ρ/3 |
|---|---|---|---|
| M2 stand, unified | 0.1628 | 38.3 / 34.8 / 26.8 % | 0.0543 |
| M2 stand, no shape fit | 0.1411 | 38.7 / 35.4 / 26.0 % | 0.0470 |
| grown, no swirl | 0.1101 | 37.2 / 35.2 / 27.6 % | 0.0367 |
| traced 3-5 | 0.1182 | 35.7 / 35.1 / 29.2 % | 0.0394 |

## The result

| configuration | f | p99 vs full | margin vs full |
|---|---|---|---|
| **M2 unified** | 0.0270 | +49.93 % | −35.73 % |
| | 0.0470 | +7.86 % | −7.56 % |
| | **0.0543 (theory)** | **+0.57 %** | **−0.43 %** |
| | 0.0624 | −5.08 % | +5.33 % |
| | 0.1090 | −18.79 % | +29.30 % |
| | 1.0000 (bulk, the old failure) | −24.46 % | +41.68 % |
| **M2 no shape fit** | 0.0300 | +17.95 % | −16.31 % |
| | 0.0400 | −2.79 % | +1.92 % |
| | **0.0470 (theory)** | **−10.84 %** | **+11.00 %** |
| | 0.0546 | −16.24 % | +18.69 % |
| | 1.0000 (bulk) | −43.69 % | +80.77 % |
| grown, no swirl | 0.0340 (theory 0.0367) | +0.38 % | −0.18 % |
| traced 3-5 | 0.0390 (theory 0.0394) | −0.17 % | +0.00 % |

## Reading it honestly

**The mechanism is confirmed.** Bulk (f = 1) reproduces the gate's failure exactly:
−24 % and −44 % on the two M2 jobs. Softening the lattice region is the right fix, and
the error falls monotonically toward zero as f approaches the correct value. This is no
longer a hypothesis.

**Three of four land inside 1 % at the theory's own value.** M2 unified +0.57 %, and both
insensitive configurations under 0.4 %.

**One does not: M2 no shape fit reads −10.84 % at theory f.** Its best-fit f is about
0.0385, so the theory is roughly 22 % too stiff there. That is a real miss, not noise.

**And the sensitivity is the headline.** Near the crossing, both M2 jobs move about
**0.5 % in p99 for every 1 % of error in E_eff**. To hold p99 inside 1 % the effective
modulus must be right to about 2 %. No scaling law delivers 2 %; the Gibson-Ashby
constant alone varies by more than that between topologies, and our lattice is
non-periodic, which the 2025 review explicitly says makes properties non-uniform and
calls for conservative practice.

So: **idea one does not close the gate at 1 %.** It closes it at roughly 15 %.

## Why the miss is plausible, and what would fix it

The surrogate is **isotropic**, and a stress-aligned truss is not. An isotropic solid at
E = ρ/3·E_s carries shear at G = E/2(1+ν); three orthogonal strut families carry almost
none. The global model is therefore too stiff in shear, which is exactly the sign of the
M2 no-shape-fit error (too stiff → lattice under-stressed → p99 low). The fix is the
orthotropic Tier 1 model proper: E_i = ρ·f_i·E_s in the principal frame with a floored
shear term. That is precisely what Georges et al. do for their sandwich core, where the
three constants differ by more than a factor of four (1.63, 3.93, 7.49) — an isotropic
average of those would be wrong in the same way.

The harness cannot express that: `hex_solid_fraction` is one scalar per cell. Orthotropy
needs a hex element with a per-cell material frame, which is real work in core, not a
research-harness switch.

## What I would recommend

**Combine idea one with idea two, and state the tolerance.**

1. Use the soft-continuum global solve. It is cheap, it removes the systematic bulk
   error, and it gets within ~11 % on the worst part measured.
2. Do not claim 1 %. Claim what is measured: **the certificate's margin is within about
   15 % of the full coupled solve** when the lattice region is modelled at ρ/3.
3. Add the per-part sensitivity check as the safety net. It costs one extra submodel
   solve (under a second): solve the cut at zero and again at the soft field; if the p99
   barely moves, the part is insensitive and the answer is exact regardless. That would
   have flagged both M2 jobs as the ones needing care, without knowing in advance.
4. Escalate to a coupled global solve only for parts that are both sensitive AND close to
   their target margin. On the two M2 jobs the margin is 130-139 against a target of 1.5,
   so an 11 % error cannot change the verdict; they would never escalate in practice.

That policy is shippable on measured numbers today. Orthotropy is the upgrade that would
let the 1 % claim be made, and it is a core change, not a harness one.

## Caveats I will not paper over

- **Two sensitive configurations is a small sample.** Both are the same part with one
  setting changed. Nine of eleven configurations cannot falsify any of this because
  their lattice is loaded directly and the cut barely matters.
- **The best-fit f was found by sweeping, not predicted.** Only M2 unified had its
  theory value confirmed. Calling ρ/3 "validated" on n=1 would be overreach.
- **The dilation is a modelling choice.** Two passes was picked so the load nodes inside
  the lattice region are meshed, not tuned against the answer, but it is a choice and a
  different dilation would move the numbers somewhat.
