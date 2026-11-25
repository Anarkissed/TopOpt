// face_loads.cpp -- see face_loads.hpp.
#include "topopt/face_loads.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <stdexcept>
#include <string>

namespace topopt {

namespace {

Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double norm(const Vec3& a) { return std::sqrt(dot(a, a)); }

// Cut one triangle at the middle of its longest side until every side is short
// enough; each final piece reports its centre and its own area.
void cut(const Vec3& a, const Vec3& b, const Vec3& c, const Vec3& unit_normal,
         double max_edge2, std::vector<FacePiece>& out) {
  const double ab = dot(sub(b, a), sub(b, a));
  const double bc = dot(sub(c, b), sub(c, b));
  const double ca = dot(sub(a, c), sub(a, c));
  const double longest = std::max(ab, std::max(bc, ca));
  if (longest <= max_edge2) {
    const double area = 0.5 * norm(cross(sub(b, a), sub(c, a)));
    if (area > 0.0)
      out.push_back({mul(add(add(a, b), c), 1.0 / 3.0), unit_normal, area});
    return;
  }
  if (longest == ab) {
    const Vec3 m = mul(add(a, b), 0.5);
    cut(a, m, c, unit_normal, max_edge2, out);
    cut(m, b, c, unit_normal, max_edge2, out);
  } else if (longest == bc) {
    const Vec3 m = mul(add(b, c), 0.5);
    cut(a, b, m, unit_normal, max_edge2, out);
    cut(a, m, c, unit_normal, max_edge2, out);
  } else {
    const Vec3 m = mul(add(c, a), 0.5);
    cut(a, b, m, unit_normal, max_edge2, out);
    cut(m, b, c, unit_normal, max_edge2, out);
  }
}

void check_model(const StepModel& model, const char* who) {
  if (model.triangle_face.size() != model.mesh.triangles.size())
    throw std::invalid_argument(std::string(who) +
                                ": triangle_face is not parallel to mesh.triangles");
}

void cut_triangle(const StepModel& model, std::size_t t, double max_edge2,
                  std::vector<FacePiece>& out) {
  const auto& tri = model.mesh.triangles[t];
  const Vec3& a = model.mesh.vertices[static_cast<std::size_t>(tri[0])];
  const Vec3& b = model.mesh.vertices[static_cast<std::size_t>(tri[1])];
  const Vec3& c = model.mesh.vertices[static_cast<std::size_t>(tri[2])];
  const Vec3 n = cross(sub(b, a), sub(c, a));
  const double len = norm(n);
  if (!(len > 0.0)) return;  // a sliver carries no area
  cut(a, b, c, mul(n, 1.0 / len), max_edge2, out);
}

// Squared distance from p to triangle (a,b,c) (Ericson, closest point on triangle).
double point_tri_dist2(const Vec3& p, const Vec3& a, const Vec3& b, const Vec3& c) {
  const Vec3 ab = sub(b, a), ac = sub(c, a), ap = sub(p, a);
  const double d1 = dot(ab, ap), d2 = dot(ac, ap);
  Vec3 q;
  if (d1 <= 0.0 && d2 <= 0.0) {
    q = a;
  } else {
    const Vec3 bp = sub(p, b);
    const double d3 = dot(ab, bp), d4 = dot(ac, bp);
    if (d3 >= 0.0 && d4 <= d3) {
      q = b;
    } else {
      const Vec3 cp = sub(p, c);
      const double d5 = dot(ab, cp), d6 = dot(ac, cp);
      const double vc = d1 * d4 - d3 * d2, vb = d5 * d2 - d1 * d6,
                   va = d3 * d6 - d5 * d4;
      if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        q = add(a, mul(ab, d1 / (d1 - d3)));
      } else if (d6 >= 0.0 && d5 <= d6) {
        q = c;
      } else if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        q = add(a, mul(ac, d2 / (d2 - d6)));
      } else if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
        q = add(b, mul(sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6))));
      } else {
        const double denom = 1.0 / (va + vb + vc);
        q = add(add(a, mul(ab, vb * denom)), mul(ac, vc * denom));
      }
    }
  }
  const Vec3 d = sub(p, q);
  return dot(d, d);
}

// The solid voxel a piece lies on: the voxel just inside the face, or the nearest
// solid voxel (distance from the piece to the voxel's cube) within one voxel.
bool host_voxel(const VoxelGrid& g, const FacePiece& piece, int& hi, int& hj, int& hk) {
  const double h = g.spacing;
  const Vec3 inside = sub(piece.point, mul(piece.normal, 0.01 * h));
  const int ci = static_cast<int>(std::floor((inside.x - g.origin.x) / h));
  const int cj = static_cast<int>(std::floor((inside.y - g.origin.y) / h));
  const int ck = static_cast<int>(std::floor((inside.z - g.origin.z) / h));
  auto in_grid = [&](int i, int j, int k) {
    return i >= 0 && j >= 0 && k >= 0 && i < g.nx && j < g.ny && k < g.nz;
  };
  if (in_grid(ci, cj, ck) && g.solid(ci, cj, ck)) {
    hi = ci;
    hj = cj;
    hk = ck;
    return true;
  }
  double best = h * h * (1.0 + 1e-9);
  bool found = false;
  for (int dk = -1; dk <= 1; ++dk)
    for (int dj = -1; dj <= 1; ++dj)
      for (int di = -1; di <= 1; ++di) {
        const int i = ci + di, j = cj + dj, k = ck + dk;
        if (!in_grid(i, j, k) || !g.solid(i, j, k)) continue;
        const double lo[3] = {g.origin.x + i * h, g.origin.y + j * h, g.origin.z + k * h};
        const double p[3] = {piece.point.x, piece.point.y, piece.point.z};
        double d2 = 0.0;
        for (int a = 0; a < 3; ++a) {
          const double q = std::min(std::max(p[a], lo[a]), lo[a] + h);
          d2 += (p[a] - q) * (p[a] - q);
        }
        // Prefer the voxel behind the face over one beside it at equal distance.
        const Vec3 centre = g.voxel_center(i, j, k);
        const double behind = dot(sub(piece.point, centre), piece.normal);
        d2 -= 1e-9 * h * behind;
        if (d2 < best) {
          best = d2;
          hi = i;
          hj = j;
          hk = k;
          found = true;
        }
      }
  return found;
}

}  // namespace

std::vector<FacePiece> face_pieces(const StepModel& model,
                                   const std::vector<int>& face_ids, double max_edge) {
  check_model(model, "face_pieces");
  if (!(max_edge > 0.0)) throw std::invalid_argument("face_pieces: max_edge must be > 0");
  for (int f : face_ids)
    if (f < 0 || f >= model.face_count)
      throw std::invalid_argument("face_pieces: face_id " + std::to_string(f) +
                                  " out of range (the model carries " +
                                  std::to_string(model.face_count) + " faces)");
  std::vector<char> wanted(static_cast<std::size_t>(std::max(model.face_count, 0)), 0);
  for (int f : face_ids) wanted[static_cast<std::size_t>(f)] = 1;
  std::vector<FacePiece> out;
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    const int f = model.triangle_face[t];
    if (f < 0 || f >= model.face_count || !wanted[static_cast<std::size_t>(f)]) continue;
    cut_triangle(model, t, max_edge * max_edge, out);
  }
  return out;
}

std::vector<FacePiece> triangle_pieces(const StepModel& model,
                                       const std::vector<int>& triangles,
                                       double max_edge) {
  if (!(max_edge > 0.0))
    throw std::invalid_argument("triangle_pieces: max_edge must be > 0");
  std::vector<FacePiece> out;
  for (int t : triangles) {
    if (t < 0 || static_cast<std::size_t>(t) >= model.mesh.triangles.size())
      throw std::invalid_argument("triangle_pieces: triangle index out of range");
    cut_triangle(model, static_cast<std::size_t>(t), max_edge * max_edge, out);
  }
  return out;
}

std::vector<NodeArea> face_node_areas(const VoxelGrid& grid,
                                      const std::vector<FacePiece>& pieces,
                                      FaceAreaReport* report) {
  const double h = grid.spacing;
  if (!(h > 0.0)) throw std::invalid_argument("face_node_areas: grid spacing must be > 0");
  struct Acc {
    double area = 0.0;
    Vec3 n;
  };
  std::map<int, Acc> acc;
  FaceAreaReport rep;
  rep.pieces = pieces.size();
  Vec3 drawn_sum, placed_sum;
  for (const FacePiece& piece : pieces) {
    rep.drawn_area += piece.area;
    drawn_sum = add(drawn_sum, mul(piece.point, piece.area));
    int i = 0, j = 0, k = 0;
    if (!host_voxel(grid, piece, i, j, k)) {
      ++rep.unplaced;
      continue;
    }
    rep.placed_area += piece.area;
    // Where the piece sits in its voxel, each coordinate held to [0, 1].
    const double u = std::min(std::max((piece.point.x - grid.origin.x) / h - i, 0.0), 1.0);
    const double v = std::min(std::max((piece.point.y - grid.origin.y) / h - j, 0.0), 1.0);
    const double w = std::min(std::max((piece.point.z - grid.origin.z) / h - k, 0.0), 1.0);
    for (int c = 0; c < 2; ++c)
      for (int b = 0; b < 2; ++b)
        for (int a = 0; a < 2; ++a) {
          const double share = (a ? u : 1.0 - u) * (b ? v : 1.0 - v) * (c ? w : 1.0 - w);
          if (!(share > 0.0)) continue;
          Acc& e = acc[fea_node_index(grid, i + a, j + b, k + c)];
          e.area += share * piece.area;
          e.n = add(e.n, mul(piece.normal, share * piece.area));
          placed_sum = add(placed_sum,
                           mul(Vec3{grid.origin.x + (i + a) * h, grid.origin.y + (j + b) * h,
                                    grid.origin.z + (k + c) * h},
                               share * piece.area));
        }
  }
  if (rep.drawn_area > 0.0) rep.drawn_centre = mul(drawn_sum, 1.0 / rep.drawn_area);
  if (rep.placed_area > 0.0) rep.placed_centre = mul(placed_sum, 1.0 / rep.placed_area);
  if (report) *report = rep;
  std::vector<NodeArea> out;
  out.reserve(acc.size());
  for (const auto& kv : acc) {
    const double len = norm(kv.second.n);
    out.push_back({kv.first, kv.second.area,
                   len > 0.0 ? mul(kv.second.n, 1.0 / len) : Vec3{0.0, 0.0, 0.0}});
  }
  return out;
}

std::vector<NodalLoad> face_traction_loads(const std::vector<NodeArea>& areas,
                                           Vec3 total_force) {
  double total_area = 0.0;
  for (const NodeArea& a : areas) total_area += a.area;
  if (!(total_area > 0.0))
    throw std::invalid_argument(
        "face_traction_loads: the face found no solid voxel to load");
  const double f[3] = {total_force.x, total_force.y, total_force.z};
  std::vector<NodalLoad> loads;
  for (const NodeArea& a : areas)
    for (int c = 0; c < 3; ++c) {
      const double v = f[c] * (a.area / total_area);
      if (v != 0.0) loads.push_back({a.node, c, v});
    }
  return loads;
}

std::vector<DirichletBC> face_clamp_bcs(const VoxelGrid& grid,
                                        const std::vector<NodeArea>& areas,
                                        double min_area_fraction) {
  const double floor_area = min_area_fraction * grid.spacing * grid.spacing;
  std::vector<DirichletBC> bcs;
  for (const NodeArea& a : areas) {
    if (a.area < floor_area) continue;
    for (int c = 0; c < 3; ++c) {
      DirichletBC bc;
      bc.node = a.node;
      bc.component = c;
      bc.value = 0.0;
      bcs.push_back(bc);
    }
  }
  return bcs;
}

std::vector<DirichletBC> face_spring_bcs(const std::vector<NodeArea>& areas,
                                         double stiffness_per_area) {
  if (!(stiffness_per_area > 0.0))
    throw std::invalid_argument("face_spring_bcs: stiffness_per_area must be > 0");
  std::vector<DirichletBC> bcs;
  for (const NodeArea& a : areas) {
    if (!(a.area > 0.0)) continue;
    DirichletBC bc;
    bc.node = a.node;
    bc.component = 0;
    bc.spring = stiffness_per_area * a.area;
    bc.spring_tangent = bc.spring;  // the same in every direction
    bc.normal = a.normal;
    bc.contact = false;             // a plain spring: it never lets go
    bcs.push_back(bc);
  }
  return bcs;
}

std::size_t mask_face_depth_mm(const VoxelGrid& grid, const StepModel& model,
                               const std::vector<int>& face_ids, double depth_mm,
                               MaskValue mask_value, DesignMask& mask,
                               std::vector<float>* fraction) {
  check_model(model, "mask_face_depth_mm");
  if (!(depth_mm > 0.0))
    throw std::invalid_argument("mask_face_depth_mm: depth_mm must be > 0");
  if (mask.size() != grid.voxel_count())
    throw std::invalid_argument("mask_face_depth_mm: mask size != voxel_count");
  const double h = grid.spacing;
  std::vector<char> wanted(static_cast<std::size_t>(std::max(model.face_count, 0)), 0);
  for (int f : face_ids) {
    if (f < 0 || f >= model.face_count)
      throw std::invalid_argument("mask_face_depth_mm: face_id " + std::to_string(f) +
                                  " out of range");
    wanted[static_cast<std::size_t>(f)] = 1;
  }
  // The faces' triangles and the box of voxels that can be within reach of them.
  std::vector<std::array<Vec3, 3>> tris;
  double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    const int f = model.triangle_face[t];
    if (f < 0 || f >= model.face_count || !wanted[static_cast<std::size_t>(f)]) continue;
    const auto& tri = model.mesh.triangles[t];
    std::array<Vec3, 3> T{model.mesh.vertices[static_cast<std::size_t>(tri[0])],
                          model.mesh.vertices[static_cast<std::size_t>(tri[1])],
                          model.mesh.vertices[static_cast<std::size_t>(tri[2])]};
    for (const Vec3& p : T) {
      lo[0] = std::min(lo[0], p.x); hi[0] = std::max(hi[0], p.x);
      lo[1] = std::min(lo[1], p.y); hi[1] = std::max(hi[1], p.y);
      lo[2] = std::min(lo[2], p.z); hi[2] = std::max(hi[2], p.z);
    }
    tris.push_back(T);
  }
  if (fraction) fraction->assign(grid.voxel_count(), 0.0f);
  if (tris.empty()) return 0;
  const double reach = depth_mm + h;  // a voxel partly inside has its centre this near
  const double org[3] = {grid.origin.x, grid.origin.y, grid.origin.z};
  const int n[3] = {grid.nx, grid.ny, grid.nz};
  int a0[3], a1[3];
  for (int a = 0; a < 3; ++a) {
    a0[a] = std::max(0, static_cast<int>(std::floor((lo[a] - reach - org[a]) / h)));
    a1[a] = std::min(n[a] - 1, static_cast<int>(std::floor((hi[a] + reach - org[a]) / h)));
  }
  auto dist2 = [&](const Vec3& p) {
    double best = 1e300;
    for (const auto& T : tris) best = std::min(best, point_tri_dist2(p, T[0], T[1], T[2]));
    return best;
  };
  const double depth2 = depth_mm * depth_mm;
  const double half_diag = 0.5 * std::sqrt(3.0) * h;
  std::size_t set = 0;
  auto freeze = [&](int i, int j, int k) {
    MaskValue& m = mask[grid.index(i, j, k)];
    if (m != mask_value) {
      m = mask_value;
      ++set;
    }
  };
  constexpr int kSub = 4;
  for (int k = a0[2]; k <= a1[2]; ++k)
    for (int j = a0[1]; j <= a1[1]; ++j)
      for (int i = a0[0]; i <= a1[0]; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const Vec3 centre = grid.voxel_center(i, j, k);
        const double d2 = dist2(centre);
        if (d2 <= depth2) freeze(i, j, k);
        if (!fraction) continue;
        const double d = std::sqrt(d2);
        float fr;
        if (d + half_diag <= depth_mm) {
          fr = 1.0f;
        } else if (d - half_diag > depth_mm) {
          fr = 0.0f;
        } else {
          int in = 0;
          for (int c = 0; c < kSub; ++c)
            for (int b = 0; b < kSub; ++b)
              for (int a = 0; a < kSub; ++a) {
                const Vec3 p{org[0] + (i + (a + 0.5) / kSub) * h,
                             org[1] + (j + (b + 0.5) / kSub) * h,
                             org[2] + (k + (c + 0.5) / kSub) * h};
                if (dist2(p) <= depth2) ++in;
              }
          fr = static_cast<float>(in) / (kSub * kSub * kSub);
        }
        (*fraction)[grid.index(i, j, k)] = fr;
      }
  // A protection never freezes nothing: the voxels the face lies on are always in.
  for (const FacePiece& piece : face_pieces(model, face_ids, 0.5 * h)) {
    int i = 0, j = 0, k = 0;
    if (host_voxel(grid, piece, i, j, k)) freeze(i, j, k);
  }
  return set;
}

}  // namespace topopt
