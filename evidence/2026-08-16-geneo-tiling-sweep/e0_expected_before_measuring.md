# What I expected before the sweep returned

Written after `core=8` landed (N_t = 1686) and **before any of 12/16/24 had
completed**, so the predictions below can be graded rather than reconstructed.
This is the same discipline `2026-08-02-warm-start-coarse-experiment` used, and
it exists because a prediction written afterwards is not a prediction.

## The arithmetic the predictions rest on

His grid is 128 x 31 x 118. `tile_cores` is per-axis, so the subdomain count is
`ceil(128/c) * ceil(31/c) * ceil(118/c)`:

| core | subdomains | vs 8^3 |
| ---: | ---: | ---: |
| 8 | 960 | 1.00x |
| 12 | 330 | 0.34x |
| 16 | 128 | 0.13x |
| 24 | 60 | 0.06x |

MEASURED at `core=8`: **N_t = 1686**, i.e. **1.76 modes per subdomain** against a
`kGeneoBlockM` cap of 20. The cap is nowhere near binding at 8^3.

## E1 — N_t falls, but SLOWER than the subdomain count

A larger subdomain has more low-lying modes below the `lambda_cut`, so
modes/subdomain should RISE as the tiling coarsens. The one prior data point
(`2026-08-02-geneo-standing-probe` W4, on a much smaller 40x16x41 grid) took
N_t 313 -> 47 going 8^3 -> 16^3: subdomains fell 8x, N_t fell 6.7x, so
modes/subdomain rose only **1.2x**.

If that 1.2x transfers, `core=16` lands near **1686 x 0.13 x 1.2 ~= 270**.
I expect the true value to be HIGHER than that, because his grid is a slab and
its subdomains are less cubic than the probe's, but I expect it in the
**200-600** band rather than the 1,686 it starts from.

**Prediction: N_t at 16^3 is between 200 and 600, and at 24^3 is lower still but
by proportionally less — the curve bends.**

## E2 — the implied threshold crosses his burn somewhere between 12 and 16

The gate engages when `burn >= 2*N_t + engaged_burn + 2*engaged_tail`. With his
measured legs (500, 472 — the 472 is this run's own rung-0 tail, 972-500) the
implied threshold is `2*N_t + 1444`. His production solves burned **4,176-4,702**
plain. So the gate starts engaging once `N_t < ~1,370`.

**Prediction: EVERY tiling coarser than 8 clears that bar**, since 8^3's 1,686 is
only 1.23x above it. This is a low bar and clearing it is NOT the interesting
result — E3 is.

## E3 — ★ THE REAL QUESTION: does TOTAL CG actually fall?

This is where I am genuinely uncertain, and it is why §1(c) makes total CG the
figure of merit rather than the armed count.

A coarser tiling buys a cheaper refresh and pays for it in BASIS QUALITY: fewer,
larger subdomains means a coarse space that resolves the near-null modes less
finely, so the DEFLATED tail should grow. `2026-07-29-matrixfree-geneo-phase2`
measured deflated tails that were remarkably FLAT in problem size (191/202/201/213
while the grid grew 15x), but that was flat across GRID size at a fixed tiling,
which is a different question from flat across TILING at a fixed grid, and it
must not be read as the latter.

**Prediction: total CG improves at 12 and 16 and is worse at 24**, with the
best point somewhere in the middle — because the refresh saving is linear in
N_t while the tail cost should grow faster than linearly once the coarse space
stops resolving the modes that matter. **Confidence: low.** Outcome §2(b) — N_t
falls but deflation degrades and total CG does not improve — is entirely live,
and it is the outcome I would bet on if forced, because every prior smoothing-
and-conditioning lever on this part has come back a no-go.

## E4 — the build gets MORE expensive as the tiling coarsens

The local eigenproblems grow with the cube of the core size: 8^3 is ~1.7k local
DOFs, 16^3 ~14k, 24^3 ~46k. LOBPCG on a dense-ish local pencil is superlinear in
that. PR 329 abandoned a `core=16` attempt after 35 minutes without finishing
one solve, and attributed it to ~10x host starvation rather than to cost.

**Prediction: `core=24` has a materially longer build than `core=8` — enough to
be visible even through this host's contention — and `core=32` would be worse
again.** If a tiling wins on total CG but its one-off build costs more than it
saves over a 4-rung ladder, that is a real finding and belongs in the trade
curve, not buried.

## E5 — margins do not move at any tiling

GenEO is exact: every term in the preconditioner is SPD, so it changes the CG
route and never the converged field or the stopping test. **Prediction: the
certified margin at every rung is IDENTICAL across tilings**, and any movement
is a defect in the exactness claim rather than a property of the tiling.

## E6 — the `--iters 1` triage cannot answer E3, and I expect it to look flat

At one design iteration per rung the design is near-uniform and the solves are
easy: rung 1 at `core=8` burned **1,121** plain against a threshold of 4,816.
A solve that cheap declines at EVERY tiling — even N_t = 100 implies a threshold
of 1,644, still above it.

**Prediction: the triage shows all-decline at every tiling and near-identical
total CG, and that is a property of the FIXTURE DEPTH, not of the lever.**
Reading "the tiling did not help" off the triage would be reading the fixture.
The arms exist for exactly this reason and must go deeper.
