#pragma once

// EXACT signed distance to a closed triangle mesh (task
// 2026-08-08-strut-clip-matches-shell).
//
// WHY THIS EXISTS. The latticed export writes TWO surfaces into one file: the
// solid SHELL (`variant.v3.mesh` — marching cubes over the physical density)
// and the strut soup, whose centrelines are clipped to
// `LatticeBoundary::signed_distance >= radius`. Until this header the boundary's
// base term was the distance to the union of solid voxel CUBES, which is NOT the
// surface the shell is extracted from: a marching-cubes vertex sits on the
// segment between two voxel CENTRES, so on a flat face the two surfaces coincide
// exactly while at a convex edge the isosurface CHAMFERS the cube union and lies
// strictly inside it. Struts clipped to the cube union therefore end outside the
// shell — at edges, and only at edges.
//
// THE CONTRACT this class supplies, and it is the one `LatticeBoundary` needs:
// `signed_distance` is the EXACT geometric signed distance to the mesh surface,
// POSITIVE INSIDE — the same sign convention `LatticeBoundary::signed_distance`
// uses — and an exact distance is 1-Lipschitz, so the certified-clip refinement
// (`certified_clip_spans`) stays sound when this term joins the min().
//
// THE SIGN is the angle-weighted pseudonormal test (Bærentzen & Aanæs 2005): the
// closest point on the mesh lies in the Voronoi region of a face, an edge or a
// vertex, and the corresponding pseudonormal — the face normal, the sum of the
// two incident face normals, or the angle-weighted sum of the incident face
// normals — gives the correct inside/outside answer for EVERY closest point,
// which a plain face normal does not. It requires a closed, consistently wound,
// welded mesh; `marching_cubes` produces exactly that (welded via its edge map),
// and `check_watertight` is what proves it per part. WHICH WAY the winding faces
// is READ from the mesh's own signed volume at build time rather than assumed —
// marching-cubes output is wound INWARD by the STL convention, and the
// constructor records the measurement that establishes it.
//
// COST. Queries go through a uniform-grid accelerator over the triangles, walked
// in expanding Chebyshev shells with an exact stopping bound — the same
// discipline `LatticeBoundary::voxel_distance` already uses over voxel cubes, so
// a clip query costs the same order it did before.

#include <cstdint>
#include <vector>

#include "topopt/mesh.hpp"

namespace topopt {

class MeshDistance {
 public:
  // Build an accelerator over `mesh`, which MUST outlive this object. `cell_mm`
  // is the accelerator's cell size; <= 0 derives one from the mesh's own mean
  // triangle extent (the natural scale — one surface layer per cell).
  //
  // The mesh must be closed, consistently wound (outward CCW) and welded for the
  // SIGN to be meaningful; the unsigned distance is correct regardless. An empty
  // mesh makes `empty()` true and every query returns 0.
  explicit MeshDistance(const TriangleMesh& mesh, double cell_mm = 0.0);

  // ★ NOT THREAD-SAFE FOR CONCURRENT QUERIES ON ONE INSTANCE. A query marks
  // triangles with a visit stamp so a triangle spanning several accelerator
  // cells is tested once, and that stamp array is per-instance mutable state.
  // Every caller today is single-threaded (`generate_lattice` is documented "no
  // threads", and `lattice_certification_mask` is a plain sweep), but
  // `LatticeBoundary` holds this through a shared_ptr, so two COPIES of a
  // boundary share one instance — copying is not a way to get a second thread's
  // worth of it. Give each thread its own MeshDistance if that ever changes.
  bool empty() const { return tri_count_ == 0; }

  // EXACT signed distance to the surface: > 0 strictly INSIDE, < 0 outside, 0 on
  // it. Deterministic (fixed traversal order, no RNG, no state carried between
  // queries beyond the visit stamps).
  double signed_distance(const Vec3& p) const;

  // EXACT unsigned distance to the surface.
  double unsigned_distance(const Vec3& p) const;

  // The accelerator's cell size, in mm — reported so a probe can state what it
  // measured with.
  double cell_mm() const { return cell_; }

  // Whether the source mesh was wound INWARD (its enclosed signed volume came
  // out negative) and the pseudonormals were therefore flipped at build time.
  // True for `marching_cubes` output — see the constructor for the measurement.
  bool inward_wound() const { return inward_wound_; }

 private:
  struct Closest {
    Vec3 point{};
    double dist2 = 0.0;
    int tri = -1;
    // The Voronoi feature the closest point fell in: 0,1,2 = vertex a,b,c;
    // 3,4,5 = edge ab,bc,ca; 6 = face interior.
    int region = 6;
  };

  Closest closest(const Vec3& p) const;
  void gather_cell(long cx, long cy, long cz, const Vec3& p, Closest& best) const;

  const TriangleMesh* mesh_ = nullptr;
  std::size_t tri_count_ = 0;

  // Uniform grid over the mesh bounding box.
  Vec3 lo_{}, hi_{};
  double cell_ = 1.0;
  long nx_ = 1, ny_ = 1, nz_ = 1;
  std::vector<std::uint32_t> cell_start_;  // size nx*ny*nz + 1 (CSR)
  std::vector<std::uint32_t> cell_tris_;

  // Pseudonormals. `face_n_` is the unnormalised face normal; `vert_n_` the
  // angle-weighted vertex sum; `edge_n_` the two-face sum, stored per (triangle,
  // local edge) so no hashing happens at query time.
  std::vector<Vec3> face_n_;
  std::vector<Vec3> vert_n_;
  std::vector<Vec3> edge_n_;  // 3 per triangle: edges ab, bc, ca

  bool inward_wound_ = false;

  // Visit stamps so a triangle spanning several cells is tested once per query.
  mutable std::vector<std::uint32_t> stamp_;
  mutable std::uint32_t query_ = 0;
};

}  // namespace topopt
