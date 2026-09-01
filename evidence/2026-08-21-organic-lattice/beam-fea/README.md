# Beam FEA for the organic lattice (2026-08-29)

Scratch work, NOT shipped code. Preserved because the validated pieces are reusable.

## Files
- `gc2.cpp`      graded_coupon_v2 + argv[31] lean_deg, argv[32] fam0_sep_mult,
                 argv[33] beam dump (segments+region tags, BCs, loads, .disp,
                 .disp_soft, .mask)
- `beamfea.py`   standalone frame solver (loads applied directly). VALIDATED.
- `submodel.py`  frame solver driven by the global displacement field. WORKS.
- `hybrid.py`    solid hex + beam, coupled. ASSEMBLY VALIDATED, SOLVE SINGULAR.
- `slender.py`   junction-to-junction strut slenderness from a .beam dump.

## Controls that PASS (exact against closed form)
- frame element vs cantilever: displacement AND stress exact to 6 s.f.
- Timoshenko shear at L/r=5: 0.251419 vs analytic 0.251419 (+9.00% over EB),
  discretisation-independent (verified with elements of L/r = 0.25)
- hex8: symmetric, exactly 6 rigid-body modes, uniaxial patch test exact to
  1e-14%, strain energy exact
- hybrid assembly on a solid block: 0.67% vs PL/(AE), Poisson contraction correct

## RESULTS (M2 stand, E=3500 MPa, nu=0.35, yield 55 MPa)
submodel, Timoshenko:
  c3 (3 mm cells)  peak 1.139 MPa   connectivity 99.70%   margin 48x
  c6 (6 mm cells)  peak 0.148 MPa   connectivity 95.83%   margin 371x
Euler-Bernoulli overstated these by 2.5x -- EB must NOT be used (see chi below).

## OPEN: hybrid.py is singular
DOF-graph has ONE component, so it is NOT disconnection. Lattice connectivity
85.85%, solid connectivity 100%, coupling 14.13% -- all sane. The rank deficiency
is in the constraint elimination (T = master->all map) or the element assembly.
Needs null-space extraction to locate. Recommendation: build this in core, which
already has validated elements, matrix-free operators and multigrid.

## THE TRANSFERABLE CRITERION (Polymers 18(16):2003, doi 10.3390/polym18162003)
Shear-to-bending compliance ratio; use shear-corrected elements when chi >~ 0.5.
For a solid circular strut at nu=0.35, kappa=0.9:   chi = 2.25 * (r/L)^2
  -> shear correction required when L/r < 2.12
MEASURED: the peak-stress strut is ALWAYS in the stubby tail (c3 worst strut was
0.83 mm long, L/r 1.7, chi 0.77), and the 5th-percentile strut is ~0.85 mm at
EVERY cell size. So Timoshenko is required unconditionally, judged on the WORST
strut, not the median.

## KNOWN BIASES in the submodel numbers (all UNAPPLIED)
1. driving field from a solve where the region is still solid  -> too stiff,
   OPTIMISTIC. Enters linearly: peak stress scales exactly with the drive
   (verified x1/x2/x5 -> 0.3649/0.7298/1.8245 MPa).
2. cut-boundary rotations clamped to zero -> too stiff, optimistic.
3. joint stiffening unmodelled -> beam models underestimate stiffness, hence
   understate stress. Dong & Zhao: 12.5% for stretching-dominant lattices.
4. AM knockdowns unapplied: vertical struts -20% modulus (Dong & Zhao);
   FDM PLA z-vs-x strength 41.08 vs 48.83 MPa (-16%).
