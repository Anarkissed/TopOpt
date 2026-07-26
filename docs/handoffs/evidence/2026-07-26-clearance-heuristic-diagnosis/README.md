# Evidence — auto-clearance heuristic diagnosis (2026-07-26)

Reproduce from the repo root:

```bash
EVID=docs/handoffs/evidence/2026-07-26-clearance-heuristic-diagnosis
CORE="core/src/io/part.cpp core/src/io/stl.cpp core/src/io/segment.cpp core/src/mesh/mesh.cpp"
clang++ -std=c++17 -O2 -Icore/include "$EVID/probe.cpp"   $CORE -o "$EVID/probe"
clang++ -std=c++17 -O2 -Icore/include "$EVID/analyze.cpp" $CORE -o "$EVID/analyze"
clang++ -std=c++17 -O2 -Icore/include "$EVID/render.cpp"  $CORE -o "$EVID/render"
./"$EVID/probe" .            # per-face heuristic verdict, every mesh fixture
./"$EVID/analyze" .          # geometric ground-truth for the shelf bracket
./"$EVID/render" . "$EVID"   # PPM renders (convert with `sips -s format png`)
```

The three sources compile against the OCCT-free / Eigen-free core slice
(`part.cpp`, `stl.cpp`, `segment.cpp`, `mesh.cpp` only) — the same STL import +
`segment_mesh_faces` pipeline the app drives on a mesh import. Binaries are not
committed; rebuild with the commands above.

## Files
- `probe.cpp` / `probe_output.txt` — runs `import_part` + `segment_mesh_faces`
  on every mesh fixture, then reproduces the app's two bore predicates
  (`FaceTopology.isCurved` 5° fan; `StepFaceGeometry.isCylinder`) and the Auto
  distances (`margin = r`, `axial = 2r`). One row per proposed bore primitive.
- `analyze.cpp` / `analyze_output.txt` — geometric ground-truth: for every
  Cylinder pseudo-face on the shelf bracket, measures radius/bbox, angular wrap,
  and concavity to separate real through-holes from wall/corner misfits.
- `bracket_shaded_a.png`, `bracket_shaded_b.png` — plain shaded renders of
  `WallMount_ShelfBracket.stl` (two azimuths). Shows the real geometry: a
  triangular truss bracket, 2–3 small round bolt holes on the left flange, plus
  large **lightening pockets** with rounded corners (not holes).
- `bracket_faces_a.png` — same view coloured by pseudo-face. Each pocket-corner
  wall and outer edge is its own pseudo-face; those are what the heuristic
  mis-proposes as bores.
