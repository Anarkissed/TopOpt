#include "topopt/build_frame.hpp"

#include <cmath>
#include <cstddef>
#include <stdexcept>

// THE rotation that carries a certified build direction onto +Z (handoff
// 2026-08-01-bake-build-orientation). Pure C++/std — no Eigen, no OCCT — so it is
// part of the always-built library and the bars that rest on it run in every
// configuration.

namespace topopt {
namespace {

double dot3(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

// EXACT cube-axis detection: the component is exactly +-1 and the other two are
// exactly zero. Deliberately NOT a tolerance test. The candidate set normalizes
// {-1,0,1}^3 vectors (length 1 divides exactly) and resolve_build_direction
// normalizes an explicit key the same way, so a genuine cube axis arrives here
// EXACT — while a direction that is merely NEAR an axis takes the general path
// and is honestly reported as lossy. A tolerance here would let bar V4's
// "bit-identical up to permutation and sign" pass on a rotation that is not one.
// (-0.0 == 0.0 in IEEE, so a component that normalized to negative zero still
// counts as zero, which is what we want.)
bool exact_cube_axis(const Vec3& d, int* axis, double* s) {
  if (d.y == 0.0 && d.z == 0.0 && (d.x == 1.0 || d.x == -1.0)) {
    *axis = 0;
    *s = d.x;
    return true;
  }
  if (d.x == 0.0 && d.z == 0.0 && (d.y == 1.0 || d.y == -1.0)) {
    *axis = 1;
    *s = d.y;
    return true;
  }
  if (d.x == 0.0 && d.y == 0.0 && (d.z == 1.0 || d.z == -1.0)) {
    *axis = 2;
    *s = d.z;
    return true;
  }
  return false;
}

// Fill `m` from an already-set signed permutation: row i carries `sign[i]` in
// column `perm[i]`. Every entry is exactly 0, +1 or -1.
void matrix_from_permutation(BuildFrameRotation* r) {
  r->m.fill(0.0);
  for (int i = 0; i < 3; ++i)
    r->m[static_cast<std::size_t>(3 * i + r->perm[static_cast<std::size_t>(i)])] =
        r->sign[static_cast<std::size_t>(i)];
}

}  // namespace

BuildFrameRotation build_frame_rotation(const Vec3& build_dir) {
  const double len = std::sqrt(dot3(build_dir, build_dir));
  if (!(len > 0.0) || !std::isfinite(len))
    throw std::invalid_argument(
        "build_frame_rotation: build_dir is zero length or non-finite");
  const Vec3 d{build_dir.x / len, build_dir.y / len, build_dir.z / len};

  BuildFrameRotation r;
  r.build_dir_model = d;

  int axis = 0;
  double s = 1.0;
  if (exact_cube_axis(d, &axis, &s)) {
    // ── THE SIX EXACT CASES, written as literals ──────────────────────────────
    // Each is a signed axis permutation with determinant +1 (a permutation of
    // odd parity is paired with an odd number of sign flips). They are spelled
    // out rather than derived so there is no arithmetic between "which axis" and
    // "which rotation" that could drift; the determinant of every one is
    // asserted by the test suite (bar V5), not assumed here.
    r.axis_permutation = true;
    if (axis == 2 && s > 0.0) {                    // +z: already up
      r.perm = {{0, 1, 2}};
      r.sign = {{1.0, 1.0, 1.0}};
      r.identity = true;
    } else if (axis == 2) {                        // -z: 180 deg about +x
      r.perm = {{0, 1, 2}};
      r.sign = {{1.0, -1.0, -1.0}};
      r.identity = false;
    } else if (axis == 0 && s > 0.0) {             // +x -> +z
      r.perm = {{2, 1, 0}};
      r.sign = {{-1.0, 1.0, 1.0}};
      r.identity = false;
    } else if (axis == 0) {                        // -x -> +z
      r.perm = {{2, 1, 0}};
      r.sign = {{1.0, 1.0, -1.0}};
      r.identity = false;
    } else if (axis == 1 && s > 0.0) {             // +y -> +z
      r.perm = {{0, 2, 1}};
      r.sign = {{1.0, -1.0, 1.0}};
      r.identity = false;
    } else {                                       // -y -> +z
      r.perm = {{0, 2, 1}};
      r.sign = {{1.0, 1.0, -1.0}};
      r.identity = false;
    }
    matrix_from_permutation(&r);
    return r;
  }

  // ── THE GENERAL CASE: the MINIMAL-ANGLE rotation d -> +z (Rodrigues) ────────
  // R = I + [v]x + [v]x^2 / (1 + c), with v = d x zhat and c = d . zhat. Proper
  // (det +1) for any unit d, and deterministic — no tie-break, no search. It is
  // LOSSY: every exported coordinate becomes a rounded sum of products, which is
  // why `axis_permutation` is false and the caller reports the deviation instead
  // of claiming exactness.
  r.axis_permutation = false;
  r.identity = false;
  const double c = d.z;
  if (1.0 + c <= 1e-12) {
    // d is (numerically) -z but did not pass the exact test. The cross product
    // is degenerate, so the axis is CHOSEN explicitly (180 deg about +x) rather
    // than left to a tie-break that could differ between builds.
    r.m = {{1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, -1.0}};
    return r;
  }
  const double k = 1.0 / (1.0 + c);
  // [v]x for v = d x zhat = (d.y, -d.x, 0).
  const std::array<double, 9> V{{0.0, 0.0, -d.x,
                                 0.0, 0.0, -d.y,
                                 d.x, d.y, 0.0}};
  // V^2.
  std::array<double, 9> V2{};
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) {
      double acc = 0.0;
      for (int t = 0; t < 3; ++t)
        acc += V[static_cast<std::size_t>(3 * i + t)] *
               V[static_cast<std::size_t>(3 * t + j)];
      V2[static_cast<std::size_t>(3 * i + j)] = acc;
    }
  for (int i = 0; i < 9; ++i)
    r.m[static_cast<std::size_t>(i)] =
        (i % 4 == 0 ? 1.0 : 0.0) + V[static_cast<std::size_t>(i)] +
        k * V2[static_cast<std::size_t>(i)];
  return r;
}

Vec3 to_build_frame(const BuildFrameRotation& r, const Vec3& v) {
  if (r.axis_permutation) {
    // EXACT: a permutation and a multiplication by +-1. No sums, so no rounding
    // and no signed-zero cancellation. This is what bar V4 rests on.
    const double c[3] = {v.x, v.y, v.z};
    return Vec3{r.sign[0] * c[r.perm[0]], r.sign[1] * c[r.perm[1]],
                r.sign[2] * c[r.perm[2]]};
  }
  return Vec3{r.m[0] * v.x + r.m[1] * v.y + r.m[2] * v.z,
              r.m[3] * v.x + r.m[4] * v.y + r.m[5] * v.z,
              r.m[6] * v.x + r.m[7] * v.y + r.m[8] * v.z};
}

Vec3 to_model_frame(const BuildFrameRotation& r, const Vec3& v) {
  if (r.axis_permutation) {
    // The inverse of a signed permutation is its transpose, and is equally
    // exact: component perm[i] of the result is sign[i] * component i of `v`.
    const double c[3] = {v.x, v.y, v.z};
    double out[3] = {0.0, 0.0, 0.0};
    for (int i = 0; i < 3; ++i)
      out[r.perm[static_cast<std::size_t>(i)]] =
          r.sign[static_cast<std::size_t>(i)] * c[i];
    return Vec3{out[0], out[1], out[2]};
  }
  return Vec3{r.m[0] * v.x + r.m[3] * v.y + r.m[6] * v.z,
              r.m[1] * v.x + r.m[4] * v.y + r.m[7] * v.z,
              r.m[2] * v.x + r.m[5] * v.y + r.m[8] * v.z};
}

double rotation_determinant(const BuildFrameRotation& r) {
  return r.m[0] * (r.m[4] * r.m[8] - r.m[5] * r.m[7]) -
         r.m[1] * (r.m[3] * r.m[8] - r.m[5] * r.m[6]) +
         r.m[2] * (r.m[3] * r.m[7] - r.m[4] * r.m[6]);
}

TriangleMesh rotate_mesh(const TriangleMesh& mesh, const BuildFrameRotation& r) {
  TriangleMesh out;
  out.vertices.reserve(mesh.vertices.size());
  for (const Vec3& v : mesh.vertices) out.vertices.push_back(to_build_frame(r, v));
  // Triangle indices are copied VERBATIM: the winding is the vertex ORDER, and a
  // determinant-+1 rotation maps an outward normal to an outward normal, so the
  // surface stays outward-facing without touching the index array. (A reflection
  // would not, which is why this header never produces one.)
  out.triangles = mesh.triangles;
  return out;
}

}  // namespace topopt
