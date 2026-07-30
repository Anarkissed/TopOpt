# Lattice page core hookup — roles, generatable enumeration, worker analyze, grading on optimize

**Date:** 2026-07-31 · **Branch:** `claude/lattice-page-core-hookup-bf5ecc`
**Scope:** `core/` + the CLI + the LAN worker, with app changes ONLY where a new
core capability is consumed (bridge enumerator, the Auto-density gate + graded
job serialization). The page itself was NOT redesigned.
**Evidence:** `evidence/2026-07-31-lattice-page-core-hookup/`
**Base:** main at 21ce7ed (after PR 253 + PR 254, as required).

## WHICH STAGES LANDED: ALL FOUR (2, 1, 4, 3) — none half-landed.

PR 254 shipped the lattice page with four features UI-complete and
core-incomplete, refusing to fake any of them. This task closes all four.

---

## Stage 2 — generatable-set enumeration (H2)

Core now exposes `lattice_gen_topology_names()` (lattice_gen.hpp/.cpp) beside the
existing `lattice_certifiable_topology_names()`, and the bridge's
`lattice_generatable_topologies()` **reads it** — the mirrored enum-case list in
`bridge.cpp` is gone (when core grows the enum, zero app changes).

Drift cannot be silent, twice over:
* `lattice_gen_topology_name` lost its silent `return "octet"` fallback — an
  unnamed case now throws `std::logic_error` (and `-Wswitch` flags it at compile
  time; the enum gained an explicit `: int` underlying type so the probe below is
  legal C++).
* `test_lattice_gen` §7 probes enum values 0..31: every value the name function
  can name MUST appear in the list, and the list must have exactly one entry per
  nameable value. A topology added to the enum + name switch but not the list
  fails the suite. (Verified by the test's construction; 29/29 checks green.)

## Stage 1 — primitive ROLES in the job schema (H1a–H1e)

**Schema** (`job.cpp`/`job.hpp`): `lattice.regions: [ { role, kind, geometry } ]`
— exactly PR 254's proposed shape. `role ∈ {include, exclude}` (a malformed role
is REFUSED, never defaulted — H1e), `kind ∈ {bolt, face}` with the SAME
manual-primitive geometry a manual clearance carries (bolt: axis_point/axis_dir/
radius_mm/half_length_mm; face: origin/normal/half_u_mm/half_w_mm/depth_mm).
`reject_unknown_keys` still rejects at every level (region, geometry, top) —
tested, and the PARENT binary refusing `regions` is in the evidence
(`checksums.md`), proving the strict parser was live before.

**The three roles are three different instructions** (none collapsed):
* clearance → NO MATERIAL. The existing `loads.clearances`, untouched: keep-outs
  still subtract from the clip region, struts are still clipped out, collars
  still dress bores.
* include → material stays, LATTICED. When any include region exists, only
  material inside the include union is latticed; the REST of the part stays
  solid.
* exclude → material stays, SOLID.

**H1a — precedence, stated first, tested per pair**
(unit: `test_lattice_boundary` §8; run: the evidence matrix):
1. clearance beats both (no material to lattice; keep-out tested first in the
   mask, and the solid companion never emits inside a keep-out).
2. exclude beats include — the subtractive instruction wins, mirroring the
   clearance rasterizer's precedence style (ONE precedence discipline, not a
   second system); solid is the always-certifiable state.
3. include over optimizer void is a NO-OP, counted in the receipt
   (`include_void_voxels`), never an error.

**H1b — one predicate, still.** Roles are carried by `LatticeBoundary` ITSELF:
`add_include_region` / `add_exclude_region` (resolved through
`resolve_clearance_manual` with zero margins — the primitive IS the region, no
second geometry concept). `cell_may_overlap` gained the same Lipschitz proof
discipline for roles (drop a cell only when PROVABLY outside every include /
inside an exclude), and `lattice_certification_mask` tests membership with the
same `point_in_clearance_region` the rasterizer uses. Generator and mask consume
the one object; §8 asserts every masked voxel's owning cell is active.
`LatticeRegion.latticed` stays null on role runs (PR 254's proposal listed it,
but the boundary alone is the cleaner reading of "one predicate" — deviation
justified below).

**Deviation (justified): roles do NOT clip struts.** A keep-out is void — strut
solid must never intrude (E5), so it clips. An exclude region is SOLID — a strut
welding into it is material bonded onto material in the interpenetrating soup;
clipping struts short of it (as at keep-outs) would leave the lattice/solid
interface unbonded. So roles act on activation + certification mask only; the
signed distance and `clip_segment` are byte-identical to before.

**H1c — solid regions are certified solid AND exported solid.** Non-latticed
voxels never enter the band check and never count as lattice (they're simply not
in the posture mask — `lattice_voxels` shrinks by exactly the excluded count,
see the matrix). NEW: the exported file now honours "kept solid" — every printed,
non-keep-out voxel the mask leaves solid becomes a closed marching-cubes **solid
companion body** in the same soup (all components kept, deterministic), and its
volume is reported SEPARATELY from interior/skin/rim (`solid_region_voxels`,
`solid_region_volume_mm3` on the voxel basis that matches mass accounting,
`solid_region_triangles`) in the receipt and run_info. The companion is armed
ONLY by roles/grading, so a legacy uniform job writes byte-identical files.

**H1d — absent fields byte-identical.** Proven against the REAL parent binary
(21ce7ed build): `nolattice.json` and `uniform.json` produce bit-identical
report/meshes/lattice mesh/lattice receipt/fields.bin across parent and new
binaries (`checksums.md`; run_info/iterations excluded — they carry wall-clock
and differ even between two runs of the same binary). An empty `regions: []`
equals absent, byte-for-byte (tested in `test_lattice_hookup`).

**H1e** — see schema above; `test_job` grew from 147 to 167 checks.

## Stage 4 — grading on the OPTIMIZE path (H4a–H4d)

`run_job` now honours `job.grading`. Schema coupling (both directions loud):
* grading on the run path REQUIRES a lattice block (nothing to grade into
  otherwise — refused, never silently ignored, which was exactly the reported
  gap);
* `lattice.cell_mm` / `strut_radius_mm` are REJECTED alongside grading (the law
  derives the cell — target raised to the printability floor — and the strut
  radii from the graded densities; a uniform number would conflict). Without
  grading they stay required, unchanged.

Per accepted variant, `emit_lattice` now: (1) builds the role-aware candidate set
(same membership predicates), (2) runs `grade_lattice` on **that variant's own
final certification-recovery von Mises field** (`v.von_mises_field` — produced by
the recovery solve on the converged design of this rung), (3) intersects the
law's mask with the shared predicate's certification mask (drops counted, never
hidden), (4) exports the GRADED lattice — per-position strut radius from the
voxel's own rho through core's `octet_strut_diameter_mm` law, cell activation
from the same mask, solid-fallback voxels carried by the solid companion — and
(5) certifies the graded per-voxel posture (plus the null-posture reproduction
proof, as before).

* **H4a — provenance in the receipt.** `grading.graded_from` names the variant
  (requested + achieved vf) and its iteration count; `test_lattice_hookup`
  additionally re-runs the law IN-TEST on the variant's own field and requires
  the receipt's latticed/fallback/cell numbers to match exactly — a stale or
  foreign field would generically differ.
* **H4b — per-voxel band compliance.** The band stays enforced PER VOXEL inside
  `analyze_fixed_design` (throws `LatticeDensityOutOfBand`; read from
  `lattice_rho_min/max`, never hardcoded). The law now counts clamps per end
  (`GradedField.clamped_lo/hi_voxels` + per-voxel `clamp_flags`, additive
  fields); the receipt reports counts + fractions. "Whether clamping changed the
  verdict" is answered by ONE extra certification solve with every clamped voxel
  kept SOLID instead (`clamp_counterfactual_ran` / `clamp_changed_verdict` — the
  well-defined counterfactual; certifying the UNCLAMPED densities is exactly what
  the band gate refuses, so it cannot be the comparison). Note: under the current
  law (ρ = ρ_max·(demand/max)^γ, frac ≤ 1) high-end clamps are unreachable;
  counted anyway so a future demand map cannot clamp silently. Real numbers
  (evidence graded run): 960/3102 voxels lo-clamped (31%), counterfactual ran,
  verdict unchanged.
* **H4c — ungraded byte-identical.** Same parent-binary proof as H1d (the graded
  machinery is gated on `grading.present`).
* **H4d — the app's Auto gate opens.** `LatticeOptimizeSurface` no longer blocks
  `.auto`; `LatticeSettings.runSpec` produces a GRADED spec (`graded: true`, NO
  uniform cell/radius — bar B6 stands: auto still never silently means uniform)
  and `RemoteRunner` serializes lattice-without-geometry + the `grading` block.
  The one remaining gate is honest: core's grading schema REQUIRES the stated
  minimum extrudable width (the printability floor's input), so without a line
  width the spec stays nil and Optimize is gated with exactly that reason.
  App tests updated accordingly (the old "auto can't ride an optimize job yet"
  assertion is the one the task existed to flip; its B6 half survives stronger).

**Physics honesty carried, not fudged:** a graded lattice needs members ≥ 5
cells across (`lattice_cells_per_member_min`). A 4 mm plate with a realistic
0.4 mm line width is UNGRADEABLE (floor ≈ 4.4 mm cell → needs ≥ 22 mm members)
and the run says so (`region_ungradeable: true`, everything stays solid) rather
than shipping a sub-floor lattice — PR 235's operational constraint, now
operational on the run path too. The E2E graded fixtures are chosen to clear the
floor honestly (a 30 mm cylinder at vf 1.0; the evidence plate run states a
0.07 mm width to exercise the machinery at small scale).

run_info: a graded run writes the same `grading` object the analyze path does
(filled from the last graded variant — each variant's full record lives in its
receipt), the `lattice_export` object gains the role/companion keys (emitted only
when roles/grading are in play), and the streaming `LATTICE` line for graded
variants carries `graded=1 rho_min= rho_max=` instead of fabricated uniform
`strut_r/rho` tokens (a NEW line shape with no pre-existing consumer; the worker
forwards it as a log line as before).

## Stage 3 — worker analyze route (H3a–H3c)

* Schema: `mode` now accepts exactly `minimize_plastic` and `analyze` — anything
  else refused at parse (H3a tested, incl. case-mangled). `run_job` REFUSES an
  analyze job with a routing message, and still refuses unknown modes
  (in-process callers covered too).
* Worker (`topopt_worker.py`): routes on the job's own mode —
  `topopt-cli analyze` for `"analyze"`, `run` otherwise. The CLI stays the
  validator, so the routing can never widen what executes. Artifacts
  (analysis_report.json / analysis.json / fields.bin) are served by the existing
  /files endpoint; the job row's `variants` stays 0.
* H3b/H3c: `analyze_job`'s provenance (analysis.json) now states
  `"analysis_solves": 1`, `"variant_meshes_written": 0`, and — for the solid
  path — `"field_scope": "solid_part"` with the "optimization INVALIDATES this
  field" note, so the label the page's RUN SIM gate shows travels WITH the result
  and cannot be lost in transit. (Additive keys; existing loadcase-analyze
  substring assertions untouched.)
* New pure-python e2e `tools/topopt-worker/e2e/analyze_route_e2e.py` (stub_cli
  gained a protocol-faithful `analyze` subcommand): proves the routing, the
  zero-variant wire behaviour, the served receipts, and that `minimize_plastic`
  on the same worker still routes to `run`. ALL PASS.
* **The app's RUN SIM stays on-device** (deviation stated, not hidden): the
  capability is now exposed end-to-end (schema + CLI + worker + labelled
  receipt), but switching the page's sim to remote dispatch is transport/UI work
  beyond "consume a new core capability" and PR 254's on-device deviation note
  still stands. When that wiring happens, the receipt label is already there.

## All stages — determinism + suite health (H5 / H6)

* **H5:** byte-identical reruns proven at every new configuration: roles
  (include+exclude) and graded, mesh + receipt + report + fields (in-test AND
  CLI-level, `checksums.md`), plus the parent-binary identity above.
* **H6: full ctest 81/81 green** (408 s wall), including the new
  `lattice_hookup` suite (57 checks) and the grown `job_schema` (167),
  `lattice_boundary` (52), `lattice_gen` (29). No pre-existing failures — the
  suite was fully green at the parent too (baseline build ran before any edit).
* App: `swift test --filter "LatticePageTests|LatticeModeTests|JobJSONEquivalenceTests"`
  → 47/47 green after the vendored-core rebuild (`build_core.sh`). The known
  lib3mf-free 3MF `AppModelTests` failures and the GPU-test flake are outside
  the touched surface (suites not affected by this change were not rerun).

## Blocked-stop paths: none needed

* Include was honoured WITHOUT a second boundary predicate (roles live on
  `LatticeBoundary`).
* Per-voxel band compliance did NOT make graded designs uncertifiable — the
  law's clamp keeps every emitted voxel in-band by construction and the E2E
  graded runs certify (accepted, with the clamp accounting on the receipt).
* The analyze route needed NO out-of-repo worker changes (`tools/topopt-worker`
  is in-repo).

## Files

| File | Change |
|---|---|
| `core/include/topopt/lattice_gen.hpp` / `src/mesh/lattice_gen.cpp` | `lattice_gen_topology_names()`, no-fallback name switch, `: int` enum base |
| `core/include/topopt/lattice_boundary.hpp` / `src/mesh/lattice_boundary.cpp` | include/exclude regions on the ONE predicate: membership, role-aware `cell_may_overlap`, role-aware certification mask |
| `core/include/topopt/job.hpp` / `src/cli/job.cpp` | `JobLatticeRegion` + `lattice.regions` parsing (H1e), mode `analyze`, grading⊗uniform-geometry mutual exclusion |
| `core/include/topopt/grading.hpp` / `src/simp/grading.cpp` | clamp counters + per-voxel `clamp_flags` (additive) |
| `core/src/cli/run_job.cpp` | role resolution → boundary; solid companion export; graded per-variant law → graded export + graded posture cert + clamp counterfactual; receipt sections (regions/grading/solid volumes); run_info folding; grading-requires-lattice preflight; strict `run` mode refusal; analyze provenance labels |
| `core/include/topopt/observability.hpp` / `src/simp/observability.cpp` | `lattice_export` role/companion keys (emitted only when present) |
| `core/src/cli/main.cpp` | usage text: mode routing |
| `core/tests/unit/test_lattice_gen.cpp` §7, `test_lattice_boundary.cpp` §8, `test_job.cpp` (+3 suites) | H2 tripwire; H1a/H1b unit; H1e/H3a/stage-4 schema |
| NEW `core/tests/validation/test_lattice_hookup.cpp` (+ CMake) | the E2E matrix / graded / analyze suite |
| `tools/topopt-worker/topopt_worker.py` | mode-based subcommand routing |
| `tools/topopt-worker/e2e/stub_cli.py`, NEW `analyze_route_e2e.py` | stub `analyze` + the route e2e |
| `app/.../TopOptBridge` (bridge.cpp + hpp) | generatable set read from core's enumerator |
| `app/.../LatticeSettings.swift` | graded `LatticeSpec` + `.auto` runSpec (line-width-gated) |
| `app/.../LatticePageModel.swift` / `LatticePage.swift` | the Auto gate opens (H4d), line-width reason |
| `app/.../RemoteRunner.swift` | graded job serialization (lattice w/o geometry + `grading` block) |
| `app/.../LatticePageTests.swift` | the flipped gate test (B6 preserved, stronger) |

## Plain language — what changed, and what it means

Four promises the lattice page made but the engine couldn't keep yet are now
kept — all four, fully.

**Keep-solid and lattice-only regions now really happen.** Before, drawing a
"keep this solid" or "lattice only this box" region only changed the preview —
the file sent to the engine had no way to say it. Now the job format carries
those regions, the engine honours them, and the rules for overlaps are explicit
and tested: a keep-clear region always wins (no material there at all), a
keep-solid region beats a lattice-only region where they overlap, and marking
"lattice this" over empty space simply does nothing (and the receipt tells you
how much of your region was empty). Solid-kept material is genuinely solid
everywhere it matters: the strength check treats it as solid, the mass report
counts it separately, and the exported file now contains an actual solid body
there — not lattice, not air. And if you use none of this, your files are
bit-for-bit identical to before — we proved that by running the same jobs
through yesterday's program and today's and comparing every byte.

**Auto density now really works on Optimize.** Before, choosing "Auto" paused
the Optimize button, because the engine could only grade a lattice during a
separate analysis, and pretending otherwise would have quietly given you a
uniform lattice labelled "Auto". Now the optimizer itself grades the lattice
from the finished design's own stress field — denser struts where the part
works hard, sparser where it doesn't — and the receipt proves it: which design
the stresses came from, how many iterations produced it, how many spots had to
be pinned to the safe density limits, and whether that pinning changed the
pass/fail verdict (checked with a real extra solve, not a guess). Parts too
thin for a trustworthy graded lattice still refuse honestly instead of getting
a bad one. On the page, the only thing that still stops Auto is a missing line
width — because the grading law needs to know what your printer can extrude.

**The quick sim can now run on the Mac.** The job format and the worker now
know a second kind of job — "analyze": one stress check of the solid part, no
optimization, no design files. The worker routes it, refuses to confuse it with
an optimize job, and the result is permanently labelled as describing the SOLID
part, so nobody can later mistake it for the optimized design's stresses. (The
page still runs its sim on the iPad for now — the off-device road is built and
tested; plugging the page into it is a follow-up.)

**And a small honesty fix:** the list of lattice types the engine can actually
build is now published by the engine itself, so the app can never drift out of
sync with it — a test fails the build if anyone adds a type and forgets the
list.
