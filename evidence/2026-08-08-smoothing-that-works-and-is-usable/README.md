# evidence — smoothing-that-works-and-is-usable

Handoff: `docs/handoffs/2026-08-08-smoothing-that-works-and-is-usable.md`

| file | what it is |
|---|---|
| `r1_byte_identity.txt` | R1. The empty diff over every shipped core source; the base-tree vs branch A/B of `ViewerMeshSignature.contentHash`; and the four deliberate behaviour changes, named rather than buried. |
| `r2_s1a_camera_fails_today.txt` | R2 for S1(a). The fix disabled in the source, the **unmodified** tests re-run. 9 failures. The camera goes from his zoom (distance 0.9108709, panned target) back to the framed default (2.6155658, model centre) on one stroke; the settle restart count reads 2 instead of 1. |
| `r3_usable_path.txt` | R3. The whole path walked on his own rung-068 mesh: stroke → tint → preview → camera unchanged → rungs 1/2/3 → Smoothed reachable with no certification. |
| `r5_assertion_census.txt` | R5. Every removed assertion-bearing line in the diff, accounted for by name. Two, both explained. Plus the proof that the 247-line harness drop is a MOVE. |
| `r5_instrument_move.txt` | The move itself: `operator_bakeoff_probe` rebuilt and re-run after PR 306's instruments were lifted into a shared header, diffed against PR 306's committed output. Every geometric figure identical; only wall-clock differs. |
| `s1c_stroke_latency.txt` | S1(c)/S1(d). Stroke-release → updated-preview on his 14.4 MB variant, before and after, with the STL re-import split from the smoothing. **States which build it ran in** — a plain `swift test` is DEBUG and puts the cost somewhere else entirely. |
| `s2_cut_population_probe.txt` | S2. The full run: the CAD/cut split on all four rungs, the "is a finer extraction a reference?" control, the bake-off table, the C4 bitwise check, and the calibrated arm. |
| `s2_cut_population.csv` | The same, machine-readable. |

## Reproduce

```bash
./app/scripts/build_cli_macos.sh          # core + OCCT + lib3mf (CI's exact pin)
./app/scripts/build_core.sh               # vendor the xcframework for the app package

# S2
cmake --build core/build -j8 --target cut_population_probe
D=evidence/2026-08-03-multiscale-lattice-to
./core/build/cut_population_probe $D/m2_multiscale_final/design.bin \
    $D/M2_verticalStand.step evidence/2026-08-08-smoothing-that-works-and-is-usable

# the harness move is behaviour-preserving
cmake --build core/build -j8 --target operator_bakeoff_probe
./core/build/operator_bakeoff_probe /tmp/bo   # diff against PR 306's bakeoff_probe.txt

# S1 + R3. RELEASE — the app ships release, and the debug figures are ~40x off.
cd app/TopOptKit && swift test -c release
```

## The two harnesses are harnesses, not ctests

`cut_population_probe` prints tables and writes CSV. It asserts only the
preconditions that would make its own numbers meaningless — that the STEP
imported, and that the mesh it measured is the real one. The bars live in the
Swift suite (`SmoothingStrokeCameraTests`, `SmoothingPreviewNoDiskTests`,
`SmoothingUsablePathTests`, `SmoothingPreviewGateTests`), which run in CI.
