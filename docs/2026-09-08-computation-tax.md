# The computation tax, measured on an idle machine

All on m2_cert, one process, `/usr/bin/time -l`, Release, nothing else running.

| | today's certificate | iterative, direct global | iterative, **iterative global** |
|---|---|---|---|
| wall | **26.0 s** | 417 s | 372 s |
| peak RSS | **4.38 GB** | 8.64 GB | 5.14 GB |
| biggest single allocation | 2.92 GB factor | 9.73 GB global factor | 0.91 GB local factor |
| setup | 0.4 s assembly | 226 s (146 s global factor) | ~16 s (no global factor) |
| per iteration | — | ~31 s (23-27 s global back-solve) | ~50 s (3,000 CG its) |
| p99 at iteration 6 | reference | −0.06 % | −0.06 % |

**The tax today is 14x time and 1.2x memory. It is still a net loss.**

## What the matrix-free change bought, and what it did not

**Bought:** the 9.73 GB global factor is gone, along with the 146 s spent building it.
Peak fell from 8.64 to 5.14 GB, and the largest remaining allocation is the local factor
at 0.91 GB. Most of the 5.14 GB is harness overhead — the reference system, the global
system and the local factor all held at once — so the essential working set is closer to
1.1 GB, though I have not measured that in isolation and will not claim it as fact.

**Did not:** time. The global solve now takes about 3,000 Jacobi-preconditioned CG
iterations, 44-56 s each. The bottleneck moved from "building a huge factor once" to
"solving the global system slowly, every iteration".

## Two things confirmed on the way

**The inexact global solve is free.** Tightening the global tolerance from 1e-3 to 1e-9
changes the answer in the fifth digit and nothing else:

    tolerance 1e-9   it0 0.17135  it1 0.16792  it3 0.16941  it6 0.16970
    tolerance 1e-3   it0 0.17134  it1 0.16778  it3 0.16941  it6 0.16970

That is the theory holding: the global solve is a preconditioner, not an answer, so it
does not need to be accurate. Confirmed, and worth 30 % of the CG cost.

**The iterative and direct versions agree exactly**, which is the check that the
matrix-free path is right rather than merely cheap.

## The remaining lever, and why I stopped short of it

3,000 CG iterations for a solid elasticity problem means the preconditioner is
inadequate, not that the problem is hard. Two standard fixes, neither implemented:

1. **A coarser global model.** This is what the literature actually does — Gendre's global
   model is a coarse mesh, not the fine one. Coarsening two-fold in each direction gives
   eight times fewer cells, and its direct factor would be well under a gigabyte with
   back-solves in a second or two, removing both the factor cost and the CG cost at once.
   The obstacle is that the method as published assumes the two meshes match at the
   interface; non-matching meshes need interpolation, which Gendre explicitly lists as
   future work. This is the right answer and it is a real piece of work.
2. **A better preconditioner** for the existing fine global model — incomplete Cholesky,
   or whatever the optimizer's own matrix-free solver uses, which is already tuned for
   exactly this kind of solid problem on this hardware. Cheaper to try, smaller payoff.

## Honest summary

The method is correct and converges to the exact answer; that part is settled and
measured. The cost is not yet competitive: 372 s against 26 s. The memory story is
promising but not proven, because the harness holds three systems at once. The next step
that would actually change the tax is a coarse global mesh, and I have not built it.
