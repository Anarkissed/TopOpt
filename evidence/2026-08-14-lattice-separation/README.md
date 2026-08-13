# evidence — 2026-08-14-lattice-separation

Handoff: `docs/handoffs/2026-08-14-lattice-separation.md`
Branch base: **`726160c`** (PR 331 `face-regions`) — REBASED onto it when the
interrupt withdrew §8. Original base `9e96beb`.

| file | what it is |
|---|---|
| `r5_r7_failing_first.txt` | R5 written to FAIL FIRST. `LatticeSeparationTests.swift` compiled against a `git checkout` of the two pre-task wizard files; the API had no way to express the coupling, so the failure is a compile failure — the same shape as PR 328's L5. |
| `r6_sample_before_reveal0.png` | §7/R6 — the wizard's own Stage-A mesh through the app's own `MeshRenderer` at `reveal = 0`, which is what the page passed on entry. A black frame: **0 lit pixels of 230,400**. |
| `r6_sample_after.png` | The same mesh at `LatticeWizardReveal().value` = 1. **61,794 lit pixels.** |
| `r9_assertion_census.txt` | R9 — assertion-message census by KIND, base vs branch. Every count unchanged or up. |
| `app_tests.txt` | The `swift test --package-path app/TopOptKit` the `app-macos` CI job runs. |
| `ctest.txt` | Core's suite, **120/120** on the REBASED tree. `core/` is untouched by this branch (`git diff --stat 726160c -- core/` is empty) — but the base moved onto one that does touch it, so the suite is re-run rather than the pre-rebase 119/119 being quoted for a tree that no longer exists. |

## Two things to read with care

**The three app failures are this machine, not this branch.** (1497 executed on the rebased tree — PR 331's 26 region tests and this task's 39 are both in it.) All three are
`AppModelTests.test*ThreeMF*` and they fail with core's own message: "3MF import
requires lib3mf, which is not available in this build". They failed identically
on this branch before any source edit. Provisioning lib3mf here makes the test
bundle fail to LINK (undefined `_lib3mf_*`) — the known worktree trap — so the
slice is deliberately 3MF-free. CI provisions lib3mf and runs the same command,
so the honest reading is **1449 of 1452 local, against CI's own denominator**.

**`r6_*.png` are renders, not device screenshots** — but they are renders through
the SHIPPING pipeline: the real `MeshRenderer`, the real `viewer_fragment` shader
whose `discard_fragment()` is the defect, the real mesh, the real camera framing
and the real clear colour. The lit-pixel counts are ASSERTED in
`LatticeSeparationEvidenceGen`, so the capture is a test rather than a picture.
