# Lattice width bounds (LatticeReview's ask, 2026-11-11)

Width over cell, per type: the open look, and where the lattice closes up (lattice.hpp,
`lattice_width_bounds`). Run from this folder with `python3 -I <script>`.

- `gap.py` -> `gap.txt`: every strut type's two gaps on its canonical cell (re-stated from
  core/src/fea/strut_cell.cpp): in 3D between struts that share no node, and seen square-on to
  a cell face between neighbouring parallel struts. Exact segment distances.
- `sheet2.py`: the sheets' channels, bisected on the void's percolation over a 3x3x3 tiling with
  the TRUE distance to the mid-surface (EDT): gyroid 0.4174 (64 voxels a cell), 0.4226 (96);
  schwarz_d 0.3166, 0.3242. Both converge from below.
- `throat.py`: the clearance at each channel's critical points of f, exactly (rays to the first
  zero crossing, refined): gyroid node sqrt 3 / 8 = 0.216506, edge midpoint 0.229658 -> the
  throat is the node, wall 0.433013; schwarz_d edge midpoint 0.175703, node 0.216506.
- `throat2.py`: schwarz_d's cross-section clearance along its edge: 0.177251 (-0.06 cell),
  0.175342 (-0.03), 0.175726 (0), 0.175335 (+0.03) -> throat wall 0.3507 (+-0.0002).
- `test_lattice_width_bounds.txt`: the core test's output.
