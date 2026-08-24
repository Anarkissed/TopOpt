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

## STILL TO DO (continuing tonight, in order)
- Grade-to-fit-shape on Default Grade (doubled) and Organic.
- Organic looks organic (PR 352 review, strut diameter from core's law).
- Grading from stress + stress overlay.
- Sample patch responds to single-cell toggle.
- Full test-suite re-run.
