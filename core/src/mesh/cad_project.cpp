// cad_project.cpp — projection of an exported surface onto the KNOWN analytic
// CAD surface (task 2026-08-06-cad-face-projection).
//
// See topopt/cad_project.hpp for why this is not smoothing. This file is
// OCCT-FREE: it reads `StepModel::mesh`, `StepModel::triangle_face` and
// `StepModel::faces` — plain data — exactly as src/io/face_tag.cpp does, so it
// builds in every configuration including the dependency-free iOS slices.

#include "topopt/cad_project.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <map>
#include <stdexcept>
#include <vector>

namespace topopt {

namespace {

Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
double dot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
double norm(const Vec3& a) { return std::sqrt(dot(a, a)); }

// Closest point on triangle (a,b,c) to p — Ericson, Real-Time Collision
// Detection §5.1.5. The same routine src/io/face_tag.cpp uses; duplicated rather
// than shared because face_tag.cpp's copy is file-local and PR-frozen.
Vec3 closest_point_triangle(const Vec3& p, const Vec3& a, const Vec3& b,
                            const Vec3& c) {
  const Vec3 ab = sub(b, a), ac = sub(c, a), ap = sub(p, a);
  const double d1 = dot(ab, ap), d2 = dot(ac, ap);
  if (d1 <= 0.0 && d2 <= 0.0) return a;

  const Vec3 bp = sub(p, b);
  const double d3 = dot(ab, bp), d4 = dot(ac, bp);
  if (d3 >= 0.0 && d4 <= d3) return b;

  const double vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
    const double v = d1 / (d1 - d3);
    return {a.x + v * ab.x, a.y + v * ab.y, a.z + v * ab.z};
  }

  const Vec3 cp = sub(p, c);
  const double d5 = dot(ab, cp), d6 = dot(ac, cp);
  if (d6 >= 0.0 && d5 <= d6) return c;

  const double vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
    const double w = d2 / (d2 - d6);
    return {a.x + w * ac.x, a.y + w * ac.y, a.z + w * ac.z};
  }

  const double va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    const double w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    return {b.x + w * (c.x - b.x), b.y + w * (c.y - b.y), b.z + w * (c.z - b.z)};
  }

  const double denom = 1.0 / (va + vb + vc);
  const double v = vb * denom, w = vc * denom;
  return {a.x + ab.x * v + ac.x * w, a.y + ab.y * v + ac.y * w,
          a.z + ab.z * v + ac.z * w};
}

double dist2_point_triangle(const Vec3& p, const Vec3& a, const Vec3& b,
                            const Vec3& c) {
  const Vec3 q = closest_point_triangle(p, a, b, c);
  const Vec3 d = sub(p, q);
  return dot(d, d);
}

// A uniform bin grid over the CAD tessellation, so "nearest face" is affordable
// on a mesh with hundreds of thousands of vertices. Same construction as the
// PR 299 harness's accelerator.
class FaceLocator {
 public:
  explicit FaceLocator(const TriangleMesh& mesh) : mesh_(&mesh) {
    if (mesh.triangles.empty()) return;
    Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
    for (const Vec3& v : mesh.vertices) {
      lo.x = std::fmin(lo.x, v.x); hi.x = std::fmax(hi.x, v.x);
      lo.y = std::fmin(lo.y, v.y); hi.y = std::fmax(hi.y, v.y);
      lo.z = std::fmin(lo.z, v.z); hi.z = std::fmax(hi.z, v.z);
    }
    origin_ = lo;
    const double ex = std::fmax(hi.x - lo.x, 1e-9);
    const double ey = std::fmax(hi.y - lo.y, 1e-9);
    const double ez = std::fmax(hi.z - lo.z, 1e-9);
    cell_ = std::fmax(std::cbrt(ex * ey * ez /
                                static_cast<double>(mesh.triangles.size())),
                      1e-6);
    nx_ = std::max(1, static_cast<int>(ex / cell_) + 1);
    ny_ = std::max(1, static_cast<int>(ey / cell_) + 1);
    nz_ = std::max(1, static_cast<int>(ez / cell_) + 1);
    bins_.assign(static_cast<std::size_t>(nx_) * ny_ * nz_, {});
    for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
      Vec3 tlo{1e300, 1e300, 1e300}, thi{-1e300, -1e300, -1e300};
      for (int k = 0; k < 3; ++k) {
        const Vec3& v =
            mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][k])];
        tlo.x = std::fmin(tlo.x, v.x); thi.x = std::fmax(thi.x, v.x);
        tlo.y = std::fmin(tlo.y, v.y); thi.y = std::fmax(thi.y, v.y);
        tlo.z = std::fmin(tlo.z, v.z); thi.z = std::fmax(thi.z, v.z);
      }
      for (int k = ck(tlo.z - origin_.z, nz_); k <= ck(thi.z - origin_.z, nz_); ++k)
        for (int j = ck(tlo.y - origin_.y, ny_); j <= ck(thi.y - origin_.y, ny_); ++j)
          for (int i = ck(tlo.x - origin_.x, nx_); i <= ck(thi.x - origin_.x, nx_); ++i)
            bins_[idx(i, j, k)].push_back(static_cast<int>(t));
    }
  }

  // Every CAD triangle within `radius` of p, plus the nearest one and its
  // distance. `out` is cleared first.
  void query(const Vec3& p, double radius, std::vector<int>& out,
             double& out_best, int& out_best_tri) const {
    out.clear();
    out_best = std::numeric_limits<double>::infinity();
    out_best_tri = -1;
    if (!mesh_ || mesh_->triangles.empty()) return;
    // Grow the search box until the current best is provably inside it, so the
    // nearest triangle is exact and not merely "nearest within one box".
    double r = std::fmax(radius, cell_);
    double best2 = std::numeric_limits<double>::infinity();
    for (int iter = 0; iter < 64; ++iter) {
      out.clear();
      best2 = std::numeric_limits<double>::infinity();
      out_best_tri = -1;
      const double r2 = radius * radius;
      for (int k = ck(p.z - r - origin_.z, nz_); k <= ck(p.z + r - origin_.z, nz_); ++k)
        for (int j = ck(p.y - r - origin_.y, ny_); j <= ck(p.y + r - origin_.y, ny_); ++j)
          for (int i = ck(p.x - r - origin_.x, nx_); i <= ck(p.x + r - origin_.x, nx_); ++i)
            for (const int t : bins_[idx(i, j, k)]) {
              const auto& tr = mesh_->triangles[static_cast<std::size_t>(t)];
              const double d2 = dist2_point_triangle(
                  p, mesh_->vertices[static_cast<std::size_t>(tr[0])],
                  mesh_->vertices[static_cast<std::size_t>(tr[1])],
                  mesh_->vertices[static_cast<std::size_t>(tr[2])]);
              if (d2 < best2) { best2 = d2; out_best_tri = t; }
              if (d2 <= r2) out.push_back(t);
            }
      if (best2 <= r * r) break;
      r *= 2.0;
    }
    out_best = std::sqrt(best2);
  }

  // Closest point on the tessellated patch of ONE face, and its distance.
  Vec3 closest_on_face(const Vec3& p, const std::vector<int>& face_tris,
                       double& out_dist) const {
    Vec3 best{p};
    double best2 = std::numeric_limits<double>::infinity();
    for (const int t : face_tris) {
      const auto& tr = mesh_->triangles[static_cast<std::size_t>(t)];
      const Vec3 q = closest_point_triangle(
          p, mesh_->vertices[static_cast<std::size_t>(tr[0])],
          mesh_->vertices[static_cast<std::size_t>(tr[1])],
          mesh_->vertices[static_cast<std::size_t>(tr[2])]);
      const Vec3 d = sub(p, q);
      const double d2 = dot(d, d);
      if (d2 < best2) { best2 = d2; best = q; }
    }
    out_dist = std::sqrt(best2);
    return best;
  }

 private:
  int ck(double d, int n) const {
    const int c = static_cast<int>(std::floor(d / cell_));
    return c < 0 ? 0 : (c >= n ? n - 1 : c);
  }
  std::size_t idx(int i, int j, int k) const {
    return static_cast<std::size_t>(k) * ny_ * nx_ +
           static_cast<std::size_t>(j) * nx_ + static_cast<std::size_t>(i);
  }
  const TriangleMesh* mesh_ = nullptr;
  Vec3 origin_{0, 0, 0};
  double cell_ = 1.0;
  int nx_ = 1, ny_ = 1, nz_ = 1;
  std::vector<std::vector<int>> bins_;
};

Vec3 project_on_plane(const Vec3& p, const Vec3& o, const Vec3& n) {
  const double s = dot(sub(p, o), n);
  return {p.x - s * n.x, p.y - s * n.y, p.z - s * n.z};
}

// Radial projection onto the cylinder of radius R about (a, d), d unit.
// Degenerate when p sits exactly on the axis; the caller checks.
bool project_on_cylinder(const Vec3& p, const Vec3& a, const Vec3& d, double R,
                         Vec3& out) {
  const Vec3 w = sub(p, a);
  const double t = dot(w, d);
  const Vec3 foot{a.x + t * d.x, a.y + t * d.y, a.z + t * d.z};
  const Vec3 rad = sub(p, foot);
  const double r = norm(rad);
  if (r < 1e-9) return false;  // on the axis: the radial direction is undefined
  const double s = R / r;
  out = {foot.x + s * rad.x, foot.y + s * rad.y, foot.z + s * rad.z};
  return true;
}

double radius_about_axis(const Vec3& p, const Vec3& a, const Vec3& d) {
  const Vec3 w = sub(p, a);
  const double t = dot(w, d);
  const Vec3 rad{w.x - t * d.x, w.y - t * d.y, w.z - t * d.z};
  return norm(rad);
}

}  // namespace

CadProjectOptions cad_project_options_for_grid(double voxel_spacing_mm) {
  CadProjectOptions o;
  o.enabled = false;
  // ONE VOXEL. MEASURED, not chosen. S1's distance-to-CAD histogram on the
  // maintainer's own part (evidence/2026-08-06-cad-face-projection/
  // s1_histogram.csv) puts 82.8% of the exported vertices inside one voxel of
  // the CAD — spread right across that band, 27.9% / 17.3% / 22.8% / 14.8% in
  // the four quarter-voxel bins — and then FALLS OFF A CLIFF: the next bin holds
  // 1.7% and the four after it under 1% each. The valley is between 1.0 and 2.5
  // voxels, so one voxel sits in empty space and half a voxel would cut the
  // retained-CAD population itself in half. That band is what the pipeline
  // actually produces: the exported surface is the 0.5 level set of the FILTERED
  // density resampled 2x, so a retained face is displaced by the voxel
  // quantisation (<= half a voxel) PLUS the density filter's inward pull, and
  // one voxel is where that combined population ends.
  o.tolerance_mm = 1.0 * voxel_spacing_mm;
  // The motion guard matches the attribution band for the same reason: a vertex
  // attributed at distance d needs to move about d to reach its face, so a guard
  // below the band would refuse exactly the vertices the band admitted. It stays
  // a guard, not a formality — anything beyond one voxel is a misattribution.
  o.max_move_mm = 1.0 * voxel_spacing_mm;
  // 0.10 voxel. A second face of a different kind this close means the vertex is
  // on a CAD edge and could honestly belong to either surface.
  o.ambiguity_band_mm = 0.10 * voxel_spacing_mm;
  o.voxel_mm = voxel_spacing_mm;
  return o;
}

CadAttribution attribute_to_cad_faces(const TriangleMesh& mesh,
                                      const StepModel& model,
                                      const CadProjectOptions& opts) {
  if (opts.tolerance_mm <= 0.0)
    throw std::invalid_argument(
        "attribute_to_cad_faces: tolerance_mm must be > 0 (it is the "
        "attribution band, in mm; derive it from the voxel spacing with "
        "cad_project_options_for_grid)");

  CadAttribution att;
  const std::size_t nv = mesh.vertices.size();
  att.face_of_vertex.assign(nv, -1);
  att.distance_mm.assign(nv, 0.0);
  att.seam.assign(nv, 0);
  att.ambiguous_flag.assign(nv, 0);
  if (nv == 0 || model.mesh.triangles.empty()) {
    att.unattributed = nv;
    return att;
  }
  if (model.triangle_face.size() != model.mesh.triangles.size())
    throw std::invalid_argument(
        "attribute_to_cad_faces: model.triangle_face is not parallel to "
        "model.mesh.triangles");

  const FaceLocator loc(model.mesh);
  std::vector<int> near;
  for (std::size_t i = 0; i < nv; ++i) {
    double best = 0.0;
    int best_tri = -1;
    loc.query(mesh.vertices[i], opts.tolerance_mm, near, best, best_tri);
    att.distance_mm[i] = best;
    if (best_tri < 0 || best > opts.tolerance_mm) {
      ++att.unattributed;
      continue;
    }
    const int f = model.triangle_face[static_cast<std::size_t>(best_tri)];
    if (f < 0 || f >= model.face_count) {
      ++att.unattributed;
      continue;
    }
    const StepSurfaceKind kind = model.faces[static_cast<std::size_t>(f)].kind;

    // AMBIGUITY: a second face of a DIFFERENT kind within the band. Recomputing
    // the per-candidate distance here (rather than trusting the radius filter)
    // keeps the band exact.
    bool ambiguous = false;
    for (const int t : near) {
      const int g = model.triangle_face[static_cast<std::size_t>(t)];
      if (g < 0 || g >= model.face_count || g == f) continue;
      if (model.faces[static_cast<std::size_t>(g)].kind == kind) continue;
      const auto& tr = model.mesh.triangles[static_cast<std::size_t>(t)];
      const double d = std::sqrt(dist2_point_triangle(
          mesh.vertices[i], model.mesh.vertices[static_cast<std::size_t>(tr[0])],
          model.mesh.vertices[static_cast<std::size_t>(tr[1])],
          model.mesh.vertices[static_cast<std::size_t>(tr[2])]));
      if (d - best <= opts.ambiguity_band_mm) { ambiguous = true; break; }
    }
    if (ambiguous) {
      att.ambiguous_flag[i] = 1;
      ++att.ambiguous;
      ++att.unattributed;
      continue;
    }

    // THE ANALYTIC RE-CHECK, and it is not a formality. Nearest-TRIANGLE is a
    // test against the face's tessellated PATCH, which is bounded; a vertex just
    // past the end of a partial cylinder can be a hair from the patch's rim and
    // a whole voxel from the cylinder itself. Attributing it would then project
    // it a long way sideways. So a vertex is attributed only if it is within the
    // SAME tolerance of the face's ANALYTIC surface, which is what it will
    // actually be moved onto. MEASURED on the maintainer's part: this withholds
    // the vertices that PR-quality nearest-triangle attribution alone would have
    // handed to the motion guard, and it is why every moved vertex lands exactly
    // on nominal rather than nearly so.
    double analytic = best;
    if (kind == StepSurfaceKind::Plane) {
      const StepFaceInfo& fi = model.faces[static_cast<std::size_t>(f)];
      if (norm(fi.plane_normal) > 0.5)
        analytic = std::fabs(dot(sub(mesh.vertices[i], fi.plane_origin),
                                 fi.plane_normal));
    } else if (kind == StepSurfaceKind::Cylinder) {
      const StepFaceInfo& fi = model.faces[static_cast<std::size_t>(f)];
      if (norm(fi.axis_dir) > 0.5 && fi.cylinder_radius_mm > 0.0)
        analytic = std::fabs(radius_about_axis(mesh.vertices[i], fi.axis_point,
                                               fi.axis_dir) -
                             fi.cylinder_radius_mm);
    }
    if (analytic > opts.tolerance_mm) {
      ++att.off_analytic_surface;
      ++att.unattributed;
      continue;
    }

    att.face_of_vertex[i] = f;
    ++att.attributed;
    switch (kind) {
      case StepSurfaceKind::Plane: ++att.n_plane; break;
      case StepSurfaceKind::Cylinder: ++att.n_cylinder; break;
      default: ++att.n_other; break;
    }
  }

  // SEAM: attributed, with a mesh-edge neighbour that is unattributed or on a
  // different face.
  for (const auto& tr : mesh.triangles) {
    for (int e = 0; e < 3; ++e) {
      const std::size_t a = static_cast<std::size_t>(tr[e]);
      const std::size_t b = static_cast<std::size_t>(tr[(e + 1) % 3]);
      if (att.face_of_vertex[a] == att.face_of_vertex[b]) continue;
      if (att.face_of_vertex[a] >= 0) att.seam[a] = 1;
      if (att.face_of_vertex[b] >= 0) att.seam[b] = 1;
    }
  }
  for (std::size_t i = 0; i < nv; ++i)
    if (att.seam[i]) ++att.n_seam;

  return att;
}

TriangleMesh project_onto_cad_faces(const TriangleMesh& mesh,
                                    const StepModel& model,
                                    const CadProjectOptions& opts,
                                    const CadAttribution& att,
                                    CadProjectionStats* out_stats) {
  TriangleMesh out = mesh;
  CadProjectionStats st;
  const std::size_t nv = mesh.vertices.size();
  if (att.face_of_vertex.size() != nv)
    throw std::invalid_argument(
        "project_onto_cad_faces: attribution is not parallel to the mesh "
        "vertices");

  st.move_mm.assign(nv, 0.0);
  st.reverted.assign(nv, 0);

  // The tessellated patch of each face that any vertex was attributed to. The
  // seam constraint needs it, and so does the over-half-a-voxel diagnostic, so
  // every attributed face gets one.
  std::map<int, std::vector<int>> patch;
  for (std::size_t i = 0; i < nv; ++i) {
    const int f = att.face_of_vertex[i];
    if (f >= 0) patch[f];
  }
  if (!patch.empty()) {
    for (std::size_t t = 0; t < model.triangle_face.size(); ++t) {
      const auto it = patch.find(model.triangle_face[t]);
      if (it != patch.end()) it->second.push_back(static_cast<int>(t));
    }
  }
  const FaceLocator loc(model.mesh);

  // Is point q still ON face f? Asked by NEAREST CAD TRIANGLE rather than by a
  // distance threshold, because the two kinds have different exactness: a planar
  // patch contains its analytic projection exactly, while a tessellated cylinder
  // is chordal, so an EXACT cylinder point always sits a sagitta OUTSIDE its own
  // facets. A distance test would therefore reject every correct cylinder
  // projection; "whose facet is nearest" does not.
  std::vector<int> scratch;
  auto still_on_face = [&](const Vec3& q, int f) {
    double d = 0.0;
    int t = -1;
    loc.query(q, 0.0, scratch, d, t);
    if (t < 0) return false;
    return model.triangle_face[static_cast<std::size_t>(t)] == f;
  };

  std::vector<char> moved(nv, 0);
  // Which of the moved vertices were carried by the transition band rather than
  // projected. The fold guard spends these first — reverting one costs nothing.
  std::vector<char> blended(nv, 0);
  // How many vertices the PROJECTION itself moved. Counted here rather than read
  // off CadProjectionStats::moved, which is only totalled after the fold guard
  // has had its say and would read 0 while the band below still needs to know.
  std::size_t n_projected = 0;
  double sum2 = 0.0;
  for (std::size_t i = 0; i < nv; ++i) {
    const int f = att.face_of_vertex[i];
    if (f < 0) { ++st.left_unattributed; continue; }
    const StepFaceInfo& info = model.faces[static_cast<std::size_t>(f)];
    const Vec3 p = mesh.vertices[i];
    Vec3 q = p;
    bool have = false;
    if (info.kind == StepSurfaceKind::Plane && opts.project_planes) {
      if (norm(info.plane_normal) > 0.5) {
        q = project_on_plane(p, info.plane_origin, info.plane_normal);
        have = true;
      }
    } else if (info.kind == StepSurfaceKind::Cylinder && opts.project_cylinders) {
      if (norm(info.axis_dir) > 0.5 && info.cylinder_radius_mm > 0.0)
        have = project_on_cylinder(p, info.axis_point, info.axis_dir,
                                   info.cylinder_radius_mm, q);
    } else {
      // kind Other, or the caller disabled this kind: no analytic surface to
      // project onto, so the vertex is LEFT ALONE rather than approximated.
      ++st.left_other;
      continue;
    }
    if (!have) { ++st.left_other; continue; }

    // SEAM CONSTRAINT: hold the vertex inside its own face's tessellated patch,
    // so it can never slide across a CAD edge onto a surface it does not belong
    // to. For a planar face the patch IS the exact surface and its rim IS the
    // exact CAD boundary, so this is exact there; for a cylinder the rim is
    // chordal, within the import's linear deflection.
    if (att.seam[i] && !still_on_face(q, f)) {
      const auto it = patch.find(f);
      if (it != patch.end() && !it->second.empty()) {
        double d_patch = 0.0;
        q = loc.closest_on_face(q, it->second, d_patch);
        // The clamp put the vertex on the face's TESSELLATED patch, which is not
        // the same thing as the face's ANALYTIC surface: a tessellated cylinder
        // is chordal, and even a planar patch's vertices sit a chord's-width off
        // the nominal plane (MEASURED on the maintainer's part: 9.240e-04 mm).
        // Left there, the seam would hand back at the rim exactly the exactness
        // the projection just bought. So the analytic projection is RE-APPLIED
        // to the clamped point. It cannot undo the clamp: projecting onto a
        // plane moves the point along the normal, and onto a cylinder along the
        // radius — neither changes where the point sits within the face's own
        // extent.
        if (info.kind == StepSurfaceKind::Cylinder) {
          Vec3 exact{0, 0, 0};
          if (project_on_cylinder(q, info.axis_point, info.axis_dir,
                                  info.cylinder_radius_mm, exact))
            q = exact;
        } else {
          q = project_on_plane(q, info.plane_origin, info.plane_normal);
        }
        ++st.seam_constrained;
      }
    }

    const double move = norm(sub(q, p));
    if (move > opts.max_move_mm) {
      // The attribution is wrong, not the CAD. Leave it and count it.
      ++st.refused_by_guard;
      continue;
    }
    // The BLOCKED-STOP question, asked of every vertex that exceeds half a
    // voxel: is the analytic projection still ON the patch of the face this
    // vertex was attributed to? A YES says the attribution is right and the
    // distance is the density filter's inward pull.
    if (opts.voxel_mm > 0.0 && move > 0.5 * opts.voxel_mm) {
      ++st.moved_over_half_voxel;
      if (still_on_face(q, f)) ++st.over_half_still_on_own_patch;
    }

    out.vertices[i] = q;
    st.move_mm[i] = move;
    moved[i] = 1;
    ++n_projected;
  }

  // ── the SEAM TRANSITION BAND ───────────────────────────────────────────────
  // Carry the projection's displacement outward into the optimizer-cut surface,
  // ring by ring, with a linearly decaying weight, so the mesh arrives at a
  // projected CAD face continuously rather than stepping onto it. Only vertices
  // that were NOT attributed move: every exact position stays exact.
  if (opts.seam_blend_rings > 0 && n_projected > 0) {
    std::vector<std::vector<int>> adj(nv);
    for (const auto& tr : mesh.triangles)
      for (int e = 0; e < 3; ++e) {
        const int a = tr[e], b = tr[(e + 1) % 3];
        adj[static_cast<std::size_t>(a)].push_back(b);
        adj[static_cast<std::size_t>(b)].push_back(a);
      }

    // ring[v]: 0 for a moved (projected) vertex, r for an unattributed vertex r
    // edges away from one, -1 for "outside the band".
    std::vector<int> ring(nv, -1);
    std::vector<std::size_t> frontier;
    for (std::size_t i = 0; i < nv; ++i)
      if (moved[i]) { ring[i] = 0; frontier.push_back(i); }

    const int R = opts.seam_blend_rings;
    std::vector<Vec3> disp(nv, Vec3{0.0, 0.0, 0.0});
    for (std::size_t i = 0; i < nv; ++i)
      if (moved[i]) disp[i] = sub(out.vertices[i], mesh.vertices[i]);

    for (int r = 1; r <= R; ++r) {
      std::vector<std::size_t> next;
      for (const std::size_t v : frontier)
        for (const int nb_i : adj[v]) {
          const std::size_t u = static_cast<std::size_t>(nb_i);
          // An attributed vertex is EXACT — never carried. A vertex already in
          // the band keeps its (nearer) ring.
          if (ring[u] >= 0 || att.face_of_vertex[u] >= 0) continue;
          ring[u] = r;
          next.push_back(u);
        }
      // Average the displacement of the neighbours one ring closer in, then
      // taper it: ring r of R keeps (R + 1 - r)/(R + 1).
      const double w = static_cast<double>(R + 1 - r) / static_cast<double>(R + 1);
      for (const std::size_t u : next) {
        Vec3 acc{0.0, 0.0, 0.0};
        int n = 0;
        for (const int nb_i : adj[u]) {
          const std::size_t s = static_cast<std::size_t>(nb_i);
          if (ring[s] < 0 || ring[s] >= r) continue;
          acc.x += disp[s].x; acc.y += disp[s].y; acc.z += disp[s].z;
          ++n;
        }
        if (n == 0) continue;
        const double inv = w / static_cast<double>(n);
        disp[u] = {acc.x * inv, acc.y * inv, acc.z * inv};
      }
      frontier.swap(next);
    }

    for (std::size_t i = 0; i < nv; ++i) {
      if (ring[i] <= 0) continue;
      const double d = norm(disp[i]);
      if (d <= 0.0) continue;
      out.vertices[i] = {mesh.vertices[i].x + disp[i].x,
                         mesh.vertices[i].y + disp[i].y,
                         mesh.vertices[i].z + disp[i].z};
      st.move_mm[i] = d;
      moved[i] = 1;  // so the seam statistics below see the band, not a cliff
      blended[i] = 1;
      ++st.blended;
      if (d > st.max_blend_mm) st.max_blend_mm = d;
    }
  }

  // ── THE FOLD GUARD ─────────────────────────────────────────────────────────
  // MEASURED, not anticipated. Two separate things fold this mesh, and they cost
  // very different amounts to fix, so the guard treats them differently.
  //
  //   * THE TRANSITION BAND. It moves optimizer-cut vertices, and averaged
  //     displacements over a terraced surface can push a facet through itself.
  //     Reverting one of these is FREE: an optimizer-cut vertex has no correct
  //     position to lose. So the guard spends this currency first, exhaustively.
  //   * THE PROJECTION ITSELF. Where an oblique CAD face was exported as a
  //     staircase, flattening every vertex onto its plane collapses the risers,
  //     and a collapsed riser can fold. Reverting one of these COSTS the
  //     exactness this whole operation exists to deliver, so the guard only
  //     spends it after the free currency is gone — and counts every one.
  //
  // The moved set only ever SHRINKS (a reverted vertex is never moved again), so
  // both loops terminate; the pass budgets are backstops, and whatever survives
  // them is COUNTED below rather than assumed away.
  auto tri_normal_of = [](const TriangleMesh& m, std::size_t t) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(m.triangles[t][0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(m.triangles[t][1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(m.triangles[t][2])];
    const Vec3 u = sub(b, a), v = sub(c, a);
    return Vec3{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z,
                u.x * v.y - u.y * v.x};
  };
  // ── THE WELD GUARD, run in the SAME loop as the fold guard ─────────────────
  //
  // ★ A SECOND WAY TO DESTROY THE MESH, and the fold guard is structurally
  // blind to it (task 2026-08-06-arm-projection-and-void-check).
  //
  // The fold guard reasons PER TRIANGLE, about normals and area. This damage is
  // PER MESH, about vertex IDENTITY. A terrace riser stands perpendicular to
  // the face it approximates, so its two endpoints share their in-plane
  // position exactly and differ only along the normal; projecting both onto
  // that plane puts them on the SAME POINT. Nothing inverts — the collapsed
  // riser reads dot == 0, which the loop below skips ON PURPOSE — and no
  // triangle becomes degenerate, because the two vertices belong to different
  // triangles. What happens instead is that the two surface sheets the riser
  // separated get welded together, and the exported file stops being
  // watertight: on the demo l-bracket at resolution 48, 293 edges ended up
  // shared by four triangles.
  //
  // EXACT EQUALITY IS THE RIGHT TEST, not a tolerance, and that is a property
  // of the geometry rather than a convenience: the two endpoints' in-plane
  // coordinates are IDENTICAL before projection and are left untouched by it,
  // so a genuine weld is exact in double and a merely-near-miss is not. A
  // tolerance would revert vertices that were never going to collide.
  //
  // The remedy is the fold guard's own: put a vertex back. Same currency order
  // — band vertices are free and are spent first — and the same fixed-point
  // loop, because reverting one vertex can expose another collision.
  //
  // The LOWEST INDEX KEEPS ITS PROJECTED POSITION and the rest are reverted.
  // Deterministic and order-independent, so the receipt stays byte-reproducible
  // (which five separate tests require of it).
  if (opts.fold_guard) {
    // `free_only` restricts reverting to band vertices (phase 1).
    auto run_guard = [&](bool free_only) {
      for (int pass = 0; pass < 64; ++pass) {
        std::vector<char> revert(nv, 0);
        std::size_t folded = 0, revertible = 0;
        for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
          bool any = false;
          for (int k = 0; k < 3; ++k)
            if (moved[static_cast<std::size_t>(mesh.triangles[t][k])]) any = true;
          if (!any) continue;
          const Vec3 nb = tri_normal_of(mesh, t);
          const Vec3 na = tri_normal_of(out, t);
          // A triangle that merely COLLAPSED reads dot == 0 and is left alone
          // HERE: a flattened riser has no area and nothing to fold through.
          // The weld scan below is what catches the harm it actually does.
          if (dot(nb, na) >= 0.0) continue;
          ++folded;
          for (int k = 0; k < 3; ++k) {
            const std::size_t v = static_cast<std::size_t>(mesh.triangles[t][k]);
            if (!moved[v]) continue;
            if (free_only && !blended[v]) continue;
            revert[v] = 1;
            ++revertible;
          }
        }
        // THE WELD SCAN. Group vertices by their OUTPUT position; any group of
        // more than one is a weld about to happen. Only a MOVED vertex can be
        // reverted, and an unmoved one always keeps its place — so a moved
        // vertex landing on an unmoved one is reverted too, which the "lowest
        // index wins" rule would not by itself guarantee.
        std::size_t welds = 0;
        {
          std::map<std::array<double, 3>, std::size_t> first_at;
          for (std::size_t i = 0; i < nv; ++i) {
            const std::array<double, 3> key{out.vertices[i].x, out.vertices[i].y,
                                            out.vertices[i].z};
            const auto it = first_at.find(key);
            if (it == first_at.end()) {
              first_at.emplace(key, i);
              continue;
            }
            ++welds;
            // Prefer to revert the one that MOVED; if both moved, revert the
            // later index and leave the earlier one exact.
            const std::size_t keep = it->second;
            std::size_t drop = i;
            if (!moved[i] && moved[keep]) drop = keep;
            if (!moved[drop]) continue;  // neither moved: pre-existing, not ours
            if (free_only && !blended[drop]) continue;
            if (!revert[drop]) {
              revert[drop] = 1;
              ++revertible;
            }
          }
        }
        if (pass == 0 && !free_only) st.weld_collisions_found = welds;
        if ((folded == 0 && welds == 0) || revertible == 0) break;
        ++st.fold_guard_passes;
        for (std::size_t i = 0; i < nv; ++i) {
          if (!revert[i]) continue;
          const bool was_weld_only = (folded == 0);
          out.vertices[i] = mesh.vertices[i];
          st.move_mm[i] = 0.0;
          moved[i] = 0;
          if (blended[i]) { blended[i] = 0; ++st.reverted_band; --st.blended; }
          else {
            st.reverted[i] = 1;
            if (was_weld_only) ++st.reverted_by_weld_guard;
            else ++st.reverted_by_fold_guard;
          }
        }
      }
    };
    run_guard(/*free_only=*/true);
    run_guard(/*free_only=*/false);
  }

  // Counted whether or not the guard ran, so "with the guard" and "without it"
  // are the same measurement rather than two different ones.
  for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
    const Vec3 nb = tri_normal_of(mesh, t);
    const Vec3 na = tri_normal_of(out, t);
    if (dot(nb, na) < 0.0) {
      ++st.inverted_triangles_remaining;
      st.inverted_area_mm2 += 0.5 * norm(na);
    }
  }

  for (std::size_t i = 0; i < nv; ++i) {
    if (!moved[i] || blended[i]) continue;
    const double move = st.move_mm[i];
    ++st.moved;
    const int f = att.face_of_vertex[i];
    if (f >= 0 &&
        model.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Plane)
      ++st.moved_plane;
    else
      ++st.moved_cylinder;
    sum2 += move * move;
    if (move > st.max_move_mm) st.max_move_mm = move;
  }
  if (st.moved > 0)
    st.rms_move_mm = std::sqrt(sum2 / static_cast<double>(st.moved));

  // ── the seam, measured two ways ────────────────────────────────────────────
  // The STEP at every moved/unmoved junction (how far the surface shifted there)
  // and, because a shift is not a crease, the CHANGE OF DIHEDRAL ANGLE at the
  // same edges — beside the dihedral of the whole mesh, before and after, which
  // is the yardstick that says whether the change is visible next to the
  // terracing already present.
  auto face_normals = [](const TriangleMesh& m) {
    std::vector<Vec3> n(m.triangles.size());
    for (std::size_t t = 0; t < m.triangles.size(); ++t) {
      const Vec3& a = m.vertices[static_cast<std::size_t>(m.triangles[t][0])];
      const Vec3& b = m.vertices[static_cast<std::size_t>(m.triangles[t][1])];
      const Vec3& c = m.vertices[static_cast<std::size_t>(m.triangles[t][2])];
      const Vec3 u = sub(b, a), v = sub(c, a);
      Vec3 f{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z,
             u.x * v.y - u.y * v.x};
      const double L = norm(f);
      if (L > 0.0) { f.x /= L; f.y /= L; f.z /= L; }
      n[t] = f;
    }
    return n;
  };
  const std::vector<Vec3> nb = face_normals(mesh);
  const std::vector<Vec3> na = face_normals(out);

  std::map<std::pair<int, int>, std::pair<int, int>> edge_tris;
  for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
    for (int e = 0; e < 3; ++e) {
      int a = mesh.triangles[t][e], b = mesh.triangles[t][(e + 1) % 3];
      if (a > b) std::swap(a, b);
      auto& slot = edge_tris[{a, b}];
      if (slot.first == 0 && slot.second == 0) slot.first = static_cast<int>(t) + 1;
      else if (slot.second == 0) slot.second = static_cast<int>(t) + 1;
    }
  }
  auto angle_deg = [](const Vec3& p, const Vec3& q) {
    double c = dot(p, q);
    c = c > 1.0 ? 1.0 : (c < -1.0 ? -1.0 : c);
    return std::acos(c) * 180.0 / 3.14159265358979323846;
  };

  double seam_sum2 = 0.0, seam_dih2 = 0.0;
  double all_b2 = 0.0, all_a2 = 0.0;
  std::size_t all_n = 0;
  for (const auto& kv : edge_tris) {
    if (kv.second.first == 0 || kv.second.second == 0) continue;
    const std::size_t t0 = static_cast<std::size_t>(kv.second.first - 1);
    const std::size_t t1 = static_cast<std::size_t>(kv.second.second - 1);
    const double db = angle_deg(nb[t0], nb[t1]);
    const double da = angle_deg(na[t0], na[t1]);
    all_b2 += db * db;
    all_a2 += da * da;
    ++all_n;
    if (db >= 45.0) ++st.sharp45_before;
    if (da >= 45.0) ++st.sharp45_after;
    if (db >= 60.0) ++st.sharp60_before;
    if (da >= 60.0) ++st.sharp60_after;
    if (db >= 90.0) ++st.sharp90_before;
    if (da >= 90.0) ++st.sharp90_after;
    const bool became_sharp = db < 45.0 && da >= 60.0;
    if (became_sharp) ++st.newly_sharp;
    const std::size_t a = static_cast<std::size_t>(kv.first.first);
    const std::size_t b = static_cast<std::size_t>(kv.first.second);
    if (moved[a] == moved[b]) continue;
    if (became_sharp) ++st.newly_sharp_at_seam;
    const std::size_t m = moved[a] ? a : b;
    const double step = norm(sub(out.vertices[m], mesh.vertices[m]));
    seam_sum2 += step * step;
    ++st.seam_edges;
    if (step > st.max_seam_step_mm) st.max_seam_step_mm = step;
    const double change = std::fabs(da - db);
    seam_dih2 += change * change;
    if (change > st.max_seam_dihedral_change_deg)
      st.max_seam_dihedral_change_deg = change;
  }
  if (st.seam_edges > 0) {
    const double n = static_cast<double>(st.seam_edges);
    st.rms_seam_step_mm = std::sqrt(seam_sum2 / n);
    st.rms_seam_dihedral_change_deg = std::sqrt(seam_dih2 / n);
  }
  st.total_edges = all_n;
  if (all_n > 0) {
    st.rms_dihedral_before_deg = std::sqrt(all_b2 / static_cast<double>(all_n));
    st.rms_dihedral_after_deg = std::sqrt(all_a2 / static_cast<double>(all_n));
  }

  if (out_stats) *out_stats = st;
  return out;
}

std::vector<BoreRoundness> measure_bores(
    const TriangleMesh& mesh, const StepModel& model, const CadAttribution& att,
    const std::vector<char>* exclude,
    std::vector<std::size_t>* out_excluded_per_face) {
  if (out_excluded_per_face)
    out_excluded_per_face->assign(static_cast<std::size_t>(model.face_count), 0);
  std::map<int, std::vector<double>> radii;
  for (std::size_t i = 0; i < mesh.vertices.size(); ++i) {
    const int f = att.face_of_vertex[i];
    if (f < 0) continue;
    const StepFaceInfo& info = model.faces[static_cast<std::size_t>(f)];
    if (info.kind != StepSurfaceKind::Cylinder) continue;
    if (norm(info.axis_dir) < 0.5) continue;
    if (exclude && i < exclude->size() && (*exclude)[i]) {
      if (out_excluded_per_face)
        (*out_excluded_per_face)[static_cast<std::size_t>(f)]++;
      continue;
    }
    radii[f].push_back(
        radius_about_axis(mesh.vertices[i], info.axis_point, info.axis_dir));
  }
  std::vector<BoreRoundness> out;
  out.reserve(radii.size());
  for (const auto& kv : radii) {
    const StepFaceInfo& info =
        model.faces[static_cast<std::size_t>(kv.first)];
    BoreRoundness b;
    b.face_id = kv.first;
    b.nominal_radius_mm = info.cylinder_radius_mm;
    b.vertices = kv.second.size();
    b.min_mm = *std::min_element(kv.second.begin(), kv.second.end());
    b.max_mm = *std::max_element(kv.second.begin(), kv.second.end());
    double s = 0.0, s2 = 0.0;
    for (const double r : kv.second) {
      s += r;
      const double e = r - b.nominal_radius_mm;
      s2 += e * e;
    }
    b.mean_mm = s / static_cast<double>(kv.second.size());
    b.rms_error_mm = std::sqrt(s2 / static_cast<double>(kv.second.size()));
    b.out_of_roundness_mm = b.max_mm - b.min_mm;
    out.push_back(b);
  }
  return out;
}

std::vector<FaceFlatness> measure_flats(
    const TriangleMesh& mesh, const StepModel& model, const CadAttribution& att,
    const std::vector<char>* exclude,
    std::vector<std::size_t>* out_excluded_per_face) {
  if (out_excluded_per_face)
    out_excluded_per_face->assign(static_cast<std::size_t>(model.face_count), 0);
  std::map<int, std::vector<double>> dev;
  for (std::size_t i = 0; i < mesh.vertices.size(); ++i) {
    const int f = att.face_of_vertex[i];
    if (f < 0) continue;
    const StepFaceInfo& info = model.faces[static_cast<std::size_t>(f)];
    if (info.kind != StepSurfaceKind::Plane) continue;
    if (norm(info.plane_normal) < 0.5) continue;
    if (exclude && i < exclude->size() && (*exclude)[i]) {
      if (out_excluded_per_face)
        (*out_excluded_per_face)[static_cast<std::size_t>(f)]++;
      continue;
    }
    dev[f].push_back(dot(sub(mesh.vertices[i], info.plane_origin),
                         info.plane_normal));
  }
  std::vector<FaceFlatness> out;
  out.reserve(dev.size());
  for (const auto& kv : dev) {
    FaceFlatness f;
    f.face_id = kv.first;
    f.vertices = kv.second.size();
    double s2 = 0.0, s1 = 0.0;
    for (const double d : kv.second) {
      s2 += d * d;
      s1 += d;
      f.max_abs_mm = std::fmax(f.max_abs_mm, std::fabs(d));
    }
    f.rms_mm = std::sqrt(s2 / static_cast<double>(kv.second.size()));
    f.mean_signed_mm = s1 / static_cast<double>(kv.second.size());
    out.push_back(f);
  }
  return out;
}

}  // namespace topopt
