# H5 — AMG re-cost under unified memory (bandwidth judgement, not capacity)

This is analysis, not a new measurement: it feeds the **measured** figures from
this run's H1 (bandwidth) and the repo's own AMG measurements into a re-costing of
the old NO-GO. Sources:

- Matrix-free geometric baseline: **88.9 MB at 804,864 reduced DOF**
  (`docs/handoffs/evidence/2026-07-23-amg-phase-1-measurement/memory_out.txt`).
- AMG **assembled-fine** prototype (smoothed prolongator): **2,071.6 MB = 23.3×**
  the baseline (`131-amg-phase-0-feasibility.md` §6c).
- AMG **memory-lean** (matrix-free fine level + **unsmoothed** prolongator, the
  Phase-1 rebuild): **210.7 MB = 2.37×** at the same DOF
  (`2026-07-23-amg-phase-1-measurement.md` §, `memory_out.txt`).
- The task's paraphrase "unsmoothed = 12× cheaper setup, 2.2× less memory" is the
  **131 §6d unsmoothed-vs-smoothed delta** *within* the AMG family (also: +1.76×
  cycles). The **2.37×** figure above is the end-to-end lean footprint (matrix-free
  fine + unsmoothed) versus the geometric baseline — the number that matters for a
  RAM budget, so it is what the table uses.

## Per-DOF footprint, scaled to production grids on THIS 16 GiB machine

Memory of these structures scales ~linearly in DOF. Bytes/DOF: matfree **110.5**,
assembled **2,573.9**, lean **261.8**.

| grid   | reduced DOF | matfree | assembled AMG (23.3×) | lean AMG (2.37×) |
|--------|------------:|--------:|----------------------:|-----------------:|
| 96³    |   2,738,019 | 0.30 GB | **7.05 GB**           | 0.72 GB          |
| 128³   |   6,440,067 | 0.71 GB | **16.58 GB**          | 1.69 GB          |

Machine: `hw.memsize` = **17.18 GB (16 GiB) total**, ~13–14 GB usable under macOS.

## Verdict — the old NO-GO was a capacity call; re-made honestly it splits

1. **The premise's "it fits" is only half-true on THIS hardware.** The **assembled
   (fat) hierarchy at 128³ = 16.58 GB EXCEEDS the machine's entire 16 GiB** — it
   still OOMs, unified memory or not. Unified memory removes the discrete-VRAM /
   host-copy split, but it does **not** remove the 16 GiB ceiling of this specific
   Mac mini. The premise imagined a large-unified-memory Mac; on a ≥32 GB machine
   the fat hierarchy fits and the constraint genuinely becomes bandwidth. On *this*
   box it does not. Capacity is still binding **for the fat variant**.

2. **For the LEAN variant the capacity NO-GO is fully reversed.** 0.72 GB (96³) /
   1.69 GB (128³) fit trivially beside the ~0.3–0.7 GB matrix-free working set.
   The Phase-1 rebuild already turned the 20 GB object into a <2 GB one; unified
   memory was never needed to make *this* fit — being lean was.

3. **Bandwidth is NOT the setup bottleneck.** One full stream of the lean 128³
   hierarchy (1.69 GB) at the H1-sustained ~140 GB/s is **~12 ms**; a whole build
   touches it a handful of times → **~60–120 ms of streaming**, negligible beside
   the geometric hierarchy build already measured at **~5 s / 66% of the solve**
   (`113` "Where the solve time goes"). The premise's guess that "the limit becomes
   bandwidth" does not hold for the lean variant — bandwidth is comfortably
   sufficient. The setup cost that remains is **CPU FP64 sparse assembly + the
   coarse LDLT factorisation**, i.e. the second half of the premise's own list.

4. **So the binding constraints, re-made, are:** (a) capacity for the fat variant
   on 16 GiB (unchanged), (b) for the lean variant, **iteration economics and the
   regime split**, not memory. Phase 1 measured that on the one fixture that is real
   optimizer output (ultra-dilute active-domain box) **geometric MG does not
   stagnate and lean AMG is 2.2× SLOWER** — AMG wins only where geometric has
   already failed (developed dense fields), and even then carries a 1.8–2.7× cycle
   penalty from the Chebyshev-for-Gauss-Seidel substitution a matrix-free fine
   level forces.

## Bottom line for the handoff

Unified memory + the lean rebuild make the AMG hierarchy **runnable on this box**
(≤1.7 GB at 128³) — a real change from the "20 GB unrunnable" framing. But the
re-cost does **not** turn AMG into a blanket solver replacement: the fat variant
still OOMs at 128³ on 16 GiB, and the lean variant is a **targeted tool for the
stagnation regime**, sitting behind the cheaper, regime-independent win already
identified (113 §B: reuse the hierarchy across K MMA iterations — a stale
preconditioner — for ~2–2.5×, which helps the geometric path too). Bandwidth,
measured, is not what stops it.
