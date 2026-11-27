# Lattice types round 2: the maintainer's rulings and their status

This file is kept in the repo so a session restart cannot lose it. Each item lands as its own commit, with:
- RED controls;
- stage hashes taken after it lands (`tools/`, and the procedure in `README.md`).

The full suite runs before the handoff, and then the branch is pushed.

## Done before this round's rulings
- (b), the frame-basis test: e6c32aa1.
- The evidence tooling: 96f9abc7.

## Accepted (2026-10-02)

These are accepted:
- (c) at 0c9648d3;
- the Structural view-state fix at 4f63770c;
- (b)'s frame-basis test (its commit comes after the sweep and the iOS build).

## Rulings and status

| # | Ruling | Status |
|---|---|---|
| R | **Remove the Regions popover everywhere.** UI only: the region model and every saved region stay. First confirm the Surface stage covers union, split and filter. If anything is reachable only through the popover, STOP and report. | **STOPPED.** Several capabilities are popover-only: filter-backed union + drift, the Small-faces area filter, Dissolve, Undo split, add/drop one face, a whole-region grid split. Map: scratch/evidence/map/r2-01 |
| — | The per-face Cell dial stays Aesthetic-only. | no change |
| 1 | **Floor key:** one named app constant `{"organic"}`, with a comment pointing at core's `lattice_beam_network_certified_algorithms()`. Swap to the core function at the next core sync; from then on it flips by itself. | done f15ebfe7; the swap waits for the sync |
| 2 | **Organic + Structural + manual Fit stays at 5** (organic untouched, U8). Report only: does the organic preview's cell match the run's at manual Fit under Structural? | reported: **NO**, plus a refusal (map r2-02) |
| 3 | **Stop sending `structural_certification: beam_network` on Stepped + Structural.** List the byte moves (3418E167). Land it BEFORE the next core sync, because #358 will refuse the key. The key comes back keyed on core's fact. | done 96a1b9bd (3418E167 only) |
| 4 | **Default Grade proof: run it.** Converted copies are allowed and must be labelled "converted"; 570B38E2 is the native case. Fix the app-side causes first: R4, and R1 if it is the app's. The core-side causes go in one core brief, with a minimal failing job each. The enable switch stays OFF until every plan is accepted and the run's cell histogram equals the preview's. | R4 done 20eb5edd; probe and switch (OFF) 5bf34e18. **The proof REFUSES every plan** (`dg_results.md`: 570B38E2 native, 68BF7B74/3418E167 converted; 92A8016E and 102117B9 are refused before the plan check). The 102117B9 bake found the Int8 region-owner crash (fixed 3ba44c7d). R1 (app anchor, constant per region) waits for a ruling. Core brief 2026-10-02-core-brief-default-grade-plan.md covers R2/R5/R3/R6 with fixture jobs and controls. R7 (app: overlapping prisms) is new |
| 5 | **Ceiling:** bridge `octet_aesthetic_density_ceiling()` now. Swap to `lattice_aesthetic_density_ceiling(octet)` at the next sync; the swap moves no bytes. | done 1d1bde5e (4 projects, digits); the swap waits for the sync |
| a | **`named()` returns nil for an unknown id, and every caller handles it.** This includes the two WorkspacePlaceholder misroutes (limits and face card). | done e5ab0325 |
| S | **Sync core** (#358 at 349053df or later, and main). See the list below. | merged 23e6154e (436819f6; main already in). Identity stated, readiness words and core's ceiling bridged; `lattice_beam_network_certified_algorithms` is not on #358 yet, so the constant stays. Hashes fs = f4b |

**At the sync:**
- Bring in `lattice_type_readiness_plain()` for the picker's words (brief item a).
- Swap in `lattice_beam_network_certified_algorithms()` (ruling 1).
- Swap in `lattice_aesthetic_density_ceiling(octet)` (ruling 5).
- **Call `topopt::set_build_identity(CoreFingerprint.value, <linked core build time>)` once at bridge start-up, before the first bridge run.**
  - It is set-once: a second call with a different value throws.
  - Test it: an in-app relattice receipt names the linked core's fingerprint.
  - Why: `bridge.cpp:1913` runs `lattice_variant_job` in-process, so the app's relattice receipts still stamp the fingerprint "unknown".
