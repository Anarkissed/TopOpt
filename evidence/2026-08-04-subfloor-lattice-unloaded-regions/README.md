# evidence — 2026-08-04-subfloor-lattice-unloaded-regions

Handoff: `docs/handoffs/2026-08-04-subfloor-lattice-unloaded-regions.md`

Builds on `evidence/2026-08-04-protect-freeze-vs-solidity/` — that task's §10
(`item8_subfloor_floor.txt`) is the measurement the 0.20 threshold is derived
from, and its `M2_verticalStand.step` / `job_maintainer.json` are the part and
the job document reused here rather than re-captured.

| file | what it is |
|---|---|
| `s1_byte_identity.sh` / `.txt` | **S1**, in FOUR parts, because this PR contains two changes with different byte-identity properties: **A** no-lattice base-vs-branch (must be identical), **B1** armed-but-inert (identical but for the reporting block the receipt gains), **B2** armed AND FIRING (the solid ladder must be bit-identical — the property §7's leak broke), **C** lattice base-vs-branch (deliberately different: the leak fix; asserts only that no verdict flips). Originally the load-bearing bar: a graded swept lattice job that does NOT opt in, run by a CLI built from the stashed base tree and by one built from this branch, sha256 per artifact. Asserts the two binaries DIFFER before comparing anything — the first version of this bar passed vacuously because `--target topopt-cli` matched the existing binary *file* and built nothing. |
| `s2_per_region.txt` | **S2**, first half: each of the maintainer's 8 include regions measured SEPARATELY on his own part. Exactly one qualifies (0.1707 of peak). No solve ran — the demand is the rung's own von Mises out of `fields.bin`. Produced by `subfloor_region_probe`. |
| `s2s4_wall_case.py` / `.txt` | **S2 + S3 + S4** on the case where retention actually fires: his job with the lattice scoped to that one wall, retention off vs on, resolution 128. 25.8 % → 100 % latticed, 822 retained at 0.74–4.45 cells per member, composite margin Δ +0.0853 % against a 0.10 % bound stated in the script before the numbers were read. |
| `s2s3s4_maintainer_case.py` / `.txt` | The same three bars on his job **exactly as he wrote it**. Retention retains NOTHING (his region union measures 0.9102 of peak) and the margin delta is 0.0000 % on every rung. Kept because it is the honest answer to "does his job work today", and because it is why `s2_per_region` had to exist — you cannot price a relaxation on a run where the relaxation did not happen. |
| `s6_gate_table.sh` / `.txt` | **S6**: five configurations × every rung, solid AND composite verdict + margin, voxel-classification flips, and the 1e-9 negative control. Four existing paths base-vs-branch (all exactly 0.00e+00); one armed-vs-not on a region measured quiet. Fails loudly if the armed row's region is empty or has nothing below the floor — both happened while building it, and both produce a serene all-zero row that tests nothing. |
| `s7_forecast.txt` | **S7**: the pre-flight forecast with and without the opt-in key. F3 did NOT already cover this. The forecast's below-floor population count is EXACT (252 forecast, 252 in the real run); the predicate itself it cannot evaluate, and it says so rather than guessing. |
| `s9_determinism_and_ladder_coupling.txt` | **S9**, and the full arc of §7's defect in four parts: (1) the control — same job twice is byte-identical, so the pipeline is deterministic here and anything below is CAUSED; (2) the defect — arming retention moved rungs 0.52/0.38/0.26 by 40/380/416 voxel flips while the rung it fired on stayed identical; (3) after the fix — 0/0/0, arming changes no design at any rung; (4) what the fix costs — it also moves the OFF baseline (32/207/282) because rung k+1 no longer consumes lattice-polluted solver state. |
| `r0_preregistration.md` | **THE BUDGET, committed BEFORE the per-region predicate was written or measured.** Per-region is a WIDENING, and the certification cannot price it, so exposure is bounded by policy: aggregate cap 3.0 % of the printed set (~3.2x the one verified case at 0.930 %), over budget ⇒ retain nothing. Acceptance bounds A-1..A-4 stated in the same document. |
| `r1_per_region.txt` | Per-region measured on the maintainer's own part: **one** of his eight regions qualifies (0.1707), the aggregate is **0.930 %** against the 3.0 % cap, and the per-region and part-level readings AGREE. Produced by `subfloor_region_probe`. |
| `r2_additivity.sh` / `.txt` | **A-1/A-2/A-3.** Two quiet regions, alone and together. **A-2 EXCEEDED**: a single region at 2.889 % exposure — INSIDE the cap — moved the composite margin +0.1801 %, 1.8x the pre-registered 0.10 % bound. **A-3 UNTESTED**: the two regions overlap (AB == B at every rung). The script now FAILS LOUDLY when an armed configuration retains nothing — its first two runs reported "A-3 MET" vacuously. |
| `r3_verdict.md` | **THE VERDICT: BLOCKED-STOP, per-region is BUILT, TESTED and DISARMED.** The two pre-registered numbers are mutually inconsistent on a real part; the pre-stated rule was report the number, not retune the threshold. Also records two side findings: exposure CLIMBS down the ladder as the printed set shrinks, and the union reading is what stays shipped. |
| `ctest.txt` | full core suite |
| `app_tests.txt` | app package suite (`swift test`, macOS slice built WITH lib3mf) |

Reproduce:

    cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
    cmake --build core/build --target topopt_cli test_grading subfloor_region_probe
    #                                     ^^^^^^^^^^ underscore. `topopt-cli` is the
    #                                     BINARY name and silently matches as a file.
    ./core/build/test_grading                      # 25137 checks
    ctest --test-dir core/build --output-on-failure --no-tests=error

    # S1 — needs a second build dir for the stashed base tree
    cmake -S core -B /tmp/build-base -DCMAKE_BUILD_TYPE=Release
    evidence/2026-08-04-subfloor-lattice-unloaded-regions/s1_byte_identity.sh \
        core/build /tmp/build-base /tmp/s1

    # S6 — base CLI from the stash-rebuild above
    evidence/2026-08-04-subfloor-lattice-unloaded-regions/s6_gate_table.sh \
        /tmp/build-base/topopt-cli core/build/topopt-cli /tmp/s6

    # S2 — his job at resolution 128 (each run is ~40 min on an M2)
    #   run job_maintainer.json (model path fixed) with and without
    #   grading.retain_subfloor_in_unloaded_regions, then:
    ./core/build/subfloor_region_probe <job.json> <off-run-dir> 0.68
    evidence/2026-08-04-subfloor-lattice-unloaded-regions/s2s4_wall_case.py \
        <wall-off-dir> <wall-on-dir>

    # app
    ./app/scripts/build_lib3mf_macos.sh && ./app/scripts/build_core.sh
    TOPOPT_ASSERT_FRAME_BUDGET=0 swift test --package-path app/TopOptKit
