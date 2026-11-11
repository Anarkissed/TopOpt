// Lattice layout, stage B: the part measured on its real surface. See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <cmath>
#include <map>
#include <unordered_map>
#include <utility>

namespace topopt::lattice_layout {

TriangleMesh weld_mesh(const TriangleMesh& in, double tol_mm, std::size_t* open_edges) {
  TriangleMesh out;
  struct Key {
    long long x, y, z;
    bool operator==(const Key& o) const { return x == o.x && y == o.y && z == o.z; }
  };
  struct Hash {
    std::size_t operator()(const Key& k) const {
      return std::hash<long long>()(k.x * 73856093LL ^ k.y * 19349663LL ^ k.z * 83492791LL);
    }
  };
  const double q = 1.0 / (tol_mm > 0.0 ? tol_mm : 1e-5);
  std::unordered_map<Key, int, Hash> ids;
  ids.reserve(in.vertices.size());
  auto id_of = [&](const Vec3& v) {
    const Key k{std::llround(v.x * q), std::llround(v.y * q), std::llround(v.z * q)};
    auto it = ids.find(k);
    if (it != ids.end()) return it->second;
    const int n = static_cast<int>(out.vertices.size());
    out.vertices.push_back(v);
    ids.emplace(k, n);
    return n;
  };
  std::map<std::pair<int, int>, int> edges;
  for (const auto& t : in.triangles) {
    const int a = id_of(in.vertices[t[0]]), b = id_of(in.vertices[t[1]]),
              c = id_of(in.vertices[t[2]]);
    if (a == b || b == c || a == c) continue;  // collapsed by the weld
    out.triangles.push_back({a, b, c});
    const int e[3][2] = {{a, b}, {b, c}, {c, a}};
    for (const auto& p : e) ++edges[{std::min(p[0], p[1]), std::max(p[0], p[1])}];
  }
  if (open_edges) {
    *open_edges = 0;
    for (const auto& kv : edges)
      if (kv.second != 2) ++*open_edges;
  }
  return out;
}

PartMeasure::PartMeasure(TriangleMesh mesh)
    : mesh_(std::make_shared<const TriangleMesh>(std::move(mesh))) {
  lo_ = Vec3{1e300, 1e300, 1e300};
  hi_ = Vec3{-1e300, -1e300, -1e300};
  for (const Vec3& v : mesh_->vertices) {
    lo_.x = std::min(lo_.x, v.x); lo_.y = std::min(lo_.y, v.y); lo_.z = std::min(lo_.z, v.z);
    hi_.x = std::max(hi_.x, v.x); hi_.y = std::max(hi_.y, v.y); hi_.z = std::max(hi_.z, v.z);
  }
  if (mesh_->vertices.empty()) lo_ = hi_ = Vec3{};
  diag_ = std::sqrt((hi_.x - lo_.x) * (hi_.x - lo_.x) + (hi_.y - lo_.y) * (hi_.y - lo_.y) +
                    (hi_.z - lo_.z) * (hi_.z - lo_.z));
}

// Walk from p along the direction by the exact distance to the surface: a step of that
// length can never cross it. Each step lands nearer, and on a face met square-on the
// first step lands on it exactly. Stops within a micron.
double PartMeasure::Probe::reach(const Vec3& p, const Vec3& d) const {
  const double kStop = 1e-3;   // mm
  double t = 0.0;
  for (int i = 0; i < 4096 && t < max_mm_; ++i) {
    const double s = md_.signed_distance(Vec3{p.x + d.x * t, p.y + d.y * t, p.z + d.z * t});
    if (s <= kStop) return i == 0 && s <= 0.0 ? 0.0 : t + std::max(s, 0.0);
    t += s;
  }
  return t;
}

}  // namespace topopt::lattice_layout
