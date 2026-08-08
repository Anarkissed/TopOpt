# evidence — shell-at-the-runs-printed-iso (2026-08-09)

Task `2026-08-09-shell-at-runs-printed-iso`. Handoff:
`docs/handoffs/2026-08-09-shell-at-runs-printed-iso.md`.

Branch `claude/shell-at-runs-printed-iso-4b8e12`, **stacked on**
`fix-inward-wound-normals` (`1ac40d0`) → `strut-clip-matches-shell` (`c586e8d`).
Every baseline here is `1ac40d0`, not `main`.

## Read this first

**The task was filed on a false premise, by me.** It claimed `check_v3` is called
with the file-scope `kIso = 0.5` unconditionally. `analyze.cpp:143` declares a
SECOND `kIso` — `const double kIso = printed_iso;` — inside `analyze_fixed_design`
(body = lines 133–564, brace-matched), and :389 binds to that one. The exported
shell is already cut at the run's own printed iso.

`s1_shell_iso.txt` settles it on a real multiscale run's artifacts;
`r2_red.txt` / `r2_green.txt` settle it exactly, on a controlled field, via the
new ctest.

## Files

| file | what |
|---|---|
| `s1_shell_iso.txt` | the measurement on a real multiscale run, **including the caveat** that only topology is compared and why a `design.bin` reconstruction is not trustworthy here |
| `r2_red.txt` / `r2_green.txt` | the new `shell_iso_provenance` ctest red against the state the filed claim describes (`v3.mesh` stuck at 188 tris for both isos), then green (764 at the multiscale iso) |
| `multiscale_run/` | the multiscale job, its `[multiscale] armed` lines, and its lattice receipt — **0 protruding vertices of 786,120**, which is §B's prediction checked |
| `r1_byte_identity.txt` | the forecast path byte-identical across the two binaries (asserted to differ first), with the uniform branch genuinely exercised |
| `job_fc.json` | the forecast-only job used for it |
| `r6_assertion_census.txt` | message census, baselined on `1ac40d0` — nothing removed |
| `ctest_full.txt` | core 117/117 |

## §B — the prediction, and it held

Stated before running: the multiscale printed iso is **0.025235**, below 0.5, so
the shell there encloses MORE material and PR 316's no-protrusion invariant
should get **easier**, never harder.

Measured: the multiscale run completed, `max_strut_protrusion_mm` **0**,
**0 of 786,120** vertices outside. The refusal I warned about when filing does
not fire. `test_shell_iso_provenance` case 2 pins the direction as an assertion
rather than a one-off observation.
