# cg_tolerance_loose design-difference table — measured **NO-GO**

**Date:** 2026-07-25
**Area:** core solver trajectory tolerance (`SimpOptions::cg_tolerance_loose`,
`adaptive_traj_cg_tol` in `core/src/simp/simp.cpp:871`). NOT `/app/`.
**Verdict:** the production flip is **BLOCKED**. Two hard bars fail. Phase B
(plumbing) was **not** written. This reproduces the handoff-129 no-go from a
filed table, which 129 never produced.
**Evidence:** `evidence/2026-07-25-cg-tol-table/` (per-fixture CSVs +
`probe_stdout.txt` + `BUILD.md`).

## The ceiling, named before measuring

Handoff 128 claimed **2.1×** fewer Jacobi iterations from this mechanism. That is
the number to beat (win) or miss (no-go). **Measured on the sanctioned harness:
1.22× on the design-box fixture. A wide MISS.**

## Harness

`core/tests/harness/cg_tol_probe.cpp` — the 110-template harness owed by 128.
It had **not** bit-rotted: it compiled and linked UNCHANGED against the current
tree (`HEAD == origin/main == 08430cc`). Nothing it measures was altered. It
drives `minimize_plastic` under `configure_production_options` on two fixtures,
toggling ONLY `cg_tolerance_loose`, interleaving tight/loose across 3 repeats.
`repeat_max|Δρ| = 0.00e+00` on every mode — the counts are deterministic, not
thermal noise.

**Parity check (BLOCKED-STOP path — clear):** the CLI job path
(`core/src/cli/run_job.cpp:391`) calls the SAME `configure_production_options`
the probe uses. No config drift; the probe faithfully measures what topopt-cli
runs.

## The table

Cost claim is the **CG-iteration ratio** (wall clock is thermally banned;
reported below only as corroboration, med of 3 with band).

### Fixture 1 — L-BRACKET LOADCASE (healthy MG regime — the B6 fixture)

| loose_tol | total CG | ratio vs tight | wall (med) | rung0 (vf .68) | rung1 (vf .52) |
|-----------|----------|----------------|------------|----------------|----------------|
| tight (0) | 30710    | 1.00×          | 1.03s      | accept         | REJECT         |
| 1e-3      | 20920    | **1.47×**      | 0.83s      | accept         | REJECT         |

Per-rung CG, tight → 1e-3: rung0 15952→11615, rung1 14758→9305. **Every rung
FALLS** (1.37× / 1.59×). Nothing rises — B6's "must not hurt" holds with margin.
Verdicts identical; shipped-rung (vf .68) mean|Δρ| = 0.00006, margin_delta 0.01%.

### Fixture 2 — DESIGN-BOX whole-domain (the regime the live 128³ job is in)

| loose_tol | total CG | ratio vs tight | wall (med) | shipped mean\|Δρ\| | gate |
|-----------|----------|----------------|------------|--------------------|------|
| tight (0) | 135169   | 1.00×          | 9.52s      | 0.00000            | —    |
| 1e-6      | 130894   | 1.03×          | 9.14s      | 0.05483            | OK   |
| 1e-5      | 125179   | 1.08×          | 8.94s      | 0.05483            | OK   |
| 1e-4      | 110301   | 1.23×          | 7.63s      | 0.05482            | OK   |
| 1e-3      | 110565   | **1.22×**      | 8.01s      | **0.05485**        | OK   |

Ladder (both modes): accept vf .68 / accept .52 / accept .38 / REJECT .26. The
shipped part is the last accepted rung, **vf 0.38**.

## Bars — all stated before measurement, scored honestly

| Bar | Requirement | Result | |
|-----|-------------|--------|-|
| **B1** | `cg_tolerance_loose=0` byte-identical to origin/main | Tree == origin/main (empty diff); default is 0; `adaptive_traj_cg_tol` returns tight when `loose<=tight`; `repeat_max\|Δρ\|=0`. No source touched. | **PASS** |
| **B2** | Gate verdicts identical every rung, both fixtures | Identical on all rungs/endpoints (`gate=OK` throughout). | **PASS** |
| **B3** | Loose margin ≥ 95% of tight (accepted rungs) | Design-box 1e-3: rung0 98.2%, rung1 104.7%, rung2 100.0%. | **PASS** |
| **B4** | Terminal (shipped) mean\|Δρ\| ≤ 0.023 | Shipped rung (vf .38) mean\|Δρ\| = **0.0548** at 1e-3 — and 0.0548 at 1e-6/1e-5/1e-4 too. | **FAIL** |
| **B5** | Design-box summed CG falls ≥ 1.5× | Best endpoint **1.22–1.23×**. Never reaches 1.5×; misses the 2.1× ceiling. | **FAIL** |
| **B6** | L-bracket: no CG rise anywhere | Every rung falls (Δ = −1051…−5453). None rise. | **PASS** |

**Two hard bars fail (B4, B5). NO-GO.**

## Why it fails — the same mechanism 129 found, now filed

The design-box regime is **basin-non-unique**: perturbing the *trajectory* solve
tolerance moves the *terminal* design by mean|Δρ| ≈ 0.055 — and it does so at
**every** loose endpoint, including the mildest 1e-6 (0.0548). This is not a
"more approximate = more drift" gradient you can tune down; the smallest nudge
already flips the basin. `max|Δρ|` is 1.000 on the shipped rung — whole voxels
swap solid↔void. The certified compliance solve stays tight, so this is not an
unsafe design (B2/B3 hold), but it **is a different design** — 2.4× over the
0.023 precedent ceiling (141/114). And the payoff that was supposed to justify
eyes-open accepting a design change isn't there: 1.22×, not 2.1×.

### Honest caveat on fixture scale (does not rescue the flip)

The harness design-box is 8×3×8 and settles to achieved vf ≈ 0.38 — it does
**not** reproduce the live 128³ job's pathology (achieved ≈ 0.030, ligaments
thinner than a coarse cell, MG latched off into a 20k-iter Jacobi grind). So the
1.22× here may *understate* the CG win the live job could see. But the harness is
the sanctioned decision instrument for this flip, the bars are stated against it,
and it independently demonstrates the **design-difference blocker (B4)** — which
is scale-agnostic non-uniqueness, not a small-grid artifact. A larger win at
128³ would not lower a 0.055 basin-flip under the 0.023 bar. **Fixtures are
maintainer-only and were not touched** to chase a friendlier number.

## What was NOT done, deliberately

- **No Phase-B wiring.** Per the task, any failed bar means the plumbing is not
  written. `cg_tolerance_loose` stays dark (default 0), exactly as it shipped.
- No escalation gate (would have been speculative; B2 shows verdicts never flip
  anyway).
- No fixture / benchmark / config edits. No weakened assertions.

## If revisited

The blocker is design non-uniqueness under trajectory-tolerance perturbation, not
solver correctness. A future attempt would need either (a) a mechanism that cuts
the Jacobi grind **without** perturbing the accepted trajectory (e.g. fixing the
MG stagnation itself so the loose tolerance is unnecessary — see
[[multigrid-coarsenability-align8-insufficient]] /
[[amg-lean-rebuild-unsmoothed-is-the-cure]]), or (b) a harness fixture the
maintainer regenerates to actually reproduce the achieved-0.030 stagnation, to
test whether the win crosses 1.5× where the live job lives — and even then B4
must be re-cleared, which this basin behavior suggests it will not be.
