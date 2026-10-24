#include "topopt/flexible/faces.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <iterator>
#include <map>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "topopt/flexible/error.hpp"

namespace topopt {
namespace flexible {
// Clip `triangles` of `mesh` by every half-space in `cuts` and append the pieces (fanned)
// to `clipped`, their indices to `ids`. Winding kept.
void clip_into(const TriangleMesh& mesh, const std::vector<int>& triangles,
               const std::vector<RegionCut>& cuts, TriangleMesh& clipped, std::vector<int>& ids);

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
  // Two expressions of the same eigenvector, (l1 - c, b) and (b, l1 - a). Take the
  // LARGER: when b is rounding noise and the long axis is the second basis axis, the
  // first is two noise terms and points anywhere (an edge press's X came out along the
  // edge, 1.7 degrees skewed; C1 addendum).
  const double ux = l1 - c, uy = b, wx = b, wy = l1 - a;
  if (ux * ux + uy * uy >= wx * wx + wy * wy) {
    dx = ux;
    dy = uy;
  } else {
    dx = wx;
    dy = wy;
  }
  if (!(dx * dx + dy * dy > 0.0)) {  // isotropic: any axis (the caller's tie rule decides)
    dx = 1;
    dy = 0;
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

  // per member triangle: the footprint PARTS it belongs to (multi-piece presses). Two pieces
  // of one face put the face's triangles in two parts (C2 B1a, P1).
  std::vector<std::vector<int>> parts;

  Tracer(const StepModel& m, const FaceFrame& f, const ResolvedFaceRegion& face, double pitch,
         const std::vector<std::vector<int>>* tri_parts)
      : model(m), frame(f) {
    const std::size_t nt = m.mesh.triangles.size();
    member.assign(nt, 0);
    parts.assign(nt, std::vector<int>{0});
    for (int t : face.member_triangles)
      if (t >= 0 && static_cast<std::size_t>(t) < nt) member[static_cast<std::size_t>(t)] = 1;
    if (tri_parts != nullptr)
      for (std::size_t t = 0; t < nt && t < tri_parts->size(); ++t) parts[t] = (*tri_parts)[t];
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

// A convex polygon in the frame's corner-relative (u, v) mm: one piece of the footprint
// (a member triangle facing the press, clipped by its part's cuts), projected.
struct Piece2D {
  std::vector<std::array<double, 2>> pts;
  double u0 = 0, u1 = 0, v0 = 0, v1 = 0;
};

double poly_area(const std::vector<std::array<double, 2>>& p, double& cu, double& cv) {
  double a = 0, x = 0, y = 0;
  for (std::size_t i = 0; i < p.size(); ++i) {
    const auto& q = p[i];
    const auto& r = p[(i + 1) % p.size()];
    const double c = q[0] * r[1] - r[0] * q[1];
    a += c;
    x += (q[0] + r[0]) * c;
    y += (q[1] + r[1]) * c;
  }
  a *= 0.5;
  if (std::fabs(a) > 0.0) {
    cu = x / (6.0 * a);
    cv = y / (6.0 * a);
  }
  return std::fabs(a);
}

// The convex polygon `p` clipped to the rectangle [u0, u1] x [v0, v1].
std::vector<std::array<double, 2>> clip_rect(std::vector<std::array<double, 2>> p, double u0, double u1,
                                             double v0, double v1) {
  auto clip = [&](int axis, double val, bool keep_above) {
    std::vector<std::array<double, 2>> out;
    const std::size_t n = p.size();
    for (std::size_t i = 0; i < n; ++i) {
      const auto& a = p[i];
      const auto& b = p[(i + 1) % n];
      const double da = keep_above ? a[axis] - val : val - a[axis];
      const double db = keep_above ? b[axis] - val : val - b[axis];
      if (da >= 0.0) out.push_back(a);
      if ((da >= 0.0) != (db >= 0.0)) {
        const double t = da / (da - db);
        out.push_back({a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t});
      }
    }
    p = out;
  };
  clip(0, u0, true);
  if (p.size() >= 3) clip(0, u1, false);
  if (p.size() >= 3) clip(1, v0, true);
  if (p.size() >= 3) clip(1, v1, false);
  if (p.size() < 3) p.clear();
  return p;
}

// THE RUN (C2 B1a, item 8(a), the app's rule: flexible_bridge.cpp:686-734). Sampled every
// quarter voxel from the entry along the load: a leading stretch OFF the lattice within two
// voxels of the entry is travel (it counts); inside the run a hole of at most one voxel's
// diagonal is crossed (it counts); a longer gap ends it; a column with no lattice within two
// voxels of its entry has no run.
double lattice_run_mm(const VoxelGrid& g, const std::vector<char>& mask, const Vec3& o, const Vec3& load,
                      double entry_t, double exit_t) {
  const double len = exit_t - entry_t;
  if (!(len > 0.0)) return 0.0;
  const int n = std::max(1, static_cast<int>(std::ceil(len / (0.25 * g.spacing))));
  const double step = len / n;
  bool in_lattice = false;
  int gap = 0;
  const int gap_max = static_cast<int>(std::floor(std::sqrt(3.0) * g.spacing / step));
  double run = 0.0;
  for (int k = 0; k < n; ++k) {
    const double t = entry_t + (k + 0.5) * step;
    const Vec3 p = add(o, mul(load, t));
    const int i = static_cast<int>(std::floor((p.x - g.origin.x) / g.spacing));
    const int j = static_cast<int>(std::floor((p.y - g.origin.y) / g.spacing));
    const int kk = static_cast<int>(std::floor((p.z - g.origin.z) / g.spacing));
    const bool on = !(i < 0 || j < 0 || kk < 0 || i >= g.nx || j >= g.ny || kk >= g.nz) && mask[g.index(i, j, kk)];
    if (on) {
      run = in_lattice ? run + gap * step + step : k * step + step;
      in_lattice = true;
      gap = 0;
    } else if (!in_lattice) {
      if ((k + 0.5) * step > 2.0 * g.spacing) break;
    } else if (++gap > gap_max) {
      break;
    }
  }
  return run;
}

// `part_cuts` (multi-piece presses): each footprint part's own cuts, triangle → its parts in
// `tri_parts`; an entry hit counts where it passes ANY of its triangle's parts' cuts. Null =
// one part with `face.cuts`, tested at the first entry hit (the original rule).
//
// ★ C2 B1a, item 25: THE GRID RUNS EDGE TO EDGE. A cell the footprint covers only in part is a
// column too: its area is the covered part (cell ∩ footprint, exact), its ray starts at the cell
// centre when that enters the face, else at the centroid of the largest covered piece. A cell
// the footprint covers whole keeps area pitch² exactly, so the areas sum to the face.
TraceOut trace(const StepModel& model, const ResolvedFaceRegion& face, const FaceFrame& f,
               const VoxelGrid& grid, const std::vector<char>& mask, double pitch,
               const std::vector<std::vector<RegionCut>>* part_cuts = nullptr,
               const std::vector<std::vector<int>>* tri_parts = nullptr) {
  TraceOut out;
  const Tracer tr(model, f, face, pitch, tri_parts);
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

  // The footprint's pieces in (u, v), binned by cell.
  std::vector<Piece2D> pieces;
  std::vector<std::vector<int>> cell_pieces(static_cast<std::size_t>(out.nu) * static_cast<std::size_t>(out.nv));
  for (int ti : face.member_triangles) {
    if (ti < 0 || static_cast<std::size_t>(ti) >= model.mesh.triangles.size()) continue;
    const std::size_t t = static_cast<std::size_t>(ti);
    if (dot(tr.area_vec[t], f.load) >= 0.0) continue;  // facing away from the press
    std::vector<const std::vector<RegionCut>*> cut_sets;
    if (part_cuts != nullptr) {
      for (int pa : tr.parts[t]) cut_sets.push_back(&(*part_cuts)[static_cast<std::size_t>(pa)]);
    } else {
      cut_sets.push_back(&face.cuts);
    }
    for (const std::vector<RegionCut>* cs : cut_sets) {
      TriangleMesh clipped;
      std::vector<int> ids;
      clip_into(model.mesh, {ti}, *cs, clipped, ids);
      if (clipped.vertices.size() < 3) continue;
      Piece2D pc;
      pc.u0 = pc.v0 = 1e300;
      pc.u1 = pc.v1 = -1e300;
      for (const Vec3& q : clipped.vertices) {
        double u = 0, v = 0;
        f.to_uv(q, u, v);
        pc.pts.push_back({u, v});
        pc.u0 = std::min(pc.u0, u);
        pc.u1 = std::max(pc.u1, u);
        pc.v0 = std::min(pc.v0, v);
        pc.v1 = std::max(pc.v1, v);
      }
      const int idx = static_cast<int>(pieces.size());
      pieces.push_back(std::move(pc));
      const Piece2D& P = pieces.back();
      const int i0 = std::max(0, static_cast<int>(std::floor(P.u0 / pitch)));
      const int i1 = std::min(out.nu - 1, static_cast<int>(std::floor(P.u1 / pitch)));
      const int j0 = std::max(0, static_cast<int>(std::floor(P.v0 / pitch)));
      const int j1 = std::min(out.nv - 1, static_cast<int>(std::floor(P.v1 / pitch)));
      for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i)
          cell_pieces[static_cast<std::size_t>(j) * static_cast<std::size_t>(out.nu) + static_cast<std::size_t>(i)]
              .push_back(idx);
    }
  }

  const double full = pitch * pitch;
  for (int iv = 0; iv < out.nv; ++iv)
    for (int iu = 0; iu < out.nu; ++iu) {
      // the covered area of this cell, and the largest covered piece's centroid
      double covered = 0.0, best_a = 0.0, best_u = 0.0, best_v = 0.0;
      for (int pi : cell_pieces[static_cast<std::size_t>(iv) * static_cast<std::size_t>(out.nu) +
                                static_cast<std::size_t>(iu)]) {
        const std::vector<std::array<double, 2>> c =
            clip_rect(pieces[static_cast<std::size_t>(pi)].pts, iu * pitch, (iu + 1) * pitch, iv * pitch,
                      (iv + 1) * pitch);
        if (c.empty()) continue;
        double cu = 0, cv = 0;
        const double a = poly_area(c, cu, cv);
        covered += a;
        if (a > best_a) {
          best_a = a;
          best_u = cu;
          best_v = cv;
        }
      }
      if (!(covered > 1e-9 * full)) continue;
      // the ray: from the cell centre if it enters the face, else from the largest piece
      const double centre_u = (iu + 0.5) * pitch, centre_v = (iv + 0.5) * pitch;
      StackColumn col;
      bool entered = false;
      double t_entry = 1e300;
      int entry_part = 0;
      Vec3 o{0, 0, 0};
      for (int attempt = 0; attempt < 2 && !entered; ++attempt) {
        const double u = attempt == 0 ? centre_u : best_u, v = attempt == 0 ? centre_v : best_v;
        if (attempt == 1 && !(best_a > 0.0)) break;
        const double uc = u + f.u_min, vc = v + f.v_min;
        const std::vector<int>* bin = tr.bin_at(uc, vc);
        if (bin == nullptr) continue;
        o = add(f.centroid, add(mul(f.x_axis, uc), mul(f.y_axis, vc)));
        t_entry = 1e300;
        for (int ti : *bin) {
          const std::size_t t = static_cast<std::size_t>(ti);
          if (!tr.member[t] || dot(tr.area_vec[t], f.load) >= 0.0) continue;  // entering only
          const auto& tri = model.mesh.triangles[t];
          double th = 0.0;
          if (line_hit(o, f.load, model.mesh.vertices[static_cast<std::size_t>(tri[0])],
                       model.mesh.vertices[static_cast<std::size_t>(tri[1])],
                       model.mesh.vertices[static_cast<std::size_t>(tri[2])], th) &&
              th < t_entry) {
            int part_ok = -1;
            if (part_cuts != nullptr) {
              for (int pa : tr.parts[t])
                if (passes_cuts((*part_cuts)[static_cast<std::size_t>(pa)], add(o, mul(f.load, th)))) {
                  part_ok = pa;
                  break;
                }
              if (part_ok < 0) continue;  // this piece's triangle, but outside its pieces
            }
            t_entry = th;
            entered = true;
            entry_part = part_ok < 0 ? 0 : part_ok;
          }
        }
        if (entered) {
          const Vec3 p_entry = add(o, mul(f.load, t_entry));
          for (const RegionCut& c : face.cuts) {
            const double sgn = dot(sub(p_entry, c.point), c.normal);
            if (c.strict ? !(sgn > 0.0) : !(sgn >= 0.0)) {
              entered = false;
              break;
            }
          }
          if (entered) {
            col.u_mm = u;
            col.v_mm = v;
          }
        }
      }
      if (!entered) continue;
      col.iu = iu;
      col.iv = iv;
      col.area_mm2 = std::fabs(covered - full) <= 1e-9 * full ? full : std::min(covered, full);
      col.entry_t = t_entry;
      col.part = entry_part;
      double t_exit = 1e300;
      const std::vector<int>* bin = tr.bin_at(col.u_mm + f.u_min, col.v_mm + f.v_min);
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
      if (have_mask) col.lattice_mm = lattice_run_mm(grid, mask, o, f.load, col.entry_t, col.exit_t);
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
                     int rotation_deg, const Vec3& build_dir, const Vec3* press_direction) {
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
  // An ANGLED press states its direction; otherwise the load is the inward normal.
  f.load = press_direction != nullptr ? press_unit(*press_direction) : mul(n, -1.0);
  f.area_mm2 = area;
  f.projected_area_mm2 = dot(sum, mul(f.load, -1.0));
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

namespace {
Stack stack_impl(const StepModel& model, const ResolvedFaceRegion& face,
                 const std::vector<ResolvedFaceRegion>& regions, const VoxelGrid& grid,
                 const std::vector<char>& lattice_mask, int rotation_deg, const Vec3& build_dir,
                 double pitch_mm, const Vec3* press_direction,
                 const std::vector<std::vector<RegionCut>>* part_cuts = nullptr,
                 const std::vector<std::vector<int>>* tri_parts = nullptr, const FaceFrame* frame = nullptr);
void finish_stack(Stack& s, const std::vector<ResolvedFaceRegion>& regions);
}  // namespace

Stack build_stack(const StepModel& model, const ResolvedFaceRegion& face,
                  const std::vector<ResolvedFaceRegion>& regions, const VoxelGrid& grid,
                  const std::vector<char>& lattice_mask, int rotation_deg,
                  const Vec3& build_dir, double pitch_mm) {
  Stack s = stack_impl(model, face, regions, grid, lattice_mask, rotation_deg, build_dir, pitch_mm,
                       nullptr);
  s.footprint_region_ids = {face.id};
  return s;
}

namespace {
Stack stack_impl(const StepModel& model, const ResolvedFaceRegion& face,
                 const std::vector<ResolvedFaceRegion>& regions, const VoxelGrid& grid,
                 const std::vector<char>& lattice_mask, int rotation_deg, const Vec3& build_dir,
                 double pitch_mm, const Vec3* press_direction,
                 const std::vector<std::vector<RegionCut>>* part_cuts,
                 const std::vector<std::vector<int>>* tri_parts, const FaceFrame* frame) {
  if (!(pitch_mm > 0.0) || !std::isfinite(pitch_mm))
    throw FlexibleError("build_stack: the column pitch must be > 0");
  if (model.triangle_face.size() != model.mesh.triangles.size())
    throw FlexibleError("build_stack: triangle_face is not parallel to the mesh triangles");
  Stack s;
  s.face_region_id = face.id;
  s.pitch_mm = pitch_mm;
  s.cuts = face.cuts;
  // A sector (a region with cuts) is framed from its own clipped geometry (B6).
  s.frame = frame != nullptr ? *frame
                             : face_frame_cut(model.mesh, face.member_triangles, face.cuts, rotation_deg,
                                              build_dir, press_direction);
  if (part_cuts != nullptr) s.part_cuts = *part_cuts;
  if (!s.frame.valid)
    throw FlexibleError("face region " + std::to_string(face.id) + ": " + s.frame.reason);
  const TraceOut t = trace(model, face, s.frame, grid, lattice_mask, pitch_mm, part_cuts, tri_parts);
  if (t.columns.empty())
    throw FlexibleError("face region " + std::to_string(face.id) + " has no column at a " +
                        std::to_string(pitch_mm) + " mm pitch");
  s.nu = t.nu;
  s.nv = t.nv;
  s.columns = std::move(t.columns);
  if (!s.cuts.empty() || !s.part_cuts.empty()) {
    // Bin the footprint triangles by column cell for stack_owns_projection.
    s.cell_tris.assign(static_cast<std::size_t>(s.nu) * static_cast<std::size_t>(s.nv), {});
    for (int ti : face.member_triangles) {
      if (ti < 0 || static_cast<std::size_t>(ti) >= model.mesh.triangles.size()) continue;
      const auto& tri = model.mesh.triangles[static_cast<std::size_t>(ti)];
      Stack::FootTri ft{model.mesh.vertices[static_cast<std::size_t>(tri[0])],
                        model.mesh.vertices[static_cast<std::size_t>(tri[1])],
                        model.mesh.vertices[static_cast<std::size_t>(tri[2])], 0, ti};
      if (dot(cross(sub(ft.b, ft.a), sub(ft.c, ft.a)), s.frame.load) >= 0.0) continue;  // not facing the press
      double u0 = 1e300, u1 = -1e300, v0 = 1e300, v1 = -1e300;
      for (const Vec3* q : {&ft.a, &ft.b, &ft.c}) {
        double u = 0, v = 0;
        s.frame.to_uv(*q, u, v);
        u0 = std::min(u0, u);
        u1 = std::max(u1, u);
        v0 = std::min(v0, v);
        v1 = std::max(v1, v);
      }
      const int i0 = std::max(0, static_cast<int>(std::floor(u0 / pitch_mm))),
                i1 = std::min(s.nu - 1, static_cast<int>(std::floor(u1 / pitch_mm)));
      const int j0 = std::max(0, static_cast<int>(std::floor(v0 / pitch_mm))),
                j1 = std::min(s.nv - 1, static_cast<int>(std::floor(v1 / pitch_mm)));
      if (i0 > i1 || j0 > j1) continue;
      // one FootTri per part the triangle is in (two pieces of one face, P1)
      const std::vector<int> tps = tri_parts != nullptr ? (*tri_parts)[static_cast<std::size_t>(ti)]
                                                        : std::vector<int>{0};
      for (int tp : tps) {
        ft.part = tp;
        const int idx = static_cast<int>(s.foot_tris.size());
        s.foot_tris.push_back(ft);
        for (int j = j0; j <= j1; ++j)
          for (int i = i0; i <= i1; ++i)
            s.cell_tris[static_cast<std::size_t>(j) * static_cast<std::size_t>(s.nu) + static_cast<std::size_t>(i)]
                .push_back(idx);
      }
    }
  }
  finish_stack(s, regions);
  return s;
}

// The column grid's index, the footprint, the lattice statistics and the exit links, from
// s.columns (after trace, and again after restrict_to_lattice).
void finish_stack(Stack& s, const std::vector<ResolvedFaceRegion>& regions) {
  s.cell.assign(static_cast<std::size_t>(s.nu) * static_cast<std::size_t>(s.nv), -1);
  s.footprint_area_mm2 = 0.0;
  s.latticed_columns = 0;
  s.stack_mm_max = 0.0;
  s.lattice_mm_max = 0.0;
  s.exit_faces.clear();
  s.exit_regions.clear();
  std::map<int, double> by_face;
  double lat_sum = 0.0;
  int unresolved = 0;
  s.lattice_mm_min = 1e300;
  for (std::size_t i = 0; i < s.columns.size(); ++i) {
    const StackColumn& c = s.columns[i];
    s.cell[static_cast<std::size_t>(c.iv) * static_cast<std::size_t>(s.nu) +
           static_cast<std::size_t>(c.iu)] = static_cast<int>(i);
    s.footprint_area_mm2 += c.area_mm2;
    if (c.exit_face >= 0) by_face[c.exit_face] += c.area_mm2;
    else ++unresolved;
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
  s.exit_unresolved_fraction =
      s.columns.empty() ? 0.0 : static_cast<double>(unresolved) / static_cast<double>(s.columns.size());
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
}
}  // namespace

bool passes_cuts(const std::vector<RegionCut>& cuts, const Vec3& p) {
  for (const RegionCut& c : cuts) {
    const double d = dot(sub(p, c.point), c.normal);
    if (c.strict ? !(d > 0.0) : !(d >= 0.0)) return false;
  }
  return true;
}

FaceFrame face_frame_cut(const TriangleMesh& mesh, const std::vector<int>& triangles,
                         const std::vector<RegionCut>& cuts, int rotation_deg,
                         const Vec3& build_dir, const Vec3* press_direction) {
  if (cuts.empty()) return face_frame(mesh, triangles, rotation_deg, build_dir, press_direction);
  // Clip every triangle by every half-space (Sutherland–Hodgman on a convex polygon),
  // then fan the pieces into a mesh of their own. The winding is kept, so the load
  // direction is the clipped face's own.
  TriangleMesh clipped;
  std::vector<int> ids;
  clip_into(mesh, triangles, cuts, clipped, ids);
  FaceFrame f = face_frame(clipped, ids, rotation_deg, build_dir, press_direction);
  if (!f.valid && ids.empty()) f.reason = "the region's cuts leave nothing of its faces";
  return f;
}

void clip_into(const TriangleMesh& mesh, const std::vector<int>& triangles,
               const std::vector<RegionCut>& cuts, TriangleMesh& clipped, std::vector<int>& ids) {
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
}

Stack build_press_stack(const StepModel& model,
                        const std::vector<const ResolvedFaceRegion*>& footprint,
                        const std::vector<ResolvedFaceRegion>& regions, const VoxelGrid& grid,
                        const std::vector<char>& lattice_mask, int rotation_deg,
                        const Vec3& build_dir, double pitch_mm, const Vec3* press_direction) {
  if (footprint.empty()) throw FlexibleError("a press needs at least one face region");
  auto name = [](const ResolvedFaceRegion* r) { return "face region " + std::to_string(r->id); };
  for (std::size_t i = 0; i < footprint.size(); ++i)
    for (std::size_t j = i + 1; j < footprint.size(); ++j)
      if (footprint[i]->id == footprint[j]->id)
        throw FlexibleError(name(footprint[i]) + " appears twice in one press");
  if (footprint.size() > 1) {
    // P1 (C2 B1a): two pieces that overlap inside one press would be pressed twice.
    {
      std::vector<PressFootprint> parts;
      for (const ResolvedFaceRegion* r : footprint) parts.push_back({r->id, {r}});
      const std::vector<SharedFootprint> ov = find_shared_footprints(model.mesh, parts);
      if (!ov.empty()) {
        char b[64];
        std::snprintf(b, sizeof(b), "%.6g", ov.front().shared_mm2);
        throw FlexibleError("face region " + std::to_string(ov.front().face_region_a) + " and face region " +
                            std::to_string(ov.front().face_region_b) + " overlap inside one press (" + b +
                            " mm2); a surface is pressed once");
      }
    }
    // ADJACENCY (C2 B1a, P2): the pieces must form one connected footprint, and two pieces
    // touch when their CLIPPED footprints share an edge segment of positive length (inside
    // both regions' cuts), not merely when their CAD faces are adjacent.
    double scale = 0.0;
    {
      Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
      for (const Vec3& p : model.mesh.vertices) {
        lo = {std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z)};
        hi = {std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z)};
      }
      scale = norm(sub(hi, lo));
    }
    const double tol = 1e-7 * std::max(1.0, scale);
    struct Seg {
      Vec3 a, b;
    };
    std::vector<std::vector<Seg>> segs(footprint.size());
    std::vector<std::pair<Vec3, Vec3>> boxes(footprint.size());
    for (std::size_t k = 0; k < footprint.size(); ++k) {
      TriangleMesh c;
      std::vector<int> ids;
      clip_into(model.mesh, footprint[k]->member_triangles, footprint[k]->cuts, c, ids);
      Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
      for (int id : ids) {
        const auto& t = c.triangles[static_cast<std::size_t>(id)];
        for (int e = 0; e < 3; ++e) {
          const Vec3& p = c.vertices[static_cast<std::size_t>(t[static_cast<std::size_t>(e)])];
          const Vec3& q = c.vertices[static_cast<std::size_t>(t[static_cast<std::size_t>((e + 1) % 3)])];
          segs[k].push_back({p, q});
          lo = {std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z)};
          hi = {std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z)};
        }
      }
      boxes[k] = {lo, hi};
    }
    auto near_box = [&](const Vec3& p, std::size_t k) {
      const Vec3& lo = boxes[k].first;
      const Vec3& hi = boxes[k].second;
      return p.x >= lo.x - tol && p.y >= lo.y - tol && p.z >= lo.z - tol && p.x <= hi.x + tol &&
             p.y <= hi.y + tol && p.z <= hi.z + tol;
    };
    auto touches = [&](std::size_t i, std::size_t j) {
      for (const Seg& sa : segs[i]) {
        if (!near_box(sa.a, j) && !near_box(sa.b, j)) continue;
        const Vec3 d = sub(sa.b, sa.a);
        const double L = norm(d);
        if (!(L > tol)) continue;
        const Vec3 e = mul(d, 1.0 / L);
        for (const Seg& sb : segs[j]) {
          const double t0 = dot(sub(sb.a, sa.a), e), t1 = dot(sub(sb.b, sa.a), e);
          if (norm(sub(sub(sb.a, sa.a), mul(e, t0))) > tol || norm(sub(sub(sb.b, sa.a), mul(e, t1))) > tol)
            continue;  // not on the same line
          const double lo = std::max(0.0, std::min(t0, t1)), hi = std::min(L, std::max(t0, t1));
          if (hi - lo > tol) return true;
        }
      }
      return false;
    };
    std::vector<char> reached(footprint.size(), 0);
    std::vector<std::size_t> todo{0};
    reached[0] = 1;
    while (!todo.empty()) {
      const std::size_t i = todo.back();
      todo.pop_back();
      for (std::size_t j = 0; j < footprint.size(); ++j)
        if (!reached[j] && touches(i, j)) {
          reached[j] = 1;
          todo.push_back(j);
        }
    }
    for (std::size_t j = 0; j < footprint.size(); ++j)
      if (!reached[j])
        throw FlexibleError(name(footprint[0]) + " and " + name(footprint[j]) +
                            " are not adjacent (no shared edge); an edge or corner press needs "
                            "one connected footprint");
  }
  Vec3 dir{0, 0, 0};
  if (press_direction != nullptr) {
    dir = press_unit(*press_direction);  // A10: the one normaliser
    // INTO THE PART over the whole footprint: every triangle must face against it.
    for (const ResolvedFaceRegion* r : footprint)
      for (int ti : r->member_triangles) {
        if (ti < 0 || static_cast<std::size_t>(ti) >= model.mesh.triangles.size()) continue;
        const auto& t = model.mesh.triangles[static_cast<std::size_t>(ti)];
        const Vec3& a = model.mesh.vertices[static_cast<std::size_t>(t[0])];
        const Vec3& b = model.mesh.vertices[static_cast<std::size_t>(t[1])];
        const Vec3& c = model.mesh.vertices[static_cast<std::size_t>(t[2])];
        const Vec3 av = cross(sub(b, a), sub(c, a));
        const double an = norm(av);
        if (!(an > 1e-12)) continue;
        if (!(dot(av, dir) < -1e-9 * an))
          throw FlexibleError("press_direction does not point into the part over " + name(r) +
                              ": part of it faces along the direction or edge-on to it");
      }
  }
  ResolvedFaceRegion u;  // the footprint as one region
  u.id = footprint[0]->id;
  u.name = footprint[0]->name;
  u.cuts = footprint.size() == 1 ? footprint[0]->cuts : std::vector<RegionCut>{};
  for (const ResolvedFaceRegion* r : footprint) {
    u.member_faces.insert(u.member_faces.end(), r->member_faces.begin(), r->member_faces.end());
    u.member_triangles.insert(u.member_triangles.end(), r->member_triangles.begin(),
                              r->member_triangles.end());
    u.area_mm2 += r->area_mm2;
  }
  std::sort(u.member_faces.begin(), u.member_faces.end());
  u.member_faces.erase(std::unique(u.member_faces.begin(), u.member_faces.end()), u.member_faces.end());
  std::sort(u.member_triangles.begin(), u.member_triangles.end());
  u.member_triangles.erase(std::unique(u.member_triangles.begin(), u.member_triangles.end()),
                           u.member_triangles.end());
  bool any_cuts = false;
  for (const ResolvedFaceRegion* r : footprint) any_cuts = any_cuts || !r->cuts.empty();
  Stack s;
  if (footprint.size() > 1 && any_cuts) {
    // SECTORS IN A MULTI-FACE PRESS (ruling 2026-10-07): each part keeps its OWN cuts.
    // The frame is built from every part's triangles clipped by its own cuts; the trace
    // accepts an entry hit only inside its part; each column records its part, so the
    // stack owns only what projects onto its sectors (B5).
    std::vector<std::vector<RegionCut>> part_cuts;
    std::vector<std::vector<int>> tri_parts(model.mesh.triangles.size());
    TriangleMesh clipped;
    std::vector<int> ids;
    for (std::size_t k = 0; k < footprint.size(); ++k) {
      part_cuts.push_back(footprint[k]->cuts);
      // P1 (C2 B1a): two pieces of ONE face in one press put its triangles in both parts.
      for (int t : footprint[k]->member_triangles)
        if (t >= 0 && static_cast<std::size_t>(t) < tri_parts.size())
          tri_parts[static_cast<std::size_t>(t)].push_back(static_cast<int>(k));
      clip_into(model.mesh, footprint[k]->member_triangles, footprint[k]->cuts, clipped, ids);
    }
    for (std::vector<int>& tp : tri_parts)
      if (tp.empty()) tp.push_back(0);
    const FaceFrame fr = face_frame(clipped, ids, rotation_deg, build_dir, press_direction != nullptr ? &dir : nullptr);
    if (!fr.valid) throw FlexibleError(name(footprint[0]) + ": " + fr.reason);
    s = stack_impl(model, u, regions, grid, lattice_mask, rotation_deg, build_dir, pitch_mm,
                   press_direction != nullptr ? &dir : nullptr, &part_cuts, &tri_parts, &fr);
  } else {
    s = stack_impl(model, u, regions, grid, lattice_mask, rotation_deg, build_dir, pitch_mm,
                   press_direction != nullptr ? &dir : nullptr);
  }
  for (const ResolvedFaceRegion* r : footprint) s.footprint_region_ids.push_back(r->id);
  s.press_direction_given = press_direction != nullptr;
  if (s.press_direction_given) s.press_direction = dir;
  return s;
}

Vec3 press_unit(const Vec3& d) {
  const double n = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
  if (!std::isfinite(n) || !(n > 0.0))
    throw FlexibleError("press_direction must be a finite, non-zero vector");
  return {d.x / n, d.y / n, d.z / n};
}

std::vector<SharedFootprint> find_shared_footprints(const TriangleMesh& mesh,
                                                    const std::vector<PressFootprint>& presses) {
  auto area_of = [](const TriangleMesh& m, const std::vector<int>& ids) {
    double a = 0.0;
    for (int t : ids) {
      const auto& tr = m.triangles[static_cast<std::size_t>(t)];
      const Vec3& p = m.vertices[static_cast<std::size_t>(tr[0])];
      const Vec3& q = m.vertices[static_cast<std::size_t>(tr[1])];
      const Vec3& r = m.vertices[static_cast<std::size_t>(tr[2])];
      a += 0.5 * norm(cross(sub(q, p), sub(r, p)));
    }
    return a;
  };
  std::vector<SharedFootprint> out;
  for (std::size_t i = 0; i < presses.size(); ++i)
    for (std::size_t j = i + 1; j < presses.size(); ++j)
      for (const ResolvedFaceRegion* a : presses[i].regions)
        for (const ResolvedFaceRegion* b : presses[j].regions) {
          std::vector<int> ta = a->member_triangles, tb = b->member_triangles, shared;
          std::sort(ta.begin(), ta.end());
          std::sort(tb.begin(), tb.end());
          std::set_intersection(ta.begin(), ta.end(), tb.begin(), tb.end(), std::back_inserter(shared));
          if (shared.empty()) continue;
          // The shared triangles inside BOTH regions' cuts (the intersection of the
          // half-spaces is convex, so clipping by the union of the cuts is exact).
          std::vector<RegionCut> both = a->cuts;
          both.insert(both.end(), b->cuts.begin(), b->cuts.end());
          TriangleMesh clipped;
          std::vector<int> ids;
          clip_into(mesh, shared, both, clipped, ids);
          const double area = area_of(clipped, ids);
          if (!(area > 1e-6)) continue;
          out.push_back({presses[i].press_id, presses[j].press_id, a->id, b->id, area});
        }
  return out;
}

std::string shared_footprint_sentence(const SharedFootprint& s) {
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%.6g", s.shared_mm2);
  return "presses " + std::to_string(s.press_a) + " and " + std::to_string(s.press_b) +
         " share surface (face region " + std::to_string(s.face_region_a) + " and face region " +
         std::to_string(s.face_region_b) + " overlap by " + buf +
         " mm2); a surface is pressed by one press: split the face so the sectors do not overlap";
}

void refuse_shared_footprints(const TriangleMesh& mesh, const std::vector<PressFootprint>& presses) {
  const std::vector<SharedFootprint> sh = find_shared_footprints(mesh, presses);
  if (!sh.empty()) throw FlexibleError(shared_footprint_sentence(sh.front()));
}

namespace {
// Keep the columns `keep` accepts; the map spans the kept cells. Returns how many were dropped.
template <class Pred>
int keep_columns(Stack& s, const std::vector<ResolvedFaceRegion>& regions, Pred keep, const char* why) {
  std::vector<StackColumn> kept;
  int dropped = 0;
  double u0 = 1e300, u1 = -1e300, v0 = 1e300, v1 = -1e300;
  for (const StackColumn& c : s.columns) {
    if (!keep(c)) {
      ++dropped;
      continue;
    }
    kept.push_back(c);
    u0 = std::min(u0, c.iu * s.pitch_mm);
    u1 = std::max(u1, (c.iu + 1) * s.pitch_mm);
    v0 = std::min(v0, c.iv * s.pitch_mm);
    v1 = std::max(v1, (c.iv + 1) * s.pitch_mm);
  }
  if (kept.empty())
    throw FlexibleError("face region " + std::to_string(s.face_region_id) + " " + why + ": none of its " +
                        std::to_string(s.columns.size()) + " columns qualifies");
  s.columns = std::move(kept);
  // the map spans the kept cells, clipped to the frame
  s.map_u0 = std::max(0.0, u0);
  s.map_u1 = std::min(s.frame.u_extent_mm, u1);
  s.map_v0 = std::max(0.0, v0);
  s.map_v1 = std::min(s.frame.v_extent_mm, v1);
  finish_stack(s, regions);
  return dropped;
}
}  // namespace

void restrict_to_lattice(Stack& s, const std::vector<ResolvedFaceRegion>& regions) {
  s.over_solid_columns =
      keep_columns(s, regions, [](const StackColumn& c) { return c.lattice_mm > 0.0; }, "has no lattice under it");
}

void restrict_to_flat_prism(Stack& s, const Vec3& apex, double depth_mm,
                            const std::vector<ResolvedFaceRegion>& regions) {
  if (!(depth_mm > 0.0) || !std::isfinite(depth_mm))
    throw FlexibleError("face region " + std::to_string(s.face_region_id) + ": a flat prism's depth must be > 0");
  s.has_flat_prism = true;
  s.flat_apex = apex;
  s.flat_depth_mm = depth_mm;
  const double tol = 1e-9 * std::max(1.0, depth_mm);
  s.outside_flat_prism_columns = keep_columns(
      s, regions,
      [&](const StackColumn& c) {
        const Vec3 e = add(s.frame.from_uv(c.u_mm, c.v_mm), mul(s.frame.load, c.entry_t));
        return dot(sub(e, apex), s.frame.load) <= depth_mm + tol;
      },
      "has no column inside its flat prism");
}

bool stack_owns_projection(const Stack& s, const Vec3& p) {
  if (s.cuts.empty() && s.part_cuts.empty()) return true;
  double u = 0, v = 0;
  s.frame.to_uv(p, u, v);
  const int iu = static_cast<int>(std::floor(u / s.pitch_mm)), iv = static_cast<int>(std::floor(v / s.pitch_mm));
  if (iu < 0 || iv < 0 || iu >= s.nu || iv >= s.nv || s.cell_tris.empty()) return false;
  const Vec3 back = mul(s.frame.load, -1.0);
  // The nearest footprint triangle along the back-ray (the first, on a tie between two
  // triangles: as before). A triangle in two parts (two pieces of one face, P1) is owned when
  // the hit passes EITHER part's cuts.
  double best = 1e300;
  int best_tri = -1;
  for (int k : s.cell_tris[static_cast<std::size_t>(iv) * static_cast<std::size_t>(s.nu) +
                           static_cast<std::size_t>(iu)]) {
    const Stack::FootTri& ft = s.foot_tris[static_cast<std::size_t>(k)];
    double th = 0.0;
    if (line_hit(p, back, ft.a, ft.b, ft.c, th) && th >= -1e-9 && th < best) {
      best = th;
      best_tri = ft.tri;
    }
  }
  if (!(best < 1e300)) return false;
  const Vec3 hit = add(p, mul(back, best));
  for (int k : s.cell_tris[static_cast<std::size_t>(iv) * static_cast<std::size_t>(s.nu) +
                           static_cast<std::size_t>(iu)]) {
    const Stack::FootTri& ft = s.foot_tris[static_cast<std::size_t>(k)];
    if (ft.tri != best_tri) continue;
    const std::vector<RegionCut>& cuts =
        s.part_cuts.empty() ? s.cuts : s.part_cuts[static_cast<std::size_t>(ft.part)];
    if (passes_cuts(cuts, hit)) return true;
  }
  return false;
}

}  // namespace flexible
}  // namespace topopt
