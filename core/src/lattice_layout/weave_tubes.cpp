// Organic cut 2 (brief E1): a weave's bars as closed shells beside the solid, never joined (OF2, OF3).
// See lattice_layout_mesh.hpp, weave_shells.
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <map>
#include <thread>

#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/lattice_layout_organic.hpp"

namespace topopt::lattice_layout {
namespace {

Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
double len(const Vec3& a) { return std::sqrt(dot(a, a)); }
Vec3 unit(const Vec3& a) { const double l = len(a); return l > 0.0 ? mul(a, 1.0 / l) : Vec3{0, 0, 0}; }
// `v` turned by the rotation that takes unit `a` to unit `b` (parallel transport of a frame along a polyline).
Vec3 turn(const Vec3& v, const Vec3& a, const Vec3& b) {
  const Vec3 c = cross(a, b);
  const double s = len(c), d = dot(a, b);
  if (s < 1e-12) return v;
  const Vec3 k = mul(c, 1.0 / s);
  return add(add(mul(v, d), mul(cross(k, v), s)), mul(k, dot(k, v) * (1.0 - d)));
}

// The signed volume of triangles [t0, t1) of `m`.
double volume_of(const TriangleMesh& m, std::size_t t0, std::size_t t1) {
  double v = 0.0;
  for (std::size_t t = t0; t < t1; ++t) {
    const auto& q = m.triangles[t];
    const Vec3 &a = m.vertices[static_cast<std::size_t>(q[0])], &b = m.vertices[static_cast<std::size_t>(q[1])],
               &c = m.vertices[static_cast<std::size_t>(q[2])];
    v += dot(a, cross(b, c)) / 6.0;
  }
  return v;
}

// One tube to sweep: its centre line, the radius at each point, and how each end is closed.
// Round: a round tube's half-sphere. Dome (OS1 B): a shallow run's end rounded IN PLAN ONLY (the piece's own end flat,
// a puck of its section revolved about the vertical there: sweep_puck).
enum class Cap { Flat, Round, Dome };
// kind 0: round (r the polygon's equal-area radius); 1: a shallow run's D section, 2: its square bar (r half the width,
// as build_mesh's StrutMaker writes a shallow bar; its ends flat, or domed with OS1 B).
struct Piece {
  std::vector<Vec3> p;
  std::vector<double> r;   // per point
  Cap cap_a = Cap::Round, cap_b = Cap::Round;
  int kind = 0;
  int sides = 0;           // OS1 A: a round piece's own sides (0: the spec's tube_sides)
  // OG2 (brief E6): a proud end's tube, from the point before it to its tip: the trim leaves the vertices outside the part
  // that lie within this tube (radius x 1.16, a mitred ring's widest) and no more than `out` (proud + radius) outside.
  // OG2b (leg B): `along` true: a bar along an open face; a vertex within it may stand out of the surface by no more than
  // `out` (its strand's p): one farther out is brought back to `out`, never pushed out.
  struct Proud { Vec3 from{}, tip{}; double r = 0.0, out = 0.0; bool along = false; };
  std::vector<Proud> proud;
  // OV1: how far the swept centre line may lie from the bars the proud tubes are read along (0: not swept).
  double slack = 0.0;
};

// A shallow run swept with its own section (the D of O14, or the square bar), the section's frame fixed by the build
// direction at every segment (its side level, square to the segment; its flat side down), never carried along. At a
// joint the ring is the mean of where the two segments' section lines meet the bisecting plane; both ends flat (an OS1 B
// rounded end is a shell of its own: sweep_puck).
bool sweep_section(const Piece& pc, int bar_sides, TriangleMesh& out, std::vector<std::size_t>& first_tri) {
  const std::size_t n = pc.p.size();
  if (n < 2) return false;
  const std::size_t m = n - 1;
  const double kPi = 3.14159265358979323846;
  const int half_facets = std::max(2, std::max(3, bar_sides) / 2);
  std::vector<Vec3> T(m), side(m), up(m);
  for (std::size_t k = 0; k < m; ++k) {
    T[k] = unit(sub(pc.p[k + 1], pc.p[k]));
    if (len(T[k]) == 0.0) return false;
    Vec3 sd{-T[k].y, T[k].x, 0.0};
    if (len(sd) < 1e-9) return false;   // a vertical segment has no level side: never a shallow bar
    sd = unit(sd);
    Vec3 u = cross(T[k], sd);
    if (u.z < 0) { u = mul(u, -1.0); sd = mul(sd, -1.0); }
    side[k] = sd;
    up[k] = u;
  }
  // The section in (side, up) coordinates for a half width r: build_mesh's d_section or square bar, in order round it.
  auto section = [&](double r) {
    std::vector<std::array<double, 2>> q;
    if (pc.kind == 1) {
      q.push_back({-r, -r});
      q.push_back({r, -r});
      for (int k = 0; k <= half_facets; ++k) {
        const double t = kPi * k / half_facets;
        q.push_back({r * std::cos(t), r * std::sin(t)});
      }
    } else {
      q = {{-r, -r}, {r, -r}, {r, r}, {-r, r}};
    }
    return q;
  };
  const int ns = static_cast<int>(section(1.0).size());
  std::vector<std::vector<Vec3>> rings;
  for (std::size_t j = 0; j <= m; ++j) {
    const auto q = section(pc.r[j]);
    std::vector<Vec3> ring(static_cast<std::size_t>(ns));
    if (j == 0 || j == m) {
      const std::size_t k = j == 0 ? 0 : m - 1;
      for (int i = 0; i < ns; ++i)
        ring[static_cast<std::size_t>(i)] = add(pc.p[j], add(mul(side[k], q[static_cast<std::size_t>(i)][0]), mul(up[k], q[static_cast<std::size_t>(i)][1])));
    } else {
      const Vec3 nb = unit(add(T[j - 1], T[j]));
      for (int i = 0; i < ns; ++i) {
        Vec3 at[2];
        for (int h = 0; h < 2; ++h) {
          const std::size_t k = h == 0 ? j - 1 : j;
          const Vec3 d = add(mul(side[k], q[static_cast<std::size_t>(i)][0]), mul(up[k], q[static_cast<std::size_t>(i)][1]));
          at[h] = sub(add(pc.p[j], d), mul(T[k], dot(d, nb) / dot(T[k], nb)));
        }
        ring[static_cast<std::size_t>(i)] = mul(add(at[0], at[1]), 0.5);
      }
    }
    rings.push_back(std::move(ring));
  }
  const int base = static_cast<int>(out.vertices.size());
  const std::size_t t0 = out.triangles.size();
  for (const auto& ring : rings) out.vertices.insert(out.vertices.end(), ring.begin(), ring.end());
  const int nr = static_cast<int>(rings.size());
  auto at = [&](int ring, int i) { return base + ring * ns + (i % ns); };
  for (int j = 0; j + 1 < nr; ++j)
    for (int i = 0; i < ns; ++i) {
      out.triangles.push_back({at(j, i), at(j, i + 1), at(j + 1, i + 1)});
      out.triangles.push_back({at(j, i), at(j + 1, i + 1), at(j + 1, i)});
    }
  for (int i = 1; i + 1 < ns; ++i) {
    out.triangles.push_back({at(0, 0), at(0, i + 1), at(0, i)});
    out.triangles.push_back({at(nr - 1, 0), at(nr - 1, i), at(nr - 1, i + 1)});
  }
  if (volume_of(out, t0, out.triangles.size()) < 0.0)
    for (std::size_t t = t0; t < out.triangles.size(); ++t) std::swap(out.triangles[t][1], out.triangles[t][2]);
  first_tri.push_back(t0);
  return true;
}

// OS1 B (the reviewer's ruling with the owner's approval, 2026-11-20; his rule of 11-12: "Please ensure bridges are flat
// and not curved. This is very important."): a shallow run's rounded end, its section revolved about the VERTICAL (the
// build direction) through the end point `c`: a closed shell, round in plan, its underside one level disc at the bar's
// own underside height there (c.z - r up.z), its side straight up to c.z, its top the D's round top revolved (a flat top
// for the square bar). Its back half lies inside the bar (or, at a corner, the next bar): seen from above an end is a
// half circle and a corner a smooth turn; seen from the side the bar's bottom is a flat line to its very end.
bool sweep_puck(const Vec3& c, double r, double up_z, int kind, int sides, int bar_sides, TriangleMesh& out,
                std::vector<std::size_t>& first_tri) {
  if (!(r > 0.0) || sides < 3) return false;
  const double kPi = 3.14159265358979323846;
  const double zb = c.z - r * up_z;
  // The profile from the axis out and up: (radius, z) rows; the first and last on the axis.
  std::vector<std::array<double, 2>> prof;
  prof.push_back({0.0, zb});
  prof.push_back({r, zb});
  if (kind == 1) {
    const int arc = std::max(2, std::max(2, std::max(3, bar_sides) / 2) / 2);   // the D's top: half its facets a quarter
    for (int k = 0; k < arc; ++k) {
      const double t = 0.5 * kPi * k / arc;
      prof.push_back({r * std::cos(t), c.z + r * std::sin(t)});
    }
    prof.push_back({0.0, c.z + r});
  } else {
    prof.push_back({r, zb + 2.0 * r * up_z});
    prof.push_back({0.0, zb + 2.0 * r * up_z});
  }
  const int rows = static_cast<int>(prof.size());   // rows 0 and rows - 1 are single vertices on the axis
  const int base = static_cast<int>(out.vertices.size());
  const std::size_t t0 = out.triangles.size();
  out.vertices.push_back({c.x, c.y, prof[0][1]});
  for (int k = 1; k + 1 < rows; ++k)
    for (int i = 0; i < sides; ++i) {
      const double a = 2.0 * kPi * i / sides;
      out.vertices.push_back({c.x + prof[static_cast<std::size_t>(k)][0] * std::cos(a),
                              c.y + prof[static_cast<std::size_t>(k)][0] * std::sin(a), prof[static_cast<std::size_t>(k)][1]});
    }
  out.vertices.push_back({c.x, c.y, prof.back()[1]});
  const int bottom = base, top = static_cast<int>(out.vertices.size()) - 1;
  auto at = [&](int k, int i) { return base + 1 + (k - 1) * sides + (i % sides); };
  for (int i = 0; i < sides; ++i) out.triangles.push_back({bottom, at(1, i + 1), at(1, i)});
  for (int k = 1; k + 2 < rows; ++k)
    for (int i = 0; i < sides; ++i) {
      out.triangles.push_back({at(k, i), at(k, i + 1), at(k + 1, i + 1)});
      out.triangles.push_back({at(k, i), at(k + 1, i + 1), at(k + 1, i)});
    }
  for (int i = 0; i < sides; ++i) out.triangles.push_back({top, at(rows - 2, i), at(rows - 2, i + 1)});
  if (volume_of(out, t0, out.triangles.size()) < 0.0)
    for (std::size_t t = t0; t < out.triangles.size(); ++t) std::swap(out.triangles[t][1], out.triangles[t][2]);
  first_tri.push_back(t0);
  return true;
}

// Appends the closed tube of `pc` to `out` (its own vertices), outward. False when it has no length.
bool sweep(const Piece& pc, int sides, TriangleMesh& out, std::vector<std::size_t>& first_tri) {
  const std::size_t n = pc.p.size();
  if (n < 2) return false;
  const std::size_t m = n - 1;
  std::vector<Vec3> T(m);
  for (std::size_t k = 0; k < m; ++k) {
    T[k] = unit(sub(pc.p[k + 1], pc.p[k]));
    if (len(T[k]) == 0.0) return false;
  }
  const double kPi = 3.14159265358979323846;
  std::vector<double> ca(static_cast<std::size_t>(sides)), sa(static_cast<std::size_t>(sides));
  for (int s = 0; s < sides; ++s) {
    ca[static_cast<std::size_t>(s)] = std::cos(2.0 * kPi * s / sides);
    sa[static_cast<std::size_t>(s)] = std::sin(2.0 * kPi * s / sides);
  }
  const int lat = std::max(1, sides / 4);   // a half-sphere's rings between its rim and its pole
  const Vec3 ref = std::fabs(T[0].z) < 0.9 ? Vec3{0, 0, 1} : Vec3{1, 0, 0};
  Vec3 u = unit(cross(T[0], ref)), v = cross(T[0], u);
  const Vec3 u0 = u, v0 = v;
  std::vector<std::vector<Vec3>> rings;
  auto ring_at = [&](const Vec3& c, double r, const Vec3& a, const Vec3& b) {
    std::vector<Vec3> ring(static_cast<std::size_t>(sides));
    for (int s = 0; s < sides; ++s)
      ring[static_cast<std::size_t>(s)] = add(c, add(mul(a, r * ca[static_cast<std::size_t>(s)]), mul(b, r * sa[static_cast<std::size_t>(s)])));
    return ring;
  };
  Vec3 pole_a{}, pole_b{};
  if (pc.cap_a == Cap::Round) {
    const double r = pc.r[0];
    for (int i = lat; i >= 1; --i) {
      const double phi = 0.5 * kPi * i / (lat + 1);
      rings.push_back(ring_at(sub(pc.p[0], mul(T[0], r * std::sin(phi))), r * std::cos(phi), u0, v0));
    }
    pole_a = sub(pc.p[0], mul(T[0], r));
  }
  for (std::size_t j = 0; j <= m; ++j) {
    if (j == 0 || j == m) { rings.push_back(ring_at(pc.p[j], pc.r[j], u, v)); continue; }
    // The mitre: the ring of the incoming tube carried along its own line onto the bisecting plane.
    const Vec3 tin = T[j - 1], tout = T[j];
    const Vec3 nb = unit(add(tin, tout));
    const double r = pc.r[j];
    std::vector<Vec3> ring(static_cast<std::size_t>(sides));
    for (int s = 0; s < sides; ++s) {
      const Vec3 d = add(mul(u, ca[static_cast<std::size_t>(s)]), mul(v, sa[static_cast<std::size_t>(s)]));
      ring[static_cast<std::size_t>(s)] = sub(add(pc.p[j], mul(d, r)), mul(tin, r * dot(d, nb) / dot(tin, nb)));
    }
    rings.push_back(std::move(ring));
    u = turn(u, tin, tout);
    v = turn(v, tin, tout);
  }
  if (pc.cap_b == Cap::Round) {
    const double r = pc.r[m];
    for (int i = 1; i <= lat; ++i) {
      const double phi = 0.5 * kPi * i / (lat + 1);
      rings.push_back(ring_at(add(pc.p[m], mul(T[m - 1], r * std::sin(phi))), r * std::cos(phi), u, v));
    }
    pole_b = add(pc.p[m], mul(T[m - 1], r));
  }
  const int base = static_cast<int>(out.vertices.size());
  const std::size_t t0 = out.triangles.size();
  for (const auto& ring : rings) out.vertices.insert(out.vertices.end(), ring.begin(), ring.end());
  const int nr = static_cast<int>(rings.size());
  auto at = [&](int ring, int s) { return base + ring * sides + (s % sides); };
  for (int j = 0; j + 1 < nr; ++j)
    for (int s = 0; s < sides; ++s) {
      out.triangles.push_back({at(j, s), at(j, s + 1), at(j + 1, s + 1)});
      out.triangles.push_back({at(j, s), at(j + 1, s + 1), at(j + 1, s)});
    }
  if (pc.cap_a == Cap::Round) {
    const int pa = static_cast<int>(out.vertices.size());
    out.vertices.push_back(pole_a);
    for (int s = 0; s < sides; ++s) out.triangles.push_back({pa, at(0, s + 1), at(0, s)});
  } else {
    for (int s = 1; s + 1 < sides; ++s) out.triangles.push_back({at(0, 0), at(0, s + 1), at(0, s)});
  }
  if (pc.cap_b == Cap::Round) {
    const int pb = static_cast<int>(out.vertices.size());
    out.vertices.push_back(pole_b);
    for (int s = 0; s < sides; ++s) out.triangles.push_back({pb, at(nr - 1, s), at(nr - 1, s + 1)});
  } else {
    for (int s = 1; s + 1 < sides; ++s) out.triangles.push_back({at(nr - 1, 0), at(nr - 1, s), at(nr - 1, s + 1)});
  }
  // Outward: a positive volume (flipped when the frame came out left-handed).
  if (volume_of(out, t0, out.triangles.size()) < 0.0)
    for (std::size_t t = t0; t < out.triangles.size(); ++t) std::swap(out.triangles[t][1], out.triangles[t][2]);
  first_tri.push_back(t0);
  return true;
}

double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

}  // namespace

int tube_sides_for(double width_mm, const MeshSpec& spec) {
  const int floor_sides = std::max(3, spec.tube_sides);
  if (!(spec.tube_facet_mm > 0.0)) return floor_sides;
  const double r = 0.5 * width_mm;
  if (!(r > 0.0)) return floor_sides;
  const double c = 1.0 - spec.tube_facet_mm / r;
  int n = c <= -1.0 ? 3 : static_cast<int>(std::ceil(3.14159265358979323846 / std::acos(std::max(-1.0, c)) - 1e-9));
  n += n % 2;   // even: a ring's sides pair across it
  return std::max(floor_sides, std::min(24, n));
}

double tube_round_factor(int sides) {
  const double kPi = 3.14159265358979323846;
  return std::sqrt(2.0 * kPi / (sides * std::sin(2.0 * kPi / sides)));
}

std::vector<std::size_t> mitre_fold_splits(const std::vector<Vec3>& p, const std::vector<double>& corner) {
  const std::size_t n = p.size();
  std::vector<std::size_t> out;
  if (n < 3 || corner.size() != n) return out;
  std::vector<double> off(n, 0.0), seg(n - 1, 0.0);
  std::vector<Vec3> t(n - 1);
  for (std::size_t k = 0; k + 1 < n; ++k) { t[k] = sub(p[k + 1], p[k]); seg[k] = len(t[k]); t[k] = unit(t[k]); }
  for (std::size_t j = 1; j + 1 < n; ++j) {
    const double c = std::clamp(dot(t[j - 1], t[j]), -1.0, 1.0);
    const double half = 0.5 * std::acos(c);
    off[j] = corner[j] * std::tan(std::min(half, 1.5));
  }
  std::vector<char> ended(n, 0);
  for (bool again = true; again;) {
    again = false;
    for (std::size_t k = 0; k + 1 < n; ++k) {
      const double oa = ended[k] ? 0.0 : off[k], ob = ended[k + 1] ? 0.0 : off[k + 1];
      if (!(seg[k] < oa + ob - 1e-9)) continue;
      const std::size_t j = oa >= ob ? k : k + 1;
      if (j == 0 || j + 1 == n || ended[j]) continue;
      ended[j] = 1;
      again = true;
    }
  }
  for (std::size_t j = 1; j + 1 < n; ++j)
    if (ended[j]) out.push_back(j);
  return out;
}

WeaveShells weave_shells(const PartMeasure& part, const Domain& domain, const Layout& layout, const Bars& bars,
                         const std::vector<char>& kept, const Carved& carved, const MeshSpec& spec, bool trim) {
  const auto t0 = std::chrono::steady_clock::now();
  WeaveShells out;
  std::vector<int> regions;
  for (const Layout::Weave& w : layout.weave) regions.push_back(w.region);
  auto in_file = [&](std::size_t i) {
    return (kept.empty() || (i < kept.size() && kept[i])) &&
           std::find(regions.begin(), regions.end(), bars.bars[i].region) != regions.end();
  };
  // Every kept weave bar is read as runs (a shallow run swept with its own section); feet stay build_mesh's shapes.
  Bars woven;
  std::vector<char> strut(bars.bars.size(), 0), feet(bars.bars.size(), 0);
  std::vector<int> round_top;
  if (spec.weave_round_top) round_top = regions;
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    if (!in_file(i)) continue;
    feet[i] = 1;
    woven.bars.push_back(bars.bars[i]);
  }
  auto kind_of = [&](const Bar& b) {
    if (!bar_is_bridge(b, spec.bridge_rise)) return 0;
    return std::find(round_top.begin(), round_top.end(), b.region) != round_top.end() ? 1 : 2;
  };
  std::vector<std::vector<std::size_t>> bar_of;
  const std::vector<WeaveRun> runs = weave_runs(woven, regions, 0.0, &bar_of);
  const int sides = std::max(3, spec.tube_sides);
  const double kPi = 3.14159265358979323846;
  const double run_on = strut_run_on_mm(carved, spec);
  const double sharp = std::cos(60.0 * kPi / 180.0);   // a turn sharper than 60 degrees ends the tube
  std::vector<Piece> pieces;   // kept for OF3's rebuild
  // OS1 B: a dome, unless the print check held this end flat (MeshSpec::flat_domes_at).
  auto dome_or_flat = [&](const Vec3& at) {
    for (const Vec3& f : spec.flat_domes_at)
      if (len(sub(f, at)) < 1e-6) { ++out.domes_held_flat; return Cap::Flat; }
    return Cap::Dome;
  };
  // A finished piece: its domes listed for the print check, its sides counted.
  auto add_piece = [&](Piece&& pc) {
    if (pc.kind == 0) {
      out.tube_sides_least = out.tube_sides_least == 0 ? pc.sides : std::min(out.tube_sides_least, pc.sides);
      out.tube_sides_most = std::max(out.tube_sides_most, pc.sides);
    }
    pieces.push_back(std::move(pc));
  };
  for (std::size_t q = 0; q < runs.size(); ++q) {
    const std::vector<std::size_t>& segs = bar_of[q];
    // The centre line, with each segment's bar width and kind; zero-length segments dropped.
    std::vector<Vec3> pts{woven.bars[segs[0]].a};
    std::vector<double> w;   // per segment
    std::vector<int> kind;   // per segment
    std::vector<double> along;   // per segment: OG2b's along_proud of its bar
    for (std::size_t s : segs) {
      const Bar& b = woven.bars[s];
      if (len(sub(b.b, pts.back())) < 1e-9) continue;
      pts.push_back(b.b);
      along.push_back(b.along_proud);
      w.push_back(b.width);
      kind.push_back(kind_of(b));
    }
    if (pts.size() < 2) continue;
    const Bar::End ea = woven.bars[segs.front()].end_a, eb = woven.bars[segs.back()].end_b;
    // OG2: a Surface end standing proud of the face (its bar's own proud_a / proud_b).
    const double proud_a = ea == Bar::End::Surface ? woven.bars[segs.front()].proud_a : 0.0;
    const double proud_b = eb == Bar::End::Surface ? woven.bars[segs.back()].proud_b : 0.0;
    std::size_t start = 0;
    for (std::size_t k = 1; k <= w.size(); ++k) {
      const bool last = k == w.size();
      const bool turn_split = !last && dot(unit(sub(pts[k], pts[k - 1])), unit(sub(pts[k + 1], pts[k]))) < sharp;
      const bool kind_split = !last && kind[k] != kind[k - 1];
      if (!last && !turn_split && !kind_split) continue;
      Piece pc;
      pc.kind = kind[start];
      pc.p.assign(pts.begin() + static_cast<std::ptrdiff_t>(start), pts.begin() + static_cast<std::ptrdiff_t>(k) + 1);
      if (pc.kind == 0) {   // OS1 A: its own sides, from its widest bar (tube_sides with tube_facet_mm 0)
        double widest = 0.0;
        for (std::size_t j = start; j < k; ++j) widest = std::max(widest, w[j]);
        pc.sides = tube_sides_for(widest, spec);
      }
      const double k_round = pc.kind == 0 ? tube_round_factor(pc.sides) : 1.0;   // equal area
      for (std::size_t j = start; j <= k; ++j) {
        const double wj = j == start ? w[start] : j == k ? w[k - 1] : std::max(w[j - 1], w[j]);
        pc.r.push_back(0.5 * wj * (pc.kind == 0 ? k_round : 1.0));
      }
      const bool outer_a = start == 0, outer_b = last;
      if (pc.kind == 0) {
        // Ends: in solid, run on and flat; on the surface, flat there; else (a joint, a free end, a split) round.
        pc.cap_a = outer_a && (ea == Bar::End::Solid || ea == Bar::End::Surface) ? Cap::Flat : Cap::Round;
        pc.cap_b = outer_b && (eb == Bar::End::Solid || eb == Bar::End::Surface) ? Cap::Flat : Cap::Round;
        // OG2: a proud end is a half-sphere cap, its tube left outside the part by the trim.
        if (outer_a && proud_a > 0.0) {
          pc.cap_a = Cap::Round;
          pc.proud.push_back({pc.p[1], pc.p[0], pc.r.front(), proud_a + pc.r.front()});
          ++out.proud_ends;
        }
        if (outer_b && proud_b > 0.0) {
          pc.cap_b = Cap::Round;
          pc.proud.push_back({pc.p[pc.p.size() - 2], pc.p.back(), pc.r.back(), proud_b + pc.r.back()});
          ++out.proud_ends;
        }
      } else {
        // Flat at both ends; run on as build_mesh runs a shallow bar on, except on the surface (flat there). OS1 B: domed
        // wherever a round tube's end is round (not in solid, not flush on the surface), unless the print check held it
        // flat (no run-on then: the dome reaches past the end).
        pc.cap_a = pc.cap_b = Cap::Flat;
        if (spec.weave_bridge_domes) {
          if (!(outer_a && (ea == Bar::End::Solid || (ea == Bar::End::Surface && !(proud_a > 0.0))))) pc.cap_a = dome_or_flat(pc.p.front());
          if (!(outer_b && (eb == Bar::End::Solid || (eb == Bar::End::Surface && !(proud_b > 0.0))))) pc.cap_b = dome_or_flat(pc.p.back());
        }
        // OG2: a shallow run's proud end keeps its flat end (its section has no round cap); its proud part is left out
        // of the trim as a tube's is (the section's corner, r x sqrt 2, from its line).
        const double rs = 1.41421356237 * pc.r.front(), re = 1.41421356237 * pc.r.back();
        if (outer_a && proud_a > 0.0) { pc.proud.push_back({pc.p[1], pc.p[0], rs, proud_a + rs}); ++out.proud_ends; }
        if (outer_b && proud_b > 0.0) { pc.proud.push_back({pc.p[pc.p.size() - 2], pc.p.back(), re, proud_b + re}); ++out.proud_ends; }
      }
      const bool on_a = pc.kind == 0 ? outer_a && ea == Bar::End::Solid
                                     : pc.cap_a == Cap::Flat && !(outer_a && ea == Bar::End::Surface);
      const bool on_b = pc.kind == 0 ? outer_b && eb == Bar::End::Solid
                                     : pc.cap_b == Cap::Flat && !(outer_b && eb == Bar::End::Surface);
      if (on_a) pc.p.front() = sub(pc.p.front(), mul(unit(sub(pc.p[1], pc.p[0])), run_on));
      if (on_b) {
        const std::size_t e = pc.p.size() - 1;
        pc.p[e] = add(pc.p[e], mul(unit(sub(pc.p[e], pc.p[e - 1])), run_on));
      }
      // OG2b: the piece's bars that run along an open face.
      for (std::size_t j = start; j < k; ++j) {
        if (!(along[j] > 0.0)) continue;
        const double rr = pc.r[j - start] > pc.r[j - start + 1] ? pc.r[j - start] : pc.r[j - start + 1];
        const double rz = pc.kind == 0 ? rr : 1.41421356237 * rr;
        pc.proud.push_back({pts[j], pts[j + 1], rz, along[j], true});
        ++out.along_bars;
      }
      // OV1: a round tube's centre line swept as a curve (a shallow run's section stays straight, R5; the span that ends
      // in solid stays straight with its run-on, R4). Its proud and along tubes keep their bars; the trim reads them
      // max_offset_mm wider (the curve is within that of its bars).
      if (pc.kind == 0 && spec.sweep.on && pc.p.size() >= 3) {
        std::vector<char> held(pc.p.size() - 1, 0);
        if (outer_a && ea == Bar::End::Solid) held.front() = 1;
        if (outer_b && eb == Bar::End::Solid) held.back() = 1;
        out.sweep_pieces_before += pc.p.size() - 1;
        SweptLine sl = sweep_centre_line(pc.p, pc.r, spec.sweep, &held);
        out.sweep_spans_curved += sl.spans_curved;
        out.sweep_mitre_small_turn += sl.mitre_small_turn;
        out.sweep_mitre_tight += sl.mitre_tight;
        out.sweep_mitre_straight_end += sl.mitre_straight_end;
        for (const Vec3& q : sl.tight_at)
          if (out.sweep_tight_at.size() < 20) out.sweep_tight_at.push_back(q);
        out.sweep_largest_offset_mm = std::max(out.sweep_largest_offset_mm, sl.largest_offset_mm);
        pc.p = std::move(sl.p);
        pc.r = std::move(sl.r);
        out.swept_lines.push_back(pc.p);
        pc.slack = spec.sweep.max_offset_mm;
        out.sweep_pieces_after += pc.p.size() - 1;
      } else if (pc.kind == 0 && spec.sweep.on) {
        out.sweep_pieces_before += pc.p.size() - 1;
        out.sweep_pieces_after += pc.p.size() - 1;
      }
      out.sharp_splits += turn_split;
      // OS1 D: ended where a mitred ring would cross the next (a round end, a dome, or flat with domes off).
      if (spec.weave_fold_split && pc.p.size() >= 3) {
        std::vector<double> corner(pc.r.size());
        for (std::size_t j = 0; j < pc.r.size(); ++j) corner[j] = pc.kind == 0 ? pc.r[j] : 1.41421356237 * pc.r[j];
        const std::vector<std::size_t> at = mitre_fold_splits(pc.p, corner);
        if (!at.empty()) {
          out.fold_splits += at.size();
          std::size_t from = 0;
          for (std::size_t q2 = 0; q2 <= at.size(); ++q2) {
            const std::size_t to = q2 < at.size() ? at[q2] : pc.p.size() - 1;
            Piece part_of = pc;
            part_of.p.assign(pc.p.begin() + static_cast<std::ptrdiff_t>(from), pc.p.begin() + static_cast<std::ptrdiff_t>(to) + 1);
            part_of.r.assign(pc.r.begin() + static_cast<std::ptrdiff_t>(from), pc.r.begin() + static_cast<std::ptrdiff_t>(to) + 1);
            const Cap inner = pc.kind == 0 ? Cap::Round : spec.weave_bridge_domes ? Cap::Dome : Cap::Flat;
            if (from > 0) part_of.cap_a = inner == Cap::Dome ? dome_or_flat(part_of.p.front()) : inner;
            if (q2 < at.size()) part_of.cap_b = inner == Cap::Dome ? dome_or_flat(part_of.p.back()) : inner;
            add_piece(std::move(part_of));
            from = to;
          }
          start = k;
          continue;
        }
      }
      add_piece(std::move(pc));
      start = k;
    }
  }
  // Every shell on its own, to be trimmed (OF3) on any number of threads; joined into one list at the end.
  std::vector<TriangleMesh> shells;
  std::vector<int> made_from;   // per shell: its piece, or -1 (a shape of build_mesh's)
  auto split_off = [&](TriangleMesh& all, std::vector<std::size_t>& firsts, int piece) {
    firsts.push_back(all.triangles.size());
    for (std::size_t s = 0; s + 1 < firsts.size(); ++s) {
      TriangleMesh one;
      int lo = 1 << 30, hi = -1;
      for (std::size_t t = firsts[s]; t < firsts[s + 1]; ++t)
        for (int k = 0; k < 3; ++k) { lo = std::min(lo, all.triangles[t][static_cast<std::size_t>(k)]); hi = std::max(hi, all.triangles[t][static_cast<std::size_t>(k)]); }
      if (hi < 0) continue;
      one.vertices.assign(all.vertices.begin() + lo, all.vertices.begin() + hi + 1);
      for (std::size_t t = firsts[s]; t < firsts[s + 1]; ++t)
        one.triangles.push_back({all.triangles[t][0] - lo, all.triangles[t][1] - lo, all.triangles[t][2] - lo});
      shells.push_back(std::move(one));
      made_from.push_back(piece);
    }
  };
  for (std::size_t i = 0; i < pieces.size(); ++i) {
    TriangleMesh one;
    std::vector<std::size_t> firsts;
    if (!(pieces[i].kind == 0 ? sweep(pieces[i], pieces[i].sides > 0 ? pieces[i].sides : sides, one, firsts) : sweep_section(pieces[i], spec.bar_sides, one, firsts))) continue;
    ++(pieces[i].kind == 0 ? out.tubes : out.bridges);
    split_off(one, firsts, static_cast<int>(i));
  }
  // OS1 B: each rounded shallow end, once per place (two bars meeting at a corner share one; the wider is kept): its
  // section revolved about the vertical there, a shell of its own (trimmed with its piece's relief).
  {
    struct Puck { Vec3 c; double r = 0.0, up_z = 1.0; int kind = 1; std::size_t piece = 0; };
    std::map<std::array<long long, 3>, Puck> at;
    for (std::size_t i = 0; i < pieces.size(); ++i) {
      const Piece& pc = pieces[i];
      if (pc.kind == 0 || pc.p.size() < 2) continue;
      for (int e = 0; e < 2; ++e) {
        if ((e == 0 ? pc.cap_a : pc.cap_b) != Cap::Dome) continue;
        const std::size_t j = e == 0 ? 0 : pc.p.size() - 1;
        const Vec3 t = unit(e == 0 ? sub(pc.p[1], pc.p[0]) : sub(pc.p[j], pc.p[j - 1]));
        const std::array<long long, 3> key = {std::llround(pc.p[j].x * 1e5), std::llround(pc.p[j].y * 1e5), std::llround(pc.p[j].z * 1e5)};
        auto it = at.find(key);
        if (it != at.end() && it->second.r >= pc.r[j]) continue;
        at[key] = Puck{pc.p[j], pc.r[j], std::sqrt(t.x * t.x + t.y * t.y), pc.kind, i};
      }
    }
    for (const auto& kv : at) {
      const Puck& u = kv.second;
      TriangleMesh one;
      std::vector<std::size_t> firsts;
      const int ps = std::max(12, tube_sides_for(2.0 * u.r, spec));
      if (!sweep_puck(u.c, u.r, u.up_z, u.kind, ps, spec.bar_sides, one, firsts)) continue;
      ++out.bridge_domes;
      out.dome_ends.push_back({u.c.x, u.c.y, u.c.z, u.r});
      split_off(one, firsts, static_cast<int>(u.piece));
    }
  }
  // build_mesh's own shapes: the shallow struts, the feet, the posts.
  {
    MeshReport counts;
    TriangleMesh all;
    std::vector<std::size_t> firsts;
    weave_bar_shells(domain, layout, bars, strut, feet, carved, spec, all, firsts, counts);
    out.feet = counts.feet;
    out.posts = counts.posts;
    split_off(all, firsts, -1);
  }
  // OF3: trimmed to the part.
  std::vector<char> keep(shells.size(), 1);
  if (trim && !shells.empty()) {
    const double over = 0.02;
    // Nothing below the bed (the part's lowest z): a vertex left within `over` of the part but under the bed would
    // become the file's lowest point and lift the bed off the solid's flat underside; it is raised onto the bed.
    double bed = 1e300;
    for (const Vec3& v : part.mesh().vertices) bed = std::min(bed, v.z);
    std::vector<double> moved_most(shells.size(), 0.0), outside_most(shells.size(), 0.0);
    std::vector<std::size_t> moved(shells.size(), 0);
    std::vector<std::size_t> proud_left(shells.size(), 0);   // OG2
    std::vector<double> proud_most(shells.size(), 0.0);
    std::vector<std::size_t> along_left(shells.size(), 0);   // OG2b
    std::vector<double> along_most(shells.size(), 0.0);
    std::vector<char> rebuilt(shells.size(), 0), bed_cut(shells.size(), 0);
    // Trims one shell in place; true when it is still closed (by index, untouched) with a positive volume of at
    // least 5 % of what it was.
    auto trim_one = [&](const PartMeasure::Probe& pr, TriangleMesh& m, std::size_t s) {
      // The owner's flat bottom: a shell reaching under the bed is cut there, flat on the bed plane.
      bool under = false;
      for (const Vec3& v : m.vertices) under = under || v.z < bed - 1e-9;
      if (under && cut_shell_at_bed(m, bed)) bed_cut[s] = 1;
      const double before = volume_of(m, 0, m.triangles.size());
      std::size_t n = 0;
      double most = 0.0, outside = 0.0;
      // OG2: the proud tubes of this shell's piece (none for a shape of build_mesh's).
      const std::vector<Piece::Proud>* proud =
          made_from[s] >= 0 && !pieces[static_cast<std::size_t>(made_from[s])].proud.empty()
              ? &pieces[static_cast<std::size_t>(made_from[s])].proud
              : nullptr;
      const double slack = made_from[s] >= 0 ? pieces[static_cast<std::size_t>(made_from[s])].slack : 0.0;   // OV1
      auto in_proud = [&](const Vec3& v, double out_by) {
        for (const Piece::Proud& z : *proud) {
          if (z.along || out_by > z.out + 1e-6) continue;
          const Vec3 ab = sub(z.tip, z.from);
          const double l2 = dot(ab, ab);
          const double t = l2 > 0.0 ? std::clamp(dot(sub(v, z.from), ab) / l2, 0.0, 1.0) : 0.0;
          if (len(sub(v, add(z.from, mul(ab, t)))) <= 1.16 * z.r + slack + 1e-6) return true;
        }
        return false;
      };
      // OG2b: the largest p of the along-face bars whose tube holds v (0: none).
      auto along_p = [&](const Vec3& v) {
        double p = 0.0;
        for (const Piece::Proud& z : *proud) {
          if (!z.along || !(z.out > p)) continue;
          const Vec3 ab = sub(z.tip, z.from);
          const double l2 = dot(ab, ab);
          const double t = l2 > 0.0 ? std::clamp(dot(sub(v, z.from), ab) / l2, 0.0, 1.0) : 0.0;
          if (len(sub(v, add(z.from, mul(ab, t)))) <= 1.16 * z.r + slack + 1e-6) p = z.out;
        }
        return p;
      };
      std::size_t kept_out = 0, along_out = 0;
      double kept_most = 0.0, along_far = 0.0;
      for (Vec3& v : m.vertices) {
        if (v.z < bed) { v.z = bed; ++n; }
        if (pr.inside(v)) continue;
        double d = pr.depth(v);
        if (proud && in_proud(v, -d)) {
          ++kept_out;
          kept_most = std::max(kept_most, -d);
          continue;
        }
        if (const double p = proud ? along_p(v) : 0.0; p > 0.0) {   // OG2b: out by no more than p
          for (int it = 0; it < 4 && d < -p - 1e-4; ++it) {
            v = add(v, mul(pr.through(v), -d - p));
            d = pr.depth(v);
          }
          if (v.z < bed) v.z = bed;
          ++along_out;
          along_far = std::max(along_far, -d);
          continue;
        }
        if (d >= -over) { outside = std::max(outside, -d); continue; }
        const Vec3 was = v;
        for (int it = 0; it < 4 && d < -1e-4; ++it) {
          v = add(v, mul(pr.through(v), -d));
          d = pr.depth(v);
        }
        if (v.z < bed) v.z = bed;
        ++n;
        most = std::max(most, len(sub(v, was)));
        outside = std::max(outside, std::max(0.0, -d));
      }
      const double after = volume_of(m, 0, m.triangles.size());
      moved[s] = n;
      moved_most[s] = most;
      outside_most[s] = outside;
      proud_left[s] = kept_out;
      proud_most[s] = kept_most;
      along_left[s] = along_out;
      along_most[s] = along_far;
      return after > 0.0 && after >= 0.05 * before;
    };
    // A tube made again from its run cut back where its line leaves the part: the longest stretch of its centre line
    // inside the part, ends found to a micron, flat there; an end that was inside keeps its own cap.
    auto cut_back = [&](const PartMeasure::Probe& pr, const Piece& pc, Piece& cut) {
      const std::size_t n = pc.p.size();
      std::vector<char> in(n);
      for (std::size_t j = 0; j < n; ++j) in[j] = pr.inside(pc.p[j]);
      // Each segment sampled at 0.1 mm for where the line is inside: the longest inside stretch, as (segment, t).
      struct At { std::size_t seg; double t; };
      std::vector<std::pair<At, At>> stretches;
      bool open = false;
      At from{0, 0.0};
      auto edge = [&](std::size_t k, double ta, double tb) {   // the place between ta (in) and tb (out) or back
        const bool a_in = pr.inside(add(pc.p[k], mul(sub(pc.p[k + 1], pc.p[k]), ta)));
        for (int it = 0; it < 30; ++it) {
          const double tm = 0.5 * (ta + tb);
          (pr.inside(add(pc.p[k], mul(sub(pc.p[k + 1], pc.p[k]), tm))) == a_in ? ta : tb) = tm;
        }
        return a_in ? ta : tb;
      };
      for (std::size_t k = 0; k + 1 < n; ++k) {
        const double L = len(sub(pc.p[k + 1], pc.p[k]));
        const int steps = std::max(1, static_cast<int>(std::ceil(L / 0.1)));
        double tp = 0.0;
        bool ip = pr.inside(pc.p[k]);
        if (k == 0 && ip) { open = true; from = {0, 0.0}; }
        for (int q = 1; q <= steps; ++q) {
          const double t = static_cast<double>(q) / steps;
          const bool i2 = pr.inside(add(pc.p[k], mul(sub(pc.p[k + 1], pc.p[k]), t)));
          if (i2 != ip) {
            const double te = edge(k, tp, t);
            if (i2) { open = true; from = {k, te}; }
            else if (open) { stretches.push_back({from, {k, te}}); open = false; }
          }
          ip = i2;
          tp = t;
        }
      }
      if (open) stretches.push_back({from, {n - 2, 1.0}});
      double best = 0.0;
      const std::pair<At, At>* pick = nullptr;
      auto along = [&](const At& a) {
        double l = 0.0;
        for (std::size_t k = 0; k < a.seg; ++k) l += len(sub(pc.p[k + 1], pc.p[k]));
        return l + a.t * len(sub(pc.p[a.seg + 1], pc.p[a.seg]));
      };
      for (const auto& st : stretches) {
        const double l = along(st.second) - along(st.first);
        if (l > best) { best = l; pick = &st; }
      }
      if (!pick || best < 1e-3) return false;
      auto point = [&](const At& a) { return add(pc.p[a.seg], mul(sub(pc.p[a.seg + 1], pc.p[a.seg]), a.t)); };
      auto radius = [&](const At& a) { return pc.r[a.seg] + (pc.r[a.seg + 1] - pc.r[a.seg]) * a.t; };
      cut = Piece{};
      cut.kind = pc.kind;
      cut.sides = pc.sides;
      cut.p.push_back(point(pick->first));
      cut.r.push_back(radius(pick->first));
      for (std::size_t j = pick->first.seg + 1; j <= pick->second.seg; ++j) {
        if (len(sub(pc.p[j], cut.p.back())) < 1e-6) continue;
        cut.p.push_back(pc.p[j]);
        cut.r.push_back(pc.r[j]);
      }
      const Vec3 e = point(pick->second);
      if (len(sub(e, cut.p.back())) > 1e-6) { cut.p.push_back(e); cut.r.push_back(radius(pick->second)); }
      if (cut.p.size() < 2) return false;
      const bool a_whole = pick->first.seg == 0 && pick->first.t == 0.0 && in[0];
      const bool b_whole = pick->second.seg == n - 2 && pick->second.t == 1.0 && in[n - 1];
      cut.cap_a = a_whole ? pc.cap_a : Cap::Flat;
      cut.cap_b = b_whole ? pc.cap_b : Cap::Flat;
      return true;
    };
    std::atomic<std::size_t> next{0};
    auto work = [&] {
      const PartMeasure::Probe pr = part.probe();
      for (std::size_t s = next.fetch_add(1); s < shells.size() && !(spec.stop && spec.stop->load()); s = next.fetch_add(1)) {
        if (trim_one(pr, shells[s], s)) continue;
        keep[s] = 0;
        if (made_from[s] < 0) continue;
        Piece cut;
        if (!cut_back(pr, pieces[static_cast<std::size_t>(made_from[s])], cut)) continue;
        TriangleMesh again;
        std::vector<std::size_t> firsts;
        if (!(cut.kind == 0 ? sweep(cut, cut.sides > 0 ? cut.sides : sides, again, firsts) : sweep_section(cut, spec.bar_sides, again, firsts))) continue;
        if (!trim_one(pr, again, s)) continue;
        shells[s] = std::move(again);
        keep[s] = 1;
        rebuilt[s] = 1;
      }
    };
    const int nt = std::max(1, std::min<int>(spec.threads > 0 ? spec.threads : static_cast<int>(std::thread::hardware_concurrency()),
                                            static_cast<int>(shells.size())));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
    if (spec.stop && spec.stop->load()) throw LayCancelled{};
    for (std::size_t s = 0; s < shells.size(); ++s) {
      out.rebuilt += rebuilt[s];
      out.cut_at_bed += bed_cut[s];
      if (!keep[s]) { ++out.left_out; continue; }
      out.trimmed_vertices += moved[s];
      out.trimmed_largest_mm = std::max(out.trimmed_largest_mm, moved_most[s]);
      out.outside_largest_mm = std::max(out.outside_largest_mm, outside_most[s]);
      out.proud_vertices += proud_left[s];
      out.proud_outside_mm = std::max(out.proud_outside_mm, proud_most[s]);
      out.along_vertices += along_left[s];
      out.along_outside_mm = std::max(out.along_outside_mm, along_most[s]);
    }
  }
  // OS1 (the reviewer's proof): the shallow runs' downward-facing surface (bars and their rounded ends, as written):
  // level (within 0.5 degrees of straight down), the bar's own flat bottom (a rising bridge's sloped underside, within
  // 0.5 degrees of a segment's bottom), or neither: curved or sloped, not a printed bridge's flat underside.
  {
    const double tight = std::cos(0.5 * 3.14159265358979323846 / 180.0);
    for (std::size_t s = 0; s < shells.size(); ++s) {
      if (!keep[s] || made_from[s] < 0) continue;
      const Piece& pc = pieces[static_cast<std::size_t>(made_from[s])];
      if (pc.kind == 0) continue;
      std::vector<Vec3> downs;
      for (std::size_t k = 0; k + 1 < pc.p.size(); ++k) {
        const Vec3 t = unit(sub(pc.p[k + 1], pc.p[k]));
        Vec3 sd{-t.y, t.x, 0.0};
        if (len(sd) < 1e-9) continue;
        sd = unit(sd);
        Vec3 u = cross(t, sd);
        if (u.z < 0) u = mul(u, -1.0);
        downs.push_back(mul(u, -1.0));
      }
      const TriangleMesh& m = shells[s];
      for (const auto& q : m.triangles) {
        const Vec3 &a = m.vertices[static_cast<std::size_t>(q[0])], &b = m.vertices[static_cast<std::size_t>(q[1])],
                   &c = m.vertices[static_cast<std::size_t>(q[2])];
        const Vec3 nn = cross(sub(b, a), sub(c, a));
        const double area = 0.5 * len(nn);
        if (!(area > 0.0)) continue;
        const Vec3 nu = mul(nn, 0.5 / area);
        if (!(nu.z < -0.05)) continue;   // not facing down
        if (-nu.z >= tight) { out.bridge_under_level_mm2 += area; continue; }
        bool own = false;
        for (const Vec3& d : downs) own = own || dot(nu, d) >= tight;
        (own ? out.bridge_under_own_mm2 : out.bridge_under_other_mm2) += area;
      }
    }
  }
  for (std::size_t s = 0; s < shells.size(); ++s) {
    if (!keep[s]) continue;
    const int base = static_cast<int>(out.mesh.vertices.size());
    out.first_tri.push_back(out.mesh.triangles.size());
    out.mesh.vertices.insert(out.mesh.vertices.end(), shells[s].vertices.begin(), shells[s].vertices.end());
    for (const auto& t : shells[s].triangles) out.mesh.triangles.push_back({t[0] + base, t[1] + base, t[2] + base});
    out.mm3 += volume_of(shells[s], 0, shells[s].triangles.size());
  }
  out.first_tri.push_back(out.mesh.triangles.size());
  {   // OG2b: how far the shells reach past the part's box
    const Vec3 lo = part.lo(), hi = part.hi();
    for (const Vec3& v : out.mesh.vertices) {
      out.grew_mm[0] = std::max(out.grew_mm[0], lo.x - v.x);
      out.grew_mm[1] = std::max(out.grew_mm[1], v.x - hi.x);
      out.grew_mm[2] = std::max(out.grew_mm[2], lo.y - v.y);
      out.grew_mm[3] = std::max(out.grew_mm[3], v.y - hi.y);
      out.grew_mm[4] = std::max(out.grew_mm[4], lo.z - v.z);
      out.grew_mm[5] = std::max(out.grew_mm[5], v.z - hi.z);
    }
  }
  out.ms = ms_since(t0);
  return out;
}

}  // namespace topopt::lattice_layout
