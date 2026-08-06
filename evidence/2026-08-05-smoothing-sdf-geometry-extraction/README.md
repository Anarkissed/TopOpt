# Evidence — smoothing-sdf-geometry-extraction (2026-08-05)

Handoff: `docs/handoffs/2026-08-05-smoothing-sdf-geometry-extraction.md`

**S1 verdict: QUALIFIED.** The SDF route removes **21.5%** of the stair-step
amplitude on the maintainer's own part at its best grid spacing (B/h = 2) and
**58.9%** on the analytic sphere. Against what his app can actually ask for
(6.9% on the same subject, 11.2% on the same sphere) that is 3.1x and 5.3x.
Against the best Taubin setting PR 299 found anywhere, re-measured here on the
same subjects, it is a draw on his part (23.4%) and still a 1.8x win on the
sphere (33.5%). What it does that Taubin does not is remove **80-86% of the
min-feature violations on every one of his four rungs** at exactly preserved
volume — and what it costs is 41% worse coverage of the original CAD surface and
a certification that refuses the mesh outright. Full reasoning in the handoff's
S1, S2 and S3.

## Files

| file | what it is |
|---|---|
| `sdf_part.txt` / `.csv` | **The headline.** His own part and his own four rungs, through PR 299's metric: as exported today, isocontour-only, the full SDF pipeline, and Taubin at both the shipped maximum and the best setting PR 299 found anywhere — all on the same subjects. |
| `sdf_partsweep.txt` / `.csv` | The SDF grid-spacing sweep on his part (B/h 3.3 → 0.5), the evidence behind any slider. |
| `sdf_sphere.txt` | The analytic sphere control, R = 20 mm at his 1.620 mm voxel, swept B/h 3.3 → 0.125. The exact surface is known in closed form. |
| `sdf_features.txt` / `.csv` | S3: how far the anchor face, the protected face, the load group and every bolt bore move, signed, plus each bore's radius read back against its B-rep cylinder axis. |
| `sdf_headline.txt` | The same measurement on PR 299's own `WallMount_ShelfBracket` fixture, for continuity with PR 299's numbers. |
| `s2_certification.txt` | S2: the certified margin, mass and min-feature of each mesh through the shipped seam (`topopt-cli analyze --mesh`). |
| `s4_resolution_cost.txt` | S4: what a finer certification actually costs, measured rather than extrapolated — and the finding that the certified margin itself moves 29% between resolution 128 and 192. |
| `s4_mesh_substitution_refused.txt` | S4: the first attempt, certifying the same exported mesh at 128/192/256. 192 and 256 are REFUSED, for the same reason the SDF mesh is. |
| `sdf_gibson.txt` | S3.4: the S1 numbers under Gibson's one-voxel constraint, on his part. |
| `r3_metric_move.txt` | The proof that PR 299's metric is unchanged: `stairstep_probe`'s output before and after the metric moved into the shared header. Every geometric figure identical; only wall-clock columns differ. |
| `r1_byte_identity.txt` | The stash-rebuild proof that the shipped library is byte-identical with this work applied. Re-run after `main` moved (PRs #298/#299/#300 landed mid-task): the digest changed because MAIN changed, the two sides did not diverge either time. |
| `julia_reference/` | The paper's own implementation, rho2sdf.jl v0.1.0, driven on a case it can finish, and the port's output at the same points. `crosscheck.jl` is the driver, `crosscheck_reference.txt` its output, `crosscheck_port.txt` the comparison. |
| `job_analyze.json`, `M2_verticalStand.step` | His own job with the mode switched to `analyze`, and his part, for the S2/S4 CLI runs. |
| `s2_loadcheck.txt` | The root cause of S2's refusal: how many of the 5,165 load-tagged voxels each mesh loses. |
| `sdf_partfactor.txt` | S5: export tessellation factor 1/2/4 on HIS part — the measurement that says a "resolution" slider over triangle count would be a lie. |

Not committed, because they are ~257 MB and the probe regenerates all of them
deterministically in one command: the four certified meshes per rung
(`meshes/v0NN_{exported,isocontour,sdf,taubin}.stl`, from the `emit` mode) and
the working meshes each mode writes (`part_subject.stl`, `part_sdf.stl`,
`part_taubin.stl`, `feat_*.stl`, `subject_variant.stl`, `sdf_out.stl`).

## Reproducing

```bash
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix eigen);$(brew --prefix opencascade)"
cmake --build core/build --target sdf_geometry_probe topopt_cli -j10
```

Note `--target topopt_cli`, with an underscore — `topopt-cli` is the output file
name and make silently treats it as up to date.

```bash
EV=evidence/2026-08-05-smoothing-sdf-geometry-extraction
D=~/.topopt-worker/7ba2442960a24050          # his run

./core/build/sdf_geometry_probe part       $D/out/design.bin $D/M2_verticalStand.step $EV 2
./core/build/sdf_geometry_probe partsweep  $D/out/design.bin $D/M2_verticalStand.step $EV 2
./core/build/sdf_geometry_probe partfactor $D/out/design.bin $D/M2_verticalStand.step
./core/build/sdf_geometry_probe features   $D/out/design.bin $D/M2_verticalStand.step $EV 2
./core/build/sdf_geometry_probe gibson     $D/out/design.bin $D/M2_verticalStand.step $EV
./core/build/sdf_geometry_probe sphere     20 1.620040 2
./core/build/sdf_geometry_probe headline   core/tests/fixtures/mesh/WallMount_ShelfBracket.stl 128 2 $EV

# the meshes S2 certifies, then the certifications themselves
for i in 0 1 2 3; do ./core/build/sdf_geometry_probe emit $D/out/design.bin $EV/meshes $i 2; done
for f in $EV/meshes/*.stl; do
  ./core/build/topopt-cli analyze $EV/job_analyze.json --mesh meshes/$(basename $f) --out /tmp/s2
done
./core/build/sdf_geometry_probe loadcheck $D/M2_verticalStand.step $EV/meshes/v068_*.stl
```

The reference implementation (Julia is NOT a dependency of this repo — nothing in
`core/`, `app/` or CI runs it):

```bash
git clone https://github.com/kopacja/rho2sdf.jl && cd rho2sdf.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia -t 1,0 --project=. ../evidence/.../julia_reference/crosscheck.jl ref.txt
./core/build/sdf_geometry_probe crosscheck ref.txt port.txt
```

`-t 1,0` is not decoration — see the trap below.

## Five traps this run hit, worth not hitting again

1. **The reference implementation cannot be driven from his density field, and
   the reason is one line.** `Sign_Detection_HEX8`
   (`src/SignedDistances/SignDetection.jl:29`) builds its candidate list with a
   comprehension over *every element* inside a loop over *every grid point*. His
   run is 468,224 elements and the SDF grid at the paper's own recommended
   spacing is 487,620 points: 2.3e11 AABB tests for one field. S1 is therefore
   measured by a port, and the port is cross-checked against the reference on a
   12³ case the reference can finish.
2. **rho2sdf.jl crashes on Julia 1.12 unless you pin the thread pools.** It sizes
   its per-thread buffers with `Threads.nthreads()` and indexes them with
   `Threads.threadid()`; on 1.12 `maxthreadid()` exceeds `nthreads()` because of
   the interactive pool, so `evalDistances` throws `BoundsError: attempt to
   access 1-element Vector{Vector{Float64}} at index [2]`. `julia -t 1,0` (zero
   interactive threads) is the only invocation that ran here; `-t 4` still
   crashes, because `-t 4` gives `maxthreadid() == 8`.
3. **The nodal lattice needs a one-element zero pad or the surface hangs half a
   voxel outside the part.** Marching cubes closes the surface half a cell beyond
   the last sample; the FE domain's outer wall has no such margin. Without the
   pad the extracted surface sits 0.85 mm outside the part wherever the design
   touches the grid wall, which cost 0.13 mm of all-vertex RMS and 0.37 mm of
   oblique max — larger than the whole effect being measured, and in the
   direction that would have read as "the method damages the part".
4. **`main` can move under a long task, and it moves `file:line`.** PR #298 added
   637 lines to `core/src/cli/run_job.cpp` ABOVE the sites this task's S2/S3/S4
   cite, shifting them by ~350. Every reference here was re-checked against the
   merged tree; four had to be corrected, one of which (`analyze.hpp:33-35` for
   `non_convergent_iteration`, actually `:132-140`) was wrong in PR 299 and had
   been carried over unverified. Re-grep every `file:line` before publishing a
   handoff that took more than an afternoon.
5. **PR 299's `WallMount_ShelfBracket.stl` reference is faceted at the scale
   being measured; his own part is not.** His part is a STEP, so the reference
   can be tessellated as finely as wanted: the run's own tessellation deviates
   from a 20x finer one by rms 0.0073 mm (0.4% of a voxel). The bracket's is a
   2,224-triangle mesh whose curved faces meet at more than 30 degrees, and on it
   *every one* of PR 299's 28,884 oblique vertices classifies as "within 1.5
   voxels of a sharp reference edge". Measure the SDF route on the bracket and a
   large part of what you read is the reference's own faceting, which no smoother
   can remove because it is not on the part.
