#ifndef TOPOPT_BUILD_FRAME_HPP
#define TOPOPT_BUILD_FRAME_HPP

// build_frame — THE rigid rotation that carries a certified build direction onto
// +Z, so the EXPORTED GEOMETRY IS the certified object (handoff
// 2026-08-01-bake-build-orientation).
//
// WHY THE GEOMETRY AND NOT A TRANSFORM. A 3MF build item's transform is ADVICE.
// "Place on bed", "auto-orient" and "arrange" all reset it, and slicers do that
// routinely — sometimes on import — so an orientation that lives only in a
// transform is an orientation the slicer is free to discard. Rotated VERTICES
// cannot be reset. run_job already holds this line for the lattice REGION ("the
// object the gate certifies and the file the slicer opens are the SAME region by
// construction"); this is the same line drawn around ORIENTATION.
//
// TWO FRAMES, NAMED ONCE, AND THEY ARE THE ONLY TWO:
//
//   MODEL frame  — the input geometry's own coordinates. The voxel grid, the
//                  solve, fields.bin, the loads, the fixtures, the clearances
//                  and the design box all live here and NONE of them move.
//   BUILD frame  — the exported file's coordinates: the model frame rotated by
//                  `BuildFrameRotation` so the applied build direction is +Z.
//
// EVERY DIRECTION-BEARING SCALAR IS THE SAME NUMBER IN BOTH. The interlayer
// tension, its margin, the support-voxel count, the build height, the first-layer
// footprint, the min-feature count and the strut margins are all computed from
// the stress/geometry AND the build direction; a rigid rotation that carries the
// build direction to +Z carries each of those computations to itself. So they
// describe the file and the model equally, and there is no frame to get wrong.
// Only VECTORS need a frame stated, and this header is where the vocabulary for
// stating it lives.
//
// EXACTNESS (bar V4). For the six cube axes the rotation is a SIGNED AXIS
// PERMUTATION and is applied as one: `out[i] = sign[i] * v[perm[i]]`, never as a
// matrix product. Negating a double is exact and permuting is exact, so the
// exported coordinates are the input coordinates bit-for-bit up to permutation
// and sign — no dot-product rounding, no -0.0 drift from summing signed zeros.
// Off-axis candidates take the minimal-angle (Rodrigues) rotation and are lossy;
// `axis_permutation` is how a caller (or a test) tells the two apart.
//
// WINDING (bar V5). `determinant()` is +1 for every rotation this header
// produces — a reflection would flip triangle winding and turn the part
// inside-out for the slicer. The constructor never returns a negative-determinant
// transform; `rotation_determinant` exists so a test can say so rather than
// assume it.

#include <array>

#include "topopt/mesh.hpp"  // Vec3, TriangleMesh, TriangleSink

namespace topopt {

// WHEN the exported geometry is rotated into the build frame. The job key is
// "bake_build_orientation"; the decision is made in exactly one place
// (resolve_bake_plan, production.hpp).
enum class BakeBuildOrientation {
  // THE DEFAULT. Bake ONLY when the user did NOT declare a build direction.
  //   * undeclared -> the scorer's best candidate is CHOSEN, certified, and
  //     baked. The receipt says so, loudly, and says when it is the reason the
  //     part passes.
  //   * declared   -> respected VERBATIM and NOT baked. Someone who named a
  //     direction may need a face down for finish, a bore round, or existing
  //     fixturing, and rotating their file would fight that. The recommendation
  //     and the verdict difference are still reported; nothing is overridden.
  //     This case is bit-identical to the pre-bake behaviour (bar V2).
  Auto,
  // Bake whatever direction is RESOLVED, declared or not. The opt-in that closes
  // the Auto gap above for a user who wants their declared orientation carried
  // in the file rather than in a transform. Never the default: it changes the
  // exported bytes of a job that declared a direction.
  Always,
  // Never bake and never choose. Exactly PR 271's behaviour, byte for byte, for
  // a caller that wants the pre-bake pipeline back (bar V3's stated fallback).
  Off,
};

// A rigid rotation of the MODEL frame onto the BUILD frame.
struct BuildFrameRotation {
  // Row-major 3x3, always a proper rotation (determinant +1).
  std::array<double, 9> m{{1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0}};

  // The MODEL-frame direction that this rotation carries onto +Z (unit).
  Vec3 build_dir_model{0.0, 0.0, 1.0};

  // true when every entry of `m` is exactly 0, +1 or -1 — i.e. the rotation is a
  // signed axis permutation and `apply` is EXACT. True for exactly the six cube
  // axes. When true, `perm`/`sign` hold the permutation:
  //   out.x = sign[0] * v[perm[0]],  out.y = sign[1] * v[perm[1]],  ...
  // with component indices 0=x, 1=y, 2=z.
  bool axis_permutation = true;
  std::array<int, 3> perm{{0, 1, 2}};
  std::array<double, 3> sign{{1.0, 1.0, 1.0}};

  // true when the rotation is the identity — the build direction is already +Z
  // and baking is a no-op. Exported bytes are then unchanged by construction.
  bool identity = true;
};

// THE rotation for `build_dir`. Deterministic: the same direction always yields
// the same rotation, so two runs of the same job export the same bytes.
//
//   * `build_dir` on a cube axis -> a signed axis permutation, det +1, EXACT.
//     The six choices are fixed literals, not derived, so they cannot drift.
//   * otherwise -> the MINIMAL-ANGLE rotation about `build_dir x +Z` (Rodrigues).
//     Deterministic and det +1, but lossy: the exported coordinates are rounded
//     dot products. `axis_permutation` is false and a caller that needs
//     exactness must check it.
//   * `build_dir` already +Z -> the identity.
//   * `build_dir` == -Z -> a 180-degree turn about +X (the cross product is
//     degenerate there, so the axis is chosen explicitly rather than by a
//     tie-break that could differ between builds).
//
// Throws std::invalid_argument if `build_dir` is zero length or non-finite.
BuildFrameRotation build_frame_rotation(const Vec3& build_dir);

// Rotate one MODEL-frame point/vector into the BUILD frame. Uses the exact
// signed-permutation path when `r.axis_permutation`, the matrix otherwise.
Vec3 to_build_frame(const BuildFrameRotation& r, const Vec3& v);

// Rotate a BUILD-frame point/vector back into the MODEL frame (the transpose).
Vec3 to_model_frame(const BuildFrameRotation& r, const Vec3& v);

// The determinant of `r.m`. Always +1 for a rotation this header produced;
// exposed so bar V5 can ASSERT that rather than trust it.
double rotation_determinant(const BuildFrameRotation& r);

// A whole mesh, rotated. Vertex ORDER and triangle WINDING are preserved
// verbatim — the determinant is +1, so the rotated surface keeps its outward
// normals and its manifold statistics (boundary edges, non-manifold edges,
// components) are unchanged: a rigid map is a homeomorphism and welding by exact
// coordinate is preserved because the exact path permutes coordinates.
TriangleMesh rotate_mesh(const TriangleMesh& mesh, const BuildFrameRotation& r);

// A TriangleSink that rotates every triangle into the BUILD frame and forwards
// it. This is how the STREAMING exports (the lattice: shell + solid companion +
// struts, gigabytes of soup) get baked without ever holding the mesh — peak
// memory stays flat in the output size, exactly as before. Vertex order within
// the triangle is untouched, so winding survives.
class RotatingTriangleSink : public TriangleSink {
 public:
  RotatingTriangleSink(TriangleSink& downstream, const BuildFrameRotation& r)
      : downstream_(downstream), r_(r) {}
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
    downstream_.add_triangle(to_build_frame(r_, a), to_build_frame(r_, b),
                             to_build_frame(r_, c));
  }

 private:
  TriangleSink& downstream_;
  BuildFrameRotation r_;
};

}  // namespace topopt

#endif  // TOPOPT_BUILD_FRAME_HPP
