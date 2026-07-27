# Evidence — Active Domain arming review (2026-07-27)

Companion to `docs/handoffs/2026-07-27-ad-arming-review.md`. All CG counts, escape
counts, latch iterations and convergence outcomes are deterministic (P-core pin, matfree
threads 6); wall times are indicative only (shared host).

## Headline results
- **Result 1 (stagnation +26% CG) REPRODUCES to the digit** — but is one sample of a
  coin-flip (L tight is −9%). `repro_stag12.log`, `mechanism_result1_analysis.txt`.
- **Result 2 (AD-on non-convergence at L) DOES NOT REPRODUCE** faithfully — AD-on L
  converges (tight 223863 CG, draft 140162 CG). The earlier "throw" was a CG-cap artifact
  (AD-off threw at the same cap). `repro_L_convergence_faithful.log`, `result2_refutation.txt`.
- **Recommendation: disarm AD** — no reliable benefit in the stagnation regime it targets,
  non-bit-identical, gate margin miss; redundant with draft. `gate_table_interpretation.txt`.

## Files
| file | bar / question | what it shows |
|---|---|---|
| `repro_stag12.log`, `stag.csv` | R1 result 1 | rec 15349 → rec+AD 19329 (+25.9%), latch@3/1008 |
| `mechanism_stag_per_iter.log` | mechanism | per-iteration CG; deep-Jacobi events redistribute |
| `mechanism_result1_analysis.txt` | mechanism | trajectory divergence, +146 restriction overhead |
| `repro_L_convergence_faithful.log` | R1 result 2 | AD-off & AD-on L both CONVERGE, uncapped |
| `result2_refutation.txt` | R1 result 2 | the CG-cap confound, named; why AD-on converges |
| `repro_L_ADon_cap2000.log`, `repro_L_ADoff_cap2000.log` | R1 result 2 | the confound: BOTH throw at cap 2000 |
| `repro_L_draft_stack.log` | robustness | shipped rec+AD+draft converges at L (0.87×) |
| `repro_L_ADon_scaleharness_uncapped.log` | R1 result 2 | corroboration via the exact PR 209 harness |
| `fourposture_healthy_arm{8,12,16}.log`, `interaction.csv` | R2 | four postures across healthy/stag grids |
| `four_posture_table.txt` | R2 | assembled table; AD sign tracks stagnation not size |
| `question_d_ad_redundant.log` | (d) | draft does 92% of the win; AD marginal under draft |
| `gate_table_adg_arm.log`, `gate/` | R3 | ARMED vs DISARMED gate ladder (verdicts identical) |
| `gate_table_interpretation.txt` | R3 | reading of the gate table for the recommendation |

## Harnesses (in `core/tests/harness/`, not CTest targets)
- `ad_stag_mechanism_probe.cpp` — per-iteration CG/MG/latch on big-stag (result 1 mechanism)
- `ad_redundant_under_draft_probe.cpp` — 2×2 {AD}×{draft} on big-stag (question d)
- `ad_L_convergence_probe.cpp` — AD-off vs AD-on L, tight, uncapped (result 2, faithful)
- `ad_L_draft_probe.cpp` — rec+draft vs rec+AD+draft at L (shipped-stack robustness)

Recipe: see the handoff's "Recipe" section.
