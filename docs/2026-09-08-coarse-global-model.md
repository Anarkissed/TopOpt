# The coarse global model: now faster AND lighter than doing it the current way

Built the thing the literature actually does — a coarse global mesh — and it turns the
tax from a 14x loss into a win.

## The headline, m2 unified, idle machine, one process each

| | today's certificate | iterative + coarse global (x2) |
|---|---|---|
| wall | 26.0 s | **10.9 s** |
| peak RSS | 4.38 GB | **3.85 GB** |
| largest allocation | 2.92 GB | 0.91 GB (local factor) |
| global model | — | 61,947 DOF, 0.42 GB, factored in **0.93 s** |
| p99 vs the exact coupled answer | reference | **−0.06 %** |
| margin vs exact | reference | +0.43 % |

And on m2 no-shape-fit: p99 −0.35 %, **margin 130.0 against a reference of 130.00**,
10.7 s, 4.00 GB.

Against the fine global model this is 38x faster (10.9 s against 417 s) and less than
half the memory. The global factorisation went from 9.73 GB and 146 s to 0.42 GB and
under a second, because coarsening two-fold in each direction leaves eight times fewer
cells.

## What had to be got right

**Non-matching meshes.** The published method assumes the global and local meshes match
at the interface and lists non-matching as future work. Coarsening breaks that, so the
transfer is the variationally consistent pair: trilinear interpolation `P` carries coarse
displacements down to the fine interface, and its transpose `P^T` carries interface
forces and the applied loads back up. Using `P^T` rather than anything else is what keeps
the coupling from leaking work. Weights are renormalised over whichever coarse corners
are actually meshed. With coarsening set to 1 the whole thing collapses to exact node
matching and reproduces the earlier result digit for digit, which is the control.

**Correcting on the interface alone stops working.** With a coarse global model the fine
complement is no longer in equilibrium, so the interface-only correction is inconsistent:
the off-interface residual sat at 1.2 instead of 1e-13 and the answer oscillated around
the reference by about half a percent instead of settling. Correcting on *every*
non-local degree of freedom fixes it — that makes the scheme a preconditioned Richardson
iteration on the fine reference system with the coarse model as preconditioner, which is
what it should have been. p99 then settles from iteration 7 and stays.

**The residual no longer goes to zero, and should not.** It plateaus near 0.5 because the
coarse model cannot represent the fine complement exactly. The iteration converges to the
solution of "coarse far field, fine local", which differs from the all-fine reference by
the coarse discretisation error — and that difference is the −0.06 % above. The
convergence indicator is therefore the *stagnation* of p99, not the residual norm.

## How far coarsening goes, measured

| coarsening | global DOF | global factor | outcome |
|---|---|---|---|
| 1 | 326,277 | 9.73 GB / 146 s | converges, exact |
| **2** | **61,947** | **0.42 GB / 0.93 s** | **converges, −0.06 %** |
| 3 | 23,190 | 0.09 GB / 0.17 s | **DIVERGES** (residual 18 → 29) |
| 4 | 10,830 | 0.02 GB / 0.04 s | **DIVERGES badly** (p99 43 → 153) |

The scheme is a Richardson iteration, so it converges only while the spectral radius stays
below one, and a weak enough preconditioner crosses that line. Damping the correction
brings it back: at coarsening 3 with a relaxation of 0.5 it converges again, to −0.43 % on
p99 and +1.08 % on margin — stable, and less accurate than coarsening 2, as expected from
a coarser far field.

So coarsening 2 is the operating point: it needs no damping and is the most accurate. The
relaxation is the safeguard, and a part where even coarsening 2 diverges would need it.

## What is still unmeasured

- **The real device footprint.** The 3.85 GB peak is mostly harness: it assembles and
  exports the entire fine coupled system to compute the residual and to cut out the local
  block. In production the residual needs the reference operator only to be *applied*,
  which an element loop does without assembling anything, and only the local region needs
  assembling. That points to roughly 1.4 GB — the local factor plus the coarse factor plus
  vectors — but I have not built it and do not claim it.
- **Two configurations.** Both are the same part with one setting changed. The nine others
  cannot discriminate.
- **Robustness of the relaxation.** One value tested on one configuration. A real
  implementation would pick it adaptively (Aitken), which is standard and cheap.
- **The matrix-free path is now beside the point.** With a coarse global model the direct
  factor is 0.42 GB and takes under a second, so there is no reason to solve it
  iteratively. The 3,000-iteration CG problem disappeared by making the problem small
  rather than by solving it better.
