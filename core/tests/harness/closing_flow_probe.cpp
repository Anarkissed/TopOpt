// closing_flow_probe — S1 of task 2026-08-08-closing-flow-and-the-field.
//
// ── WHY THIS IS NOT A FOURTH ATTEMPT AT THE SAME THING ───────────────────────
//
// Three NO-GOs precede this one and ALL THREE ARE FILTERS — operators that
// redistribute existing material with no reference to smooth toward:
//
//   PR 299  constrained Taubin        5.5% of the stair-step amplitude removed
//   PR 303  SDF / RBF extraction      21.5% against Taubin-best 23.4%
//   PR 314  mean-curvature flow       ROUGHER on his part at every setting
//
// PR 314 established WHY: on the optimizer-cut population there is no reference
// to smooth toward. The CAD does not describe that surface, and a finer
// extraction of the same field moves it by ~1/40th of the staircase's own
// amplitude, so the finer extraction is not a reference either.
//
// A morphological CLOSING is a different operation, not a fourth filter. It ADDS
// material: the closing of a solid S by a ball of radius r is
//
//     S • B_r = (S ⊕ B_r) ⊖ B_r
//
// — everything a ball of radius r rolling on the OUTSIDE cannot reach is filled
// in. It has a reference (the ball), it is monotone (S ⊆ S • B_r, so material is
// only ever added), and its fixed point is characterised by a curvature bound
// rather than by a pass-band.
//
// ── THE OPERATOR, AND WHERE IT COMES FROM ────────────────────────────────────
//
// Sellán, Kesten, Ang Yan Sheng & Jacobson, "Opening and Closing Surfaces",
// SIGGRAPH Asia 2020, ACM TOG 39(6) Art. 198. Their closing flow is minimum-
// curvature flow with a CURVATURE-BASED OBSTACLE, and the paper is explicit that
// the obstacle is the whole point:
//
//   "Minimum curvature flow, upon which our closing flow is based, moves
//    everything and may shrink the shape in some regions. Our use of a
//    curvature-based obstacle ensures OUTWARD flow toward the closing. Other
//    flows such as Willmore or classic mean curvature do not behave like a
//    closing."
//
// That sentence names PR 314's operator as the wrong tool, which is why this is
// worth one more measurement rather than a fourth repetition.
//
// THE ACTIVE SET IS THE OBSTACLE. A vertex moves only where its MINIMUM
// principal curvature is more negative than −1/r — that is exactly "a ball of
// radius r does not fit in this crevice". Everywhere else the vertex is left
// alone, bit for bit. The flow terminates when the active set empties, and the
// surface is then r-closed.
//
// ── WHAT IS REPRODUCED FROM THE REFERENCE, AND WHAT IS NOT ───────────────────
//
// The reference implementations are MATLAB + gptoolbox mex
// (github.com/sgsellan/opening-and-closing-surfaces, MIT) and a Python
// reimplementation (github.com/kentechx/closing_flow). NEITHER IS ADDED TO THE
// BUILD — the brief forbids adding MATLAB, gptoolbox or a Python runtime without
// the maintainer's decision, and this is a measurement. What is reproduced here,
// from the reference's own source:
//
//   REPRODUCED
//     * κ_min from the discrete curvatures: κ = H/A ± sqrt((H/A)² − K/A), with H
//       the integrated mean curvature (¼ Σ_e |e| β_e over incident edges, β the
//       signed exterior dihedral angle) and K the angle deficit 2π − Σθ. This is
//       `discrete_mean_curvature.m` / `discrete_gaussian_curvature.m` verbatim in
//       structure, and it is the same Meyer et al. 2003 formulation core's own
//       `mean_curvature_normals` already uses for H.
//     * the active-set predicate `is_active = lambda k: k < -bd`, bd = 1/r.
//     * outward-only motion, and the active set recomputed every iteration so a
//       vertex STOPS the moment its crevice admits the ball.
//     * termination on an empty active set.
//
//   NOT REPRODUCED, and stated rather than hidden
//     * the IMPLICIT solve. The reference takes a backward-Euler step of a
//       Dirichlet energy on positions projected onto the minimum-curvature
//       direction field; this probe takes the EXPLICIT step along the vertex
//       normal, magnitude dt·(−κ_min), with dt = dt_scale·h̄² so the operator is
//       scale-free in exactly the sense core's own MeanCurvatureParams::dt_scale
//       is. Explicit and implicit differ in step size and in how much the moving
//       vertices couple, not in the fixed point.
//     * REMESHING. The reference calls `remesh_botsch` every iteration so the
//       filled crevice has triangles to be represented on. This probe does not
//       remesh, because remeshing destroys the vertex correspondence three of the
//       four required readings are defined on: C4's bitwise CAD identity, the
//       per-vertex signed outward displacement, and a comparable per-vertex
//       motion column. Triangle quality is therefore MEASURED and reported
//       (`worst_aspect` before/after, and the degenerate-triangle count before/
//       after) rather than assumed, and the handoff's §S1.2 says plainly what a
//       remeshing implementation could and could not change.
//
// ── HOW IT IS SCORED ─────────────────────────────────────────────────────────
//
// PR 314's metric, unchanged, so the rows land in its table:
//   * `dihedral_rms_deg` on the whole mesh — the roughness column of §S2.2.
//   * `deviation_from_cad` restricted to the CAD population — the only surface on
//     his part where "how much stair-step amplitude was removed" has a truthful
//     answer (§S2.3).
//   * `min_slice_section_of` — PR 306's slice-area instrument, via the shared
//     header, so the tendril column is literally the same code.
// Both metric headers are INCLUDED, not retyped.
//
//   cmake --build core/build --target closing_flow_probe
//   ./core/build/closing_flow_probe <design.bin> <part.step> [evidence_dir]

#include "topopt/cad_project.hpp"
#include "topopt/design_store.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/mesh.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/surface_operator.hpp"
#include "topopt/voxel.hpp"

#include "stairstep_metric.hpp"
#include "surface_instruments.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

using namespace topopt;
using namespace topopt::stairstep;
using namespace topopt::surface_instruments;

namespace {

// The shipped export, reproduced exactly as PR 314's probe reproduces it, so the
// subject is the same object its rows describe.
constexpr int kShippedFactor = 2;

// PLA, core/src/materials/materials.json. The job that produced these rungs
// (evidence/2026-08-03-multiscale-lattice-to/job_multiscale.json) declares
// "material": "PLA". Grams are the price the maintainer pays for the material a
// closing adds, so they are reported and not left as mm³.
constexpr double kPlaDensityGPerCm3 = 1.24;

TriangleMesh extract(const VoxelGrid& g, const std::vector<double>& rho,
                     int factor) {
  return keep_largest_component(marching_cubes_resampled(
      g.nx, g.ny, g.nz, g.spacing, g.origin, rho, 0.5, factor,
      ResampleInterp::Tricubic));
}

struct Population {
  std::vector<char> cad;
  std::vector<char> cut;
  std::size_t n_cad = 0, n_cut = 0, n_ambiguous = 0;
};

Population split(const CadAttribution& att, std::size_t nverts) {
  Population p;
  p.cad.assign(nverts, 0);
  p.cut.assign(nverts, 0);
  for (std::size_t v = 0; v < nverts; ++v) {
    if (att.face_of_vertex[v] >= 0) { p.cad[v] = 1; ++p.n_cad; }
    else if (att.ambiguous_at(v))   { ++p.n_ambiguous; }
    else                            { p.cut[v] = 1; ++p.n_cut; }
  }
  return p;
}

// ─────────────────────────────────────────────────────────────────────────────
// THE DISCRETE CURVATURES
// ─────────────────────────────────────────────────────────────────────────────
//
// SIGN CONVENTION, stated because everything downstream depends on it: with the
// outward normal, a CONVEX body (a sphere) has positive mean and positive
// Gaussian curvature, and a CREVICE has κ_min very negative. So "κ_min < −1/r"
// reads "a valley too tight for the ball", which is the set a closing fills.
//
// Verified on an analytic sphere in main() before any rung is measured: a sphere
// of radius R must read κ_min = κ_max = +1/R. That positive control is the only
// thing standing between a sign error and four pages of confident nonsense.
struct Curvatures {
  std::vector<double> kappa_min;   // 1/mm
  std::vector<double> kappa_max;   // 1/mm
  std::vector<double> area_mixed;  // mm^2
};

Curvatures discrete_curvatures(const TriangleMesh& m) {
  const std::size_t nv = m.vertices.size();
  Curvatures c;
  c.kappa_min.assign(nv, 0.0);
  c.kappa_max.assign(nv, 0.0);
  c.area_mixed.assign(nv, 0.0);
  if (m.triangles.empty()) return c;

  auto sub = [](const Vec3& a, const Vec3& b) {
    return Vec3{a.x - b.x, a.y - b.y, a.z - b.z};
  };
  auto dot = [](const Vec3& a, const Vec3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
  };
  auto cross = [](const Vec3& a, const Vec3& b) {
    return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
                a.x * b.y - a.y * b.x};
  };
  auto len = [&](const Vec3& a) { return std::sqrt(dot(a, a)); };

  // Face normals and areas.
  const std::size_t nt = m.triangles.size();
  std::vector<Vec3> fn(nt);
  std::vector<double> fa(nt, 0.0);
  std::vector<Vec3> fc(nt);
  for (std::size_t t = 0; t < nt; ++t) {
    const auto& tr = m.triangles[t];
    const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tr[1])];
    const Vec3& d = m.vertices[static_cast<std::size_t>(tr[2])];
    const Vec3 n = cross(sub(b, a), sub(d, a));
    const double L = len(n);
    fa[t] = 0.5 * L;
    fn[t] = L > 0.0 ? Vec3{n.x / L, n.y / L, n.z / L} : Vec3{0.0, 0.0, 0.0};
    fc[t] = Vec3{(a.x + b.x + d.x) / 3.0, (a.y + b.y + d.y) / 3.0,
                 (a.z + b.z + d.z) / 3.0};
  }

  // (1) Barycentric mass: one third of each incident face's area. igl's default
  // massmatrix is the mixed Voronoi area; the barycentric lumping agrees with it
  // exactly on a well-shaped triangulation and is bounded on a degenerate one,
  // where the Voronoi form is not. Both integrate to the same total area, which
  // is what makes κ = H/A dimensionally right either way.
  for (std::size_t t = 0; t < nt; ++t)
    for (int k = 0; k < 3; ++k)
      c.area_mixed[static_cast<std::size_t>(m.triangles[t][k])] += fa[t] / 3.0;

  // (2) Gaussian curvature: the angle deficit 2π − Σθ, integrated.
  std::vector<double> K(nv, 2.0 * M_PI);
  for (std::size_t t = 0; t < nt; ++t) {
    const auto& tr = m.triangles[t];
    for (int k = 0; k < 3; ++k) {
      const Vec3& p = m.vertices[static_cast<std::size_t>(tr[k])];
      const Vec3& q = m.vertices[static_cast<std::size_t>(tr[(k + 1) % 3])];
      const Vec3& s = m.vertices[static_cast<std::size_t>(tr[(k + 2) % 3])];
      const Vec3 u = sub(q, p), w = sub(s, p);
      const double lu = len(u), lw = len(w);
      if (lu <= 0.0 || lw <= 0.0) continue;
      double cs = dot(u, w) / (lu * lw);
      cs = std::fmax(-1.0, std::fmin(1.0, cs));
      K[static_cast<std::size_t>(tr[k])] -= std::acos(cs);
    }
  }

  // (3) Mean curvature, the Cohen-Steiner & Morvan edge form:
  //
  //     H_int(v) = ¼ Σ_{e ∋ v} |e| β_e
  //
  // with β_e the SIGNED exterior dihedral angle — β > 0 on a ridge, β < 0 in a
  // valley. The sign is decided by whether the neighbouring face's centroid lies
  // in front of or behind this face's plane, the same convexity test the
  // reference's `dihedral_angles` uses.
  //
  // ★ THE COEFFICIENT IS ¼ PER ENDPOINT, NOT ⅛, and the sphere control below is
  // what settled it. Summing the per-vertex form over all vertices counts every
  // edge twice, so Σ_v H_int(v) = ½ Σ_e |e| β_e, which is Cohen-Steiner &
  // Morvan's estimate of ∫H dA. On a sphere that must come to 4πR, and with ⅛ it
  // comes to 2πR — the factor of two the control caught. The Python
  // reimplementation's 0.5*0.5*0.5 pairs with a different mass convention
  // downstream; copying its constant into this mass convention is exactly the
  // "agrees in spirit" error the shared-header rule exists to prevent.
  std::map<std::pair<int, int>, std::array<int, 2>> edge_faces;
  for (std::size_t t = 0; t < nt; ++t) {
    const auto& tr = m.triangles[t];
    for (int e = 0; e < 3; ++e) {
      int a = tr[e], b = tr[(e + 1) % 3];
      if (a > b) std::swap(a, b);
      auto it = edge_faces.find({a, b});
      if (it == edge_faces.end()) edge_faces[{a, b}] = {static_cast<int>(t), -1};
      else if (it->second[1] < 0) it->second[1] = static_cast<int>(t);
    }
  }
  std::vector<double> H(nv, 0.0);
  for (const auto& kv : edge_faces) {
    if (kv.second[1] < 0) continue;  // a boundary edge carries no dihedral
    const std::size_t t0 = static_cast<std::size_t>(kv.second[0]);
    const std::size_t t1 = static_cast<std::size_t>(kv.second[1]);
    const Vec3& p = m.vertices[static_cast<std::size_t>(kv.first.first)];
    const Vec3& q = m.vertices[static_cast<std::size_t>(kv.first.second)];
    const double L = len(sub(q, p));
    if (!(L > 0.0)) continue;
    double cs = dot(fn[t0], fn[t1]);
    cs = std::fmax(-1.0, std::fmin(1.0, cs));
    double beta = std::acos(cs);  // unsigned exterior angle in [0, π]
    // Convex (ridge) when the neighbour's centroid sits BEHIND this face's
    // plane; concave (valley) when in front.
    if (dot(sub(fc[t1], fc[t0]), fn[t0]) > 0.0) beta = -beta;
    const double contrib = 0.25 * beta * L;
    H[static_cast<std::size_t>(kv.first.first)] += contrib;
    H[static_cast<std::size_t>(kv.first.second)] += contrib;
  }

  // (4) κ = H/A ± sqrt((H/A)² − K/A). The discriminant goes negative where the
  // discrete curvatures are inconsistent (it cannot on a smooth surface); the
  // reference takes the real part, which is the same as clamping it at 0.
  for (std::size_t v = 0; v < nv; ++v) {
    const double A = c.area_mixed[v];
    if (!(A > 0.0)) continue;
    const double km = H[v] / A;
    const double kg = K[v] / A;
    const double disc = std::fmax(0.0, km * km - kg);
    const double s = std::sqrt(disc);
    c.kappa_min[v] = km - s;
    c.kappa_max[v] = km + s;
  }
  return c;
}

// ─────────────────────────────────────────────────────────────────────────────
// THE CLOSING FLOW
// ─────────────────────────────────────────────────────────────────────────────
struct ClosingParams {
  double radius_mm = 1.0;   // the structuring element; the obstacle is −1/r
  int max_iterations = 40;
  double dt_scale = 0.125;  // dt = dt_scale * h̄², as core's MCF writes it
  double trust_mm = 0.0;    // C1 half-width; <= 0 disables (reported either way)
};

struct ClosingStats {
  int iterations = 0;
  std::size_t active_first = 0;   // |active set| on iteration 1
  std::size_t active_last = 0;    // |active set| when it stopped
  bool converged = false;         // the active set emptied
  std::size_t moved = 0;          // vertices that moved at least once
  std::size_t c4_frozen = 0;
  std::size_t c1_clamped = 0;      // the normal-direction bound bit
  std::size_t c1_box_clamped = 0;  // the axis-aligned cube bit

  // (c) THE OUTWARD PROPERTY, ASSERTED. Signed displacement along the vertex's
  // OWN OUTWARD NORMAL as it stood before the flow. Any negative value means the
  // obstacle is not holding.
  std::size_t inward_vertices = 0;
  double worst_inward_mm = 0.0;   // most negative signed displacement (>= 0 ok)
  double max_outward_mm = 0.0;

  // Triangle quality, because this implementation does not remesh.
  double worst_aspect_before = 0.0;
  double worst_aspect_after = 0.0;
  std::size_t degenerate_before = 0;
  std::size_t degenerate_after = 0;

  double wall_s = 0.0;
};

// Worst (largest) ratio of longest edge to the triangle's inradius-proxy; a
// stretched sliver reads large. Reported before and after so "no remeshing" is a
// measured cost rather than a caveat.
double worst_aspect_ratio(const TriangleMesh& m, std::size_t& degenerate) {
  degenerate = 0;
  double worst = 0.0;
  for (const auto& tr : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tr[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(tr[2])];
    const double e0 = std::hypot(std::hypot(b.x - a.x, b.y - a.y), b.z - a.z);
    const double e1 = std::hypot(std::hypot(c.x - b.x, c.y - b.y), c.z - b.z);
    const double e2 = std::hypot(std::hypot(a.x - c.x, a.y - c.y), a.z - c.z);
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
    const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
    const Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z,
                 u.x * v.y - u.y * v.x};
    const double area = 0.5 * std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (!(area > 0.0)) { ++degenerate; continue; }
    const double longest = std::fmax(e0, std::fmax(e1, e2));
    worst = std::fmax(worst, longest * longest / (4.0 * area));
  }
  return worst;
}

double mean_edge_length(const TriangleMesh& m) {
  double sum = 0.0;
  std::size_t n = 0;
  for (const auto& tr : m.triangles)
    for (int e = 0; e < 3; ++e) {
      const Vec3& a = m.vertices[static_cast<std::size_t>(tr[e])];
      const Vec3& b = m.vertices[static_cast<std::size_t>(tr[(e + 1) % 3])];
      sum += std::sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) +
                       (b.z - a.z) * (b.z - a.z));
      ++n;
    }
  return n ? sum / static_cast<double>(n) : 0.0;
}

// `frozen[v] != 0` ⇒ vertex v is C4-frozen: excluded from the active set and
// never written. The write is a BRANCH, never `p + 0*d`, so a frozen vertex
// stays byte-for-byte identical (0.0 * x flips the sign bit on a -0.0 coordinate
// and would defeat memcmp — PR 314's own note).
TriangleMesh closing_flow(const TriangleMesh& in, const ClosingParams& p,
                          const std::vector<char>& frozen, ClosingStats& st) {
  const Clock::time_point t0 = Clock::now();
  TriangleMesh m = in;
  const std::size_t nv = m.vertices.size();
  const double hbar = mean_edge_length(in);
  const double dt = p.dt_scale * hbar * hbar;
  const double obstacle = -1.0 / p.radius_mm;

  st.worst_aspect_before = worst_aspect_ratio(in, st.degenerate_before);
  for (std::size_t v = 0; v < nv; ++v)
    if (v < frozen.size() && frozen[v]) ++st.c4_frozen;

  // The outward normals as they stood BEFORE the flow — (c) is a statement about
  // the direction the surface faced when the operator was handed it.
  const std::vector<Vec3> n0 = vertex_normals(in);

  for (int iter = 0; iter < p.max_iterations; ++iter) {
    const Curvatures cv = discrete_curvatures(m);
    const std::vector<Vec3> nrm = vertex_normals(m);

    // THE OBSTACLE. Recomputed every iteration, so a vertex leaves the active
    // set the moment its crevice admits the ball — that is what makes the flow
    // stop at the closing instead of running on.
    std::size_t active = 0;
    std::vector<double> step(nv, 0.0);
    for (std::size_t v = 0; v < nv; ++v) {
      if (v < frozen.size() && frozen[v]) continue;
      if (!(cv.area_mixed[v] > 0.0)) continue;
      if (!(cv.kappa_min[v] < obstacle)) continue;  // the ball fits: leave it
      ++active;
      // Outward by construction: κ_min < −1/r < 0 ⇒ −κ_min > 1/r > 0.
      step[v] = dt * (-cv.kappa_min[v]);
    }
    if (iter == 0) st.active_first = active;
    st.active_last = active;
    if (active == 0) { st.converged = true; st.iterations = iter; break; }

    for (std::size_t v = 0; v < nv; ++v) {
      if (step[v] <= 0.0) continue;
      double d = step[v];
      const Vec3& o = in.vertices[v];
      if (p.trust_mm > 0.0) {
        // C1, measured against the ORIGINAL position, not the previous step.
        const Vec3& c = m.vertices[v];
        const double along = (c.x - o.x) * n0[v].x + (c.y - o.y) * n0[v].y +
                             (c.z - o.z) * n0[v].z;
        if (along + d > p.trust_mm) {
          d = std::fmax(0.0, p.trust_mm - along);
          ++st.c1_clamped;
        }
        if (d <= 0.0) continue;
      }
      Vec3 np{m.vertices[v].x + d * nrm[v].x, m.vertices[v].y + d * nrm[v].y,
              m.vertices[v].z + d * nrm[v].z};
      if (p.trust_mm > 0.0) {
        // ★ AND THE BOX, WHICH IS WHAT C1 MEANS IN THIS CODEBASE.
        // `SurfaceConstraints::trust_voxels` (surface_operator.hpp) defines C1 as
        // "the axis-aligned cube of half-width trust_voxels * cell_mm about the
        // vertex's ORIGINAL position". The normal-direction test above is weaker
        // than that: a vertex whose normal has flipped can accumulate TANGENTIAL
        // travel the projection never sees, and leave the cube while every
        // individual step passed. Both are applied, so C1 here means what C1
        // means everywhere else and the rows stay comparable.
        const double t = p.trust_mm;
        double cx = std::fmax(o.x - t, std::fmin(o.x + t, np.x));
        double cy = std::fmax(o.y - t, std::fmin(o.y + t, np.y));
        double cz = std::fmax(o.z - t, std::fmin(o.z + t, np.z));
        if (cx != np.x || cy != np.y || cz != np.z) ++st.c1_box_clamped;
        np = Vec3{cx, cy, cz};
      }
      m.vertices[v] = np;
    }
    st.iterations = iter + 1;
  }

  // (c) THE ASSERTION, not the assumption.
  for (std::size_t v = 0; v < nv; ++v) {
    const double dx = m.vertices[v].x - in.vertices[v].x;
    const double dy = m.vertices[v].y - in.vertices[v].y;
    const double dz = m.vertices[v].z - in.vertices[v].z;
    if (dx == 0.0 && dy == 0.0 && dz == 0.0) continue;
    ++st.moved;
    const double s = dx * n0[v].x + dy * n0[v].y + dz * n0[v].z;
    if (s < 0.0) {
      ++st.inward_vertices;
      st.worst_inward_mm = std::fmin(st.worst_inward_mm, s);
    }
    st.max_outward_mm = std::fmax(st.max_outward_mm, s);
  }
  std::size_t deg = 0;
  st.worst_aspect_after = worst_aspect_ratio(m, deg);
  st.degenerate_after = deg;
  st.wall_s = secs_since(t0);
  return m;
}

// ─────────────────────────────────────────────────────────────────────────────
// THE COUPLED VARIANT — much closer to what the reference actually solves
// ─────────────────────────────────────────────────────────────────────────────
//
// ★ WHY THERE IS A SECOND DISCRETIZATION, AND IT IS NOT A SECOND CHANCE.
//
// The explicit flow above diverges on his part: the active set GROWS with every
// iteration instead of emptying. The mechanism is not mysterious and it is a
// property of the discretization, not of the operator — an explicit per-vertex
// normal step moves ONE vertex out of a crevice, which manufactures a concave
// collar around it, which enters the active set on the next iteration. Nothing
// couples the moving vertices, so a fill becomes a spike.
//
// The reference does not do that. It takes a BACKWARD-EULER step in which the
// active vertices are the unknowns and everything outside the active set is a
// Dirichlet boundary, so the crevice is filled toward the surrounding geometry
// and, by the maximum principle, cannot overshoot past it. Declaring a NO-GO on
// a reimplementation that diverges where the reference does not would be a
// statement about this file, so the coupled form is measured too.
//
// It is a Jacobi sweep of the same constrained system — x_v <- mean of the
// one-ring for the active v, inactive vertices held — with two additions this
// application needs and the reference gets from elsewhere:
//   * OUTWARD-ONLY. The Laplacian step is projected onto the vertex's outward
//     normal and the inward half discarded, so the operator remains a closing
//     rather than a fairing. (c) is then a claim about the projection, and it is
//     still measured rather than assumed.
//   * C1, the same half-cell trust region, about the ORIGINAL position.
TriangleMesh closing_flow_coupled(const TriangleMesh& in, const ClosingParams& p,
                                  const std::vector<char>& frozen,
                                  ClosingStats& st) {
  const Clock::time_point t0 = Clock::now();
  TriangleMesh m = in;
  const std::size_t nv = in.vertices.size();
  const double obstacle = -1.0 / p.radius_mm;

  st.worst_aspect_before = worst_aspect_ratio(in, st.degenerate_before);
  for (std::size_t v = 0; v < nv; ++v)
    if (v < frozen.size() && frozen[v]) ++st.c4_frozen;
  const std::vector<Vec3> n0 = vertex_normals(in);

  std::vector<std::vector<int>> ring(nv);
  for (const auto& tr : in.triangles)
    for (int e = 0; e < 3; ++e) {
      ring[static_cast<std::size_t>(tr[e])].push_back(tr[(e + 1) % 3]);
      ring[static_cast<std::size_t>(tr[(e + 1) % 3])].push_back(tr[e]);
    }
  for (auto& rr : ring) {
    std::sort(rr.begin(), rr.end());
    rr.erase(std::unique(rr.begin(), rr.end()), rr.end());
  }

  for (int iter = 0; iter < p.max_iterations; ++iter) {
    const Curvatures cv = discrete_curvatures(m);
    const std::vector<Vec3> nrm = vertex_normals(m);
    std::vector<char> active(nv, 0);
    std::size_t nact = 0;
    for (std::size_t v = 0; v < nv; ++v) {
      if (v < frozen.size() && frozen[v]) continue;
      if (!(cv.area_mixed[v] > 0.0)) continue;
      if (!(cv.kappa_min[v] < obstacle)) continue;
      active[v] = 1;
      ++nact;
    }
    if (iter == 0) st.active_first = nact;
    st.active_last = nact;
    if (nact == 0) { st.converged = true; st.iterations = iter; break; }

    std::vector<Vec3> next = m.vertices;
    for (std::size_t v = 0; v < nv; ++v) {
      if (!active[v] || ring[v].empty()) continue;
      Vec3 c{0, 0, 0};
      for (const int u : ring[v]) {
        c.x += m.vertices[static_cast<std::size_t>(u)].x;
        c.y += m.vertices[static_cast<std::size_t>(u)].y;
        c.z += m.vertices[static_cast<std::size_t>(u)].z;
      }
      const double k = 1.0 / static_cast<double>(ring[v].size());
      Vec3 delta{c.x * k - m.vertices[v].x, c.y * k - m.vertices[v].y,
                 c.z * k - m.vertices[v].z};
      // OUTWARD-ONLY: keep the component along the current outward normal and
      // discard it entirely when it points inward.
      const double along = delta.x * nrm[v].x + delta.y * nrm[v].y +
                           delta.z * nrm[v].z;
      if (!(along > 0.0)) continue;
      double d = along;
      if (p.trust_mm > 0.0) {
        const Vec3& o = in.vertices[v];
        const Vec3& cur = m.vertices[v];
        const double sofar = (cur.x - o.x) * n0[v].x + (cur.y - o.y) * n0[v].y +
                             (cur.z - o.z) * n0[v].z;
        if (sofar + d > p.trust_mm) {
          d = std::fmax(0.0, p.trust_mm - sofar);
          ++st.c1_clamped;
        }
        if (d <= 0.0) continue;
      }
      Vec3 np{m.vertices[v].x + d * nrm[v].x, m.vertices[v].y + d * nrm[v].y,
              m.vertices[v].z + d * nrm[v].z};
      if (p.trust_mm > 0.0) {
        // C1's BOX, as in the explicit arm above and as surface_operator.hpp
        // defines it.
        const Vec3& o = in.vertices[v];
        const double t = p.trust_mm;
        const double cx = std::fmax(o.x - t, std::fmin(o.x + t, np.x));
        const double cy = std::fmax(o.y - t, std::fmin(o.y + t, np.y));
        const double cz = std::fmax(o.z - t, std::fmin(o.z + t, np.z));
        if (cx != np.x || cy != np.y || cz != np.z) ++st.c1_box_clamped;
        np = Vec3{cx, cy, cz};
      }
      next[v] = np;
    }
    for (std::size_t v = 0; v < nv; ++v)
      if (!(v < frozen.size() && frozen[v])) m.vertices[v] = next[v];
    st.iterations = iter + 1;
  }

  for (std::size_t v = 0; v < nv; ++v) {
    const double dx = m.vertices[v].x - in.vertices[v].x;
    const double dy = m.vertices[v].y - in.vertices[v].y;
    const double dz = m.vertices[v].z - in.vertices[v].z;
    if (dx == 0.0 && dy == 0.0 && dz == 0.0) continue;
    ++st.moved;
    const double s = dx * n0[v].x + dy * n0[v].y + dz * n0[v].z;
    if (s < 0.0) {
      ++st.inward_vertices;
      st.worst_inward_mm = std::fmin(st.worst_inward_mm, s);
    }
    st.max_outward_mm = std::fmax(st.max_outward_mm, s);
  }
  std::size_t deg = 0;
  st.worst_aspect_after = worst_aspect_ratio(m, deg);
  st.degenerate_after = deg;
  st.wall_s = secs_since(t0);
  return m;
}

std::size_t cad_vertices_that_moved(const TriangleMesh& a, const TriangleMesh& b,
                                    const std::vector<char>& cad) {
  std::size_t bad = 0;
  const std::size_t lim = std::min(a.vertices.size(), b.vertices.size());
  for (std::size_t v = 0; v < lim; ++v) {
    if (!cad[v]) continue;
    if (std::memcmp(&a.vertices[v], &b.vertices[v], sizeof(Vec3)) != 0) ++bad;
  }
  return bad;
}

struct Motion {
  double max_mm = 0.0, rms_mm = 0.0;
  std::size_t moved = 0;
};

Motion motion(const TriangleMesh& a, const TriangleMesh& b,
              const std::vector<char>& only) {
  Motion m;
  double s2 = 0.0;
  std::size_t n = 0;
  const std::size_t lim = std::min(a.vertices.size(), b.vertices.size());
  for (std::size_t v = 0; v < lim; ++v) {
    if (!only.empty() && !only[v]) continue;
    const double dx = b.vertices[v].x - a.vertices[v].x;
    const double dy = b.vertices[v].y - a.vertices[v].y;
    const double dz = b.vertices[v].z - a.vertices[v].z;
    const double d = std::sqrt(dx * dx + dy * dy + dz * dz);
    if (d > 0.0) ++m.moved;
    if (d > m.max_mm) m.max_mm = d;
    s2 += d * d;
    ++n;
  }
  if (n) m.rms_mm = std::sqrt(s2 / static_cast<double>(n));
  return m;
}

// THE POSITIVE CONTROL FOR THE CURVATURE SIGN. An analytic sphere of radius R,
// tessellated by subdividing an octahedron, must read κ_min = κ_max = +1/R. If
// this is wrong the active-set predicate selects ridges instead of valleys and
// every number below is the opposite of what it claims to be.
TriangleMesh sphere_mesh(double R, int subdiv) {
  TriangleMesh m;
  m.vertices = {{R, 0, 0}, {-R, 0, 0}, {0, R, 0}, {0, -R, 0}, {0, 0, R}, {0, 0, -R}};
  m.triangles = {{0, 2, 4}, {2, 1, 4}, {1, 3, 4}, {3, 0, 4},
                 {2, 0, 5}, {1, 2, 5}, {3, 1, 5}, {0, 3, 5}};
  for (int s = 0; s < subdiv; ++s) {
    std::map<std::pair<int, int>, int> mid;
    std::vector<std::array<int, 3>> out;
    auto midpoint = [&](int a, int b) {
      auto key = std::minmax(a, b);
      auto it = mid.find({key.first, key.second});
      if (it != mid.end()) return it->second;
      const Vec3& p = m.vertices[static_cast<std::size_t>(a)];
      const Vec3& q = m.vertices[static_cast<std::size_t>(b)];
      Vec3 c{0.5 * (p.x + q.x), 0.5 * (p.y + q.y), 0.5 * (p.z + q.z)};
      const double L = std::sqrt(c.x * c.x + c.y * c.y + c.z * c.z);
      c = Vec3{c.x * R / L, c.y * R / L, c.z * R / L};
      const int id = static_cast<int>(m.vertices.size());
      m.vertices.push_back(c);
      mid[{key.first, key.second}] = id;
      return id;
    };
    for (const auto& t : m.triangles) {
      const int a = midpoint(t[0], t[1]);
      const int b = midpoint(t[1], t[2]);
      const int c = midpoint(t[2], t[0]);
      out.push_back({t[0], a, c});
      out.push_back({a, t[1], b});
      out.push_back({c, b, t[2]});
      out.push_back({a, b, c});
    }
    m.triangles = out;
  }
  return m;
}

}  // namespace


int main(int argc, char** argv) {
  if (argc < 3) {
    std::printf("usage: closing_flow_probe <design.bin> <part.step> [evidence_dir]\n");
    return 2;
  }
  const std::string design_path = argv[1];
  const std::string step_path = argv[2];
  const std::string ev = argc > 3 ? argv[3] : ".";

  std::printf("== closing_flow_probe — S1 of closing-flow-and-the-field ==\n\n");

  // ── THE POSITIVE CONTROL, FIRST ────────────────────────────────────────────
  {
    std::printf("-- S1.0 SIGN CONTROL: an analytic sphere must read +1/R -------------\n");
    // READ AREA-WEIGHTED, NOT AS A MIN AND A MAX OVER VERTICES. An
    // octahedron-subdivision sphere has strongly non-uniform triangles, so the
    // extreme vertex is a statement about the worst-shaped corner of the
    // tessellation and not about the operator. The AREA-WEIGHTED means are the
    // two quantities the continuous identities pin exactly — Cohen-Steiner &
    // Morvan for ∫H dA = 4πR and Gauss-Bonnet for ∫K dA = 4π — so those are what
    // is asserted, with the spread printed beside them so a wide distribution
    // cannot hide inside a correct mean.
    bool ok = true;
    for (const double R : {5.0, 20.0}) {
      const TriangleMesh s = sphere_mesh(R, 4);
      const Curvatures c = discrete_curvatures(s);
      double area = 0.0, wmean = 0.0, wgauss = 0.0, wmin = 0.0, wmax = 0.0;
      std::vector<double> mins;
      mins.reserve(s.vertices.size());
      for (std::size_t v = 0; v < s.vertices.size(); ++v) {
        const double a = c.area_mixed[v];
        if (!(a > 0.0)) continue;
        area += a;
        wmean += a * 0.5 * (c.kappa_min[v] + c.kappa_max[v]);
        wgauss += a * c.kappa_min[v] * c.kappa_max[v];
        wmin += a * c.kappa_min[v];
        wmax += a * c.kappa_max[v];
        mins.push_back(c.kappa_min[v]);
      }
      wmean /= area; wgauss /= area; wmin /= area; wmax /= area;
      std::sort(mins.begin(), mins.end());
      const double want = 1.0 / R;
      const double err = std::fmax(std::fabs(wmin - want), std::fabs(wmax - want)) / want;
      std::printf("  R = %5.1f mm  expect kappa %+8.5f, K %+9.6f, area %9.2f mm2\n",
                  R, want, want * want, 4.0 * M_PI * R * R);
      std::printf("       area-weighted: kappa_mean %+8.5f  K %+9.6f  kmin %+8.5f"
                  "  kmax %+8.5f   area %9.2f mm2\n",
                  wmean, wgauss, wmin, wmax, area);
      std::printf("       kappa_min spread p10 %+8.5f  median %+8.5f  p90 %+8.5f\n",
                  mins[mins.size() / 10], mins[mins.size() / 2],
                  mins[9 * mins.size() / 10]);
      std::printf("       rel err on the area-weighted principals: %.2f%%  %s\n",
                  100.0 * err, err < 0.05 ? "OK" : "FAIL");
      if (!(err < 0.05)) ok = false;
      // And the obstacle must select NOTHING on a convex body, at any radius.
      std::size_t sel = 0;
      for (std::size_t v = 0; v < s.vertices.size(); ++v)
        if (c.kappa_min[v] < -1.0 / 1.0) ++sel;
      std::printf("                 obstacle (-1/1mm) selects %zu of %zu vertices"
                  "   %s (a convex body has nothing to close)\n",
                  sel, s.vertices.size(), sel == 0 ? "OK" : "FAIL");
      if (sel != 0) ok = false;
    }
    // A NEGATIVE control: a crevice must be selected. Two spheres' worth of
    // curvature is not enough on its own — an operator that selects nothing
    // everywhere would pass the test above vacuously.
    {
      // A wedge: two half-planes meeting at a concave 90-degree seam.
      TriangleMesh w;
      const int N = 12;
      const double L = 10.0;
      for (int i = 0; i <= N; ++i)
        for (int j = 0; j <= N; ++j) {
          const double u = L * i / N, t = L * j / N;
          w.vertices.push_back(Vec3{u, t, 0.0});           // floor
        }
      for (int i = 0; i <= N; ++i)
        for (int j = 1; j <= N; ++j) {
          const double u = L * i / N, t = L * j / N;
          w.vertices.push_back(Vec3{u, 0.0, t});           // wall
        }
      auto fid = [&](int i, int j) { return i * (N + 1) + j; };
      auto wid = [&](int i, int j) {
        return (N + 1) * (N + 1) + i * N + (j - 1);
      };
      for (int i = 0; i < N; ++i)
        for (int j = 0; j < N; ++j) {
          w.triangles.push_back({fid(i, j), fid(i + 1, j), fid(i + 1, j + 1)});
          w.triangles.push_back({fid(i, j), fid(i + 1, j + 1), fid(i, j + 1)});
        }
      for (int i = 0; i < N; ++i)
        for (int j = 1; j < N; ++j) {
          const int a = (j == 1) ? fid(i, 0) : wid(i, j);
          const int b = (j == 1) ? fid(i + 1, 0) : wid(i + 1, j);
          w.triangles.push_back({a, b, wid(i + 1, j + 1)});
          w.triangles.push_back({a, wid(i + 1, j + 1), wid(i, j + 1)});
        }
      const Curvatures c = discrete_curvatures(w);
      std::size_t seam_sel = 0, seam_total = 0;
      for (int i = 0; i <= N; ++i) {
        const std::size_t v = static_cast<std::size_t>(fid(i, 0));
        ++seam_total;
        if (c.kappa_min[v] < -1.0 / 5.0) ++seam_sel;
      }
      std::printf("  concave 90-degree seam: obstacle (-1/5mm) selects %zu of %zu seam"
                  " vertices   %s\n", seam_sel, seam_total,
                  seam_sel > 0 ? "OK (a crevice IS selected)"
                               : "FAIL (nothing is ever selected)");
      if (seam_sel == 0) ok = false;
    }
    std::printf("  %s\n\n", ok ? "SIGN CONTROL PASSES — the obstacle selects valleys, not ridges."
                               : "★ SIGN CONTROL FAILED — every number below is suspect.");
    if (!ok) return 3;
  }

  DesignStore store = read_design_file(design_path);
  VoxelGrid grid;
  grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
  grid.spacing = store.spacing; grid.origin = store.origin;
  grid.tags.assign(store.voxel_count(), VoxelTag::Empty);

  std::printf("design   %s\n", design_path.c_str());
  std::printf("part     %s\n", step_path.c_str());
  std::printf("grid     %d x %d x %d, spacing %.6f mm\n", grid.nx, grid.ny,
              grid.nz, grid.spacing);
  const double cell_mm = grid.spacing / kShippedFactor;
  std::printf("export   factor %d (tricubic) => cell %.6f mm, C1 half-cell %.6f mm\n",
              kShippedFactor, cell_mm, 0.5 * cell_mm);
  std::printf("material PLA, %.2f g/cm3\n", kPlaDensityGPerCm3);
  std::printf("rungs    %zu\n\n", store.variants.size());

  const StepModel model = import_part_file_resolved(step_path);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the STEP imported empty — OCCT is required for this probe\n");
    return 2;
  }
  std::printf("CAD      %zu faces over %zu tessellation triangles\n\n",
              model.faces.size(), model.mesh.triangles.size());

  const CadProjectOptions copts = cad_project_options_for_grid(grid.spacing);

  // The radii swept. The obstacle is −1/r, so r is the size of crevice the
  // closing is allowed to bridge. Chosen against the staircase's own geometry:
  // the export cell is 0.8526 mm and PR 299 measured the stair-step amplitude at
  // rms 0.3424 mm, so a groove of half-width ~0.43 mm and depth ~0.34 mm needs
  // r >= (w^2+d^2)/(2d) ~ 0.44 mm to be bridged at all. 0.5 mm is therefore the
  // smallest radius that can do anything, and 3.41 mm is two whole voxels.
  const double radii[] = {0.5, 1.0, 1.705279, 3.410558};

  std::ofstream csv(ev + "/s1_closing_flow.csv");
  csv << "rung,operator,iterations,wall_s,cut_max_mm,cut_rms_mm,cut_moved,"
         "cad_moved_bitwise,dihedral_before,dihedral_after,vol_before_mm3,"
         "vol_after_mm3,vol_drift_pct,mass_added_g,cad_dev_rms_before,"
         "cad_dev_rms_after,cad_removed_pct,active_first,active_last,converged,"
         "inward_vertices,worst_inward_mm,max_outward_mm,c1_clamped,"
         "min_section_mm2,min_section_fine_mm2,worst_aspect_before,"
         "worst_aspect_after\n";

  for (std::size_t r = 0; r < store.variants.size(); ++r) {
    const StoredDesign& d = store.variants[r];
    char rung[64];
    std::snprintf(rung, sizeof rung, "%.2f", d.requested_volume_fraction);

    const TriangleMesh subject = extract(grid, d.density, kShippedFactor);

    std::printf("=====================================================================\n");
    std::printf("RUNG %s — %zu vertices / %zu triangles\n", rung,
                subject.vertices.size(), subject.triangles.size());
    std::printf("=====================================================================\n");

    const CadAttribution att = attribute_to_cad_faces(subject, model, copts);
    const Population pop = split(att, subject.vertices.size());
    std::printf("  CAD-attributed %8zu (%5.2f%%)   ambiguous %6zu   OPTIMIZER-CUT %8zu (%5.2f%%)\n",
                pop.n_cad, 100.0 * pop.n_cad / subject.vertices.size(),
                pop.n_ambiguous, pop.n_cut,
                100.0 * pop.n_cut / subject.vertices.size());

    // C4: CAD + ambiguous frozen, exactly as PR 314 froze them.
    std::vector<char> frozen(subject.vertices.size(), 0);
    for (std::size_t v = 0; v < subject.vertices.size(); ++v)
      if (pop.cad[v] || att.ambiguous_at(v)) frozen[v] = 1;

    const double vol0 = std::fabs(signed_volume(subject));
    const double dih0 = dihedral_rms_deg(subject);
    const TriGrid cad_ref(model.mesh);
    const Deviation cad0 = deviation_from_cad(subject, cad_ref, pop.cad);
    const SliceSection sec0 = min_slice_section_of(subject, grid);

    // (d) THE TENDRIL COLUMN, AND WHY THERE ARE TWO OF THEM. PR 306's instrument
    // measures on the DESIGN grid, whose voxel is 1.705 mm — it cannot see a
    // sub-voxel change and read identically on every row of PR 314's table. A
    // closing that adds material sub-voxel would look identical there whether it
    // was safe or not, so the same instrument is ALSO run on a grid one
    // tessellation cell across, where a change of that size is visible.
    VoxelGrid fine_ref;
    fine_ref.nx = grid.nx * kShippedFactor;
    fine_ref.ny = grid.ny * kShippedFactor;
    fine_ref.nz = grid.nz * kShippedFactor;
    fine_ref.spacing = cell_mm;
    fine_ref.origin = grid.origin;
    fine_ref.tags.assign(static_cast<std::size_t>(fine_ref.nx) * fine_ref.ny *
                             fine_ref.nz, VoxelTag::Empty);
    const SliceSection secf0 = min_slice_section_of(subject, fine_ref);

    std::printf("\n  as exported: dihedral %.2f deg, volume %.0f mm3 (%.2f g),"
                " CAD dev rms %.4f mm\n", dih0, vol0,
                vol0 * 1e-3 * kPlaDensityGPerCm3, cad0.rms_mm);
    std::printf("               min section %.4f mm2 (design grid) / %.4f mm2 (export cell)\n",
                sec0.min_area_mm2, secf0.min_area_mm2);

    // ── ★ S1.1 WHAT SHAPE IS THE STAIRCASE, AS A CLOSING SEES IT? ───────────
    //
    // A closing fills every concavity TIGHTER THAN THE BALL and leaves the rest
    // alone. So before asking what it removed, ask what it can even reach: the
    // CREVICE RADIUS of a vertex is -1/kappa_min, the radius of the largest ball
    // that fits into the local concavity, and a closing at radius r touches
    // exactly the vertices whose crevice radius is smaller than r. Printed over
    // the OPTIMIZER-CUT population, which is the brush's whole domain.
    //
    // This is the reading that decides whether a NO-GO is about the operator or
    // about the geometry, and it is independent of every discretization choice
    // in this file.
    {
      const Curvatures cv0 = discrete_curvatures(subject);
      std::vector<double> radius;   // -1/kappa_min for concave vertices
      std::size_t convex = 0;
      radius.reserve(pop.n_cut);
      for (std::size_t v = 0; v < subject.vertices.size(); ++v) {
        if (!pop.cut[v] || !(cv0.area_mixed[v] > 0.0)) continue;
        if (cv0.kappa_min[v] >= 0.0) { ++convex; continue; }
        radius.push_back(-1.0 / cv0.kappa_min[v]);
      }
      std::sort(radius.begin(), radius.end());
      std::printf("\n-- ★ S1.1 THE CREVICE RADIUS OF THE CUT POPULATION -----------------\n");
      std::printf("  A closing at radius r moves exactly the vertices whose crevice\n");
      std::printf("  radius -1/kappa_min is BELOW r. Over %zu cut vertices:\n", pop.n_cut);
      std::printf("    convex (no crevice at all, unreachable by any closing): %zu (%.2f%%)\n",
                  convex, 100.0 * convex / pop.n_cut);
      if (!radius.empty()) {
        auto q = [&](double p) {
          return radius[std::min(radius.size() - 1,
                                 static_cast<std::size_t>(p * (radius.size() - 1)))];
        };
        std::printf("    concave: %zu   crevice radius p01 %.4f  p10 %.4f  median %.4f"
                    "  p90 %.4f mm\n",
                    radius.size(), q(0.01), q(0.10), q(0.50), q(0.90));
        std::printf("    fraction of the CUT population a closing reaches, by radius:\n");
        for (const double rr : {0.25, 0.5, 1.0, 1.705279, 3.410558, 6.821116}) {
          const std::size_t n =
              static_cast<std::size_t>(std::lower_bound(radius.begin(), radius.end(), rr) -
                                       radius.begin());
          std::printf("        r = %8.4f mm (%.2f voxel)  reaches %8zu  = %6.2f%%\n",
                      rr, rr / grid.spacing, n, 100.0 * n / pop.n_cut);
        }
      }
      std::printf("  READ THIS AGAINST THE STAIRCASE: PR 299 measured its amplitude at\n");
      std::printf("  rms 0.3424 mm on a %.4f mm voxel. A terrace that shallow and that\n", grid.spacing);
      std::printf("  wide is an OBTUSE concavity, and an obtuse concavity has a LARGE\n");
      std::printf("  crevice radius — which is exactly what a closing cannot reach\n");
      std::printf("  without a ball big enough to swallow the design's own features.\n");
    }

    std::printf("\noperator             r_mm  iters  wall_s  cutmax  cutrms  cutmoved"
                "  cadmoved  dihed_b  dihed_a    vol%%   mass_g   cad_rm%%   inward\n");
    std::printf("as exported          -     0    0.000  0.0000  0.0000         0"
                "         0  %7.2f  %7.2f   0.000    0.000     0.0%%        0\n",
                dih0, dih0);

    // Four arms per radius: the explicit flow with C1 armed and disarmed, the
    // explicit flow at a fifth of the time step (so a divergence cannot be
    // blamed on the step size alone), and the COUPLED form, which is the one the
    // reference actually solves.
    struct Variant { const char* suffix; int coupled; int c1; double dt; };
    const Variant variants[] = {
        {"expl_C1on",  0, 1, 0.125},
        {"expl_C1off", 0, 0, 0.125},
        {"expl_dt.025", 0, 1, 0.025},
        {"COUPLED",    1, 1, 0.125},
    };
    for (const double rad : radii) {
      for (const Variant& var : variants) {
        ClosingParams cp;
        cp.radius_mm = rad;
        cp.max_iterations = 40;
        cp.dt_scale = var.dt;
        cp.trust_mm = var.c1 ? 0.5 * cell_mm : 0.0;
        ClosingStats st;
        const TriangleMesh out = var.coupled
                                     ? closing_flow_coupled(subject, cp, frozen, st)
                                     : closing_flow(subject, cp, frozen, st);

        const Motion cut_m = motion(subject, out, pop.cut);
        const std::size_t c4 = cad_vertices_that_moved(subject, out, pop.cad);
        const double dih1 = dihedral_rms_deg(out);
        const double vol1 = std::fabs(signed_volume(out));
        const Deviation cad1 = deviation_from_cad(out, cad_ref, pop.cad);
        const SliceSection sec1 = min_slice_section_of(out, grid);
        const SliceSection secf1 = min_slice_section_of(out, fine_ref);
        const double mass_g = (vol1 - vol0) * 1e-3 * kPlaDensityGPerCm3;
        const double removed = cad0.rms_mm > 0.0
                                   ? 100.0 * (1.0 - cad1.rms_mm / cad0.rms_mm)
                                   : 0.0;

        char label[96];
        std::snprintf(label, sizeof label, "Close_r%.2f_%s", rad, var.suffix);
        std::printf("%-20s %5.2f %5d  %6.3f  %6.4f  %6.4f  %8zu  %8zu  %7.2f  %7.2f"
                    "  %6.3f  %7.3f  %6.1f%%  %7zu\n",
                    label, rad, st.iterations, st.wall_s, cut_m.max_mm,
                    cut_m.rms_mm, cut_m.moved, c4, dih0, dih1,
                    100.0 * (vol1 - vol0) / vol0, mass_g, removed,
                    st.inward_vertices);

        csv << rung << "," << label << "," << st.iterations << "," << st.wall_s
            << "," << cut_m.max_mm << "," << cut_m.rms_mm << "," << cut_m.moved
            << "," << c4 << "," << dih0 << "," << dih1 << "," << vol0 << ","
            << vol1 << "," << 100.0 * (vol1 - vol0) / vol0 << "," << mass_g
            << "," << cad0.rms_mm << "," << cad1.rms_mm << "," << removed << ","
            << st.active_first << "," << st.active_last << ","
            << (st.converged ? 1 : 0) << "," << st.inward_vertices << ","
            << st.worst_inward_mm << "," << st.max_outward_mm << ","
            << st.c1_clamped << "," << sec1.min_area_mm2 << ","
            << secf1.min_area_mm2 << "," << st.worst_aspect_before << ","
            << st.worst_aspect_after << "\n";

        // The per-radius detail that does not fit in the table.
        std::printf("      %*s active set %zu -> %zu (%s), C1 clamped %zu,"
                    " frozen %zu, max outward %.4f mm, worst inward %.6f mm\n",
                    0, "", st.active_first, st.active_last,
                    st.converged ? "EMPTIED — the surface is r-closed"
                                 : "STILL NON-EMPTY at the iteration cap",
                    st.c1_clamped, st.c4_frozen, st.max_outward_mm,
                    st.worst_inward_mm);
        std::printf("      %*s min section: design grid %.4f -> %.4f mm2,"
                    " export cell %.4f -> %.4f mm2   aspect %.2f -> %.2f"
                    "   degenerate tris %zu -> %zu   C1 box clamps %zu\n",
                    0, "", sec0.min_area_mm2, sec1.min_area_mm2,
                    secf0.min_area_mm2, secf1.min_area_mm2,
                    st.worst_aspect_before, st.worst_aspect_after,
                    st.degenerate_before, st.degenerate_after,
                    st.c1_box_clamped);
      }
    }

    // ── C4 OFF: THE ONLY SURFACE WITH A CORRECT ANSWER ──────────────────────
    //
    // PR 314 §S2.3's arm, verbatim in purpose: with C4 armed nothing on the CAD
    // population may move, so `cad_rm%` above reads 0.0% BY CONSTRUCTION and is
    // an assertion rather than a result. The brief's row (b) — "amplitude removed
    // on the surface that HAS a correct answer" — is only defined here, with the
    // freeze off, and it is measured with PR 299's metric unchanged. This is NOT
    // a proposal to run a closing flow on his CAD: PR 307's projection owns that
    // surface and is exact.
    std::printf("\n  -- C4 OFF: amplitude removed on the surface that HAS an answer --\n");
    std::printf("  as exported: cad_rms %.4f mm\n", cad0.rms_mm);
    std::printf("operator             r_mm  iters  wall_s   cad_rms_mm  removed%%"
                "   cad_max_mm   vol%%   mass_g\n");
    {
      const std::vector<char> nofreeze(subject.vertices.size(), 0);
      for (const double rad : radii)
        for (const int coupled : {0, 1}) {
          ClosingParams cp;
          cp.radius_mm = rad;
          cp.max_iterations = 40;
          cp.trust_mm = 0.5 * cell_mm;
          ClosingStats st;
          const TriangleMesh out =
              coupled ? closing_flow_coupled(subject, cp, nofreeze, st)
                      : closing_flow(subject, cp, nofreeze, st);
          const Deviation da = deviation_from_cad(out, cad_ref, pop.cad);
          const double vol1 = std::fabs(signed_volume(out));
          char lab[64];
          std::snprintf(lab, sizeof lab, "Close_r%.2f_%s", rad,
                        coupled ? "COUPLED" : "expl");
          std::printf("%-20s %5.2f %5d  %6.3f    %8.4f   %6.1f%%     %8.4f"
                      " %6.3f  %7.3f\n",
                      lab, rad, st.iterations, st.wall_s, da.rms_mm,
                      100.0 * (1.0 - da.rms_mm / cad0.rms_mm), da.max_mm,
                      100.0 * (vol1 - vol0) / vol0,
                      (vol1 - vol0) * 1e-3 * kPlaDensityGPerCm3);
        }
      for (const int pairs : {20, 160}) {
        TaubinParams tp;
        tp.pairs = pairs;
        SmoothConstraints tc;
        tc.enforce_min_feature = false;
        const Clock::time_point t0 = Clock::now();
        const SmoothResult sr = constrained_taubin_smooth(subject, tp, tc);
        const double w = secs_since(t0);
        const Deviation da = deviation_from_cad(sr.mesh, cad_ref, pop.cad);
        const double vol1 = std::fabs(signed_volume(sr.mesh));
        std::printf("Taubin_pairs_%-8d -  %4d  %6.3f    %8.4f   %6.1f%%     %8.4f"
                    " %6.3f  %7.3f\n",
                    pairs, sr.stats.applied_pairs, w, da.rms_mm,
                    100.0 * (1.0 - da.rms_mm / cad0.rms_mm), da.max_mm,
                    100.0 * (vol1 - vol0) / vol0,
                    (vol1 - vol0) * 1e-3 * kPlaDensityGPerCm3);
      }
    }

    // ── THE INCUMBENT, ON THE SAME MESH, SO THE ROWS ARE COMPARABLE ──────────
    // PR 314's Taubin rows, re-run here rather than quoted, because the subject
    // is re-extracted and a quoted row would be a row from a different mesh.
    std::printf("\n  -- the incumbent, re-run on THIS extraction (PR 314's rows) --\n");
    for (const int pairs : {20, 160}) {
      TaubinParams tp;
      tp.pairs = pairs;
      SmoothConstraints tc;
      tc.enforce_min_feature = false;
      tc.vertex_weight.assign(subject.vertices.size(), 1.0);
      for (std::size_t v = 0; v < subject.vertices.size(); ++v)
        if (frozen[v]) tc.vertex_weight[v] = 0.0;
      const Clock::time_point t0 = Clock::now();
      const SmoothResult sr = constrained_taubin_smooth(subject, tp, tc);
      const double w = secs_since(t0);
      const Motion cut_m = motion(subject, sr.mesh, pop.cut);
      const double vol1 = std::fabs(signed_volume(sr.mesh));
      const Deviation cad1 = deviation_from_cad(sr.mesh, cad_ref, pop.cad);
      std::printf("Taubin_pairs_%-8d -  %4d  %6.3f  %6.4f  %6.4f  %8zu  %8zu"
                  "  %7.2f  %7.2f  %6.3f  %7.3f  %6.1f%%        -\n",
                  pairs, sr.stats.applied_pairs, w, cut_m.max_mm, cut_m.rms_mm,
                  cut_m.moved, cad_vertices_that_moved(subject, sr.mesh, pop.cad),
                  dih0, dihedral_rms_deg(sr.mesh),
                  100.0 * (vol1 - vol0) / vol0,
                  (vol1 - vol0) * 1e-3 * kPlaDensityGPerCm3,
                  cad0.rms_mm > 0.0 ? 100.0 * (1.0 - cad1.rms_mm / cad0.rms_mm) : 0.0);
      csv << rung << ",Taubin_pairs_" << pairs << "," << sr.stats.applied_pairs
          << "," << w << "," << cut_m.max_mm << "," << cut_m.rms_mm << ","
          << cut_m.moved << ","
          << cad_vertices_that_moved(subject, sr.mesh, pop.cad) << "," << dih0
          << "," << dihedral_rms_deg(sr.mesh) << "," << vol0 << "," << vol1
          << "," << 100.0 * (vol1 - vol0) / vol0 << ","
          << (vol1 - vol0) * 1e-3 * kPlaDensityGPerCm3 << "," << cad0.rms_mm
          << "," << cad1.rms_mm << ","
          << (cad0.rms_mm > 0.0 ? 100.0 * (1.0 - cad1.rms_mm / cad0.rms_mm) : 0.0)
          << ",0,0,1,0,0,0,0," << min_slice_section_of(sr.mesh, grid).min_area_mm2
          << "," << min_slice_section_of(sr.mesh, fine_ref).min_area_mm2
          << ",0,0\n";
    }
    std::printf("\n");
    std::fflush(stdout);
  }

  // ── (f) COST PER STROKE, AGAINST THE 63 ms THE PAGE NOW ACHIEVES ───────────
  //
  // PR 314 measured the shipped stroke path end to end at 63.3 ms on his rung-068
  // variant, of which 34.9 ms is the smoothing itself. This is the same question
  // asked of the closing flow: what would ONE stroke cost if the brush drove this
  // operator instead? Reported per iteration as well as per run, because an
  // operator that needs 40 iterations to converge cannot be priced at one.
  {
    std::printf("=====================================================================\n");
    std::printf("(f) COST PER STROKE, on rung 068, against the page's 63.3 ms\n");
    std::printf("=====================================================================\n");
    const StoredDesign& d = store.variants[0];
    const TriangleMesh subject = extract(grid, d.density, kShippedFactor);
    const CadAttribution att = attribute_to_cad_faces(subject, model, copts);
    const Population pop = split(att, subject.vertices.size());
    std::vector<char> frozen(subject.vertices.size(), 0);
    for (std::size_t v = 0; v < subject.vertices.size(); ++v)
      if (pop.cad[v] || att.ambiguous_at(v)) frozen[v] = 1;
    std::printf("  %zu vertices / %zu triangles (the shipped variant_068.stl carries\n"
                "  143862 — this is the same field re-extracted, PR 314's note)\n\n",
                subject.vertices.size(), subject.triangles.size());
    std::printf("operator                       iters   total_ms   ms/iteration"
                "   x the 63.3 ms budget\n");
    for (const int coupled : {0, 1})
      for (const int iters : {1, 5, 40}) {
        ClosingParams cp;
        cp.radius_mm = 1.705279;
        cp.max_iterations = iters;
        cp.trust_mm = 0.5 * cell_mm;
        ClosingStats st;
        const Clock::time_point t0 = Clock::now();
        const TriangleMesh out =
            coupled ? closing_flow_coupled(subject, cp, frozen, st)
                    : closing_flow(subject, cp, frozen, st);
        const double ms = 1000.0 * secs_since(t0);
        (void)out;
        std::printf("Closing r1.71 %-14s %5d   %8.1f   %12.1f   %18.1fx\n",
                    coupled ? "COUPLED" : "explicit", st.iterations, ms,
                    st.iterations ? ms / st.iterations : ms, ms / 63.3);
      }
    TaubinParams tp;
    tp.pairs = 20;
    SmoothConstraints tc;
    tc.enforce_min_feature = false;
    const Clock::time_point t0 = Clock::now();
    const SmoothResult sr = constrained_taubin_smooth(subject, tp, tc);
    const double ms = 1000.0 * secs_since(t0);
    std::printf("Taubin pairs 20 (the incumbent) %5d   %8.1f   %12.1f   %18.1fx\n",
                sr.stats.applied_pairs, ms, ms / 20.0, ms / 63.3);
    std::printf("\n  NOTE: these are CORE wall times in a release build, not the\n"
                "  end-to-end page latency PR 314's 63.3 ms measures — that figure\n"
                "  includes the app-side ViewerMesh build (19.7 ms) on top of the\n"
                "  34.9 ms of smoothing. The comparison to make is operator against\n"
                "  operator: Taubin's 34.9 ms is the budget a successor has to fit.\n\n");
  }
  return 0;
}
