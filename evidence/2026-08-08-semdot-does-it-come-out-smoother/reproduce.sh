#!/bin/sh
# reproduce.sh — task semdot-does-it-come-out-smoother (2026-08-08)
#
# Everything here is deterministic: no RNG, no threading in any measurement loop,
# and the two S2 arms run SEQUENTIALLY so their wall numbers compare like for like.
# The host was NOT idle when the recorded numbers were taken (two other worktrees
# were running solver jobs); host_contention.txt records that minute by minute,
# and the ITERATION counts — which contention cannot move — are the primary cost
# reading.
#
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang, Release.
# Run from the repo root. Roughly two to five hours for step 3.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EV="$ROOT/evidence/2026-08-08-semdot-does-it-come-out-smoother"
cd "$ROOT"

# ── 0. build, at CI's DENOMINATOR ───────────────────────────────────────────
# lib3mf is not a Homebrew formula, so a plain configure silently drops the two
# 3MF tests and a local "114/114" is not CI's 116. Point the prefix path at the
# vcpkg tree build_lib3mf_macos.sh provisions (or run that script first).
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/eigen;/opt/homebrew/opt/opencascade;$ROOT/../.vcpkg/installed/arm64-osx-dynamic" \
  >/dev/null
cmake --build core/build -j8

# ── 1. the correctness bar: the map itself (registered in ctest as `semdot`) ──
./core/build/test_semdot | tee "$EV/unit_semdot.txt"

# ── 2. R1 — OFF IS BYTE-IDENTICAL, base detached worktree vs branch ─────────
"$EV/r1_byte_identity.sh" main

# ── 3. S2 — HIS PART, BOTH WAYS, resolution 128, all four rungs ─────────────
#     job_simp.json is his captured job document (lattice/grading removed — see
#     run_s2.sh's header for why); job_semdot.json is that plus one key.
"$EV/run_s2.sh"

# ── 4. the measurement ──────────────────────────────────────────────────────
cmake --build core/build --target semdot_surface_probe
./core/build/semdot_surface_probe "$EV/s2_simp/design.bin" \
    "$EV/s2_semdot/design.bin" "$EV/M2_verticalStand.step" "$EV" \
    | tee "$EV/s2_surface_probe.txt"
"$EV/s2_cost_and_verdict.py" "$EV" | tee "$EV/s2_cost_and_verdict.txt"

# ── 5. R7 — the assertion-message census ────────────────────────────────────
"$EV/r7_assertion_census.py" main

# ── 6. the suite, at CI's denominator ───────────────────────────────────────
(cd core/build && ctest --output-on-failure) | tee "$EV/ctest_116.txt"
