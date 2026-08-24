# Overnight run — 2026-08-24 (Claude, while you slept)

Branch: `claude/topopt-lattice-preview-1b7355` (this worktree). Every fix has tests;
the sim build installed on the iPad is from this branch tip.

## DECISIONS YOU ASKED ME TO LEAVE FOR YOU

1. **Width statistic** — you said "read the actual depth of that area, preferably per
   voxel". Implemented exactly that (see below). The one judgement call inside it:
   the per-cell divisor uses the same nearest-whole-fit `round` as the region rule
   (so a 13 mm cell on a 12.03 mm wall stays one cell), and the "never S/2" bump is
   NOT applied to the width-driven divisor — S/2 is exactly what a half-thick wall
   holds. Say the word if you want ceil (stricter) or the S/2 ban there too.
2. **Solid outline vs your attached-walls-only rule** — the outline rim currently
   draws along the WHOLE face outline (the in-plane distance field has no notion of
   "attached vs open to the world"). With fullSkin on, open faces are skinned anyway,
   so tonight it reads fine — but the attached-only refinement is still open.
3. **The lattice-variant STL is a triangle soup** (by design, slicer-targeted). I made
   the app display it raw instead of dying (details below). If you want the FILE
   itself manifold (17k duplicated triangles from the two overlapping regions), that
   is a core-side mesh-emission change — not done tonight.
4. My driving ran the Lattice pipeline on **M2 verticalStand**, so the project now
   shows "Optimized" with a lattice variant result (the app persists run outcomes
   itself). Settings/roles/depths are untouched (verified in project.json).

## FIXED TONIGHT (each committed with tests)

### 1. The 12.00/6.50 single-cell asymmetry — was a SWAPPED-DEPTH red herring, then his real fix
- The handoff had the faces' depths swapped; project.json says face 15 → 12,
  face 2 → 13. With true depths every logged bake reproduced exactly.
- Root cause of the visible 6.50: the p05 width statistic (8.59 = face 2's thinnest
  sliver; median 12.03) crossing the n=1.5 rounding boundary.
- **Per your ruling**: width is now a per-voxel FIELD
  (`wallWidthFieldAlongNormalMM`); the stepped region cell anchors on the MEDIAN and
  each painted cell divides to what its OWN wall holds (round, not ceil).
- **Verified in-sim**: `DIAG regionCell` shows both faces at floor 1 → one cell
  through each wall (stated [12.0, 13.0]); the sliver got exactly 40 local 6.5 mm
  cells (`w[min=8.59 … shrunk=40]`). Visually: clean truss, flush caps, no quilt.

### 2. Entering the lattice stage KILLED the run on its own mesh
- Fresh session → Lattice → the on-device lattice job ran, core certified it, then
  the run FAILED: "cannot import … non-manifold edges". The lattice STL is a
  deliberate union-less soup; with two overlapping regions it has 17,172 duplicated
  triangles + 194 true T-junction edges. The solid importer is right to refuse — and
  nothing at that call site needs a solid. Now falls back to the raw soup parse the
  RELATTICE path always used. Run completes; certification verdict is core's.

### 3. A loaded "stepped" project silently became "doubled" (the night's big one)
- `cellTransition` (the settings-page picker state) was stored but NEVER persisted;
  every load reset it to Default Grade while `algorithm` loaded correctly. The
  settings page save then stamped `algorithm = cellTransition.coreAlgorithm` —
  quietly rewriting stepped → doubled. Measured live: project.json said stepped, the
  runtime guard printed `algo='doubled'`, the preview silently drew the ladder.
- `cellTransition` is now COMPUTED over `algorithm` (setter writes it). One home.
- This would have hit you on every app relaunch → settings page → save.

## VERIFIED (your backlog items 1–3 of the night)
- **Quilt / single-cell confirmation**: stated [12,13] at floor 1, flush caps, no
  quilt on either wall (screenshots in the scratchpad, and the sizes histogram is
  12.00×105 + 13.00×92 with only sliver/rim shrinks).
- **Solid outline**: baked (solidRim=18, outline band 1.72 mm) and visible on screen
  along wall boundaries.
- **Blank spots (front-left)**: the complaint was against the old 6.5 mm layout;
  at the new one-cell layout coverage is full. Re-check with your own eyes.

## LATER IN THE NIGHT

### Grade-to-fit-shape on Default Grade (doubled) — the distance was the wall's thickness
The doubled ladder ALREADY had a shape ceiling (applied to `desired`, all modes) —
but driven by the 3-D distance to the candidate set's edge, which reaches 0 at the
DEPTH CAPS: through a 12 mm wall it reads ~6 mm everywhere. At the one-cell sizes
single-cell now produces, `S ≤ 2d` bound mid-wall. `perVoxelForGrading` now hands
each voxel its OWNING region's in-plane distance (3-D only where no axis-aligned
face region owns it — bolt regions and whole-part lattices are byte-identical).
Tested headlessly on your part; **not yet eyeballed in the sim** — switching your
project to Default Grade would rewrite its algorithm on save, and you said copies
only. Try it yourself, or tell me duplicating the project is fine.

### Organic — deliberately NOT touched here
The organic-look work is actively owned on other branches (newest:
"Thin beads, level bridges, a flattened roof — the fabric the traced cube was
loved for" on `claude/organic-lattice-beauty-print-9721c9`, plus
`claude/organic-growth-generator`). Redoing it on this branch would collide.
PR 352 (core printability) is OPEN and reviewed — findings at the bottom of this
doc once the review agent lands them.

### Grading from stress + the overlay — WORKS, and the flatness is physics
The waveform icon in the lattice-stage viewport toggles the stress view; the part
paints by von Mises with a legend. On M2 verticalStand at your 5.5 lbs the field
tops out at ~0.02 MPa against a ~30 MPa allowable — utilisation ~0.1% — so an
honest utilisation-driven grade is uniform at the band's low end, and the interior
fill rightly shows no variation. The machinery is wired; this part just is not
working hard. If you want the grade RELATIVE to the field's own range (visible
variation even at negligible absolute stress), that is a product decision — say so.

### Sample responds to single-cell — wired
The settings-page sample now derives its cell through core's own derivation at the
mode's floor (member = smallest declared include depth, the bake's own
pre-measurement fallback), so toggling single-cell doubles the sample's cell on
screen. Chain: `derivedSampleCellMM` (LatticeSetupWizard) →
`stageMesh(derivedCellMM:)`. Test: LatticeSampleSingleCellTests.

### Full test-suite re-run — GREEN
**2194 tests, 30 skipped, 0 failures, exit 0** (the count is up from 2179: tonight
added ~18 tests and the suite total moved with main's earlier merges). Three
earlier attempts were void — one piped through `tail` (exit code was tail's, a
green run measuring nothing), one died on a compile error in a new test, one was
crashed BY my first attached-rim test indexing an empty field. The final run has
the real exit code and the totals captured.

### The attached-only rim (your unscheduled solid-edges rule) — DONE, and it found two real bugs
The rim now keys on an in-plane field seeded only by part material OUTSIDE the
latticed set: junction edges rim, open edges don't (the finish owns them). In-sim:
solidRim went 18 → 11 with every other number byte-identical. On the way it
uncovered (a) `partSDF` is misnamed — its SIGN is the region-clipped occupancy's,
so nothing outside the regions is ever negative (the seed now reads
`memberThicknessMM`, the whole-part field); and (b) the distance transform mapped
UNREACHABLE voxels to 0, which downstream means "on the boundary" — the exact
two-meanings-of-zero inversion again; unreached is now `kFarMM`.

**Latent gap worth knowing (deliberately not "fixed"):** because `partSDF` is
clip-signed, the along-normal width walk still stops at a region's own caps
wherever no OTHER region continues the material — a single declared face into a
deeper wall reads its declared depth. But note the trade before changing it:
walking the WHOLE-part solid instead would balloon at junctions (along the front
wall's normal, the base plate reads as the part's full ~49 mm depth — the same
junction inflation that made the isotropic measure quilt). The cap-stop is
partly protective. If this ever needs solving, it needs a junction-aware rule,
not a substrate swap — one for your eyes, not for 3 a.m.

## PR 352 REVIEW — "Organic lattice: printability, shape fit, and a scale"

**Verdict: not merge-ready.** The full 13-finding review is condensed here (I did
not post to GitHub — say the word and I will). The headline guarantee — mid-air
starts refused — holds only on the re-lattice-variant path, only AFTER the refused
meshes are already written, and only when the job states a `layer_height_mm`.

Ship-blockers:
1. `require_no_midair_start` enforced only in `lattice_variant_job`; the main
   optimize run's `emit_lattice` → `lattice_one_variant` path exports the same
   files with no check.
2. The refusal throws after the STL/3MF/_WELDED files are on disk — nothing
   deletes or withholds them.
3. With `loads.layer_height_mm` unset (default 0), the mid-air census is skipped
   and the guard passes vacuously — the default config silently disarms it.
4. The branch-support fallback can't tell anchored/merged tips from dead ones
   (no flag; all end `alive=false`), so it deletes real lattice material wherever
   branched support SUCCEEDED.
5. The fill mat runs on round 0, not at quiescence (unlike slenderness), and its
   struts are uncuttable — mis-placed fill is permanent.
6. Pad-under-touchdowns is armed by default with no guard: if no span endpoint is
   within 1.5·rmat of the cut plane, ZERO mat is emitted, silently (the author's
   own admission, confirmed reachable in shipped configs).
7. The flat-base cut applies only to the welded file; the always-written span-soup
   STL keeps the sub-base capsule caps ("dots").
8. `organic_scale` is silently inert with plain `cell_mm` (no swept window):
   multiplies two zeros, no refusal.

Smaller: `curves_kept_for_coverage` plumbed but never incremented (permanent 0 on
the receipt); base-plane sentinel is value-based (z ≤ 0 base silently skips the
weld cut); fixed-point cap exits silent (`fixed_point_converged=false` only);
prune budget is cumulative across rounds then silently skips;
`organic_shape_fit_only` can COARSEN cells and ignores W/N*, contradicting its
own header; B9 lacks a positive control (can pass vacuously);
`TOPOPT_ORGANIC_NO_BASE_MAT` changes shipped geometry with no receipt marker;
`[scale]/[vdi]/[base-mat]` stderr scaffolding still unconditional.

Minimum to merge: move the refusal before the writes and onto both export paths;
census must run (or refuse as unverified) when layer_height is 0; per-tip
anchored/merged flags; gate fill mat on quiescence; fix or remove the pad logic;
refuse scale without a window; apply the base cut to the soup STL or document it.
