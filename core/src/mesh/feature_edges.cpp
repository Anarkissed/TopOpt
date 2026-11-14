// ★ Feature edges of a shipped surface (ruling 11-08 (A)). topopt/feature_edges.hpp states
// the contract.

#include "topopt/feature_edges.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <map>
#include <numeric>
#include <tuple>
#include <utility>

namespace topopt {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kWeldMm = 1e-6;  // positions closer than this are one vertex

Vec3 vsub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 vcross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double vdot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
double vnorm(const Vec3& a) { return std::sqrt(vdot(a, a)); }

struct FaceRef {
  int tri;
  bool forward;  // the face's winding runs key.first -> key.second
};

int find_root(std::vector<int>& p, int i) {
  while (p[static_cast<std::size_t>(i)] != i) {
    p[static_cast<std::size_t>(i)] = p[static_cast<std::size_t>(p[static_cast<std::size_t>(i)])];
    i = p[static_cast<std::size_t>(i)];
  }
  return i;
}

}  // namespace

std::vector<FeatureChain> mesh_feature_chains(const TriangleMesh& mesh,
                                              double angle_threshold_deg,
                                              double min_piece_mm,
                                              FeatureEdgeStats* stats) {
  FeatureEdgeStats st;
  st.angle_threshold_deg = angle_threshold_deg;
  st.min_piece_mm = min_piece_mm;

  // ── weld by position ──────────────────────────────────────────────────────
  std::vector<Vec3> P;
  std::vector<int> weld(mesh.vertices.size(), -1);
  {
    std::map<std::tuple<long long, long long, long long>, int> at;
    for (std::size_t i = 0; i < mesh.vertices.size(); ++i) {
      const Vec3& v = mesh.vertices[i];
      const auto k = std::make_tuple(std::llround(v.x / kWeldMm), std::llround(v.y / kWeldMm),
                                     std::llround(v.z / kWeldMm));
      auto it = at.find(k);
      if (it == at.end()) {
        it = at.emplace(k, static_cast<int>(P.size())).first;
        P.push_back(v);
      }
      weld[i] = it->second;
    }
  }
  st.welded_vertices = P.size();

  // ── faces: unit normals, degenerate ones left out ─────────────────────────
  std::vector<std::array<int, 3>> T;
  std::vector<Vec3> N;
  for (const auto& t : mesh.triangles) {
    const std::array<int, 3> w{weld[static_cast<std::size_t>(t[0])],
                               weld[static_cast<std::size_t>(t[1])],
                               weld[static_cast<std::size_t>(t[2])]};
    if (w[0] == w[1] || w[1] == w[2] || w[2] == w[0]) continue;
    const Vec3& a = P[static_cast<std::size_t>(w[0])];
    const Vec3 n = vcross(vsub(P[static_cast<std::size_t>(w[1])], a),
                          vsub(P[static_cast<std::size_t>(w[2])], a));
    const double l = vnorm(n);
    if (!(l > 1e-14)) continue;
    T.push_back(w);
    N.push_back({n.x / l, n.y / l, n.z / l});
  }

  // ── edges and their faces ─────────────────────────────────────────────────
  std::map<std::pair<int, int>, std::vector<FaceRef>> E;
  for (std::size_t f = 0; f < T.size(); ++f)
    for (int c = 0; c < 3; ++c) {
      const int a = T[f][static_cast<std::size_t>(c)];
      const int b = T[f][static_cast<std::size_t>((c + 1) % 3)];
      const auto key = a < b ? std::make_pair(a, b) : std::make_pair(b, a);
      E[key].push_back({static_cast<int>(f), a < b});
    }

  // Feature edges: endpoints (key order), the face whose winding runs first -> second
  // (`fwd`) and the other (`bwd`), and the angle.
  struct FE {
    int u, v;
    int fwd, bwd;
    double angle;
  };
  std::vector<FE> fe;
  const double cos_thr = std::cos(angle_threshold_deg * kPi / 180.0);
  for (const auto& [key, faces] : E) {
    if (faces.size() == 1) { ++st.open_edges; continue; }
    if (faces.size() > 2) { ++st.nonmanifold_edges; continue; }
    ++st.edges;
    const Vec3& n0 = N[static_cast<std::size_t>(faces[0].tri)];
    const Vec3& n1 = N[static_cast<std::size_t>(faces[1].tri)];
    const double c = std::clamp(vdot(n0, n1), -1.0, 1.0);
    if (!(c < cos_thr)) continue;
    // A consistently wound pair runs the edge both ways; if not, the first face stands as
    // the forward one (the angle is the same, only left / right could swap).
    const bool f0 = faces[0].forward;
    const int fwd = f0 || !faces[1].forward ? faces[0].tri : faces[1].tri;
    const int bwd = fwd == faces[0].tri ? faces[1].tri : faces[0].tri;
    fe.push_back({key.first, key.second, fwd, bwd, std::acos(c) * 180.0 / kPi});
  }
  st.feature_edges = fe.size();

  // ── pieces (connected through corners) and their lengths ──────────────────
  std::vector<int> parent(P.size());
  std::iota(parent.begin(), parent.end(), 0);
  for (const FE& e : fe) {
    const int a = find_root(parent, e.u), b = find_root(parent, e.v);
    if (a != b) parent[static_cast<std::size_t>(std::max(a, b))] = std::min(a, b);
  }
  std::map<int, double> piece_len;
  for (const FE& e : fe)
    piece_len[find_root(parent, e.u)] +=
        vnorm(vsub(P[static_cast<std::size_t>(e.v)], P[static_cast<std::size_t>(e.u)]));
  std::map<int, int> piece_id;  // root -> kept id (1-based), 0 = dropped
  for (const auto& [root, len] : piece_len) {
    if (len < min_piece_mm) {
      piece_id[root] = 0;
      ++st.pieces_dropped_short;
      st.length_dropped_mm += len;
    } else {
      piece_id[root] = static_cast<int>(++st.pieces);
    }
  }

  // ── chains: walk between vertices where the graph does not simply continue ─
  std::vector<std::vector<int>> inc(P.size());
  for (std::size_t i = 0; i < fe.size(); ++i) {
    inc[static_cast<std::size_t>(fe[i].u)].push_back(static_cast<int>(i));
    inc[static_cast<std::size_t>(fe[i].v)].push_back(static_cast<int>(i));
  }
  std::vector<char> used(fe.size(), 0);
  std::vector<FeatureChain> out;
  // Append edge `ei` walked from vertex `from` to the chain; returns the far vertex.
  auto step = [&](FeatureChain& ch, int ei, int from) {
    const FE& e = fe[static_cast<std::size_t>(ei)];
    const int to = e.u == from ? e.v : e.u;
    // left = the face whose winding runs from -> to
    const bool along_key = (from == e.u);
    const int left = along_key ? e.fwd : e.bwd, right = along_key ? e.bwd : e.fwd;
    const Vec3& nl = N[static_cast<std::size_t>(left)];
    const Vec3& nr = N[static_cast<std::size_t>(right)];
    const Vec3 d = vsub(P[static_cast<std::size_t>(to)], P[static_cast<std::size_t>(from)]);
    ch.left_normal.push_back(nl);
    ch.right_normal.push_back(nr);
    ch.angle_deg.push_back(e.angle);
    ch.convex.push_back(vdot(vcross(nl, nr), d) > 0.0 ? 1 : 0);
    ch.length_mm += vnorm(d);
    used[static_cast<std::size_t>(ei)] = 1;
    return to;
  };
  auto next_unused = [&](int v) {
    for (int ei : inc[static_cast<std::size_t>(v)])
      if (!used[static_cast<std::size_t>(ei)]) return ei;
    return -1;
  };
  auto finish = [&](FeatureChain&& ch, int any_vertex) {
    const int pid = piece_id[find_root(parent, any_vertex)];
    if (pid == 0) {
      ++st.chains_dropped_short;
      return;
    }
    ch.piece = pid;
    st.length_mm += ch.length_mm;
    ++st.chains;
    out.push_back(std::move(ch));
  };
  for (std::size_t v0 = 0; v0 < P.size(); ++v0) {
    if (inc[v0].empty() || inc[v0].size() == 2) continue;
    for (int ei0 : inc[v0]) {
      if (used[static_cast<std::size_t>(ei0)]) continue;
      FeatureChain ch;
      ch.points.push_back(P[v0]);
      int v = step(ch, ei0, static_cast<int>(v0));
      ch.points.push_back(P[static_cast<std::size_t>(v)]);
      while (inc[static_cast<std::size_t>(v)].size() == 2) {
        const int ei = next_unused(v);
        if (ei < 0) break;
        v = step(ch, ei, v);
        ch.points.push_back(P[static_cast<std::size_t>(v)]);
      }
      finish(std::move(ch), static_cast<int>(v0));
    }
  }
  // Closed loops: every vertex on them continues (degree 2).
  for (std::size_t ei0 = 0; ei0 < fe.size(); ++ei0) {
    if (used[ei0]) continue;
    FeatureChain ch;
    ch.closed = true;
    const int start = fe[ei0].u;
    ch.points.push_back(P[static_cast<std::size_t>(start)]);
    int v = step(ch, static_cast<int>(ei0), start);
    while (v != start) {
      ch.points.push_back(P[static_cast<std::size_t>(v)]);
      const int ei = next_unused(v);
      if (ei < 0) { ch.closed = false; break; }   // cannot happen on a degree-2 loop
      v = step(ch, ei, v);
    }
    finish(std::move(ch), start);
  }
  if (stats) *stats = st;
  return out;
}

}  // namespace topopt
