// Bounded simplification of a contoured field (topopt/mesh_simplify.hpp states the contract).

#include "topopt/mesh_simplify.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <queue>
#include <set>

namespace topopt {

namespace {

Vec3 sub3(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 cross3(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double dot3(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
double len3(const Vec3& a) { return std::sqrt(dot3(a, a)); }

std::uint64_t key_of(const Vec3& p) {
  std::uint64_t h = 1469598103934665603ull;
  for (double d : {p.x, p.y, p.z}) {
    std::uint64_t b;
    std::memcpy(&b, &d, sizeof b);
    h = (h ^ b) * 1099511628211ull;
  }
  return h;
}

// Quadric of the plane through a triangle, weighted by its area (Garland & Heckbert).
void add_plane(double q[10], const Vec3& a, const Vec3& b, const Vec3& c) {
  const Vec3 n = cross3(sub3(b, a), sub3(c, a));
  const double l = len3(n);
  if (!(l > 1e-300)) return;
  const double w = 0.5 * l;
  const double nx = n.x / l, ny = n.y / l, nz = n.z / l, d = -(nx * a.x + ny * a.y + nz * a.z);
  const double v[4] = {nx, ny, nz, d};
  int k = 0;
  for (int i = 0; i < 4; ++i)
    for (int j = i; j < 4; ++j) q[k++] += w * v[i] * v[j];
}

double quadric_cost(const double q[10], const Vec3& p) {
  const double x = p.x, y = p.y, z = p.z;
  return q[0] * x * x + 2 * q[1] * x * y + 2 * q[2] * x * z + 2 * q[3] * x + q[4] * y * y +
         2 * q[5] * y * z + 2 * q[6] * y + q[7] * z * z + 2 * q[8] * z + q[9];
}

// The quadric's minimiser, when its 3x3 block is well conditioned.
bool quadric_optimum(const double q[10], Vec3* out) {
  const double a = q[0], b = q[1], c = q[2], d = q[4], e = q[5], f = q[7];
  const double det = a * (d * f - e * e) - b * (b * f - c * e) + c * (b * e - c * d);
  const double scale = std::max({std::abs(a), std::abs(d), std::abs(f), 1e-300});
  if (!(std::abs(det) > 1e-9 * scale * scale * scale)) return false;
  const double r0 = -q[3], r1 = -q[6], r2 = -q[8];
  const double x = (r0 * (d * f - e * e) - b * (r1 * f - e * r2) + c * (r1 * e - d * r2)) / det;
  const double y = (a * (r1 * f - e * r2) - r0 * (b * f - c * e) + c * (b * r2 - r1 * c)) / det;
  const double z = (a * (d * r2 - r1 * e) - b * (b * r2 - r1 * c) + r0 * (b * e - c * d)) / det;
  *out = {x, y, z};
  return std::isfinite(x) && std::isfinite(y) && std::isfinite(z);
}

// The sample points of a triangle: each EDGE at the same points whichever triangle asks
// (endpoints in a fixed order, a fixed spacing), so the two triangles on an edge judge its
// chord identically; then the interior on the triangle's own grid. `fn` returns false to stop.
template <class Fn>
bool for_each_sample(const Vec3& a, const Vec3& b, const Vec3& c, double spacing, Fn&& fn) {
  auto less = [](const Vec3& p, const Vec3& q) {
    return p.x < q.x || (p.x == q.x && (p.y < q.y || (p.y == q.y && p.z < q.z)));
  };
  const Vec3* e[3][2] = {{&a, &b}, {&b, &c}, {&c, &a}};
  for (auto& pq : e) {
    const Vec3& p = less(*pq[0], *pq[1]) ? *pq[0] : *pq[1];
    const Vec3& q = less(*pq[0], *pq[1]) ? *pq[1] : *pq[0];
    const int n = std::max(1, static_cast<int>(std::ceil(len3(sub3(q, p)) / spacing)));
    for (int k = 0; k <= n; ++k) {
      const double u = static_cast<double>(k) / n;
      if (!fn(Vec3{p.x + (q.x - p.x) * u, p.y + (q.y - p.y) * u, p.z + (q.z - p.z) * u}))
        return false;
    }
  }
  const double emax = std::max({len3(sub3(b, a)), len3(sub3(c, b)), len3(sub3(a, c))});
  const int m = std::max(1, static_cast<int>(std::ceil(emax / spacing)));
  for (int i = 1; i < m; ++i)
    for (int j = 1; i + j < m; ++j) {
      const double u = static_cast<double>(i) / m, w = static_cast<double>(j) / m;
      if (!fn(Vec3{a.x + (b.x - a.x) * u + (c.x - a.x) * w, a.y + (b.y - a.y) * u + (c.y - a.y) * w,
                   a.z + (b.z - a.z) * u + (c.z - a.z) * w}))
        return false;
    }
  return true;
}

}  // namespace

BoundedSimplifySink::BoundedSimplifySink(TriangleSink& out,
                                         std::function<double(const Vec3&)> field,
                                         BoundedSimplifyOptions opt)
    : out_(out), field_(std::move(field)), opt_(std::move(opt)) {}

double BoundedSimplifySink::max_in(const Vec3& p) const {
  return opt_.max_in_mm ? opt_.max_in_mm(p) : opt_.max_out_mm;
}

int BoundedSimplifySink::vertex_of(const Vec3& p) {
  const std::uint64_t k = key_of(p);
  auto& bucket = weld_[k];
  for (int v : bucket)
    if (P_[static_cast<std::size_t>(v)].x == p.x && P_[static_cast<std::size_t>(v)].y == p.y &&
        P_[static_cast<std::size_t>(v)].z == p.z)
      return v;
  const int v = static_cast<int>(P_.size());
  P_.push_back(p);
  // A vertex arriving already behind the front belongs to a region a flush may have
  // emitted: freeze it, so it can never move away from a triangle already written.
  // Flags: 4 frozen (behind the front, or at a cut when cuts are frozen); 8 at a cut that
  // is simplified within its own band (never refined).
  const bool cut = opt_.at_cut && opt_.at_cut(p);
  vflag_.push_back(static_cast<std::uint8_t>(
      ((started_ && p.z < front_z_ - opt_.front_margin_mm) || (cut && !(opt_.cut_tol_mm > 0.0))
           ? 4 : 0) |
      (cut && opt_.cut_tol_mm > 0.0 ? 8 : 0)));
  stamp_.push_back(0);
  vt_.emplace_back();
  bucket.push_back(v);
  return v;
}

void BoundedSimplifySink::add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) {
  ++st_.triangles_in;
  const int ia = vertex_of(a), ib = vertex_of(b), ic = vertex_of(c);
  const int t = static_cast<int>(T_.size());
  T_.push_back({ia, ib, ic});
  tdead_.push_back(0);
  for (int v : {ia, ib, ic}) vt_[static_cast<std::size_t>(v)].push_back(t);
  front_z_ = std::max({front_z_, a.z, b.z, c.z});
  if (!started_) {
    started_ = true;
    last_flush_z_ = front_z_;
  }
  if (opt_.slab_mm > 0.0 && front_z_ - last_flush_z_ > opt_.slab_mm) {
    flush(false);
    last_flush_z_ = front_z_;
  }
}

void BoundedSimplifySink::finish() { flush(true); }

bool BoundedSimplifySink::triangle_ok(const Vec3& a, const Vec3& b, const Vec3& c,
                                      bool sheet_only) const {
  return for_each_sample(a, b, c, opt_.sample_spacing_mm, [&](const Vec3& p) {
    const double f = field_(p);
    if (opt_.cut_tol_mm > 0.0 && opt_.at_cut && opt_.at_cut(p))
      return sheet_only || std::abs(f) <= opt_.cut_tol_mm;
    return sheet_ok(p, f, sheet_only);
  });
}

// The sheet's own band, or, off it within reach of a step (the header's ★ STEPS), the
// step's band; `sheet_only` (refine, and what a flush holds back) passes a step as a cut
// is passed, since no split there converges.
bool BoundedSimplifySink::sheet_ok(const Vec3& p, double f, bool sheet_only) const {
  if (f <= opt_.max_out_mm && -f <= max_in(p)) return true;
  if (!opt_.step) return false;
  const double off = opt_.step(p);
  return off >= 0.0 && (sheet_only || off == 0.0);
}

// Pulled onto the MIDDLE of the band at m (field = (max_out - max_in) / 2), not onto the
// surface: where a wall is at the bead, max_in is 0 and the surface is the band's inner edge.
Vec3 BoundedSimplifySink::onto_surface(const Vec3& m, double reach) const {
  Vec3 p = m;
  const double e = 1e-4;
  const double target = 0.5 * (opt_.max_out_mm - max_in(m));
  for (int k = 0; k < 12; ++k) {
    const double f = field_(p) - target;
    if (std::abs(f) < 1e-6) break;
    const Vec3 g{(field_({p.x + e, p.y, p.z}) - field_({p.x - e, p.y, p.z})) / (2 * e),
                 (field_({p.x, p.y + e, p.z}) - field_({p.x, p.y - e, p.z})) / (2 * e),
                 (field_({p.x, p.y, p.z + e}) - field_({p.x, p.y, p.z - e})) / (2 * e)};
    const double gg = dot3(g, g);
    if (!(gg > 1e-12)) break;
    p = {p.x - f * g.x / gg, p.y - f * g.y / gg, p.z - f * g.z / gg};
  }
  return len3(sub3(p, m)) <= reach ? p : m;
}

bool BoundedSimplifySink::fan_complete(int x) const {
  // Every edge at x carries exactly two triangles HERE: none of x's triangles was written
  // already, so the link test below sees x's whole ring.
  std::map<int, int> n;
  for (int t : vt_[static_cast<std::size_t>(x)])
    for (int y : T_[static_cast<std::size_t>(t)]) if (y != x) ++n[y];
  for (const auto& kv : n) if (kv.second != 2) return false;
  return !n.empty();
}

bool BoundedSimplifySink::try_collapse(int u, int v) {
  // Keep u, remove v. A frozen or live vertex never moves.
  const auto fixed = [&](int x) { return (vflag_[static_cast<std::size_t>(x)] & 6) != 0; };
  if (fixed(v)) std::swap(u, v);
  if (fixed(v)) { ++st_.rejected_topology; return false; }
  // A LIVE vertex has triangles still to come and a frozen one on a seam has triangles
  // already written; neither ring is whole here, so the link test cannot see it. Keep v
  // only onto a vertex whose whole ring is held (a frozen crease vertex, or a free one).
  if ((vflag_[static_cast<std::size_t>(u)] & 2) ||
      ((vflag_[static_cast<std::size_t>(u)] & 4) && !fan_complete(u))) {
    ++st_.rejected_topology;
    return false;
  }
  const std::vector<int>& tu = vt_[static_cast<std::size_t>(u)];
  const std::vector<int>& tv = vt_[static_cast<std::size_t>(v)];
  // The two triangles on the edge, and the link condition.
  std::vector<int> shared;
  for (int t : tv)
    if (std::find(tu.begin(), tu.end(), t) != tu.end()) shared.push_back(t);
  if (shared.size() != 2) { ++st_.rejected_topology; return false; }
  std::set<int> nu, nv;
  for (int t : tu)
    for (int x : T_[static_cast<std::size_t>(t)]) if (x != u) nu.insert(x);
  for (int t : tv)
    for (int x : T_[static_cast<std::size_t>(t)]) if (x != v) nv.insert(x);
  int common = 0;
  for (int x : nu) if (x != v && nv.count(x)) ++common;
  if (common != 2) { ++st_.rejected_topology; return false; }
  // Every edge at v must carry exactly two triangles (no boundary at v).
  for (int x : nv) {
    int n = 0;
    for (int t : tv)
      for (int y : T_[static_cast<std::size_t>(t)]) if (y == x) ++n;
    if (n != 2) { ++st_.rejected_topology; return false; }
  }

  // Candidate positions: the quadric's optimum, the midpoint, then the two ends.
  double q[10];
  {
    std::fill(q, q + 10, 0.0);
    for (int x : {u, v})
      for (int t : vt_[static_cast<std::size_t>(x)]) {
        const auto& T = T_[static_cast<std::size_t>(t)];
        add_plane(q, P_[static_cast<std::size_t>(T[0])], P_[static_cast<std::size_t>(T[1])],
                  P_[static_cast<std::size_t>(T[2])]);
      }
  }
  std::vector<Vec3> cand;
  Vec3 opt;
  const Vec3 pu = P_[static_cast<std::size_t>(u)], pv = P_[static_cast<std::size_t>(v)];
  if (!fixed(u)) {
    const double luv = len3(sub3(pu, pv));
    const Vec3 mid{0.5 * (pu.x + pv.x), 0.5 * (pu.y + pv.y), 0.5 * (pu.z + pv.z)};
    if (quadric_optimum(q, &opt) && len3(sub3(opt, pu)) + len3(sub3(opt, pv)) < 3.0 * luv)
      cand.push_back(opt);
    cand.push_back(mid);
    // The midpoint pulled onto the true surface: a vertex ON the surface leaves the
    // chord error to one side, which a collapse on a curved patch often needs.
    cand.push_back(onto_surface(mid, 0.5 * luv));
    cand.push_back(pv);
  }
  cand.push_back(pu);

  for (const Vec3& p : cand) {
    bool ok = true;
    for (int x : {u, v}) {
      for (int t : vt_[static_cast<std::size_t>(x)]) {
        if (t == shared[0] || t == shared[1]) continue;
        const auto& T = T_[static_cast<std::size_t>(t)];
        Vec3 o[3], nw[3];
        for (int i = 0; i < 3; ++i) {
          o[i] = P_[static_cast<std::size_t>(T[static_cast<std::size_t>(i)])];
          nw[i] = (T[static_cast<std::size_t>(i)] == u || T[static_cast<std::size_t>(i)] == v)
                      ? p : o[i];
        }
        const Vec3 n0 = cross3(sub3(o[1], o[0]), sub3(o[2], o[0]));
        const Vec3 n1 = cross3(sub3(nw[1], nw[0]), sub3(nw[2], nw[0]));
        const double l0 = len3(n0), l1 = len3(n1);
        if (!(l1 > 1e-12) || !(l0 > 0.0) || dot3(n0, n1) < opt_.min_normal_dot * l0 * l1) {
          ok = false;
          break;
        }
      }
      if (!ok) break;
    }
    if (!ok) { ++st_.rejected_topology; continue; }
    for (int x : {u, v}) {
      for (int t : vt_[static_cast<std::size_t>(x)]) {
        if (t == shared[0] || t == shared[1]) continue;
        const auto& T = T_[static_cast<std::size_t>(t)];
        Vec3 nw[3];
        for (int i = 0; i < 3; ++i) {
          const int y = T[static_cast<std::size_t>(i)];
          nw[i] = (y == u || y == v) ? p : P_[static_cast<std::size_t>(y)];
        }
        if (!triangle_ok(nw[0], nw[1], nw[2])) { ok = false; break; }
      }
      if (!ok) break;
    }
    if (!ok) { ++st_.rejected_deviation; continue; }

    // Apply: v's triangles move to u, the two on the edge die.
    P_[static_cast<std::size_t>(u)] = p;
    for (int t : shared) {
      tdead_[static_cast<std::size_t>(t)] = 1;
      for (int x : T_[static_cast<std::size_t>(t)]) {
        auto& L = vt_[static_cast<std::size_t>(x)];
        L.erase(std::remove(L.begin(), L.end(), t), L.end());
      }
    }
    for (int t : vt_[static_cast<std::size_t>(v)]) {
      for (int& x : T_[static_cast<std::size_t>(t)]) if (x == v) x = u;
      vt_[static_cast<std::size_t>(u)].push_back(t);
    }
    vt_[static_cast<std::size_t>(v)].clear();
    vflag_[static_cast<std::size_t>(v)] |= 1;
    ++stamp_[static_cast<std::size_t>(u)];
    ++stamp_[static_cast<std::size_t>(v)];
    ++st_.collapses;
    return true;
  }
  return false;
}

void BoundedSimplifySink::simplify() {
  struct Entry {
    double cost;
    int u, v;
    std::uint32_t su, sv;
    bool operator<(const Entry& o) const {  // a max-heap of the NEGATED order: min first
      if (cost != o.cost) return cost > o.cost;
      if (u != o.u) return u > o.u;
      return v > o.v;
    }
  };
  std::priority_queue<Entry> heap;
  auto vertex_quadric = [&](int x, double q[10]) {
    for (int t : vt_[static_cast<std::size_t>(x)]) {
      const auto& T = T_[static_cast<std::size_t>(t)];
      add_plane(q, P_[static_cast<std::size_t>(T[0])], P_[static_cast<std::size_t>(T[1])],
                P_[static_cast<std::size_t>(T[2])]);
    }
  };
  auto push_edge = [&](int a, int b) {
    if (a > b) std::swap(a, b);
    double q[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    vertex_quadric(a, q);
    vertex_quadric(b, q);
    const Vec3 pa = P_[static_cast<std::size_t>(a)], pb = P_[static_cast<std::size_t>(b)];
    Vec3 o{0.5 * (pa.x + pb.x), 0.5 * (pa.y + pb.y), 0.5 * (pa.z + pb.z)};
    Vec3 opt;
    double c = quadric_cost(q, o);
    if (quadric_optimum(q, &opt)) c = std::min(c, quadric_cost(q, opt));
    heap.push({std::max(0.0, c), a, b, stamp_[static_cast<std::size_t>(a)],
               stamp_[static_cast<std::size_t>(b)]});
  };
  for (std::size_t t = 0; t < T_.size(); ++t) {
    if (tdead_[t]) continue;
    const auto& T = T_[t];
    for (int i = 0; i < 3; ++i) {
      const int a = T[static_cast<std::size_t>(i)], b = T[static_cast<std::size_t>((i + 1) % 3)];
      if (a < b) push_edge(a, b);  // each interior edge once (its other triangle has b < a)
    }
  }
  while (!heap.empty()) {
    const Entry e = heap.top();
    heap.pop();
    if ((vflag_[static_cast<std::size_t>(e.u)] & 1) || (vflag_[static_cast<std::size_t>(e.v)] & 1))
      continue;
    if (e.su != stamp_[static_cast<std::size_t>(e.u)] ||
        e.sv != stamp_[static_cast<std::size_t>(e.v)])
      continue;
    int keep = e.u, gone = e.v;
    if (!try_collapse(keep, gone)) continue;
    if (vflag_[static_cast<std::size_t>(keep)] & 1) std::swap(keep, gone);
    // The kept vertex's edges are re-costed. Its neighbours' other edges keep their old
    // cost: the quadric only ORDERS collapses (the field check decides them), and the next
    // pass re-costs everything anyway.
    std::set<int> nb;
    for (int t : vt_[static_cast<std::size_t>(keep)])
      for (int x : T_[static_cast<std::size_t>(t)]) if (x != keep) nb.insert(x);
    for (int x : nb) push_edge(keep, x);
  }
}

// Between collapse passes: a Delaunay-style flip pass and a tangential smoothing pass, each
// move taken only if every triangle it makes stays in the band. Greedy collapse stalls on
// skinny triangles and uneven vertex spacing; evening them out lets the next pass go on.
void BoundedSimplifySink::improve() {
  auto angle_at = [&](int o, int a, int b) {  // the angle at o in triangle (o, a, b)
    const Vec3 u = sub3(P_[static_cast<std::size_t>(a)], P_[static_cast<std::size_t>(o)]);
    const Vec3 w = sub3(P_[static_cast<std::size_t>(b)], P_[static_cast<std::size_t>(o)]);
    const double c = dot3(u, w) / std::max(1e-300, len3(u) * len3(w));
    return std::acos(std::clamp(c, -1.0, 1.0));
  };
  // Flips.
  for (std::size_t t = 0; t < T_.size(); ++t) {
    if (tdead_[t]) continue;
    for (int k = 0; k < 3; ++k) {
      const auto T = T_[t];
      const int a = T[static_cast<std::size_t>(k)], b = T[static_cast<std::size_t>((k + 1) % 3)],
                c = T[static_cast<std::size_t>((k + 2) % 3)];
      if (a > b) continue;  // each edge once
      int t2 = -1, d = -1;
      for (int u : vt_[static_cast<std::size_t>(a)]) {
        if (u == static_cast<int>(t)) continue;
        const auto& U = T_[static_cast<std::size_t>(u)];
        for (int i = 0; i < 3; ++i)
          if (U[static_cast<std::size_t>(i)] == b && U[static_cast<std::size_t>((i + 1) % 3)] == a) {
            t2 = u;
            d = U[static_cast<std::size_t>((i + 2) % 3)];
          }
      }
      if (t2 < 0 || c == d) continue;
      bool held = true;  // every vertex's ring held here (see try_collapse)
      for (int x : {a, b, c, d})
        held = held && !(vflag_[static_cast<std::size_t>(x)] & 2) &&
               (!(vflag_[static_cast<std::size_t>(x)] & 4) || fan_complete(x));
      if (!held) continue;
      if (angle_at(c, a, b) + angle_at(d, b, a) <= 3.14159265358979 + 1e-9) continue;
      // The edge c-d must not exist already.
      bool exists = false;
      for (int u : vt_[static_cast<std::size_t>(c)]) {
        const auto& U = T_[static_cast<std::size_t>(u)];
        exists = exists || std::find(U.begin(), U.end(), d) != U.end();
      }
      if (exists) continue;
      // (a, b, c) + (b, a, d) -> (a, d, c) + (b, c, d): the same winding.
      const Vec3 pa = P_[static_cast<std::size_t>(a)], pb = P_[static_cast<std::size_t>(b)],
                 pc = P_[static_cast<std::size_t>(c)], pd = P_[static_cast<std::size_t>(d)];
      const Vec3 n0 = cross3(sub3(pb, pa), sub3(pc, pa)), n1 = cross3(sub3(pd, pa), sub3(pc, pa)),
                 n2 = cross3(sub3(pc, pb), sub3(pd, pb));
      const double l0 = len3(n0);
      if (!(len3(n1) > 1e-12 && len3(n2) > 1e-12)) continue;
      if (dot3(n0, n1) < opt_.min_normal_dot * l0 * len3(n1) ||
          dot3(n0, n2) < opt_.min_normal_dot * l0 * len3(n2))
        continue;
      if (!triangle_ok(pa, pd, pc) || !triangle_ok(pb, pc, pd)) continue;
      T_[t] = {a, d, c};
      T_[static_cast<std::size_t>(t2)] = {b, c, d};
      auto drop = [&](int v, int tri) {
        auto& L = vt_[static_cast<std::size_t>(v)];
        L.erase(std::remove(L.begin(), L.end(), tri), L.end());
      };
      drop(b, static_cast<int>(t));
      drop(a, t2);
      vt_[static_cast<std::size_t>(d)].push_back(static_cast<int>(t));
      vt_[static_cast<std::size_t>(c)].push_back(t2);
      for (int x : {a, b, c, d}) ++stamp_[static_cast<std::size_t>(x)];
      ++st_.flips;
      break;
    }
  }
  // Tangential smoothing: each free vertex toward its ring's centroid, pulled onto the surface.
  for (std::size_t v = 0; v < P_.size(); ++v) {
    if ((vflag_[v] & 7) || vt_[v].empty()) continue;
    Vec3 c{0, 0, 0};
    int n = 0;
    std::set<int> ring;
    for (int t : vt_[v])
      for (int x : T_[static_cast<std::size_t>(t)]) if (x != static_cast<int>(v)) ring.insert(x);
    for (int x : ring) {
      c = {c.x + P_[static_cast<std::size_t>(x)].x, c.y + P_[static_cast<std::size_t>(x)].y,
           c.z + P_[static_cast<std::size_t>(x)].z};
      ++n;
    }
    if (n < 3) continue;
    c = {c.x / n, c.y / n, c.z / n};
    const Vec3 old = P_[v];
    const Vec3 tgt = onto_surface(c, len3(sub3(c, old)) + 1e-3);
    bool ok = true;
    for (int t : vt_[v]) {
      const auto& T = T_[static_cast<std::size_t>(t)];
      Vec3 o[3], nw[3];
      for (int i = 0; i < 3; ++i) {
        o[i] = P_[static_cast<std::size_t>(T[static_cast<std::size_t>(i)])];
        nw[i] = T[static_cast<std::size_t>(i)] == static_cast<int>(v) ? tgt : o[i];
      }
      const Vec3 n0 = cross3(sub3(o[1], o[0]), sub3(o[2], o[0]));
      const Vec3 n1 = cross3(sub3(nw[1], nw[0]), sub3(nw[2], nw[0]));
      if (!(len3(n1) > 1e-12) || dot3(n0, n1) < opt_.min_normal_dot * len3(n0) * len3(n1) ||
          !triangle_ok(nw[0], nw[1], nw[2])) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    P_[v] = tgt;
    ++stamp_[v];
    ++st_.smoothed;
  }
}

void BoundedSimplifySink::measure_and_emit(int t) {
  const auto& T = T_[static_cast<std::size_t>(t)];
  const Vec3 a = P_[static_cast<std::size_t>(T[0])], b = P_[static_cast<std::size_t>(T[1])],
             c = P_[static_cast<std::size_t>(T[2])];
  for_each_sample(a, b, c, opt_.sample_spacing_mm, [&](const Vec3& p) {
    const double f = field_(p);
    if (opt_.at_cut && opt_.at_cut(p)) {
      ++st_.cut_samples;
      st_.cut_max_out_mm = std::max(st_.cut_max_out_mm, f);
      st_.cut_max_in_mm = std::max(st_.cut_max_in_mm, -f);
      return true;
    }
    if (!(f <= opt_.max_out_mm && -f <= max_in(p)) && opt_.step) {
      const double off = opt_.step(p);
      if (off >= 0.0) {
        ++st_.step_samples;
        st_.step_max_out_mm = std::max(st_.step_max_out_mm, f);
        st_.step_max_in_mm = std::max(st_.step_max_in_mm, -f);
        if (off > 0.0) ++st_.step_samples_outside_band;
        st_.step_worst_outside_band_mm = std::max(st_.step_worst_outside_band_mm, off);
        return true;
      }
    }
    ++st_.samples;
    st_.max_out_measured_mm = std::max(st_.max_out_measured_mm, f);
    st_.max_in_measured_mm = std::max(st_.max_in_measured_mm, -f);
    const double past = std::max(f - opt_.max_out_mm, -f - max_in(p));
    if (-f > max_in(p) + 1e-12) ++st_.samples_past_max_in;
    if (past > st_.worst_excess_mm) { st_.worst_excess_mm = past; st_.worst_at = p; }
    return true;
  });
  out_.add_triangle(a, b, c);
  ++st_.triangles_out;
}

// Split every triangle that leaves the band, at its longest edge, until none does (or the
// edge is a micron). The new vertex is the edge's midpoint pulled onto the true surface by
// Newton steps on the field, so a triangle that slices the corner off a crease (one vertex
// on a wall, two on a cut face) gains a vertex at the crease. The contouring places none
// there; measured, such a triangle cut 0.16 mm into a 1 mm gyroid wall at the sample
// block's faces. Collapses afterwards remove whatever the band does not need.
bool BoundedSimplifySink::in_band(const Vec3& p) const {
  const double f = field_(p);
  if (opt_.cut_tol_mm > 0.0 && opt_.at_cut && opt_.at_cut(p)) return true;  // the cut's own band
  return sheet_ok(p, f, /*sheet_only=*/false);
}

// A contoured vertex can sit just outside the band (the QEF places it off the surface where
// the cell's crossings disagree). Each free one is pulled onto the band's middle when that
// folds none of its triangles.
void BoundedSimplifySink::snap_vertices() {
  for (std::size_t v = 0; v < P_.size(); ++v) {
    if ((vflag_[v] & 7) || vt_[v].empty() || in_band(P_[v])) continue;
    double reach = 0.0;  // the fold check below is the guard, not the reach
    for (int t : vt_[v])
      for (int x : T_[static_cast<std::size_t>(t)])
        if (x != static_cast<int>(v))
          reach = std::max(reach, len3(sub3(P_[static_cast<std::size_t>(x)], P_[v])));
    const Vec3 to = onto_surface(P_[v], 0.5 * reach);
    if (!in_band(to)) continue;
    bool ok = true;
    for (int t : vt_[v]) {
      const auto& T = T_[static_cast<std::size_t>(t)];
      Vec3 o[3], nw[3];
      for (int i = 0; i < 3; ++i) {
        o[i] = P_[static_cast<std::size_t>(T[static_cast<std::size_t>(i)])];
        nw[i] = T[static_cast<std::size_t>(i)] == static_cast<int>(v) ? to : o[i];
      }
      const Vec3 n0 = cross3(sub3(o[1], o[0]), sub3(o[2], o[0]));
      const Vec3 n1 = cross3(sub3(nw[1], nw[0]), sub3(nw[2], nw[0]));
      if (!(len3(n1) > 1e-12) || dot3(n0, n1) < opt_.min_normal_dot * len3(n0) * len3(n1)) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    P_[v] = to;
    ++stamp_[v];
    ++st_.snapped;
  }
}

void BoundedSimplifySink::refine() {
  snap_vertices();
  std::vector<int> work;
  for (std::size_t t = 0; t < T_.size(); ++t)
    if (!tdead_[t]) work.push_back(static_cast<int>(t));
  for (int round = 0; round < 20 && !work.empty(); ++round) {
    std::vector<int> next;
    std::vector<std::uint8_t> touched(T_.size(), 0);
    for (int t : work) {
      if (tdead_[static_cast<std::size_t>(t)] || touched[static_cast<std::size_t>(t)]) continue;
      const auto T = T_[static_cast<std::size_t>(t)];
      // A frozen vertex (a seam already written, or a frozen cut) never moves, and an edge
      // with a written triangle on it is never split (the two-triangle test below), so a
      // triangle beside the seam is refined like any other.
      const Vec3 a = P_[static_cast<std::size_t>(T[0])], b = P_[static_cast<std::size_t>(T[1])],
                 c = P_[static_cast<std::size_t>(T[2])];
      // Only the sheet's own surface is refined: at a cut no split converges (the contouring
      // put no vertex on the crease), and the cut keeps its own band.
      if (triangle_ok(a, b, c, /*sheet_only=*/true)) continue;
      // A vertex outside the band is not mended by splitting around it (every new triangle
      // keeps it): leave the triangle as it is.
      if (!in_band(a) || !in_band(b) || !in_band(c)) continue;
      // The edge to split: the one whose midpoint lies furthest off the surface (where the
      // chord leaves the band), that can be split: both its triangles here (an edge on an
      // emitted seam is not), neither already split this round.
      std::array<std::pair<double, int>, 3> by_dev;
      std::array<double, 3> elen;
      for (int k = 0; k < 3; ++k) {
        const Vec3 p0 = P_[static_cast<std::size_t>(T[static_cast<std::size_t>(k)])];
        const Vec3 p1 = P_[static_cast<std::size_t>(T[static_cast<std::size_t>((k + 1) % 3)])];
        elen[static_cast<std::size_t>(k)] = len3(sub3(p1, p0));
        by_dev[static_cast<std::size_t>(k)] = {
            std::abs(field_({0.5 * (p0.x + p1.x), 0.5 * (p0.y + p1.y), 0.5 * (p0.z + p1.z)})), k};
      }
      std::sort(by_dev.begin(), by_dev.end(),
                [](const auto& x, const auto& y) { return x.first > y.first || (x.first == y.first && x.second < y.second); });
      int ea = -1, eb = -1;
      double best = 0.0;
      std::vector<int> on;
      for (const auto& [dv, k] : by_dev) {
        (void)dv;
        const double l = elen[static_cast<std::size_t>(k)];
        if (l < 1e-3) continue;
        const int xa = T[static_cast<std::size_t>(k)], xb = T[static_cast<std::size_t>((k + 1) % 3)];
        on.clear();
        for (int u : vt_[static_cast<std::size_t>(xa)]) {
          const auto& U = T_[static_cast<std::size_t>(u)];
          if (std::find(U.begin(), U.end(), xb) != U.end()) on.push_back(u);
        }
        if (on.size() != 2) continue;
        bool busy = false;
        for (int u : on) busy = busy || touched[static_cast<std::size_t>(u)];
        if (busy) continue;
        ea = xa; eb = xb; best = l;
        break;
      }
      if (ea < 0) { if (round + 1 < 20) next.push_back(t); continue; }
      const Vec3 pa = P_[static_cast<std::size_t>(ea)], pb = P_[static_cast<std::size_t>(eb)];
      const Vec3 mid{0.5 * (pa.x + pb.x), 0.5 * (pa.y + pb.y), 0.5 * (pa.z + pb.z)};
      // The new vertex is pulled onto the band unless that would fold either new pair of
      // triangles; then it stays on the edge (a plain split). It is a NEW vertex, so a
      // frozen neighbour does not move.
      Vec3 pm = onto_surface(mid, 0.5 * best);
      for (int u : on) {
        const auto& U = T_[static_cast<std::size_t>(u)];
        int opp = -1;
        for (int x : U)
          if (x != ea && x != eb) opp = x;
        const Vec3 po = P_[static_cast<std::size_t>(opp)];
        const Vec3 n0 = cross3(sub3(pb, pa), sub3(po, pa));
        const Vec3 n1 = cross3(sub3(pm, pa), sub3(po, pa)), n2 = cross3(sub3(pb, pm), sub3(po, pm));
        const double l0 = len3(n0);
        if (!(len3(n1) > 1e-12 && len3(n2) > 1e-12) ||
            dot3(n0, n1) < opt_.min_normal_dot * l0 * len3(n1) ||
            dot3(n0, n2) < opt_.min_normal_dot * l0 * len3(n2))
          pm = mid;
      }
      // A split never makes a vertex outside the band (a plain midpoint on a curved patch
      // can be): such a triangle is left as it is.
      if (!in_band(pm)) continue;
      const int m = static_cast<int>(P_.size());
      P_.push_back(pm);
      vflag_.push_back(static_cast<std::uint8_t>(
          (vflag_[static_cast<std::size_t>(ea)] | vflag_[static_cast<std::size_t>(eb)]) & 2));
      stamp_.push_back(0);
      vt_.emplace_back();
      for (int u : on) {
        auto& U = T_[static_cast<std::size_t>(u)];
        int k = 0;
        while (!((U[static_cast<std::size_t>(k)] == ea && U[static_cast<std::size_t>((k + 1) % 3)] == eb) ||
                 (U[static_cast<std::size_t>(k)] == eb && U[static_cast<std::size_t>((k + 1) % 3)] == ea)))
          ++k;
        const int p0 = U[static_cast<std::size_t>(k)], q0 = U[static_cast<std::size_t>((k + 1) % 3)],
                  r0 = U[static_cast<std::size_t>((k + 2) % 3)];
        // (p0, q0, r0) -> (p0, m, r0) + (m, q0, r0): the same winding.
        U = {p0, m, r0};
        const int nt = static_cast<int>(T_.size());
        T_.push_back({m, q0, r0});
        tdead_.push_back(0);
        touched.push_back(1);
        auto& Lq = vt_[static_cast<std::size_t>(q0)];
        Lq.erase(std::remove(Lq.begin(), Lq.end(), u), Lq.end());
        Lq.push_back(nt);
        vt_[static_cast<std::size_t>(r0)].push_back(nt);
        vt_[static_cast<std::size_t>(m)].push_back(u);
        vt_[static_cast<std::size_t>(m)].push_back(nt);
        touched[static_cast<std::size_t>(u)] = 1;
        next.push_back(u);
        next.push_back(nt);
      }
      ++st_.splits;
    }
    work.swap(next);
  }
}

void BoundedSimplifySink::flush(bool final) {
  const auto t0 = std::chrono::steady_clock::now();
  ++st_.flushes;
  // Live: a vertex a future layer may still reach. Never on the final flush.
  for (std::size_t v = 0; v < P_.size(); ++v) {
    vflag_[v] &= static_cast<std::uint8_t>(~2u);
    if (!final && !(vflag_[v] & 1) && P_[v].z >= front_z_ - opt_.front_margin_mm) vflag_[v] |= 2;
  }
  refine();
  // Passes until one gains little: an edge refused early can pass once its neighbours
  // have moved.
  for (int pass = 0; pass < 6; ++pass) {
    const long long before = st_.collapses;
    if (pass > 0) improve();
    simplify();
    long long alive = 0;
    for (std::size_t t = 0; t < T_.size(); ++t) alive += tdead_[t] ? 0 : 1;
    if (st_.collapses - before < alive / 100 + 1) break;
  }
  // And once more before anything is written: a triangle the passes left out of the band
  // (or one about to become a seam, whose far side will be written) is split while both
  // its neighbours are still here, after a flip pass has opened up the slivers a split
  // could not move a vertex on.
  improve();
  refine();
  // Emit every triangle with no live vertex; keep the rest. A vertex shared by an emitted
  // triangle and a kept one is frozen from now on, so the seam cannot open.
  std::vector<std::uint8_t> emitted(T_.size(), 0);
  for (std::size_t t = 0; t < T_.size(); ++t) {
    if (tdead_[t]) continue;
    bool live = false;
    for (int x : T_[t]) live = live || (vflag_[static_cast<std::size_t>(x)] & 2);
    if (live) continue;
    // Not yet in the band (its neighbour near the front could not be mended this flush):
    // held for the next one rather than written, since a written edge can never be split.
    if (!final && !triangle_ok(P_[static_cast<std::size_t>(T_[t][0])],
                               P_[static_cast<std::size_t>(T_[t][1])],
                               P_[static_cast<std::size_t>(T_[t][2])], /*sheet_only=*/true))
      continue;
    measure_and_emit(static_cast<int>(t));
    emitted[t] = 1;
  }
  // Compact: keep the unemitted triangles and the vertices they use.
  std::vector<int> remap(P_.size(), -1);
  std::vector<Vec3> P2;
  std::vector<std::uint8_t> f2;
  std::vector<std::uint32_t> s2;
  std::vector<std::array<int, 3>> T2;
  for (std::size_t t = 0; t < T_.size(); ++t) {
    if (tdead_[t] || emitted[t]) continue;
    std::array<int, 3> nt;
    for (int i = 0; i < 3; ++i) {
      const int x = T_[t][static_cast<std::size_t>(i)];
      if (remap[static_cast<std::size_t>(x)] < 0) {
        remap[static_cast<std::size_t>(x)] = static_cast<int>(P2.size());
        P2.push_back(P_[static_cast<std::size_t>(x)]);
        // Shared with an emitted triangle => frozen.
        bool touches_emitted = false;
        for (int u : vt_[static_cast<std::size_t>(x)]) touches_emitted |= emitted[static_cast<std::size_t>(u)] != 0;
        f2.push_back(static_cast<std::uint8_t>((vflag_[static_cast<std::size_t>(x)] & 4) |
                                               (touches_emitted ? 4 : 0)));
        s2.push_back(0);
      }
      nt[static_cast<std::size_t>(i)] = remap[static_cast<std::size_t>(x)];
    }
    T2.push_back(nt);
  }
  P_.swap(P2);
  vflag_.swap(f2);
  stamp_.swap(s2);
  T_.swap(T2);
  tdead_.assign(T_.size(), 0);
  vt_.assign(P_.size(), {});
  for (std::size_t t = 0; t < T_.size(); ++t)
    for (int x : T_[t]) vt_[static_cast<std::size_t>(x)].push_back(static_cast<int>(t));
  weld_.clear();
  for (std::size_t v = 0; v < P_.size(); ++v) weld_[key_of(P_[v])].push_back(static_cast<int>(v));
  st_.seconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

}  // namespace topopt
