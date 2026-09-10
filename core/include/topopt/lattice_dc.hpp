#pragma once
// ── The lattice as an isosurface of its own exact SDF, contoured manifold ─────
//
// WHY, after LSLT already meshes it analytically. LSLT is fast and exact on the strut
// surfaces, but it inherits the whole joint problem: mandatory vertices, interference
// planes, hole filling, unclosed nodes, a cap per arm. Every one of those exists only
// because the method builds each strut separately and must then reconcile them. And the
// published methods in that family do not solve it either -- the 2024 state of the art
// (arXiv:2405.15197) makes NO manifoldness claim, does not treat high-valence nodes, and
// fills the leftover holes "by a straightforward method". MEASURED here: 28,642 edges
// used more than twice, and an enclosed volume of 20,966 mm3 against a true union of
// 29,139 +/- 5 -- the mesh under-reports by 28 %.
//
// A UNION HAS NO JOINTS. Take the field
//
//     d(p) = min_i ( dist(p, segment_i) - r_i )
//
// and every junction, at any valence and any mix of radii, is handled by the min. There
// is nothing to stitch. The gradient is exact too (the unit vector from the nearest
// segment), so the contouring gets true Hermite data rather than finite differences.
//
// WHY THIS IS NOT THE MARCHING-CUBES WELD AGAIN. That failed because it sampled a
// UNIFORM grid over the bounding box, so resolving a 0.84 mm strut inside a 203 mm part
// cost 2.6e8 voxels and the 40 M cap forced a 0.45 mm pitch that dropped thin struts
// outright (its volume came to 9,490 mm3, 67 % low). Cost belongs on the SURFACE, not
// the box: this visits only cells the surface passes through, which on the M2 lattice is
// 2.9e6 at 0.2 mm against 2.6e8 uniform -- 90x fewer, and 180x at 0.1 mm.
//
// AND WHY DUAL CONTOURING RATHER THAN MARCHING CUBES. It places one vertex per cell by
// minimising the quadratic error of the crossing planes, so it reproduces the sharp
// crease where two struts meet instead of rounding it away, and on a uniform grid it is
// manifold by construction. Manifold Dual Contouring (Schaefer, Ju & Warren, IEEE TVCG
// 13(3):610-619, 2007, DOI 10.1109/TVCG.2007.1012) is the extension that keeps that
// guarantee under adaptive simplification; the cell splitting below is its criterion,
// applied where one cell would otherwise carry two sheets of surface.
//
// THE ACCEPTANCE TEST is the union volume (topopt/lattice_union_volume.hpp), which is
// measured without any mesh and so cannot be fooled by a defect in this one.

#include <cstddef>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/organic_lattice.hpp"

namespace topopt {

struct LatticeDcOptions {
  // The BASE cell: the FINEST a leaf can be, and the grid the octree merges upward from.
  // 0 => derived from the thinnest strut so it is resolved across its diameter.
  double cell_mm = 0.0;
  int cells_across_thinnest = 4;
  // Bisection steps when locating an edge crossing. The field is exact, so this is pure
  // precision: 12 steps put the crossing within cell/4096.
  int crossing_steps = 12;
  // Tikhonov weight pulling an under-determined QEF toward the cell's mass point.
  double qef_regularisation = 0.02;

  // ── the octree ──────────────────────────────────────────────────────────────
  // false reproduces the uniform grid, which is what the convergence controls were
  // established on and is kept as the reference implementation.
  bool adaptive = true;
  // NO SUB-BASE REFINEMENT, AND THE MEASUREMENT THAT SETTLED IT. Taking the ambiguous
  // cells one level FINER than the base looked like the cure for the last non-manifold
  // edges. It is not. Measured on the M2 lattice at a 0.4 mm base: 284 non-manifold edges
  // became 591, and 177 boundary edges and 129 dropped quads appeared where there had
  // been none. Widening the refinement to the ambiguous cell's whole one-ring made it
  // worse again (3,871 boundary, 2,595 dropped) -- the damage scales with the number of
  // level changes, not with how they are placed. The cause: a coarse cell beside a
  // refined one cannot see, at its own corners, a crossing that exists only on the finer
  // grid, so it reports itself empty and the mesh opens along that face. Coarsening never
  // hits this because it only merges cells whose fine crossings it has already summed.
  // So the tree only ever goes UP from the base, and the base is chosen fine enough.
  //
  // How far ABOVE cell_mm the tree may coarsen: the RMS distance, in mm, that the fine
  // crossing planes are allowed to sit off the merged cell's single vertex. 0 => a tenth
  // of cell_mm. This is the size dial: raise it for a smaller file, lower it for fidelity.
  double simplify_tolerance_mm = 0.0;
  // A ceiling on how coarse a leaf may become, as a multiple of cell_mm (a power of two is
  // used, rounded down). Keeps a flat slab from collapsing into one enormous cell whose
  // vertex then drags long slivers to its finer neighbours.
  double max_leaf_multiple = 8.0;
};

struct LatticeDcStats {
  double cell_mm = 0.0;               // the base cell asked for
  double finest_leaf_mm = 0.0;        // after refinement
  double coarsest_leaf_mm = 0.0;      // after simplification
  double simplify_tolerance_mm = 0.0;
  std::size_t capsules = 0;
  std::size_t cells_visited = 0;      // octree nodes descended into
  std::size_t cells_active = 0;       // leaves carrying surface
  std::size_t field_evaluations = 0;
  std::size_t cells_split = 0;        // leaves carrying more than one sheet of surface
  std::size_t cells_merged = 0;       // internal nodes collapsed into a single leaf
  std::size_t quads_dropped = 0;      // a neighbouring leaf held no vertex: a hole
  std::size_t vertices = 0;
  std::size_t triangles = 0;
  std::size_t boundary_edges = 0;     // used once: a hole
  std::size_t nonmanifold_edges = 0;  // used more than twice
  bool watertight = false;
  bool manifold = false;
  double volume_mm3 = 0.0;            // enclosed, for comparison with the union volume
  double seconds = 0.0;
};

TriangleMesh lattice_dual_contour(const std::vector<OrganicSpan>& spans,
                                  const LatticeDcOptions& opt, LatticeDcStats& stats);

}  // namespace topopt
