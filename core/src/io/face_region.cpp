// face_region.cpp — the REGION layer (task 2026-08-14-face-regions §1).
//
// Everything here reads `StepModel::mesh`, `StepModel::triangle_face` and
// `StepModel::faces`; NOTHING here writes any of them. That is the whole point:
// layer 1 (voxel -> original CAD face id) is what projection and the analytic
// surface lookups stand on, and a union has no analytic surface to offer.
//
// OCCT-free by construction — the same reason face_tag.cpp exists as its own
// translation unit (handoff 134): a region must resolve wherever a mesh is,
// including the dependency-free iOS slices.

#include "topopt/face_region.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace topopt {

namespace {

Vec3 sub(const Vec3& a, const Vec3& b) {
  return Vec3{a.x - b.x, a.y - b.y, a.z - b.z};
}
double dot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
Vec3 cross(const Vec3& a, const Vec3& b) {
  return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
              a.x * b.y - a.y * b.x};
}
Vec3 scale(const Vec3& a, double s) { return Vec3{a.x * s, a.y * s, a.z * s}; }
Vec3 add(const Vec3& a, const Vec3& b) {
  return Vec3{a.x + b.x, a.y + b.y, a.z + b.z};
}
double length(const Vec3& a) { return std::sqrt(dot(a, a)); }
Vec3 normalize(const Vec3& a) {
  const double l = length(a);
  return l > 1e-12 ? scale(a, 1.0 / l) : Vec3{0.0, 0.0, 0.0};
}

// The one out-of-range diagnostic, matching face_tag.cpp's wording so a user
// sees the same message whichever layer resolved the id.
std::string face_id_range_error(const std::string& what, int face_id,
                                int face_count) {
  if (face_count <= 0)
    return what + ": face id " + std::to_string(face_id) +
           " out of range — this model carries no face ids at all (0 faces).";
  return what + ": face id " + std::to_string(face_id) +
         " out of range — the model carries " + std::to_string(face_count) +
         " faces (valid ids 0.." + std::to_string(face_count - 1) + ")";
}

void require_parallel(const StepModel& model, const char* what) {
  if (model.triangle_face.size() != model.mesh.triangles.size())
    throw std::invalid_argument(
        std::string(what) + ": triangle_face is not parallel to mesh.triangles");
}

// Squared distance from p to triangle (a,b,c) — the SAME routine face_tag.cpp
// uses (Ericson, ClosestPtPointTriangle). Duplicated rather than exported
// because it is an implementation detail of both files' scan; the two are held
// together by test_face_region.cpp asserting a one-member region tags exactly
// what tag_step_face tags, which is the property that actually matters.
double point_tri_dist2(const Vec3& p, const Vec3& a, const Vec3& b,
                       const Vec3& c) {
  auto axpy = [](const Vec3& base, double t, const Vec3& dir) {
    return Vec3{base.x + t * dir.x, base.y + t * dir.y, base.z + t * dir.z};
  };
  const Vec3 ab = sub(b, a);
  const Vec3 ac = sub(c, a);
  const Vec3 ap = sub(p, a);
  const double d1 = dot(ab, ap);
  const double d2 = dot(ac, ap);

  Vec3 q;
  if (d1 <= 0.0 && d2 <= 0.0) {
    q = a;
  } else {
    const Vec3 bp = sub(p, b);
    const double d3 = dot(ab, bp);
    const double d4 = dot(ac, bp);
    if (d3 >= 0.0 && d4 <= d3) {
      q = b;
    } else {
      const Vec3 cp = sub(p, c);
      const double d5 = dot(ab, cp);
      const double d6 = dot(ac, cp);
      const double vc = d1 * d4 - d3 * d2;
      const double vb = d5 * d2 - d1 * d6;
      const double va = d3 * d6 - d5 * d4;
      if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        q = axpy(a, d1 / (d1 - d3), ab);
      } else if (d6 >= 0.0 && d5 <= d6) {
        q = c;
      } else if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        q = axpy(a, d2 / (d2 - d6), ac);
      } else if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
        q = axpy(b, (d4 - d3) / ((d4 - d3) + (d5 - d6)), sub(c, b));
      } else {
        const double denom = 1.0 / (va + vb + vc);
        q = axpy(axpy(a, vb * denom, ab), vc * denom, ac);
      }
    }
  }
  const Vec3 d = sub(p, q);
  return dot(d, d);
}

bool inside_cut(const Vec3& p, const RegionCut& c) {
  const double s = dot(sub(p, c.point), c.normal);
  return c.strict ? s > 0.0 : s >= 0.0;
}

bool inside_all(const Vec3& p, const std::vector<RegionCut>& cuts) {
  for (const RegionCut& c : cuts)
    if (!inside_cut(p, c)) return false;
  return true;
}

// A stable orthonormal pair spanning the plane perpendicular to `d` (unit).
void perp_basis(const Vec3& d, Vec3& e1, Vec3& e2) {
  const Vec3 seed = std::fabs(d.x) < 0.9 ? Vec3{1.0, 0.0, 0.0} : Vec3{0.0, 1.0, 0.0};
  e1 = normalize(sub(seed, scale(d, dot(seed, d))));
  if (length(e1) < 1e-9) e1 = Vec3{1.0, 0.0, 0.0};
  e2 = normalize(cross(d, e1));
}

// The distinct welded vertex indices of a region's member triangles.
std::vector<int> region_vertex_indices(const StepModel& model,
                                       const ResolvedFaceRegion& region) {
  std::set<int> s;
  for (int t : region.member_triangles) {
    const auto& tri = model.mesh.triangles[static_cast<std::size_t>(t)];
    s.insert(tri[0]);
    s.insert(tri[1]);
    s.insert(tri[2]);
  }
  return std::vector<int>(s.begin(), s.end());
}

// Symmetric 3x3 eigen-decomposition by cyclic Jacobi. `a` is overwritten;
// `vecs` columns are the eigenvectors, `vals` the eigenvalues (unordered).
void jacobi3(double a[3][3], double vecs[3][3], double vals[3]) {
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) vecs[i][j] = (i == j) ? 1.0 : 0.0;
  for (int sweep = 0; sweep < 32; ++sweep) {
    double off = 0.0;
    for (int i = 0; i < 3; ++i)
      for (int j = i + 1; j < 3; ++j) off += a[i][j] * a[i][j];
    if (off < 1e-24) break;
    for (int p = 0; p < 3; ++p) {
      for (int q = p + 1; q < 3; ++q) {
        if (std::fabs(a[p][q]) < 1e-30) continue;
        const double theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
        const double t = (theta >= 0.0 ? 1.0 : -1.0) /
                         (std::fabs(theta) + std::sqrt(theta * theta + 1.0));
        const double c = 1.0 / std::sqrt(t * t + 1.0);
        const double s = t * c;
        for (int k = 0; k < 3; ++k) {
          const double akp = a[k][p], akq = a[k][q];
          a[k][p] = c * akp - s * akq;
          a[k][q] = s * akp + c * akq;
        }
        for (int k = 0; k < 3; ++k) {
          const double apk = a[p][k], aqk = a[q][k];
          a[p][k] = c * apk - s * aqk;
          a[q][k] = s * apk + c * aqk;
        }
        for (int k = 0; k < 3; ++k) {
          const double vkp = vecs[k][p], vkq = vecs[k][q];
          vecs[k][p] = c * vkp - s * vkq;
          vecs[k][q] = s * vkp + c * vkq;
        }
      }
    }
  }
  for (int i = 0; i < 3; ++i) vals[i] = a[i][i];
}

}  // namespace

// ---------------------------------------------------------------------------
// face measures
// ---------------------------------------------------------------------------

std::vector<double> face_areas_mm2(const StepModel& model) {
  require_parallel(model, "face_areas_mm2");
  std::vector<double> areas(static_cast<std::size_t>(std::max(0, model.face_count)),
                            0.0);
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    const int f = model.triangle_face[t];
    if (f < 0 || f >= model.face_count) continue;
    const auto& tri = model.mesh.triangles[t];
    const Vec3& a = model.mesh.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = model.mesh.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = model.mesh.vertices[static_cast<std::size_t>(tri[2])];
    areas[static_cast<std::size_t>(f)] +=
        0.5 * length(cross(sub(b, a), sub(c, a)));
  }
  return areas;
}

std::vector<std::vector<int>> face_adjacency(const StepModel& model) {
  require_parallel(model, "face_adjacency");
  // welded edge (lo,hi) -> the distinct faces incident to it
  std::unordered_map<std::uint64_t, std::set<int>> edge_faces;
  edge_faces.reserve(model.mesh.triangles.size() * 3);
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    const int f = model.triangle_face[t];
    if (f < 0 || f >= model.face_count) continue;
    const auto& tri = model.mesh.triangles[t];
    for (int e = 0; e < 3; ++e) {
      const int a = tri[e], b = tri[(e + 1) % 3];
      const std::uint64_t lo = static_cast<std::uint64_t>(std::min(a, b));
      const std::uint64_t hi = static_cast<std::uint64_t>(std::max(a, b));
      edge_faces[(lo << 32) | hi].insert(f);
    }
  }
  std::vector<std::set<int>> adj(
      static_cast<std::size_t>(std::max(0, model.face_count)));
  for (const auto& kv : edge_faces) {
    if (kv.second.size() < 2) continue;
    for (int f : kv.second)
      for (int g : kv.second)
        if (f != g) adj[static_cast<std::size_t>(f)].insert(g);
  }
  std::vector<std::vector<int>> out(adj.size());
  for (std::size_t i = 0; i < adj.size(); ++i)
    out[i].assign(adj[i].begin(), adj[i].end());
  return out;
}

std::vector<int> match_region_filter(const StepModel& model,
                                     const RegionFilter& filter) {
  std::vector<int> out;
  if (!filter.any()) return out;  // an all-unset filter matches NOTHING
  const std::vector<double> areas = face_areas_mm2(model);
  std::vector<std::vector<int>> adj;
  if (filter.min_larger_neighbours > 0) adj = face_adjacency(model);

  for (int f = 0; f < model.face_count; ++f) {
    const std::size_t fi = static_cast<std::size_t>(f);
    const double area = areas[fi];
    if (filter.max_area_mm2 > 0.0 && area > filter.max_area_mm2) continue;
    if (filter.min_area_mm2 > 0.0 && area < filter.min_area_mm2) continue;

    if (!filter.kind.empty()) {
      const StepSurfaceKind k =
          fi < model.faces.size() ? model.faces[fi].kind : StepSurfaceKind::Other;
      if (filter.kind == "plane" && k != StepSurfaceKind::Plane) continue;
      if (filter.kind == "cylinder" && k != StepSurfaceKind::Cylinder) continue;
      if (filter.kind == "other" && k != StepSurfaceKind::Other) continue;
    }

    if (filter.cylinder_radius_mm > 0.0) {
      if (fi >= model.faces.size()) continue;
      const StepFaceInfo& info = model.faces[fi];
      if (info.kind != StepSurfaceKind::Cylinder) continue;
      if (std::fabs(info.cylinder_radius_mm - filter.cylinder_radius_mm) >
          filter.cylinder_radius_tol_mm)
        continue;
    }

    if (filter.min_larger_neighbours > 0) {
      if (!(area > 0.0)) continue;  // a face with no area has no blend signal
      int larger = 0;
      for (int g : adj[fi])
        if (areas[static_cast<std::size_t>(g)] >= filter.larger_ratio * area)
          ++larger;
      if (larger < filter.min_larger_neighbours) continue;
    }

    out.push_back(f);
  }
  return out;
}

// ---------------------------------------------------------------------------
// resolution
// ---------------------------------------------------------------------------

std::vector<ResolvedFaceRegion> resolve_face_regions(
    const StepModel& model, const std::vector<FaceRegionSpec>& specs) {
  require_parallel(model, "resolve_face_regions");

  // triangles by face, built once for all specs.
  std::vector<std::vector<int>> face_triangles(
      static_cast<std::size_t>(std::max(0, model.face_count)));
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    const int f = model.triangle_face[t];
    if (f >= 0 && f < model.face_count)
      face_triangles[static_cast<std::size_t>(f)].push_back(
          static_cast<int>(t));
  }
  const std::vector<double> areas = face_areas_mm2(model);

  std::set<int> seen_ids;
  std::vector<ResolvedFaceRegion> out;
  out.reserve(specs.size());
  for (const FaceRegionSpec& s : specs) {
    const std::string what = "face region " + std::to_string(s.id);
    if (s.id < 0)
      throw std::invalid_argument(
          "a face region id must be >= 0 (got " + std::to_string(s.id) + ")");
    if (!seen_ids.insert(s.id).second)
      throw std::invalid_argument("face region id " + std::to_string(s.id) +
                                  " is declared twice — region ids must be "
                                  "unique within a job");
    for (const RegionCut& c : s.cuts)
      if (!(length(c.normal) > 1e-12))
        throw std::invalid_argument(
            what + ": a cut normal is zero — a split plane with no direction "
                   "selects nothing");

    ResolvedFaceRegion r;
    r.id = s.id;
    r.name = s.name;
    r.parent_id = s.parent_id;
    r.cuts = s.cuts;

    const std::vector<int> matched = match_region_filter(model, s.filter);
    r.filter_matched = static_cast<int>(matched.size());
    if (s.filter_matched_at_author >= 0) {
      r.filter_drift_known = true;
      r.filter_drift = r.filter_matched - s.filter_matched_at_author;
    }

    std::set<int> members(matched.begin(), matched.end());
    for (int f : s.add) {
      if (f < 0 || f >= model.face_count)
        throw std::invalid_argument(face_id_range_error(what + " \"add\"", f,
                                                        model.face_count));
      members.insert(f);
    }
    for (int f : s.remove) {
      if (f < 0 || f >= model.face_count)
        throw std::invalid_argument(face_id_range_error(what + " \"remove\"", f,
                                                        model.face_count));
      members.erase(f);
    }
    if (members.empty())
      throw std::invalid_argument(
          what + " resolves to NO faces on this model — its filter matched " +
          std::to_string(r.filter_matched) + " face(s) and its add/remove list "
          "left nothing. An empty region tags nothing and would report success; "
          "it is refused instead.");

    r.member_faces.assign(members.begin(), members.end());
    for (int f : r.member_faces) {
      const std::vector<int>& ts = face_triangles[static_cast<std::size_t>(f)];
      r.member_triangles.insert(r.member_triangles.end(), ts.begin(), ts.end());
      r.area_mm2 += areas[static_cast<std::size_t>(f)];
    }
    std::sort(r.member_triangles.begin(), r.member_triangles.end());
    out.push_back(std::move(r));
  }
  return out;
}

// ---------------------------------------------------------------------------
// the region's own coordinates
// ---------------------------------------------------------------------------

RegionFrame region_frame(const StepModel& model,
                         const ResolvedFaceRegion& region) {
  RegionFrame frame;
  const std::vector<int> vidx = region_vertex_indices(model, region);
  if (vidx.size() < 3) return frame;  // valid == false

  // Do the member faces share one cylinder axis?
  bool all_cyl = !region.member_faces.empty();
  Vec3 axis_dir{0.0, 0.0, 0.0};
  Vec3 axis_point{0.0, 0.0, 0.0};
  const double cos_tol = std::cos(kRegionAxisToleranceDeg * 3.14159265358979323846 / 180.0);
  for (int f : region.member_faces) {
    const std::size_t fi = static_cast<std::size_t>(f);
    if (fi >= model.faces.size() ||
        model.faces[fi].kind != StepSurfaceKind::Cylinder) {
      all_cyl = false;
      break;
    }
    const Vec3 d = normalize(model.faces[fi].axis_dir);
    if (!(length(d) > 0.5)) {
      all_cyl = false;
      break;
    }
    if (length(axis_dir) < 0.5) {
      axis_dir = d;
      axis_point = model.faces[fi].axis_point;
    } else if (std::fabs(dot(axis_dir, d)) < cos_tol) {
      all_cyl = false;  // a different axis: not one bore's worth of blends
      break;
    }
  }

  // The centroid of the member vertices — the origin both branches measure
  // their extents from.
  Vec3 centroid{0.0, 0.0, 0.0};
  for (int i : vidx)
    centroid = add(centroid, model.mesh.vertices[static_cast<std::size_t>(i)]);
  centroid = scale(centroid, 1.0 / static_cast<double>(vidx.size()));

  if (all_cyl && length(axis_dir) > 0.5) {
    frame.cylindrical = true;
    frame.valid = true;
    frame.axis_dir = axis_dir;
    // Move the stored axis point to the foot of the region centroid so the
    // axial parameter is centred on the material, not on wherever OCCT put the
    // cylinder's origin.
    frame.axis_point =
        add(axis_point, scale(axis_dir, dot(sub(centroid, axis_point), axis_dir)));
    frame.origin = frame.axis_point;
    perp_basis(axis_dir, frame.u, frame.v);
    frame.w = axis_dir;
    double lo = 0.0, hi = 0.0;
    bool first = true;
    for (int i : vidx) {
      const double s =
          dot(sub(model.mesh.vertices[static_cast<std::size_t>(i)], frame.axis_point),
              axis_dir);
      if (first) { lo = hi = s; first = false; }
      lo = std::min(lo, s);
      hi = std::max(hi, s);
    }
    frame.axial_lo = lo;
    frame.axial_hi = hi;
    return frame;
  }

  double cov[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
  for (int i : vidx) {
    const Vec3 d = sub(model.mesh.vertices[static_cast<std::size_t>(i)], centroid);
    const double c[3] = {d.x, d.y, d.z};
    for (int a = 0; a < 3; ++a)
      for (int b = 0; b < 3; ++b) cov[a][b] += c[a] * c[b];
  }
  double vecs[3][3], vals[3];
  jacobi3(cov, vecs, vals);
  int order[3] = {0, 1, 2};
  std::sort(order, order + 3, [&](int a, int b) { return vals[a] > vals[b]; });
  auto col = [&](int k) {
    return normalize(Vec3{vecs[0][k], vecs[1][k], vecs[2][k]});
  };
  frame.origin = centroid;
  frame.u = col(order[0]);
  frame.v = col(order[1]);
  frame.w = col(order[2]);
  if (!(length(frame.u) > 0.5) || !(length(frame.v) > 0.5)) return frame;
  // Right-handed, so the snap candidates and the grid indices are deterministic.
  if (dot(cross(frame.u, frame.v), frame.w) < 0.0) frame.w = scale(frame.w, -1.0);
  frame.valid = true;

  bool first = true;
  for (int i : vidx) {
    const Vec3 d = sub(model.mesh.vertices[static_cast<std::size_t>(i)], centroid);
    const double su = dot(d, frame.u), sv = dot(d, frame.v);
    if (first) {
      frame.u_lo = frame.u_hi = su;
      frame.v_lo = frame.v_hi = sv;
      first = false;
    }
    frame.u_lo = std::min(frame.u_lo, su);
    frame.u_hi = std::max(frame.u_hi, su);
    frame.v_lo = std::min(frame.v_lo, sv);
    frame.v_hi = std::max(frame.v_hi, sv);
  }
  return frame;
}

std::vector<Vec3> manual_split_snap_normals(const RegionFrame& frame) {
  std::vector<Vec3> out;
  if (!frame.valid) return out;
  const Vec3 u = frame.cylindrical ? frame.w : frame.u;  // the long direction
  const Vec3 v = frame.cylindrical ? frame.u : frame.v;
  out.push_back(normalize(u));                                 // across the long axis
  out.push_back(normalize(v));                                 // along it
  out.push_back(normalize(add(u, v)));                         // 45 degrees
  out.push_back(normalize(sub(v, u)));                         // 135 degrees
  return out;
}

// ---------------------------------------------------------------------------
// grid split
// ---------------------------------------------------------------------------

std::vector<GridSplitCell> grid_split_cells(const RegionFrame& frame, int n,
                                            int m) {
  if (n < 1 || m < 1)
    throw std::invalid_argument(
        "a grid split needs n >= 1 and m >= 1 (got n=" + std::to_string(n) +
        ", m=" + std::to_string(m) + ")");
  if (!frame.valid)
    throw std::invalid_argument(
        "a grid split needs a region frame — this region has fewer than three "
        "distinct vertices, so it has no principal axis and no axis to cut "
        "about");

  std::vector<GridSplitCell> cells;
  cells.reserve(static_cast<std::size_t>(n) * static_cast<std::size_t>(m));

  if (frame.cylindrical) {
    Vec3 e1 = frame.u, e2 = frame.v;
    const double two_pi = 6.283185307179586476925;
    for (int i = 0; i < n; ++i) {
      // Sector i spans [a0, a1). Each boundary plane CONTAINS the axis, so its
      // normal is the tangent at that angle.
      const double a0 = two_pi * static_cast<double>(i) / static_cast<double>(n);
      const double a1 = two_pi * static_cast<double>(i + 1) / static_cast<double>(n);
      std::vector<RegionCut> ang;
      if (n >= 2) {
        RegionCut lo;
        lo.point = frame.axis_point;
        lo.normal = add(scale(e1, -std::sin(a0)), scale(e2, std::cos(a0)));
        lo.strict = false;
        ang.push_back(lo);
        RegionCut hi;
        hi.point = frame.axis_point;
        hi.normal = scale(add(scale(e1, -std::sin(a1)), scale(e2, std::cos(a1))), -1.0);
        hi.strict = true;
        ang.push_back(hi);
      }
      for (int j = 0; j < m; ++j) {
        GridSplitCell cell;
        cell.i = i;
        cell.j = j;
        cell.cuts = ang;
        const double span = frame.axial_hi - frame.axial_lo;
        const double s0 = frame.axial_lo + span * static_cast<double>(j) / m;
        const double s1 = frame.axial_lo + span * static_cast<double>(j + 1) / m;
        if (j > 0) {
          RegionCut lo;
          lo.point = add(frame.axis_point, scale(frame.axis_dir, s0));
          lo.normal = frame.axis_dir;
          lo.strict = false;
          cell.cuts.push_back(lo);
        }
        if (j < m - 1) {
          RegionCut hi;
          hi.point = add(frame.axis_point, scale(frame.axis_dir, s1));
          hi.normal = scale(frame.axis_dir, -1.0);
          hi.strict = true;
          cell.cuts.push_back(hi);
        }
        cells.push_back(std::move(cell));
      }
    }
    return cells;
  }

  // PCA: n slabs perpendicular to u, m slabs perpendicular to v. The OUTER
  // boundaries are omitted rather than placed at the measured extent, so a
  // vertex-derived extent that sits a hair inside a voxel centre cannot drop
  // that voxel out of every cell.
  const double du = frame.u_hi - frame.u_lo;
  const double dv = frame.v_hi - frame.v_lo;
  for (int i = 0; i < n; ++i) {
    for (int j = 0; j < m; ++j) {
      GridSplitCell cell;
      cell.i = i;
      cell.j = j;
      if (i > 0) {
        RegionCut lo;
        lo.point = add(frame.origin,
                       scale(frame.u, frame.u_lo + du * static_cast<double>(i) / n));
        lo.normal = frame.u;
        lo.strict = false;
        cell.cuts.push_back(lo);
      }
      if (i < n - 1) {
        RegionCut hi;
        hi.point = add(frame.origin,
                       scale(frame.u, frame.u_lo + du * static_cast<double>(i + 1) / n));
        hi.normal = scale(frame.u, -1.0);
        hi.strict = true;
        cell.cuts.push_back(hi);
      }
      if (j > 0) {
        RegionCut lo;
        lo.point = add(frame.origin,
                       scale(frame.v, frame.v_lo + dv * static_cast<double>(j) / m));
        lo.normal = frame.v;
        lo.strict = false;
        cell.cuts.push_back(lo);
      }
      if (j < m - 1) {
        RegionCut hi;
        hi.point = add(frame.origin,
                       scale(frame.v, frame.v_lo + dv * static_cast<double>(j + 1) / m));
        hi.normal = scale(frame.v, -1.0);
        hi.strict = true;
        cell.cuts.push_back(hi);
      }
      cells.push_back(std::move(cell));
    }
  }
  return cells;
}

// ---------------------------------------------------------------------------
// voxels, counts, the sliver guard
// ---------------------------------------------------------------------------

std::vector<int> region_member_voxels(const VoxelGrid& grid,
                                      const StepModel& model,
                                      const ResolvedFaceRegion& region,
                                      int depth_voxels) {
  if (depth_voxels < 1)
    throw std::invalid_argument(
        "region_member_voxels: depth_voxels must be >= 1");
  require_parallel(model, "region_member_voxels");

  const double h = grid.spacing;
  const double thr = (static_cast<double>(depth_voxels) - 0.5) * h;
  const double thr2 = thr * thr;
  const double eps = 1e-9 * h * h;

  std::vector<int> out;
  for (int k = 0; k < grid.nz; ++k) {
    for (int j = 0; j < grid.ny; ++j) {
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const Vec3 centre = grid.voxel_center(i, j, k);
        bool against = false;
        for (std::size_t ti = 0; ti < region.member_triangles.size() && !against;
             ++ti) {
          const auto& tri = model.mesh.triangles[static_cast<std::size_t>(
              region.member_triangles[ti])];
          const Vec3& a = model.mesh.vertices[static_cast<std::size_t>(tri[0])];
          const Vec3& b = model.mesh.vertices[static_cast<std::size_t>(tri[1])];
          const Vec3& c = model.mesh.vertices[static_cast<std::size_t>(tri[2])];
          if (point_tri_dist2(centre, a, b, c) <= thr2 + eps) against = true;
        }
        if (against) out.push_back(static_cast<int>(grid.index(i, j, k)));
      }
    }
  }
  return out;
}

namespace {
// Recover the voxel centre from a grid index without a divide-heavy round trip
// per cut evaluation.
Vec3 centre_of_index(const VoxelGrid& grid, int idx) {
  const int i = idx % grid.nx;
  const int j = (idx / grid.nx) % grid.ny;
  const int k = idx / (grid.nx * grid.ny);
  return grid.voxel_center(i, j, k);
}
}  // namespace

std::vector<int> cut_voxels(const VoxelGrid& grid, const std::vector<int>& voxels,
                            const std::vector<RegionCut>& cuts) {
  if (cuts.empty()) return voxels;
  std::vector<int> out;
  out.reserve(voxels.size());
  for (int idx : voxels)
    if (inside_all(centre_of_index(grid, idx), cuts)) out.push_back(idx);
  return out;
}

std::vector<std::size_t> grid_split_voxel_counts(
    const VoxelGrid& grid, const std::vector<int>& member_voxels,
    const std::vector<GridSplitCell>& cells) {
  std::vector<std::size_t> counts(cells.size(), 0);
  for (int idx : member_voxels) {
    const Vec3 c = centre_of_index(grid, idx);
    for (std::size_t ci = 0; ci < cells.size(); ++ci)
      if (inside_all(c, cells[ci].cuts)) ++counts[ci];
  }
  return counts;
}

SliverVerdict check_sliver(const std::vector<std::size_t>& cell_voxels,
                           const std::vector<GridSplitCell>& cells,
                           std::size_t member_voxels, std::size_t floor) {
  SliverVerdict v;
  v.floor_voxels = floor;
  v.member_voxels = member_voxels;
  v.max_cells_budget =
      floor > 0 ? static_cast<int>(member_voxels / floor) : 0;
  if (cell_voxels.empty()) {
    v.reason = "a grid split produced no cells";
    return v;
  }
  std::size_t worst = cell_voxels[0];
  std::size_t worst_at = 0;
  for (std::size_t i = 0; i < cell_voxels.size(); ++i) {
    if (cell_voxels[i] == 0) ++v.empty_cells;
    if (cell_voxels[i] < worst) {
      worst = cell_voxels[i];
      worst_at = i;
    }
  }
  v.min_cell_voxels = worst;
  if (worst_at < cells.size()) {
    v.min_cell_i = cells[worst_at].i;
    v.min_cell_j = cells[worst_at].j;
  }
  if (worst >= floor) {
    v.ok = true;
    return v;
  }
  v.reason = "smallest cell (" + std::to_string(v.min_cell_i + 1) + "x" +
             std::to_string(v.min_cell_j + 1) + ") holds " +
             std::to_string(worst) + " voxels, under the floor of " +
             std::to_string(floor) + ". This region holds " +
             std::to_string(member_voxels) + " voxels, so at most " +
             std::to_string(v.max_cells_budget) + " cells can clear it.";
  return v;
}

// ---------------------------------------------------------------------------
// tagging by region
// ---------------------------------------------------------------------------

std::size_t tag_step_region(VoxelGrid& grid, const StepModel& model,
                            const ResolvedFaceRegion& region, VoxelTag tag) {
  if (tag != VoxelTag::Load && tag != VoxelTag::Fixture)
    throw std::invalid_argument("tag_step_region: tag must be Load or Fixture");
  const std::vector<int> members = region_member_voxels(grid, model, region, 1);
  const std::vector<int> sel = cut_voxels(grid, members, region.cuts);
  for (int idx : sel) {
    const int i = idx % grid.nx;
    const int j = (idx / grid.nx) % grid.ny;
    const int k = idx / (grid.nx * grid.ny);
    grid.set_tag(i, j, k, tag);
  }
  return sel.size();
}

std::size_t mask_step_region(const VoxelGrid& grid, const StepModel& model,
                             const ResolvedFaceRegion& region,
                             MaskValue mask_value, int depth_voxels,
                             DesignMask& mask) {
  if (depth_voxels < 1)
    throw std::invalid_argument("mask_step_region: depth_voxels must be >= 1");
  if (mask.size() != grid.voxel_count())
    throw std::invalid_argument("mask_step_region: mask size != voxel_count");
  const std::vector<int> members =
      region_member_voxels(grid, model, region, depth_voxels);
  const std::vector<int> sel = cut_voxels(grid, members, region.cuts);
  for (int idx : sel) mask[static_cast<std::size_t>(idx)] = mask_value;
  return sel.size();
}

double region_thinnest_extent_mm(const ClearanceVoxelMask& mask) {
  VoxelGrid grid;
  grid.nx = mask.nx;
  grid.ny = mask.ny;
  grid.nz = mask.nz;
  grid.spacing = mask.spacing;
  grid.origin = mask.origin;
  grid.tags.assign(mask.inside.size(), VoxelTag::Empty);
  for (std::size_t i = 0; i < mask.inside.size(); ++i)
    if (mask.inside[i]) grid.tags[i] = VoxelTag::Interior;
  std::vector<double> dens(grid.voxel_count(), 0.0);
  const std::size_t n =
      std::min(dens.size(), mask.inside.size());
  for (std::size_t i = 0; i < n; ++i)
    if (mask.inside[i]) dens[i] = 1.0;
  // The cap bounds cost at O(cap · voxels). A region thicker than the cap
  // returns +inf from the primitive, which reads as "thicker than we measured"
  // — the conservative direction for a thinnest-extent bound, and the same
  // sentinel the grading law already handles.
  const int cap = 64;
  const std::vector<double> tau =
      local_member_thickness_mm(grid, dens, 0.5, cap);
  std::vector<double> body;
  body.reserve(mask.set_count());
  for (std::size_t i = 0; i < n; ++i)
    if (mask.inside[i] && i < tau.size() && tau[i] > 0.0) body.push_back(tau[i]);
  if (body.empty()) return std::numeric_limits<double>::infinity();
  const std::size_t mid = body.size() / 2;
  std::nth_element(body.begin(), body.begin() + mid, body.end());
  return body[mid];
}

}  // namespace topopt
