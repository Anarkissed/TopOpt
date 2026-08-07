# Both defaults are armed. Your bolt holes come out the size you drew them — and the app still exports the old part on your iPad.

**Slug:** `arm-projection-and-void-check` · **Branch:**
`claude/arm-projection-void-check-7fe5b5`, from `main` at `d9fe8f7`.
**Evidence:** `evidence/2026-08-06-arm-projection-and-void-check/`
**Requires:** PR #305 and PR #307, both merged (the merge base IS the #307 merge).
**Supersedes** S1 of `app-core-option-controls` (projection default ON); that task
had not shipped, so S1 comes out of it.

---

# 0. WHAT CHANGES FOR YOU, BEFORE ANY METHOD

**Both features are now ON unless you turn them off, and the default is set in
CORE** — `core/include/topopt/job.hpp`, not in a front-end. The CLI, the LAN
worker and the on-device bridge all read that one initializer, so they cannot
disagree about it the way the dropped outer wall line width did.

**Three things change on your next run:**

1. **Your six 3 mm bolt bores come out exactly 3.0000 mm and exactly round.**
   They were 0.42–0.48 mm out of round and up to 0.9 mm oversize. Every flat
   face lands in the plane your CAD draws it on. Measured on your own part at
   resolution 128, on all four rungs. §R1.
2. **The mesh-derived weights in the app drop by about 8% on your part** — rung
   068 goes 649.94 g → 598.99 g. They drop because the exported part was
   oversize and is not any more. **No mass formula was touched.** The
   voxel-derived figures do not move at all, and §S1(d) lists every number on
   your screen and says which kind it is.
3. **A lattice with a sealed pocket now stops that rung** instead of exporting
   it. On your own job it refuses nothing — your lattice drains through all six
   faces at depth 0. §S2.

**★ AND ONE THING THAT DOES NOT CHANGE, WHICH YOU NEED TO KNOW ABOUT.**
**Runs on the iPad/Mac itself do NOT get the corrected geometry — only runs sent
to the worker do.** The on-device path never calls the code the projection lives
in. Arming the core default did not arm it there, and closing that gap is a
piece of work this task did not do. It is a blocked-stop, it is stated in full
in §S1(b), and it is the first thing in the "what next" list.

**Two defects were found and fixed on the way, both exposed by the flip itself:**
a wall clock inside a document five tests require to be byte-reproducible, and
projection **welding the exported mesh shut** on coarse grids. §R6.

**The certified verdict does not move.** ACCEPTED before and after on every rung.
§R1.

---

# 1. WHAT SHIPPED

| what | where |
| --- | --- |
| `output.project_cad_faces` default `false` → **`true`** | [core/include/topopt/job.hpp:123](../../core/include/topopt/job.hpp) |
| `lattice.require_lattice_void_reaches_exterior` default `false` → **`true`** | [core/include/topopt/job.hpp:289](../../core/include/topopt/job.hpp) |
| the refusal text made ACTIONABLE (and its now-wrong advice fixed) | [core/src/mesh/lattice_void.cpp:378](../../core/src/mesh/lattice_void.cpp) |
| the wall clock removed from the per-variant receipt | [core/src/cli/run_job.cpp:2256](../../core/src/cli/run_job.cpp) |
| **the weld guard** — projection may not fuse two surface sheets | [core/src/mesh/cad_project.cpp](../../core/src/mesh/cad_project.cpp), stats at [cad_project.hpp:203](../../core/include/topopt/cad_project.hpp) |
| the app sends `project_cad_faces` explicitly, always | [app/…/RemoteRunner.swift:640](../../app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift) |
| the app sends the void rule explicitly, always, on BOTH job paths | [RemoteRunner.swift:689](../../app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift), [RelatticeRunner.swift:118](../../app/TopOptKit/Sources/TopOptFlows/RelatticeRunner.swift) |
| the CAD-surfaces OFF control (chip) | [WorkspacePlaceholder.swift](../../app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift) `cadFacesChip`, id at [WorkspaceChipLayout.swift:43](../../app/TopOptKit/Sources/TopOptFlows/WorkspaceChipLayout.swift) |
| the enclosed-void OFF control (card) | [LatticePage.swift](../../app/TopOptKit/Sources/TopOptFlows/LatticePage.swift) `enclosedVoidCard` |
| the settings, persisted nil → **ON** | [ProjectModel.swift](../../app/TopOptKit/Sources/TopOptFlows/ProjectModel.swift), [ProjectStore.swift](../../app/TopOptKit/Sources/TopOptFlows/ProjectStore.swift), [LatticeSettings.swift](../../app/TopOptKit/Sources/TopOptFlows/LatticeSettings.swift) |
| the default-arming test (core) | `core/tests/unit/test_default_arming.cpp` — ctest `default_arming` |
| the default-arming tests (app) | `app/TopOptKit/Tests/TopOptFlowsTests/DefaultArmingTests.swift` |

---

# S1 — PROJECTION ON BY DEFAULT

## S1(a) — the core default

Flipped at [job.hpp:123](../../core/include/topopt/job.hpp). **The key stays
parseable and settable to `false`**, and both directions are asserted rather
than assumed — `test_default_arming.cpp` checks the struct's own initializer,
the absent-key parse, an explicit `false` and an explicit `true`. The last two
are what stop the file passing vacuously: an implementation that hard-wired
`true` fails the `false` case, and one that stopped reading the key fails
whichever direction disagreed with its constant.

## S1(b) — every job-building site, changed and deliberately not

**CHANGED — one site, because there is only one that authors an `output` block:**

| site | what it now does |
| --- | --- |
| `RemoteRun.buildJobJSON()` [RemoteRunner.swift:619](../../app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift) | writes `output.project_cad_faces` on **every** job, in both directions |

**DELIBERATELY NOT CHANGED, with the reason for each:**

| site | why not |
| --- | --- |
| `RelatticeJobBuilder.build` [RelatticeRunner.swift:69](../../app/TopOptKit/Sources/TopOptFlows/RelatticeRunner.swift) | The `output` block travels through **verbatim** (the builder is additive on the decoded original), so the key arrives if the optimize run wrote it. Writing it again would be inert: `export_variant_mesh` — the ONLY place projection runs, [run_job.cpp:342](../../core/src/cli/run_job.cpp) — is called at exactly two sites ([:7501](../../core/src/cli/run_job.cpp) and [:7915](../../core/src/cli/run_job.cpp)), **both inside the optimize path**. `lattice_variant_job` starts at [:5026](../../core/src/cli/run_job.cpp) and never reaches it. Writing an inert key into the record would suggest it did something. |
| the forecast job [RelatticeRunner.swift:349](../../app/TopOptKit/Sources/TopOptFlows/RelatticeRunner.swift) | Same document plus `forecast_only`; a forecast writes no mesh at all. |
| `probe_job_json` [bridge.cpp:1878](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp) | A synthetic document fed to `parse_job` for **schema validation only**. Never submitted, never solved. |

**AND THE ONE THAT COULD NOT BE CHANGED — this is a blocked-stop, reported
rather than special-cased, exactly as the brief requires.**

**★ THE ON-DEVICE PATH BUILDS NO JOB DOCUMENT AND HAS NO PROJECTION.** It is not
a job-building site that is missing a key; it is a **second export path that
does not contain the feature**:

* the device optimize calls `topopt::minimize_plastic` **directly**
  ([bridge.cpp:886](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp),
  [:1728](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp)) — never
  `run_job`, so `export_variant_mesh` is never reached;
* it extracts its own export mesh in `export_display_mesh`
  ([bridge.cpp:240](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp)), which
  mirrors the CLI's `marching_cubes_resampled` and stops there. A repo-wide grep
  for `project_cad_faces` / `cad_project` over `bridge.cpp` returns **nothing**;
* `to_optimize_result(mp, grid)`
  ([bridge.cpp:369](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp)) does
  not even take a `StepModel`, so the analytic surfaces are not in hand at the
  point the mesh is made.

**So "universally armed" is NOT true as shipped.** A LAN run exports the
corrected part; the same job run on the device exports the old one. That is the
divergence shape the brief names, and pretending the core default closed it
would be worse than saying so. Wiring it needs the `StepModel` threaded through
`build_optimize_result` → `to_optimize_variant` → `export_display_mesh` plus a
flag, in a seam four PRs have already broken, and it cannot be validated without
an xcframework rebuild and device testing. **It belongs in its own task.**

## S1(c) — the OFF control

A **CAD surfaces** chip in the workspace cluster
(`SettingsChipID.cadFaces`). It is a menu rather than a switch because the copy
has to say what it does, and a switch has nowhere to say it:

* *Restore CAD surfaces · walls and holes exactly as drawn*
* *Export the voxel approximation · what earlier versions shipped*

Shown only for a STEP part: an STL/3MF import carries manufactured pseudo-faces
with no analytic surface behind them, so the control would govern an operation
that cannot run. The setting is on `ProjectModel`, persisted, and **decodes
nil → ON** so a project saved before this task reopens armed rather than
silently opted out.

## S1(d) — the masses move, and here is every one of them

Full audit with file and line in
[`s1d_mass_audit.md`](../../evidence/2026-08-06-arm-projection-and-void-check/s1d_mass_audit.md).
**Ten displayed figures, all sourced. Nothing was "fixed".** The blocked-stop
*"a displayed figure whose source you cannot determine"* was not hit.

The rule: projection runs on a **copy of the mesh** after the design, the field,
the certification and the report are final, so **VOXEL figures do not move and
MESH figures do**. Seven of the ten are voxel-derived and unchanged; two show
both numbers side by side and labelled; one is mesh-only.

Measured on your part, resolution 128 (`r1_table_128.txt`):

| rung | mesh mass BEFORE | AFTER | change |
|---|---:|---:|---:|
| 026 | 479.97 g | 436.85 g | **−8.98%** |
| 038 | 529.56 g | 484.20 g | **−8.57%** |
| 052 | 604.70 g | 556.84 g | **−7.91%** |
| 068 | 649.94 g | 598.99 g | **−7.84%** |

**★ THE −8% IS A PROPERTY OF YOUR PART AT 128, NOT OF THE FEATURE.** The same
operation makes the exported volume **larger** on the demo l-bracket at
resolution 48 (20 215.0 → 22 029.1 mm³, **+9.0%**, `r4_end_to_end.txt`) and
**larger** on your own part at resolution 64 (**+1.6% to +2.9%**,
`r1r2_defaultpath_res64.txt`). Reading "masses drop 8%" as a general rule would
be wrong: what projection removes is the *error*, and the error's sign depends
on the part and the grid.

**Two other things worth knowing.** `lattice_mass_grams` is written by core and
**never read by the app** — a repo-wide grep returns zero hits, so it is a
receipt figure, not a screen figure. And `MassComparison.summary`
([ResultsModel.swift:543](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift))
prints one number or two depending on whether mesh and voxel diverge past 1%, so
on some parts that row could change *shape*. That is the existing rule behaving
correctly on a newly-correct input, and it was left alone.

---

# S2 — THE VOID CHECK ON BY DEFAULT

## S2(a) — the core default

Flipped at [job.hpp:289](../../core/include/topopt/job.hpp), asserted the same
four ways, plus **at the run level**: `test_lattice_void_exterior.cpp` V7 runs a
job that sets **nothing** and requires the sealed cavity to be refused. V2 (the
flag set by hand) and V7 (the flag untouched) differ by exactly one line, so a
regression that made the flag ineffective fails V7 while V2 passes, and one that
re-defaulted it to false fails V7 while V1 passes. **That is the assertion that
catches the failure mode the brief names — shipping it quietly as opt-in to keep
a bar green.**

## S2(b) — ★ the refusal had to change, and not only to be nicer

The old text ended:

> *"Either place the lattice so it reaches the surface, add a drain path, or
> **clear** `lattice.require_lattice_void_reaches_exterior`."*

**That advice became WRONG the moment the default flipped.** Clearing the key
leaves it at the default, which is now `true`, and the next run refuses
identically — a loop, handed to someone whose run has just stopped. It is the
"painted door" defect in its purest form: correct-sounding, and it does nothing.

The refusal now names **how to proceed**, the **exact value**, and the
**consequence** (from `core/src/mesh/lattice_void.cpp`):

> … TO PROCEED, either (a) place the lattice so it reaches the surface or add a
> drain path — the cavity above tells you where — or (b) set
> `"require_lattice_void_reaches_exterior": false` in the job's `"lattice"`
> block to export anyway. **THIS CHECK IS ON BY DEFAULT, so REMOVING the key
> does not turn it off; only an explicit false does.** Exporting with it off
> ships a part with sealed lattice cavities: whatever ends up inside them —
> powder, resin or support — cannot be removed after printing, and the part's
> real mass will exceed the reported one by the mass of whatever stays in there.

Five assertions in `test_lattice_void.cpp` pin this, including one that requires
the **old wording to be absent** so it cannot come back under the new default.

## S2(c) — the OFF control

An **"Empty space must reach the outside"** card on the lattice page, in its own
card rather than a row inside the retention card — it is a different *kind* of
setting from everything else on that page, because it can **stop a run**, and a
switch that can stop a run should not be found by accident while reading about
cell sizes. Turning it off swaps the copy for a warning that states what gets
exported. Persisted, decodes **nil → ON**.

## S2(d) — PR #305's own evidence, re-run with the default flipped

**One test asserted the OLD default and was updated deliberately.**

`test_lattice_void_exterior.cpp` **V1** ran the sealed-cavity fixture with the
flag untouched and asserted that this build *exports and CERTIFIES a sealed
lattice cavity with no complaint whatsoever*. With the default on, leaving it
unset would refuse the rung and every assertion in that block would silently
have started testing the armed path — V1 would stop being the positive control
that gives the rest of the file its meaning.

**The claim is unchanged; only how the check is turned off changed.** V1 now
sets `require_lattice_void_reaches_exterior = false` explicitly, which is also
the OFF control a user runs the same job with. It was **not deleted** and not
weakened, and V7 was added alongside it to cover the default.

`ctest`: **114/114 passed** (`ctest.txt`) — see §A3 on why an earlier run of
this suite said 112 — including `lattice_void` (75 checks,
up from 70), `lattice_void_exterior`, `cad_project` (38 checks, up from 31) and
the new `default_arming` (10 checks).

## S2(e) — does anything in the repo now refuse that did not before?

**How the search was done, because "none found" is worthless without it:**

1. **Every test, empirically.** The full `ctest` suite was run against the
   flipped build. Six tests failed on the first pass; all six are diagnosed in
   §R6 and **all six now pass** — none of them was a void refusal.
2. **Every committed job document, in both arms.**
   `s2e_refusal_sweep.py` finds every `*.json` under `core/tests`, `docs`,
   `evidence`, `tools` and `app` that parses as a job document (has `mode` and
   `model`) — **116 found, 50 of them carrying a lattice block, and not one of
   the 50 carries the void key**, so all 50 now run the check. Each runnable one
   is executed **twice**, once with the merge-base binary and once with the
   branch binary, and only a job that **succeeds on base and fails on branch**
   counts. Running both arms is what makes the answer attributable.
3. **PR #305's own table.** It measured all seven real lattice fixtures plus
   your job at two resolutions with the rule **armed**, and none refused. Arming
   by default cannot refuse what arming by hand did not.

**Result at the time of writing: 41 of 82 runnable job documents completed in
both arms, and ZERO newly refused.** The sweep is still running — it is 164 full
optimize runs and it competes with the machine's other work — and its final
count belongs in a follow-up comment rather than being guessed at here. 34
documents are skipped and **every skip is printed with its reason** (model file
absent from the repo, or resolution above the 48 cap chosen to keep 164 runs
tractable); nothing is dropped silently.

**One documented recipe DOES refuse today, and it is not caused by this task.**
`evidence/2026-08-03-multiscale-lattice-to/job_multiscale.json` sets
`"skin": "rim"`, and its own captured `run_info.json` records
`rim_triangles: 0` / `skin_triangles: 0` — the exact condition the
`lattice-cell-fit-mode` **M4** refusal fires on. That rule merged to `main`
before this task started, so the recipe refuses on the merge base too. PR #305
hit the same thing and set `"skin": "none"` for the same reason.

---

# S3 — ★ THE INTERACTION NEITHER PR COULD SEE ALONE

The void check is **field-level**; projection is **mesh-level** and pulls the
exported surface inward. PR #305's `scope_note` says the check does not model the
exported shell as a barrier, and `outer_finish` defaults to `"shell"`. Arming
both makes that gap more relevant, not less.

## S3(a) — measured on the geometry, not argued from the field

`s3_mesh_flood_fill.py` voxelizes the **exported mesh** by parity ray casting,
then flood-fills the empty space **6-connected** from the grid boundary — PR
#305's adjacency, so "the field says open" and "the file says open" are the same
question asked twice. Anything the fill cannot reach is an enclosed cavity in the
exported solid.

**★ THE COUNT IS SWEPT ACROSS THE MEASURING GRID, and that is not a formality —
it is the difference between this section's answer and its opposite.** The flood
fill discretises the exported mesh, so its OWN grid can close a channel the mesh
leaves open. On the first pass, at a single grid, this probe reported a
**703-voxel / 6960.668 mm³ cavity appearing on rung 068 the moment projection
was armed**. That is exactly the shape of the blocked-stop this section exists to
catch, and I was one measurement away from reporting it as one.

It is not one. The same two meshes measured at 96, 128 and 160 report **zero**
cavities in **both** arms — the drain channel is simply narrower than a 3.4 mm
measuring voxel. **A cavity count at one grid is not evidence.**

**Your part, resolution 128, all four rungs, swept** (`s3_mesh_flood_fill.txt`):

| mesh | grid 128 | grid 160 | grid 192 |
|---|---:|---:|---:|
| variant_026 | 0 | 2 (3 vox) | 0 |
| variant_026 **projected** | 0 | 0 | 1 (1 vox) |
| variant_038 | 0 | 0 | 0 |
| variant_038 **projected** | 0 | 0 | 0 |
| variant_052 | 1 (1 vox) | 0 | 0 |
| variant_052 **projected** | 0 | 0 | 0 |
| variant_068 | 0 | 0 | 0 |
| variant_068 **projected** | 0 | 0 | 0 |

**Every mesh is watertight at every grid, in both arms** — which is what makes
the parity inside/outside test meaningful at all, and is precisely the property
this task's weld guard exists to protect.

**★ NO PORE THE FIELD CALLS OPEN BECOMES SEALED IN THE EXPORTED MESH.** Not one
non-zero entry survives a change of measuring grid, and every one of them is 1–3
voxels — the probe's own noise floor. Nothing appears in the projected arm and
stays. The 26-connected negative control (it can only ever reach more) agrees at
0 throughout.

An earlier draft of this section read "rung 052 goes 1 → 0" as though projection
had *opened* something. That was the same noise seen from the other side, and it
is corrected rather than left standing.

## S3(b) — the blocked-stop is not triggered

Projection does not seal a pore on this part at this resolution. **But the
mechanism the brief worried about is real, and this task found it in a different
form** — see the weld guard in §R6. Without that guard projection *did* pull two
surface sheets into contact, which is precisely "the shell closing over
something", and it broke watertightness rather than sealing a pore. **Every one
of the eight meshes above is watertight**, which is what makes the cavity counts
meaningful at all: parity has no defined inside on an open surface, and the
script refuses to print a number for one.

## S3(c) — the `scope_note`, and a second scope fact worth more than it

The receipt's `scope_note` already says the check is a statement about the design
field and does not model the exported shell as a barrier. **That is still exactly
true with projection on**, and this task measured it rather than leaving it
abstract: §S3(a) is the measurement, and it says the shell does not close over
anything on this part.

**★ AND THERE IS A SHARPER SCOPE FACT THAT MATTERS MORE.** Projection applies to
the **solid variant mesh only**. The latticed companion is built from
`variant.v3.mesh` on its own path
([run_job.cpp:1007](../../core/src/cli/run_job.cpp)) and is **not projected**.
PR #307 named that as follow-on work, which was fair while the feature was
opt-in. **Defaulting it on makes the inconsistency the default:** for the same
rung, `variant_068.stl` is now the corrected part and `variant_068_lattice.stl`
is still the oversize one. Whichever you print, you get a different part. That is
stated here rather than buried, and it is second on the "what next" list.

---

# THE BARS

## R1 — ★ NO BYTE-IDENTITY CLAIM FOR THE DEFAULT PATH

None is made. The default export changes on purpose. What is measured instead:

### The exported file, your part, resolution 128, all four rungs

`r1_table_128.txt`. Subject: the four meshes in
`evidence/2026-08-03-multiscale-lattice-to/m2_multiscale_final/` — **the same
four PR #307 measured**, so its figures are directly comparable. AFTER is those
meshes through `cad_project_probe`, which makes the same two calls
`export_variant_mesh` makes, including this task's weld guard.

| rung | watertight | volume BEFORE | volume AFTER | mesh mass BEFORE | AFTER | Δ |
|---|---|---:|---:|---:|---:|---:|
| 026 | yes → yes | 387 068.7 | 352 295.8 | 479.97 g | 436.85 g | −8.98% |
| 038 | yes → yes | 427 065.5 | 390 480.1 | 529.56 g | 484.20 g | −8.57% |
| 052 | yes → yes | 487 659.2 | 449 066.6 | 604.70 g | 556.84 g | −7.91% |
| 068 | yes → yes | 524 148.4 | 483 054.8 | 649.94 g | 598.99 g | −7.84% |

### Bolt bores — all six, on all four rungs

| face | nominal | before min | before max | before out-of-round | AFTER |
|---|---:|---:|---:|---:|---|
| 58 | 3.0000 | 3.2696 | 3.6866 | 0.4170 | **3.0000 / 3.0000, 4.0e-15** |
| 61 | 3.0000 | 3.2488 | 3.6760 | 0.4272 | **3.0000 / 3.0000, 6.2e-15** |
| 62 | 3.0000 | 3.4438 | 3.9279 | 0.4841 | **3.0000 / 3.0000, 8.9e-16** |
| 63 | 3.0000 | 3.2740 | 3.7305 | 0.4565 | **3.0000 / 3.0000, 4.9e-14** |
| 64 | 3.0000 | 3.4558 | 3.9199 | 0.4641 | **3.0000 / 3.0000, 1.8e-14** |
| 65 | 3.0000 | 3.2695 | 3.6861 | 0.4166 | **3.0000 / 3.0000, 2.6e-14** |

(rung 068; the other three agree to four decimals — `r1_table_128.txt` has all.)
**Worst out-of-roundness over every cylindrical face: 3.3624 mm → 9.095e-13 mm**,
on all four rungs.

### Flat faces

30 planar faces carry surface. Worst deviation from each face's own nominal
plane: **1.694–1.702 mm before → 1.093e-14 mm after**, identical on all four
rungs.

### The void-check record

From the default-path run (`r1r2_defaultpath_res64.txt`), your job, keys absent,
two binaries:

* **BEFORE:** no `void_escape` block at all — the check did not run. PR #305's
  bar V5 ("off means not one extra byte") still holds.
* **AFTER:** `sealed=false`, `sealed_variants=0`, **1082 latticed cells, 6276
  voxels reached, 0 sealed, escape depth 0, escaping through all six faces
  −x +x −y +y −z +z**, connectivity 6, 240 011 BFS visits, 0.0036 s.
  One enclosed void holding no lattice — reported, never refused.

### ★ The certified margin and verdict — THE VERDICT DOES NOT MOVE

`r1_cert_table.txt`. Both meshes of each rung re-certified through the shipped
path, same job, resolution 128, same declared load PR #307 used:

| rung | verdict | margin BEFORE | margin AFTER | Δ margin | voxel mass Δ |
|---|---|---:|---:|---:|---:|
| 026 | **ACCEPTED → ACCEPTED** | 5062.150734 | 4511.449877 | −10.88% | −10.14% |
| 038 | **ACCEPTED → ACCEPTED** | 5044.721905 | 4714.375520 | −6.55% | −9.32% |
| 052 | **ACCEPTED → ACCEPTED** | 4948.661523 | 4724.384380 | −4.53% | −8.40% |
| 068 | **ACCEPTED → ACCEPTED** | 4595.797434 | 4614.998005 | **+0.42%** | **−8.03%** |

**PR #307's figures are reproduced exactly.** Rung 068: margin
4595.797434 → 4614.998005 = **+0.4178%** against its +0.42%; voxel mass
683.8424 → 628.9313 g = **−8.03%** against its −8.03%; volume fraction
**1.002768 → 0.922248** against its 1.002768 → 0.922257. The small residuals in
the projected arm (628.9313 vs its 628.9375 g; 97 vs 98 min-feature violations)
are **the weld guard putting a few vertices back** — a difference this task
introduced and can account for, not noise.

**★ AND ONE THING PR #307 COULD NOT SEE, BECAUSE IT MEASURED ONE RUNG.** The
margin does **not** move in a consistent direction: it rises 0.42% on rung 068
and **falls** by up to 10.9% on the lighter rungs. That is not alarming — every
margin is still ~3000× the required 1.5 and no verdict moves — but "+0.42%"
should not be repeated as if it were the feature's signature. The lighter the
rung, the less of its surface came from your CAD (60% on 026 against 82% on 068),
and the more of the removed 8% comes out of load-carrying structure.

### Byte-identity WITH BOTH SWITCHES OFF — still claimed, and proved

`r1_byte_identity.txt`, exit 0. Two separately built binaries from one build
folder; **the script requires the two binary hashes to differ and exits non-zero
if they do not** (the `topopt-cli` vs `topopt_cli` trap that bit both prior PRs).
Subject exercises both features: a STEP part with a lattice include region.

**11 artifacts byte-identical**, including `design.bin`, `fields.bin`,
`report.json`, both solid meshes, both latticed meshes and both lattice receipts.
`run_info.json` and `iterations.csv` are excluded by name for their wall clocks.
`build_orientation.json` is **not** excluded wholesale — it carries two clocks
(`sweep_seconds`, `strut_axis_measure_seconds`) and 99% geometry, so the clocks
are stripped by name and everything else is compared.

## R2 — THE GATE TABLE, AND THE FLIPS ARE THE DELIVERABLE

`r1r2_defaultpath_res64.txt`. Your job, both binaries, keys absent.

**Against the negative-control floor, run FIRST:**

* **C1 resolution** — one voxel moved across the printed iso by 1e-9
  (1.000000000000 → 0.499999999000): the comparator reports **exactly 1 flip**.
* **C2 sensitivity** — rung 0.68 vs rung 0.52 of the same run: **743 flips**.

| requested vf | achieved before | achieved after | margin before | margin after | verdict | **voxel flips** |
|---:|---:|---:|---:|---:|---|---:|
| 0.68 | 0.680001295 | 0.680001295 | 1837.416402 | 1837.416402 | True→True | **0** |
| 0.52 | 0.520004835 | 0.520004835 | 1780.493448 | 1780.493448 | True→True | **0** |
| 0.38 | 0.379999999 | 0.379999999 | 1691.749462 | 1691.749462 | True→True | **0** |
| 0.26 | 0.260002808 | 0.260002808 | 1654.089195 | 1654.089195 | True→True | **0** |

**TOTAL: 0 flips. There are no flips to enumerate, and that is the correct
answer rather than a missing one.**

**The attribution, which is what the bar actually asks for.** Neither change
*can* move a voxel, and this is structural rather than empirical: projection runs
inside `export_variant_mesh` ([run_job.cpp:342](../../core/src/cli/run_job.cpp))
on a **copy of the mesh**, after the design, the density field, the certification
and the report are all final; the void check
([run_job.cpp:2934](../../core/src/cli/run_job.cpp)) is a refuse-or-do-nothing
gate on the already-final mask. A non-zero flip count would have been a **defect
to explain**, not a result. C1 proves the comparator can see a single 1e-9 move,
so the zero is a measurement and not an inability to count.

## R3 — FAILING TEST FIRST, FOR EACH FLIP

`r3_failing_test_core.txt` — built from the merge-base tree plus the test file
alone, and **it prints the old default rather than only failing**, so the paste
is the evidence:

```
observed: output.project_cad_faces with the key ABSENT = false
FAIL (line 115): project_cad_faces: an ABSENT key must now mean ARMED (was false before this task)
FAIL (line 120): project_cad_faces: the JobOutput struct's own default must be armed, …
observed: lattice.require_lattice_void_reaches_exterior with the key ABSENT = false
FAIL (line 149): require_lattice_void_reaches_exterior: an ABSENT key must now mean ARMED …
FAIL (line 154): require_lattice_void_reaches_exterior: the JobLattice struct's own default …
FAIL (line 179): independence: disarming projection leaves the void check armed
FAIL (line 185): independence: disarming the void check leaves projection armed
default arming: 6 of 10 checks FAILED
exit=1
```

After the flip (`r3_passing_test_core.txt`): `all 10 checks passed`, with the
same two lines now reading `= true`. The app half is
`DefaultArmingTests.swift` — **10 tests, all through the REAL serializers**
(`RemoteRun.buildJobJSON` and `RelatticeJobBuilder.build`), never a
hand-assembled dictionary.

## R4 — DEMONSTRABLY USABLE, BOTH OPTIONS, BOTH DIRECTIONS

`r4_end_to_end.txt`. The chain is: **the user's control → the app's real
serializer → bytes on disk → the real `topopt-cli` → an effect in the result.**
`DefaultArmingEvidenceGen` writes the app's actual `output` and `lattice` blocks
to `app_blocks_*.json`; the script splices **those** into a runnable l-bracket
load case. Nothing is re-authored.

| arm | app wrote `project_cad_faces` | app wrote void rule | exported mm³ | `void_escape` in run_info |
|---|---|---|---:|---|
| both on | true | true | **22 029.1** | **yes** (sealed false) |
| cad off | false | true | **20 215.0** | **yes** |
| void off | true | false | **22 029.1** | **NO** |
| both off | false | false | **20 215.0** | **NO** |

**Both effects are visible in the result, and the two move independently** — the
2×2 separates perfectly, so they are not one switch wearing two names. Turning
each off reproduces the old behaviour exactly (R1's byte-identity bar).

The re-lattice path is exercised separately (`r4_app_bytes.txt`): the void rule
reaches it in both directions, and the `output` block travels through unchanged.

## R5 — NO ASSERTION WEAKENED OR DELETED

`r5_assertion_census.txt`. Message-text census, merge base vs branch, as PR #305
established — a rename reads as a deletion if you grep function names.

* **C++ `CHECK` message texts:** 1507 on the merge base, 1510 on the branch.
  **Present on main and absent now: 1.** Added: 4.
* **Swift test functions:** 1322 → 1332. **Lost: 0.** Added: 10.
* **Swift assertion-call census by kind:** identical on both sides.

**The one lost message, accounted for by hand:**

| message | what happened |
|---|---|
| `"wall_seconds"` (V6, `test_lattice_void_exterior.cpp`) | **Replaced, not dropped.** It asserted the check's wall clock was in the per-variant RECEIPT. Arming the check by default put that clock into every lattice receipt and broke five separate "byte-identical on a rerun" assertions at once. The claim is **split and strengthened**: `bfs_visits` is still asserted in the receipt, the run_info assertion that carries **both** figures is untouched, and a **new** assertion requires the receipt to contain no wall clock at all — so the clock cannot come back without failing there first. §R6. |

**All nine removed lines under the two test trees, each one I edited:**
four in `DesignOverhaulRound2Tests` (two width dictionaries and the expected
order — `.cadFaces` added the same way the previous three chips were, so the
tests keep checking the ORDER rather than which chips exist); two in
`test_cli.cpp` (the volume reference and its message — see below); one comment
line in `test_lattice_void_exterior.cpp`; two for the V6 clock.

**Tests updated for the new default, named individually:**

| test | why |
|---|---|
| `test_lattice_void_exterior.cpp` **V1** | Asserted "this build exports and certifies a sealed cavity with no complaint" with the flag unset. Now sets it **explicitly false** — same claim, and it is also the OFF control. §S2(d). |
| `test_lattice_void_exterior.cpp` **V6** | The receipt-level clock assertion. §R6. |
| `test_cli.cpp` "re-imported volume within 0.5%" | Compared the exported file against the **un-projected in-memory mesh**; the file is now the projected one, so the two are deliberately different objects (~7% apart on that fixture). **The 0.5% tolerance is unchanged** — it is simply aimed at the mesh that is actually written, reproduced with the same two calls the export makes. A **new positive control** requires the armed default to have measurably moved the volume, so the 0.5% check cannot pass by projection having become a no-op. |
| `DesignOverhaulRound2Tests` chip tests | `.cadFaces` added to the measured-width dictionaries, exactly as `.faceProtectDepth`, `.paint` and `.buildOrientation` were before it. |

## R6 — ROOT CAUSE WITH FILE AND LINE

Six tests failed on the first flipped build. **All six are one of two defects,
both real, both fixed, and neither visible before the defaults were armed.**

| what | root cause |
|---|---|
| `lattice_hookup` H1d/H5, `lattice_variant` Z8, `protect_freeze_vs_solidity` PF6, `designbox_lattice_recert` AI7, `bake_build_orientation` V6 — all "the receipt is byte-identical on a rerun" | **A WALL CLOCK IN A BYTE-REPRODUCIBLE DOCUMENT.** [run_job.cpp:2256](../../core/src/cli/run_job.cpp) wrote `void_escape.wall_seconds` into the per-variant lattice receipt. Confirmed by measurement, not inference: two identical runs of the same job differed by `0.0010455` vs `0.001088709` **and by nothing else**. PR #305 never hit it because the block only appeared when the check was explicitly armed and no armed run was ever rerun-compared; defaulting it on put a clock in every lattice receipt. **Fixed** by keeping the deterministic `bfs_visits` in the receipt and shipping the clock in `run_info` — where this project already keeps clocks and where every byte-identity comparison already excludes it by name. Both figures still reported, still separately, still outside `gen_seconds`. |
| `cli_demo` "re-imported variant is watertight" | **★ PROJECTION WELDED THE MESH SHUT.** A terrace riser stands perpendicular to the face it approximates, so its two endpoints share their in-plane position **exactly** and differ only along the normal; projecting both onto that plane lands them on the **same point**. No triangle inverts and none becomes degenerate — the two vertices belong to different triangles — so the fold guard passes over it **by design** ([cad_project.cpp:666](../../core/src/mesh/cad_project.cpp) says a collapsed riser "has nothing to fold through"). But the two surface sheets it separated are now welded. Measured on the demo l-bracket at resolution 48 through the real CLI: **124 positions received two vertices each, and the re-imported file had 293 edges shared by FOUR triangles.** **Fixed** with a weld guard in the fold guard's own loop, spending free band vertices first, lowest index keeping its exact position. |
| the weld guard's first cut still let two vertices through | **THE WRONG PRECISION.** It keyed on exact **double** equality, which cleaned up resolution 48 completely — and then your part at resolution 64 exported **37 798 distinct float32 positions from 37 800 double-distinct vertices** on rung 052. Binary STL stores **float32** and every consumer re-welds by position, so a difference below a float32 ULP does not survive the file. **Fixed** by keying on the float32 round-trip. Pairs already float32-coincident in the input are left alone — not this operation's doing, and treating them as collisions would make the guard fight a pre-existing degeneracy forever. |
| the old refusal told the user to CLEAR the key | Correct while the default was false; a **loop** once it flipped. [lattice_void.cpp:378](../../core/src/mesh/lattice_void.cpp). §S2(b). |
| this task's own `design.bin` reader produced garbage | Carried over from PR #305's `r3_gate_table.py`, which expects an 8-byte magic; the format has none — the first byte **is** the version. A misaligned reader does not fail cleanly, so the block size is now asserted against the grid. `r1r2_analysis.py`. |
| `check_watertight` could not have caught the weld | It walks **index** topology: two distinct indices at one position leave that perfectly manifold. The file carries **positions**. That is why PR #307's own watertight assertion passed while the exported file failed — so the new assertion is stated at the level the file is written at. |

**The weld guard has a positive control, because a guard that only ever passes is
not a guard.** The block fixture has axis-aligned faces, exports no terraces and
reports **0 collisions** — a vacuous pass, and the test prints so. So the failure
is constructed from the exact geometry that produces it in the field, and the
same projection is run twice differing only in the guard:

```
weld guard: 0 collisions found, 0 projected vertices put back, 0 coincident positions left
weld control: guard OFF -> 8 coincident positions (of 16 vertices)
weld control: guard ON  -> 0 coincident positions, 8 collisions found, 8 vertices put back
```

## R7 — NO UNFILLED PLACEHOLDERS

```
grep -nE "PLACEHOLDER|<<|TBD|filled in with|FIXME|XXX|\.\.\.$" \
  docs/handoffs/2026-08-06-arm-projection-and-void-check.md
```

Clean before commit. Every number in this document exists in
`evidence/2026-08-06-arm-projection-and-void-check/`. The one figure stated as
in-progress — the S2(e) sweep's final count — is stated **as** in-progress, with
the count reached, rather than guessed.

## R8 — SEPARATE COMMIT, AND NO SCRATCH AT THE ROOT

Any response to review is added as its own commit; nothing is amended.

```
git diff --stat d9fe8f7 HEAD -- . ':(exclude)core' ':(exclude)app' \
  ':(exclude)docs' ':(exclude)evidence'
```

**Empty.** Every changed line is under `core/`, `app/`, `docs/` or `evidence/`.
The evidence directory is **~70 KB of scripts and text plus four small JSON
blocks** — no meshes, no run outputs, no `design.bin`. Every large artifact
(runs, projected meshes, certification outputs) stayed in the session scratchpad
and is regenerable from the committed scripts.

---

# BLOCKED-STOPS

| the stop | hit? |
|---|---|
| a certified verdict moves | **No.** ACCEPTED → ACCEPTED on all four rungs. §R1. |
| S3 finds projection sealing a pore the field calls open | **No** — but only after the count was swept across the measuring grid. A single-grid reading showed a 6960 mm³ cavity appearing on rung 068 and it evaporated at every finer grid. Nothing above the probe's own 1–3 voxel noise floor survives in either arm. §S3. |
| an existing fixture, test or recipe refuses and cannot be explained | **No.** Six tests failed and all six are explained and fixed (§R6); 21/82 job documents swept in both arms with zero newly refused; the one recipe that does refuse (`job_multiscale.json`, `skin: "rim"`) refuses on the merge base too. §S2(e). |
| the mass audit finds a figure whose source you cannot determine | **No.** All ten sourced. §S1(d). |
| **a job-building site cannot send a key without restructuring how jobs are assembled** | **★ YES — REPORTED, NOT SPECIAL-CASED.** The on-device path builds no job document and contains no projection at all. §S1(b). |

---

# WHAT THIS DOES NOT DO

* **It does not arm projection on the device.** §S1(b). This is the gap.
* **It does not project the latticed companion.** §S3(c). The two exported files
  of one rung now disagree about where the surface is.
* **It does not touch the `Other` CAD faces** — ~19.8% of your part is B-rep
  surface that is neither plane nor cylinder, and PR #307 left it alone. So the
  8% is still a floor on how wrong the export was, not a full correction.
* **It does not change a single mass formula.** Deliberately. §S1(d).
* **It does not re-mesh the flattened faces.** The ~0.7%-sharp-edge cost PR #307
  measured is unchanged; the weld guard addresses a different failure.

---

# A — THE PR 309 CI FAILURE: PROJECTION WAS RUNNING ON FITTED SURFACES

`threemf_import` failed in CI (113/114) on *"STL and 3MF export byte-identical
variant meshes"*. Full working in
[`a1_root_cause.txt`](../../evidence/2026-08-06-arm-projection-and-void-check/a1_root_cause.txt).

## A1 — established before fixing

**The review's premise — that the FLOAT32 weld key is STL-specific and welded a
pair 3MF would have written apart — is refuted by measurement.** The weld key is
not involved.

* **(a) The guard runs ONCE, on a shared mesh.** `export_variant_mesh` resolves
  one `export_mesh` and only then branches to `write_3mf_file` /
  `write_stl_file`. A divergence *between the writers* is not expressible there.
* **(b) Line 277 compares the two WRITTEN FILES — and both are STL.**
  `plate_job()` ([test_3mf_import.cpp:181](../../core/tests/validation/test_3mf_import.cpp))
  sets `mesh_format = "stl"` for both arms; what differs is the **input**
  (`plate_bore.stl` vs `plate_bore.3mf`). The assertion says *the same part
  through the two front doors must export the same bytes*. Nothing re-imports an
  export, so the lossy-round-trip distinction never arises.
* **(c) It PASSED on the merge base**, same fixture, same lib3mf 2.5.0#1:
  `Test #113: threemf_import ... Passed`. It was not marginal. The branch caused it.
* **(d) The two failing checks are the same assertion**, fired once per exported
  variant (the fixture accepts two). Everything else passed — including
  identical pseudo-face ids, solid-diff 0 at five resolutions, and a
  byte-identical report. **The design was identical; only the geometry moved.**

**Isolated with the CLI, not argued:** `project_cad_faces=off` → the two exports
are byte-identical; `on` → they are not. And the magnitudes settle the rest:
**~1000 of 6972 corners differ by ~2.4e-07 mm.** A different weld-guard decision
reverts a vertex by up to one voxel — ~1.5 mm here. Six orders of magnitude too
small, three orders too many vertices.

## ★ Root cause, with file and line

[`segment.cpp:185`](../../core/src/io/segment.cpp) fits a plane from a patch's
**mean normal** and [`:280`](../../core/src/io/segment.cpp) fits a cylinder by
**least squares**. So an STL/3MF import's `StepModel::faces` carry
`Plane`/`Cylinder` that were **estimated from the imported mesh**. The projection
gate in `export_variant_mesh` only asked `!cad->faces.empty()`, which those
manufactured faces satisfy — so arming the default turned projection on for mesh
parts, snapping exported vertices onto surfaces fitted from the very mesh being
exported. Because the fit is computed from vertices that STL quantises to
float32 and 3MF does not, the two imports fit slightly different surfaces.

**It is a correctness bug, not only a test failure.** PR #307's justification is
that projection is exact *because the B-rep states the surface*, and
[`job.hpp`](../../core/include/topopt/job.hpp) says "nothing is averaged, no
surface is estimated". On a mesh part both are false.

## A2 — the fix, and why not the three offered options

All three options in the review presuppose the weld key is the cause. It is not,
so none of them would have fixed this. The fix is **`StepModel::faces_are_fitted`**
([step.hpp](../../core/include/topopt/step.hpp)), set `false` by the STEP path
([part.cpp:507](../../core/src/io/part.cpp)) and `true` by the mesh path
([:551](../../core/src/io/part.cpp)); `export_variant_mesh` now requires
`!cad->faces_are_fitted`. **Projection runs where surfaces were READ, not where
they were FITTED.** It also makes core agree with the app, which already gated
its control to STEP parts (`isStepPart`).

**No writer loses precision** — the blocked-stop about one of them giving up
something it is supposed to carry does not arise, because the two writers were
never the problem. **The assertion at line 277 was not touched.**

**What happened to the two near-miss pairs the float32 key was added to catch:
nothing.** They are on the maintainer's part, which is STEP, so projection and
the weld guard still run there. Re-measured on the fixed build:

| case | tris | distinct float32 verts | non-manifold |
|---|---:|---:|---:|
| his part @64 rung 052, projection OFF | 75 616 | 37 800 | 0 |
| his part @64 rung 052, projection **ON** | 75 616 | **37 800** | 0 |
| l-bracket @48 rung 070, projection **ON** | 14 972 | **7 474** | 0 |

37 800 — not the 37 798 that motivated the float32 key — and the l-bracket's
7 474 matches its projection-OFF count exactly, so the 124 collisions are still
caught.

## A3 — ★ my local suite was not CI's, and that is why this shipped

**112 was true and meaningless.** `lib3mf` was absent from my configure, so
`export_3mf` and `threemf_import` never registered — and one of them was the test
that broke. The gates are
[CMakeLists.txt:1529](../../core/CMakeLists.txt) and
[:1843](../../core/CMakeLists.txt) (`if(lib3mf_FOUND)`); the cache read
`lib3mf_DIR-NOTFOUND`.

**Both now register locally.** `./app/scripts/build_lib3mf_macos.sh` provisions
CI's exact lib3mf 2.5.0#1 via the pinned vcpkg baseline. One trap worth naming,
already documented at
[build_cli_macos.sh:53](../../app/scripts/build_cli_macos.sh): a stale cache
keeps `lib3mf_DIR-NOTFOUND` and **re-running cmake does not re-search** —
`find_package` short-circuits. The cache must be deleted.

**And the omission is now LOUD**, so the next fresh worktree cannot repeat this.
`core/CMakeLists.txt` emits a configure-time **warning** naming the missing
dependency, the tests that will not register, and the fix:

```
REDUCED TEST SUITE — this configuration registers FEWER TESTS THAN CI.
    lib3mf       -> tests `export_3mf` and `threemf_import` will NOT register
                    fix: ./app/scripts/build_lib3mf_macos.sh   (pins CI's exact 2.5.0#1)
  A `ctest` pass here does NOT mean a CI pass. Report N/<CI's total>, not
  N/N, and say which tests did not run.
```

**Corrected denominator: `ctest` 114/114** (`ctest.txt`), including
`threemf_import` and `export_3mf`. Every evidence file claiming a full pass now
states the denominator; the earlier "112/112" is corrected in place with the
reason rather than quietly overwritten.

## A — bars

| bar | result |
|---|---|
| **R1** failing test is the proof | Red locally before (`FAIL (line 277)`, 2/47), green after. Both pasted in `a1_root_cause.txt`. Not a claimed pass — actually run. |
| **R2** full suite at CI's denominator | **114/114**, not N/N. |
| **R3** no assertion weakened | Census re-run: **1** C++ message lost (the V6 clock, already accounted for) and **0** Swift test functions. **Nothing was added to or removed from line 277.** |
| **R4** arming work not re-opened | Untouched. Both defaults, both OFF controls, the mass audit and the S3 sweep all stand. |
| **R5** root cause with file and line | `segment.cpp:185`/`:280` + the gate in `export_variant_mesh`. |
| **R6** no placeholders, no root scratch | Clean; `.vcpkg/` is gitignored ([.gitignore:12](../../.gitignore)). |

---

# IN PLAIN WORDS — WHAT WAS DONE, AND WHAT IS NEXT

**Your bolt holes now come out the size you drew them.** Every one of your six
3 mm bores was coming out of the pipeline oversize and out of round — a hole
drawn at 6.000 mm across measured between 6.50 mm and 7.86 mm, and was out of
round by up to 0.48 mm. They now come out at exactly 3.0000 mm radius and exactly
round, and every flat wall lands in the plane your CAD puts it on instead of up
to 1.7 mm away. That is on all four rungs of your own part, and it happens now
without you asking for it.

**The weights in the app drop by about 8%, and that is the numbers getting
better, not worse.** On the finished design the mesh weight goes from **649.94 g
to 598.99 g**. The lighter rungs move about the same: 479.97 → 436.85 g,
529.56 → 484.20 g, 604.70 → 556.84 g. Nothing about how weight is calculated was
changed. The reason it drops is that the exported part used to be **bigger than
the part you drew** — every flat face sat about 0.67 mm outside where the CAD
puts it, and the certificate agreed from the other end by reporting that one
variant filled 100.28% of the space it was cut from, which is impossible. The
part is now the right size, so the weight is now the right weight. One caveat
worth being straight about: that 8% is your part at the fine setting. On a
different part, or at the Fast setting, the correction can go the **other** way —
on your own part at 64³ the exported volume goes *up* by about 2%. What is being
removed is the error, and the error's sign depends on the part.

**If a run is ever refused for a sealed cavity, here is what you will see and
what to do.** The run stops that rung — the others keep going and still produce
their files — and it tells you how many lattice cells are sealed, how much volume
is trapped, the box in millimetres the cavity sits in, and which of the regions
you drew it belongs to. Then it tells you how to continue: either move the
lattice so it reaches the surface or add a drain path, **or** put
`"require_lattice_void_reaches_exterior": false` in the job's `lattice` block —
and it says explicitly that **deleting the setting will not turn it off**, because
it is on by default now, so only an explicit `false` works. It also says what you
are choosing if you do: the part ships with pockets that whatever gets inside
them can never come out of, and it will weigh more than the run says. In the app
the same switch is the **"Empty space must reach the outside"** card on the
lattice page. **On your own job none of this fires** — your lattice drains
through all six sides of the part.

**★ The one thing you should know before you trust this.** Runs you send to the
Mac worker get the corrected geometry. **Runs you do on the iPad or in the app
itself do not.** The on-device path doesn't go through the code that does the
correction — it isn't a missing setting, it's a second export route that doesn't
have the feature in it. I did not wire it, because doing so means threading the
CAD model through a part of the bridge that four previous changes have broken,
and it can't be checked without a full rebuild and testing on the device. It is
written up in detail and it is the first job on the list.

**About the CI failure, and your four latticed variants from last night.**
The build caught something real: with the correction switched on by default, it
was also being applied to parts imported as **STL or 3MF** — and for those there
is no CAD file to restore anything to. The app invents approximate flat and
round surfaces for them by looking at the mesh, and the correction was snapping
the geometry onto those guesses instead of onto anything you drew. It now only
runs on STEP parts, where the surfaces are genuinely stated. Your STEP parts are
unaffected: the bores and flat faces still come out exactly as described above.

**★ Are last night's four latticed variants affected? No.** They were exported
as STL by a build from before this branch, so none of this touched them — not
the correction, not the enclosed-void rule. They are exactly the files you
already have. What is true of them is what §S1(d) says of any export from that
build: their **mesh-derived** weights are about 8% high, because the part in the
file is bigger than the part you drew. Re-run them on the new build and the
weights will drop by roughly that much without a gram of material changing.

**What I would do next, in order:**

1. **Close the device gap.** Until it is closed, "on by default" means "on by
   default for worker runs", and two people comparing an iPad export against a
   worker export of the same job will see an 8% difference and no explanation.
2. **Project the latticed companion too.** Right now `variant_068.stl` is the
   corrected part and `variant_068_lattice.stl` is still the oversize one. Same
   rung, same run, two different parts.
3. **Let the repo-wide sweep finish.** It runs all 82 committed job documents
   through both the old and the new build. 41 are done and none refuses; the rest
   is running and the number belongs in a comment on this PR, not in a guess.
4. **Cover the other quarter of your surface.** About 19.8% of the part is CAD
   surface that is neither a plane nor a cylinder — cones, tori, fillets. Those
   have closed-form answers too and are the largest remaining win.
5. **Decide whether "open" should mean "open enough".** Today a one-voxel channel
   counts as a drain path. It probably should not, but the honest way to set a
   minimum is to measure real drain behaviour rather than pick a number.
