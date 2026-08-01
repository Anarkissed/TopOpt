# Predictions, recorded BEFORE any measurement (W1's requirement)

Written 2026-08-01, before the first run of `geneo_standing_probe`.
Machine: Apple M2 Pro (10 cores), 16 GB, Apple clang -O2.

## The arithmetic that drives every prediction

The observed operating point is ~275 Jacobi-CG iterations per solve — NOT the
1,685-41,063-iteration stagnation regime GenEO was armed for. At that operating
point the deflation's OVERHEAD is priced in the same currency as the solve:

* **A coarse-operator REFRESH costs N_t FULL matvecs** (`build_coarse_operator`
  loops q = 0..N_t applying `apply_kgg_raw`), plus an N_t^3/3 dense LDLT.
* The refresh is **MANDATORY on every solve whose moduli moved** — and in a
  topology-optimization ladder the moduli move EVERY design iteration. So the
  refresh is not amortisable across design iterations the way the BASIS is.
* Phase 2 measured N_t = 595 at ng = 156,198. The armed production run showed
  N_t = 7,588.

So the standing posture's per-design-iteration price is roughly
`N_t matvecs (refresh) + k_geneo CG iterations`, against a baseline of
`~275 CG iterations`. For it to pay at all:

    N_t + k_geneo  <  275

**Phase 2's own N_t (595) already exceeds the entire baseline solve by 2.2x.
The armed run's N_t (7,588) exceeds it by 28x.**

## Stated predictions

**W1 — standing GenEO LOSES on this fixture.** I expect CG iterations to fall
sharply (275 -> somewhere in 60-150, i.e. the literature's contrast-independence
IS real), and total WALL to get *worse*, by roughly 2-10x, entirely because of
the per-solve refresh. I expect ~1-3 basis builds and one refresh per design
iteration.

**W2 — the BASIS amortises fine; the REFRESH is what does not.** I expect
builds/run in the low single digits, so design-iterations-per-build in the
10-40 range, comparable to DTU's 28.6. That is not the problem. The problem is
the term DTU does not pay per design iteration at all.

**W3 — this is the decisive experiment, not a footnote.** Driving the eigenvalue
cut down drives N_t down, and N_t is the refresh price. I predict the *smallest*
basis wins on wall despite losing on iterations — DTU's finding, but here for a
sharper reason than theirs. My prediction: standing GenEO only reaches parity
with plain Jacobi if N_t falls to roughly O(100) or below, and I am not confident
a cut that small still deflates enough to keep CG under ~200. Best case at the
low end: parity, maybe 1.2-1.5x. I do NOT predict a clean win.

**W4 — I expect PR 257's finding to hold over the paper's, i.e. LARGER tiles
win here** (16^3 > 8^3 > 4^3 on wall), because larger agglomerates mean fewer
subdomains, hence fewer eigenvectors, hence smaller N_t and a cheaper refresh —
which on this fixture is the dominant cost. Note this is the same conclusion as
PR 257's but for a partly different reason (PR 257: the subdomain must SPAN the
contrast feature; here: N_t is the price).

**W5a — diag(K_agg) weighting: cheaper BUILD, roughly unchanged N_t and
iterations.** Build time should fall noticeably (the B-applies collapse from a
full element pass to a scale). Since the build is not the binding cost, I expect
this to change the verdict by ~nothing.

**W5b — I expect the shipped rebuild_factor=2.0 policy to MISS the continuation
points**, because the mandatory refresh keeps the reused basis good enough that
a solve rarely exceeds 2.0x its post-rebuild reference. I expect few or zero
policy rebuilds, and forced rebuilds at beta changes to cost more than they save
at this operating point.

**W6 — I expect PASS.** Every added term is SPD around the same Jacobi base and
the stopping test is untouched, so u should match to solver tolerance and reruns
should be bit-identical (fixed LOBPCG seeds, fixed merge order).

**W7 — healthy multigrid should be far cheaper than either**, and standing GenEO
should be structurally INERT on it (0 builds), because a healthy solve never
enters `mf_cg_solve` at all.

## What would falsify the above

If N_t comes out one to two orders of magnitude below phase 2's 595 on this
fixture — plausible if the developed bracket has far fewer near-disconnected
subdomains than the phase-2 fixture's 98/100 — then the refresh is cheap and
standing GenEO could win outright. That is the single number to look at first.
