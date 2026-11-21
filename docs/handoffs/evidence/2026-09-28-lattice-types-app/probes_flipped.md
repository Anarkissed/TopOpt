# Core-capability probes: what linking #358 flipped (03-app-spec §1)

2026-10-01, PR #354's branch. The linked core is **19a1443bee65**: PR #358 at 4a1ccc45, merged one
way, with `build_core.sh` rerun.

**Context.**
- This branch **first** linked #358 at merge **74e510c4** (2026-09-28). No app handoff recorded
  the flips then, so this file reports them from the pre-#358 core: 74e510c4^1 = eb318951.
- The later syncs (7793ee0f and this one, 19a1443b) changed nothing a probe reads. Since
  7793ee0f, core's source has changed only in three data files: `lattice_print_tests.json` and
  the two Flexible files.
- So **the flips below have been live since 2026-09-28**, and every stage hash in the variant-face-walls
  handoff since then already includes them.

**Method.** A static read of each probe's core question on both cores, cross-checked at
runtime on the linked core by `LatticeCoreProbeReportTests`. That test prints every value and pins
it, so the next "sync core" that flips one fails by name. Runtime values on 19a1443bee65:

```
coreCarriesTheSampleRepairFix = true          steppedStructuralCertificationWired = true
regionFrameAxesWired = true                   steppedCellsWired = false   (BROKEN PROBE)
organicStructuralCertificationWired = true    organicSyntheticStressWired = true
organicProbeWired = true                      gradingSchemaProbeIsReliable = true
latticeSchemaAccepts(emit_organic_spans) = true   gradingSchemaAcceptsCellMode(fit) = true
gradingSchemaAccepts: intent, stepped_min_tile_mm, max_relative_density, shape_grade,
  shape_grade_band_mm, structural_certification, retain_subfloor_in_unloaded_regions,
  subfloor_stress_fraction, subfloor_per_region, report_region_cells = true
gradingSchemaAccepts(organic_overhang_fillet) = false
latticeGeneratableTopologies = ["octet"]
latticeCertifiableTopologies = ["octet","sc","bcc","fcc","diamond","kelvin","rhombic"]
```

## Flipped false → true at the first link (74e510c4)

| probe | the core question | what changed on screen or in the job |
|---|---|---|
| `coreCarriesTheSampleRepairFix` (TopOptKit.swift:2032) | grading key `stepped_min_tile_mm` | The wizard's "Repairs need the newer core (PR 358)" note is gone. The organic sample cube draws core's print-repair emission. |
| `steppedStructuralCertificationWired` (:2033) | grading `structural_certification` for stepped | Stepped + Structural jobs carry `structural_certification: beam_network`. **The preview:** under Structural, Stepped and Default Grade cells now take the aesthetic cells-per-member floor (2), not the homogenised one (5), so cells are about 2.5x larger. See "Raised" below. |
| `regionFrameAxesWired` (:2024) | face-region `frame_u` / `frame_w` | Every face region in every job carries its frame axes. Nothing changes on screen. |
| `gradingSchemaAccepts(max_relative_density)` (LatticeSettings.swift:933) | grading key | Every graded non-organic job with Allow quilt off (the default) carries `max_relative_density` ≈ 0.219, the octet aesthetic ceiling. Core now caps the grade there. |
| `gradingSchemaAccepts(shape_grade / shape_grade_band_mm)` (:942, :944) | grading keys | Stepped and Default Grade jobs with a shape band carry `shape_grade`, and the run draws the solid outline beam. |
| `gradingSchemaAccepts(stepped_min_tile_mm)` (:919) | grading key | Stepped + Structural jobs carry it. Core reads it only on the `stepped_cells` path, which the app never takes (see below), so it has no effect. |

Also new with #358, though not probes: the receipt keys `span_count`, `span_length_mm` and
`unsupported_spans`. They switch on the organic preview-versus-run strut check and the "spans
cross open air" line.

## Flipped true → false

- `gradingSchemaAccepts(organic_overhang_fillet)`: #358 removed the key. For the 74e510c4 build
  only, the "Flare overhangs" toggle went grey. 026904dd then removed the toggle, so nothing
  remains of it.

## Did NOT flip: a broken probe

**`steppedCellsWired` (TopOptKit.swift:2008-2015) is false on every core**, by its own construction.
- Its document puts lattice `cell_mm` and `strut_radius_mm` beside a grading block, which core
  refuses as a pair: *"lattice "cell_mm" is not allowed with a "grading" block"*.
- The same document without those two keys parses; `stepped_cells` itself is accepted (proved by
  `testSteppedCellsWiredIsABrokenProbe`).
- So **the app has never sent `lattice.stepped_cells`**, and Stepped and Default Grade runs use
  core's own planner instead of the preview's packed plan. That is an M5 (preview = run) gap.
- **Not fixed: maintainer's ruling needed.** Fixing the probe adds `stepped_cells` to every
  Stepped or Default Grade octet job with a baked plan. That is an octet job-byte move, which the
  task's U8 and stop rule forbid deciding in the app.

## Unchanged

- `organicStructuralCertificationWired`, `organicSyntheticStressWired` and `organicProbeWired`;
- `latticeSchemaAccepts(emit_organic_spans)`;
- intent, every `organic_*` key and the four subfloor keys;
- `gradingSchemaAcceptsCellMode(fit)` and `gradingSchemaProbeIsReliable`;
- the topology and algorithm name lists.

`LatticeCoreCapability` holds constants, not probes; the facts it pins hold on both cores.

## Raised for the maintainer (findings of this report, not fixed)

1. **Stepped / Default Grade under Structural.**
   - Since the flip, the preview sizes their cells for a beam-network certificate (floor 2).
   - The run runs that certificate only for organic (`run_job.cpp:7488`, call at 7587).
   - Core refuses the key for Default Grade, and the app sends it for Stepped only.
   - So the preview's Structural cells can be about 2.5x coarser than what the run's homogenised
     certificate supports.
   - This is a preview ≠ run question, and it involves core.
2. **The octet aesthetic ceiling's source.** Core's `octet_aesthetic_density_ceiling()` is
   0.218871, from a 200-step bisection at a 4 mm cell. The app re-derives it in Swift: 24 steps at
   the project's cell (`LatticeType.swift:269-276`). R12 says to take it from core, but doing so
   changes the digits of `max_relative_density` in every graded octet job. That is an R9 / U8
   question.
3. **Frame axes on untested normals.** Core refuses the RUN, after the solve, when the app's
   `LatticeRegionMask.basis(n)` disagrees with core's plane basis. The app's test pins only the +z
   normal.
