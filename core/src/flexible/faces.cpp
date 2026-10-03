#include "topopt/flexible/faces.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "topopt/flexible/error.hpp"

namespace topopt {
namespace flexible {
namespace {

constexpr double kPi = 3.14159265358979323846;

Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double norm(const Vec3& a) { return std::sqrt(dot(a, a)); }
Vec3 unit(const Vec3& a) {
  const double n = norm(a);
  return n > 0.0 ? mul(a, 1.0 / n) : Vec3{0, 0, 0};
}
double angle_deg(const Vec3& a, const Vec3& b) {
  const double c = dot(unit(a), unit(b));
  return std::acos(std::min(1.0, std::max(-1.0, c))) * 180.0 / kPi;
}

// Remove the load component and normalise.
Vec3 in_plane(const Vec3& v, const Vec3& load) { return unit(sub(v, mul(load, dot(v, load)))); }

// The tie rule and the sign rule of the frame (see faces.hpp).
Vec3 orient_axis(Vec3 x, bool tied, const Vec3& load) {
  if (tied) {
    x = in_plane({1, 0, 0}, load);
    if (norm(sub(Vec3{1, 0, 0}, mul(load, dot(Vec3{1, 0, 0}, load)))) < 0.1)
      x = in_plane({0, 1, 0}, load);
  }
  for (const Vec3& ref : {Vec3{1, 0, 0}, Vec3{0, 1, 0}, Vec3{0, 0, 1}}) {
    const double d = dot(x, ref);
    if (std::fabs(d) > 1e-9) {
      if (d < 0.0) x = mul(x, -1.0);
      break;
    }
  }
  return x;
}

// Rotate X about the load by a multiple of 90°, exactly.
void rotate_frame(FaceFrame& f, int rotation_deg) {
  if (rotation_deg % 90 != 0)
    throw FlexibleError("frame_rotation_deg must be a multiple of 90 (got " +
                        std::to_string(rotation_deg) + ")");
  const int q = ((rotation_deg / 90) % 4 + 4) % 4;
  Vec3 x = f.x_axis;
  const Vec3 y = cross(f.load, x);
  if (q == 1) x = y;
  if (q == 2) x = mul(x, -1.0);
  if (q == 3) x = mul(y, -1.0);
  f.x_axis = x;
  f.y_axis = cross(f.load, x);
  f.rotation_deg = q * 90;
}

// Principal direction of a symmetric 2x2 [[a, b], [b, c]] (largest eigenvalue).
// `tied` when the two eigenvalues agree within 1e-6 relative.
void principal_2d(double a, double b, double c, double& dx, double& dy, bool& tied) {
  const double mean = 0.5 * (a + c);
  const double r = std::sqrt(0.25 * (a - c) * (a - c) + b * b);
  const double l1 = mean + r, l2 = mean - r;
  tied = !(l1 > 0.0) || (l1 - l2) <= 1e-4 * std::fabs(l1);
  if (std::fabs(b) > 1e-300) {
    dx = l1 - c;
    dy = b;
  } else if (a >= c) {
    dx = 1;
    dy = 0;
  } else {
    dx = 0;
    dy = 1;
  }
  const double n = std::sqrt(dx * dx + dy * dy);
  dx /= n;
  dy /= n;
}

// Any orthonormal basis of the plane ⟂ load.
void plane_basis(const Vec3& load, Vec3& e1, Vec3& e2) {
  const Vec3 a = std::fabs(load.x) < 0.9 ? Vec3{1, 0, 0} : Vec3{0, 1, 0};
  e1 = unit(cross(load, a));
  e2 = cross(load, e1);
}

void set_extents_from_points(FaceFrame& f, const std::vector<Vec3>& pts) {
  double umin = 1e300, umax = -1e300, vmin = 1e300, vmax = -1e300;
  for (const Vec3& p : pts) {
    const Vec3 d = sub(p, f.centroid);
    const double u = dot(d, f.x_axis), v = dot(d, f.y_axis);
    umin = std::min(umin, u);
    umax = std::max(umax, u);
    vmin = std::min(vmin, v);
    vmax = std::max(vmax, v);
  }
  f.u_min = umin;
  f.v_min = vmin;
  f.u_extent_mm = umax - umin;
  f.v_extent_mm = vmax - vmin;
}

// Möller–Trumbore along a LINE (t may be negative). Edges are inclusive, so a ray
// through a shared edge hits both triangles at the same t — harmless, since every
// consumer takes a minimum.
bool line_hit(const Vec3& o, const Vec3& d, const Vec3& v0, const Vec3& v1, const Vec3& v2,
              double& t) {
  const Vec3 e1 = sub(v1, v0), e2 = sub(v2, v0);
  const Vec3 p = cross(d, e2);
  const double det = dot(e1, p);
  if (std::fabs(det) < 1e-14 * norm(e1) * norm(e2)) return false;  // parallel
  const double inv = 1.0 / det;
  const Vec3 s = sub(o, v0);
  const double u = dot(s, p) * inv;
  if (u < -1e-9 || u > 1.0 + 1e-9) return false;
  const Vec3 q = cross(s, e1);
  const double v = dot(d, q) * inv;
  if (v < -1e-9 || u + v > 1.0 + 1e-9) return false;
  t = dot(e2, q) * inv;
  return true;
}

struct Tracer {
  const StepModel& model;
  const FaceFrame& frame;
  std::vector<char> member;       // per triangle
  std::vector<Vec3> area_vec;     // per triangle, |.| = 2 × area
  // bins over the frame's (u, v) (centroid-relative) of triangles that can be hit
  double bu0 = 0, bv0 = 0, bsize = 1;
  int bnu = 1, bnv = 1;
  std::vector<std::vector<int>> bins;

  Tracer(const StepModel& m, const FaceFrame& f, const ResolvedFaceRegion& face, double pitch)
      : model(m), frame(f) {
    const std::size_t nt = m.mesh.triangles.size();
    member.assign(nt, 0);
    for (int t : face.member_triangles)
      if (t >= 0 && static_cast<std::size_t>(t) < nt) member[static_cast<std::size_t>(t)] = 1;
    area_vec.resize(nt);
    bu0 = f.u_min - pitch;
    bv0 = f.v_min - pitch;
    const double su = f.u_extent_mm + 2 * pitch, sv = f.v_extent_mm + 2 * pitch;
    bsize = std::max(4.0 * pitch, std::max(su, sv) / 256.0);
    bnu = std::max(1, static_cast<int>(std::ceil(su / bsize)));
    bnv = std::max(1, static_cast<int>(std::ceil(sv / bsize)));
    bins.assign(static_cast<std::size_t>(bnu) * static_cast<std::size_t>(bnv), {});
    for (std::size_t t = 0; t < nt; ++t) {
      const auto& tri = m.mesh.triangles[t];
      const Vec3& a = m.mesh.vertices[static_cast<std::size_t>(tri[0])];
      const Vec3& b = m.mesh.vertices[static_cast<std::size_t>(tri[1])];
      const Vec3& c = m.mesh.vertices[static_cast<std::size_t>(tri[2])];
      area_vec[t] = cross(sub(b, a), sub(c, a));
      const double an = norm(area_vec[t]);
      if (!(an > 0.0) || std::fabs(dot(area_vec[t], f.load)) <= 1e-12 * an) continue;
      double umin = 1e300, umax = -1e300, vmin = 1e300, vmax = -1e300;
      for (const Vec3* p : {&a, &b, &c}) {
        const Vec3 d = sub(*p, f.centroid);
        const double u = dot(d, f.x_axis), v = dot(d, f.y_axis);
        umin = std::min(umin, u);
        umax = std::max(umax, u);
        vmin = std::min(vmin, v);
        vmax = std::max(vmax, v);
      }
      const int i0 = std::max(0, static_cast<int>(std::floor((umin - bu0) / bsize)));
      const int i1 = std::min(bnu - 1, static_cast<int>(std::floor((umax - bu0) / bsize)));
      const int j0 = std::max(0, static_cast<int>(std::floor((vmin - bv0) / bsize)));
      const int j1 = std::min(bnv - 1, static_cast<int>(std::floor((vmax - bv0) / bsize)));
      for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i)
          bins[static_cast<std::size_t>(j) * static_cast<std::size_t>(bnu) +
               static_cast<std::size_t>(i)]
              .push_back(static_cast<int>(t));
    }
  }

  const std::vector<int>* bin_at(double uc, double vc) const {
    const int i = static_cast<int>(std::floor((uc - bu0) / bsize));
    const int j = static_cast<int>(std::floor((vc - bv0) / bsize));
    if (i < 0 || j < 0 || i >= bnu || j >= bnv) return nullptr;
    return &bins[static_cast<std::size_t>(j) * static_cast<std::size_t>(bnu) +
                 static_cast<std::size_t>(i)];
  }
};

struct TraceOut {
  int nu = 0, nv = 0;
  std::vector<StackColumn> columns;
  int unresolved = 0;
};

TraceOut trace(const StepModel& model, const ResolvedFaceRegion& face, const FaceFrame& f,
               const VoxelGrid& grid, const std::vector<char>& mask, double pitch) {
  TraceOut out;
  const Tracer tr(model, f, face, pitch);
  out.nu = std::max(1, static_cast<int>(std::ceil(f.u_extent_mm / pitch - 1e-9)));
  out.nv = std::max(1, static_cast<int>(std::ceil(f.v_extent_mm / pitch - 1e-9)));
  double diag = 0.0;
  {
    Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
    for (const Vec3& p : model.mesh.vertices) {
      lo = {std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z)};
      hi = {std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z)};
    }
    diag = norm(sub(hi, lo));
  }
  const double eps = 1e-9 * std::max(1.0, diag);
  const bool have_mask = mask.size() == grid.voxel_count() && grid.spacing > 0.0;
  for (int iv = 0; iv < out.nv; ++iv)
    for (int iu = 0; iu < out.nu; ++iu) {
      const double u = (iu + 0.5) * pitch, v = (iv + 0.5) * pitch;
      const double uc = u + f.u_min, vc = v + f.v_min;
      const std::vector<int>* bin = tr.bin_at(uc, vc);
      if (bin == nullptr) continue;
      const Vec3 o = add(f.centroid, add(mul(f.x_axis, uc), mul(f.y_axis, vc)));
      double t_entry = 1e300;
      bool entered = false;
      for (int ti : *bin) {
        const std::size_t t = static_cast<std::size_t>(ti);
        if (!tr.member[t] || dot(tr.area_vec[t], f.load) >= 0.0) continue;  // entering only
        const auto& tri = model.mesh.triangles[t];
        double th = 0.0;
        if (line_hit(o, f.load, model.mesh.vertices[static_cast<std::size_t>(tri[0])],
                     model.mesh.vertices[static_cast<std::size_t>(tri[1])],
                     model.mesh.vertices[static_cast<std::size_t>(tri[2])], th) &&
            th < t_entry) {
          t_entry = th;
          entered = true;
        }
      }
      if (!entered) continue;
      const Vec3 p_entry = add(o, mul(f.load, t_entry));
      bool keep = true;
      for (const RegionCut& c : face.cuts) {
        const double s = dot(sub(p_entry, c.point), c.normal);
        if (c.strict ? !(s > 0.0) : !(s >= 0.0)) {
          keep = false;
          break;
        }
      }
      if (!keep) continue;
      StackColumn col;
      col.iu = iu;
      col.iv = iv;
      col.u_mm = u;
      col.v_mm = v;
      col.area_mm2 = pitch * pitch;
      col.entry_t = t_entry;
      double t_exit = 1e300;
      for (int ti : *bin) {
        const std::size_t t = static_cast<std::size_t>(ti);
        if (dot(tr.area_vec[t], f.load) <= 0.0) continue;  // leaving only
        const auto& tri = model.mesh.triangles[t];
        double th = 0.0;
        if (line_hit(o, f.load, model.mesh.vertices[static_cast<std::size_t>(tri[0])],
                     model.mesh.vertices[static_cast<std::size_t>(tri[1])],
                     model.mesh.vertices[static_cast<std::size_t>(tri[2])], th) &&
            th > t_entry + eps && th < t_exit) {
          t_exit = th;
          col.exit_face = t < model.triangle_face.size() ? model.triangle_face[t] : -1;
        }
      }
      if (col.exit_face < 0 && t_exit >= 1e300) {
        ++out.unresolved;
        col.exit_t = t_entry;
      } else {
        col.exit_t = t_exit;
      }
      const double len = col.exit_t - col.entry_t;
      if (have_mask && len > 0.0) {
        const int n = std::max(1, static_cast<int>(std::ceil(len / (0.25 * grid.spacing))));
        const double step = len / n;
        int inside = 0;
        for (int k = 0; k < n; ++k) {
          const Vec3 p = add(o, mul(f.load, col.entry_t + (k + 0.5) * step));
          const int i = static_cast<int>(std::floor((p.x - grid.origin.x) / grid.spacing));
          const int j = static_cast<int>(std::floor((p.y - grid.origin.y) / grid.spacing));
          const int kk = static_cast<int>(std::floor((p.z - grid.origin.z) / grid.spacing));
          if (i < 0 || j < 0 || kk < 0 || i >= grid.nx || j >= grid.ny || kk >= grid.nz) continue;
          if (mask[grid.index(i, j, kk)]) ++inside;
        }
        col.lattice_mm = inside * step;
      }
      out.columns.push_back(col);
    }
  return out;
}

}  // namespace

void FaceFrame::to_uv(const Vec3& p, double& u, double& v) const {
  const Vec3 d = sub(p, centroid);
  u = dot(d, x_axis) - u_min;
  v = dot(d, y_axis) - v_min;
}

Vec3 FaceFrame::from_uv(double u, double v) const {
  return add(centroid, add(mul(x_axis, u + u_min), mul(y_axis, v + v_min)));
}

double axis_angle_deg(const Vec3& a, const Vec3& b) {
  const double c = std::fabs(dot(unit(a), unit(b)));
  return std::acos(std::min(1.0, c)) * 180.0 / kPi;
}

FaceFrame face_frame(const TriangleMesh& mesh, const std::vector<int>& triangles,
                     int rotation_deg, const Vec3& build_dir) {
  FaceFrame f;
  if (rotation_deg % 90 != 0)
    throw FlexibleError("frame_rotation_deg must be a multiple of 90 (got " +
                        std::to_string(rotation_deg) + ")");
  if (triangles.empty()) {
    f.reason = "the face has no triangles";
    return f;
  }
  Vec3 sum{0, 0, 0}, cen{0, 0, 0};
  double area = 0.0, max_a = 0.0;
  std::vector<Vec3> nrm;
  std::vector<double> ar;
  std::vector<Vec3> pts;
  for (int ti : triangles) {
    if (ti < 0 || static_cast<std::size_t>(ti) >= mesh.triangles.size()) {
      f.reason = "triangle index " + std::to_string(ti) + " is out of range";
      return f;
    }
    const auto& t = mesh.triangles[static_cast<std::size_t>(ti)];
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(t[2])];
    const Vec3 av = cross(sub(b, a), sub(c, a));
    const double A = 0.5 * norm(av);
    sum = add(sum, mul(av, 0.5));
    cen = add(cen, mul(add(add(a, b), c), A / 3.0));
    area += A;
    max_a = std::max(max_a, A);
    nrm.push_back(unit(av));
    ar.push_back(A);
    pts.push_back(a);
    pts.push_back(b);
    pts.push_back(c);
  }
  if (!(area > 0.0) || norm(sum) <= 1e-9 * area) {
    f.reason = "the face's normals cancel out (no single direction to push along)";
    return f;
  }
  const Vec3 n = unit(sum);
  f.load = mul(n, -1.0);
  f.area_mm2 = area;
  f.projected_area_mm2 = dot(sum, n);
  f.centroid = mul(cen, 1.0 / area);
  // spread: two-sweep over triangles of non-negligible area
  {
    int i1 = -1;
    double worst = -1.0;
    for (std::size_t i = 0; i < nrm.size(); ++i)
      if (ar[i] > 1e-12 * max_a && angle_deg(nrm[i], n) > worst) {
        worst = angle_deg(nrm[i], n);
        i1 = static_cast<int>(i);
      }
    double spread = 0.0;
    if (i1 >= 0)
      for (std::size_t i = 0; i < nrm.size(); ++i)
        if (ar[i] > 1e-12 * max_a)
          spread = std::max(spread, angle_deg(nrm[i], nrm[static_cast<std::size_t>(i1)]));
    f.normal_spread_deg = spread;
    f.normal_spread_flag = spread > kNormalSpreadFlagDeg;
  }
  // principal axis: exact second moment of the projected triangles
  Vec3 e1, e2;
  plane_basis(f.load, e1, e2);
  // Second moments of the PROJECTED face about the PROJECTED face's own centroid
  // (sums about the 3D centroid, then the parallel-axis shift), so a curved or mixed-
  // slope face gets the principal axis of what the stack actually sees.
  double sxx = 0, sxy = 0, syy = 0, pa = 0, pcx = 0, pcy = 0;
  for (int ti : triangles) {
    const auto& t = mesh.triangles[static_cast<std::size_t>(ti)];
    double px[3], py[3];
    for (int k = 0; k < 3; ++k) {
      const Vec3 d = sub(mesh.vertices[static_cast<std::size_t>(t[static_cast<std::size_t>(k)])],
                         f.centroid);
      px[k] = dot(d, e1);
      py[k] = dot(d, e2);
    }
    const double A2 = std::fabs((px[1] - px[0]) * (py[2] - py[0]) - (px[2] - px[0]) * (py[1] - py[0]));
    const double A = 0.5 * A2;
    const double sx = px[0] + px[1] + px[2], sy = py[0] + py[1] + py[2];
    double xx = sx * sx, xy = sx * sy, yy = sy * sy;
    for (int k = 0; k < 3; ++k) {
      xx += px[k] * px[k];
      xy += px[k] * py[k];
      yy += py[k] * py[k];
    }
    sxx += A / 12.0 * xx;
    sxy += A / 12.0 * xy;
    syy += A / 12.0 * yy;
    pa += A;
    pcx += A * sx / 3.0;
    pcy += A * sy / 3.0;
  }
  if (pa > 0.0) {
    pcx /= pa;
    pcy /= pa;
    sxx -= pa * pcx * pcx;
    sxy -= pa * pcx * pcy;
    syy -= pa * pcy * pcy;
  }
  double dx = 1, dy = 0;
  bool tied = false;
  principal_2d(sxx, sxy, syy, dx, dy, tied);
  f.principal_axis_tied = tied;
  f.x_axis = orient_axis(unit(add(mul(e1, dx), mul(e2, dy))), tied, f.load);
  f.y_axis = cross(f.load, f.x_axis);
  rotate_frame(f, rotation_deg);
  set_extents_from_points(f, pts);
  const Vec3 bz = unit(build_dir);
  f.build_angle_deg = axis_angle_deg(f.load, bz);
  f.side = f.build_angle_deg > kSideStackDeg;
  f.valid = true;
  return f;
}

Stack build_stack(const StepModel& model, const ResolvedFaceRegion& face,
                  const std::vector<ResolvedFaceRegion>& regions, const VoxelGrid& grid,
                  const std::vector<char>& lattice_mask, int rotation_deg,
                  const Vec3& build_dir, double pitch_mm) {
  if (!(pitch_mm > 0.0) || !std::isfinite(pitch_mm))
    throw FlexibleError("build_stack: the column pitch must be > 0");
  if (model.triangle_face.size() != model.mesh.triangles.size())
    throw FlexibleError("build_stack: triangle_face is not parallel to the mesh triangles");
  Stack s;
  s.face_region_id = face.id;
  s.pitch_mm = pitch_mm;
  s.cuts = face.cuts;
  // A sector (a region with cuts) is framed from its own clipped geometry (B6).
  s.frame = face_frame_cut(model.mesh, face.member_triangles, face.cuts, rotation_deg, build_dir);
  if (!s.frame.valid)
    throw FlexibleError("face region " + std::to_string(face.id) + ": " + s.frame.reason);
  const TraceOut t = trace(model, face, s.frame, grid, lattice_mask, pitch_mm);
  if (t.columns.empty())
    throw FlexibleError("face region " + std::to_string(face.id) + " has no column at a " +
                        std::to_string(pitch_mm) + " mm pitch");
  s.nu = t.nu;
  s.nv = t.nv;
  s.columns = std::move(t.columns);
  s.cell.assign(static_cast<std::size_t>(s.nu) * static_cast<std::size_t>(s.nv), -1);
  std::map<int, double> by_face;
  double lat_sum = 0.0;
  s.lattice_mm_min = 1e300;
  for (std::size_t i = 0; i < s.columns.size(); ++i) {
    const StackColumn& c = s.columns[i];
    s.cell[static_cast<std::size_t>(c.iv) * static_cast<std::size_t>(s.nu) +
           static_cast<std::size_t>(c.iu)] = static_cast<int>(i);
    s.footprint_area_mm2 += c.area_mm2;
    if (c.exit_face >= 0) by_face[c.exit_face] += c.area_mm2;
    s.stack_mm_max = std::max(s.stack_mm_max, c.exit_t - c.entry_t);
    if (c.lattice_mm > 0.0) {
      ++s.latticed_columns;
      lat_sum += c.lattice_mm;
      s.lattice_mm_min = std::min(s.lattice_mm_min, c.lattice_mm);
      s.lattice_mm_max = std::max(s.lattice_mm_max, c.lattice_mm);
    }
  }
  if (s.latticed_columns == 0) s.lattice_mm_min = 0.0;
  s.lattice_mm_mean = s.latticed_columns ? lat_sum / s.latticed_columns : 0.0;
  s.exit_unresolved_fraction = static_cast<double>(t.unresolved) /
                               static_cast<double>(s.columns.size());
  for (const auto& kv : by_face) s.exit_faces.push_back({kv.first, kv.second / s.footprint_area_mm2});
  // A region is credited only where the column's EXIT POINT satisfies its cuts, so the
  // halves of a split face share their face's area instead of each taking all of it (B4).
  std::map<int, double> by_region;
  for (const ResolvedFaceRegion& r : regions)
    for (const StackColumn& c : s.columns) {
      if (c.exit_face < 0 ||
          !std::binary_search(r.member_faces.begin(), r.member_faces.end(), c.exit_face))
        continue;
      const Vec3 exit = add(s.frame.from_uv(c.u_mm, c.v_mm), mul(s.frame.load, c.exit_t));
      if (passes_cuts(r.cuts, exit)) by_region[r.id] += c.area_mm2;
    }
  for (const auto& kv : by_region)
    s.exit_regions.push_back({kv.first, kv.second / s.footprint_area_mm2});
  auto by_share = [](const StackLink& a, const StackLink& b) {
    return a.area_fraction != b.area_fraction ? a.area_fraction > b.area_fraction : a.id < b.id;
  };
  std::sort(s.exit_faces.begin(), s.exit_faces.end(), by_share);
  std::sort(s.exit_regions.begin(), s.exit_regions.end(), by_share);
  return s;
}

bool passes_cuts(const std::vector<RegionCut>& cuts, const Vec3& p) {
  for (const RegionCut& c : cuts) {
    const double d = dot(sub(p, c.point), c.normal);
    if (c.strict ? !(d > 0.0) : !(d >= 0.0)) return false;
  }
  return true;
}

FaceFrame face_frame_cut(const TriangleMesh& mesh, const std::vector<int>& triangles,
                         const std::vector<RegionCut>& cuts, int rotation_deg,
                         const Vec3& build_dir) {
  if (cuts.empty()) return face_frame(mesh, triangles, rotation_deg, build_dir);
  // Clip every triangle by every half-space (Sutherland–Hodgman on a convex polygon),
  // then fan the pieces into a mesh of their own. The winding is kept, so the load
  // direction is the clipped face's own.
  TriangleMesh clipped;
  std::vector<int> ids;
  for (int ti : triangles) {
    if (ti < 0 || static_cast<std::size_t>(ti) >= mesh.triangles.size()) continue;
    const auto& t = mesh.triangles[static_cast<std::size_t>(ti)];
    std::vector<Vec3> poly = {mesh.vertices[static_cast<std::size_t>(t[0])],
                              mesh.vertices[static_cast<std::size_t>(t[1])],
                              mesh.vertices[static_cast<std::size_t>(t[2])]};
    for (const RegionCut& c : cuts) {
      std::vector<Vec3> out;
      const std::size_t n = poly.size();
      for (std::size_t i = 0; i < n; ++i) {
        const Vec3& a = poly[i];
        const Vec3& b = poly[(i + 1) % n];
        const double da = dot(sub(a, c.point), c.normal), db = dot(sub(b, c.point), c.normal);
        if (da >= 0.0) out.push_back(a);
        if ((da >= 0.0) != (db >= 0.0)) out.push_back(add(a, mul(sub(b, a), da / (da - db))));
      }
      poly = out;
      if (poly.size() < 3) break;
    }
    if (poly.size() < 3) continue;
    const int base = static_cast<int>(clipped.vertices.size());
    for (const Vec3& p : poly) clipped.vertices.push_back(p);
    for (std::size_t i = 1; i + 1 < poly.size(); ++i) {
      const Vec3 e1 = sub(poly[i], poly[0]), e2 = sub(poly[i + 1], poly[0]);
      if (norm(cross(e1, e2)) <= 1e-12) continue;  // a sliver the cut left behind
      ids.push_back(static_cast<int>(clipped.triangles.size()));
      clipped.triangles.push_back({base, base + static_cast<int>(i), base + static_cast<int>(i) + 1});
    }
  }
  FaceFrame f = face_frame(clipped, ids, rotation_deg, build_dir);
  if (!f.valid && ids.empty()) f.reason = "the region's cuts leave nothing of its faces";
  return f;
}

}  // namespace flexible
}  // namespace topopt
