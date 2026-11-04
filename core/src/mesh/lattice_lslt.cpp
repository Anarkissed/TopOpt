// LSLT — see topopt/lattice_lslt.hpp for the method and its sources.
#include "topopt/lattice_lslt.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>
#include <unordered_map>

namespace topopt {
namespace {

// The interference plane degenerates as two beams line up; below this the pair has no
// usable plane and is skipped. den = 1 - cos(angle), so 0.01 is about 8 degrees apart.
constexpr double kMinInterferenceDen = 0.01;
// and no vertex is pushed further than this many node radii (see the note at the push).
constexpr double kMaxPushRadii = 3.0;
// ...and never more than this fraction of the beam's own length, so a push cannot
// run past the far end of the beam it belongs to.
constexpr double kMaxPushBeamFraction = 0.45;
// Virtual-Trim 4.3: how far an UNCLOSED node's rings are extended, in node radii. Their
// value, chosen there because computing the true minimum is expensive and 2R is ample.
constexpr double kVirtualTrimExtendRadii = 2.0;
// Virtual-Trim 4.5: two ring vertices on different struts are candidates for matching
// only within this many node radii of each other.
constexpr double kVirtualTrimMatchRadii = 0.75;

inline Vec3 sub(const Vec3& a, const Vec3& b) { return Vec3{a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 add(const Vec3& a, const Vec3& b) { return Vec3{a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 mul(const Vec3& a, double s) { return Vec3{a.x * s, a.y * s, a.z * s}; }
inline double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 cross(const Vec3& a, const Vec3& b) {
  return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline double len(const Vec3& a) { return std::sqrt(dot(a, a)); }
inline Vec3 unit(const Vec3& a) {
  const double l = len(a);
  return l > 0.0 ? mul(a, 1.0 / l) : Vec3{0, 0, 0};
}

// A stable orthonormal frame about `d`, so the two ends of a beam share a zero angle and
// the quad strip between them cannot twist.
void frame_of(const Vec3& d, Vec3& u, Vec3& v) {
  const Vec3 pick = (std::fabs(d.z) < 0.9) ? Vec3{0, 0, 1} : Vec3{1, 0, 0};
  u = unit(cross(pick, d));
  v = cross(d, u);
}

struct Incident {
  int beam = 0;      // index into the beam list
  int end = 0;       // 0 = this node is the beam's a, 1 = its b
  Vec3 dir{0, 0, 0}; // unit, pointing AWAY from the node along the beam
  double r = 0.0;    // the beam's own radius
};

}  // namespace

TriangleMesh lattice_lslt(const std::vector<OrganicSpan>& spans, const LsltOptions& opt,
                          LsltStats& stats) {
  stats = LsltStats{};
  TriangleMesh mesh;
  if (spans.empty()) return mesh;

  // ── the section vertex count, from the chord error ────────────────────────────
  // e = 1 - cos(pi/N)  =>  N = pi / acos(1 - e). Relative to the radius, so ONE count
  // serves every beam: a thin strut and a thick one need the same number of facets for
  // the same proportional deviation.
  const double e = std::min(0.5, std::max(1e-4, opt.chord_error_ratio));
  int N = static_cast<int>(std::ceil(M_PI / std::acos(1.0 - e)));
  N = std::max(opt.min_section_vertices, std::min(opt.max_section_vertices, N));
  stats.section_vertices = N;

  // ── weld endpoints into nodes ────────────────────────────────────────────────
  const double q = std::max(1e-9, opt.weld_tol_mm);
  auto key_of = [&](const Vec3& p) {
    return std::array<long long, 3>{std::llround(p.x / q), std::llround(p.y / q),
                                    std::llround(p.z / q)}; };
  std::map<std::array<long long, 3>, int> node_id;
  std::vector<Vec3> node_pos;
  auto node_of = [&](const Vec3& p) {
    const auto k = key_of(p);
    auto it = node_id.find(k);
    if (it != node_id.end()) return it->second;
    const int id = static_cast<int>(node_pos.size());
    node_id.emplace(k, id);
    node_pos.push_back(p);
    return id; };

  struct Beam { int na = 0, nb = 0; double r = 0.0; Vec3 dir{0, 0, 0}; double len = 0.0; };
  std::vector<Beam> beams;
  beams.reserve(spans.size());
  for (const OrganicSpan& sp : spans) {
    const Vec3 ab = sub(sp.b, sp.a);
    const double L = len(ab);
    if (!(L > 0.0) || !(sp.r > 0.0)) continue;   // degenerate: nothing to mesh
    Beam bm;
    bm.na = node_of(sp.a); bm.nb = node_of(sp.b);
    if (bm.na == bm.nb) continue;                // a loop onto its own node
    bm.r = sp.r; bm.dir = mul(ab, 1.0 / L); bm.len = L;
    beams.push_back(bm);
  }
  if (beams.empty()) return mesh;
  stats.beams = beams.size();
  stats.nodes = node_pos.size();

  std::vector<std::vector<Incident>> inc(node_pos.size());
  for (std::size_t i = 0; i < beams.size(); ++i) {
    const Beam& bm = beams[i];
    inc[bm.na].push_back({static_cast<int>(i), 0, bm.dir, bm.r});
    inc[bm.nb].push_back({static_cast<int>(i), 1, mul(bm.dir, -1.0), bm.r});
  }
  std::vector<double> node_R(node_pos.size(), 0.0);
  for (std::size_t v = 0; v < node_pos.size(); ++v) {
    for (const Incident& in : inc[v]) node_R[v] = std::max(node_R[v], in.r);
    stats.max_valence = std::max(stats.max_valence, static_cast<int>(inc[v].size()));
  }

  // ── SECTIONS ────────────────────────────────────────────────────────────────
  // A section is one ring. Valence 2 shares ONE ring on the mitre plane (Chougrani's
  // Val=2 case, and 69.6 % of this lattice's nodes); valence 1 and >= 3 get a ring per
  // beam end. A ring is an ORDERED list of (angle, vertex), because from here on rings
  // no longer all have the same length: the mandatory vertices below are inserted into
  // whichever rings need them.
  std::vector<int> sec_of(beams.size() * 2, -1);
  auto se_index = [](std::size_t beam, int end) {
    return beam * 2 + static_cast<std::size_t>(end); };
  struct Section {
    int node = 0;
    Vec3 nrm{0, 0, 0}, u{0, 0, 0}, v{0, 0, 0};
    double r = 0.0;
    std::vector<std::pair<double, int>> ring;   // (angle, vertex index), sorted
  };
  std::vector<Section> secs;
  for (std::size_t vtx = 0; vtx < node_pos.size(); ++vtx) {
    const auto& list = inc[vtx];
    if (list.size() == 2) {
      Vec3 nrm = unit(sub(list[0].dir, list[1].dir));
      if (!(len(nrm) > 0.0)) nrm = list[0].dir;
      Section sc; sc.node = static_cast<int>(vtx); sc.nrm = nrm;
      sc.r = std::max(list[0].r, list[1].r);
      const int id = static_cast<int>(secs.size());
      secs.push_back(sc);
      sec_of[se_index(static_cast<std::size_t>(list[0].beam), list[0].end)] = id;
      sec_of[se_index(static_cast<std::size_t>(list[1].beam), list[1].end)] = id;
    } else {
      for (const Incident& in : list) {
        Section sc; sc.node = static_cast<int>(vtx); sc.nrm = in.dir; sc.r = in.r;
        const int id = static_cast<int>(secs.size());
        secs.push_back(sc);
        sec_of[se_index(static_cast<std::size_t>(in.beam), in.end)] = id;
      }
    }
  }
  stats.sections = secs.size();

  // ── one angular origin per chain, carried by rotation-minimising transport ───
  std::vector<char> sec_done(secs.size(), 0);
  auto set_frame = [&](int sid, const Vec3& want) {
    Section& sc = secs[static_cast<std::size_t>(sid)];
    Vec3 u = sub(want, mul(sc.nrm, dot(want, sc.nrm)));
    if (!(len(u) > 1e-9)) { Vec3 a, b; frame_of(sc.nrm, a, b); u = a; }
    sc.u = unit(u); sc.v = cross(sc.nrm, sc.u);
    sec_done[static_cast<std::size_t>(sid)] = 1; };
  for (std::size_t i = 0; i < beams.size(); ++i) {
    const int s0 = sec_of[se_index(i, 0)], s1 = sec_of[se_index(i, 1)];
    const std::size_t k0 = static_cast<std::size_t>(s0), k1 = static_cast<std::size_t>(s1);
    if (!sec_done[k0] && !sec_done[k1]) { Vec3 a, b; frame_of(beams[i].dir, a, b); set_frame(s0, a); }
    if (sec_done[k0] && !sec_done[k1]) set_frame(s1, secs[k0].u);
    else if (sec_done[k1] && !sec_done[k0]) set_frame(s0, secs[k1].u);
  }
  for (std::size_t i = 0; i < secs.size(); ++i)
    if (!sec_done[i]) { Vec3 a, b; frame_of(secs[i].nrm, a, b); set_frame(static_cast<int>(i), a); }

  auto angle_in = [&](const Section& sc, const Vec3& p) {
    const Vec3 d = sub(p, node_pos[static_cast<std::size_t>(sc.node)]);
    double a = std::atan2(dot(d, sc.v), dot(d, sc.u));
    if (a < 0.0) a += 2.0 * M_PI;
    return a; };
  auto point_at = [&](const Section& sc, double a) {
    return add(node_pos[static_cast<std::size_t>(sc.node)],
               add(mul(sc.u, sc.r * std::cos(a)), mul(sc.v, sc.r * std::sin(a)))); };

  // ── ★★ MANDATORY VERTICES (paper 3.1) ───────────────────────────────────────
  // For each PAIR of beams at a node, O = (d_ik x d_ij)/||...||, and N_i +/- R_i*O lie
  // on both cylinders and on the node sphere. Emitting each as ONE mesh vertex and
  // putting that same index into BOTH sections is what stitches the arms together:
  // without it every ring is its own closed loop and the only way to close a joint is a
  // cone cap per arm, which is what the maintainer has been seeing as facets.
  // every ring / mandatory vertex belongs to a node; the joint closure below needs it
  std::vector<int> vert_node;
  auto tag = [&](int vi, int node) {
    if (vert_node.size() <= static_cast<std::size_t>(vi)) vert_node.resize(vi + 1, -1);
    vert_node[static_cast<std::size_t>(vi)] = node; };
  const double kSameAngle = 2.0 * M_PI / (8 * N);   // no two ring vertices closer
  auto insert_into = [&](int sid, int vert) {
    Section& sc = secs[static_cast<std::size_t>(sid)];
    const double a = angle_in(sc, mesh.vertices[static_cast<std::size_t>(vert)]);
    // a near-duplicate angle would make a sliver triangle in the strip
    for (const auto& e : sc.ring) {
      double d = std::fabs(e.first - a);
      d = std::min(d, 2.0 * M_PI - d);
      if (d < kSameAngle) return;
    }
    sc.ring.push_back({a, vert}); };
  for (std::size_t vtx = 0; vtx < node_pos.size(); ++vtx) {
    const auto& list = inc[vtx];
    if (list.size() < 3) continue;            // valence 2 is already one shared ring
    const Vec3 Nv = node_pos[vtx];
    const double Ri = node_R[vtx];
    for (std::size_t a = 0; a < list.size(); ++a)
      for (std::size_t b = a + 1; b < list.size(); ++b) {
        const Vec3 O = unit(cross(list[b].dir, list[a].dir));
        if (!(len(O) > 0.0)) continue;        // collinear pair: no interference curve
        const int sa = sec_of[se_index(static_cast<std::size_t>(list[a].beam), list[a].end)];
        const int sb = sec_of[se_index(static_cast<std::size_t>(list[b].beam), list[b].end)];
        for (int sgn = -1; sgn <= 1; sgn += 2) {
          const int vi = static_cast<int>(mesh.vertices.size());
          mesh.vertices.push_back(add(Nv, mul(O, sgn * Ri)));
          tag(vi, static_cast<int>(vtx));
          insert_into(sa, vi);
          insert_into(sb, vi);
          ++stats.mandatory_vertices;
        }
      }
  }

  // ── fill each ring out to the chord error, then sort by angle ────────────────
  for (std::size_t si = 0; si < secs.size(); ++si) {
    Section& sc = secs[si];
    for (int t = 0; t < N; ++t) {
      const double a = 2.0 * M_PI * t / N;
      bool clash = false;
      for (const auto& e : sc.ring)
        // ★ KEEP FILL VERTICES BETWEEN MANDATORY ONES. Two rings share a mandatory
        // vertex by design, which is a POINT contact and manifold. If a ring drops the
        // fill vertices next to it, two mandatory vertices can end up ADJACENT in both
        // rings -- then the rings share an EDGE, and that edge is used by two strips
        // plus the joint fan. Measured: suppressing fill within a quarter-step took the
        // non-manifold count from 52 to 53,353. A tight window keeps the separation.
        if (std::fabs(e.first - a) < 2.0 * M_PI / (16 * N)) { clash = true; break; }
      if (clash) continue;
      const int vi = static_cast<int>(mesh.vertices.size());
      mesh.vertices.push_back(point_at(sc, a));
      tag(vi, sc.node);
      sc.ring.push_back({a, vi});
    }
    std::sort(sc.ring.begin(), sc.ring.end());
  }

  // ── ★★ A. NODE CLOSURE, AND THE EXTENSION (Virtual-Trim 4.3) ────────────────
  // A node is closed when its struts' half-spaces cover the sphere between them, i.e.
  // when no direction x satisfies d_i . x <= 0 for every strut. They solve that as an LP;
  // the equivalent statement is that the directions positively span R^3, so it is done
  // here by minimising max_i (d_i . x) over unit x. A negative minimum IS the gap, and x
  // points down it. An unclosed node's rings are then extended along their own beams by
  // 2 x the node radius (their eq. 6-7) so the arms reach far enough to be reconciled.
  std::vector<char> node_open(node_pos.size(), 0);
  std::vector<Vec3> node_gap(node_pos.size(), Vec3{0, 0, 0});
  for (std::size_t vtx = 0; vtx < node_pos.size(); ++vtx) {
    const auto& list = inc[vtx];
    if (list.size() < 3) continue;                  // 1 and 2 are closed by their own caps
    // start from the direction that opposes the arms most, then descend on the max
    Vec3 x{0, 0, 0};
    for (const Incident& in : list) x = sub(x, in.dir);
    if (!(len(x) > 1e-12)) x = Vec3{0, 0, 1};
    x = unit(x);
    double best = 1e300;
    for (int it = 0; it < 64; ++it) {
      double worst = -1e300; Vec3 g{0, 0, 0};
      for (const Incident& in : list) {
        const double d = dot(in.dir, x);
        if (d > worst) { worst = d; g = in.dir; }   // subgradient of the max
      }
      best = std::min(best, worst);
      Vec3 nx = sub(x, mul(g, 0.35 / (1.0 + it)));  // step against the active constraint
      nx = sub(nx, mul(x, dot(nx, x) - 1.0) );      // keep it near the sphere
      if (!(len(nx) > 1e-12)) break;
      x = unit(nx);
    }
    if (best < -1e-6) {
      node_open[vtx] = 1;
      node_gap[vtx] = x;                            // the direction no strut covers
      ++stats.nodes_unclosed;
    }
  }
  // ★★ THE EXTENSION, RE-DERIVED FOR A NODE-CENTRED RING ──────────────────────
  // Virtual-Trim's eq. (6-7) slides a ring along the generatrix by 2R because their
  // rings sit at the STRUT ENDS, so that lengthens the strut and the trim cuts the
  // excess. Ours sit AT THE NODE, and transplanting the formula shortened the beam
  // instead: measured, 29 % of the enclosed volume (19,263 -> 13,761 mm3). Worse, the
  // gap at an unclosed node lies along a direction NO BEAM POINTS ALONG -- that is what
  // unclosed means -- so no displacement of the rings along their own axes can put
  // material there. The extension has to become node geometry.
  //
  // The exact result that gives it: a cylinder of radius r whose axis passes through N
  // meets the sphere of radius R about N in a CIRCLE. With p = a*d + b*e, |b| = r and
  // a^2 + b^2 = R^2, so a = sqrt(R^2 - r^2): centre N + sqrt(R^2 - r^2)*d, radius r, in
  // the plane perpendicular to d. So the displacement is sqrt(R^2 - r^2) along +d, not
  // 2R. It shortens the tube by exactly what the node sphere then fills, so no volume is
  // lost, and where the radii at a node are equal it is ZERO -- an equal-radius joint
  // needs no extension, which is why the canonical cases are untouched by this.
  for (std::size_t vtx = 0; vtx < node_pos.size(); ++vtx) {
    if (!node_open[vtx]) continue;
    const double R = node_R[vtx];
    for (const Incident& in : inc[vtx]) {
      const std::size_t sid =
          static_cast<std::size_t>(sec_of[se_index(static_cast<std::size_t>(in.beam), in.end)]);
      const double off = std::sqrt(std::max(0.0, R * R - in.r * in.r));
      if (!(off > 1e-12)) continue;
      const double cap = kMaxPushBeamFraction * beams[static_cast<std::size_t>(in.beam)].len;
      const double dd = std::min(off, cap);
      for (const auto& e : secs[sid].ring) {
        mesh.vertices[static_cast<std::size_t>(e.second)] =
            add(mesh.vertices[static_cast<std::size_t>(e.second)], mul(in.dir, dd));
        ++stats.vertices_extended;
      }
    }
  }
  if (std::getenv("TOPOPT_LSLT_TRACE") && stats.nodes_unclosed)
    std::fprintf(stderr, "[lslt] %zu node(s) UNCLOSED (Virtual-Trim 4.3): rings moved onto "
                 "the node sphere, %zu vertices\n", stats.nodes_unclosed, stats.vertices_extended);

  // ── the special boolean, valence >= 3 only ──────────────────────────────────
  const bool no_push = std::getenv("TOPOPT_LSLT_NOPUSH") != nullptr;
  std::unordered_map<int, double> pushed;
  for (std::size_t vtx = 0; vtx < node_pos.size() && !no_push; ++vtx) {
    const auto& list = inc[vtx];
    if (list.size() < 3) continue;
    const Vec3 Nv = node_pos[vtx];
    for (std::size_t a = 0; a < list.size(); ++a) {
      const std::size_t sid =
          static_cast<std::size_t>(sec_of[se_index(static_cast<std::size_t>(list[a].beam), list[a].end)]);
      const Vec3 da = list[a].dir;
      const double budget = std::min(kMaxPushBeamFraction * beams[static_cast<std::size_t>(list[a].beam)].len,
                                     kMaxPushRadii * node_R[vtx]);
      for (std::size_t b = 0; b < list.size(); ++b) {
        if (a == b) continue;
        const Vec3 nP = unit(sub(da, list[b].dir));
        if (!(len(nP) > 0.0)) continue;
        const double den = dot(nP, da);
        if (!(den > kMinInterferenceDen)) continue;
        for (const auto& e : secs[sid].ring) {
          Vec3& V = mesh.vertices[static_cast<std::size_t>(e.second)];
          const double sd = dot(nP, sub(V, Nv));
          if (sd >= 0.0) continue;            // a mandatory vertex sits AT 0: never moved
          double lambda = -sd / den;          // eq. (10)
          if (!(lambda > 0.0)) continue;
          double& acc = pushed[e.second];
          lambda = std::min(lambda, budget - acc);
          if (!(lambda > 0.0)) continue;
          V = add(V, mul(da, lambda));
          acc += lambda;
          ++stats.vertices_pushed;
        }
      }
    }
  }

  // ── ★★ B. MATCH THE TRIMMED POINTS (Virtual-Trim 4.5) ───────────────────────
  // Ring vertices are produced per strut and trimmed per strut, so between two arms of
  // the same joint they do not line up and the surface is left with a gap there. For
  // each vertex, find the nearest vertex belonging to a DIFFERENT section at the same
  // node; where the two are MUTUALLY nearest, move both to their midpoint. Mutual is the
  // point -- it pairs each vertex at most once, so the correction cannot cascade.
  for (std::size_t vtx = 0; vtx < node_pos.size(); ++vtx) {
    const auto& list = inc[vtx];
    if (list.size() < 3) continue;
    struct RV { int sid; int vert; };
    std::vector<RV> all;
    for (const Incident& in : list) {
      const int sid = sec_of[se_index(static_cast<std::size_t>(in.beam), in.end)];
      for (const auto& e : secs[static_cast<std::size_t>(sid)].ring) all.push_back({sid, e.second});
    }
    const std::size_t m = all.size();
    if (m < 2) continue;
    std::vector<int> near(m, -1);
    for (std::size_t a = 0; a < m; ++a) {
      double bd = 1e300; int bi = -1;
      for (std::size_t b = 0; b < m; ++b) {
        if (all[b].sid == all[a].sid) continue;     // must be a DIFFERENT strut
        const double d = len(sub(mesh.vertices[static_cast<std::size_t>(all[a].vert)],
                                 mesh.vertices[static_cast<std::size_t>(all[b].vert)]));
        if (d < bd) { bd = d; bi = static_cast<int>(b); }
      }
      // only worth pairing when they are already close on the scale of the joint
      if (bi >= 0 && bd < kVirtualTrimMatchRadii * node_R[vtx]) near[a] = bi;
    }
    for (std::size_t a = 0; a < m; ++a) {
      const int b = near[a];
      if (b < 0 || static_cast<std::size_t>(b) < a) continue;
      if (near[static_cast<std::size_t>(b)] != static_cast<int>(a)) continue;   // mutual only
      Vec3& A = mesh.vertices[static_cast<std::size_t>(all[a].vert)];
      Vec3& B = mesh.vertices[static_cast<std::size_t>(all[static_cast<std::size_t>(b)].vert)];
      const Vec3 mid = mul(add(A, B), 0.5);
      A = mid; B = mid;
      stats.vertices_matched += 2;
    }
  }

  if (std::getenv("TOPOPT_LSLT_TRACE"))
    std::fprintf(stderr, "[lslt] Virtual-Trim: %zu unclosed node(s), %zu vertices matched\n",
                 stats.nodes_unclosed, stats.vertices_matched);
  // ── the tube walls: two rings of UNEQUAL length, stitched by angle ───────────
  // Rings differ in length now, so the strip is a merge-walk: advance whichever loop is
  // behind in normalised angle. Handedness is taken from the geometry, since a shared
  // section's frame belongs to whichever beam defined it.
  auto handed = [&](const Section& sc, const Vec3& axis) {
    if (sc.ring.size() < 2) return 1;
    const Vec3 c = node_pos[static_cast<std::size_t>(sc.node)];
    return dot(cross(sub(mesh.vertices[static_cast<std::size_t>(sc.ring[0].second)], c),
                     sub(mesh.vertices[static_cast<std::size_t>(sc.ring[1].second)], c)),
               axis) >= 0.0 ? 1 : -1; };
  for (std::size_t i = 0; i < beams.size(); ++i) {
    const Section& SA = secs[static_cast<std::size_t>(sec_of[se_index(i, 0)])];
    const Section& SB = secs[static_cast<std::size_t>(sec_of[se_index(i, 1)])];
    if (SA.ring.size() < 3 || SB.ring.size() < 3) continue;
    const int hA = handed(SA, beams[i].dir), hB = handed(SB, beams[i].dir);
    const std::size_t na = SA.ring.size(), nb = SB.ring.size();
    auto va = [&](std::size_t k) { return SA.ring[k % na].second; };
    auto vb = [&](std::size_t k) {
      const std::size_t j = hB == hA ? (k % nb) : ((nb - (k % nb)) % nb);
      return SB.ring[j].second; };
    // walk both loops, advancing the one that is behind in normalised position
    std::size_t ia = 0, ib = 0;
    while (ia < na || ib < nb) {
      const double pa = static_cast<double>(ia) / na, pb = static_cast<double>(ib) / nb;
      const bool take_a = (ib >= nb) || (ia < na && pa <= pb);
      if (take_a) {
        if (hA > 0) mesh.triangles.push_back({va(ia), va(ia + 1), vb(ib)});
        else        mesh.triangles.push_back({va(ia), vb(ib), va(ia + 1)});
        ++ia;
      } else {
        if (hA > 0) mesh.triangles.push_back({vb(ib), va(ia), vb(ib + 1)});
        else        mesh.triangles.push_back({vb(ib), vb(ib + 1), va(ia)});
        ++ib;
      }
    }
  }

  if (std::getenv("TOPOPT_LSLT_TRACE")) {
    std::map<std::pair<int, int>, int> pre;
    for (const auto& t : mesh.triangles)
      for (int k = 0; k < 3; ++k) {
        const int x = t[k], y = t[(k + 1) % 3];
        ++pre[{std::min(x, y), std::max(x, y)}];
      }
    std::size_t o = 0, m = 0;
    for (const auto& kv : pre) { if (kv.second == 1) ++o; else if (kv.second > 2) ++m; }
    std::fprintf(stderr, "[lslt] BEFORE filling: edges once=%zu, >2 times=%zu\n", o, m);
  }
  // ── ★★ CLOSE EACH HOLE, TRACED PROPERLY (paper 3.6) ─────────────────────────
  // The opening round a joint is bounded by arcs of SEVERAL rings, and at a mandatory
  // vertex -- shared by two of them by construction -- the boundary BRANCHES. Two
  // simpler closures were tried and both failed on that: a naive successor walk
  // truncated the loop (8 edges left open on a tee), and fanning a whole node's boundary
  // to one apex used the apex-to-shared-vertex edge up to four times (53,015 non-manifold
  // edges on the real lattice).
  //
  // The right pairing is the half-edge umbrella. Arriving at v along boundary edge
  // (a -> v), the loop leaves v along the first edge found by ROTATING around v through
  // the incident triangles until the far side is empty. That is the unique continuation
  // that stays on the surface, so it separates the arms of a branch correctly and every
  // loop closes on itself.
  {
    std::map<std::pair<int, int>, int> he_tri;      // directed edge -> its triangle
    const std::size_t n_tri = mesh.triangles.size();
    for (std::size_t t = 0; t < n_tri; ++t)
      for (int k = 0; k < 3; ++k)
        he_tri.emplace(std::make_pair(mesh.triangles[t][k], mesh.triangles[t][(k + 1) % 3]),
                       static_cast<int>(t));
    auto third_after = [&](int tri, int from, int v) {
      const auto& T = mesh.triangles[static_cast<std::size_t>(tri)];
      for (int k = 0; k < 3; ++k)
        if (T[k] == from && T[(k + 1) % 3] == v) return T[(k + 2) % 3];
      return -1; };
    // successor of the boundary half-edge (a -> v): rotate around v
    auto successor = [&](int a, int v) {
      auto it = he_tri.find({a, v});
      if (it == he_tri.end()) return -1;
      int w = third_after(it->second, a, v);
      int guard = 0;
      while (w >= 0 && ++guard < 256) {
        auto op = he_tri.find({w, v});              // is the far side of (v,w) covered?
        if (op == he_tri.end()) return w;           // no: (v -> w) is the next boundary
        w = third_after(op->second, w, v);
      }
      return -1; };
    std::set<std::pair<int, int>> boundary;
    for (const auto& kv : he_tri)
      if (!he_tri.count({kv.first.second, kv.first.first})) boundary.insert(kv.first);
    std::set<std::pair<int, int>> used;
    for (const auto& start : boundary) {
      if (used.count(start)) continue;
      std::vector<int> loop;
      std::pair<int, int> cur = start;
      int guard = 0;
      while (!used.count(cur) && ++guard < 8192) {
        used.insert(cur);
        loop.push_back(cur.first);
        const int nx = successor(cur.first, cur.second);
        if (nx < 0) break;
        cur = {cur.second, nx};
        if (cur == start) break;
      }
      if (loop.size() < 3) continue;
      Vec3 g{0, 0, 0};
      for (int vi : loop) g = add(g, mesh.vertices[static_cast<std::size_t>(vi)]);
      g = mul(g, 1.0 / static_cast<double>(loop.size()));
      int nd = -1;
      for (int vi : loop) {
        if (static_cast<std::size_t>(vi) < vert_node.size() && vert_node[static_cast<std::size_t>(vi)] >= 0) {
          nd = vert_node[static_cast<std::size_t>(vi)]; break;
        }
      }
      Vec3 apex = g;
      if (nd >= 0) {
        const Vec3 Nb = node_pos[static_cast<std::size_t>(nd)];
        // ★ AT AN UNCLOSED NODE THE APEX BELONGS IN THE GAP. The closure test already
        // found the one direction no strut covers, which is precisely where the joint's
        // surface has to bulge; the loop's barycentre is arbitrary next to it.
        Vec3 dg = node_open[static_cast<std::size_t>(nd)]
                      ? node_gap[static_cast<std::size_t>(nd)] : sub(g, Nb);
        if (!(len(dg) > 1e-12)) {                   // a whole ring is centred on its node
          Vec3 sum{0, 0, 0};
          for (const Incident& in : inc[static_cast<std::size_t>(nd)]) sum = add(sum, in.dir);
          dg = mul(unit(sum), -1.0);
        }
        double reach = node_R[static_cast<std::size_t>(nd)];
        for (int vi : loop)
          reach = std::max(reach, len(sub(mesh.vertices[static_cast<std::size_t>(vi)], Nb)));
        if (len(dg) > 1e-12) apex = add(Nb, mul(unit(dg), reach));
        if (inc[static_cast<std::size_t>(nd)].size() >= 3) ++stats.joints_stitched;
      }
      const int ai = static_cast<int>(mesh.vertices.size());
      mesh.vertices.push_back(apex);
      // the loop was walked along the boundary's own direction, so reverse each edge
      for (std::size_t k = 0; k < loop.size(); ++k) {
        mesh.triangles.push_back({ai, loop[(k + 1) % loop.size()], loop[k]});
        ++stats.hole_triangles;
      }
      ++stats.holes_filled;
    }
  }

  // ★★ AND WHATEVER THE WALK COULD NOT CONSUME. The umbrella pairing is only valid on a
  // surface that is already manifold, and the strips are not quite: MEASURED on the M2
  // lattice, 6,032 edges are used more than twice BEFORE any hole is filled, because a
  // high-valence node crowds its rings (2 x C(valence,2) mandatory vertices -- ninety of
  // them at valence 10 -- on a ring carrying about thirteen fill vertices). Around those
  // the walk stalls and leaves boundary behind. Tracing alone therefore left 16,598 edges
  // OPEN, which is worse than a coarse closure: a hole is a leak, a non-manifold edge is
  // not. So sweep up the remainder per node and fan it, and report how much needed it.
  {
    std::map<std::pair<int, int>, int> use2;
    std::map<std::pair<int, int>, std::pair<int, int>> dir2;
    for (const auto& t : mesh.triangles)
      for (int k = 0; k < 3; ++k) {
        const int x = t[k], y = t[(k + 1) % 3];
        const auto key = std::make_pair(std::min(x, y), std::max(x, y));
        ++use2[key];
        dir2[key] = {x, y};
      }
    std::unordered_map<int, std::vector<std::pair<int, int>>> left;
    for (const auto& kv : use2) {
      if (kv.second != 1) continue;
      const auto d = dir2[kv.first];
      int nd = -1;
      if (static_cast<std::size_t>(d.first) < vert_node.size()) nd = vert_node[static_cast<std::size_t>(d.first)];
      if (nd < 0 && static_cast<std::size_t>(d.second) < vert_node.size())
        nd = vert_node[static_cast<std::size_t>(d.second)];
      if (nd < 0) continue;
      left[nd].push_back(d);
      ++stats.edges_swept;
    }
    for (const auto& kv : left) {
      const std::size_t nd = static_cast<std::size_t>(kv.first);
      const Vec3 Nb = node_pos[nd];
      Vec3 g{0, 0, 0};
      for (const auto& e : kv.second)
        g = add(g, mul(add(mesh.vertices[static_cast<std::size_t>(e.first)],
                           mesh.vertices[static_cast<std::size_t>(e.second)]), 0.5));
      g = mul(g, 1.0 / static_cast<double>(kv.second.size()));
      Vec3 dg = sub(g, Nb);
      if (!(len(dg) > 1e-12)) {
        Vec3 sum{0, 0, 0};
        for (const Incident& in : inc[nd]) sum = add(sum, in.dir);
        dg = mul(unit(sum), -1.0);
      }
      double reach = node_R[nd];
      for (const auto& e : kv.second)
        reach = std::max(reach, len(sub(mesh.vertices[static_cast<std::size_t>(e.first)], Nb)));
      const Vec3 apex = (len(dg) > 1e-12) ? add(Nb, mul(unit(dg), reach)) : Nb;
      const int ai = static_cast<int>(mesh.vertices.size());
      mesh.vertices.push_back(apex);
      for (const auto& e : kv.second) {
        mesh.triangles.push_back({ai, e.second, e.first});
        ++stats.hole_triangles;
      }
      ++stats.holes_filled;
    }
  }

  stats.triangles = mesh.triangles.size();

  // ── the closure check, on the mesh that is about to be written ──────────────
  {
    std::map<std::pair<int, int>, int> use;
    for (const auto& t : mesh.triangles)
      for (int k = 0; k < 3; ++k) {
        const int x = t[k], y = t[(k + 1) % 3];
        ++use[{std::min(x, y), std::max(x, y)}];
      }
    std::size_t once = 0, many = 0, degen = 0;
    for (const auto& kv : use) {
      if (kv.first.first == kv.first.second) { ++degen; continue; }
      if (kv.second == 1) ++once;
      else if (kv.second != 2) ++many;
    }
    stats.boundary_edges_left = once + many + degen;
    if (std::getenv("TOPOPT_LSLT_TRACE"))
      std::fprintf(stderr, "[lslt] edges used once=%zu, >2 times=%zu, degenerate=%zu\n",
                   once, many, degen);
    stats.watertight = stats.boundary_edges_left == 0;
  }
  // signed volume, for the mass accounting to be checked against
  double vol = 0.0;
  for (const auto& t : mesh.triangles) {
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(t[2])];
    vol += dot(a, cross(b, c));
  }
  stats.volume_mm3 = vol / 6.0;
  return mesh;
}

}  // namespace topopt
