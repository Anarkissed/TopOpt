# Evidence — smoothing-must-actually-smooth (2026-08-05)

Handoff: `docs/handoffs/2026-08-05-smoothing-must-actually-smooth.md`

**Verdict: NO-GO.** `constrained_taubin_smooth` removes 5.5% of the stair-step
amplitude at the strength the app can ask for, and at most 10.6% at any setting
in the family. The guard the brief suspected does not halt it on the maintainer's
part — it applies 20/20 pairs.

## Files

| file | what it is |
|---|---|
| `stairstep_probe.txt` | The full S1 + S2(a) run. Arithmetic, the STL round trip, baseline, the pair sweep (constrained and unconstrained), the λ\|k_PB sweep, the analytic sphere control, the resolution control, the export-factor control, and the cost breakdown. |
| `stairstep_sweep.csv` | Every sweep row as data — oblique and all-vertex deviation, dihedral, max shift, volume drift and bound, min-feature before/after, whether the guard fired, wall time. |
| `sphere_profile.png` | **The picture.** Equatorial radius-vs-angle of a 20 mm sphere voxelized at the maintainer's voxel size, unsmoothed / 20 pairs / 160 pairs, against the true circle. The smoothed traces sit on top of the unsmoothed one. |
| `sphere_profile_baseline.csv`, `sphere_profile_pairs20.csv`, `sphere_profile_pairs160.csv` | The data behind that plot. |
| `s3_reproduction_failing.txt` | The three S3 preview-gate reproductions **failing** on unfixed code, verbatim. |
| `r1_byte_identity.txt` | The R1 stash-rebuild proof: 45 object files, two fresh identically-configured build dirs, same digest. |
| `job.json`, `job_nobox.json`, `WallMount_ShelfBracket.stl` | The maintainer's own job (mode switched to `analyze`) and part, for the CLI round-trip timings. `job_nobox` is the design-box-removed control. |

Not committed, because they are large and the probe regenerates all of them
deterministically in one command: `subject_variant.stl` (8.2 MB — the mesh the
probe measures, the part's own occupancy at res 128 through
`marching_cubes_resampled(factor 2, Tricubic)` and back through STL, which is
what the app hands the smoother), and the two scratch control meshes the probe
writes and deletes.

## Reproducing

```bash
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix eigen);$(brew --prefix opencascade)"
cmake --build core/build --target stairstep_probe topopt_cli -j8

./core/build/stairstep_probe \
  core/tests/fixtures/mesh/WallMount_ShelfBracket.stl 128 2 \
  evidence/2026-08-05-smoothing-must-actually-smooth
```

Note `--target topopt_cli`, with an underscore — `topopt-cli` is the output file
and make silently treats it as up to date.

That run writes `subject_variant.stl` into the evidence directory; the S2(a)
timings below need it, so run the probe first. From the repo root:

```bash
EV=evidence/2026-08-05-smoothing-must-actually-smooth
/usr/bin/time -p ./core/build/topopt-cli analyze $EV/job.json \
    --mesh subject_variant.stl --out /tmp/an_cert          # certification alone
/usr/bin/time -p ./core/build/topopt-cli analyze $EV/job.json \
    --mesh subject_variant.stl --smooth 1.0 --out /tmp/an_smooth   # + smoothing
```

The S3 reproductions (they `XCTSkip` their final assertion — the recorded failure
is in `s3_reproduction_failing.txt`; see the handoff's R5 note):

```bash
cd app/TopOptKit && swift test --filter SmoothingPreviewGateTests
```

## Two traps this run hit, worth not hitting again

1. **The STL round trip is not cosmetic.** The same 82,104 vertices read
   min-feature **2162** in memory and **6** after a write/read through STL.
   Marching cubes places crossings exactly on coarse voxel centres at export
   factor 2, so the inside/outside tests are knife-edge in double precision and
   float32 rounding moves them. Measure the mesh the app actually smooths — the
   round-tripped one — or the guard's verdict comes out backwards.
2. **Export tessellation is not a substitute for resolution.** Raising
   `smooth_factor` 1 → 2 → 4 leaves the deviation flat at ~0.33 mm while the
   dihedral RMS falls from 13.47° to 5.31°. An intrinsic roughness metric would
   have scored that as a big win; it is the same surface in the same wrong place.
3. **The app's smoothing load case sets `minimize_plastic = false`**
   (`SmoothBrushKit.swift:119`), which puts `build_production_loadcase` on the
   growth path. A probe built with the default `ProductionLoadCase` is answering
   about a different configuration.
