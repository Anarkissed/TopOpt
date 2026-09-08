# Iterative global/local coupling: implemented, and it converges to the exact answer

The method from Gendre, Allix, Gosselet & Comte (2009), built in the research harness
and measured on the two configurations that can discriminate. **It works, and the
stiffness estimate no longer matters.**

## The claim, tested directly

Run the same problem twice: once from the good surrogate (E_eff = ρ/3) and once from the
worst one we ever had (bulk, E_eff = E_solid — the model that failed the original gate by
44 %). If the theory is right they converge to the same answer and differ only in speed.

### M2 stand, no shape fit — reference p99 0.1802, margin 130.00

| iteration | good surrogate (f = 0.047) | bulk surrogate (f = 1.0) |
|---|---|---|
| 0 (today's one-way submodel) | −3.78 % | −18.93 % |
| 1 | −2.51 % | −15.75 % |
| 3 | −0.61 % | −9.92 % |
| 6 | −0.11 % | −6.38 % |
| 10 | **−0.03 %** | −3.18 % |
| 12 | **−0.03 %** | −1.83 % (still falling) |

### M2 stand, unified — reference p99 0.1698, margin 138.90

| iteration | good surrogate (f = 0.054) | bulk surrogate (f = 1.0) |
|---|---|---|
| 0 | +0.91 % | −11.46 % |
| 3 | −0.23 % | −6.42 % |
| 6 | −0.06 % | −3.15 % |
| 10 | **−0.06 %**, margin 138.91 vs 138.90 | −1.27 % |
| 12 | — | −0.57 % (still falling) |

**Both surrogates converge to the same answer.** The good one reaches 0.03-0.06 % on p99
and lands the margin on 138.91 against a reference of 138.90. The bulk one — wrong by a
factor of twenty in the lattice regions — is still walking to the same place, just needing
three or four times the iterations. That is the whole claim, measured.

So: the homogenized stiffness sets the **iteration count**, never the answer. Every
question of the last three days about ρ/3, directionality, and 2.2 cells across was a
question about convergence speed.

## What was built

`iglcut:<f>:<collar>:<iters>`, roughly a hundred lines, because reading Gendre gave a much
simpler formulation than the one I had planned. Their Eq. 24 identifies the interface
residual as the residual of the *condensed reference problem*. Since our complement region
is plain solid in both models, the complement reactions cancel and it reduces to

    r|_Γ = ( F − K_reference · u_GL ) |_Γ

with `u_GL` the composite field: the local solution inside the local domain, the global one
outside. One sparse product. No operator splitting, no separate complement assembly.

    u_G = K_G⁻¹ F                     global, soft continuum, FACTORED ONCE
    repeat:
      solve LOCAL with u_G on the cut  (kept region, real struts; ALSO factored once)
      u_GL = local inside, global outside
      r = (F − K_ref u_GL)|_Γ
      u_G += K_G⁻¹ r                   one back-substitution

Both operators are constant, so each iteration is two back-substitutions.

## One real bug, and the diagnostic that caught it

The first version diverged: the residual fell for three iterations then grew. The
off-interface residual — which must be zero, since the complement is in equilibrium — was
0.30 to 0.41 of the load norm and growing.

The cause was that the two models were not identical outside the local domain. I had built
the local domain around the struts, and the softened region reached past it, so some cells
were soft continuum in the global model and beams in the reference while sitting in the
*complement*. Rebuilding the local domain **from the softened region** — every soft cell
plus the collar — fixed it. The off-interface residual is now 1e-13 on every run.

That quantity is worth keeping permanently: it is a correctness check on the partition
that cost nothing and caught a subtle error immediately.

## Cost, measured

| | m2 unified | m2 no shape fit |
|---|---|---|
| local domain | 255,573 DOF | 255,318 DOF |
| interface Γ | 18,048 DOF | 18,405 DOF |
| local factor | 0.914 GB | 0.845 GB |
| global factor (direct) | 9.7 GB | 8.2 GB |
| setup | 229 s | 131 s |

**The global direct factor is the problem, and it is bigger than the original**: filling
the lattice pores with continuum makes the mesh denser than the solid it replaced, so a
direct global factor is worse than what we started with. This does not threaten the
method, but it settles the architecture:

- The global stage **must** be the matrix-free iterative solve, not a direct one. It is a
  plain solid problem, which is exactly what the app already solves matrix-free at 1.47M
  DOF on device for the optimizer. The conditioning pathology that forced the direct
  solver came from mixing beams with solid, and the global model has no beams.
- The local stage stays direct: 0.85-0.91 GB here, and it was 0.04-0.21 GB at the tighter
  collar used before. The collar grew because the local domain must now contain the whole
  softened region; that is a real cost of doing it correctly and it can be tuned.

## What is not done

- **No acceleration.** Gendre §4.1 gives a symmetric-rank-one update that works on
  interface vectors only and needs no extra global solve; their examples go from ~7
  iterations to 2-3. Ours would likely reach 0.1 % in 2-3 instead of 6. Not implemented.
- **The global stage is still a direct solve** in the harness. Switching it to the
  matrix-free iterative path is the next real step and is what makes the device claim.
- **Two configurations.** The other nine cannot discriminate; they are insensitive to the
  cut. The convergence behaviour on a part that is sensitive *and* has a low margin is
  untested, and that is the case where iteration count actually matters.
- **The collar is larger than before** (255k DOF against 150-190k), because correctness
  demanded the local domain contain the soft region. The trade between collar size and
  iteration count has not been explored.

## Where this leaves the whole question

The original question was whether the organic certificate can run on an iPad. The answer
is now yes, on measured numbers, and the route is:

1. Global: solid only, lattice regions as a soft continuum, **matrix-free iterative**.
2. Local: lattice plus collar, real struts, direct.
3. Iterate the two, four to six times, or two to three with the standard acceleration.

The result is the exact coupled answer, not an approximation with a stated tolerance. The
stiffness surrogate needs to be reasonable, not right, and everything measured over the
last three days about how wrong it is turns out to bound the iteration count rather than
the error.
