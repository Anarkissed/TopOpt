# evidence — lattice-variant margin tolerance and mass rule

Task `lattice-variant-margin-tolerance-and-mass-rule`, branch
`claude/lattice-variant-margin-tolerance-f0902f`, branched from `966ffa6`
(`origin/main`, PR 312). Handoff:
`docs/handoffs/2026-08-08-lattice-variant-margin-tolerance.md`.

Everything here is measured on the maintainer's own run — worker job
`ca62f91cba4b422d`, `M2_verticalStand.step`, resolution 128, four rungs — except
where a second fixture is named as a control.

---

## 1 · The measured numbers, in one place

**Solver-path noise — what the band must ADMIT** (identical inputs, recycler
armed vs disarmed; relative difference in the certified worst-case margin):

| where | rungs | range |
|---|---|---|
| his run, recorded vs on-demand re-cert | 4 | 8.0e-10 … 3.5e-09 |
| his run, recorded vs in-run re-cert (his own receipts) | 4 | 9.5e-10 … 3.7e-09 |
| `M2_verticalStand.step` res 40 | 4 | 8.4e-11 … 4.4e-10 |
| `test_margin_reproduction` beam, in process | 1 | **6.77e-09** ← worst |

**Corruptions — what the band must REFUSE** (`test_margin_reproduction` B3):

| change | relative delta |
|---|---|
| the declared load off by one part in 10⁴ | 1.0e-04 |
| **ONE voxel of the design flipped to solid** | **2.0e-03** |
| the whole design 2 % denser | 6.1e-02 |

**The band: 1.0e-06** = 100 × the certification solve's own relative-residual
tolerance (`cg_tolerance` = 1e-8). **148× above the worst noise, 100× below the
smallest corruption**, and that smallest corruption is one voxel — the finest
change to a design that exists.

---

## 2 · Files

### S1 — the float equality

| file | what |
|---|---|
| `s1a_root_cause.md` | **the root cause**, with file:line, the probe, the falsifier and the in-process reproduction |
| `s1a_cert_input_probe.patch` | the temporary instrumentation (reverted; never built in production) |
| `s1a_probe_output.txt` | its raw output — two calls, identical input hashes, different `recycling`, different margins |
| `s1a_solver_regime.txt` | the falsifier: multigrid / recycler engagement on three runs, from each run's own `iterations.csv` |
| `s1b_band_separation.txt` | `test_margin_reproduction` output — the noise and the three corruptions |
| `R2_red_his_run.txt` | **RED**: all four of his rungs refusing, verbatim, before the change |
| `S1cd_materialise.txt` | **GREEN**: all four materialising, with wall times, receipts and sizes |
| `s1cd_materialise.sh` | the script that produced it |
| `S1d_bytes_vs_eager.txt` | the regenerated mesh against the run's own file, triangle by triangle |
| `s1d_compare_stl.py` | the comparator |

### S2 — the recommendation

| file | what |
|---|---|
| `R2_red_s2_recommendation.txt` | **RED**: the 4 failing tests with the old rule restored |
| `S2d_recommendation_before_after.txt` | **before/after on his run**, both masses, both lines, and every fallback |

### S3 — the `out/` cleanup

| file | what |
|---|---|
| `s3_cleanup_scope.md` | the gate test by name, what a cleanup would delete/keep, **what becomes unrecoverable (measured)**, which world it assumes, and his 5.17 GB |

### Bars

| file | what |
|---|---|
| `R1_byte_identity.txt` | stash-rebuild checksum, **with the base-vs-base control** that separates the wall clock from real change. 0 unexpected differences |
| `r1_byte_identity.sh` | the script |
| `R2_green.txt` | core 115/115; app 1377 tests / 8 failures, all 3 pre-existing 3MF cases, proven pre-existing |
| `R4_no_verdict_moves.txt` | every verdict on his run, recorded vs on-demand |
| `R5_assertion_census.txt` | app + core message census, and the one production relaxation located |
| `assertion_census.sh` | the script |

---

## 3 · Reproducing

```bash
# core
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_REQUIRE_DEPS=ON \
  -Dlib3mf_DIR=<repo>/.vcpkg/installed/arm64-osx-dynamic/share/lib3mf \
  -DCMAKE_PREFIX_PATH="$(brew --prefix opencascade);$(brew --prefix eigen);<repo>/.vcpkg/installed/arm64-osx-dynamic"
cmake --build build -j 10 && (cd build && ctest)

# the four rungs, on demand, from {job.json, design.bin} only  (~22 min, 22 GB free)
bash evidence/2026-08-08-lattice-variant-margin-tolerance/s1cd_materialise.sh

# app  (needs ./app/scripts/build_core.sh first, WITHOUT lib3mf in a worktree)
cd app/TopOptKit && swift test
```
