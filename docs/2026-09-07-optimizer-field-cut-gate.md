# ITEM 1 — the gate. The optimizer's field on the cut: MEASURED, and it FAILS.

Proposed tolerance: **1 % on p99 and on margin** (the natural bar given the 0.2 %
already measured with a coupled global field). Stated before the measurement.

Method: the dump now carries `v.displacement_field` — the per-node displacement of the
same analysis that produces `von_mises_field`, DOF-ordered over the grid's FEA nodes.
The harness maps it into the coupled solve's solid dof numbering through the exported
solid node positions (`fieldcmp`/`submodel ... optimizer`; 56,566 of 56,566 nodes
mapped, 0 missed on every configuration), prescribes it on the cut, solves the kept
region, and compares member stresses with the FULL coupled solve of the same dump.
All eleven configurations, Release, one process each.

## The result

| configuration | p99 full | p99 submodel | Δ p99 | margin full | margin submodel | Δ margin |
|---|---|---|---|---|---|---|
| traced 5.5-6 | 1.6807 | 1.6827 | +0.12 % | 17.29 | 17.33 | +0.23 % |
| traced 4-4 | 1.2854 | 1.2863 | +0.07 % | 22.22 | 22.27 | +0.23 % |
| traced 3-5 | 0.8022 | 0.7982 | −0.50 % | 35.59 | 35.59 | 0.00 % |
| grown no ties | 7.1464 | 7.1478 | +0.02 % | 3.43 | 3.43 | 0.00 % |
| grown ties | 1.3828 | 1.3826 | −0.01 % | 20.78 | 20.76 | −0.10 % |
| grown no swirl | 2.3956 | 2.4075 | +0.50 % | 10.92 | 10.86 | −0.55 % |
| grown u4.5 | 0.7660 | 0.7690 | +0.39 % | 35.64 | 35.64 | 0.00 % |
| grown u5.5 | 2.2499 | 2.2480 | −0.08 % | 13.61 | 13.54 | −0.51 % |
| grown u6.5 | 1.0825 | 1.0836 | +0.10 % | 27.11 | 26.98 | −0.48 % |
| **M2 stand, unified** | 0.1698 | **0.1305** | **−23.13 %** | 138.90 | **195.30** | **+40.60 %** |
| **M2 stand, no shape fit** | 0.1802 | **0.1015** | **−43.66 %** | 130.00 | **234.50** | **+80.38 %** |

Nine of eleven are inside 0.55 %. Two are outside by 23 % and 44 % on p99, 41 % and
80 % on margin — **and in the unsafe direction**: the submodel reads the lattice as
stronger than it is. A certificate built on this field would pass M2 parts it should
question.

## It is not the cut, and not the collar, and not a scale

- **Collar** (M2 unified): 2 vox −23.13 %, 4 vox −23.08 %, 8 vox −10.27 %. Growing it
  does not converge; at 8 voxels 296,235 of 326,277 dofs are kept, which is not a
  submodel any more. The research's 2/4/8 rows said growth would not help; it does not.
  Not tuned further, as instructed.
- **The cut and the machinery are correct.** Same dumps, same collar, same code, with a
  COUPLED global field prescribed on the cut instead: **+0.00 %** on p99 and margin for
  m2_cert, m2_noshapefit and gcert_3_5 alike. The submodel reproduces the full solve
  exactly when it is given the right field.
- **Not a constant scale.** The optimizer's field is 4-25 % of the coupled field's
  magnitude; scaling it up by 3.98 and 5.46 moves M2 from −23.1 % to −17.1 % and
  −10.0 % but never to zero. It is a different solution, not the same one mis-scaled.

## Why (measured, not inferred)

`fieldcmp` compares the two fields node by node on the solid dofs they share:

| configuration | mean \|u\| coupled (mm) | mean \|u\| optimizer (mm) | ratio | mean relative difference | p50 | p95 |
|---|---|---|---|---|---|---|
| traced 5.5-6 | 1.83e-3 | 8.60e-5 | 0.047 | 0.966 | 0.543 | 1.104 |
| traced 3-5 | 1.32e-3 | 8.63e-5 | 0.066 | 0.953 | 0.533 | 1.056 |
| grown ties | 1.52e-3 | 8.61e-5 | 0.057 | 0.960 | 0.655 | 1.186 |
| grown no swirl | 2.22e-3 | 8.61e-5 | 0.039 | 0.974 | 0.734 | 1.175 |
| M2 unified | 6.81e-4 | 1.71e-4 | 0.251 | 0.796 | 0.467 | 0.991 |
| M2 no shape fit | 9.32e-4 | 1.71e-4 | 0.183 | 0.855 | 0.544 | 0.990 |

The two fields differ by 80-97 % relative on EVERY configuration, including the nine
that passed. The nine did not pass because the fields agree; they passed because their
lattice stress is set by the loads and restraints inside the kept region, so the cut
contributes almost nothing. The two configurations whose lattice stress does depend on
the surrounding solid's deformation are the two that fail.

The physical reason is visible in the magnitudes: the analysis field is the field of a
part whose lattice regions are BULK MATERIAL at their density — it has no beams. The
coupled solve replaces that bulk with a lattice that is 4-25x more compliant, so the
part deforms 4-25x more. Prescribing the bulk-model field on the cut surrounds the
lattice with a part far too stiff, and the lattice then carries less than it really does.

## Decision — STOPPED, as instructed

The certificate is NOT a submodel of the optimizer's field at 1 %, and the failure is
unsafe. Item 2 is not started; the production worktree carries no changes.

The maintainer's call is the one the task named: **does a coupled global solve run on
the worker once per part?** If it does, everything else is already measured — the same
cut with a coupled field reproduces the full solve to 0.00 %, at 0.07-0.24 GB and under
a second, and the certificate becomes a submodel of THAT.

Two narrower options exist, both unmeasured and neither authorised here:
1. **Solve the global model once with the lattice present but cheap** (the lattice
   region as an equivalent soft continuum rather than beams) and cut against that. It
   would be one coarse solid solve, not a coupled one. Whether its field is within 1 %
   is exactly the measurement above, repeated with a different global model.
2. **Keep the full coupled solve only where the cut matters.** The nine insensitive
   configurations need no global field at all; a per-part test of that sensitivity
   (solve the submodel with the cut fixed at zero and again at the optimizer field; if
   p99 moves less than the tolerance, the part is insensitive) would certify most parts
   cheaply and escalate the rest. This is a real option and it is cheap to measure, but
   it changes what the certificate promises, so it is the maintainer's to authorise.
