# Directional stiffness: built, measured, and it does NOT help

Asked for after the isotropic surrogate missed by 11 % on one part. Result up front:
**the directional model is worse than the isotropic one on both sensitive parts, at
every scale tested. Anisotropy is not the missing ingredient.**

## What was built

Not a scaling law. The effective stiffness of a pin-jointed strut network is a standard
result, and it needs no unit cell, no periodicity and no fitted constant:

    C_ijkl = (1/V) Σ_struts (E·A·L)_s · n_i n_j n_k n_l

In Voigt with engineering shear each strut contributes a **rank-one 6×6**:

    D += (E·A·L / V) · m ⊗ m,     m = [n_x², n_y², n_z², n_x n_y, n_y n_z, n_z n_x]

So the per-cell material is read directly off the struts that are actually in that cell,
with their real directions and radii. This is the right construction for a non-periodic,
stress-aligned lattice, which is why it was worth doing.

Wiring: a general-D hex element (the existing 2×2×2 integrator already accepts an
arbitrary constitutive matrix, so no new element maths) plus an optional per-cell
material in the coupled solve. A pin-jointed network carries no shear and a single-strut
cell is rank one, so a stated isotropic floor `β` stands in for the joint and bending
stiffness a truss model omits.

## The result

| configuration | model | p99 vs full | margin vs full |
|---|---|---|---|
| **M2 unified** | isotropic, f = ρ/3 = 0.0543 | **+0.57 %** | −0.43 % |
| | directional, β = 0.02 | −18.58 % | +31.32 % |
| | directional, β = 0.05 | −19.38 % | +32.83 % |
| | directional, β = 0.10 | −19.57 % | +33.98 % |
| | directional ×0.7 | −18.39 % | +28.29 % |
| | directional ×0.5 | −15.28 % | +22.03 % |
| | directional ×0.3 | −9.69 % | +11.74 % |
| **M2 no shape fit** | isotropic, f = ρ/3 = 0.0470 | **−10.84 %** | +11.00 % |
| | directional, β = 0.02 / 0.05 / 0.10 | −34.09 / −35.75 / −37.01 % | +55.8 / +57.9 / +60.7 % |
| | directional ×0.7 / ×0.5 / ×0.3 | −32.46 / −29.43 / −24.75 % | +51.3 / +44.0 / +32.7 % |
| traced 3-5 (insensitive) | directional | −0.37 % | +0.00 % |
| grown no swirl (insensitive) | directional | +0.45 % | −0.27 % |

Three things are settled by this:

1. **Directional is worse than isotropic**, on both parts that can discriminate. Not
   marginally: 19 % against 0.6 %, and 36 % against 11 %.
2. **The isotropic floor β is not the cause.** Sweeping it 5× moves the answer by under
   1.2 points.
3. **No single scale rescues it.** Scaling the whole tensor improves M2 unified
   monotonically (−19 % → −9.7 % at ×0.3) but M2 no-shape-fit stays worse than isotropic
   at every scale (−24.75 % at best). One factor cannot fit both, so the tensor's SHAPE
   is not right either — it is not merely too big.

## Why, as far as the evidence supports

The rank-one sum is the **Voigt (upper) bound**: it assumes every strut stretches
affinely with the surrounding material. That is tight only for a fully triangulated,
stretch-dominated network. Where struts bend instead, the real lattice is softer than the
bound, so the global model comes out too stiff and the lattice looks under-stressed —
which is the sign of every directional row above. The tensor also manufactures shear
stiffness out of curved, non-orthogonal struts, which is why scaling it down does not
recover the isotropic result: the extra stiffness is in the shear terms, not the
magnitude.

**A hypothesis I could not test with these parts.** Our walls are ~2.2 cells thick. Every
homogenization method assumes the microstructure is many cells below the part's scale;
the 2022 review states the requirement as "at least a couple of orders of magnitude", and
the 2025 review says non-periodic lattices have non-uniform properties and warrant
conservative practice. At two cells there is no scale separation at all, and the
signature fits: one continuum surrogate happens to land at +0.57 %, another is 19 % out,
and no principled refinement improves matters. That would mean **the isotropic hit on M2
unified was partly luck**, and no continuum model will be reliably right at this wall
thickness. I cannot confirm it here: the nine thicker-margin configurations are
insensitive to the cut, so they cannot discriminate between surrogates.

## Where this leaves the recommendation — unchanged, and now better evidenced

The isotropic ρ/3 surrogate remains the best cheap global model measured: it removes the
bulk error (24–44 % → 0.6–11 %) and nothing built since has improved on it. So:

1. **Use the isotropic soft continuum**, and state ~15 %, not 1 %.
2. **Add the per-part sensitivity check** as the net: solve the cut at zero and again at
   the soft field, and if p99 barely moves, that part's answer is exact regardless of the
   surrogate. Under a second. It flags exactly the parts where any of this matters.
3. **Escalate to a coupled global solve** only for parts that are both sensitive and near
   their target margin. Both M2 jobs report margins of 130–139 against a target of 1.5, so
   an 11 % error cannot flip them; they would never escalate.

**What I would NOT now recommend** is chasing a better continuum estimate. Two principled
attempts (a stretch-dominated scaling law, and the truss network's own stiffness tensor)
land 11 % and 36 % out on the same part. The next honest step is not a third surrogate;
it is either accepting the stated tolerance with the sensitivity net, or paying for the
coupled global solve on the worker for the parts that need it.

## Caveats

- Two discriminating configurations, and they are the same part with one setting changed.
- The scale sweep is a fitted parameter, included to test a hypothesis, not proposed as a
  model.
- `β` and the two-pass dilation of the lattice region are stated modelling choices; β was
  swept and does not matter, the dilation was not swept.
