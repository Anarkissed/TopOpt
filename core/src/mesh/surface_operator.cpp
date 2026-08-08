#include "topopt/surface_operator.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <stdexcept>
#include <utility>
#include <vector>

namespace topopt {
namespace {

using Clock = std::chrono::steady_clock;

Vec3 sub(const Vec3& a, const Vec3& b) { return Vec3{a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 add(const Vec3& a, const Vec3& b) { return Vec3{a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 scale(const Vec3& a, double s) { return Vec3{a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double norm(const Vec3& a) { return std::sqrt(dot(a, a)); }
Vec3 normalized(const Vec3& a) {
  const double n = norm(a);
  return n > 0.0 ? scale(a, 1.0 / n) : Vec3{0.0, 0.0, 0.0};
}

// Per-vertex area: one third of every incident triangle's area. Summed over the
// mesh this is the total surface area, which is what the C3 uniform shift needs
// (dV = shift * A to first order).
std::vector<double> vertex_areas(const TriangleMesh& m) {
  std::vector<double> a(m.vertices.size(), 0.0);
  for (const auto& t : m.triangles) {
    const Vec3& p0 = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& p1 = m.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& p2 = m.vertices[static_cast<std::size_t>(t[2])];
    const double area = 0.5 * norm(cross(sub(p1, p0), sub(p2, p0)));
    for (int c = 0; c < 3; ++c) a[static_cast<std::size_t>(t[c])] += area / 3.0;
  }
  return a;
}

double mean_edge_length(const TriangleMesh& m) {
  double sum = 0.0;
  std::size_t n = 0;
  for (const auto& t : m.triangles)
    for (int c = 0; c < 3; ++c) {
      const Vec3& a = m.vertices[static_cast<std::size_t>(t[c])];
      const Vec3& b = m.vertices[static_cast<std::size_t>(t[(c + 1) % 3])];
      sum += norm(sub(b, a));
      ++n;
    }
  return n > 0 ? sum / static_cast<double>(n) : 0.0;
}

// ── C1 + C2 + C5, applied to a TOTAL displacement from the ORIGINAL position ──
//
// Every clamp in this file is against `orig`, never against the previous
// iterate: C1 bounds how far a vertex has moved from where the export put it, so
// a hundred small steps must be bounded exactly as one large one is.
//
// C1 IS A DIRECTION-PRESERVING SCALING, not a per-axis box clamp. Given a
// proposed displacement d, the largest t in [0,1] with orig + t*d inside the box
// is taken. That matters: a per-axis clamp changes the DIRECTION of the motion
// and can therefore turn an outward step into one with an inward component,
// re-breaking C2 after C2 has already been enforced. Scaling cannot: t*d has the
// sign of d along every direction, so C2 survives C1 exactly and the two
// constraints compose without iteration.
//
// The counters are PER VERTEX EVER, not per event: an operator that runs 40
// steps clamps the same vertex 40 times, and reporting 40 would read as 40
// vertices. `ever_*` is set once and counted at the end.
struct ConstraintCounters {
  std::vector<char> ever_c1;
  std::vector<char> ever_c2;
  std::vector<char> ever_pinned;
  double max_c1_pullback = 0.0;
  double max_unclamped_excursion = 0.0;

  void resize(std::size_t n) {
    ever_c1.assign(n, 0);
    ever_c2.assign(n, 0);
    ever_pinned.assign(n, 0);
  }
  static std::size_t count(const std::vector<char>& f) {
    std::size_t n = 0;
    for (const char c : f) n += (c ? 1u : 0u);
    return n;
  }
};

// Constrain ONE vertex's proposed total displacement. `n` is its outward normal.
Vec3 constrain_delta(const Vec3& d_in, const Vec3& n, TrustSign sign, double weight,
                     double radius_mm, ConstraintCounters* c, std::size_t v) {
  if (sign == TrustSign::Pinned || weight == 0.0) {
    if (c != nullptr && sign == TrustSign::Pinned) c->ever_pinned[v] = 1;
    return Vec3{0.0, 0.0, 0.0};
  }

  Vec3 d = scale(d_in, weight);

  // C2 — project out the component that runs against the sign.
  if (sign != TrustSign::Both) {
    const double s = dot(d, n);
    const bool violates = (sign == TrustSign::OutwardOnly && s < 0.0) ||
                          (sign == TrustSign::InwardOnly && s > 0.0);
    if (violates) {
      d = sub(d, scale(n, s));
      if (c != nullptr) c->ever_c2[v] = 1;
    }
  }

  // C1 — scale into the trust box.
  if (radius_mm > 0.0) {
    const double ax[3] = {std::fabs(d.x), std::fabs(d.y), std::fabs(d.z)};
    double excursion = 0.0;
    for (const double a : ax) excursion = std::fmax(excursion, a - radius_mm);
    if (excursion > 0.0) {
      double t = 1.0;
      for (const double a : ax)
        if (a > radius_mm) t = std::fmin(t, radius_mm / a);
      const Vec3 clamped = scale(d, t);
      if (c != nullptr) {
        c->ever_c1[v] = 1;
        c->max_unclamped_excursion = std::fmax(c->max_unclamped_excursion, excursion);
        c->max_c1_pullback = std::fmax(c->max_c1_pullback, norm(sub(d, clamped)));
      }
      d = clamped;
    }
  }
  return d;
}

// Constrain a whole displacement field.
void constrain_field(const std::vector<Vec3>& proposed,
                     const std::vector<Vec3>& normals,
                     const SurfaceConstraints& k, double radius_mm,
                     std::vector<Vec3>& out, ConstraintCounters* c) {
  const bool has_sign = !k.sign.empty();
  const bool has_w = !k.vertex_weight.empty();
  out.resize(proposed.size());
  for (std::size_t v = 0; v < proposed.size(); ++v) {
    const TrustSign s = has_sign ? k.sign[v] : TrustSign::Both;
    double w = has_w ? k.vertex_weight[v] : 1.0;
    if (!(w > 0.0)) w = 0.0;  // also catches NaN
    if (w > 1.0) w = 1.0;
    out[v] = constrain_delta(proposed[v], normals[v], s, w, radius_mm, c, v);
  }
}

// Apply a displacement field to the original positions. A zero displacement takes
// a VERBATIM branch rather than `p + 0*d`: -0.0 + 0.0 is +0.0, and one flipped
// sign bit defeats the byte-identity bar.
void apply_field(const std::vector<Vec3>& orig, const std::vector<Vec3>& delta,
                 std::vector<Vec3>& out) {
  out.resize(orig.size());
  for (std::size_t v = 0; v < orig.size(); ++v) {
    if (delta[v].x == 0.0 && delta[v].y == 0.0 && delta[v].z == 0.0) {
      out[v] = orig[v];
      continue;
    }
    out[v] = add(orig[v], delta[v]);
  }
}

// ── C3 — the uniform shift of the level set ──────────────────────────────────
//
// Curvature flow shrinks. The compensator is the mesh analogue of shifting a
// level set by a single scalar: every movable vertex moves along its own normal
// by the one value that closes the volume gap, dV = shift * A. It is iterated
// because the relation is first-order and because C1/C2 can block part of the
// shift — the residual after the last iteration is REPORTED, never assumed away.
void preserve_volume(const std::vector<Vec3>& orig,
                     const std::vector<Vec3>& ref_normals,
                     const SurfaceConstraints& k, double radius_mm,
                     double target_volume, TriangleMesh& mesh,
                     std::vector<Vec3>& delta, SurfaceOperatorStats& st) {
  if (!k.preserve_volume || target_volume == 0.0) return;
  ConstraintCounters sink;  // clamp counters here are C3's, not the operator's
  sink.resize(delta.size());
  std::vector<Vec3> proposed(delta.size());
  std::vector<Vec3> saved(delta.size());

  // THE SHIFT IS DAMPED AND BACKTRACKED, and it has to be. dV = shift * A is a
  // FIRST-ORDER relation, and the shift it asks for after a hard operator run is
  // not small: on a voxelized R=10 sphere that has lost 13% of its volume it is
  // 0.46 mm against a 0.5 mm trust radius. Applied raw, most vertices hit the C1
  // boundary, the volume overshoots, the next iteration overshoots back, and the
  // loop leaves the part FURTHER from its target than it found it — measured, on
  // this fixture, at -18.3% against the -13.6% it started from. So each step is
  // KEPT only if it strictly reduces the volume error, and halved when it does
  // not. What cannot be corrected inside C1 is reported as residual drift, never
  // ground away at.
  double relax = 1.0;
  for (int it = 0; it < k.volume_iterations; ++it) {
    const double v_now = std::fabs(signed_volume(mesh));
    const double err = target_volume - v_now;
    if (std::fabs(err) <= k.volume_tolerance * std::fabs(target_volume)) break;

    const std::vector<Vec3> n = vertex_normals(mesh);
    const std::vector<double> area = vertex_areas(mesh);
    double movable_area = 0.0;
    const bool has_sign = !k.sign.empty();
    const bool has_w = !k.vertex_weight.empty();
    for (std::size_t v = 0; v < mesh.vertices.size(); ++v) {
      const TrustSign s = has_sign ? k.sign[v] : TrustSign::Both;
      const double w = has_w ? k.vertex_weight[v] : 1.0;
      if (s == TrustSign::Pinned || !(w > 0.0)) continue;
      movable_area += area[v];
    }
    if (!(movable_area > 0.0)) break;

    const double shift = relax * err / movable_area;
    saved = delta;
    for (std::size_t v = 0; v < delta.size(); ++v)
      proposed[v] = add(delta[v], scale(n[v], shift));
    // Constrained against `ref_normals` — the ORIGINAL surface's normals —
    // because "outward" has to mean outward on the geometry C2 was classified
    // against, not on whatever the operator has produced so far.
    constrain_field(proposed, ref_normals, k, radius_mm, delta, &sink);
    apply_field(orig, delta, mesh.vertices);

    const double err_after = target_volume - std::fabs(signed_volume(mesh));
    if (std::fabs(err_after) >= std::fabs(err)) {
      delta = saved;  // reject
      apply_field(orig, delta, mesh.vertices);
      relax *= 0.5;
      if (relax < 1e-4) break;  // C1 has no room left; the residual is reported
      continue;
    }
    st.volume_shift_iterations = it + 1;
  }
}

}  // namespace

std::vector<Vec3> vertex_normals(const TriangleMesh& mesh) {
  std::vector<Vec3> n(mesh.vertices.size(), Vec3{0.0, 0.0, 0.0});
  for (const auto& t : mesh.triangles) {
    const Vec3& p0 = mesh.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& p1 = mesh.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& p2 = mesh.vertices[static_cast<std::size_t>(t[2])];
    // Un-normalized cross product: magnitude is twice the area, so accumulating
    // it directly IS the area weighting.
    const Vec3 fn = cross(sub(p1, p0), sub(p2, p0));
    for (int c = 0; c < 3; ++c) {
      Vec3& acc = n[static_cast<std::size_t>(t[c])];
      acc = add(acc, fn);
    }
  }

  // ORIENTATION IS MEASURED, NOT ASSUMED.
  //
  // ★ AS OF task 2026-08-09-fix-inward-wound-normals THIS BRANCH NO LONGER FIRES
  // on core-built meshes, and the history is worth keeping because it is what
  // makes the branch worth keeping. When this was written, core's own
  // `marching_cubes` emitted the OPPOSITE of the counter-clockwise-from-outside
  // winding STL specifies: on a voxelized R=10 sphere signed_volume(m) was
  // -4204.6667, so cross(p1-p0, p2-p0) pointed INTO the solid at every triangle.
  // Taking the winding on faith would have made every "outward" normal in this
  // file point inward, and the consequence was not cosmetic: C2's OutwardOnly —
  // the case whose entire job is to forbid removing material from a load path or
  // a thin section — would have permitted exactly and only the motion that
  // removes it, while reporting that it was protecting the part.
  //
  // That producer is now fixed at its source, so `signed_volume` is positive for
  // a core mesh and this flip is skipped. It STAYS because it is a measurement
  // of the mesh in hand, not a compensation tuned to one producer: this module
  // is also handed IMPORTED meshes, and the first inward one would silently
  // invert OutwardOnly again if the sign were taken on faith instead.
  if (signed_volume(mesh) < 0.0)
    for (Vec3& v : n) v = scale(v, -1.0);

  for (Vec3& v : n) v = normalized(v);
  return n;
}

std::vector<Vec3> mean_curvature_normals(const TriangleMesh& mesh) {
  const std::size_t nv = mesh.vertices.size();
  std::vector<Vec3> lap(nv, Vec3{0.0, 0.0, 0.0});
  std::vector<double> mixed(nv, 0.0);

  for (const auto& t : mesh.triangles) {
    const int idx[3] = {t[0], t[1], t[2]};
    const Vec3 p[3] = {mesh.vertices[static_cast<std::size_t>(idx[0])],
                       mesh.vertices[static_cast<std::size_t>(idx[1])],
                       mesh.vertices[static_cast<std::size_t>(idx[2])]};
    const Vec3 e01 = sub(p[1], p[0]), e02 = sub(p[2], p[0]);
    const double two_area = norm(cross(e01, e02));
    if (!(two_area > 0.0)) continue;  // degenerate: contributes nothing
    const double area = 0.5 * two_area;

    // cot at corner c, which subtends the edge opposite c.
    double cot[3];
    bool obtuse[3];
    for (int c = 0; c < 3; ++c) {
      const Vec3 u = sub(p[(c + 1) % 3], p[c]);
      const Vec3 w = sub(p[(c + 2) % 3], p[c]);
      const double d = dot(u, w);
      cot[c] = d / two_area;  // |u||w|cos / (|u||w|sin) = cot
      obtuse[c] = d < 0.0;
    }

    // L[i] = sum_j (cot alpha + cot beta) (p_j - p_i): the angle at corner c
    // weights the edge between the OTHER two corners.
    for (int c = 0; c < 3; ++c) {
      const int a = idx[(c + 1) % 3], b = idx[(c + 2) % 3];
      const Vec3 pa = p[(c + 1) % 3], pb = p[(c + 2) % 3];
      lap[static_cast<std::size_t>(a)] =
          add(lap[static_cast<std::size_t>(a)], scale(sub(pb, pa), cot[c]));
      lap[static_cast<std::size_t>(b)] =
          add(lap[static_cast<std::size_t>(b)], scale(sub(pa, pb), cot[c]));
    }

    // Meyer et al. mixed area: Voronoi where the triangle is non-obtuse, and the
    // half/quarter split where it is (the Voronoi cell leaves the triangle there
    // and its area would be wrong).
    const bool tri_obtuse = obtuse[0] || obtuse[1] || obtuse[2];
    for (int c = 0; c < 3; ++c) {
      double contrib;
      if (!tri_obtuse) {
        const Vec3 u = sub(p[(c + 1) % 3], p[c]);
        const Vec3 w = sub(p[(c + 2) % 3], p[c]);
        contrib = (dot(u, u) * cot[(c + 2) % 3] + dot(w, w) * cot[(c + 1) % 3]) / 8.0;
      } else {
        contrib = obtuse[c] ? area / 2.0 : area / 4.0;
      }
      mixed[static_cast<std::size_t>(idx[c])] += contrib;
    }
  }

  std::vector<Vec3> kn(nv, Vec3{0.0, 0.0, 0.0});
  for (std::size_t v = 0; v < nv; ++v)
    if (mixed[v] > 0.0) kn[v] = scale(lap[v], 1.0 / (2.0 * mixed[v]));
  return kn;
}

// ── edges and watertight refinement ──────────────────────────────────────────

std::vector<std::pair<int, int>> mesh_edges(const TriangleMesh& mesh) {
  std::vector<std::pair<int, int>> e;
  e.reserve(mesh.triangles.size() * 3);
  for (const auto& t : mesh.triangles)
    for (int c = 0; c < 3; ++c) {
      int a = t[c], b = t[(c + 1) % 3];
      if (a > b) std::swap(a, b);
      e.emplace_back(a, b);
    }
  std::sort(e.begin(), e.end());
  e.erase(std::unique(e.begin(), e.end()), e.end());
  return e;
}

namespace {
int edge_index(const std::vector<std::pair<int, int>>& edges, int a, int b) {
  if (a > b) std::swap(a, b);
  const auto it = std::lower_bound(edges.begin(), edges.end(), std::make_pair(a, b));
  if (it == edges.end() || *it != std::make_pair(a, b)) return -1;
  return static_cast<int>(it - edges.begin());
}
}  // namespace

TriangleMesh refine_edges(const TriangleMesh& mesh,
                          const std::vector<char>& split_edge_flag,
                          const std::vector<std::pair<int, int>>& edges,
                          std::vector<std::pair<int, int>>* out_new_vertex_parents) {
  if (split_edge_flag.size() != edges.size())
    throw std::invalid_argument("refine_edges: flag/edge size mismatch");

  TriangleMesh out;
  out.vertices = mesh.vertices;

  // One new vertex per split edge, appended in ascending edge order — the source
  // of the routine's determinism.
  std::vector<int> mid(edges.size(), -1);
  for (std::size_t e = 0; e < edges.size(); ++e) {
    if (!split_edge_flag[e]) continue;
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(edges[e].first)];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(edges[e].second)];
    mid[e] = static_cast<int>(out.vertices.size());
    out.vertices.push_back(Vec3{0.5 * (a.x + b.x), 0.5 * (a.y + b.y), 0.5 * (a.z + b.z)});
    if (out_new_vertex_parents != nullptr) out_new_vertex_parents->push_back(edges[e]);
  }

  for (const auto& t : mesh.triangles) {
    // m[c] is the midpoint of the edge OPPOSITE corner c.
    int m[3];
    int count = 0;
    for (int c = 0; c < 3; ++c) {
      const int ei = edge_index(edges, t[(c + 1) % 3], t[(c + 2) % 3]);
      m[c] = ei >= 0 ? mid[static_cast<std::size_t>(ei)] : -1;
      if (m[c] >= 0) ++count;
    }
    const int v0 = t[0], v1 = t[1], v2 = t[2];

    if (count == 0) {
      out.triangles.push_back({v0, v1, v2});
    } else if (count == 1) {
      // The apex is the corner opposite the split edge.
      int c = 0;
      while (m[c] < 0) ++c;
      const int a = t[c], b = t[(c + 1) % 3], d = t[(c + 2) % 3];
      out.triangles.push_back({a, b, m[c]});
      out.triangles.push_back({a, m[c], d});
    } else if (count == 2) {
      // The apex is the corner opposite the UNSPLIT edge; both split edges meet
      // there. Fan the remaining quad from the first new midpoint.
      int c = 0;
      while (m[c] >= 0) ++c;
      const int a = t[c], b = t[(c + 1) % 3], d = t[(c + 2) % 3];
      const int mab = m[(c + 2) % 3];  // midpoint of edge (a,b) = edge opposite d
      const int mda = m[(c + 1) % 3];  // midpoint of edge (d,a) = edge opposite b
      out.triangles.push_back({a, mab, mda});
      out.triangles.push_back({mab, b, d});
      out.triangles.push_back({mab, d, mda});
    } else {
      out.triangles.push_back({v0, m[2], m[1]});
      out.triangles.push_back({v1, m[0], m[2]});
      out.triangles.push_back({v2, m[1], m[0]});
      out.triangles.push_back({m[0], m[1], m[2]});
    }
    (void)count;
  }
  return out;
}

// ── C2 classification ────────────────────────────────────────────────────────

std::vector<TrustSign> classify_trust_sign(const TriangleMesh& mesh,
                                           const VoxelGrid& grid,
                                           const std::vector<double>& density,
                                           const TrustSignPolicy& policy) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument("classify_trust_sign: density size mismatch");

  const double thin_mm =
      policy.thin_section_mm > 0.0 ? policy.thin_section_mm : 2.0 * grid.spacing;
  const double bind_tol =
      policy.bind_tol_mm > 0.0 ? policy.bind_tol_mm : grid.spacing;

  // The width field is the same Hildebrand measure the width-aware knockdown
  // gate reads. Computed once for the whole grid.
  std::vector<double> width;
  if (thin_mm > 0.0)
    width = local_member_thickness_mm(grid, density, 0.5, policy.thickness_cap_voxels);

  std::vector<TrustSign> sign(mesh.vertices.size(), TrustSign::Both);
  for (std::size_t v = 0; v < mesh.vertices.size(); ++v) {
    const Vec3& p = mesh.vertices[v];
    bool material_matters = false;

    const int i0 = static_cast<int>(std::floor((p.x - grid.origin.x) / grid.spacing));
    const int j0 = static_cast<int>(std::floor((p.y - grid.origin.y) / grid.spacing));
    const int k0 = static_cast<int>(std::floor((p.z - grid.origin.z) / grid.spacing));

    // (b) reads the thickest member this vertex touches: a surface vertex beside
    // a thick rib is not on a thin section merely because some sliver is nearby.
    double thickest = -1.0;
    for (int dk = -1; dk <= 1 && !material_matters; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          const int i = i0 + di, j = j0 + dj, k = k0 + dk;
          if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz)
            continue;
          const std::size_t idx = grid.index(i, j, k);
          // (a) LOAD PATH.
          if (policy.load_path_binds && (grid.tags[idx] == VoxelTag::Load ||
                                         grid.tags[idx] == VoxelTag::Fixture)) {
            material_matters = true;
            break;
          }
          if (!width.empty() && width[idx] > 0.0)
            thickest = std::fmax(thickest, width[idx]);
        }
    // (b) THIN SECTION. `thickest < 0` means no solid voxel in the neighbourhood
    // — nothing to be thin — so it is NOT a thin section.
    //
    // THE COMPARISON IS `<=`, AND THAT IS NOT A FUDGE. local_member_thickness_mm
    // reports 2 * r * spacing for an integer radius r, so its smallest non-zero
    // value is exactly 2 voxels: a one-voxel-thick fin reads 2.000, not 1.000. A
    // strict `<` against a 2-voxel threshold is therefore UNREACHABLE — it can
    // never fire on any member, however thin. `<=` also happens to be the right
    // rule on its own terms: a member sitting exactly on §7 V3's "minimum feature
    // size >= 2 voxels" floor is precisely the one that must not be thinned.
    if (!material_matters && thickest > 0.0 && thickest <= thin_mm)
      material_matters = true;

    bool box_binds = false;
    if (policy.has_design_box) {
      const double dx = std::fmin(p.x - policy.box_min.x, policy.box_max.x - p.x);
      const double dy = std::fmin(p.y - policy.box_min.y, policy.box_max.y - p.y);
      const double dz = std::fmin(p.z - policy.box_min.z, policy.box_max.z - p.z);
      // Distance to the nearest wall from inside; negative when already outside.
      const double inside_margin = std::fmin(dx, std::fmin(dy, dz));
      box_binds = inside_margin <= bind_tol;
    }

    if (material_matters && box_binds)
      sign[v] = TrustSign::Pinned;
    else if (material_matters)
      sign[v] = TrustSign::OutwardOnly;
    else if (box_binds)
      sign[v] = TrustSign::InwardOnly;
  }
  return sign;
}

// ── OPERATOR A ───────────────────────────────────────────────────────────────

SurfaceOperatorResult mean_curvature_flow(const TriangleMesh& mesh,
                                          const MeanCurvatureParams& params,
                                          const SurfaceConstraints& constraints) {
  if (mesh.vertices.empty() || mesh.triangles.empty())
    throw std::invalid_argument("mean_curvature_flow: empty mesh");
  if (!constraints.sign.empty() && constraints.sign.size() != mesh.vertices.size())
    throw std::invalid_argument("mean_curvature_flow: sign size mismatch");
  if (!constraints.vertex_weight.empty() &&
      constraints.vertex_weight.size() != mesh.vertices.size())
    throw std::invalid_argument("mean_curvature_flow: vertex_weight size mismatch");

  const Clock::time_point t0 = Clock::now();
  SurfaceOperatorResult r;
  r.mesh = mesh;
  SurfaceOperatorStats& st = r.stats;
  st.requested_steps = params.steps > 0 ? params.steps : 0;
  st.vertices_in = st.vertices_out = mesh.vertices.size();
  st.triangles_in = st.triangles_out = mesh.triangles.size();
  st.volume_before_mm3 = std::fabs(signed_volume(mesh));
  st.volume_after_operator_mm3 = st.volume_before_mm3;
  st.volume_after_mm3 = st.volume_before_mm3;
  if (params.steps <= 0) {
    st.wall_seconds = std::chrono::duration<double>(Clock::now() - t0).count();
    return r;  // OFF -> identity (byte-identical)
  }

  const double radius = constraints.trust_voxels > 0.0
                            ? constraints.trust_voxels * constraints.cell_mm
                            : 0.0;
  const std::vector<Vec3>& orig = mesh.vertices;
  const std::vector<Vec3> ref_normals = vertex_normals(mesh);
  const double h = mean_edge_length(mesh);
  const double dt = params.dt_scale * h * h;

  ConstraintCounters counters;
  counters.resize(orig.size());
  std::vector<Vec3> delta(orig.size(), Vec3{0.0, 0.0, 0.0});
  std::vector<Vec3> proposed(orig.size());

  for (int s = 0; s < params.steps; ++s) {
    const std::vector<Vec3> kn = mean_curvature_normals(r.mesh);
    const std::vector<Vec3> n_now = vertex_normals(r.mesh);
    for (std::size_t v = 0; v < orig.size(); ++v) {
      // ALONG ITS OWN NORMAL, PROPORTIONAL TO MEAN CURVATURE. The cotangent
      // Laplacian carries a tangential component on an irregular triangulation;
      // projecting it out keeps the operator's motion purely normal, which is
      // both what the method is defined as and what makes the C2 sign test mean
      // what it says.
      const double kh = dot(kn[v], n_now[v]);
      proposed[v] = add(delta[v], scale(n_now[v], dt * kh));
    }
    constrain_field(proposed, ref_normals, constraints, radius, delta, &counters);
    apply_field(orig, delta, r.mesh.vertices);
    st.applied_steps = s + 1;
  }

  st.volume_after_operator_mm3 = std::fabs(signed_volume(r.mesh));
  preserve_volume(orig, ref_normals, constraints, radius, st.volume_before_mm3,
                  r.mesh, delta, st);
  st.volume_after_mm3 = std::fabs(signed_volume(r.mesh));
  st.volume_drift_fraction =
      st.volume_before_mm3 > 0.0
          ? std::fabs(st.volume_after_mm3 - st.volume_before_mm3) / st.volume_before_mm3
          : 0.0;

  for (const Vec3& d : delta)
    st.max_displacement_mm = std::fmax(st.max_displacement_mm, norm(d));
  st.c1_clamped = ConstraintCounters::count(counters.ever_c1);
  st.c2_projected = ConstraintCounters::count(counters.ever_c2);
  st.pinned = ConstraintCounters::count(counters.ever_pinned);
  st.c1_would_violate = st.c1_clamped;
  st.max_c1_pullback_mm = counters.max_c1_pullback;
  st.max_unclamped_excursion_mm = counters.max_unclamped_excursion;
  st.wall_seconds = std::chrono::duration<double>(Clock::now() - t0).count();
  return r;
}

// ── OPERATOR B ───────────────────────────────────────────────────────────────

namespace {

// Terrace segmentation: connected runs of faces whose normal agrees with the
// run's SEED normal within `angle`. Seed-relative rather than neighbour-relative
// on purpose — chaining neighbour-to-neighbour lets one "terrace" bend around a
// whole fillet, which is exactly the shape that must NOT be flattened.
std::vector<int> segment_terraces(const TriangleMesh& mesh,
                                  const std::vector<Vec3>& face_normal,
                                  double cos_tol, std::size_t& out_count) {
  const std::size_t nf = mesh.triangles.size();
  // face adjacency over shared edges
  const std::vector<std::pair<int, int>> edges = mesh_edges(mesh);
  std::vector<std::array<int, 2>> edge_face(edges.size(), {-1, -1});
  for (std::size_t f = 0; f < nf; ++f)
    for (int c = 0; c < 3; ++c) {
      const int ei = edge_index(edges, mesh.triangles[f][c], mesh.triangles[f][(c + 1) % 3]);
      if (ei < 0) continue;
      auto& ef = edge_face[static_cast<std::size_t>(ei)];
      if (ef[0] < 0) ef[0] = static_cast<int>(f);
      else if (ef[1] < 0) ef[1] = static_cast<int>(f);
    }

  std::vector<int> label(nf, -1);
  std::vector<int> stack;
  int next = 0;
  for (std::size_t seed = 0; seed < nf; ++seed) {
    if (label[seed] >= 0) continue;
    const Vec3 sn = face_normal[seed];
    label[seed] = next;
    stack.clear();
    stack.push_back(static_cast<int>(seed));
    while (!stack.empty()) {
      const int f = stack.back();
      stack.pop_back();
      for (int c = 0; c < 3; ++c) {
        const int ei = edge_index(edges, mesh.triangles[static_cast<std::size_t>(f)][c],
                                  mesh.triangles[static_cast<std::size_t>(f)][(c + 1) % 3]);
        if (ei < 0) continue;
        const auto& ef = edge_face[static_cast<std::size_t>(ei)];
        for (const int g : ef) {
          if (g < 0 || label[static_cast<std::size_t>(g)] >= 0) continue;
          if (dot(face_normal[static_cast<std::size_t>(g)], sn) < cos_tol) continue;
          label[static_cast<std::size_t>(g)] = next;
          stack.push_back(g);
        }
      }
    }
    ++next;
  }
  out_count = static_cast<std::size_t>(next);
  return label;
}

std::vector<Vec3> face_normals_of(const TriangleMesh& m) {
  std::vector<Vec3> fn(m.triangles.size());
  for (std::size_t f = 0; f < m.triangles.size(); ++f) {
    const auto& t = m.triangles[f];
    fn[f] = normalized(cross(sub(m.vertices[static_cast<std::size_t>(t[1])],
                                 m.vertices[static_cast<std::size_t>(t[0])]),
                             sub(m.vertices[static_cast<std::size_t>(t[2])],
                                 m.vertices[static_cast<std::size_t>(t[0])])));
  }
  return fn;
}

// Solve the 3x3 symmetric normal equations for the plane fit h = a + b*x1 + g*x2.
// Returns false if the system is singular (a degenerate terrace).
bool solve3(double A[3][3], double rhs[3], double out[3]) {
  for (int i = 0; i < 3; ++i) {
    int piv = i;
    for (int r = i + 1; r < 3; ++r)
      if (std::fabs(A[r][i]) > std::fabs(A[piv][i])) piv = r;
    if (std::fabs(A[piv][i]) < 1e-12) return false;
    if (piv != i) {
      for (int c = 0; c < 3; ++c) std::swap(A[i][c], A[piv][c]);
      std::swap(rhs[i], rhs[piv]);
    }
    for (int r = i + 1; r < 3; ++r) {
      const double f = A[r][i] / A[i][i];
      for (int c = i; c < 3; ++c) A[r][c] -= f * A[i][c];
      rhs[r] -= f * rhs[i];
    }
  }
  for (int i = 2; i >= 0; --i) {
    double s = rhs[i];
    for (int c = i + 1; c < 3; ++c) s -= A[i][c] * out[c];
    out[i] = s / A[i][i];
  }
  return true;
}

}  // namespace

SurfaceOperatorResult ramp_reconstruction(const TriangleMesh& mesh,
                                          const RampParams& params,
                                          const SurfaceConstraints& constraints) {
  if (mesh.vertices.empty() || mesh.triangles.empty())
    throw std::invalid_argument("ramp_reconstruction: empty mesh");
  if (!constraints.sign.empty() && constraints.sign.size() != mesh.vertices.size())
    throw std::invalid_argument("ramp_reconstruction: sign size mismatch");
  if (!constraints.vertex_weight.empty() &&
      constraints.vertex_weight.size() != mesh.vertices.size())
    throw std::invalid_argument("ramp_reconstruction: vertex_weight size mismatch");

  const Clock::time_point t0 = Clock::now();
  SurfaceOperatorResult r;
  r.mesh = mesh;
  SurfaceOperatorStats& st = r.stats;
  st.requested_steps = params.steps > 0 ? params.steps : 0;
  st.vertices_in = mesh.vertices.size();
  st.triangles_in = mesh.triangles.size();
  st.vertices_out = mesh.vertices.size();
  st.triangles_out = mesh.triangles.size();
  st.volume_before_mm3 = std::fabs(signed_volume(mesh));
  st.volume_after_operator_mm3 = st.volume_before_mm3;
  st.volume_after_mm3 = st.volume_before_mm3;
  if (params.steps <= 0) {
    st.wall_seconds = std::chrono::duration<double>(Clock::now() - t0).count();
    return r;  // OFF -> identity (byte-identical)
  }

  const double cos_tol = std::cos(params.terrace_angle_deg * 3.14159265358979323846 / 180.0);

  // ── REFINE ALONG THE TERRACE ───────────────────────────────────────────────
  // Points are added where the ramp has to be REPRESENTED: inside a terrace,
  // on edges too long to carry a slope. Splitting an edge at its midpoint and
  // re-triangulating is exactly volume-preserving (the new vertex lies on the
  // old edge and the old faces are subdivided in their own planes), so the
  // refinement itself moves no surface — the projection below is what moves it.
  // Parent pairs of every vertex refinement appends, in append order and across
  // every pass, so a new vertex's constraints can be INHERITED rather than
  // defaulted (see the propagation below — defaulting is a hole, not a detail).
  std::vector<std::pair<int, int>> born;
  if (params.target_edge_cells > 0.0 && constraints.cell_mm > 0.0) {
    const double target = params.target_edge_cells * constraints.cell_mm;
    for (int pass = 0; pass < params.max_refine_passes; ++pass) {
      const std::vector<Vec3> fn = face_normals_of(r.mesh);
      std::size_t nter = 0;
      const std::vector<int> label = segment_terraces(r.mesh, fn, cos_tol, nter);
      std::vector<std::size_t> tsize(nter, 0);
      for (const int l : label) tsize[static_cast<std::size_t>(l)]++;

      const std::vector<std::pair<int, int>> edges = mesh_edges(r.mesh);
      // An edge is refined when it is long AND interior to a fittable terrace:
      // both of its incident faces carry the same, big-enough label.
      std::vector<int> edge_label(edges.size(), -2);  // -2 unseen, -1 mixed
      for (std::size_t f = 0; f < r.mesh.triangles.size(); ++f)
        for (int c = 0; c < 3; ++c) {
          const int ei = edge_index(edges, r.mesh.triangles[f][c],
                                    r.mesh.triangles[f][(c + 1) % 3]);
          if (ei < 0) continue;
          int& el = edge_label[static_cast<std::size_t>(ei)];
          if (el == -2) el = label[f];
          else if (el != label[f]) el = -1;
        }

      std::vector<char> split(edges.size(), 0);
      std::size_t n_split = 0;
      for (std::size_t e = 0; e < edges.size(); ++e) {
        const int el = edge_label[e];
        if (el < 0 || tsize[static_cast<std::size_t>(el)] < params.min_terrace_faces)
          continue;
        const Vec3& a = r.mesh.vertices[static_cast<std::size_t>(edges[e].first)];
        const Vec3& b = r.mesh.vertices[static_cast<std::size_t>(edges[e].second)];
        if (norm(sub(b, a)) <= target) continue;
        split[e] = 1;
        ++n_split;
      }
      if (n_split == 0) break;
      r.mesh = refine_edges(r.mesh, split, edges, &born);
      st.refined_edges += n_split;
    }
  }
  st.vertices_out = r.mesh.vertices.size();
  st.triangles_out = r.mesh.triangles.size();

  // The trust region is anchored on the REFINED positions: a new vertex's box is
  // centred where refinement was born it, which is a point ON the exported
  // surface (the midpoint of one of its edges) and therefore carries the same
  // +/- half-cell uncertainty every exported vertex carries.
  const std::vector<Vec3> orig = r.mesh.vertices;
  const std::vector<Vec3> ref_normals = vertex_normals(r.mesh);
  const double radius = constraints.trust_voxels > 0.0
                            ? constraints.trust_voxels * constraints.cell_mm
                            : 0.0;

  // The constraint vectors were sized for the INPUT mesh. Refinement appended
  // vertices, so they are extended here rather than silently mismatching: a new
  // vertex inherits Both / weight 1 unless the caller sized them itself.
  // A NEW VERTEX INHERITS ITS PARENTS' CONSTRAINTS, CONSERVATIVELY. Defaulting an
  // appended vertex to `Both` / weight 1 would be a hole big enough to drive the
  // whole feature through: refinement splits edges INSIDE a terrace, so a terrace
  // sitting on a pinned load pad or under an unpainted part of the brush would
  // acquire a fresh, unconstrained vertex in the middle of it and the operator
  // would move it. The rules are the same ones C2 states for the original
  // vertices, applied to the pair:
  //   * Pinned if EITHER parent is pinned;
  //   * Pinned if the parents disagree OutwardOnly vs InwardOnly — both bind on
  //     this edge and the conflict resolves to "do nothing", never to a
  //     compromise nobody chose;
  //   * otherwise whichever parent is constrained, else Both.
  // The brush weight takes the MINIMUM of the two, so a new vertex is never
  // brushed harder than the softer of the points it was born between.
  SurfaceConstraints k = constraints;
  if (!k.sign.empty() || !k.vertex_weight.empty()) {
    const std::size_t n0 = mesh.vertices.size();
    if (!k.sign.empty()) k.sign.resize(orig.size(), TrustSign::Both);
    if (!k.vertex_weight.empty()) k.vertex_weight.resize(orig.size(), 1.0);
    for (std::size_t i = 0; i < born.size(); ++i) {
      const std::size_t v = n0 + i;
      if (v >= orig.size()) break;
      const std::size_t a = static_cast<std::size_t>(born[i].first);
      const std::size_t b = static_cast<std::size_t>(born[i].second);
      if (!k.sign.empty()) {
        const TrustSign sa = k.sign[a], sb = k.sign[b];
        TrustSign out;
        if (sa == TrustSign::Pinned || sb == TrustSign::Pinned)
          out = TrustSign::Pinned;
        else if ((sa == TrustSign::OutwardOnly && sb == TrustSign::InwardOnly) ||
                 (sa == TrustSign::InwardOnly && sb == TrustSign::OutwardOnly))
          out = TrustSign::Pinned;
        else if (sa != TrustSign::Both)
          out = sa;
        else
          out = sb;
        k.sign[v] = out;
      }
      if (!k.vertex_weight.empty())
        k.vertex_weight[v] = std::fmin(k.vertex_weight[a], k.vertex_weight[b]);
    }
  }

  ConstraintCounters counters;
  counters.resize(orig.size());
  std::vector<Vec3> delta(orig.size(), Vec3{0.0, 0.0, 0.0});
  std::vector<Vec3> proposed(orig.size());
  std::vector<Vec3> accum(orig.size());
  std::vector<double> accum_w(orig.size());

  for (int s = 0; s < params.steps; ++s) {
    const std::vector<Vec3> fn = face_normals_of(r.mesh);
    std::size_t nter = 0;
    const std::vector<int> label = segment_terraces(r.mesh, fn, cos_tol, nter);
    st.terraces = nter;

    // Group faces by terrace.
    std::vector<std::vector<int>> faces_of(nter);
    for (std::size_t f = 0; f < r.mesh.triangles.size(); ++f)
      faces_of[static_cast<std::size_t>(label[f])].push_back(static_cast<int>(f));

    // One-ring adjacency, for the fit neighbourhood.
    std::vector<std::vector<int>> ring(orig.size());
    for (const auto& t : r.mesh.triangles)
      for (int c = 0; c < 3; ++c) {
        auto& n = ring[static_cast<std::size_t>(t[c])];
        for (int o = 1; o < 3; ++o) {
          const int u = t[(c + o) % 3];
          if (std::find(n.begin(), n.end(), u) == n.end()) n.push_back(u);
        }
      }

    std::fill(accum.begin(), accum.end(), Vec3{0.0, 0.0, 0.0});
    std::fill(accum_w.begin(), accum_w.end(), 0.0);

    for (std::size_t T = 0; T < nter; ++T) {
      const std::vector<int>& F = faces_of[T];
      if (F.size() < params.min_terrace_faces) continue;

      // Terrace normal (area-weighted) and vertex set.
      Vec3 nT{0.0, 0.0, 0.0};
      std::vector<int> verts;
      double terrace_area = 0.0;
      for (const int f : F) {
        const auto& t = r.mesh.triangles[static_cast<std::size_t>(f)];
        const Vec3& p0 = r.mesh.vertices[static_cast<std::size_t>(t[0])];
        const Vec3& p1 = r.mesh.vertices[static_cast<std::size_t>(t[1])];
        const Vec3& p2 = r.mesh.vertices[static_cast<std::size_t>(t[2])];
        const Vec3 c = cross(sub(p1, p0), sub(p2, p0));
        nT = add(nT, c);
        terrace_area += 0.5 * norm(c);
        for (int q = 0; q < 3; ++q) verts.push_back(t[q]);
      }
      nT = normalized(nT);
      if (norm(nT) == 0.0) continue;
      std::sort(verts.begin(), verts.end());
      verts.erase(std::unique(verts.begin(), verts.end()), verts.end());

      // THE FIT NEIGHBOURHOOD reaches `fit_rings` beyond the terrace. That is
      // what makes this a RAMP and not a re-flattening: a tread is flat, so a
      // fit over the tread alone reproduces the tread. The extremes the ramp
      // runs between live on the risers and the adjacent treads, one ring out.
      std::vector<int> S = verts;
      for (int ringi = 0; ringi < params.fit_rings; ++ringi) {
        std::vector<int> grow = S;
        for (const int u : S)
          for (const int w : ring[static_cast<std::size_t>(u)]) grow.push_back(w);
        std::sort(grow.begin(), grow.end());
        grow.erase(std::unique(grow.begin(), grow.end()), grow.end());
        S.swap(grow);
      }

      // Local frame at the terrace centroid.
      Vec3 c{0.0, 0.0, 0.0};
      for (const int u : verts) c = add(c, r.mesh.vertices[static_cast<std::size_t>(u)]);
      c = scale(c, 1.0 / static_cast<double>(verts.size()));
      Vec3 e1 = std::fabs(nT.x) < 0.9 ? Vec3{1.0, 0.0, 0.0} : Vec3{0.0, 1.0, 0.0};
      e1 = normalized(sub(e1, scale(nT, dot(e1, nT))));
      const Vec3 e2 = cross(nT, e1);

      double A[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
      double rhs[3] = {0, 0, 0};
      double h_lo = 0.0, h_hi = 0.0;
      bool first = true;
      for (const int u : S) {
        const Vec3 d = sub(r.mesh.vertices[static_cast<std::size_t>(u)], c);
        const double x1 = dot(d, e1), x2 = dot(d, e2), hh = dot(d, nT);
        const double b[3] = {1.0, x1, x2};
        for (int i = 0; i < 3; ++i) {
          for (int j = 0; j < 3; ++j) A[i][j] += b[i] * b[j];
          rhs[i] += b[i] * hh;
        }
        if (first) { h_lo = h_hi = hh; first = false; }
        else { h_lo = std::fmin(h_lo, hh); h_hi = std::fmax(h_hi, hh); }
      }
      double coef[3] = {0, 0, 0};
      if (!solve3(A, rhs, coef)) continue;  // degenerate terrace: left alone

      const double face_w = terrace_area / static_cast<double>(verts.size());
      for (const int u : verts) {
        const Vec3 d = sub(r.mesh.vertices[static_cast<std::size_t>(u)], c);
        const double x1 = dot(d, e1), x2 = dot(d, e2), hh = dot(d, nT);
        double h_target = coef[0] + coef[1] * x1 + coef[2] * x2;
        if (params.clamp_to_envelope) {
          const double before = h_target;
          h_target = std::fmin(h_hi, std::fmax(h_lo, h_target));
          if (h_target != before) {
            st.envelope_clamped++;
            st.max_envelope_clamp_mm =
                std::fmax(st.max_envelope_clamp_mm, std::fabs(before - h_target));
          }
        }
        const Vec3 move = scale(nT, h_target - hh);
        accum[static_cast<std::size_t>(u)] =
            add(accum[static_cast<std::size_t>(u)], scale(move, face_w));
        accum_w[static_cast<std::size_t>(u)] += face_w;
      }
    }

    for (std::size_t v = 0; v < orig.size(); ++v) {
      const Vec3 move = accum_w[v] > 0.0 ? scale(accum[v], 1.0 / accum_w[v])
                                         : Vec3{0.0, 0.0, 0.0};
      proposed[v] = add(delta[v], move);
    }
    constrain_field(proposed, ref_normals, k, radius, delta, &counters);
    apply_field(orig, delta, r.mesh.vertices);
    st.applied_steps = s + 1;
  }

  st.volume_after_operator_mm3 = std::fabs(signed_volume(r.mesh));
  preserve_volume(orig, ref_normals, k, radius, st.volume_before_mm3, r.mesh,
                  delta, st);
  st.volume_after_mm3 = std::fabs(signed_volume(r.mesh));
  st.volume_drift_fraction =
      st.volume_before_mm3 > 0.0
          ? std::fabs(st.volume_after_mm3 - st.volume_before_mm3) / st.volume_before_mm3
          : 0.0;

  for (const Vec3& d : delta)
    st.max_displacement_mm = std::fmax(st.max_displacement_mm, norm(d));
  st.c1_clamped = ConstraintCounters::count(counters.ever_c1);
  st.c2_projected = ConstraintCounters::count(counters.ever_c2);
  st.pinned = ConstraintCounters::count(counters.ever_pinned);
  st.c1_would_violate = st.c1_clamped;
  st.max_c1_pullback_mm = counters.max_c1_pullback;
  st.max_unclamped_excursion_mm = counters.max_unclamped_excursion;
  st.wall_seconds = std::chrono::duration<double>(Clock::now() - t0).count();
  return r;
}

}  // namespace topopt
