// The canonical strut cell per type (topopt/strut_cell.hpp states the contract).
//
// The builders are the strut-lattice family study's integer machinery
// (evidence/2026-07-27-strut-lattice-family/strut_lattice_gen.cpp), the same code
// tensor_library_nine_probe.cpp copied to measure the landed tensor rows. They are
// re-stated here, not invented: test_strut_cell compiles the probe's source and
// asserts this table equals the probe's make_lattice() for every type.

#include "topopt/strut_cell.hpp"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <functional>
#include <set>
#include <stdexcept>
#include <string>
#include <tuple>

namespace topopt {
namespace {

using P = StrutCellPoint;

bool lt(const P& a, const P& b) {
  return std::tie(a.x, a.y, a.z) < std::tie(b.x, b.y, b.z);
}
struct PLess {
  bool operator()(const P& a, const P& b) const { return lt(a, b); }
};
struct SLess {
  bool operator()(const StrutCellStrut& s, const StrutCellStrut& t) const {
    if (lt(s.a, t.a)) return true;
    if (lt(t.a, s.a)) return false;
    return lt(s.b, t.b);
  }
};
P add(const P& a, const P& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
long dist2(const P& a, const P& b) {
  const long dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
  return dx * dx + dy * dy + dz * dz;
}
StrutCellStrut canonicalized(const P& a, const P& b) {
  return lt(b, a) ? StrutCellStrut{b, a} : StrutCellStrut{a, b};
}
// Midpoint in [0,S)^3 <=> each component of (a+b) in [0, 2S) (integers, exact).
bool midpoint_in_cell(const P& a, const P& b, int S) {
  auto ok = [S](int u, int v) {
    const int m2 = u + v;
    return m2 >= 0 && m2 < 2 * S;
  };
  return ok(a.x, b.x) && ok(a.y, b.y) && ok(a.z, b.z);
}
bool in_half_open(const P& p, int S) {
  return p.x >= 0 && p.x < S && p.y >= 0 && p.y < S && p.z >= 0 && p.z < S;
}
bool in_closed(const P& p, int S) {
  return p.x >= 0 && p.x <= S && p.y >= 0 && p.y <= S && p.z >= 0 && p.z <= S;
}
bool is_corner(const P& p, int S) {
  return p.x % S == 0 && p.y % S == 0 && p.z % S == 0;
}

// Bravais lattices: nearest-neighbour bonds of the right class over the 3^3 block,
// folded canonical (the probe's canonical_from_pairs).
std::vector<StrutCellStrut> from_pairs(const std::vector<P>& basis, int S,
                                       const std::function<bool(P, P)>& bond) {
  std::vector<P> pts;
  for (int dz = -1; dz <= 1; ++dz)
    for (int dy = -1; dy <= 1; ++dy)
      for (int dx = -1; dx <= 1; ++dx)
        for (const P& n : basis) pts.push_back({n.x + dx * S, n.y + dy * S, n.z + dz * S});
  std::set<StrutCellStrut, SLess> uniq;
  for (std::size_t i = 0; i < pts.size(); ++i)
    for (std::size_t j = i + 1; j < pts.size(); ++j) {
      if (!bond(pts[i], pts[j])) continue;
      if (midpoint_in_cell(pts[i], pts[j], S)) uniq.insert(canonicalized(pts[i], pts[j]));
    }
  return {uniq.begin(), uniq.end()};
}

// Voronoi-cell lattices (Kelvin, rhombic): each polyhedron's own edges at the known
// edge length, folded canonical (the probe's canonical_from_polyhedra).
std::vector<StrutCellStrut> from_polyhedra(const std::vector<P>& centres, int S,
                                           const std::vector<P>& verts, long edge_d2) {
  std::set<StrutCellStrut, SLess> uniq;
  for (int dz = -1; dz <= 1; ++dz)
    for (int dy = -1; dy <= 1; ++dy)
      for (int dx = -1; dx <= 1; ++dx)
        for (const P& c : centres) {
          const P C{c.x + dx * S, c.y + dy * S, c.z + dz * S};
          std::vector<P> v;
          v.reserve(verts.size());
          for (const P& r : verts) v.push_back(add(C, r));
          for (std::size_t i = 0; i < v.size(); ++i)
            for (std::size_t j = i + 1; j < v.size(); ++j)
              if (dist2(v[i], v[j]) == edge_d2 && midpoint_in_cell(v[i], v[j], S))
                uniq.insert(canonicalized(v[i], v[j]));
        }
  return {uniq.begin(), uniq.end()};
}

// The polyhedra's vertices folded into the half-open cell (the family study's node
// lists for Kelvin and rhombic).
std::vector<P> folded_vertices(const std::vector<P>& centres, int S,
                               const std::vector<P>& verts) {
  std::set<P, PLess> ns;
  for (int dz = -1; dz <= 1; ++dz)
    for (int dy = -1; dy <= 1; ++dy)
      for (int dx = -1; dx <= 1; ++dx)
        for (const P& c : centres) {
          const P C{c.x + dx * S, c.y + dy * S, c.z + dz * S};
          for (const P& r : verts) {
            const P p = add(C, r);
            if (in_half_open(p, S)) ns.insert(p);
          }
        }
  return {ns.begin(), ns.end()};
}

std::vector<P> bcc_basis(int S) { return {{0, 0, 0}, {S / 2, S / 2, S / 2}}; }
std::vector<P> fcc_basis(int S) {
  const int h = S / 2;
  return {{0, 0, 0}, {h, h, 0}, {h, 0, h}, {0, h, h}};
}
std::vector<P> diamond_basis(int S) {  // S = 4: 4 FCC 'A' sites + 4 'B' (offset S/4)
  const int q = S / 4, h = S / 2;
  return {{0, 0, 0}, {h, h, 0},         {h, 0, h},         {0, h, h},
          {q, q, q}, {q, 3 * q, 3 * q}, {3 * q, q, 3 * q}, {3 * q, 3 * q, q}};
}
// Truncated-octahedron vertices (24) about its centre: all permutations of (0, ±1, ±2).
std::vector<P> trunc_oct_verts() {
  std::set<std::array<int, 3>> s;
  const int base[3] = {0, 1, 2};
  int perm[3] = {0, 1, 2};
  do {
    for (int s1 = -1; s1 <= 1; s1 += 2)
      for (int s2 = -1; s2 <= 1; s2 += 2) {
        std::array<int, 3> p{};
        for (int k = 0; k < 3; ++k) {
          const int val = base[perm[k]];
          p[k] = val == 0 ? 0 : val == 1 ? s1 : 2 * s2;
        }
        s.insert(p);
      }
  } while (std::next_permutation(perm, perm + 3));
  std::vector<P> out;
  for (const auto& p : s) out.push_back({p[0], p[1], p[2]});
  return out;
}
// Rhombic-dodecahedron vertices (14): 6 axis (±2,0,0) and permutations, 8 (±1,±1,±1).
std::vector<P> rhombic_dodec_verts() {
  std::vector<P> v;
  for (int s = -2; s <= 2; s += 4) {
    v.push_back({s, 0, 0});
    v.push_back({0, s, 0});
    v.push_back({0, 0, s});
  }
  for (int a = -1; a <= 1; a += 2)
    for (int b = -1; b <= 1; b += 2)
      for (int c = -1; c <= 1; c += 2) v.push_back({a, b, c});
  return v;
}

std::vector<P> sorted_unique(std::vector<P> v) {
  std::set<P, PLess> s(v.begin(), v.end());
  return {s.begin(), s.end()};
}

StrutCell build(LatticeTopology topo) {
  StrutCell c;
  switch (topo) {
    case LatticeTopology::SimpleCubic:
      c.S = 2;
      c.nodes = {{0, 0, 0}};
      c.struts = from_pairs({{0, 0, 0}}, c.S, [S = c.S](P a, P b) {
        return dist2(a, b) == static_cast<long>(S) * S;
      });
      break;
    case LatticeTopology::Bcc:
      c.S = 2;
      c.nodes = sorted_unique(bcc_basis(c.S));
      c.struts = from_pairs(bcc_basis(c.S), c.S, [](P a, P b) { return dist2(a, b) == 3; });
      break;
    case LatticeTopology::Fcc:
      c.S = 2;
      c.nodes = sorted_unique(fcc_basis(c.S));
      c.struts = from_pairs(fcc_basis(c.S), c.S, [S = c.S](P a, P b) {
        return dist2(a, b) == 2 && (is_corner(a, S) != is_corner(b, S));
      });
      break;
    case LatticeTopology::Octet:
      c.S = 2;
      c.nodes = sorted_unique(fcc_basis(c.S));
      c.struts = from_pairs(fcc_basis(c.S), c.S, [](P a, P b) { return dist2(a, b) == 2; });
      break;
    case LatticeTopology::Diamond:
      c.S = 4;
      c.nodes = sorted_unique(diamond_basis(c.S));
      c.struts =
          from_pairs(diamond_basis(c.S), c.S, [](P a, P b) { return dist2(a, b) == 3; });
      break;
    case LatticeTopology::Kelvin: {
      c.S = 4;
      const std::vector<P> centres = {{0, 0, 0}, {2, 2, 2}};  // BCC sites
      c.struts = from_polyhedra(centres, c.S, trunc_oct_verts(), 2);
      c.nodes = folded_vertices(centres, c.S, trunc_oct_verts());
      break;
    }
    case LatticeTopology::Rhombic: {
      c.S = 4;
      const std::vector<P> centres = fcc_basis(c.S);  // FCC sites
      c.struts = from_polyhedra(centres, c.S, rhombic_dodec_verts(), 3);
      c.nodes = folded_vertices(centres, c.S, rhombic_dodec_verts());
      break;
    }
    case LatticeTopology::Bccz:
    case LatticeTopology::Fccz:
    case LatticeTopology::Reentrant:
      throw std::invalid_argument(
          std::string("lattice_strut_cell: \"") + lattice_topology_name(topo) +
          "\" has no canonical cell in core: it is tetragonal and not in round 1 "
          "(docs/design/lattice-types/00-decisions.md M1).");
    case LatticeTopology::Gyroid:
    case LatticeTopology::SchwarzD:
      throw std::invalid_argument(
          std::string("lattice_strut_cell: \"") + lattice_topology_name(topo) +
          "\" is a SHEET lattice: it has no struts, its geometry is the TPMS field "
          "(topopt/tpms.hpp).");
  }
  // The ownership invariant the generator rests on: every canonical strut lies inside
  // its owner's CLOSED box. A cell that broke this would emit geometry outside itself.
  for (const StrutCellStrut& s : c.struts)
    if (!in_closed(s.a, c.S) || !in_closed(s.b, c.S))
      throw std::logic_error(std::string("lattice_strut_cell: a canonical ") +
                             lattice_topology_name(topo) +
                             " strut leaves its owner's closed cell");
  return c;
}

}  // namespace

bool lattice_has_strut_cell(LatticeTopology topo) {
  switch (topo) {
    case LatticeTopology::Octet:
    case LatticeTopology::SimpleCubic:
    case LatticeTopology::Bcc:
    case LatticeTopology::Fcc:
    case LatticeTopology::Diamond:
    case LatticeTopology::Kelvin:
    case LatticeTopology::Rhombic:
      return true;
    case LatticeTopology::Bccz:
    case LatticeTopology::Fccz:
    case LatticeTopology::Reentrant:
    case LatticeTopology::Gyroid:
    case LatticeTopology::SchwarzD:
      return false;
  }
  return false;
}

const StrutCell& lattice_strut_cell(LatticeTopology topo) {
  // One build per type, on first use (function-local statics are thread-safe).
  switch (topo) {
    case LatticeTopology::Octet: { static const StrutCell c = build(topo); return c; }
    case LatticeTopology::SimpleCubic: { static const StrutCell c = build(topo); return c; }
    case LatticeTopology::Bcc: { static const StrutCell c = build(topo); return c; }
    case LatticeTopology::Fcc: { static const StrutCell c = build(topo); return c; }
    case LatticeTopology::Diamond: { static const StrutCell c = build(topo); return c; }
    case LatticeTopology::Kelvin: { static const StrutCell c = build(topo); return c; }
    case LatticeTopology::Rhombic: { static const StrutCell c = build(topo); return c; }
    case LatticeTopology::Bccz:
    case LatticeTopology::Fccz:
    case LatticeTopology::Reentrant:
    case LatticeTopology::Gyroid:
    case LatticeTopology::SchwarzD:
      break;
  }
  build(topo);  // throws, naming the type
  throw std::logic_error("lattice_strut_cell: unreachable");
}

std::vector<StrutCellStrut> strut_cell_closed_struts(const StrutCell& cell) {
  const int S = cell.S;
  std::vector<StrutCellStrut> out;
  for (const StrutCellStrut& s : cell.struts)
    for (int dz = -1; dz <= 1; ++dz)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          const P sh{dx * S, dy * S, dz * S};
          const P a = add(s.a, sh), b = add(s.b, sh);
          if (in_closed(a, S) && in_closed(b, S)) out.push_back({a, b});
        }
  return out;
}

std::vector<StrutCellPoint> strut_cell_closed_nodes(const StrutCell& cell) {
  const int S = cell.S;
  std::vector<P> out;
  for (const P& n : cell.nodes)
    for (int dz = -1; dz <= 1; ++dz)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          const P p{n.x + dx * S, n.y + dy * S, n.z + dz * S};
          if (in_closed(p, S)) out.push_back(p);
        }
  return out;
}

namespace {
double halton(unsigned i, unsigned base) {
  double f = 1.0, r = 0.0;
  while (i > 0) {
    f /= base;
    r += f * (i % base);
    i /= base;
  }
  return r;
}
}  // namespace

double strut_cell_solid_fraction(const StrutCell& cell, double r_unit, int samples) {
  if (!(r_unit > 0.0) || !(samples > 0))
    throw std::invalid_argument("strut_cell_solid_fraction: r_unit and samples must be > 0");
  struct Seg { double ax, ay, az, ex, ey, ez, len2; };
  std::vector<Seg> segs;
  const double inv = 1.0 / cell.S;
  for (const StrutCellStrut& s : cell.struts)
    for (int dz = -1; dz <= 1; ++dz)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          const double ax = s.a.x * inv + dx, ay = s.a.y * inv + dy, az = s.a.z * inv + dz;
          const double bx = s.b.x * inv + dx, by = s.b.y * inv + dy, bz = s.b.z * inv + dz;
          if (std::max(ax, bx) < -r_unit || std::min(ax, bx) > 1.0 + r_unit ||
              std::max(ay, by) < -r_unit || std::min(ay, by) > 1.0 + r_unit ||
              std::max(az, bz) < -r_unit || std::min(az, bz) > 1.0 + r_unit)
            continue;
          const double ex = bx - ax, ey = by - ay, ez = bz - az;
          segs.push_back({ax, ay, az, ex, ey, ez, ex * ex + ey * ey + ez * ez});
        }
  const double r2 = r_unit * r_unit;
  long long solid = 0;
  for (int n = 1; n <= samples; ++n) {
    const double x = halton(static_cast<unsigned>(n), 2), y = halton(static_cast<unsigned>(n), 3),
                 z = halton(static_cast<unsigned>(n), 5);
    for (const Seg& s : segs) {
      double t = s.len2 > 0.0
                     ? ((x - s.ax) * s.ex + (y - s.ay) * s.ey + (z - s.az) * s.ez) / s.len2
                     : 0.0;
      t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
      const double qx = x - (s.ax + t * s.ex), qy = y - (s.ay + t * s.ey),
                   qz = z - (s.az + t * s.ez);
      if (qx * qx + qy * qy + qz * qz < r2) { ++solid; break; }
    }
  }
  return static_cast<double>(solid) / static_cast<double>(samples);
}

double strut_cell_voxel_density(const StrutCell& cell, double r_unit, int vpc) {
  if (!(r_unit > 0.0) || !(vpc > 0))
    throw std::invalid_argument("strut_cell_voxel_density: r_unit and vpc must be > 0");
  // The 27 integer-shift images of every canonical strut, in unit-cell coordinates,
  // kept only when they come within r of the unit cube: the rest cannot reach a voxel
  // centre and skipping them changes no voxel (a strict cull on the same test).
  struct Seg { double ax, ay, az, ex, ey, ez, len2; };
  std::vector<Seg> segs;
  const double inv = 1.0 / cell.S;
  for (const StrutCellStrut& s : cell.struts)
    for (int dz = -1; dz <= 1; ++dz)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          const double ax = s.a.x * inv + dx, ay = s.a.y * inv + dy, az = s.a.z * inv + dz;
          const double bx = s.b.x * inv + dx, by = s.b.y * inv + dy, bz = s.b.z * inv + dz;
          if (std::max(ax, bx) < -r_unit || std::min(ax, bx) > 1.0 + r_unit ||
              std::max(ay, by) < -r_unit || std::min(ay, by) > 1.0 + r_unit ||
              std::max(az, bz) < -r_unit || std::min(az, bz) > 1.0 + r_unit)
            continue;
          const double ex = bx - ax, ey = by - ay, ez = bz - az;
          segs.push_back({ax, ay, az, ex, ey, ez, ex * ex + ey * ey + ez * ez});
        }
  const double r2 = r_unit * r_unit;
  long long solid = 0;
  for (int k = 0; k < vpc; ++k)
    for (int j = 0; j < vpc; ++j)
      for (int i = 0; i < vpc; ++i) {
        const double x = (i + 0.5) / vpc, y = (j + 0.5) / vpc, z = (k + 0.5) / vpc;
        for (const Seg& s : segs) {
          double t = s.len2 > 0.0
                         ? ((x - s.ax) * s.ex + (y - s.ay) * s.ey + (z - s.az) * s.ez) / s.len2
                         : 0.0;
          t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
          const double qx = x - (s.ax + t * s.ex), qy = y - (s.ay + t * s.ey),
                       qz = z - (s.az + t * s.ez);
          if (qx * qx + qy * qy + qz * qz < r2) { ++solid; break; }
        }
      }
  return static_cast<double>(solid) /
         (static_cast<double>(vpc) * static_cast<double>(vpc) * static_cast<double>(vpc));
}

}  // namespace topopt
